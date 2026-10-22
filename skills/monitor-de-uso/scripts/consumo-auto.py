#!/usr/bin/env python3
"""Consumo central (serviço do usuário `consumo-auto`). Código de REFERÊNCIA: o gerente adapta ao que a máquina tem.

Uma fonte só de informação de uso para os projetos (KIT_PROJETOS), mantida pela automação; o zelador só recebe o
excepcional. A cada CONSUMO_INTERVALO s (padrão 60):
  1. CONTA: lê o estado do monitor da conta (monitor-uso.py: janela de 5 h, semana, previsão, limite) e o balanço.
  2. CONSUMO POR PROJETO: soma, de forma incremental, o custo aproximado das mensagens das transcrições
     (~/.claude/projects/<pasta>/*.jsonl e os subagentes) desde o início da semana da conta, por projeto, gerente e
     outros. Custo aproximado = tokens x peso do tipo (entrada 1, escrita de cache 1,25 ou 2, leitura de cache 0,1,
     saída 5) x peso do modelo (capaz 5, intermediário 3, econômico 1). Serve para repartir o uso, não é o número oficial.
  3. AGENTES RODANDO: subagentes sem `finished` no .meta.json com a transcrição escrita há menos de 10 min, ou
     (mesmo com `finished`, nas últimas 3 h) com uma tarefa em segundo plano ainda viva. Vigias (esperar-*.sh) não
     contam. SÓ agentes capazes (opus/fable) valem 1; sonnet, haiku e zelador valem 0. Grava o total em `agentes`.
  4. BASTÃO do modelo capaz, sempre pelo vez-opus.sh: solta sozinho quando o dono está sem agente capaz há 15 min
     (5 min se outro projeto espera, depois de 10 min de posse); renova por 30 min quando a previsão venceu e o
     agente capaz ainda trabalha. Com só uma sessão de projeto no ar, o bastão fica fixo nela (`vez-opus.sh unica`).
  5. ORIENTAÇÃO: grava `orientacao.json` e `orientacao.txt` (conta, modo, orçamento, rodando, livre, bastão, consumo
     por projeto). Cada projeto tem uma `chave`; `esperar-orientacao.sh <projeto>` acorda o orquestrador só quando
     a chave dele muda.
  6. ESCALA ao zelador (consumo-escalados.log): AGENTES (o orçamento mudou), monitor parado, consulta falhando há 1 h,
     meta atingida e o RELATÓRIO SEMANAL (relatorios/, quando a semana da conta renova).
Corte por previsão: previsão da semana acima de 110% reduz o orçamento; solta com 105% ou menos.
Modos: (sem argumento) serviço; `--uma-vez`; `--ver`.
"""
import calendar, datetime as dt, fcntl, glob, json, os, re, signal, subprocess, sys, tempfile, time
_L = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "gerente-da-maquina", "lib")
if not os.path.isdir(_L):
    _L = os.path.expanduser("~/.claude/skills/gerente-da-maquina/lib")
sys.path.insert(0, _L)
import kit_config as K
SESS = tuple(n for n, _, _ in K.projetos())
GERENTE = K.cfg["KIT_GERENTE"]
PROPORCAO = K.cfg["KIT_BASTAO_PROPORCAO"]

ENV = os.environ
H = os.path.expanduser
DIR = H(ENV.get("CONSUMO_DIR", K.cfg["KIT_CACHE"]))
PROJETOS = H(ENV.get("CONSUMO_PROJETOS", "~/.claude/projects"))
SESSOES = H(ENV.get("CONSUMO_SESSOES", "~/.claude/sessions"))
PROC = ENV.get("CONSUMO_PROC", "/proc")
GARANTIR = ENV.get("CONSUMO_GARANTIR", H("~/.claude/skills/monitor-de-uso/scripts/garantir-monitor.sh"))
INTERVALO = float(ENV.get("CONSUMO_INTERVALO", "60"))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import meta_semana


EXTRA = os.path.join(DIR, "orcamento-extra.json")


PREVISTA_CORTE, PREVISTA_SOLTA = 110.0, 105.0  # até 110% de previsão mantém os agentes (flutuação)


def corte_prevista(orc, semana, prevista, horas, ativo):
    """Com a previsão da semana (ritmo das últimas horas, balanco.py) acima de 110%, reduz o orçamento pela tabela da
    semana (esgota > 24 h antes da renovação: 1; antes: 2; até 24 h depois: 3); solta com 105% ou menos. -> (orc, ativo)"""
    if not orc or semana is None or prevista is None or not horas or horas <= 0:
        return orc, False
    ativo = prevista > PREVISTA_CORTE or (ativo and prevista > PREVISTA_SOLTA)
    if not ativo or prevista <= semana:
        return orc, ativo
    r = (prevista - semana) / horas  # %/h
    folga = (100 - semana) / r - horas
    lim = 1 if folga < -24 else 2 if folga < 0 else 3 if folga < 24 else orc
    return min(orc, lim), ativo


def orcamento_extra(agora):
    """Orçamento mínimo de agentes por janela (por exemplo, 2 capazes para uma auditoria junto com o trabalho). orcamento-extra.json: {"janelas": [{"min": 2, "de": <época>, "ate": <época>, "por": "..."},
    {"min": 2, "semanal": {"dia": 5, "de": "17:00", "ate": "23:00"}, "por": "..."}]} (dia: 0 = segunda ... 5 = sábado).
    Devolve (mínimo, motivo) da janela ativa de maior mínimo, ou (0, "")."""
    try:
        js = json.load(open(EXTRA)).get("janelas", [])
    except (OSError, ValueError, AttributeError):
        return 0, ""
    lt = time.localtime(agora)
    melhor = (0, "")
    for j in js:
        try:
            if "semanal" in j:
                w = j["semanal"]
                hm_ = f"{lt.tm_hour:02d}:{lt.tm_min:02d}"
                ativa = lt.tm_wday == int(w["dia"]) and w["de"] <= hm_ < w["ate"]
                fim = w["ate"]
            else:
                ativa = float(j.get("de", 0)) <= agora < float(j["ate"])
                fim = time.strftime("%d/%m %H:%M", time.localtime(float(j["ate"])))
            if ativa and float(j["min"]) > melhor[0]:
                melhor = (float(j["min"]), f"{j.get('por', 'extra')} (até {fim})")
        except (KeyError, ValueError, TypeError):
            continue
    return melhor


def meta_atual():
    return float(ENV["CONSUMO_META"]) if ENV.get("CONSUMO_META") else meta_semana.atual()
ATIVO_S = float(ENV.get("CONSUMO_ATIVO_S", "600"))           # transcrição escrita há menos disso = agente vivo
FUNDO_S = float(ENV.get("CONSUMO_FUNDO_S", "10800"))         # agente esperando tarefa em segundo plano: até 3 h
VIGIA_RE = re.compile(r"esperar-[A-Za-z0-9_.-]+\.sh|python3 -I - (" + "|".join(map(re.escape, SESS or ("-",))) + r")\b")  # esperas sem trabalho
SOLTA_S = float(ENV.get("CONSUMO_SOLTA_S", "900"))           # dono sem agente capaz há isso = solta
SOLTA_ESPERA_S = float(ENV.get("CONSUMO_SOLTA_ESPERA_S", "300"))  # o mesmo, com a outra sessão na fila
POSSE_MIN_S = float(ENV.get("CONSUMO_POSSE_MIN_S", "600"))   # carência depois de pegar
RENOVA_S = float(ENV.get("CONSUMO_RENOVA_S", "1800"))
TETO_S = float(ENV.get("CONSUMO_TETO_S", "5400"))            # a outra sessão espera há 90 min
ESTADO = os.path.join(DIR, "consumo-auto-estado.json")
LOG = os.path.join(DIR, "consumo-auto.log")
ESCALADOS = os.path.join(DIR, "consumo-escalados.log")
VEZ = os.path.join(DIR, "vez-opus.json")
VEZ_LOCK = os.path.join(DIR, "vez-opus.lock")
VEZ_LOG = os.path.join(DIR, "vez-opus.log")
PESO_TIPO = {"input_tokens": 1.0, "cache_read_input_tokens": 0.1, "output_tokens": 5.0}
PESO_CACHE = {"ephemeral_5m_input_tokens": 1.25, "ephemeral_1h_input_tokens": 2.0}


def iso(t=None):
    return time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(t))


def hm(t):
    return time.strftime("%d/%m %H:%M", time.localtime(t)) if t else "-"


def anexar(caminho, linha):
    os.makedirs(os.path.dirname(caminho), exist_ok=True)
    with open(caminho, "a") as f:
        f.write(linha + "\n")


def gravar_json(caminho, dado):
    os.makedirs(os.path.dirname(caminho), exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=os.path.basename(caminho) + ".", dir=os.path.dirname(caminho))
    with os.fdopen(fd, "w") as f:
        json.dump(dado, f, ensure_ascii=False, indent=1)
    os.replace(tmp, caminho)


def ler_json(caminho, padrao):
    try:
        with open(caminho) as f:
            return json.load(f)
    except (OSError, ValueError):
        return padrao


def _codifica(caminho):
    return re.sub(r"[^A-Za-z0-9]", "-", caminho)


def projeto_da_pasta(nome):
    """Pasta de ~/.claude/projects (caminho com '-') ou caminho real -> projeto, 'gerente' ou 'outros'.
    Vale o prefixo mais longo (worktrees ficam sob a pasta do projeto)."""
    nome = _codifica(nome)
    melhor, tam = "outros", 0
    for n, d, _ in K.projetos():
        p = _codifica(os.path.realpath(d))
        if (nome == p or nome.startswith(p + "-")) and len(p) > tam:
            melhor, tam = n, len(p)
    if tam == 0 and nome == _codifica(os.path.realpath(K.cfg["KIT_GERENTE_DIR"])):
        return "gerente"
    return melhor


def peso_modelo(modelo):
    m = (modelo or "").lower()
    if "opus" in m or "fable" in m:
        return 5.0
    if "haiku" in m:
        return 1.0
    return 3.0


def custo(u, modelo):
    c = sum(float(u.get(k) or 0) * p for k, p in PESO_TIPO.items())
    cc = u.get("cache_creation") or {}
    if cc:
        c += sum(float(cc.get(k) or 0) * p for k, p in PESO_CACHE.items())
    else:
        c += float(u.get("cache_creation_input_tokens") or 0) * 1.25
    return c * peso_modelo(modelo) / 1e6


def ts_utc(s):
    try:
        return calendar.timegm(time.strptime(s[:19], "%Y-%m-%dT%H:%M:%S"))
    except (TypeError, ValueError):
        return None


class Consumo:
    def __init__(self):
        self.e = ler_json(ESTADO, {})
        self.agora = time.time()

    # ---------- 1. conta ----------
    def conta(self):
        est = ler_json(os.path.join(DIR, "estado.json"), {})
        p = est.get("previsao") or {}
        amostras = []
        try:
            with open(os.path.join(DIR, "amostras.jsonl"), "rb") as f:
                f.seek(0, 2)
                f.seek(max(0, f.tell() - 4000))
                amostras = [json.loads(l) for l in f.read().decode("utf-8", "replace").splitlines()[1:] if l.strip()]
        except (OSError, ValueError):
            pass
        reset_semana = next((a.get("reset_semana") for a in reversed(amostras) if a.get("reset_semana")), None)
        bal = {}
        try:
            sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
            import balanco
            balanco.DIR = __import__("pathlib").Path(DIR)
            bal = balanco.balanco(meta_atual())
        except Exception:
            bal = {}
        return est, p, reset_semana, bal

    # ---------- 2. consumo por projeto ----------
    def contabilizar(self, inicio):
        if self.e.get("semana_inicio") != inicio:
            self.e["semana_inicio"] = inicio
            self.e["arquivos"] = {}
            self.e["baldes"] = {}
        arqs, baldes = self.e.setdefault("arquivos", {}), self.e.setdefault("baldes", {})
        caminhos = glob.glob(os.path.join(PROJETOS, "*", "*.jsonl")) + \
            glob.glob(os.path.join(PROJETOS, "*", "*", "subagents", "*.jsonl"))
        for c in caminhos:
            try:
                st = os.stat(c)
            except OSError:
                continue
            if st.st_mtime < inicio:
                continue
            a = arqs.setdefault(c, {"off": 0, "id": ""})
            if st.st_size < a["off"]:
                a["off"], a["id"] = 0, ""
            if st.st_size == a["off"]:
                continue
            proj = projeto_da_pasta(os.path.relpath(c, PROJETOS).split(os.sep)[0])
            with open(c, "rb") as f:
                f.seek(a["off"])
                bloco = f.read()
            fim = bloco.rfind(b"\n")
            if fim < 0:
                continue
            a["off"] += fim + 1
            for l in bloco[:fim].split(b"\n"):
                if b'"usage"' not in l:
                    continue
                try:
                    d = json.loads(l)
                except ValueError:
                    continue
                m = d.get("message") or {}
                u = m.get("usage")
                t = ts_utc(d.get("timestamp"))
                if not u or t is None or t < inicio:
                    continue
                mid = m.get("id") or d.get("requestId") or ""
                if mid and mid == a["id"]:
                    continue  # a mesma resposta repetida em várias linhas (um bloco de conteúdo por linha)
                a["id"] = mid
                h = str(int(t // 3600 * 3600))
                b = baldes.setdefault(h, {})
                b[proj] = round(b.get(proj, 0.0) + custo(u, m.get("model")), 6)

    def parcelas(self, desde=0):
        tot = {}
        for h, b in self.e.get("baldes", {}).items():
            if int(h) + 3600 > desde:
                for k, v in b.items():
                    tot[k] = tot.get(k, 0.0) + v
        soma = sum(tot.values())
        return {k: round(100 * v / soma, 1) for k, v in sorted(tot.items(), key=lambda x: -x[1])} if soma else {}

    # ---------- 3. agentes rodando ----------
    def tarefas_vivas(self):
        """IDs das tarefas em segundo plano do Claude Code com processo vivo (fd aberto em .../tasks/<ID>.output),
        sem as que são vigias."""
        vivas = {}
        for nome in os.listdir("/proc"):
            if not nome.isdigit():
                continue
            d = f"/proc/{nome}/fd"
            try:
                if os.stat(f"/proc/{nome}").st_uid != os.getuid():
                    continue
                for fd in os.listdir(d):
                    alvo = os.readlink(f"{d}/{fd}")
                    m = re.search(r"/tasks/([A-Za-z0-9_-]+)\.output$", alvo)
                    if m:
                        cmd = open(f"/proc/{nome}/cmdline", "rb").read().replace(b"\0", b" ").decode("utf-8", "replace")
                        vivas.setdefault(m.group(1), []).append(cmd)
            except OSError:
                continue
        # vigia se QUALQUER processo que segura a saída é vigia (o sleep filho dele também a segura)
        return {k for k, cs in vivas.items() if not any(VIGIA_RE.search(c) for c in cs)}

    def agentes(self):
        rod = {s: {"capaz": 0, "economico": 0, "unidades": 0.0, "lista": []} for s in SESS + ("gerente", "outros")}
        vivas = None
        for meta in glob.glob(os.path.join(PROJETOS, "*", "*", "subagents", "*.meta.json")):
            j = meta[: -len(".meta.json")] + ".jsonl"
            try:
                idade = self.agora - os.stat(j).st_mtime
                if idade > max(ATIVO_S, FUNDO_S):
                    continue
                md = json.load(open(meta))
            except (OSError, ValueError):
                continue
            if md.get("finished") or idade > ATIVO_S:
                # Só vale se espera uma tarefa em segundo plano ainda viva.
                if vivas is None:
                    vivas = self.tarefas_vivas()
                if not vivas:
                    continue
                try:
                    ids = set(re.findall(rb"running in background with ID: ([A-Za-z0-9_-]+)", open(j, "rb").read()))
                except OSError:
                    continue
                if not {i.decode() for i in ids} & vivas:
                    continue
            modelo = md.get("model") or ""
            if not modelo:
                try:
                    with open(j, "rb") as f:
                        f.seek(0, 2)
                        f.seek(max(0, f.tell() - 65536))
                        achados = re.findall(rb'"model":"(claude-[a-z0-9.-]+)"', f.read())
                    modelo = achados[-1].decode() if achados else ""
                except OSError:
                    pass
            capaz = peso_modelo(modelo) >= 5
            r = rod[projeto_da_pasta(os.path.relpath(meta, PROJETOS).split(os.sep)[0])]
            r["capaz" if capaz else "economico"] += 1
            r["unidades"] += 1.0 if capaz else 0.0  # só os capazes contam: sonnet, haiku e zelador fora
            r["lista"].append(f"{md.get('description', '?')} ({modelo or '?'})")
        return rod

    # ---------- 4. bastão ----------
    def vez(self, *args):
        env = {**ENV, "VEZ_ESTADO": VEZ, "VEZ_LOCK": VEZ_LOCK, "VEZ_LOG": VEZ_LOG}
        r = subprocess.run(["bash", os.path.join(os.path.dirname(os.path.abspath(__file__)), "vez-opus.sh"), *args],
                           env=env, capture_output=True, text=True, timeout=30)
        anexar(LOG, f"{iso()} bastão: vez-opus.sh {' '.join(args)} -> {r.returncode}")

    def sessoes_ativas(self):
        """Projetos configurados com uma sessão interativa do Claude Code no ar."""
        ativas = set()
        for arq in glob.glob(os.path.join(SESSOES, "*.json")):
            try:
                s = ler_json(arq, {})
                cmd = open(os.path.join(PROC, str(int(s["pid"])), "cmdline"), "rb").read().split(b"\0")
            except (OSError, ValueError, KeyError, TypeError):
                continue
            if cmd and os.path.basename(cmd[0].decode(errors="replace")) == "claude":
                pr = projeto_da_pasta(s.get("cwd") or "")
                if pr in SESS:
                    ativas.add(pr)
        return ativas

    def bastao(self, rod):
        """Decide fora da trava e age pelo vez-opus.sh (o rodízio 2:1 e a fila ficam todos lá)."""
        v = ler_json(VEZ, {})
        ativas = self.sessoes_ativas()
        if len(ativas) == 1 and len(SESS) > 1:  # os outros desligados: sem passagem de bastão
            s = next(iter(ativas))
            d = v.get("dono") or {}
            if v.get("unica") != s or d.get("sessao") != s or v.get("fila") or d.get("previsao_fim", 0) < self.agora:
                self.vez("unica", s)
            self.e.pop("sem_capaz_desde", None)
            return ler_json(VEZ, {"dono": None, "fila": []})
        if len(ativas) >= 2 and v.get("unica"):
            self.vez("unica", "nenhuma")
            v = ler_json(VEZ, {})
        d, fila = v.get("dono"), v.get("fila") or []
        sem = self.e.setdefault("sem_capaz_desde", {})
        if not d:
            sem.clear()
            return ler_json(VEZ, {"dono": None, "fila": []})
        s = d["sessao"]
        if rod.get(s, {}).get("capaz", 0) > 0:
            sem.pop(s, None)
            if self.agora - d["previsao_fim"] >= 0:
                self.vez("renovar", s, f"{RENOVA_S / 60:g}")
        else:
            desde = sem.setdefault(s, self.agora)
            espera = any(x["sessao"] != s for x in fila)
            limite = SOLTA_ESPERA_S if espera else SOLTA_S  # "se não estiver usando, libera"
            if self.agora - desde >= limite and self.agora - d["desde"] >= POSSE_MIN_S:
                self.vez("soltar", s, f"automático: sem agente capaz há {int((self.agora - desde) // 60)} min")
                sem.pop(s, None)
        return ler_json(VEZ, {"dono": None, "fila": []})

    # ---------- 6. escalações ----------
    def escalar(self, chave, texto, reaviso_s=1800):
        ult = self.e.setdefault("escalado", {}).get(chave, 0)
        if self.agora - ult < reaviso_s:
            return
        self.e["escalado"][chave] = self.agora
        anexar(ESCALADOS, f"{iso()} {texto}")
        anexar(LOG, f"{iso()} escalado: {texto}")

    def vigiar_monitor(self, est):
        atual = ts_utc((est.get("atualizado") or "")[:19].replace(" ", "T"))
        # "atualizado" vem com fuso local; compara pela data do arquivo, que é o que importa
        try:
            idade = self.agora - os.stat(os.path.join(DIR, "estado.json")).st_mtime
        except OSError:
            idade = 1e9
        if idade <= 1800:
            self.e["monitor_falhas"] = 0
        else:
            n = self.e.get("monitor_falhas", 0) + 1
            self.e["monitor_falhas"] = n
            subprocess.run(["bash", GARANTIR], capture_output=True, timeout=60)
            anexar(LOG, f"{iso()} monitor da conta parado há {int(idade // 60)} min: garantir-monitor.sh")
            if n >= 3:
                self.escalar("monitor", f"MONITOR DE USO PARADO: o estado da conta não é atualizado há "
                                        f"{int(idade // 60)} min, mesmo depois de {n} tentativas do garantir-monitor.sh")
        del atual
        if est.get("falhando"):
            desde = self.e.setdefault("falha_desde", self.agora)
            if self.agora - desde >= 3600:
                self.escalar("consulta", f"CONSULTA DO USO FALHANDO há {int((self.agora - desde) // 60)} min: "
                                         f"{str(est.get('erro'))[:120]}")
        else:
            self.e.pop("falha_desde", None)

    def relatorio_semanal(self, inicio_novo):
        ant = self.e.get("semana_inicio")
        if not ant or ant == inicio_novo:
            return
        tot = self.parcelas()
        pct = self.e.get("ultima_semana_pct")
        os.makedirs(os.path.join(DIR, "relatorios"), exist_ok=True)
        caminho = os.path.join(DIR, "relatorios", f"semana-{time.strftime('%Y-%m-%d', time.localtime(ant))}.txt")
        linhas = [f"Relatório da semana da conta de {hm(ant)} a {hm(inicio_novo)}",
                  f"Uso da semana no fim: {pct if pct is not None else '?'}% (meta {meta_atual():g}%)",
                  "Consumo por projeto (custo aproximado das transcrições): " +
                  (", ".join(f"{k} {v:g}%" for k, v in tot.items()) or "sem dados")]
        with open(caminho, "w") as f:
            f.write("\n".join(linhas) + "\n")
        self.escalar("relatorio", f"RELATÓRIO SEMANAL: {caminho} · uso {pct}% · " +
                     ", ".join(f"{k} {v:g}%" for k, v in tot.items()), 0)

    # ---------- volta ----------
    def volta(self):
        est, p, reset_semana, bal = self.conta()
        # A renovação informada pela conta oscila em 1 s entre consultas (17:00:00 e 16:59:59): arredonda para a hora
        # cheia e mantém o início guardado quando a diferença é menor que 1 h.
        inicio = int(round(reset_semana / 3600) * 3600 - 7 * 86400) if reset_semana else int(self.agora - 7 * 86400)
        guardado = self.e.get("semana_inicio")
        if guardado and abs(inicio - guardado) < 3600:
            inicio = guardado
        try:
            self.relatorio_semanal(inicio)
        except Exception as ex:
            anexar(LOG, f"{iso()} ERRO no relatório: {type(ex).__name__}: {ex}")
        try:
            self.contabilizar(inicio)
        except Exception as ex:
            anexar(LOG, f"{iso()} ERRO na contabilidade: {type(ex).__name__}: {ex}")
        rod = self.agentes()
        total_u = sum(r["unidades"] for r in rod.values())
        try:
            with open(os.path.join(DIR, "agentes"), "w") as f:
                f.write(f"{total_u:g}\n")
        except OSError:
            pass
        try:
            v = self.bastao(rod)
        except Exception as ex:
            anexar(LOG, f"{iso()} ERRO no bastão: {type(ex).__name__}: {ex}")
            v = ler_json(VEZ, {"dono": None, "fila": []})
        try:
            self.vigiar_monitor(est)
        except Exception as ex:
            anexar(LOG, f"{iso()} ERRO na vigia do monitor: {type(ex).__name__}: {ex}")
        semana = p.get("semana_pct")
        if semana is not None:
            self.e["ultima_semana_pct"] = semana
            if semana >= meta_atual():
                self.escalar(f"meta-{inicio}", f"META DA SEMANA ATINGIDA: {semana:g}% (meta {meta_atual():g}%); orçamento de "
                                               f"agentes zerado até a renovação ({p.get('semana_reset')})", 10 ** 9)
        self.orientar(est, p, bal, rod, total_u, v)
        self.e["batida"] = time.time()
        gravar_json(ESTADO, self.e)

    def orientar(self, est, p, bal, rod, total_u, v):
        faixa = est.get("faixa_prevista") or "?"
        modo = {"acima": "só o caminho crítico", "abaixo": "pode intensificar", "meta": "ritmo normal"}.get(faixa, "ritmo normal")
        semana = p.get("semana_pct")
        orc = 0 if (semana is not None and semana >= meta_atual()) else p.get("limite_codificadores")
        orc = 0 if orc is None else orc
        try:
            horas = (dt.datetime.fromisoformat(p.get("semana_reset") or "").timestamp() - self.agora) / 3600
        except (TypeError, ValueError):
            horas = None
        antes = orc
        orc, self.e["corte_prevista"] = corte_prevista(orc, semana, bal.get("prevista_pct"), horas,
                                                       self.e.get("corte_prevista", False))
        por_prevista = f"reduzido de {antes:g} pela previsão de {bal.get('prevista_pct'):g}% (> {PREVISTA_CORTE:g}%)" if orc < antes else ""
        extra, por_extra = orcamento_extra(self.agora)
        if orc and extra > orc:  # com a meta atingida (orc 0), o extra não vale
            orc = extra
        else:
            por_extra = ""
        livre = max(0.0, orc - total_u)
        d, fila = v.get("dono"), v.get("fila") or []
        espera = {x["sessao"]: self.agora - x["desde"] for x in fila}
        chaves = {}
        for s in SESS:
            if not d:
                vez = "livre"
            elif d["sessao"] == s:
                outro = [t for k, t in espera.items() if k != s]
                vez = "dono-teto" if outro and max(outro) >= TETO_S else "dono"
            else:
                vez = "fila" if s in espera else "outro"
            chaves[s] = {"modo": faixa, "orcamento": orc, "vaga": "sim" if livre >= 1 else "não", "vez": vez}
        par_sem, par_6h = self.parcelas(), self.parcelas(self.agora - 6 * 3600)
        bast = "livre" if not d else (f"{d['sessao']} desde {hm(d['desde'])} ({d['tarefa']}), previsão "
                                      f"{hm(d['previsao_fim'])}")
        if d and v.get("unica") == d["sessao"]:
            bast = f"{d['sessao']} fixo, única sessão de projeto no ar (sem passagem de bastão nem fila)"
        if fila:
            bast += "; fila: " + ", ".join(f"{x['sessao']} há {int((self.agora - x['desde']) // 60)} min ({x['tarefa']})"
                                           for x in fila)
        txt = [f"ORIENTAÇÃO DE USO (fonte única: consumo-auto, {GERENTE}) · {hm(self.agora)}",
               f"Conta: janela de 5 h {p.get('uso_pct', '?')}% (renova {p.get('reset', '?')}) · semana "
               f"{semana if semana is not None else '?'}% (renova {p.get('semana_reset', '?')}), prevista "
               f"{bal.get('prevista_pct', '?')}% para a meta de {meta_atual():g}% → {modo}.",
               f"Orçamento de agentes da conta (os dois projetos juntos): {orc:g} agente(s) capaz(es) (opus ou fable; sonnet, haiku e o zelador não contam)"
               + (f", com extra: {por_extra}" if por_extra else "") + (f", {por_prevista}" if por_prevista else "") + ". "
               "Rodando: " + ", ".join(f"{s} {rod[s]['unidades']:g}" for s in SESS)
               + (f", outros {rod['gerente']['unidades'] + rod['outros']['unidades']:g}"
                  if rod['gerente']['unidades'] + rod['outros']['unidades'] else "")
               + f". Livre: {livre:g}.",
               f"Bastão do modelo capaz: {bast}." + ("" if v.get("unica") else
               f" Rodízio: {SESS[0] if SESS else ''} (prioritário) tem {PROPORCAO} rodada(s) para 1 de cada outro "
               f"(com {v.get('seguidas_prio', 0)} seguida(s)); quem não pediu a próxima rodada não segura o bastão. "
               f"O consumo-auto solta sozinho quando o dono fica sem agente capaz (5 min com fila, 15 sem) e renova "
               f"enquanto o agente trabalha."),
               "Consumo da semana por projeto (aproximado): " + (", ".join(f"{k} {x:g}%" for k, x in par_sem.items())
                                                                 or "medindo") +
               " · últimas 6 h: " + (", ".join(f"{k} {x:g}%" for k, x in par_6h.items()) or "sem uso")]
        dado = {"atualizado": iso(), "ts": self.agora, "modo": modo, "faixa": faixa, "orcamento": orc,
                "rodando": {k: {kk: vv for kk, vv in r.items()} for k, r in rod.items()}, "livre": livre,
                "bastao": v, "parcelas_semana": par_sem, "parcelas_6h": par_6h, "conta": p,
                "balanco": bal, "chave": chaves, "texto": "\n".join(txt)}
        gravar_json(os.path.join(DIR, "orientacao.json"), dado)
        # Orçamento de agentes mudou (para cima ou para baixo) -> o zelador passa o número aos orquestradores.
        ant = self.e.get("orc_ant")
        if ant is not None and orc != ant:
            self.escalar(f"agentes-{int(self.agora)}", f"AGENTES: orçamento da conta {ant:g} -> {orc:g} unidade(s) "
                         f"(só agentes capazes, opus ou fable; os dois projetos juntos)" + (f", com extra: {por_extra}" if por_extra else "")
                         + ". Rodando: " + ", ".join(f"{s} {rod[s]['unidades']:g}" for s in SESS) + ".", 0)
        self.e["orc_ant"] = orc
        with open(os.path.join(DIR, "orientacao.txt.tmp"), "w") as f:
            f.write("\n".join(txt) + "\n")
        os.replace(os.path.join(DIR, "orientacao.txt.tmp"), os.path.join(DIR, "orientacao.txt"))


def autoteste():
    print("autoteste: não incluído nesta versão de referência; prove com --uma-vez numa pasta de teste (CONSUMO_DIR, CONSUMO_PROJETOS)")
    sys.exit(0)


def main():
    if "--autoteste" in sys.argv:
        autoteste()
    if "--ver" in sys.argv:
        print(ler_json(os.path.join(DIR, "orientacao.json"), {}).get("texto", "sem orientação ainda"))
        return
    if "--uma-vez" in sys.argv:
        Consumo().volta()
        return
    os.makedirs(DIR, exist_ok=True)
    trava = open(os.path.join(DIR, "consumo-auto.lock"), "w")
    try:
        fcntl.flock(trava, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        print("outra instância do consumo-auto já roda", file=sys.stderr)
        sys.exit(1)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    anexar(LOG, f"{iso()} serviço iniciado (intervalo {int(INTERVALO)} s)")
    while True:
        try:
            Consumo().volta()
        except Exception as ex:
            anexar(LOG, f"{iso()} ERRO na volta: {type(ex).__name__}: {ex}")
        time.sleep(INTERVALO)


if __name__ == "__main__":
    main()
