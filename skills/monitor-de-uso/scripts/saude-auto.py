#!/usr/bin/env python3
"""Automação da saúde da máquina (serviço do usuário `saude-auto`).

Faz sozinha, a cada SAUDE_AUTO_INTERVALO s (padrão 60), o que a tabela do zelador fazia à mão, e só escreve em
`saude-escalados.log` o que pede julgamento ou o que não conseguiu resolver. O agente zelador (sonnet, gerido pela
sessão gerente) espera esse log com `esperar-zelador.sh`. Os orquestradores dos projetos nunca recebem nada daqui.

Lê o `$KIT_CACHE/saude.log` do `saude-maquina.sh` (colunas pelo cabeçalho mais recente).
  COLETOR: log com mais de 3 min -> roda o garantir-monitor.sh; 3 olhadas seguidas sem voltar -> escala.
  CI-TÉRMICA: serviço inativo -> restart; ainda inativo na olhada seguinte -> escala.
  VENTOINHAS: com CI (processo que casa KIT_CI_PADRAO) há mais de 90 s e um arquivo de KIT_FAN_BOOST abaixo de 255
    -> grava 255 e confere; escala se a escrita falhar ou se precisar repor 3 vezes em 30 min (algo as zera).
  DISCO (o menor livre entre / e $HOME; no máximo uma cascata a cada 30 min): < 50 GB -> `docker builder prune -f
    --filter until=6h`; < 40 GB -> until=2h e, se preciso, until=1h; < 15 GB -> `uv cache prune`; ainda < 15 GB
    -> escala. SAUDE_AUTO_PRUNE=0 desliga as limpezas (só escala o crítico).
  ESCALA (com reaviso de 30 min, 60 na temperatura, enquanto persistir): Docker fora (4 amostras sem contagem de
    contêineres); CPU crítica (>= 96 °C) a hora inteira com a GPU abaixo de 30 W (calor só da CI); memória
    disponível < 3 GB ou PSI de memória > 10% por 30 min; PSI de CPU > 60% por 60 min sem CI.
  TETO DA MÁQUINA para os orquestradores (sem acordar ninguém): grava em `teto-maquina` (mesma pasta) KIT_TETO_AGENTES_CARGA se a
    carga de 1 min passou de KIT_CARGA_ALTA em alguma amostra dos últimos 30 min, senão KIT_TETO_AGENTES. O orquestrador lê o arquivo antes de lançar agente.
  WSL (Windows): sem hwmon do host, ventoinhas são puladas; sem systemd, o ci-termica não é cobrado; sem docker, não
  há DOCKER FORA nem limpeza do docker. Disco e carga valem (o df do / do WSL conta). O swap não entra. Temperatura alta com a GPU em uso é esperada: só o ci-termica age.
Cada ação vai numa linha em $KIT_REGISTRO, com o desfazer; o log próprio é
$KIT_CACHE/saude-auto.log, e o estado (com a batida) saude-auto-estado.json.
Modos: (sem argumento) serviço; `--uma-vez`; `--autoteste` (log, sysfs e comandos falsos, sem tocar no sistema).
Para provas, SAUDE_AUTO_* trocam caminhos e comandos (veja `CFG`).
"""
import fcntl, glob, json, os, re, shlex, shutil, signal, subprocess, sys, time

sys.path.insert(0, os.path.expanduser("~/.claude/skills/gerente-da-maquina/lib"))
sys.path.insert(1, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "gerente-da-maquina", "lib"))
import kit_config as K

ENV = os.environ
H = os.path.expanduser
KC = K.cfg


def _wsl():
    if ENV.get("SAUDE_AUTO_WSL") in ("0", "1"):
        return ENV["SAUDE_AUTO_WSL"] == "1"
    try:
        return "microsoft" in open("/proc/version").read().lower()
    except OSError:
        return False


WSL = _wsl()
CFG = {
    "INTERVALO": float(ENV.get("SAUDE_AUTO_INTERVALO", "60")),
    "DIR": H(ENV.get("SAUDE_AUTO_DIR", KC["KIT_CACHE"])),
    "LOG_SAUDE": H(ENV.get("SAUDE_AUTO_LOG", os.path.join(KC["KIT_CACHE"], "saude.log"))),
    "MUDANCAS": H(ENV.get("SAUDE_AUTO_MUDANCAS", KC["KIT_REGISTRO"])),
    "FAN": ENV["SAUDE_AUTO_FAN"] if "SAUDE_AUTO_FAN" in ENV else KC["KIT_FAN_BOOST"],
    "ATIVA": KC["KIT_TERM_ATIVA"] != "0" and ENV.get("SAUDE_AUTO_TERM", "1") != "0",
    "DISCO_CMD": ENV.get("SAUDE_AUTO_DISCO_CMD", ""),  # provas: comando que imprime os GB livres
    "DOCKER": ENV.get("SAUDE_AUTO_DOCKER", "docker"),
    "UV": ENV.get("SAUDE_AUTO_UV", "uv"),
    "SYSTEMCTL": ENV.get("SAUDE_AUTO_SYSTEMCTL", "systemctl --user"),
    "GARANTIR": ENV.get("SAUDE_AUTO_GARANTIR", os.path.join(os.path.dirname(os.path.abspath(__file__)), "garantir-monitor.sh")),
    "CI_CMD": ENV.get("SAUDE_AUTO_CI_CMD", "pgrep " + shlex.quote(KC["KIT_CI_PADRAO"])),
    "GPU_W_CMD": ENV.get("SAUDE_AUTO_GPU_W_CMD", "nvidia-smi --query-gpu=power.draw --format=csv,noheader,nounits"),
    "PRUNE": ENV.get("SAUDE_AUTO_PRUNE", "1") != "0",
    "SESSOES": H(ENV.get("SAUDE_AUTO_SESSOES", "~/.claude/sessions")),
    "PROJETOS": H(ENV.get("SAUDE_AUTO_PROJETOS", "~/.claude/projects")),
    "PROC": ENV.get("SAUDE_AUTO_PROC", "/proc"),
}
ESTADO = os.path.join(CFG["DIR"], "saude-auto-estado.json")
LOG = os.path.join(CFG["DIR"], "saude-auto.log")
ESCALADOS = os.path.join(CFG["DIR"], "saude-escalados.log")
CABECALHO = ("data_hora carga1 carga5 mem_disp_GB swap_GB psi_cpu psi_mem psi_io_full conteineres jobs_ci "
             "cpu_pacote_C cpu_nucleo_max_C cpu_mhz gpu_C docker_nucleos docker_mem_GB ci_nucleos ci_mem_GB "
             "sessoes_nucleos docker_psi_mem").split()


def iso():
    return time.strftime("%Y-%m-%dT%H:%M:%S%z")


def anexar(caminho, linha):
    os.makedirs(os.path.dirname(caminho), exist_ok=True)
    with open(caminho, "a") as f:
        f.write(linha + "\n")


def rodar(cmd, timeout=600):
    """(código, saída) de um comando em texto; nunca levanta."""
    try:
        r = subprocess.run(shlex.split(cmd) if isinstance(cmd, str) else cmd, capture_output=True, text=True,
                           timeout=timeout)
        return r.returncode, (r.stdout + r.stderr).strip()
    except (OSError, subprocess.SubprocessError) as e:
        return 127, str(e)


def amostras(segundos):
    """Amostras do log de saúde dos últimos `segundos` (dicts com float ou None), da mais antiga à mais nova."""
    try:
        with open(CFG["LOG_SAUDE"], "rb") as f:
            f.seek(0, 2)
            f.seek(max(0, f.tell() - int(segundos / 30 + 20) * 200))
            linhas = f.read().decode("utf-8", "replace").replace("\0", "").splitlines()
    except OSError:
        return []
    cab, out, limite = CABECALHO, [], time.time() - segundos
    for l in linhas:
        c = l.split()
        if not c:
            continue
        if c[0] == "data_hora":
            cab = c
            continue
        if len(c) != len(cab) or "T" not in c[0]:
            continue
        try:
            ts = time.mktime(time.strptime(c[0], "%Y-%m-%dT%H:%M:%S"))
        except ValueError:
            continue
        if ts < limite:
            continue
        d = {"ts": ts}
        for k, v in zip(cab[1:], c[1:]):
            try:
                d[k] = float(v)
            except ValueError:
                d[k] = None
        out.append(d)
    return out


def persistiu(segundos, cond):
    """Verdadeiro se há amostras cobrindo os últimos `segundos` (tolerância de 2 min) e todas cumprem `cond`."""
    a = amostras(segundos)
    return bool(a) and a[0]["ts"] <= time.time() - segundos + 120 and all(cond(x) for x in a)


def livre_gb():
    if CFG["DISCO_CMD"]:
        return float(rodar(CFG["DISCO_CMD"])[1] or 0)
    vals = []
    for p in ("/", H("~")):
        st = os.statvfs(p)
        vals.append(st.f_bavail * st.f_frsize / 1e9)
    return min(vals)


class Zelo:
    def __init__(self):
        try:
            with open(ESTADO) as f:
                self.e = json.load(f)
        except (OSError, ValueError):
            self.e = {}
        self.agora = time.time()

    def gravar(self):
        self.e["batida"] = time.time()
        os.makedirs(CFG["DIR"], exist_ok=True)
        tmp = ESTADO + ".tmp"
        with open(tmp, "w") as f:
            json.dump(self.e, f)
        os.replace(tmp, ESTADO)

    def escalar(self, chave, texto, reaviso_min=30):
        ult = self.e.setdefault("escalado", {}).get(chave, 0)
        if self.agora - ult < reaviso_min * 60:
            return
        self.e["escalado"][chave] = self.agora
        anexar(ESCALADOS, f"{iso()} {texto}")
        anexar(LOG, f"{iso()} escalado: {texto}")

    def limpar(self, chave):
        self.e.setdefault("escalado", {}).pop(chave, None)

    def mudanca(self, texto, desfazer):
        anexar(LOG, f"{iso()} {texto}")
        anexar(CFG["MUDANCAS"], f"{iso()} saude-auto: {texto}. Desfazer: {desfazer}")

    # --- verificações ---
    def coletor(self):
        try:
            idade = self.agora - os.stat(CFG["LOG_SAUDE"]).st_mtime
        except OSError:
            idade = 1e9
        if idade <= 180:
            self.e["coletor_falhas"] = 0
            self.limpar("coletor")
            return
        n = self.e.get("coletor_falhas", 0) + 1
        self.e["coletor_falhas"] = n
        if n >= 3:
            self.escalar("coletor", f"COLETOR PARADO: o saude.log não é escrito há {int(idade // 60)} min, mesmo "
                                    f"depois de {n - 1} tentativas do garantir-monitor.sh")
        cod, out = rodar(["bash", CFG["GARANTIR"]], timeout=60)
        anexar(LOG, f"{iso()} coletor parado ({int(idade)} s): garantir-monitor.sh -> {cod}")

    def ci_termica(self):
        if not CFG["ATIVA"]:
            return
        cod, out = rodar(f"{CFG['SYSTEMCTL']} is-active ci-termica", timeout=20)
        if cod == 127 or "Failed to connect" in out:
            return  # sem systemd do usuário (ex.: WSL sem systemd): nada a cobrar
        if out.strip() == "active":
            self.e["ci_termica_reinicios"] = 0
            self.limpar("ci_termica")
            return
        n = self.e.get("ci_termica_reinicios", 0)
        if n >= 1:
            self.escalar("ci_termica", f"CI-TÉRMICA FORA: o serviço ci-termica está '{out.strip()}' mesmo depois "
                                       f"de {n} restart(s). Veja: journalctl --user -u ci-termica -n 20")
        cod, _ = rodar(f"{CFG['SYSTEMCTL']} restart ci-termica", timeout=60)
        self.e["ci_termica_reinicios"] = n + 1
        self.mudanca(f"ci-termica estava '{out.strip()}'; restart -> {cod}",
                     "systemctl --user stop ci-termica")

    def ha_ci(self):
        cod, out = rodar(CFG["CI_CMD"], timeout=20)
        return cod == 0 and bool(out.strip())

    def ventoinhas(self):
        if not CFG["ATIVA"] or WSL or not CFG["FAN"] or not self.ha_ci():
            self.e["ci_desde"] = None
            return
        desde = self.e.get("ci_desde") or self.agora
        self.e["ci_desde"] = desde
        if self.agora - desde < 90:
            return
        baixos = []
        for f in sorted(glob.glob(CFG["FAN"])):
            try:
                v = int(open(f).read().strip())
            except (OSError, ValueError):
                continue
            if v < 255:
                baixos.append((f, v))
        if not baixos:
            return
        falhou = []
        for f, v in baixos:
            try:
                with open(f, "w") as fh:
                    fh.write("255\n")
                if int(open(f).read().strip()) != 255:
                    falhou.append(os.path.basename(f))
            except (OSError, ValueError):
                falhou.append(os.path.basename(f))
        nomes = ", ".join(f"{os.path.basename(f)}={v}" for f, v in baixos)
        if falhou:
            self.escalar("ventoinhas", f"VENTOINHAS: durante a CI estavam abaixo do máximo ({nomes}) e a escrita "
                                       f"de 255 falhou em {', '.join(falhou)}")
            return
        self.mudanca(f"ventoinhas abaixo do máximo durante a CI ({nomes}) -> 255",
                     "o ci-termica repõe o estado de antes quando a CI acaba")
        rep = [t for t in self.e.get("ventoinhas_reposicoes", []) if self.agora - t < 1800] + [self.agora]
        self.e["ventoinhas_reposicoes"] = rep
        if len(rep) >= 3:
            self.escalar("ventoinhas_zeradas", f"VENTOINHAS ZERADAS: precisei repor 255 {len(rep)} vezes em 30 min "
                                               f"durante a CI; algo as zera (extensão do desktop? udev?)", 120)

    def disco(self):
        livre = livre_gb()
        if livre >= 50:
            self.limpar("disco")
            return
        if self.agora - self.e.get("disco_ultima", 0) < 1800:
            return
        self.e["disco_ultima"] = self.agora
        antes = livre
        passos = []
        if CFG["PRUNE"] and shutil.which(shlex.split(CFG["DOCKER"])[0]):
            for limite, filtro in ((50, "6h"), (40, "2h"), (40, "1h")):
                if livre < limite:
                    cod, out = rodar(f"{CFG['DOCKER']} builder prune -f --filter until={filtro}", timeout=900)
                    novo = livre_gb()
                    passos.append(f"builder prune until={filtro} -> {cod}, {livre:.0f} -> {novo:.0f} GB")
                    livre = novo
            if livre < 15 and shutil.which(shlex.split(CFG["UV"])[0]):
                cod, out = rodar(f"{CFG['UV']} cache prune", timeout=900)
                novo = livre_gb()
                passos.append(f"uv cache prune -> {cod}, {livre:.0f} -> {novo:.0f} GB")
                livre = novo
        if passos:
            self.mudanca(f"disco com {antes:.0f} GB livres: " + "; ".join(passos),
                         "não se aplica (o cache se refaz no próximo build)")
        if livre < 15:
            self.escalar("disco", f"DISCO CRÍTICO: {livre:.0f} GB livres (menor entre / e $HOME) depois da limpeza "
                                  f"automática ({'; '.join(passos) or 'limpeza desligada'})")

    def amostrais(self):
        ult = amostras(150)[-4:]
        if shutil.which(shlex.split(CFG["DOCKER"])[0]) and len(ult) >= 4 and all(x.get("conteineres") is None for x in ult):
            self.escalar("docker", "DOCKER FORA: o coletor não conta contêineres há 4 amostras (o Docker precisa "
                                   "de sudo para voltar)")
        elif ult:
            self.limpar("docker")
        if persistiu(3600, lambda x: (x.get("cpu_pacote_C") or 0) >= 96):
            cod, out = rodar(CFG["GPU_W_CMD"], timeout=20)
            try:
                w = float(out.split()[0])
            except (ValueError, IndexError):
                w = None
            if w is not None and w < 30:
                self.escalar("temp", f"TEMPERATURA CRÍTICA: CPU >= 96 °C há 60 min com a GPU em {w:.0f} W (calor só "
                                     f"da CI; o ci-termica não bastou)", 60)
        if persistiu(1800, lambda x: x.get("mem_disp_GB") is not None and x["mem_disp_GB"] < 3):
            self.escalar("memoria", "MEMÓRIA BAIXA: menos de 3 GB disponíveis há 30 min")
        if persistiu(1800, lambda x: (x.get("psi_mem") or 0) > 10):
            self.escalar("pressao_mem", "PRESSÃO DE MEMÓRIA: PSI de memória acima de 10% há 30 min")
        if persistiu(3600, lambda x: (x.get("psi_cpu") or 0) > 60) and not self.ha_ci():
            self.escalar("cpu", "CPU SATURADA: PSI de CPU acima de 60% há 60 min, sem CI rodando")

    def modo_auto(self):
        # Toda sessão do Claude Code em modo auto: escala uma vez por PID a que roda pulando
        # permissões, pela linha de comando ou pelo modo atual gravado na transcrição. Quem reinicia é o gerente.
        vivos = set()
        for arq in glob.glob(os.path.join(CFG["SESSOES"], "*.json")):
            try:
                s = json.load(open(arq))
                pid = int(s["pid"])
                cmd = open(os.path.join(CFG["PROC"], str(pid), "cmdline"), "rb").read().decode(errors="replace")
            except (OSError, ValueError, KeyError, TypeError):
                continue
            args = cmd.split("\0")
            if not args or os.path.basename(args[0]) != "claude":
                continue
            vivos.add(f"sem_auto_{pid}")
            modo = ""
            if "--dangerously-skip-permissions" in args:
                modo = "--dangerously-skip-permissions"
            for i, a in enumerate(args):
                if a == "--permission-mode" and i + 1 < len(args) and args[i + 1] == "bypassPermissions" \
                        or a == "--permission-mode=bypassPermissions":
                    modo = "--permission-mode bypassPermissions"
            sid = s.get("sessionId", "")
            for tr in glob.glob(os.path.join(CFG["PROJETOS"], "*", f"{sid}.jsonl"))[:1] if sid else []:
                try:
                    with open(tr, "rb") as f:
                        f.seek(max(0, os.path.getsize(tr) - 524288))
                        achados = re.findall(rb'"permissionMode":"(\w+)"', f.read())
                except OSError:
                    achados = []
                if achados and achados[-1] == b"bypassPermissions" and not modo:
                    modo = "bypassPermissions (trocado na sessão)"
            if modo:
                self.escalar(f"sem_auto_{pid}", f"SESSÃO SEM AUTO {s.get('name') or '?'}: PID {pid} em {modo} "
                             f"(sessão {sid or '?'}, tmux {s.get('tmux') or '-'}, cwd {s.get('cwd') or '?'}). "
                             f"{KC['KIT_GERENTE']}: reiniciar em auto e avisar {KC['KIT_DONO']}.", reaviso_min=720)
        for k in [k for k in self.e.get("escalado", {}) if k.startswith("sem_auto_") and k not in vivos]:
            self.limpar(k)

    def teto(self):
        a = amostras(1800)
        if not a:
            return
        carga = max((x.get("carga1") or 0) for x in a)
        teto = int(K.num("KIT_TETO_AGENTES_CARGA")) if carga > K.num("KIT_CARGA_ALTA") else int(K.num("KIT_TETO_AGENTES"))
        caminho = os.path.join(CFG["DIR"], "teto-maquina")
        try:
            atual = open(caminho).read().split()[0]
        except (OSError, IndexError):
            atual = ""
        if atual != str(teto):
            os.makedirs(CFG["DIR"], exist_ok=True)
            with open(caminho + ".tmp", "w") as f:
                f.write(f"{teto} agentes no total (carga máxima de 1 min nos últimos 30 min: {carga:.1f}; "
                        f"{KC['KIT_TETO_AGENTES_CARGA']} se passar de {KC['KIT_CARGA_ALTA']}) · {iso()}\n")
            os.replace(caminho + ".tmp", caminho)
            anexar(LOG, f"{iso()} teto da máquina: {atual or '-'} -> {teto} (carga máx. {carga:.1f})")

    def volta(self):
        for nome in ("coletor", "ci_termica", "ventoinhas", "disco", "amostrais", "teto", "modo_auto"):
            try:
                getattr(self, nome)()
            except Exception as ex:  # uma verificação quebrada não derruba as outras
                anexar(LOG, f"{iso()} ERRO em {nome}: {type(ex).__name__}: {ex}")
        self.gravar()


def autoteste():
    import shutil, tempfile
    T = tempfile.mkdtemp(prefix="autoteste-saude-", dir=(os.makedirs(CFG["DIR"], exist_ok=True) or CFG["DIR"]))
    falhas = []
    try:
        hw = os.path.join(T, "hwmon", "hwmonB")
        os.makedirs(hw)
        open(os.path.join(hw, "name"), "w").write("fan_wmi\n")
        bin_ = os.path.join(T, "bin")
        os.makedirs(bin_)

        def script(nome, corpo):
            p = os.path.join(bin_, nome)
            open(p, "w").write("#!/bin/bash\n" + corpo + "\n")
            os.chmod(p, 0o755)
            return p
        # Os comandos falsos registram as chamadas; o disco "libera" o que o arquivo ganho manda.
        reg = os.path.join(T, "chamadas")
        disco = os.path.join(T, "disco")
        script("docker", f'echo "docker $*" >> {reg}; g=$(cat {T}/ganho 2>/dev/null || echo 0); '
                         f'echo $(( $(cat {disco}) + g )) > {disco}')
        script("uv", f'echo "uv $*" >> {reg}')
        script("systemctl", f'echo "systemctl $*" >> {reg}; [ "$2" = is-active ] && cat {T}/ci_termica; true')
        script("garantir", f'echo garantir >> {reg}')
        script("ci", f'cat {T}/ci')
        script("gpu", f'cat {T}/gpu')
        log = os.path.join(T, "saude.log")

        def linhas_log(n, **v):
            base = dict(zip(CABECALHO[1:], "1 1 20 4 0 0 0 2 0 70 70 1500 60 0 0 0 0 0 0".split()))
            base.update({k: str(x) for k, x in v.items()})
            with open(log, "w") as f:
                f.write(" ".join(CABECALHO) + "\n")
                for i in range(n, -1, -1):
                    ts = time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(time.time() - i * 30))
                    f.write(ts + " " + " ".join(base[k] for k in CABECALHO[1:]) + "\n")

        def prepara(disco_gb=100, ci="", ci_termica="active", gpu="100", ganho=0, fans=(255, 255), **log_v):
            for nome, v in (("disco", disco_gb), ("ci", ci), ("ci_termica", ci_termica), ("gpu", gpu),
                            ("ganho", ganho)):
                open(os.path.join(T, nome), "w").write(f"{v}\n")
            for i, v in enumerate(fans, 1):
                p = os.path.join(hw, f"fan{i}_boost")
                if os.path.exists(p):
                    os.chmod(p, 0o644)
                open(p, "w").write(f"{v}\n")
            linhas_log(130, **log_v)
            for f in (reg, os.path.join(T, "estado", "saude-escalados.log")):
                if os.path.exists(f):
                    os.remove(f)

        env = {**ENV, "SAUDE_AUTO_DIR": os.path.join(T, "estado"), "SAUDE_AUTO_LOG": log,
               "SAUDE_AUTO_MUDANCAS": os.path.join(T, "mudancas.log"), "SAUDE_AUTO_FAN": os.path.join(T, "hwmon", "hwmon*", "fan*_boost"), "SAUDE_AUTO_WSL": "0", "KIT_CONF": os.path.join(T, "sem.conf"),
               "SAUDE_AUTO_DISCO_CMD": f"cat {disco}", "SAUDE_AUTO_DOCKER": f"{bin_}/docker",
               "SAUDE_AUTO_UV": f"{bin_}/uv", "SAUDE_AUTO_SYSTEMCTL": f"{bin_}/systemctl --user",
               "SAUDE_AUTO_GARANTIR": f"{bin_}/garantir", "SAUDE_AUTO_CI_CMD": f"{bin_}/ci",
               "SAUDE_AUTO_GPU_W_CMD": f"{bin_}/gpu", "SAUDE_AUTO_SESSOES": os.path.join(T, "sessoes"),
               "SAUDE_AUTO_PROJETOS": os.path.join(T, "projetos"), "SAUDE_AUTO_PROC": os.path.join(T, "proc")}

        def volta(novo_estado=True):
            if novo_estado:
                shutil.rmtree(os.path.join(T, "estado"), ignore_errors=True)
            subprocess.run([sys.executable, "-I", os.path.abspath(__file__), "--uma-vez"], env=env, check=True)

        def ler(nome):
            p = os.path.join(T, "estado", "saude-escalados.log") if nome == "esc" else reg
            return open(p).read() if os.path.exists(p) else ""

        def confere(nome, cond, det=""):
            if not cond:
                falhas.append(f"{nome}{': ' + det if det else ''}")

        prepara()
        volta()
        confere("tudo normal: nada", ler("esc") == "" and "prune" not in ler("reg"), ler("esc") + ler("reg"))
        confere("teto 5 com carga baixa", open(os.path.join(T, "estado", "teto-maquina")).read().startswith("5 "))
        prepara(carga1=30)
        volta()
        confere("teto 3 com carga 30", open(os.path.join(T, "estado", "teto-maquina")).read().startswith("3 "))
        prepara(disco_gb=45, ganho=10)
        volta()
        confere("disco 45: só prune 6h", "until=6h" in ler("reg") and "until=2h" not in ler("reg")
                and ler("esc") == "", ler("reg"))
        prepara(disco_gb=10)
        volta()
        r = ler("reg")
        confere("disco 10: cascata inteira", all(x in r for x in ("until=6h", "until=2h", "until=1h", "uv cache prune")), r)
        confere("disco 10: escala", "DISCO CRÍTICO" in ler("esc"), ler("esc"))
        open(reg, "w").close()
        volta(novo_estado=False)
        confere("disco: sem repetir em 30 min", "prune" not in ler("reg") and ler("esc").count("DISCO") == 1)
        prepara(ci="123", fans=(0, 0))
        volta()
        confere("ventoinhas: espera 90 s de CI", open(os.path.join(hw, "fan1_boost")).read().strip() == "0")
        e = json.load(open(os.path.join(T, "estado", "saude-auto-estado.json")))
        e["ci_desde"] = time.time() - 120
        json.dump(e, open(os.path.join(T, "estado", "saude-auto-estado.json"), "w"))
        volta(novo_estado=False)
        confere("ventoinhas: repõe 255", all(open(os.path.join(hw, f"fan{i}_boost")).read().strip() == "255"
                                            for i in (1, 2)) and ler("esc") == "", ler("esc"))
        for i in range(2):
            open(os.path.join(hw, "fan1_boost"), "w").write("0\n")
            volta(novo_estado=False)
        confere("ventoinhas zeradas 3x: escala", "VENTOINHAS ZERADAS" in ler("esc"), ler("esc"))
        prepara(ci="123", fans=(0, 255))
        os.chmod(os.path.join(hw, "fan1_boost"), 0o444)
        e = {"ci_desde": time.time() - 120}
        os.makedirs(os.path.join(T, "estado"), exist_ok=True)
        json.dump(e, open(os.path.join(T, "estado", "saude-auto-estado.json"), "w"))
        volta(novo_estado=False)
        if os.geteuid() != 0:
            confere("ventoinhas: escrita falha -> escala", "VENTOINHAS: durante" in ler("esc"), ler("esc"))
        prepara(ci_termica="inactive")
        volta()
        confere("ci-termica: restart", "restart ci-termica" in ler("reg") and ler("esc") == "", ler("reg"))
        volta(novo_estado=False)
        confere("ci-termica: escala se não voltar", "CI-TÉRMICA FORA" in ler("esc"), ler("esc"))
        prepara(conteineres="-")
        volta()
        confere("docker fora: escala", "DOCKER FORA" in ler("esc"), ler("esc"))
        prepara(cpu_pacote_C=97, gpu="10")
        volta()
        confere("temp crítica 60 min, GPU 10 W: escala", "TEMPERATURA CRÍTICA" in ler("esc"), ler("esc"))
        prepara(cpu_pacote_C=97, gpu="110")
        volta()
        confere("temp crítica com GPU 110 W: não escala", ler("esc") == "", ler("esc"))
        prepara(mem_disp_GB=2)
        volta()
        confere("memória baixa 30 min: escala", "MEMÓRIA BAIXA" in ler("esc"), ler("esc"))
        prepara(psi_cpu=80, ci="123")
        volta()
        confere("CPU saturada com CI: não escala", "CPU SATURADA" not in ler("esc"), ler("esc"))
        prepara()
        os.utime(log, (time.time() - 600, time.time() - 600))
        volta()
        confere("coletor parado: chama garantir", "garantir" in ler("reg") and ler("esc") == "", ler("reg"))
        volta(novo_estado=False)
        volta(novo_estado=False)
        confere("coletor parado 3x: escala", "COLETOR PARADO" in ler("esc"), ler("esc"))

        def sessao(pid, args, modo_tr="auto", nome="X"):
            for d in ("sessoes", f"proc/{pid}", "projetos/-p"):
                os.makedirs(os.path.join(T, d), exist_ok=True)
            json.dump({"pid": pid, "sessionId": f"s{pid}", "name": nome, "cwd": "/p"},
                      open(os.path.join(T, "sessoes", f"{pid}.json"), "w"))
            open(os.path.join(T, "proc", str(pid), "cmdline"), "w").write("\0".join(args) + "\0")
            open(os.path.join(T, "projetos", "-p", f"s{pid}.jsonl"), "w").write(
                '{"permissionMode":"bypassPermissions"}\n{"permissionMode":"%s"}\n' % modo_tr)
        prepara()
        sessao(11, ["claude", "--permission-mode", "auto", "--name", "A"])
        sessao(12, ["/usr/bin/python3", "--dangerously-skip-permissions"])
        volta()
        confere("sessões em auto (e não-claude): nada", ler("esc") == "", ler("esc"))
        sessao(13, ["claude", "--dangerously-skip-permissions", "--name", "PROJ"], nome="PROJ")
        volta()
        confere("bypass na linha de comando: escala", "SESSÃO SEM AUTO PROJ: PID 13" in ler("esc"), ler("esc"))
        volta(novo_estado=False)
        confere("bypass: escala uma vez só", ler("esc").count("SEM AUTO") == 1, ler("esc"))
        prepara()
        shutil.rmtree(os.path.join(T, "sessoes"))
        sessao(14, ["claude", "--permission-mode", "bypassPermissions"])
        sessao(15, ["claude", "--permission-mode", "auto"], modo_tr="bypassPermissions")
        volta()
        confere("bypassPermissions e troca na sessão: escala os dois",
                "PID 14" in ler("esc") and "PID 15 em bypassPermissions (trocado" in ler("esc"), ler("esc"))
        shutil.rmtree(os.path.join(T, "sessoes"))
    finally:
        shutil.rmtree(T, ignore_errors=True)
    print("autoteste: " + ("OK" if not falhas else "FALHOU"))
    for f in falhas:
        print("  - " + f)
    sys.exit(1 if falhas else 0)


def main():
    if "--autoteste" in sys.argv:
        autoteste()
    if "--uma-vez" in sys.argv:
        Zelo().volta()
        return
    os.makedirs(CFG["DIR"], exist_ok=True)
    trava = open(os.path.join(CFG["DIR"], "saude-auto.lock"), "w")
    try:
        fcntl.flock(trava, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        print("outra instância do saude-auto já roda", file=sys.stderr)
        sys.exit(1)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    anexar(LOG, f"{iso()} serviço iniciado (intervalo {int(CFG['INTERVALO'])} s; limpeza "
                f"{'ligada' if CFG['PRUNE'] else 'desligada'})")
    while True:
        Zelo().volta()
        time.sleep(CFG["INTERVALO"])


if __name__ == "__main__":
    main()
