#!/usr/bin/env python3
"""Monitor autônomo do uso da janela de 5 h.

A cada 10 min consulta o uso da conta (o mesmo endereço do /usage do Claude Code, com o token que o
Claude Code guarda em ~/.claude/.credentials.json; o token não é impresso nem gravado), grava a
amostra em $KIT_CACHE/amostras.jsonl, refaz a previsão (uso-previsao.py, na mesma pasta) e grava
estado.json. Acrescenta em alertas.log um aviso (USO ADEQUADO ou USO ULTRAPASSANDO, com o limite de codificadores)
só quando algo muda (para economizar a sessão que vigia): o limite subiu ou caiu, a semana cruzou 70%, 80%
ou 90%, a janela de 5 h cruzou 85% ou passou a ultrapassar ou deixou de ultrapassar. Também avisa quando a consulta
passa a falhar ou volta. Não há mais aviso periódico.
O limite é o número de agentes capazes que a conta comporta; o consumo-auto o transforma na orientação única.
Um só processo por vez (trava em monitor.pid). Uso: monitor-uso.py [--uma-vez]
"""
from __future__ import annotations

import datetime as dt
import importlib.util
import json
import os
import sys
import time
import urllib.request
from pathlib import Path

_L = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "gerente-da-maquina", "lib")
if not os.path.isdir(_L):
    _L = os.path.expanduser("~/.claude/skills/gerente-da-maquina/lib")
sys.path.insert(0, _L)
import kit_config as K

DIR = Path(K.cfg["KIT_CACHE"])
AMOSTRAS, ESTADO, ALERTAS, PID = DIR / "amostras.jsonl", DIR / "estado.json", DIR / "alertas.log", DIR / "monitor.pid"
CRED = Path.home() / ".claude/.credentials.json"
INTERVALO = 600  # verificação a cada 10 min; também evita o limite de taxa da consulta
ESPERA_MAX = 900  # espera máxima depois de um 429
FAIXAS_SEMANA = (70, 80, 85, 90)  # cruzar uma dessas faixas da semana gera aviso
# Faixa da previsão da semana contra a meta (KIT_META_SEMANA): também avisa quando fica muito abaixo (15 pontos).
# Histerese: "acima" entra com >= 100% e sai com <= 90%; "abaixo" entra com <= 80% e sai com >= 83%.
# A faixa nova só vale depois de 2 amostras seguidas, porque o ritmo de 3 h oscila muito.
PREV_ACIMA, PREV_ACIMA_SAI, PREV_ABAIXO, PREV_ABAIXO_SAI = 100, 90, 80, 83


def faixa_prevista(p, ant):
    # as faixas seguem a meta da semana (meta_semana.py; 95 dá 100/90/80/83)
    try:
        import importlib.util
        spec = importlib.util.spec_from_file_location("meta_semana", Path(__file__).resolve().parent / "meta_semana.py")
        ms = importlib.util.module_from_spec(spec); spec.loader.exec_module(ms)
        fx = ms.faixas()
        PREV_ACIMA, PREV_ACIMA_SAI, PREV_ABAIXO, PREV_ABAIXO_SAI = fx["acima"], fx["acima_sai"], fx["abaixo"], fx["abaixo_sai"]
    except Exception:
        PREV_ACIMA, PREV_ACIMA_SAI, PREV_ABAIXO, PREV_ABAIXO_SAI = 100, 90, 80, 83
    if p is None:
        return ant or "meta"
    if p >= PREV_ACIMA:
        return "acima"
    if p <= PREV_ABAIXO:
        return "abaixo"
    if ant == "acima" and p > PREV_ACIMA_SAI:
        return "acima"
    if ant == "abaixo" and p < PREV_ABAIXO_SAI:
        return "abaixo"
    return "meta"


def agora_txt() -> str:
    return dt.datetime.now().astimezone().isoformat(timespec="seconds")


ULTIMO_AVISO = 0.0  # hora da última linha qualquer em alertas.log (também guardada em estado.json)


def hora(iso):
    return iso[11:16] if iso else "?"


def dia_hora(iso):
    return f"{iso[8:10]}/{iso[5:7]} {iso[11:16]}" if iso else "?"


def alerta(texto: str) -> None:
    global ULTIMO_AVISO
    with ALERTAS.open("a") as f:
        f.write(f"{agora_txt()} {texto}\n")
    ULTIMO_AVISO = time.time()


def consultar() -> dict:
    tok = json.loads(CRED.read_text())["claudeAiOauth"]["accessToken"]
    req = urllib.request.Request(
        "https://api.anthropic.com/api/oauth/usage",
        headers={"Authorization": f"Bearer {tok}", "anthropic-beta": "oauth-2025-04-20", "User-Agent": "claude-monitor-uso"},
    )
    d = json.load(urllib.request.urlopen(req, timeout=20))
    fh = d.get("five_hour") or {}
    reset = dt.datetime.fromisoformat(fh["resets_at"]).timestamp() if fh.get("resets_at") else None
    sd = d.get("seven_day") or {}
    reset7 = dt.datetime.fromisoformat(sd["resets_at"]).timestamp() if sd.get("resets_at") else None
    return {"ts": int(time.time()), "pct": float(fh.get("utilization") or 0), "reset": int(reset) if reset else None,
            "sete_dias": sd.get("utilization"), "reset_semana": int(reset7) if reset7 else None}


def previsor():
    spec = importlib.util.spec_from_file_location("p", Path(__file__).resolve().parent / "uso-previsao.py")
    p = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(p)
    return p


def ciclo(estado: dict) -> dict:
    try:
        a = consultar()
    except Exception as e:  # rede, token vencido, limite de taxa (429), resposta inesperada
        erro = f"{type(e).__name__} {getattr(e, 'code', '')}".strip()
        if getattr(e, "code", None) == 429:
            ra = 0
            try:
                ra = int((getattr(e, "headers", None) or {}).get("Retry-After") or 0)
            except ValueError:
                pass
            estado["espera"] = min(ESPERA_MAX, max(ra, 2 * estado.get("espera", INTERVALO)))
        else:
            estado["espera"] = INTERVALO
        if not estado.get("falhando"):
            alerta(f"FALHA na consulta do uso ({erro}); a previsão fica parada até voltar.")
        estado.update(falhando=True, erro=erro, atualizado=agora_txt())
        return estado
    with AMOSTRAS.open("a") as f:
        f.write(json.dumps(a) + "\n")
    r = previsor().prever()
    if estado.get("falhando"):
        alerta("Consulta do uso voltou a funcionar.")
    lim = r.get("limite_codificadores")
    ex5, ex7 = r.get("excesso_pct"), r.get("semana_excesso_pct")
    ultrapassando = ((ex5 or 0) > 0 or (ex7 or 0) > 0 or (r.get("uso_pct") or 0) >= 85
                     or (r.get("semana_pct") or 0) >= 90)
    if ultrapassando:
        partes = []
        if (ex5 or 0) > 0 or (r.get("uso_pct") or 0) >= 85:
            partes.append(f"janela de 5 h +{max(ex5 or 0, 0):g}% (uso {r.get('uso_pct'):g}%, renova {hora(r.get('reset'))})")
        if (ex7 or 0) > 0 or (r.get("semana_pct") or 0) >= 90:
            partes.append(f"semana +{max(ex7 or 0, 0):g}% (uso {r.get('semana_pct'):g}%, renova {dia_hora(r.get('semana_reset'))})")
        texto = f"USO ULTRAPASSANDO: {'; '.join(partes)}. Limite de codificadores {lim}."
    else:
        texto = (f"USO ADEQUADO: janela de 5 h {r.get('uso_pct'):g}%, semana {r.get('semana_pct') or 0:g}%. "
                 f"Limite de codificadores {lim}.")
    faixa = sum(1 for f in FAIXAS_SEMANA if (r.get("semana_pct") or 0) >= f)
    # Meta da semana (KIT_META_SEMANA): o balanço sugere os agentes.
    try:
        spec = importlib.util.spec_from_file_location("b", Path(__file__).resolve().parent / "balanco.py")
        bm = importlib.util.module_from_spec(spec); spec.loader.exec_module(bm)
        bal = bm.balanco(); texto += " " + bm.texto(bal)
        meta = [bal.get("agentes_sugeridos"), bal.get("freio")]
    except Exception as e:  # o balanço nunca derruba o monitor
        bal = {}; meta = None; texto += f" (balanço indisponível: {type(e).__name__})"
    fp_ant = estado.get("faixa_prevista")
    cand = faixa_prevista(bal.get("prevista_pct"), fp_ant)
    if fp_ant is None or cand == fp_ant or cand == estado.get("faixa_prevista_pend"):
        fp, estado["faixa_prevista_pend"] = cand, None  # sem mudança, ou confirmada na 2.ª amostra seguida
    else:
        fp, estado["faixa_prevista_pend"] = fp_ant, cand  # 1.ª amostra da faixa nova: espera a próxima
    texto += {"abaixo": " [prev:abaixo] PREVISÃO MUITO ABAIXO DA META: intensifique.",
              "acima": " [prev:acima] PREVISÃO ACIMA DA META: só o caminho crítico.",
              "meta": " [prev:meta]"}[fp]
    janela_alta = (r.get("uso_pct") or 0) >= 85
    mudou = (ultrapassando != estado.get("ultrapassando")
             or lim != estado.get("limite_avisado")
             or faixa != estado.get("faixa_semana")
             or janela_alta != estado.get("janela_alta")
             or meta != estado.get("meta_semana")
             or fp != estado.get("faixa_prevista"))
    if mudou:
        alerta(texto)
    estado.update(limite_avisado=lim, faixa_semana=faixa, janela_alta=janela_alta, ultrapassando=ultrapassando, meta_semana=meta,
                  faixa_prevista=fp)
    estado.update(falhando=False, erro=None, previsao=r, atualizado=agora_txt(), espera=INTERVALO, ultimo_aviso=ULTIMO_AVISO)
    return estado


def main() -> int:
    DIR.mkdir(parents=True, exist_ok=True)
    if "--uma-vez" not in sys.argv:
        if PID.exists():
            try:
                pid = int(PID.read_text())
                # Depois de um boot o número pode ser de outro processo (já foi uma thread de outro serviço).
                if "monitor-uso.py" not in open(f"/proc/{pid}/cmdline", "rb").read().decode(errors="ignore"):
                    raise ValueError("pid de outro processo")
                print("monitor já está rodando")
                return 0
            except (OSError, ValueError):
                pass
        PID.write_text(str(os.getpid()))
    estado = json.loads(ESTADO.read_text()) if ESTADO.exists() else {}
    global ULTIMO_AVISO
    ULTIMO_AVISO = estado.get("ultimo_aviso", 0.0)
    if estado.get("falhando") and estado.get("espera", 0) > INTERVALO:
        time.sleep(estado["espera"])  # não insistir logo depois de um 429
    while True:
        estado = ciclo(estado)
        ESTADO.write_text(json.dumps(estado, ensure_ascii=False, indent=1))
        if "--uma-vez" in sys.argv:
            return 0
        time.sleep(estado.get("espera", INTERVALO))


if __name__ == "__main__":
    sys.exit(main())
