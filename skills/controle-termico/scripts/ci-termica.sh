#!/usr/bin/env bash
# Perfil térmico AUTÔNOMO da CI local. Roda como serviço systemd do usuário (ci-termica.service), sem privilégios.
#
# Detecção: há CI quando existe algum processo cujo nome (/proc/*/comm) casa com KIT_CI_PADRAO (padrão
# Runner.Worker: o executor do GitHub Actions cria um por job), de QUALQUER usuário. Amostra a cada INTERVALO (15 s).
#   - entra no perfil da CI assim que aparece 1 job;
#   - sai só depois de SAIDA (3 min) seguidos sem nenhum job (os jobs de um workflow vêm um atrás do outro).
# Perfil da CI, nesta ordem: powerprofilesctl performance; intel_pstate no_turbo=0 (turbo ligado) e max_perf_pct=
# KIT_TERM_TETO_INICIAL (60); 255 em cada arquivo de ventoinha de KIT_FAN_BOOST (vazio = não mexe). O "aplicado" é o
# valor lido de volta depois de gravar.
# Teto dinâmico: no modo CI, a cada TETO_JANELA (60 s) tira a média da temperatura do pacote da CPU (coretemp ou
# k10temp) nas amostras do último minuto; com média acima de KIT_TERM_DESCE_C (80 °C), baixa o max_perf_pct em
# TETO_PASSO (10) pontos, até o piso TETO_PISO (50). No piso e ainda acima do limite, desce um degrau de perfil e
# recomeça o teto em 100: performance -> balanced -> power-saver; no piso do power-saver, fica e avisa. Teto e perfil
# mudados assim contam como "aplicado" (não são mudança à mão) e a saída da CI repõe os de antes.
# Teto ou perfil mudados à mão durante a CI: o ajuste para (o dono manda).
# Subida: com a MÁXIMA do minuto em até KIT_TERM_SOBE_C (70 °C) por TETO_SUBIDA janelas seguidas (3 = 3 min), o teto
# sobe TETO_PASSO até 100; já em 100 num perfil de baixo da cascata, volta ao perfil anterior com o teto no piso.
# Só sob carga: a janela só conta para a subida com o uso médio da CPU (/proc/stat) em pelo menos TETO_USO (50%);
# minuto frio com a CPU ociosa não conta nem zera. Queda rápida: média acima de KIT_TERM_CRITICO_C (90 °C) baixa o
# teto direto ao inicial da CI.
# Ventoinhas SEMPRE no máximo durante a CI, em qualquer perfil: a cada amostra, um arquivo de ventoinha abaixo do da
# CI volta a 255 (a troca de perfil do powerprofilesctl pode zerá-lo), inclusive se mudado à mão.
# Saída: repõe o estado de antes da CI, guardado na entrada. Item que alguém mudou à mão durante a CI (valor atual
# diferente do aplicado) NÃO é reposto: o dono manda.
# Início com a CI já rodando: item cujo valor atual já é o da CI usa o padrão de reserva como "antes"
# (balanced, no_turbo 0, max_perf_pct 100, ventoinha 0). Fora da CI o padrão é balanced, com turbo, 100 e ventoinha 0.
# Queda no meio da CI (SIGKILL, falha, boot): o estado salvo em $KIT_CACHE/ci-termica/estado.json é retomado na partida
# seguinte; se o boot mudou e há job, o perfil da CI é reaplicado (o boot zera ventoinha e pstate).
# SIGTERM e SIGINT no modo CI repõem o estado salvo antes de sair (serviço parado não prende a máquina).
# Perfil depois do boot: no boot o powerprofilesctl só responde depois do login gráfico. Boot novo fora da CI: assim
# que o perfil for legível, se não for o padrão (balanced), volta a ele, uma vez por boot.
# Calor sem CI: fora da CI, CALOR_N amostras seguidas acima de CALOR_C (80 °C) entram no mesmo perfil, com o mesmo
# teto dinâmico ("ENTROU no perfil térmico por calor"); testes locais pesados também esquentam a máquina. Sai depois
# de SAIDA (3 min) sem job e sem carga: nenhuma amostra acima de TETO_FOLGA (70 °C) e, com o teto abaixo de 100, a CPU
# abaixo de TETO_USO (50%); com carga e fria, o teto sobe até 100 e então sai (sem vaivém). Job que aparece no perfil
# por calor vira CI normal e sai pela regra da CI.
# Item ausente ou não gravável vira AVISO no log; o resto segue.
#
# WSL2 (Windows): não há intel_pstate nem hwmon do host. Detecta-se pelo /proc/version ("microsoft"). Sem
# KIT_TERM_WINDOWS=1 o serviço só registra as sessões da CI e não aplica nada (sem erro em laço). Com
# KIT_TERM_WINDOWS=1 limita a CPU pelo host com powercfg.exe (interop do WSL): PROCTHROTTLEMAX do esquema atual,
# corrente alternada (win_ac) e bateria (win_dc), seguido de "powercfg.exe /setactive SCHEME_CURRENT". Guarda e
# repõe o valor de antes como os demais itens. Sem leitura de temperatura no host, o teto fica FIXO em
# KIT_TERM_TETO_INICIAL durante a CI e é reposto na saída.
#
# Permissões (sem sudo, Linux nativo): no_turbo e max_perf_pct e os arquivos de ventoinha precisam ser graváveis
# pelo usuário (regra udev/tmpfiles de exemplo na SKILL.md do controle-termico); powerprofilesctl pelo polkit.
# Núcleo em Python (stdlib): o bash do Ubuntu 24.04 corrompe o analisador quando um trap roda no meio de um $(...), e
# o SIGTERM no meio da CI precisa repor sempre.
#
# Uso: ci-termica.sh              o laço (o serviço)
#      ci-termica.sh --estado     mostra o modo, o estado salvo, os valores atuais e os jobs (só lê)
#      ci-termica.sh --autoteste  cenários contra um sysfs falso (mktemp -d), sem tocar no sistema real
# Log de cada troca: $KIT_CACHE/ci-termica/ci-termica.log (também no journal do serviço) e uma linha por troca, com o
# comando de desfazer, em $KIT_REGISTRO. Configuração: KIT_TERM_ATIVA, KIT_CI_PADRAO, KIT_TERM_TETO_INICIAL,
# KIT_TERM_SOBE_C, KIT_TERM_DESCE_C, KIT_TERM_CRITICO_C, KIT_FAN_BOOST, KIT_TERM_WINDOWS (kit.conf).
# Variáveis (para provas, sem tocar no sistema real):
#   CI_TERMICA_DIR, CI_TERMICA_LOG, CI_TERMICA_MUDANCAS, CI_TERMICA_PSTATE (/sys/devices/system/cpu/intel_pstate),
#   CI_TERMICA_HWMON (/sys/class/hwmon), CI_TERMICA_FAN (glob das ventoinhas), CI_TERMICA_PPCTL (powerprofilesctl),
#   CI_TERMICA_POWERCFG (powercfg.exe), CI_TERMICA_WSL (0|1), CI_TERMICA_WINDOWS (0|1), CI_TERMICA_PADRAO,
#   CI_TERMICA_LISTAR_JOBS (comando bash que imprime um usuário por job; vazio = /proc),
#   CI_TERMICA_BOOT_ID (/proc/sys/kernel/random/boot_id), CI_TERMICA_INTERVALO_S (15),
#   CI_TERMICA_SAIDA_MIN (3) ou CI_TERMICA_SAIDA_S (segundos, tem precedência);
#   perfil da CI: CI_TERMICA_CI_PERFIL (performance), _CI_NO_TURBO (0), _CI_MAX_PERF (60), _CI_BOOST (255);
#   teto dinâmico: CI_TERMICA_TETO_FOLGA_C, _TETO_SUBIDA (3 janelas), CI_TERMICA_TETO_LIMITE_C, _TETO_PASSO (10),
#   _TETO_PISO (50), _TETO_JANELA_S (60), _TETO_USO_PCT (50), _TETO_QUEDA_C, CI_TERMICA_STAT (/proc/stat),
#   CI_TERMICA_USO_ARQ (só o autoteste: arquivo com o uso em %);
#   reserva: CI_TERMICA_RES_PERFIL (balanced), _RES_NO_TURBO (0), _RES_MAX_PERF (100), _RES_BOOST (0);
#   CI_TERMICA_TMP (pasta do autoteste), CI_TERMICA_MANTER=1 (não apaga a pasta do autoteste).
export CI_TERMICA_SELF; CI_TERMICA_SELF="$(readlink -f "$0")"
KITSH="$(dirname "$CI_TERMICA_SELF")/../../gerente-da-maquina/lib/kit.sh"
# shellcheck disable=SC1090
[ -f "$KITSH" ] && . "$KITSH"
exec python3 -I - "$@" <<'PY'
import datetime, fcntl, glob, json, os, pwd, random, re, shutil, signal, subprocess, sys, tempfile, time

E = os.environ
H = os.path.expanduser("~")
SELF = E["CI_TERMICA_SELF"]
KC = E.get("KIT_CACHE") or f"{H}/.cache/gerente-maquina"
DIR = E.get("CI_TERMICA_DIR") or f"{KC}/ci-termica"
EST = f"{DIR}/estado.json"
LOG = E.get("CI_TERMICA_LOG") or f"{DIR}/ci-termica.log"
MUD = E.get("CI_TERMICA_MUDANCAS") or E.get("KIT_REGISTRO") or f"{KC}/mudancas-sistema.log"
PSTATE = E.get("CI_TERMICA_PSTATE") or "/sys/devices/system/cpu/intel_pstate"
HWMON = E.get("CI_TERMICA_HWMON") or "/sys/class/hwmon"
FAN = E["CI_TERMICA_FAN"] if "CI_TERMICA_FAN" in E else E.get("KIT_FAN_BOOST", "")
POWERCFG = E.get("CI_TERMICA_POWERCFG") or "powercfg.exe"
PADRAO = E.get("CI_TERMICA_PADRAO") or E.get("KIT_CI_PADRAO") or "Runner.Worker"
def _wsl():
    if E.get("CI_TERMICA_WSL") in ("0", "1"): return E["CI_TERMICA_WSL"] == "1"
    try:
        with open("/proc/version") as f: return "microsoft" in f.read().lower()
    except OSError: return False
WSL = _wsl()
WIN = (E.get("CI_TERMICA_WINDOWS") or E.get("KIT_TERM_WINDOWS") or "0") == "1"
ATIVA = (E.get("KIT_TERM_ATIVA") or "1") != "0"
PPCTL = E.get("CI_TERMICA_PPCTL") or "powerprofilesctl"
LISTAR = E.get("CI_TERMICA_LISTAR_JOBS", "")
BOOT = E.get("CI_TERMICA_BOOT_ID") or "/proc/sys/kernel/random/boot_id"
INTERVALO = float(E.get("CI_TERMICA_INTERVALO_S") or 15)
SAIDA_S = float(E.get("CI_TERMICA_SAIDA_S") or float(E.get("CI_TERMICA_SAIDA_MIN") or 3) * 60)
CI_V = {"perfil": E.get("CI_TERMICA_CI_PERFIL") or "performance", "no_turbo": E.get("CI_TERMICA_CI_NO_TURBO") or "0",
        "max_perf_pct": E.get("CI_TERMICA_CI_MAX_PERF") or E.get("KIT_TERM_TETO_INICIAL") or "60", "boost": E.get("CI_TERMICA_CI_BOOST") or "255"}
TETO_LIMITE = float(E.get("CI_TERMICA_TETO_LIMITE_C") or E.get("KIT_TERM_DESCE_C") or 80)
TETO_PASSO = int(E.get("CI_TERMICA_TETO_PASSO") or 10)
TETO_PISO = int(E.get("CI_TERMICA_TETO_PISO") or 50)
TETO_JANELA = float(E.get("CI_TERMICA_TETO_JANELA_S") or 60)
TETO_FOLGA = float(E.get("CI_TERMICA_TETO_FOLGA_C") or E.get("KIT_TERM_SOBE_C") or 70)
TETO_SUBIDA = int(E.get("CI_TERMICA_TETO_SUBIDA") or 3)
TETO_USO = float(E.get("CI_TERMICA_TETO_USO_PCT") or 50)  # subir só com a CPU trabalhando
TETO_QUEDA = float(E.get("CI_TERMICA_TETO_QUEDA_C") or E.get("KIT_TERM_CRITICO_C") or 90)  # acima disso, volta direto ao teto inicial da CI
CALOR_C = float(E.get("CI_TERMICA_CALOR_C") or E.get("KIT_TERM_CALOR_C") or 80)  # fora da CI, acima disso entra no perfil
CALOR_N = int(E.get("CI_TERMICA_CALOR_N") or 2)  # amostras seguidas acima de CALOR_C para entrar
STAT = E.get("CI_TERMICA_STAT") or "/proc/stat"
USO_ARQ = E.get("CI_TERMICA_USO_ARQ", "")
CASCATA = ["performance", "balanced", "power-saver"]  # degraus de perfil quando o teto chega ao piso e segue quente
RES_V = {"perfil": E.get("CI_TERMICA_RES_PERFIL") or "balanced", "no_turbo": E.get("CI_TERMICA_RES_NO_TURBO") or "0",
         "max_perf_pct": E.get("CI_TERMICA_RES_MAX_PERF") or "100", "boost": E.get("CI_TERMICA_RES_BOOST") or "0"}
CI_V["win"] = CI_V["max_perf_pct"]; RES_V["win"] = RES_V["max_perf_pct"]  # PROCTHROTTLEMAX do Windows (WSL)

# ---------- itens: ler, gravar, comando equivalente ----------
def fan_arquivos():  # {item: caminho}; o item é "<name do hwmon>/<arquivo>", estável quando o número do hwmon muda
    r = {}
    if not FAN: return r
    for f in sorted(glob.glob(FAN)):
        d = os.path.dirname(f)
        try:
            with open(f"{d}/name") as h: nome = h.read().strip()
        except OSError: nome = os.path.basename(d)
        r[f"{nome}/{os.path.basename(f)}"] = f
    return r
def classe(i): return "boost" if "/" in i else ("win" if i.startswith("win_") else i)
def arquivo(i):
    if i in ("no_turbo", "max_perf_pct"): return f"{PSTATE}/{i}"
    return fan_arquivos().get(i)
def ppctl(*a):
    try: r = subprocess.run([PPCTL, *a], capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError): return None
    return r.stdout.strip() if r.returncode == 0 else None
def powercfg(*a):  # saída (texto) ou None; o powercfg.exe do Windows pelo interop do WSL
    try: r = subprocess.run([POWERCFG, *a], capture_output=True, text=True, errors="replace", timeout=30)
    except (OSError, subprocess.SubprocessError): return None
    return r.stdout if r.returncode == 0 else None
def win_ler(i):  # independe do idioma do Windows: os dois últimos 0x... da consulta são CA e CC, nessa ordem
    out = powercfg("/query", "SCHEME_CURRENT", "SUB_PROCESSOR", "PROCTHROTTLEMAX")
    vals = re.findall(r"0x[0-9a-fA-F]{8}", out or "")
    if len(vals) < 2: return None
    return str(int(vals[-2 if i == "win_ac" else -1], 16))
def win_gravar(i, v):
    op = "/setacvalueindex" if i == "win_ac" else "/setdcvalueindex"
    if powercfg(op, "SCHEME_CURRENT", "SUB_PROCESSOR", "PROCTHROTTLEMAX", str(v)) is None: return f"powercfg.exe {op} falhou"
    if powercfg("/setactive", "SCHEME_CURRENT") is None: return "powercfg.exe /setactive falhou"
    return None
def ler(i):
    if i in ("win_ac", "win_dc"): return win_ler(i)
    if i == "perfil": v = ppctl("get")
    else:
        f = arquivo(i)
        try:
            with open(f) as h: v = h.read().strip()
        except (OSError, TypeError): v = None
    return v or None
def gravar(i, v):  # None = gravou; senão, a mensagem de erro curta
    if i in ("win_ac", "win_dc"): return win_gravar(i, v)
    if i == "perfil": return None if ppctl("set", v) is not None else f"powerprofilesctl set {v} falhou"
    f = arquivo(i)
    if not f: return "ventoinha ausente"
    if not os.access(f, os.W_OK): return f"{f} não gravável"
    try:
        with open(f, "w") as h: h.write(f"{v}\n")
    except OSError as e: return f"gravar {v} em {f} falhou ({e.strerror})"
    return None
def comando(i, v):
    if i in ("win_ac", "win_dc"):
        op = "/setacvalueindex" if i == "win_ac" else "/setdcvalueindex"
        return f"powercfg.exe {op} SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMAX {v}; powercfg.exe /setactive SCHEME_CURRENT"
    if i == "perfil": return f"powerprofilesctl set {v}"
    return f"echo {v} > {arquivo(i) or '<ventoinha>/' + i}"
def temp_cpu():  # °C do pacote da CPU (coretemp "Package id 0"; senão o maior temp*_input do coretemp/k10temp)
    try: nomes = sorted(os.listdir(HWMON))
    except OSError: return None
    for n in nomes:
        d = f"{HWMON}/{n}"
        try:
            with open(f"{d}/name") as f: nome = f.read().strip()
        except OSError: continue
        if nome not in ("coretemp", "k10temp"): continue
        vals, pacote = [], None
        for t in sorted(os.listdir(d)):
            if not (t.startswith("temp") and t.endswith("_input")): continue
            try:
                with open(f"{d}/{t}") as f: v = int(f.read().strip()) / 1000
                try:
                    with open(f"{d}/{t[:-6]}_label") as f: rot = f.read().strip()
                except OSError: rot = ""
            except (OSError, ValueError): continue
            vals.append(v)
            if rot in ("Package id 0", "Tctl"): pacote = v
        if pacote is not None or vals: return pacote if pacote is not None else max(vals)
    return None
def itens_presentes():
    r = [] if WSL else ["perfil"]
    if os.path.isdir(PSTATE): r += ["no_turbo", "max_perf_pct"]
    r += sorted(fan_arquivos())
    if WIN: r += ["win_ac", "win_dc"]
    return r

# ---------- registro ----------
def agora_iso(): return datetime.datetime.now().astimezone().isoformat(timespec="seconds")
def anexar(arq, linha):
    os.makedirs(os.path.dirname(arq), exist_ok=True)
    with open(arq, "a") as f: f.write(f"{agora_iso()} {linha}\n")
def registrar(msg): anexar(LOG, msg); print(msg, flush=True)
def mudanca(msg): anexar(MUD, f"ci-termica: {msg}")
def descrever(d, itens): return " ".join(f"{i}={d[i]}" for i in itens if i in d) or "nada"

# ---------- estado ----------
def boot_id():
    try:
        with open(BOOT) as f: return f.read().strip()
    except OSError: return "-"
def novo_estado(): return {"modo": "normal", "desde": 0, "boot": boot_id(), "itens": [], "vistos": [], "antes": {}, "aplicado": {}}
def carregar():
    try:
        with open(EST) as f: e = json.load(f)
        return {**novo_estado(), **e}
    except FileNotFoundError: return None
    except (OSError, ValueError) as x:
        registrar(f"AVISO: estado salvo ilegível ({x}); começa do zero"); return None
def salvar(e):
    os.makedirs(DIR, exist_ok=True); e["boot"] = boot_id()
    fd, tmp = tempfile.mkstemp(prefix="estado.", dir=DIR)
    with os.fdopen(fd, "w") as f: json.dump(e, f, ensure_ascii=False, indent=1); f.flush(); os.fsync(f.fileno())
    os.replace(tmp, EST)

# ---------- jobs ----------
def listar_jobs():  # lista de usuários, um por job; None = não sei (nada muda nesta amostra)
    if LISTAR:
        try: r = subprocess.run(["bash", "-c", LISTAR], capture_output=True, text=True, timeout=10)
        except (OSError, subprocess.SubprocessError): return None
        return [l.strip() for l in r.stdout.splitlines() if l.strip()] if r.returncode == 0 else None
    try: pids = [p for p in os.listdir("/proc") if p.isdigit()]
    except OSError: return None
    r = []
    for p in pids:
        try:
            with open(f"/proc/{p}/comm") as f:
                if not re.search(PADRAO, f.read().strip()): continue
            uid = os.stat(f"/proc/{p}").st_uid
        except OSError: continue  # processo que acabou entre a lista e a leitura
        try: r.append(pwd.getpwuid(uid).pw_name)
        except KeyError: r.append(str(uid))
    return r
def resumo(jobs):
    c = {}
    for u in jobs: c[u] = c.get(u, 0) + 1
    return " ".join(f"{u}×{n}" for u, n in sorted(c.items())) or "nenhum"

# ---------- entrar e sair ----------
def aplicar_ci(e):  # grava o perfil da CI; tira dos itens o que não foi gravado
    ok = []
    for i in e["itens"]:
        err = gravar(i, CI_V[classe(i)])
        if err: registrar(f"AVISO: {i} não aplicado ({err}); segue com o resto"); e["antes"].pop(i, None)
        else: ok.append(i)
    e["itens"] = ok
    e["aplicado"] = {i: ler(i) or CI_V[classe(i)] for i in ok}  # lido de volta (kernel ou daemon podem ajustar)
    return "; ".join(comando(i, e["antes"][i]) for i in ok)
def entrar(e, jobs, inicio, calor=None):  # calor = °C que disparou a entrada sem job
    if FAN and not fan_arquivos(): registrar(f"AVISO: nenhuma ventoinha em KIT_FAN_BOOST ({FAN}); ventoinhas ficam como estão")
    if WSL and not WIN: registrar("WSL sem KIT_TERM_WINDOWS=1: sem intel_pstate nem hwmon, nada a aplicar (só o registro das sessões da CI)")
    itens, antes, reserva = [], {}, []
    for i in itens_presentes():
        v = ler(i)
        if v is None: registrar(f"AVISO: não consegui ler {i}; fica como está"); continue
        c = classe(i)
        if inicio and v == CI_V[c] and RES_V[c] != v: v = RES_V[c]; reserva.append(i)
        itens.append(i); antes[i] = v
    # Modo CI salvo ANTES de gravar: uma queda no meio da aplicação deixa o "antes" guardado; sem "aplicado",
    # a saída repõe o item sem a checagem de mudança à mão.
    e.update(modo="ci", desde=time.time(), itens=itens, antes=antes, aplicado={}, vistos=sorted(set(jobs)), piso_avisado=False, calor=calor is not None)
    salvar(e)
    desfazer = aplicar_ci(e); salvar(e)
    extra = f" · reserva (a CI já rodava no início) em: {' '.join(reserva)}" if reserva else ""
    oque = f"ENTROU no perfil térmico por calor ({calor:.0f} °C, sem job)" if calor is not None else f"ENTROU no perfil da CI · jobs: {resumo(jobs)}"
    registrar(f"{oque} · antes: {descrever(e['antes'], e['itens'])} · aplicado: {descrever(e['aplicado'], e['itens'])}{extra}")
    mudanca(f"{oque}: {descrever(e['aplicado'], e['itens'])}. Desfazer: o próprio serviço repõe quando a CI ou o calor "
            f"acabam (ou systemctl --user stop ci-termica); à mão: {desfazer or 'nada'}")
def manter_ventoinhas(e):  # a cada amostra no modo CI: boost abaixo do da CI volta ao da CI
    repostas = []
    for i in e["itens"]:
        if classe(i) != "boost": continue
        v = ler(i)
        if v is not None and v != CI_V["boost"]:
            err = gravar(i, CI_V["boost"])
            if err: registrar(f"AVISO: {i} em {v} e não voltou a {CI_V['boost']} ({err})"); continue
            e["aplicado"][i] = ler(i) or CI_V["boost"]; repostas.append(f"{i} {v}->{CI_V['boost']}")
    if repostas:
        salvar(e); registrar(f"VENTOINHAS repostas no máximo durante a CI: {' '.join(repostas)}")
        mudanca(f"VENTOINHAS repostas no máximo durante a CI ({' '.join(repostas)}). Desfazer: a saída da CI repõe o de antes")
def cpu_ler():  # (total, ocioso) da 1ª linha do /proc/stat; ocioso = idle + iowait
    try:
        with open(STAT) as f: v = [int(x) for x in f.readline().split()[1:9]]
    except (OSError, ValueError): return None
    return (sum(v), v[3] + v[4]) if len(v) >= 5 else None
def uso_janela(ini, fim):  # % de uso da CPU entre duas leituras; None se não der para saber (não sobe)
    if USO_ARQ:
        try:
            with open(USO_ARQ) as f: return float(f.read().strip())
        except (OSError, ValueError): return None
    if not ini or not fim or fim[0] <= ini[0]: return None
    return 100 * (1 - (fim[1] - ini[1]) / (fim[0] - ini[0]))
def ajustar_teto(e, temps, uso=None):  # chamado a cada TETO_JANELA no modo CI
    if len(temps) < 2 or "max_perf_pct" not in e["aplicado"]: return
    media = sum(temps) / len(temps)
    atual = ler("max_perf_pct")
    if atual is None or atual != e["aplicado"]["max_perf_pct"]: return  # mudado à mão: o dono manda
    perfil = ler("perfil") if "perfil" in e["aplicado"] else None
    if perfil is not None and perfil != e["aplicado"]["perfil"]: return
    if media <= TETO_LIMITE:
        if max(temps) > TETO_FOLGA: e["frios"] = 0  # subir só com a máxima em até 70
        elif uso is not None and uso >= TETO_USO: e["frios"] = e.get("frios", 0) + 1  # e com a CPU trabalhando
        # CPU ociosa: o minuto frio não diz quanto ela aguenta; não conta nem zera
        if e.get("frios", 0) >= TETO_SUBIDA:
            e["frios"] = 0; subir_teto(e, atual, perfil, media)
        return
    e["frios"] = 0
    if int(atual) <= TETO_PISO:
        prox = CASCATA[CASCATA.index(perfil) + 1] if perfil in CASCATA[:-1] else None
        if prox:
            err = gravar("perfil", prox) or gravar("max_perf_pct", 100)
            if err: registrar(f"AVISO: degrau de perfil não aplicado ({err})"); return
            e["aplicado"]["perfil"] = ler("perfil") or prox; e["aplicado"]["max_perf_pct"] = ler("max_perf_pct") or "100"; salvar(e)
            manter_ventoinhas(e)  # a troca de perfil pode zerar o boost
            registrar(f"PERFIL da CI {perfil} -> {prox}, teto 100% (média {media:.1f} °C > {TETO_LIMITE:g} com o teto no piso {TETO_PISO}%)")
            mudanca(f"PERFIL da CI {perfil} -> {prox} com teto 100% (média {media:.1f} °C no piso de {TETO_PISO}%). Desfazer: a "
                    f"saída da CI repõe o de antes; à mão: powerprofilesctl set {perfil}; echo {atual} > {arquivo('max_perf_pct')}")
            return
        if not e.get("piso_avisado"):
            registrar(f"TETO no piso ({TETO_PISO}%) do último perfil ({perfil}) e a média segue em {media:.1f} °C (> {TETO_LIMITE:g})"); e["piso_avisado"] = True; salvar(e)
        return
    novo = max(TETO_PISO, int(atual) - TETO_PASSO)
    if media > TETO_QUEDA and novo > int(CI_V["max_perf_pct"]): novo = int(CI_V["max_perf_pct"])  # pico: direto ao inicial
    err = gravar("max_perf_pct", novo)
    if err: registrar(f"AVISO: teto não reduzido ({err})"); return
    e["aplicado"]["max_perf_pct"] = ler("max_perf_pct") or str(novo); salvar(e)
    registrar(f"TETO reduzido {atual} -> {novo}% (média {media:.1f} °C em {len(temps)} amostras > {TETO_LIMITE:g} °C)")
    mudanca(f"TETO da CI reduzido {atual} -> {novo}% (média {media:.1f} °C > {TETO_LIMITE:g}). Desfazer: a saída da CI "
            f"repõe o de antes; à mão: echo {atual} > {arquivo('max_perf_pct')}")
def subir_teto(e, atual, perfil, media):
    if int(atual) < 100:
        novo = min(100, int(atual) + TETO_PASSO)
        err = gravar("max_perf_pct", novo)
        if err: registrar(f"AVISO: teto não subiu ({err})"); return
        e["aplicado"]["max_perf_pct"] = ler("max_perf_pct") or str(novo); e["piso_avisado"] = False; salvar(e)
        registrar(f"TETO subiu {atual} -> {novo}% (máxima até {TETO_FOLGA:g} °C por {TETO_SUBIDA} janelas; média {media:.1f} °C)")
        mudanca(f"TETO da CI subiu {atual} -> {novo}% (média {media:.1f} °C, folga). Desfazer: a saída da CI repõe o de antes")
        return
    ant = CASCATA[CASCATA.index(perfil) - 1] if perfil in CASCATA[1:] else None
    if not ant: return
    err = gravar("perfil", ant) or gravar("max_perf_pct", TETO_PISO)
    if err: registrar(f"AVISO: volta de perfil não aplicada ({err})"); return
    e["aplicado"]["perfil"] = ler("perfil") or ant; e["aplicado"]["max_perf_pct"] = ler("max_perf_pct") or str(TETO_PISO); salvar(e)
    manter_ventoinhas(e)
    registrar(f"PERFIL da CI voltou {perfil} -> {ant}, teto {TETO_PISO}% (máxima até {TETO_FOLGA:g} °C com teto 100%)")
    mudanca(f"PERFIL da CI voltou {perfil} -> {ant} com teto {TETO_PISO}% (folga). Desfazer: a saída da CI repõe o de antes")
def sair(e, motivo):
    repostos, mantidos, falhas = [], [], []
    for i in e["itens"]:
        v = ler(i)
        if v is None: registrar(f"AVISO: não consegui ler {i} na saída; fica como está"); falhas.append(i); continue
        # Já no valor de antes não é "mudança à mão": a reposição do perfil (powerprofilesctl) zera o boost (20/10).
        if v == e["antes"][i]: repostos.append(f"{i}={v}"); continue
        if i in e["aplicado"] and v != e["aplicado"][i]: mantidos.append(f"{i}={v}"); continue
        err = gravar(i, e["antes"][i])
        if err: registrar(f"AVISO: {i} não reposto ({err})"); falhas.append(i)
        else: repostos.append(f"{i}={e['antes'][i]}")
    txt = (f"SAIU do perfil {'térmico por calor' if e.get('calor') else 'da CI'} ({motivo}) · jobs vistos: {' '.join(e['vistos']) or 'nenhum'}"
           f" · reposto: {' '.join(repostos) or 'nada'}")
    if mantidos: txt += f" · mantido (mudado à mão durante a CI): {' '.join(mantidos)}"
    if falhas: txt += f" · falhou: {' '.join(falhas)}"
    registrar(txt)
    refazer = "; ".join(comando(i, CI_V[classe(i)]) for i in e["itens"])
    mudanca(f"{txt}. Desfazer: não se aplica (a próxima CI reaplica sozinha); à mão: {refazer or 'nada'}")
    e.update(novo_estado()); salvar(e)

# ---------- laço ----------
def perfil_pos_boot():  # True = resolvido (legível); fora da CI, volta ao padrão se estiver noutro
    v = ler("perfil")
    if v is None: return False
    if v != RES_V["perfil"]:
        err = gravar("perfil", RES_V["perfil"])
        if err: registrar(f"AVISO: perfil pós-boot não reposto ({err})"); return True
        registrar(f"PERFIL pós-boot {v} -> {RES_V['perfil']} (fora da CI, boot novo)")
        mudanca(f"PERFIL pós-boot {v} -> {RES_V['perfil']} (fora da CI, boot novo). Desfazer: powerprofilesctl set {v}")
    return True
def incluir_perfil(e):  # CI que entrou sem o perfil (ilegível no boot): inclui quando ficar legível
    v = ler("perfil")
    if v is None: return
    e["itens"] = ["perfil"] + e["itens"]; e["antes"]["perfil"] = RES_V["perfil"]; salvar(e)
    err = gravar("perfil", CI_V["perfil"])
    if err: registrar(f"AVISO: perfil não aplicado ({err}); segue com o resto"); e["itens"].remove("perfil"); e["antes"].pop("perfil"); salvar(e); return
    e["aplicado"]["perfil"] = ler("perfil") or CI_V["perfil"]; salvar(e)
    registrar(f"INCLUIU o perfil na CI (estava ilegível na entrada): {v} -> {e['aplicado']['perfil']} · antes: {RES_V['perfil']} (padrão)")
    mudanca(f"INCLUIU o perfil na CI: {v} -> {e['aplicado']['perfil']}. Desfazer: a saída da CI repõe {RES_V['perfil']}")
class Parar(Exception): pass
PARAR = None; DORMINDO = False
def ao_sinal(sig, _frame):
    global PARAR
    PARAR = signal.Signals(sig).name
    if DORMINDO: raise Parar()  # fora do sono, o laço confere o pedido no próximo passo seguro
def laco():
    if not ATIVA:
        registrar("KIT_TERM_ATIVA=0: controle térmico desligado; nada a fazer"); sys.exit(0)
    os.makedirs(DIR, exist_ok=True)
    trava = open(f"{DIR}/trava", "w")  # o Python não deixa os filhos herdarem o descritor
    try: fcntl.flock(trava, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError: print(f"ci-termica: outra instância já roda com {DIR}; saindo", file=sys.stderr); sys.exit(3)
    global DORMINDO
    signal.signal(signal.SIGTERM, ao_sinal); signal.signal(signal.SIGINT, ao_sinal)
    e = carregar()
    if e is None: e = novo_estado(); salvar(e)
    boot_salvo = e["boot"]
    registrar(f"INICIOU {'(WSL' + (', modo Windows' if WIN else '') + ') ' if WSL else ''}(intervalo {INTERVALO:g} s, saída após {SAIDA_S:g} s sem job; modo salvo: {e['modo']})")
    if e["modo"] == "ci": registrar(f"RETOMOU o estado salvo da CI (a instância anterior caiu no meio): antes: {descrever(e['antes'], e['itens'])}")
    ultimo = time.monotonic(); primeira = True; falha_listar = False; pos_boot = boot_salvo != boot_id()
    temps = []; janela_ini = time.monotonic(); cpu_ini = cpu_ler()
    quentes = 0; ultima_carga = time.monotonic(); cpu_amostra = cpu_ler()
    try:
        while True:
            if PARAR: raise Parar()
            jobs = listar_jobs()
            if jobs is None:
                if not falha_listar: registrar("AVISO: a listagem de jobs falhou; nada muda até ela voltar")
                falha_listar = True
            else:
                if falha_listar: registrar("a listagem de jobs voltou a funcionar")
                falha_listar = False
                agora = time.monotonic()
                if jobs:
                    ultimo = agora
                    if e["modo"] != "ci": entrar(e, jobs, primeira)
                    elif e.get("calor"):  # job no perfil por calor: vira CI normal (log no formato da CI, para a tendência)
                        e["calor"] = False; e["vistos"] = sorted(set(jobs)); salvar(e)
                        registrar(f"ENTROU no perfil da CI · jobs: {resumo(jobs)} (já no perfil por calor) · antes: "
                                  f"{descrever(e['antes'], e['itens'])} · aplicado: {descrever(e['aplicado'], e['itens'])}")
                    elif primeira and boot_salvo != boot_id():
                        # Retomada depois de um boot com job rodando: o boot zerou o boost e o pstate.
                        desfazer = aplicar_ci(e); e["vistos"] = sorted(set(e["vistos"]) | set(jobs)); salvar(e)
                        registrar(f"REAPLICOU o perfil da CI (boot novo desde o estado salvo) · jobs: {resumo(jobs)} · aplicado: {descrever(e['aplicado'], e['itens'])}")
                        mudanca(f"REAPLICOU o perfil da CI depois de um boot: {descrever(e['aplicado'], e['itens'])}. Desfazer: à mão: {desfazer or 'nada'}")
                    elif not set(jobs) <= set(e["vistos"]):
                        e["vistos"] = sorted(set(e["vistos"]) | set(jobs)); salvar(e)
                elif e["modo"] == "ci" and e.get("calor"):
                    if agora - max(ultimo, ultima_carga) >= SAIDA_S: sair(e, f"{agora - max(ultimo, ultima_carga):.0f} s sem calor nem carga")
                elif e["modo"] == "ci" and agora - ultimo >= SAIDA_S:
                    sair(e, f"{agora - ultimo:.0f} s sem job")
            if e["modo"] == "ci":
                pos_boot = False
                if not WSL and "perfil" not in e["itens"]: incluir_perfil(e)
                manter_ventoinhas(e)
                t = temp_cpu(); agora = time.monotonic()
                if t is not None: temps.append(t)
                cpu = cpu_ler(); uso = uso_janela(cpu_amostra, cpu); cpu_amostra = cpu
                teto = ler("max_perf_pct")
                if (t is not None and t > TETO_FOLGA) or (uso is not None and uso >= TETO_USO and teto is not None and int(teto) < 100):
                    ultima_carga = agora  # perfil por calor: ainda quente, ou com carga e o teto abaixo de 100
                if agora - janela_ini >= TETO_JANELA:
                    cpu = cpu_ler(); ajustar_teto(e, temps, uso_janela(cpu_ini, cpu)); temps = []; janela_ini = agora; cpu_ini = cpu
            else:
                if pos_boot and jobs is not None and (WSL or perfil_pos_boot()): pos_boot = False
                temps = []; janela_ini = time.monotonic(); cpu_ini = cpu_ler(); cpu_amostra = cpu_ini
                t = temp_cpu(); quentes = quentes + 1 if t is not None and t > CALOR_C else 0
                if quentes >= CALOR_N and jobs is not None:
                    quentes = 0; ultima_carga = time.monotonic(); entrar(e, [], primeira, calor=t)
            primeira = False
            if PARAR: raise Parar()
            DORMINDO = True
            try: time.sleep(INTERVALO)
            finally: DORMINDO = False
    except Parar:
        signal.signal(signal.SIGTERM, signal.SIG_IGN); signal.signal(signal.SIGINT, signal.SIG_IGN)
        if e["modo"] == "ci": sair(e, f"serviço parado por {PARAR} no meio da CI")
        registrar(f"PAROU ({PARAR})"); sys.exit(0)

def mostrar_estado():
    e = carregar() or novo_estado()
    print(f"modo: {e['modo']}" + (f" desde {datetime.datetime.fromtimestamp(e['desde']):%Y-%m-%d %H:%M:%S}" if e["modo"] == "ci" else ""))
    if e["itens"]: print(f"antes: {descrever(e['antes'], e['itens'])}\naplicado: {descrever(e['aplicado'], e['itens'])}")
    its = itens_presentes(); agora = {i: v for i in its if (v := ler(i)) is not None}
    print(f"agora: {descrever(agora, its)} · ventoinhas: {', '.join(fan_arquivos()) or 'nenhuma'} · WSL: {'sim' if WSL else 'não'} · modo Windows: {'sim' if WIN else 'não'}")
    j = listar_jobs(); print(f"jobs: {resumo(j) if j is not None else 'listagem falhou'}")

# ---------- autoteste ----------
def autoteste():
    base = E.get("CI_TERMICA_TMP") or f"{KC}"; os.makedirs(base, exist_ok=True)
    T = tempfile.mkdtemp(prefix="ci-termica-autoteste.", dir=base)
    procs = []; falhas = 0; ESP = 2  # SAIDA_S dos testes
    def ler_arq(p):
        try:
            with open(p) as f: return f.read().strip()
        except OSError: return "-"
    def esc(p, v):
        with open(p, "w") as f: f.write(f"{v}\n")
    def prep(n, perfil, nt, mx, boost):  # sysfs falso: hwmonA = coretemp, hwmonB = ventoinhas (name fan_wmi)
        d = f"{T}/{n}"
        for s in ("pstate", "hwmon/hwmonA", "hwmon/hwmonB", "est"): os.makedirs(f"{d}/{s}")
        esc(f"{d}/hwmon/hwmonA/name", "coretemp"); esc(f"{d}/hwmon/hwmonB/name", "fan_wmi")
        esc(f"{d}/perfil", perfil); esc(f"{d}/pstate/no_turbo", nt); esc(f"{d}/pstate/max_perf_pct", mx)
        esc(f"{d}/hwmon/hwmonB/fan1_boost", boost); esc(f"{d}/hwmon/hwmonB/fan2_boost", boost)
        esc(f"{d}/jobs", ""); esc(f"{d}/boot_id", "boot-1"); esc(f"{d}/uso", 90)  # CPU trabalhando, salvo no (n)
        with open(f"{d}/ppctl", "w") as f:  # powerprofilesctl falso: get/set num arquivo
            f.write(f'#!/bin/bash\n[ -e "{d}/ppctl_fora" ] && exit 1\ncase "$1" in get) cat "{d}/perfil";; set) printf "%s\\n" "$2" > "{d}/perfil";; *) exit 2;; esac\n')
        os.chmod(f"{d}/ppctl", 0o755)
        return d
    def amb(d, intervalo="0.2"):
        a = {k: v for k, v in E.items() if not k.startswith(("CI_TERMICA_", "KIT_"))}
        a["KIT_CONF"] = f"{d}/sem-kit.conf"
        a.update(CI_TERMICA_DIR=f"{d}/est", CI_TERMICA_LOG=f"{d}/est/log", CI_TERMICA_MUDANCAS=f"{d}/mudancas.log",
                 CI_TERMICA_PSTATE=f"{d}/pstate", CI_TERMICA_HWMON=f"{d}/hwmon", CI_TERMICA_FAN=f"{d}/hwmon/hwmon*/fan*_boost", CI_TERMICA_WSL="0", CI_TERMICA_PPCTL=f"{d}/ppctl",
                 CI_TERMICA_LISTAR_JOBS=f"cat '{d}/jobs'", CI_TERMICA_BOOT_ID=f"{d}/boot_id",
                 CI_TERMICA_INTERVALO_S=intervalo, CI_TERMICA_SAIDA_S=str(ESP), CI_TERMICA_USO_ARQ=f"{d}/uso")
        return a
    def iniciar(d, intervalo="0.2"):
        p = subprocess.Popen(["bash", SELF], env=amb(d, intervalo), stdout=open(f"{d}/saida", "a"), stderr=subprocess.STDOUT)
        procs.append(p); return p
    def est(d):
        try:
            with open(f"{d}/est/estado.json") as f: return json.load(f)
        except (OSError, ValueError): return {}
    def em_ci(d): x = est(d); return x.get("modo") == "ci" and bool(x.get("aplicado"))
    def normal(d): return est(d).get("modo") == "normal"
    def vals(d):
        hw = next((f"{d}/hwmon/{n}" for n in sorted(os.listdir(f"{d}/hwmon")) if ler_arq(f"{d}/hwmon/{n}/name") == "fan_wmi"), None)
        fans = f"{ler_arq(hw + '/fan1_boost')} {ler_arq(hw + '/fan2_boost')}" if hw else "- -"
        return f"{ler_arq(d + '/perfil')} {ler_arq(d + '/pstate/no_turbo')} {ler_arq(d + '/pstate/max_perf_pct')} {fans}"
    def esperar(s, cond):
        fim = time.monotonic() + s
        while not cond():
            if time.monotonic() >= fim: return False
            time.sleep(0.05)
        return True
    def no_log(d, txt): return txt in ler_arq(f"{d}/est/log")
    R = []
    def confere(veio, esperado, oque):
        if veio != esperado: R.append(f"{oque}: esperado [{esperado}], veio [{veio}]")
    def exige(cond, oque):
        if not cond: R.append(oque)
    def fim_cen(rotulo, p=None):
        nonlocal falhas
        if p and p.poll() is None:
            p.terminate()
            try: p.wait(3)
            except subprocess.TimeoutExpired: p.kill(); R.append("não terminou com SIGTERM")
        print(("ok    " if not R else "FALHA ") + rotulo + "".join(f"; {r}" for r in R), flush=True)
        if R: falhas += 1
        R.clear()
    def entra(d, jobs="ciuser"):
        esc(f"{d}/jobs", jobs); exige(esperar(3, lambda: em_ci(d)), "não entrou no modo CI")
    def sai(d):
        esc(f"{d}/jobs", ""); exige(esperar(ESP + 3, lambda: normal(d)), "não saiu do modo CI")
    try:
        # (a) entra com 1 job e aplica os 4 itens; segunda instância recusada; linha no log de mudanças
        d = prep("a", "power-saver", 1, 100, 0); p = iniciar(d)
        exige(esperar(3, lambda: normal(d)), "não iniciou"); entra(d)
        confere(vals(d), "performance 0 60 255 255", "valores na CI")
        exige("ENTROU" in ler_arq(f"{d}/mudancas.log"), "sem linha no log de mudanças")
        r = subprocess.run(["bash", SELF], env=amb(d), capture_output=True, timeout=10)
        confere(r.returncode, 3, "segunda instância")
        sai(d); confere(vals(d), "power-saver 1 100 0 0", "valores repostos (no_turbo volta a 1)")
        fim_cen("(a) entra com 1 job e aplica perfil, no_turbo, max_perf_pct e boost", p)

        # (b) 2 jobs de usuários diferentes, um termina: segue na CI
        d = prep("b", "power-saver", 0, 100, 0); p = iniciar(d); esperar(3, lambda: normal(d))
        entra(d, "ciuser\nciuser2"); esc(f"{d}/jobs", "ciuser2"); time.sleep(ESP + 1)
        exige(em_ci(d), "saiu com 1 job ainda rodando"); confere(vals(d), "performance 0 60 255 255", "valores com 1 job")
        sai(d); exige(no_log(d, "jobs vistos: ciuser ciuser2"), "log da saída sem os dois usuários")
        fim_cen("(b) dois jobs de usuários diferentes, um termina: segue no modo CI", p)

        # (c) sem job por menos de N: não sai; por N: sai e repõe
        d = prep("c", "power-saver", 0, 100, 0); p = iniciar(d); esperar(3, lambda: normal(d)); entra(d)
        esc(f"{d}/jobs", ""); t0 = time.monotonic(); time.sleep(ESP / 2)
        exige(em_ci(d), "saiu antes de N"); sai(d); dt = time.monotonic() - t0
        exige(dt >= ESP - 0.3, f"saiu cedo demais ({dt:.2f} s)")
        confere(vals(d), "power-saver 0 100 0 0", "valores repostos")
        fim_cen(f"(c) sem job por menos de N não sai; por N sai e repõe (saiu {dt:.1f} s depois do último job; N = {ESP} s)", p)

        # (d) mudança à mão do perfil (e do teto) durante a CI: esses itens ficam como o dono deixou
        d = prep("d", "power-saver", 0, 100, 0); p = iniciar(d); esperar(3, lambda: normal(d)); entra(d)
        esc(f"{d}/perfil", "balanced"); esc(f"{d}/pstate/max_perf_pct", 80); sai(d)
        confere(vals(d), "balanced 0 80 0 0", "valores na saída")
        exige(no_log(d, "mantido (mudado à mão durante a CI): perfil=balanced max_perf_pct=80"), "log sem os itens mantidos")
        fim_cen("(d) mudança à mão durante a CI fica como o dono deixou; o resto é reposto", p)

        # (e) SIGTERM no meio da CI: repõe, sai com 0 e logo (sem esperar o fim do sono)
        d = prep("e", "power-saver", 0, 100, 0); esc(f"{d}/jobs", "ciuser"); p = iniciar(d, "5")  # job já na 1ª amostra
        exige(esperar(3, lambda: em_ci(d)), "não entrou no modo CI")
        time.sleep(0.3); t0 = time.monotonic(); p.terminate()
        try: rc = p.wait(3)
        except subprocess.TimeoutExpired: rc = "preso"
        dt = time.monotonic() - t0
        confere(rc, 0, "código de saída"); confere(vals(d), "power-saver 0 100 0 0", "valores depois do SIGTERM")
        confere(est(d).get("modo"), "normal", "modo salvo")
        exige(no_log(d, "SAIU do perfil da CI (serviço parado por SIGTERM"), "log sem a saída por SIGTERM")
        fim_cen(f"(e) SIGTERM no meio da CI repõe o estado salvo (terminou em {dt * 1000:.0f} ms, intervalo de 5 s)")

        # (f) início com a CI já rodando e o estado já no da CI: o "antes" vira o padrão de reserva
        d = prep("f", "performance", 0, 100, 255); esc(f"{d}/jobs", "ciuser"); p = iniciar(d)
        exige(esperar(3, lambda: em_ci(d)), "não entrou")
        confere(descrever(est(d).get("antes", {}), est(d).get("itens", [])),
                "perfil=balanced no_turbo=0 max_perf_pct=100 fan_wmi/fan1_boost=0 fan_wmi/fan2_boost=0", "antes")
        sai(d); confere(vals(d), "balanced 0 100 0 0", "valores na saída")
        fim_cen("(f) início com a CI já rodando usa a reserva (balanced, 0, 100, 0)", p)

        # (l) ventoinhas sempre no máximo na CI: zeradas (à mão ou pela troca de perfil) voltam a 255; saída repõe
        d = prep("l", "power-saver", 0, 100, 0); p = iniciar(d); esperar(3, lambda: normal(d)); entra(d)
        esc(f"{d}/hwmon/hwmonB/fan1_boost", 0); esc(f"{d}/hwmon/hwmonB/fan2_boost", 128)
        exige(esperar(2, lambda: vals(d).endswith("255 255")), "ventoinhas não voltaram a 255")
        exige(esperar(2, lambda: no_log(d, "VENTOINHAS repostas")), "sem log da reposição")
        sai(d); confere(vals(d), "power-saver 0 100 0 0", "saída repõe as ventoinhas de antes")
        fim_cen("(l) ventoinhas zeradas durante a CI voltam a 255 em qualquer perfil; a saída repõe", p)

        def temp(d, c): esc(f"{d}/hwmon/hwmonA/temp1_label", "Package id 0"); esc(f"{d}/hwmon/hwmonA/temp1_input", int(c * 1000))
        # (m) subida: média < 70 por 3 janelas sobe 10 até 100; entre 70 e 80 fica; depois desce com > 80
        d = prep("m", "power-saver", 0, 100, 0); temp(d, 60)
        a = amb(d, "0.05"); a.update(CI_TERMICA_TETO_JANELA_S="0.3", CI_TERMICA_SAIDA_S="1.5")
        p = subprocess.Popen(["bash", SELF], env=a, stdout=open(f"{d}/saida", "a"), stderr=subprocess.STDOUT); procs.append(p)
        exige(esperar(3, lambda: normal(d)), "não iniciou"); esc(f"{d}/jobs", "ciuser"); exige(esperar(3, lambda: em_ci(d)), "não entrou")
        confere(ler_arq(f"{d}/pstate/max_perf_pct"), "60", "começa em 60")
        temp(d, 71); time.sleep(1.5); confere(ler_arq(f"{d}/pstate/max_perf_pct"), "60", "71 °C: não sobe (acima de 70)")
        temp(d, 70); exige(esperar(1.5, lambda: ler_arq(f"{d}/pstate/max_perf_pct") == "70"), "70 °C: não subiu a 70")
        exige(esperar(6, lambda: ler_arq(f"{d}/pstate/max_perf_pct") == "100"), "70 °C: não chegou a 100")
        time.sleep(1.5); confere(ler_arq(f"{d}/pstate/max_perf_pct"), "100", "não passa de 100")
        temp(d, 75); time.sleep(0.4); t75 = ler_arq(f"{d}/pstate/max_perf_pct"); time.sleep(1.5)
        confere(ler_arq(f"{d}/pstate/max_perf_pct"), t75, "75 °C: fica onde está")
        temp(d, 90); exige(esperar(2, lambda: ler_arq(f"{d}/pstate/max_perf_pct") == "90"), "90 °C: não desceu a 90")
        exige(esperar(2, lambda: no_log(d, "TETO subiu 60 -> 70%")), "sem log da subida")
        temp(d, 60); esc(f"{d}/jobs", ""); exige(esperar(5, lambda: normal(d)), "não saiu"); confere(vals(d), "power-saver 0 100 0 0", "saída repõe")
        fim_cen("(m) subida: máxima até 70 °C por 3 janelas sobe 10 até 100; 71 não sobe; entre 70 e 80 fica; > 80 desce; saída repõe", p)

        # (n) só sob carga: CPU ociosa e fria não sobe; com carga sobe; pico > 90 °C volta direto ao inicial (60)
        d = prep("n", "power-saver", 0, 100, 0); temp(d, 60); esc(f"{d}/uso", 10)
        a = amb(d, "0.05"); a.update(CI_TERMICA_TETO_JANELA_S="0.3", CI_TERMICA_SAIDA_S="1.5")
        p = subprocess.Popen(["bash", SELF], env=a, stdout=open(f"{d}/saida", "a"), stderr=subprocess.STDOUT); procs.append(p)
        exige(esperar(3, lambda: normal(d)), "não iniciou"); esc(f"{d}/jobs", "ciuser"); exige(esperar(3, lambda: em_ci(d)), "não entrou")
        time.sleep(1.8); confere(ler_arq(f"{d}/pstate/max_perf_pct"), "60", "CPU ociosa (10%) e fria: não sobe")
        esc(f"{d}/uso", 49); time.sleep(1.2); confere(ler_arq(f"{d}/pstate/max_perf_pct"), "60", "uso 49%: não sobe")
        esc(f"{d}/uso", 90); exige(esperar(6, lambda: ler_arq(f"{d}/pstate/max_perf_pct") == "100"), "com carga: não chegou a 100")
        temp(d, 95); exige(esperar(1.5, lambda: ler_arq(f"{d}/pstate/max_perf_pct") == "60"), "95 °C: não voltou direto a 60")
        exige(no_log(d, "TETO reduzido 100 -> 60%"), "a queda passou por degraus")
        temp(d, 85); exige(esperar(1.5, lambda: ler_arq(f"{d}/pstate/max_perf_pct") == "50"), "85 °C em 60: não desceu 10")
        temp(d, 60); esc(f"{d}/jobs", ""); exige(esperar(5, lambda: normal(d)), "não saiu"); confere(vals(d), "power-saver 0 100 0 0", "saída repõe")
        fim_cen("(n) só sob carga: ociosa (10%, 49%) não sobe, com 90% sobe; > 90 °C volta direto a 60; 80-90 desce 10; saída repõe", p)

        # (p) calor sem CI: 80 °C não entra; > 80 entra no perfil; quente fica; frio e ociosa sai e repõe; job no perfil
        # por calor vira CI; com carga e fria, o teto sobe até 100 antes de sair (sem vaivém)
        d = prep("calor", "balanced", 0, 100, 0); temp(d, 80); esc(f"{d}/uso", 10)
        a = amb(d, "0.05"); a.update(CI_TERMICA_TETO_JANELA_S="0.3", CI_TERMICA_SAIDA_S="1.5")
        p = subprocess.Popen(["bash", SELF], env=a, stdout=open(f"{d}/saida", "a"), stderr=subprocess.STDOUT); procs.append(p)
        exige(esperar(3, lambda: normal(d)), "não iniciou"); time.sleep(0.6); exige(normal(d), "80 °C (não passou de 80): entrou")
        temp(d, 85); exige(esperar(2, lambda: em_ci(d)), "85 °C sem job: não entrou")
        confere(vals(d), "performance 0 60 255 255", "valores no perfil por calor"); exige(no_log(d, "ENTROU no perfil térmico por calor (85 °C, sem job)"), "sem log da entrada por calor")
        temp(d, 75); time.sleep(2.2); exige(em_ci(d), "75 °C (acima de 70): saiu")
        temp(d, 60); exige(esperar(4, lambda: normal(d)), "frio e ociosa: não saiu"); confere(vals(d), "balanced 0 100 0 0", "saída por calor repõe")
        exige(no_log(d, "SAIU do perfil térmico por calor"), "sem log da saída por calor")
        temp(d, 85); exige(esperar(2, lambda: em_ci(d)), "85 °C de novo: não entrou"); esc(f"{d}/jobs", "ci1")
        exige(esperar(2, lambda: no_log(d, "(já no perfil por calor)")), "job no perfil por calor: sem log da CI")
        temp(d, 60); time.sleep(0.5); esc(f"{d}/jobs", ""); exige(esperar(4, lambda: normal(d)), "CI vinda do calor: não saiu")
        exige(no_log(d, "SAIU do perfil da CI"), "saída da CI vinda do calor sem o nome da CI"); confere(vals(d), "balanced 0 100 0 0", "saída repõe")
        esc(f"{d}/uso", 90); temp(d, 85); exige(esperar(2, lambda: em_ci(d)), "com carga: não entrou"); temp(d, 65)
        time.sleep(2.0); exige(em_ci(d), "com carga, fria e teto abaixo de 100: saiu (vaivém)")
        exige(esperar(8, lambda: normal(d)), "com carga e fria: não saiu depois do teto chegar a 100")
        exige(no_log(d, "TETO subiu 90 -> 100%"), "saiu antes de o teto chegar a 100")
        fim_cen("(p) calor sem CI: > 80 °C entra, 80 não; acima de 70 fica; fria e ociosa sai e repõe; job vira CI; com carga sobe a 100 antes de sair", p)

        # (k) teto dinâmico: média > 85 baixa 10 por janela até o piso de 50; abaixo de 85 para; a saída repõe
        d = prep("k", "power-saver", 0, 100, 0); temp(d, 70)
        a = amb(d, "0.05"); a.update(CI_TERMICA_TETO_JANELA_S="0.4", CI_TERMICA_SAIDA_S="1.5", CI_TERMICA_CI_MAX_PERF="100")
        p = subprocess.Popen(["bash", SELF], env=a, stdout=open(f"{d}/saida", "a"), stderr=subprocess.STDOUT); procs.append(p)
        exige(esperar(3, lambda: normal(d)), "não iniciou"); esc(f"{d}/jobs", "ciuser"); exige(esperar(3, lambda: em_ci(d)), "não entrou")
        time.sleep(1.2); confere(ler_arq(f"{d}/pstate/max_perf_pct"), "100", "70 °C: teto fica em 100")
        temp(d, 90); exige(esperar(2, lambda: ler_arq(f"{d}/pstate/max_perf_pct") == "90"), "90 °C: não baixou a 90")
        temp(d, 80); time.sleep(1.5); confere(ler_arq(f"{d}/pstate/max_perf_pct"), "90", "80 °C: estabiliza em 90")
        temp(d, 95); exige(esperar(5, lambda: ler_arq(f"{d}/pstate/max_perf_pct") == "50"), "95 °C: não chegou ao piso 50")
        exige(esperar(3, lambda: ler_arq(f"{d}/perfil") == "balanced"), "no piso e quente: não desceu para balanced")
        exige(esperar(5, lambda: ler_arq(f"{d}/perfil") == "balanced" and ler_arq(f"{d}/pstate/max_perf_pct") == "50"), "balanced: não desceu a 50")
        exige(esperar(3, lambda: ler_arq(f"{d}/perfil") == "power-saver"), "balanced no piso e quente: não desceu para power-saver")
        exige(esperar(5, lambda: ler_arq(f"{d}/perfil") == "power-saver" and ler_arq(f"{d}/pstate/max_perf_pct") == "50"), "power-saver: não desceu a 50")
        time.sleep(1.2); confere(vals(d)[:16], "power-saver 0 50", "fica no piso do último perfil"); exige(no_log(d, "TETO no piso"), "sem aviso do piso")
        exige(no_log(d, "PERFIL da CI performance -> balanced") and no_log(d, "PERFIL da CI balanced -> power-saver"), "log sem os degraus de perfil")
        exige("TETO da CI reduzido" in ler_arq(f"{d}/mudancas.log"), "redução sem linha no log de mudanças")
        temp(d, 60); esc(f"{d}/jobs", ""); exige(esperar(5, lambda: normal(d)), "não saiu")
        confere(vals(d), "power-saver 0 100 0 0", "saída repõe o teto de antes (redução não conta como mudança à mão)")
        fim_cen("(k) teto dinâmico: 100 -> 90 com média > 80, para em 80 ou menos; no piso desce de perfil (performance -> balanced -> power-saver, cada um de 100 a 50); saída repõe", p)

        # (g1) ventoinhas ausentes; (g2) boost não gravável: segue com o resto, avisa, não morre
        d = prep("g1", "power-saver", 0, 100, 0); shutil.rmtree(f"{d}/hwmon/hwmonB")
        p = iniciar(d); esperar(3, lambda: normal(d)); entra(d)
        confere(vals(d), "performance 0 60 - -", "valores na CI"); exige(no_log(d, "AVISO: nenhuma ventoinha"), "sem AVISO das ventoinhas")
        sai(d); confere(vals(d), "power-saver 0 100 - -", "valores na saída"); exige(p.poll() is None, "morreu")
        fim_cen("(g1) ventoinhas ausentes: aplica e repõe o resto, com AVISO, sem morrer", p)
        d = prep("g2", "power-saver", 0, 100, 0)
        for f in ("fan1_boost", "fan2_boost"): os.chmod(f"{d}/hwmon/hwmonB/{f}", 0o444)
        p = iniciar(d); esperar(3, lambda: normal(d)); entra(d)
        confere(vals(d), "performance 0 60 0 0", "valores na CI"); exige(no_log(d, "AVISO: fan_wmi/fan1_boost não aplicado"), "sem AVISO de não gravável")
        sai(d); confere(vals(d), "power-saver 0 100 0 0", "valores na saída"); exige(p.poll() is None, "morreu")
        fim_cen("(g2) boost não gravável: aplica e repõe o resto, com AVISO, sem morrer", p)

        # (h) o hwmon troca de número durante a CI: acha pelo nome e repõe no novo
        d = prep("h", "power-saver", 0, 100, 0); p = iniciar(d); esperar(3, lambda: normal(d)); entra(d)
        os.rename(f"{d}/hwmon/hwmonB", f"{d}/hwmon/hwmonC"); sai(d)
        confere(f"{ler_arq(d + '/hwmon/hwmonC/fan1_boost')} {ler_arq(d + '/hwmon/hwmonC/fan2_boost')}", "0 0", "boost no hwmonC")
        confere(vals(d), "power-saver 0 100 0 0", "valores na saída")
        fim_cen("(h) o hwmon troca de número (hwmonB -> hwmonC): acha pelo nome", p)

        # (o) boot novo fora da CI: espera o powerprofilesctl voltar e repõe o padrão; mesmo boot não mexe
        d = prep("o", "performance", 0, 100, 0); p = iniciar(d); esperar(3, lambda: normal(d)); time.sleep(0.8)
        confere(ler_arq(f"{d}/perfil"), "performance", "mesmo boot, fora da CI: perfil mudado à mão fica"); p.terminate(); p.wait()
        esc(f"{d}/boot_id", "boot-2"); esc(f"{d}/ppctl_fora", 1); p = iniciar(d); time.sleep(0.8)
        confere(ler_arq(f"{d}/perfil"), "performance", "powerprofilesctl fora: nada muda"); os.remove(f"{d}/ppctl_fora")
        exige(esperar(3, lambda: ler_arq(f"{d}/perfil") == "balanced"), "boot novo: não voltou a balanced")
        exige(no_log(d, "PERFIL pós-boot performance -> balanced"), "log sem o perfil pós-boot")
        esc(f"{d}/perfil", "power-saver"); time.sleep(0.8); confere(ler_arq(f"{d}/perfil"), "power-saver", "só uma vez por boot")
        fim_cen("(o) boot novo fora da CI: volta ao padrão (balanced) quando o powerprofilesctl responde, uma vez", p)

        # (p) CI que entra com o powerprofilesctl fora: inclui o perfil depois, com o antes no padrão
        d = prep("p", "balanced", 0, 100, 0); esc(f"{d}/ppctl_fora", 1); esc(f"{d}/jobs", "ciuser"); p = iniciar(d)
        exige(esperar(3, lambda: em_ci(d)), "não entrou"); confere(ler_arq(f"{d}/perfil"), "balanced", "perfil fora: fica")
        os.remove(f"{d}/ppctl_fora"); exige(esperar(3, lambda: ler_arq(f"{d}/perfil") == "performance"), "não incluiu o perfil")
        exige(no_log(d, "INCLUIU o perfil na CI"), "log sem a inclusão")
        sai(d); confere(vals(d), "balanced 0 100 0 0", "saída repõe o padrão")
        fim_cen("(p) CI com o perfil ilegível na entrada: inclui depois e a saída repõe balanced", p)

        # (i) queda (SIGKILL) no meio da CI + boot novo + job: retoma o "antes" salvo, reaplica, repõe no fim
        d = prep("i", "power-saver", 0, 100, 0); p = iniciar(d); esperar(3, lambda: normal(d)); entra(d)
        p.kill(); p.wait()
        esc(f"{d}/boot_id", "boot-2"); os.rename(f"{d}/hwmon/hwmonB", f"{d}/hwmon/hwmonD")  # o boot renumera e zera
        esc(f"{d}/hwmon/hwmonD/fan1_boost", 0); esc(f"{d}/hwmon/hwmonD/fan2_boost", 0); esc(f"{d}/pstate/max_perf_pct", 100)
        p = iniciar(d); exige(esperar(3, lambda: no_log(d, "REAPLICOU")), "não reaplicou depois do boot")
        confere(vals(d), "performance 0 60 255 255", "valores reaplicados")
        sai(d); confere(vals(d), "power-saver 0 100 0 0", "valores na saída (o antes de antes da queda)")
        fim_cen("(i) queda no meio da CI e boot novo: retoma o estado salvo e reaplica", p)

        # (q) WSL com modo Windows: powercfg.exe simulado; teto fixo na CI, reposto na saída; mudança à mão fica
        d = prep("q", "power-saver", 0, 100, 0)
        with open(f"{d}/powercfg", "w") as f:
            f.write(f'''#!/bin/bash
D="{d}"; [ -e "$D/win_ac" ] || echo 100 > "$D/win_ac"; [ -e "$D/win_dc" ] || echo 100 > "$D/win_dc"
case "$1" in
 /query) printf 'Esquema atual\\n  Indice CA atual: 0x%08x\\n  Indice CC atual: 0x%08x\\n' "$(cat "$D/win_ac")" "$(cat "$D/win_dc")";;
 /setacvalueindex) echo "$5" > "$D/win_ac";;
 /setdcvalueindex) echo "$5" > "$D/win_dc";;
 /setactive) echo x >> "$D/ativou";;
 *) exit 1;;
esac
''')
        os.chmod(f"{d}/powercfg", 0o755)
        a = amb(d); a.update(CI_TERMICA_WSL="1", CI_TERMICA_WINDOWS="1", CI_TERMICA_POWERCFG=f"{d}/powercfg",
                              CI_TERMICA_PSTATE=f"{d}/sem-pstate", CI_TERMICA_FAN="")
        p = subprocess.Popen(["bash", SELF], env=a, stdout=open(f"{d}/saida", "a"), stderr=subprocess.STDOUT); procs.append(p)
        exige(esperar(3, lambda: normal(d)), "não iniciou"); esc(f"{d}/jobs", "ciuser"); exige(esperar(3, lambda: em_ci(d)), "WSL+Windows: não entrou")
        confere(f"{ler_arq(d + '/win_ac')} {ler_arq(d + '/win_dc')}", "60 60", "teto fixo no Windows (CA e CC)")
        exige(ler_arq(f"{d}/ativou") != "-", "sem powercfg /setactive")
        time.sleep(1); confere(f"{ler_arq(d + '/win_ac')} {ler_arq(d + '/win_dc')}", "60 60", "teto continua fixo")
        esc(f"{d}/win_ac", 80); sai(d)
        confere(f"{ler_arq(d + '/win_ac')} {ler_arq(d + '/win_dc')}", "80 100", "saída repõe a bateria e mantém o que foi mudado à mão")
        exige(p.poll() is None, "morreu")
        fim_cen("(q) WSL com modo Windows (powercfg simulado): teto fixo na CI (CA e CC), setactive, saída repõe", p)

        # (r) WSL sem modo Windows: nada a aplicar, sem AVISO nem erro, sem chamar o powercfg
        d = prep("r", "power-saver", 0, 100, 0)
        a = amb(d); a.update(CI_TERMICA_WSL="1", CI_TERMICA_WINDOWS="0", CI_TERMICA_POWERCFG=f"{d}/nao-deve-chamar",
                              CI_TERMICA_PSTATE=f"{d}/sem-pstate", CI_TERMICA_FAN="")
        p = subprocess.Popen(["bash", SELF], env=a, stdout=open(f"{d}/saida", "a"), stderr=subprocess.STDOUT); procs.append(p)
        exige(esperar(3, lambda: normal(d)), "não iniciou"); esc(f"{d}/jobs", "ciuser")
        exige(esperar(3, lambda: est(d).get("modo") == "ci"), "WSL: não registrou a sessão")
        time.sleep(0.6); exige(no_log(d, "WSL sem KIT_TERM_WINDOWS=1"), "sem a nota do WSL")
        exige("AVISO" not in ler_arq(f"{d}/est/log") and "Traceback" not in ler_arq(f"{d}/saida"), "AVISO ou erro no WSL sem Windows")
        confere(ler_arq(f"{d}/perfil"), "power-saver", "WSL: o perfil nem é lido")
        esc(f"{d}/jobs", ""); exige(esperar(5, lambda: normal(d)), "não saiu"); exige(p.poll() is None, "morreu")
        fim_cen("(r) WSL sem modo Windows: registra a sessão, não aplica nada, sem AVISO nem erro", p)

        # (j) estresse: SIGTERM em momentos ao acaso (entrando, na CI, saindo); sempre repõe e termina
        ruins = []
        for k in range(25):
            d = prep(f"j{k}", "power-saver", 0, 100, 0); esc(f"{d}/jobs", "ciuser")
            p = iniciar(d, "0.05"); time.sleep(random.uniform(0.15, 0.6))
            if k % 3 == 0: esc(f"{d}/jobs", "")
            p.terminate()
            try: rc = p.wait(3)
            except subprocess.TimeoutExpired: p.kill(); rc = "preso"
            if rc not in (0, -15) or vals(d) != "power-saver 0 100 0 0": ruins.append(f"j{k}: rc={rc} [{vals(d)}]")
        exige(not ruins, f"{len(ruins)}/25 ruins: {', '.join(ruins)}")
        fim_cen("(j) SIGTERM ao acaso em 25 partidas: sempre repõe e termina")
    finally:
        for p in procs:
            if p.poll() is None: p.kill(); p.wait()
        if E.get("CI_TERMICA_MANTER"): print(f"pasta mantida: {T}")
        else: shutil.rmtree(T, ignore_errors=True)
    print("---")
    print("autoteste: todos os cenários ok" if not falhas else f"autoteste: {falhas} cenário(s) com FALHA")
    return 0 if not falhas else 1

a = sys.argv[1:]
if a == ["--autoteste"]: sys.exit(autoteste())
elif a == ["--estado"]: mostrar_estado()
elif not a: laco()
else:
    with open(SELF) as f: print("".join(l[2:] for l in f.readlines()[1:] if l.startswith("#")), end="")
    sys.exit(2)
PY
