"""Configuração do kit para scripts python.

    sys.path.insert(0, os.path.expanduser("~/.claude/skills/gerente-da-maquina/lib")); import kit_config as K
Lê ~/.config/gerente-maquina/kit.conf (KEY=VALUE, o mesmo arquivo do kit.sh) e aplica os padrões.
"""
import os
import shlex
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


def num(chave):
    return float(cfg[chave])


def projetos():
    """[(nome, dir, sessão tmux)] na ordem do kit.conf; o 1º é o prioritário."""
    saida = []
    for item in cfg["KIT_PROJETOS"].split():
        partes = item.split(":")
        nome, pasta = partes[0], (partes[1] if len(partes) > 1 else "")
        tmux = partes[2] if len(partes) > 2 and partes[2] else nome.lower()
        saida.append((nome, os.path.expanduser(pasta), tmux))
    return saida


def sessao_de_dir(pasta):
    """Diretório -> nome da sessão (o gerente ou um projeto) ou ''."""
    real = os.path.realpath(os.path.expanduser(pasta))
    if real == os.path.realpath(cfg["KIT_GERENTE_DIR"]):
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
    import re
    return re.sub(r"[^A-Za-z0-9]", "-", pasta)


def sessao_de_transcricao(transcricao="", cwd=""):
    """Transcrição (e, de reserva, o cwd) -> nome da sessão; a pasta da transcrição vale mais que o cwd."""
    pasta = os.path.basename(os.path.dirname(transcricao or "/x/x"))
    candidatas = [(cfg["KIT_GERENTE"], cfg["KIT_GERENTE_DIR"])] + [(n, d) for n, d, _ in projetos()]
    for nome, d in candidatas:
        if pasta in (codifica_dir(d), codifica_dir(os.path.realpath(d))):
            return nome
    return sessao_de_dir(cwd) if cwd else ""
