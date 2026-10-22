"""Meta da semana de uso da conta (padrão KIT_META_SEMANA, 95%), com troca temporária em
$KIT_CACHE/meta-semana.json: {"meta": 100, "ate": <época>, "por": "..."}.
Passada a data `ate`, volta sozinha ao padrão. Lida pelo balanco.py, monitor-uso.py, uso-previsao.py e consumo-auto.py.
As faixas derivadas mantêm as distâncias da meta de 95 (acima >= 100, sai <= 90; abaixo <= 80, sai >= 83;
agentes a 0 com a semana em 90%). Os 5% que sobram da meta ficam para o uso pessoal do dono."""
import json, os, sys, time

_L = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "gerente-da-maquina", "lib")
if not os.path.isdir(_L):
    _L = os.path.expanduser("~/.claude/skills/gerente-da-maquina/lib")
sys.path.insert(0, _L)
import kit_config as K

PADRAO = K.num("KIT_META_SEMANA")
ARQ = os.path.expanduser(os.environ.get("META_SEMANA_ARQ", os.path.join(K.cfg["KIT_CACHE"], "meta-semana.json")))


def atual(agora=None):
    try:
        with open(ARQ) as f:
            d = json.load(f)
        if (agora or time.time()) < float(d["ate"]):
            return float(d["meta"])
    except (OSError, ValueError, KeyError, TypeError):
        pass
    return PADRAO


def faixas(meta=None):
    m = atual() if meta is None else meta
    # meta 100: os agentes param em 98
    return {"acima": m + 5, "acima_sai": m - 5, "abaixo": m - 15, "abaixo_sai": m - 12, "parada": m - 2 if m >= 100 else m - 5}
