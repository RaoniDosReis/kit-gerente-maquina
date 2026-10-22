#!/usr/bin/env python3
"""Automação dos processos parados (serviço do usuário `parados-auto`).

Um só processo para a máquina inteira: a cada PARADOS_INTERVALO s (padrão 300) examina os processos do usuário que
descendem de um processo do Claude Code (sessões, subagentes e os comandos que eles deixaram) ou que são invólucros
de comando do Claude Code órfãos, e decide sozinho pela política abaixo, combinada com os orquestradores dos projetos. O que precisa de julgamento vai numa linha para `parados-escalados.log`, que o agente zelador de
processos (sonnet, gerido pela sessão gerente) espera com `esperar-zelador.sh`.

Política (só processos com mais de PARADOS_IDADE_MIN min, padrão 30):
  PROTEGIDOS, nunca mortos nem avisados: os vigias (esperar-*.sh, vez-opus.sh, monitor-uso.py, saude-maquina.sh,
    garantir-monitor.sh, statusline.py, parados-auto.py); `gh run watch` e os laços de `gh run view`; a árvore do
    `scripts/verify.sh` (pytest, xdist, navegadores, node, docker compose...); `llama-server`; mais as regex de
    PARADOS_EXCECOES / KIT_PARADOS_EXCECOES (rodadas de GPU, benchmarks do projeto etc.). A regex vale no comando do
    processo, de um ancestral ou de um descendente. Com a cwd num worktree (`/worktrees/`) que ainda existe, o
    processo também é protegido, salvo pelo motivo (b).
  MATA SOZINHO (TERM na árvore; KILL 10 s depois no que sobrar; confere antes o instante de início do PID):
    (a) cwd apagada;
    (b) laço while/until com pgrep -f, pkill -f ou "ps | grep" cujo padrão casa a própria linha (nunca termina);
    (c) de projeto em KIT_PARADOS_MATA_OCIOSO (padrão: o 1º de KIT_PROJETOS), ocioso há PARADOS_OCIOSO_MIN min
        (padrão 120) e com a cwd fora de um repositório git existente.
  ESCALA ao agente (DECIDIR): (a) de um processo protegido; (c) dos demais projetos, de outra sessão ou com a cwd num
    repositório existente; (d) CPU alta contínua há PARADOS_OCUPADO_MIN min (padrão 60); (e) `verify.sh` rodando há
    mais de PARADOS_VERIFY_MIN min (padrão 120: travado; avisar, não matar).
  INFORMA o dono (o agente repassa uma linha): morte de um processo com a cwd num repositório que ainda existe.
  FALHA: o processo sobreviveu ao KILL ou a morte deu erro.

Modos: (sem argumento) serviço; `--uma-vez` uma olhada; `--seco` uma olhada sem matar nem gravar estado, que só
imprime o que faria. Registros em $KIT_CACHE/: parados-auto.log (cada decisão),
parados-escalados.log (para o agente), parados-auto-estado.json (com a batida `batida`, para o vigia saber que o
serviço vive). Cada morte vai também em $KIT_REGISTRO. Só lê /proc; não imprime ambiente, e
no comando curto os valores de variáveis com TOKEN, SECRET, PASS ou KEY no nome viram "***".
"""
import fcntl, json, os, re, shlex, signal, stat, subprocess, sys, time

sys.path.insert(0, os.path.expanduser("~/.claude/skills/gerente-da-maquina/lib"))
sys.path.insert(1, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "gerente-da-maquina", "lib"))
import kit_config as K

ENV = os.environ


def num(nome, padrao, escala=60.0):
    """PARADOS_<nome>_S (segundos, para provas) tem precedência sobre PARADOS_<nome>_MIN."""
    if ENV.get(f"PARADOS_{nome}_S"):
        return float(ENV[f"PARADOS_{nome}_S"])
    return float(ENV.get(f"PARADOS_{nome}_MIN", padrao)) * escala


INTERVALO = float(ENV.get("PARADOS_INTERVALO", "300"))
IDADE_MIN = num("IDADE", 30)
OCIOSO = num("OCIOSO", 120)
OCUPADO = num("OCUPADO", 60)
VERIFY_MAX = num("VERIFY", 120)
ESPERA_KILL = float(ENV.get("PARADOS_ESPERA_KILL", "10"))
CPU_BAIXA = float(ENV.get("PARADOS_CPU_BAIXA", "0.5"))
CPU_ALTA = float(ENV.get("PARADOS_CPU_ALTA", "80"))
DIR = os.path.expanduser(ENV.get("PARADOS_DIR", K.cfg["KIT_CACHE"]))
ESTADO = os.path.join(DIR, "parados-auto-estado.json")
LOG = os.path.join(DIR, "parados-auto.log")
ESCALADOS = os.path.join(DIR, "parados-escalados.log")
MUDANCAS = os.path.expanduser(ENV.get("PARADOS_MUDANCAS", K.cfg["KIT_REGISTRO"]))
# Só para provas: limita o escopo às cadeias cujo comando casa esta regex.
FILTRO = re.compile(ENV["PARADOS_FILTRO"]) if ENV.get("PARADOS_FILTRO") else None

PROTEGIDOS = (r"esperar-[A-Za-z0-9_.-]*\.sh|vez-opus\.sh|monitor-uso\.py|saude-maquina\.sh|garantir-monitor\.sh"
              r"|statusline\.py|parados-auto\.py"
              r"|\bgh run (watch|view)\b"                      # espera legítima pela CI
              r"|scripts/verify\.sh"                          # verificação longa do projeto e toda a árvore
              r"|llama-server")                               # servidor de modelo local: pouca CPU, de propósito
for _x in (ENV.get("PARADOS_EXCECOES"), ENV.get("KIT_PARADOS_EXCECOES") or K.cfg.get("KIT_PARADOS_EXCECOES")):
    if _x:  # regex extra de processos protegidos (rodadas de GPU, benchmarks etc.), do kit.conf
        PROTEGIDOS += "|" + _x
_MATA = (ENV.get("KIT_PARADOS_MATA_OCIOSO") or K.cfg.get("KIT_PARADOS_MATA_OCIOSO") or "").split()
if not _MATA and K.projetos():
    _MATA = [K.projetos()[0][0]]  # padrão: só o 1º projeto tem o ocioso fora de repositório morto sozinho
PROT_RE = re.compile(PROTEGIDOS)
VERIFY_RE = re.compile(r"(^|/)verify\.sh$")
HZ = os.sysconf("SC_CLK_TCK")
UID = os.getuid()
CLAUDE_DIR = os.path.expanduser("~/.local/share/claude/versions/")
SNAPSHOT = "/.claude/shell-snapshots/"
MOTIVOS = {"a": "cwd apagada", "b": "laço de espera que casa a própria linha",
           "c": "CPU quase zero, sem filho nem escrita", "d": "CPU alta contínua sem filho novo",
           "e": "verify.sh rodando além do prazo"}


def agora_iso():
    return time.strftime("%Y-%m-%dT%H:%M:%S%z")


def anexar(caminho, linha):
    os.makedirs(os.path.dirname(caminho), exist_ok=True)
    with open(caminho, "a") as f:
        f.write(linha + "\n")


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


def inicio_de(pid):
    p = ler(pid)
    return p["inicio"] if p else None


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


_repo_cache = {}


def repositorio(cwd):
    """Raiz do repositório/worktree git que contém a cwd, se ainda existe; '' se não há."""
    if cwd in _repo_cache:
        return _repo_cache[cwd]
    r = ""
    if cwd.startswith("/") and not cwd.endswith("(deleted)") and os.path.isdir(cwd):
        try:
            out = subprocess.run(["git", "-C", cwd, "rev-parse", "--show-toplevel"], capture_output=True,
                                 text=True, timeout=10, env={**ENV, "GIT_OPTIONAL_LOCKS": "0"})
            r = out.stdout.strip() if out.returncode == 0 else ""
        except (OSError, subprocess.SubprocessError):
            r = "?"  # na dúvida, trata como repositório existente (não mata)
    _repo_cache[cwd] = r
    return r


def projeto(p, raiz_p):
    """Nome do projeto (KIT_PROJETOS) cuja pasta contém a cwd da sessão dona (senão, a do processo); senão 'outra (...)'."""
    for cwd in ([raiz_p["cwd"]] if raiz_p else []) + [p["cwd"]]:
        real = os.path.realpath(cwd) if cwd.startswith("/") and not cwd.endswith("(deleted)") else cwd
        for nome, d, _ in K.projetos():
            d = os.path.realpath(d)
            if real == d or real.startswith(d + os.sep):
                return nome
    return f"outra ({raiz_p['cwd'] if raiz_p else 'órfão'})"


def carregar():
    try:
        with open(ESTADO) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def gravar(est):
    os.makedirs(DIR, exist_ok=True)
    tmp = ESTADO + ".tmp"
    with open(tmp, "w") as f:
        json.dump(est, f)
    os.replace(tmp, ESTADO)


def matar(p, desc):
    """TERM no processo e nos descendentes; KILL depois de ESPERA_KILL s no que sobrar. Devolve (ok, detalhe)."""
    alvos = [(p["pid"], p["inicio"])] + [(d["pid"], d["inicio"]) for d in desc]
    if inicio_de(p["pid"]) != p["inicio"]:
        return True, "já tinha terminado"
    for pid, ini in alvos:
        if inicio_de(pid) == ini:
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            except OSError as e:
                return False, f"TERM falhou: {e}"
    fim = time.time() + ESPERA_KILL
    while time.time() < fim and any(inicio_de(pid) == ini for pid, ini in alvos):
        time.sleep(0.2)
    usou_kill = False
    for pid, ini in alvos:
        if inicio_de(pid) == ini:
            usou_kill = True
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            except OSError as e:
                return False, f"KILL falhou: {e}"
    time.sleep(0.5)
    vivos = [pid for pid, ini in alvos if inicio_de(pid) == ini and not zumbi(pid)]
    if vivos:
        return False, f"sobreviveram ao KILL: {vivos}"
    return True, "KILL" if usou_kill else "TERM"


def zumbi(pid):
    try:
        with open(f"/proc/{pid}/stat") as f:
            s = f.read()
        return s[s.rindex(")") + 2] == "Z"
    except (OSError, ValueError):
        return True


def olhar(est, seco=False):
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
    meus = set()
    q = os.getpid()
    while q > 1:
        meus.add(q)
        q = procs[q]["ppid"] if q in procs else 1

    def descendentes(pid):
        out, pilha = [], list(filhos.get(pid, []))
        while pilha:
            c = pilha.pop()
            out.append(c)
            pilha.extend(filhos.get(c, []))
        return out

    novo_est, eventos, examinados = {}, [], 0
    for p in procs.values():
        pid = p["pid"]
        if pid in meus or eh_claude(p) or pid not in procs:
            continue
        cadeia, raiz_p, q = [], None, p
        while q is not None:
            cadeia.append(q)
            if q is not p and eh_claude(q):
                raiz_p = q
                break
            q = procs.get(q["ppid"])
        if raiz_p is None and not any(len(c["argv"]) >= 3 and SNAPSHOT in c["argv"][2] for c in cadeia):
            continue
        if FILTRO and not any(FILTRO.search(" ".join(c["argv"])) for c in cadeia):
            continue
        idade = agora - p["inicio"]
        if idade < IDADE_MIN:
            continue
        examinados += 1
        desc = [procs[d] for d in descendentes(pid) if d in procs]
        cmd = comando_usuario(p["argv"])
        eh_verify = bool(p["argv"]) and any(VERIFY_RE.search(a) for a in p["argv"][:2]) and "-c" not in p["argv"][:2]
        acima = cadeia[1:-1] if raiz_p else cadeia[1:]  # ancestrais, sem o processo do Claude Code
        protegido = any(PROT_RE.search(" ".join(c["argv"])) for c in acima + desc) or \
            (PROT_RE.search(" ".join(p["argv"])) and not eh_verify)
        proj = projeto(p, raiz_p)
        repo = repositorio(p["cwd"])
        if "/worktrees/" in (repo or ""):
            protegido = True  # worktree de agente que ainda existe
        sub_t = p["self_t"] + p["reaped_t"] + sum(d["self_t"] + d["reaped_t"] for d in desc)
        caçula = max((d["inicio"] for d in desc), default=0.0)
        escrita = max([ultima_escrita(pid)] + [ultima_escrita(d["pid"]) for d in desc])
        k = f"{pid}:{int(p['inicio'])}"
        ant = est.get(k)
        e = {"ts": agora, "self_t": p["self_t"], "reaped_t": p["reaped_t"], "sub_t": sub_t,
             "feito": ant.get("feito", False) if ant else False}
        medido, ocioso, alto = False, False, False
        cpu_txt = "1ª olhada"
        if ant:
            dt = max(agora - ant["ts"], 0.001)
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
            media_sub = sub_t / HZ / idade * 100
            media_self = p["self_t"] / HZ / idade * 100
            e["ocioso_desde"] = max(p["inicio"], caçula, escrita) if media_sub < CPU_BAIXA else agora
            e["ocupado_desde"] = max(p["inicio"], caçula) if media_self >= CPU_ALTA else None
        motivos = []
        if p["cwd"].endswith("(deleted)"):
            motivos.append(("a", ""))
        b = laco_autocasante(cmd)
        if b:
            motivos.append(("b", b))
        if medido and ocioso and agora - e["ocioso_desde"] >= OCIOSO:
            motivos.append(("c", f"ociosa há {idade_txt(agora - e['ocioso_desde'])}"))
        if medido and alto and e["ocupado_desde"] and agora - e["ocupado_desde"] >= OCUPADO:
            motivos.append(("d", f"ocupada há {idade_txt(agora - e['ocupado_desde'])}"))
        if eh_verify and idade >= VERIFY_MAX:
            motivos.append(("e", f"rodando há {idade_txt(idade)}"))
        novo_est[k] = e
        if not motivos or e["feito"]:
            continue
        letras = {m for m, _ in motivos}
        if "b" in letras and not any(re.search(r"esperar-|vez-opus", " ".join(c["argv"])) for c in [p] + acima):
            acao = "matar"
        elif "a" in letras:
            acao = "decidir" if protegido else "matar"
        elif protegido and letras <= {"c", "d"}:
            acao = None  # espera legítima: nem mata nem avisa
        elif "e" in letras or "d" in letras:
            acao = "decidir"
        elif "c" in letras:
            acao = "matar" if proj in _MATA and not repo else "decidir"
        else:
            acao = None
        if acao is None:
            continue
        e["feito"] = True
        eventos.append({"p": p, "desc": desc, "idade": idade, "motivos": motivos, "cpu": cpu_txt,
                        "proj": proj, "repo": repo, "acao": acao, "raiz": raiz_p["pid"] if raiz_p else None,
                        "acima": {c["pid"] for c in acima}})
    # Um evento por árvore: o filho de um processo que já tem evento sai junto com ele (matar leva os descendentes).
    com_evento = {ev["p"]["pid"] for ev in eventos}
    eventos = [ev for ev in eventos if not ev["acima"] & com_evento]
    return novo_est, eventos, examinados


def linha_evento(ev, extra=""):
    p = ev["p"]
    mt = "; ".join(f"({m}) {MOTIVOS[m]}" + (f": {x}" if x else "") for m, x in ev["motivos"])
    sessao = f"sessão {ev['raiz']}" if ev["raiz"] else "órfão"
    return (f"PID {p['pid']} · {idade_txt(ev['idade'])} · {ev['proj']} · {mt} · {ev['cpu']} · pai {p['ppid']} "
            f"({sessao}){extra} · cmd: {curto(comando_usuario(p['argv']))} · cwd: {p['cwd']}"
            + (f" · repo: {ev['repo']}" if ev["repo"] else ""))


def agir(eventos, seco=False):
    for ev in eventos:
        ts = agora_iso()
        if seco:
            print(f"[seco] {ev['acao'].upper()} {linha_evento(ev)}")
            continue
        if ev["acao"] == "decidir":
            l = linha_evento(ev)
            anexar(ESCALADOS, f"{ts} DECIDIR {l}")
            anexar(LOG, f"{ts} escalado: {l}")
            continue
        ok, det = matar(ev["p"], ev["desc"])
        l = linha_evento(ev, f" · {det}")
        if not ok:
            anexar(ESCALADOS, f"{ts} FALHA ao matar: {l}")
            anexar(LOG, f"{ts} FALHA: {l}")
            continue
        anexar(LOG, f"{ts} morto: {l}")
        anexar(MUDANCAS, f"{ts} parados-auto: matou {l}. Desfazer: não se aplica (processo parado; o dono roda "
                         f"de novo se precisar)")
        if ev["repo"]:
            anexar(ESCALADOS, f"{ts} INFORMAR {ev['proj']} morto: {l}")


def uma_volta(seco=False):
    est = carregar()
    novo, eventos, examinados = olhar(est.get("processos", {}), seco)
    agir(eventos, seco)
    if not seco:
        gravar({"batida": time.time(), "examinados": examinados, "processos": novo})
    return eventos, examinados


def autoteste():
    """Cenários com processos de verdade, sob dois Claude falsos (bash com o nome claude), num escopo filtrado."""
    import shutil, tempfile
    base = K.cfg["KIT_CACHE"]
    os.makedirs(base, exist_ok=True)
    T = tempfile.mkdtemp(prefix="autoteste-parados-", dir=base)
    falhas, pids_sessoes = [], []
    try:
        claude = os.path.join(T, "claude")
        os.symlink("/bin/bash", claude)
        for d in ("PROJA/semrepo", "PROJA/repo/scripts", "PROJB/x", "worktrees/wt-a", "del"):
            os.makedirs(os.path.join(T, d))
        for r in ("PROJA/repo", "worktrees/wt-a"):
            subprocess.run(["git", "init", "-q", os.path.join(T, r)], check=True)
        with open(os.path.join(T, "PROJA/repo/scripts/verify.sh"), "w") as f:
            f.write("sleep 100004\n")
        q = shlex.quote
        cenarios = {  # nome: (pasta, comando, esperado: morto | vivo)
            "b": ("PROJA/semrepo", "bash -c 'until ! pgrep -f zzqq_b; do sleep 0.3; done'", "morto"),
            "b_repo": ("PROJA/repo", "bash -c 'until ! pgrep -f zzqq_br; do sleep 0.3; done'", "morto"),
            "a": ("del", "bash -c 'sleep 100001; : zzqq_a'", "morto"),
            "c_fora": ("PROJA/semrepo", "bash -c 'sleep 100002; : zzqq_c'", "morto"),
            "c_repo": ("PROJA/repo", "bash -c 'sleep 100012; : zzqq_cr'", "vivo"),
            "protegido": ("PROJA/semrepo", "bash -c 'gh run watch 1 2>/dev/null; sleep 100003; : zzqq_p'", "vivo"),
            "d": ("PROJA/semrepo", "bash -c 'while :; do :; done; : zzqq_d'", "vivo"),
            "verify": ("PROJA/repo", "bash scripts/verify.sh zzqq_v", "vivo"),
        }
        cenarios_proj = {
            "proj_c": ("PROJB/x", "bash -c 'sleep 100006; : zzqq_sx'", "vivo"),
            "proj_wt": ("worktrees/wt-a", "bash -c 'sleep 100007; : zzqq_sw'", "vivo"),
        }
        pidfile = os.path.join(T, "pids")

        def sessao(pasta, cen):
            linhas = [f"(cd {q(os.path.join(T, d))} && exec {c}) & echo {n}=$! >> {q(pidfile)}"
                      for n, (d, c, _) in cen.items()]
            return subprocess.Popen([claude, "-c", "\n".join(linhas) + "\nwait"], cwd=os.path.join(T, pasta),
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        pids_sessoes += [sessao("PROJA", cenarios), sessao("PROJB", cenarios_proj)]
        # Órfão fora do escopo: reparentado ao init/subreaper, sem invólucro do Claude Code.
        subprocess.run(["bash", "-c", "setsid bash -c 'sleep 100005; : zzqq_o' </dev/null >/dev/null 2>&1 &"])
        time.sleep(1.5)
        os.rmdir(os.path.join(T, "del"))
        pids = dict(l.strip().split("=") for l in open(pidfile))
        env = {**ENV, "KIT_CONF": os.path.join(T, "sem.conf"), "KIT_PROJETOS": f"PROJA:{T}/PROJA PROJB:{T}/PROJB", "KIT_PARADOS_MATA_OCIOSO": "PROJA", "PARADOS_FILTRO": "zzqq", "PARADOS_DIR": os.path.join(T, "estado"),
               "PARADOS_MUDANCAS": os.path.join(T, "mudancas.log"), "PARADOS_IDADE_S": "1",
               "PARADOS_OCIOSO_S": "2", "PARADOS_OCUPADO_S": "2", "PARADOS_VERIFY_S": "2",
               "PARADOS_ESPERA_KILL": "2"}
        for _ in range(3):
            subprocess.run([sys.executable, "-I", os.path.abspath(__file__), "--uma-vez"], env=env, check=True)
            time.sleep(3)
        tudo = {**cenarios, **cenarios_proj}
        for n, (_, _, esperado) in tudo.items():
            vivo = os.path.exists(f"/proc/{pids[n]}") and not zumbi(int(pids[n]))
            if (esperado == "vivo") != vivo:
                falhas.append(f"{n}: esperado {esperado}, ficou {'vivo' if vivo else 'morto'}")
        orfao = subprocess.run(["pgrep", "-fx", "sleep 100005"], capture_output=True, text=True).stdout.split()
        if not orfao:
            falhas.append("órfão fora do escopo: foi morto")
        esc = open(os.path.join(T, "estado", "parados-escalados.log")).read() if os.path.exists(
            os.path.join(T, "estado", "parados-escalados.log")) else ""
        esperado_esc = {"zzqq_cr": "DECIDIR", "zzqq_d": "DECIDIR", "zzqq_v": "DECIDIR", "zzqq_sx": "DECIDIR",
                        "zzqq_br": "INFORMAR PROJA"}
        for marca, tipo in esperado_esc.items():
            linhas = [l for l in esc.splitlines() if marca in l]
            if len(linhas) != 1 or tipo not in linhas[0]:
                falhas.append(f"escalado {marca}: esperado 1 linha {tipo}, veio {len(linhas)}: {linhas[:1]}")
        for marca in ("zzqq_p", "zzqq_sw", "zzqq_c'", "zzqq_a", "zzqq_b'"):
            if any(marca in l for l in esc.splitlines() if "DECIDIR" in l or "FALHA" in l):
                falhas.append(f"escalado indevido: {marca}")
        mortes = open(os.path.join(T, "mudancas.log")).read().count("parados-auto: matou")
        if mortes != 4:
            falhas.append(f"mudancas-sistema: esperadas 4 mortes, vieram {mortes}")
    finally:
        for s in pids_sessoes:
            for pid in descendentes_vivos(s.pid):
                try:
                    os.kill(pid, signal.SIGKILL)
                except OSError:
                    pass
            s.kill()
        for pid in subprocess.run(["pgrep", "-fx", "sleep 100005"], capture_output=True, text=True).stdout.split():
            os.kill(int(pid), signal.SIGKILL)
        shutil.rmtree(T, ignore_errors=True)
    print("autoteste: " + ("OK (10 cenários + órfão fora do escopo)" if not falhas else "FALHOU"))
    for f in falhas:
        print("  - " + f)
    sys.exit(1 if falhas else 0)


def descendentes_vivos(raiz):
    filhos = {}
    for nome in os.listdir("/proc"):
        if nome.isdigit():
            p = ler(int(nome))
            if p:
                filhos.setdefault(p["ppid"], []).append(p["pid"])
    out, pilha = [], list(filhos.get(raiz, []))
    while pilha:
        c = pilha.pop()
        out.append(c)
        pilha.extend(filhos.get(c, []))
    return out


def main():
    if "--autoteste" in sys.argv:
        autoteste()
    seco = "--seco" in sys.argv
    if seco or "--uma-vez" in sys.argv:
        eventos, n = uma_volta(seco)
        if seco:
            print(f"[seco] {n} processo(s) de agentes examinados; {len(eventos)} ação(ões).")
        return
    os.makedirs(DIR, exist_ok=True)
    trava = open(os.path.join(DIR, "parados-auto.lock"), "w")
    try:
        fcntl.flock(trava, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        print("outra instância do parados-auto já roda", file=sys.stderr)
        sys.exit(1)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    anexar(LOG, f"{agora_iso()} serviço iniciado (intervalo {int(INTERVALO)} s)")
    while True:
        try:
            uma_volta()
        except Exception as e:  # um erro numa olhada não derruba o serviço; o vigia vê a batida parar se repetir
            anexar(LOG, f"{agora_iso()} ERRO na olhada: {type(e).__name__}: {e}")
        _repo_cache.clear()
        time.sleep(INTERVALO)


if __name__ == "__main__":
    main()
