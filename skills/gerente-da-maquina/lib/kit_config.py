"""Configuração do kit para scripts python.

    sys.path.insert(0, os.path.expanduser("~/.claude/skills/gerente-da-maquina/lib")); import kit_config as K
Lê ~/.config/gerente-maquina/kit.conf (KEY=VALUE, o mesmo arquivo do kit.sh) e aplica os padrões.
"""
import glob
import os
import re
import shlex
import shutil
import subprocess
import sys
import time

HOME = os.path.expanduser("~")
PADROES = {
    "KIT_DONO": "o dono", "KIT_GERENTE": "Gerente", "KIT_GERENTE_TMUX": "gerente", "KIT_GERENTE_DIR": HOME,
    "KIT_PROJETOS": "", "KIT_CACHE": os.path.join(HOME, ".cache", "gerente-maquina"), "KIT_MODO": "auto",
    "KIT_REGISTRO": "", "KIT_META_SEMANA": "95", "KIT_ORCAMENTO_MAX": "3", "KIT_BASTAO_PROPORCAO": "2",
    "KIT_TETO_AGENTES": "5", "KIT_TETO_AGENTES_CARGA": "3", "KIT_CARGA_ALTA": "24",
    "KIT_TERM_ATIVA": "1", "KIT_CI_PADRAO": "Runner.Worker", "KIT_TERM_TETO_INICIAL": "60", "KIT_TERM_SOBE_C": "70",
    "KIT_TERM_DESCE_C": "80", "KIT_TERM_CRITICO_C": "90", "KIT_TERM_CALOR_C": "80", "KIT_FAN_BOOST": "",
    "KIT_PASSAGEM_AVISO_K": "200000", "KIT_PASSAGEM_CAUTION_K": "250000", "KIT_PASSAGEM_WARNING_K": "275000",
    "KIT_PASSAGEM_CLEAR_K": "300000", "KIT_PASSAGEM_TETO_K": "330000", "KIT_COMPACT_REDE": "360000",
    "KIT_AGENTE_AVISO_K": "150000", "KIT_AGENTE_COMPACT": "200000", "KIT_API_LIMITE": "2",
    "KIT_GPU": "auto", "KIT_CI_ROTULOS": "", "KIT_TERM_WINDOWS": "0",
    "KIT_ZELADOR": "zelador", "KIT_ZELADOR_MODELO": "sonnet", "KIT_ZELADOR_MODO": "auto", "KIT_VIGIA_FORA_S": "300",
}


def _ler(caminho):
    valores = {}
    try:
        linhas = open(caminho, encoding="utf-8").read().splitlines()
    except OSError:
        return valores
    for linha in linhas:
        linha = linha.strip()
        if not linha or linha.startswith("#") or "=" not in linha:
            continue
        chave, valor = linha.split("=", 1)
        chave = chave.replace("export", "").strip()
        try:
            partes = shlex.split(valor, comments=True)
        except ValueError:
            partes = [valor]
        valores[chave] = os.path.expandvars(os.path.expanduser(" ".join(partes)))
    return valores


CONF = os.environ.get("KIT_CONF", os.path.join(HOME, ".config", "gerente-maquina", "kit.conf"))
cfg = dict(PADROES)
cfg.update(_ler(CONF))
for _k in PADROES:  # o ambiente vale mais que o arquivo (útil nos testes)
    if _k in os.environ:
        cfg[_k] = os.environ[_k]
if not cfg["KIT_REGISTRO"]:
    cfg["KIT_REGISTRO"] = os.path.join(cfg["KIT_CACHE"], "mudancas-sistema.log")


def plataforma():
    """linux | wsl | windows | macos | outro (KIT_PLATAFORMA força; mesma regra do plataforma.sh)."""
    if os.environ.get("KIT_PLATAFORMA"):
        return os.environ["KIT_PLATAFORMA"]
    if os.name == "nt" or sys.platform.startswith(("cygwin", "msys")):
        return "windows"
    if sys.platform == "darwin":
        return "macos"
    try:
        with open(os.path.join(os.environ.get("KIT_PROC", "/proc"), "version")) as f:
            return "wsl" if "microsoft" in f.read().lower() else "linux"
    except OSError:
        return "linux" if sys.platform.startswith("linux") else "outro"


def gpu():
    """nvidia | amd | intel | nenhuma. KIT_GPU (kit.conf ou ambiente) força; auto detecta como o plataforma.sh."""
    g = cfg.get("KIT_GPU", "auto")
    if g in ("nvidia", "amd", "intel", "nenhuma"):
        return g
    smi = os.environ.get("KIT_NVIDIA_SMI", "nvidia-smi")
    if shutil.which(smi):
        try:
            if subprocess.run([smi, "-L"], capture_output=True, text=True, timeout=5).stdout.strip():
                return "nvidia"
        except (OSError, subprocess.SubprocessError):
            pass
    if shutil.which(os.environ.get("KIT_ROCM_SMI", "rocm-smi")):
        return "amd"
    achou = ""
    for c in sorted(glob.glob(os.path.join(os.environ.get("KIT_DRM_DIR", "/sys/class/drm"), "card*"))):
        if "-" in os.path.basename(c):
            continue
        try:
            v = open(os.path.join(c, "device", "vendor")).read().strip()
        except OSError:
            continue
        if v == "0x10de":
            return "nvidia"
        if v == "0x1002":
            achou = "amd"
        elif v == "0x8086" and not achou:
            achou = "intel"
    return achou or "nenhuma"


def caminho(p):
    """No Python do Windows, /c/Users/x (do Git Bash) vira C:/Users/x; nos outros, o mesmo."""
    p = os.path.expanduser(p)
    if os.name == "nt":
        m = re.match(r"^/([A-Za-z])(/.*)?$", p)
        if m:
            p = m.group(1).upper() + ":" + (m.group(2) or "/")
    return p


def num(chave):
    return float(cfg[chave])


def projetos():
    """[(nome, dir, sessão tmux)] na ordem do kit.conf; o 1º é o prioritário."""
    saida = []
    for item in cfg["KIT_PROJETOS"].split():
        partes = item.split(":")
        nome, pasta = partes[0], (partes[1] if len(partes) > 1 else "")
        tmux = partes[2] if len(partes) > 2 and partes[2] else nome.lower()
        saida.append((nome, caminho(pasta), tmux))
    return saida


def sessao_de_dir(pasta):
    """Diretório -> nome da sessão (o gerente ou um projeto) ou ''."""
    real = os.path.realpath(caminho(pasta))
    if real == os.path.realpath(caminho(cfg["KIT_GERENTE_DIR"])):
        return cfg["KIT_GERENTE"]
    for nome, d, _ in projetos():
        if real == os.path.realpath(d):
            return nome
    return ""


def registrar(texto):
    os.makedirs(os.path.dirname(cfg["KIT_REGISTRO"]), exist_ok=True)
    with open(cfg["KIT_REGISTRO"], "a", encoding="utf-8") as f:
        f.write(time.strftime("%Y-%m-%dT%H:%M:%S%z") + " " + texto + "\n")


def codifica_dir(pasta):
    """Nome que o Claude Code dá à pasta das transcrições de uma pasta de trabalho."""
    return re.sub(r"[^A-Za-z0-9]", "-", os.path.normpath(caminho(pasta)) if os.name == "nt" else pasta)


def sessao_de_transcricao(transcricao="", cwd=""):
    """Transcrição (e, de reserva, o cwd) -> nome da sessão; a pasta da transcrição vale mais que o cwd."""
    pasta = os.path.basename(os.path.dirname(transcricao or "/x/x"))
    candidatas = [(cfg["KIT_GERENTE"], cfg["KIT_GERENTE_DIR"])] + [(n, d) for n, d, _ in projetos()]
    for nome, d in candidatas:
        if pasta in (codifica_dir(d), codifica_dir(os.path.realpath(d))):
            return nome
    return sessao_de_dir(cwd) if cwd else ""


if __name__ == "__main__" and sys.argv[1:] == ["--autoteste"]:
    import tempfile
    falhas = []

    def ok(nome, obtido, esperado):
        if obtido != esperado:
            falhas.append(nome)
            print(f"FALHA {nome}: obtido {obtido!r}, esperado {esperado!r}")

    T = tempfile.mkdtemp()
    os.environ.update({"KIT_NVIDIA_SMI": os.path.join(T, "nada"), "KIT_ROCM_SMI": os.path.join(T, "nada"),
                       "KIT_DRM_DIR": os.path.join(T, "drm")})
    cfg["KIT_GPU"] = "auto"
    ok("sem gpu", gpu(), "nenhuma")
    for card, v in (("card0-DP-1", "0x10de"), ("card0", "0x8086"), ("card1", "0x1002")):
        os.makedirs(os.path.join(T, "drm", card, "device"))
        open(os.path.join(T, "drm", card, "device", "vendor"), "w").write(v + "\n")
    ok("amd vence intel", gpu(), "amd")
    shutil.rmtree(os.path.join(T, "drm", "card1"))
    ok("intel", gpu(), "intel")
    open(os.path.join(T, "drm", "card0", "device", "vendor"), "w").write("0x10de\n")
    ok("nvidia sem nvidia-smi", gpu(), "nvidia")
    cfg["KIT_GPU"] = "nenhuma"
    ok("KIT_GPU força", gpu(), "nenhuma")
    os.makedirs(os.path.join(T, "proc"))
    open(os.path.join(T, "proc", "version"), "w").write("Linux 5.15 microsoft-standard-WSL2\n")
    os.environ["KIT_PROC"] = os.path.join(T, "proc")
    if sys.platform.startswith("linux"):
        ok("wsl", plataforma(), "wsl")
    os.environ["KIT_PLATAFORMA"] = "windows"
    ok("KIT_PLATAFORMA força", plataforma(), "windows")
    if os.name != "nt":
        ok("caminho fora do Windows", caminho("/c/x"), "/c/x")
    shutil.rmtree(T)
    print("autoteste: OK" if not falhas else "autoteste: FALHOU")
    sys.exit(1 if falhas else 0)
