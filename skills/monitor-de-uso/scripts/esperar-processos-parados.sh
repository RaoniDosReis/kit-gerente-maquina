#!/usr/bin/env bash
# Vigia de processos parados por MUDANÇA DE ESTADO: a cada PARADOS_INTERVALO s (padrão 300) examina os
# processos do usuário que descendem de um processo do Claude Code (sessões, subagentes e os laços que eles
# deixaram) ou que são órfãos de um comando do Claude Code (o "bash -c source ~/.claude/shell-snapshots/..."
# reparentado ao systemd quando a sessão saiu). Só termina, imprimindo um relatório, quando acha um suspeito
# NOVO. Nunca mata nada: o relatório traz o "kill <pid>" e quem decide é o orquestrador. Ao receber, rode de novo.
# Origem: 11 processos esquecidos, de 1h30 a 6h45, quase todos laços
# "until ! pgrep -f X; do sleep 30; done" que nunca acabam porque o pgrep -f casa a linha do próprio shell.
# Suspeito (só com mais de PARADOS_IDADE_MIN min de vida, padrão 30):
#   (a) cwd apagado ("(deleted)");
#   (b) laço (while/until) com pgrep -f, pkill -f ou "ps ... | grep" cujo padrão casa a própria linha de comando;
#   (c) CPU quase zero (< PARADOS_CPU_BAIXA % de um núcleo, padrão 0.5) há mais de PARADOS_OCIOSO_MIN min
#       (padrão 30), contando a árvore de filhos, sem filho novo e sem escrita recente em arquivo aberto
#       (mtime dos arquivos normais em /proc/<pid>/fd, dele e dos filhos);
#   (d) CPU alta (>= PARADOS_CPU_ALTA % de um núcleo, padrão 80) e contínua há mais de PARADOS_OCUPADO_MIN min
#       (padrão 60) sem filho novo: laço ocupado.
#   (c) e (d) exigem uma medida real entre duas olhadas; na primeira, o início do ócio ou da ocupação é
#   estimado pela média da vida inteira do processo (só vale se a olhada seguinte confirmar).
# Exceções: os vigias conhecidos (esperar-*.sh, monitor-uso.py, saude-maquina.sh, garantir-monitor.sh,
# statusline.py; mais PARADOS_EXCECOES, uma regex), no próprio comando ou num ancestral; o próprio vigia; os
# processos do Claude Code; tudo que não é do usuário (executores da CI, serviços do sistema) ou não descende
# do Claude Code.
# Estado: $KIT_CACHE/parados-estado-<chave>.json, com a chave tirada da pasta da sessão (como
# no esperar-aviso-relevante.sh; PARADOS_SESSAO troca a chave, PARADOS_ESTADO troca o arquivo). O mesmo PID
# (com o mesmo instante de início) nunca é avisado duas vezes. Só lê /proc; não imprime ambiente, e no comando
# curto os valores de variáveis com TOKEN, SECRET, PASS ou KEY no nome viram "***".
set -u
KITSH="$(dirname "$(readlink -f "${BASH_SOURCE[0]:-$0}")")/../../gerente-da-maquina/lib/kit.sh"
# shellcheck disable=SC1090
[ -f "$KITSH" ] && . "$KITSH"
: "${KIT_CACHE:=$HOME/.cache/gerente-maquina}"
chave="${PARADOS_SESSAO:-$(printf '%s' "$PWD" | md5sum | cut -c1-12)}"
export PARADOS_ESTADO="${PARADOS_ESTADO:-$KIT_CACHE/parados-estado-$chave.json}"
mkdir -p "$(dirname "$PARADOS_ESTADO")"
python3 -I - <<'PY'
import json, os, re, shlex, stat, sys, time

ENV = os.environ
INTERVALO = float(ENV.get("PARADOS_INTERVALO", "300"))
IDADE_MIN = float(ENV.get("PARADOS_IDADE_MIN", "30")) * 60
OCIOSO = float(ENV.get("PARADOS_OCIOSO_MIN", "30")) * 60
OCUPADO = float(ENV.get("PARADOS_OCUPADO_MIN", "60")) * 60
CPU_BAIXA = float(ENV.get("PARADOS_CPU_BAIXA", "0.5"))
CPU_ALTA = float(ENV.get("PARADOS_CPU_ALTA", "80"))
ESTADO = ENV["PARADOS_ESTADO"]
EXC = r"esperar-[A-Za-z0-9_.-]*\.sh|monitor-uso\.py|saude-maquina\.sh|garantir-monitor\.sh|statusline\.py"
if ENV.get("PARADOS_EXCECOES"):
    EXC += "|" + ENV["PARADOS_EXCECOES"]
EXC_RE = re.compile(EXC)
HZ = os.sysconf("SC_CLK_TCK")
UID = os.getuid()
CLAUDE_DIR = os.path.expanduser("~/.local/share/claude/versions/")
SNAPSHOT = "/.claude/shell-snapshots/"
MOTIVOS = {"a": "cwd apagado", "b": "laço de espera que casa a própria linha",
           "c": "CPU quase zero, sem filho nem escrita", "d": "CPU alta contínua sem filho novo"}


def boot():
    with open("/proc/stat") as f:
        for l in f:
            if l.startswith("btime "):
                return int(l.split()[1])


BOOT = boot()


def ler(pid):
    """Lê o que interessa de /proc/<pid>; None se o processo sumiu ou não é do usuário."""
    base = f"/proc/{pid}"
    try:
        if os.stat(base).st_uid != UID:
            return None
        with open(base + "/stat") as f:
            s = f.read()
        campos = s[s.rindex(")") + 2:].split()
        with open(base + "/cmdline", "rb") as f:
            argv = [a.decode("utf-8", "replace") for a in f.read().split(b"\0") if a]
        try:
            exe = os.readlink(base + "/exe")
        except OSError:
            exe = ""
        try:
            cwd = os.readlink(base + "/cwd")
        except OSError:
            cwd = "?"
        with open(base + "/comm") as f:
            comm = f.read().strip()
    except (OSError, ValueError):
        return None
    return {"pid": pid, "ppid": int(campos[1]), "comm": comm, "argv": argv, "exe": exe, "cwd": cwd,
            "self_t": int(campos[11]) + int(campos[12]), "reaped_t": int(campos[13]) + int(campos[14]),
            "inicio": BOOT + int(campos[19]) / HZ}


def ultima_escrita(pid):
    """Maior mtime entre os arquivos normais abertos (fora de /proc, /dev e /sys)."""
    m = 0.0
    d = f"/proc/{pid}/fd"
    try:
        fds = os.listdir(d)[:256]
    except OSError:
        return m
    for fd in fds:
        try:
            alvo = os.readlink(f"{d}/{fd}")
            if alvo.startswith(("/proc", "/dev", "/sys")) or not alvo.startswith("/"):
                continue
            st = os.stat(f"{d}/{fd}")
            if stat.S_ISREG(st.st_mode):
                m = max(m, st.st_mtime)
        except OSError:
            pass
    return m


def eh_claude(p):
    return p["exe"].startswith(CLAUDE_DIR) or p["comm"] == "claude"


def comando_usuario(argv):
    """O comando que o agente digitou: o eval '...' do invólucro do Claude Code, ou o argv inteiro."""
    linha = " ".join(argv)
    if len(argv) >= 3 and SNAPSHOT in argv[2]:
        m = re.search(r"eval '((?:[^']|'\\'')*)'", argv[2])
        if m:
            return m.group(1).replace("'\\''", "'")
    return linha


def curto(txt, n=110):
    txt = re.sub(r"\b([A-Za-z_]*(?:TOKEN|SECRET|PASS|KEY)[A-Za-z_]*)=\S+", r"\1=***", txt, flags=re.I)
    txt = re.sub(r"\s+", " ", txt).strip()
    return txt if len(txt) <= n else txt[: n - 1] + "…"


OPC_COM_ARG = set("uUgGPstdF") | {"--ns", "--nslist", "--signal", "--session", "--terminal", "--parent",
                                   "--pgroup", "--group", "--euid", "--uid", "--pidfile", "--delimiter"}


def laco_autocasante(linha):
    """(b): laço while/until com pgrep/pkill -f ou ps | grep cujo padrão casa a própria linha."""
    if not re.search(r"\b(while|until)\b", linha):
        return None
    for m in re.finditer(r"\b(pgrep|pkill)\b([^;&|)]*)", linha):
        try:
            toks = shlex.split(m.group(2))
        except ValueError:
            toks = m.group(2).split()
        full, pad, pula = False, None, False
        for t in toks:
            if pula:
                pula = False
                continue
            if t.startswith("--"):
                full |= t == "--full"
                pula = t.split("=")[0] in OPC_COM_ARG and "=" not in t
            elif t.startswith("-") and len(t) > 1:
                full |= "f" in t[1:]
                pula = t[-1] in OPC_COM_ARG
            else:
                pad = t
                break
        if not full or pad is None:
            continue
        if "$" in pad or "`" in pad:
            return f"{m.group(1)} -f com padrão variável ({curto(pad, 30)}), provável autocasamento"
        try:
            if re.search(pad, linha):
                return f"{m.group(1)} -f '{curto(pad, 30)}' casa a própria linha"
        except re.error:
            if pad in linha:
                return f"{m.group(1)} -f '{curto(pad, 30)}' casa a própria linha"
    for m in re.finditer(r"\bps\b[^;&|]*\|\s*grep\b([^;&|)]*)", linha):
        resto = linha[m.end():m.end() + 40]
        if re.search(r"grep\s+-v\s+grep", m.group(0) + resto):
            continue
        try:
            toks = [t for t in shlex.split(m.group(1)) if not t.startswith("-")]
        except ValueError:
            toks = [t for t in m.group(1).split() if not t.startswith("-")]
        pad = toks[0] if toks else ""
        try:
            casa = (not pad) or "$" in pad or re.search(pad, linha)
        except re.error:
            casa = pad in linha
        if casa:
            return f"ps | grep '{curto(pad, 30)}' casa a própria linha"
    return None


def idade_txt(s):
    s = int(s)
    if s < 60:
        return f"{s}s"
    return f"{s // 3600}h{s % 3600 // 60:02d}" if s >= 3600 else f"{s // 60}min"


def carregar():
    try:
        with open(ESTADO) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def gravar(est):
    tmp = ESTADO + ".tmp"
    with open(tmp, "w") as f:
        json.dump(est, f)
    os.replace(tmp, ESTADO)


def olhar(est):
    agora = time.time()
    procs = {}
    for nome in os.listdir("/proc"):
        if nome.isdigit():
            p = ler(int(nome))
            if p:
                procs[p["pid"]] = p
    filhos = {}
    for p in procs.values():
        filhos.setdefault(p["ppid"], []).append(p["pid"])
    # O próprio vigia e os seus ancestrais nunca entram.
    meus = set()
    q = os.getpid()
    while q > 1:
        meus.add(q)
        try:
            with open(f"/proc/{q}/stat") as f:
                s = f.read()
            q = int(s[s.rindex(")") + 2:].split()[1])
        except (OSError, ValueError):
            break

    def descendentes(pid):
        out, pilha = [], list(filhos.get(pid, []))
        while pilha:
            c = pilha.pop()
            out.append(c)
            pilha.extend(filhos.get(c, []))
        return out

    novo_est, suspeitos, examinados = {}, [], 0
    for p in procs.values():
        pid = p["pid"]
        if pid in meus or eh_claude(p):
            continue
        # Escopo: um ancestral do Claude Code, ou um invólucro de comando do Claude Code órfão.
        cadeia, raiz, q, exc = [], None, p, False
        while q is not None:
            cadeia.append(q)
            if q is not p and eh_claude(q):
                raiz = q["pid"]
                break
            q = procs.get(q["ppid"])
        if raiz is None and not any(c["argv"][2:3] and SNAPSHOT in c["argv"][2] for c in cadeia if len(c["argv"]) >= 3):
            continue
        if any(EXC_RE.search(" ".join(c["argv"])) for c in cadeia):
            continue
        idade = agora - p["inicio"]
        if idade < IDADE_MIN:
            continue
        examinados += 1
        desc = [procs[d] for d in descendentes(pid) if d in procs]
        sub_t = p["self_t"] + p["reaped_t"] + sum(d["self_t"] + d["reaped_t"] for d in desc)
        caçula = max((d["inicio"] for d in desc), default=0.0)
        escrita = max([ultima_escrita(pid)] + [ultima_escrita(d["pid"]) for d in desc])
        k = f"{pid}:{int(p['inicio'])}"
        ant = est.get(k)
        e = {"ts": agora, "self_t": p["self_t"], "reaped_t": p["reaped_t"], "sub_t": sub_t,
             "avisado": ant.get("avisado", False) if ant else False}
        medido, ocioso, alto = False, False, False
        cpu_txt = "1ª olhada"
        if ant:
            dt = max(agora - ant["ts"], 1.0)
            pct_sub = max(sub_t - ant["sub_t"], 0) / HZ / dt * 100
            pct_self = max(p["self_t"] - ant["self_t"], 0) / HZ / dt * 100
            filho_novo = caçula > ant["ts"] or p["reaped_t"] > ant["reaped_t"]
            ocioso = pct_sub < CPU_BAIXA and not filho_novo and escrita <= ant["ts"]
            alto = pct_self >= CPU_ALTA and not filho_novo
            e["ocioso_desde"] = ant.get("ocioso_desde", agora) if ocioso else agora
            e["ocupado_desde"] = (ant.get("ocupado_desde") or ant["ts"]) if alto else None
            medido = True
            cpu_txt = f"CPU {pct_self:.1f}% (árvore {pct_sub:.1f}%) em {idade_txt(dt)}"
        else:
            # Estimativa pela vida inteira; só vale se a próxima olhada medir o mesmo.
            media_sub = sub_t / HZ / idade * 100
            media_self = p["self_t"] / HZ / idade * 100
            e["ocioso_desde"] = max(p["inicio"], caçula, escrita) if media_sub < CPU_BAIXA else agora
            e["ocupado_desde"] = max(p["inicio"], caçula) if media_self >= CPU_ALTA else None
        motivos = []
        if p["cwd"].endswith("(deleted)"):
            motivos.append(("a", ""))
        b = laco_autocasante(comando_usuario(p["argv"]))
        if b:
            motivos.append(("b", b))
        if medido and ocioso and agora - e["ocioso_desde"] >= OCIOSO:
            motivos.append(("c", f"ocioso há {idade_txt(agora - e['ocioso_desde'])}"))
        if medido and alto and e["ocupado_desde"] and agora - e["ocupado_desde"] >= OCUPADO:
            motivos.append(("d", f"ocupado há {idade_txt(agora - e['ocupado_desde'])}"))
        if motivos and not e["avisado"]:
            e["avisado"] = True
            suspeitos.append((p, idade, motivos, cpu_txt, raiz))
        novo_est[k] = e
    return novo_est, suspeitos, examinados


def relatorio(suspeitos, examinados):
    print(f"PROCESSOS PARADOS: {len(suspeitos)} suspeito(s) novo(s) entre {examinados} processo(s) de agentes "
          f"com mais de {idade_txt(IDADE_MIN)}. Nada foi morto; avalie e mate pelo PID ou mantenha.")
    for p, idade, motivos, cpu_txt, raiz in sorted(suspeitos, key=lambda s: -s[1]):
        mt = "; ".join(f"({m}) {MOTIVOS[m]}" + (f": {x}" if x else "") for m, x in motivos)
        sessao = f"sessão {raiz}" if raiz else "órfão"
        print(f"- PID {p['pid']} · {idade_txt(idade)} · {mt} · {cpu_txt} · pai {p['ppid']} ({sessao})")
        print(f"    cmd: {curto(comando_usuario(p['argv']))}")
        print(f"    cwd: {p['cwd']}")
        print(f"    matar: kill {p['pid']}")


while True:
    est, suspeitos, examinados = olhar(carregar())
    gravar(est)
    if suspeitos:
        relatorio(suspeitos, examinados)
        sys.exit(0)
    time.sleep(INTERVALO)
PY
