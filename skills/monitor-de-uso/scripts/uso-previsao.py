#!/usr/bin/env python3
"""Previsão do uso da janela de 5 h do Claude Code.

Lê as amostras gravadas pelo monitor ($KIT_CACHE/amostras.jsonl: ts, pct da
janela de 5 h, resets_at) e calcula, para a janela atual:
  - consumo acumulado: % usado e ritmo médio desde a primeira amostra da janela;
  - consumo atual: ritmo dos últimos 40 min (regressão linear);
  - previsão: hora em que chega a 100% no ritmo atual, comparada com o reset;
  - limite de codificadores simultâneos (mínimo 1, máximo 4):
      esgota antes do reset              -> 1
      esgota até 30 min depois do reset  -> 2
      sobra de 30 a 90 min               -> 3
      sobra mais de 90 min               -> 4
    e, por segurança, 1 se o uso já passou de 85%.
A regra para o orquestrador: agir só sobre o número que recebe; nunca interromper os
que já estão rodando, só não acionar novos acima do limite.
Uso: uso-previsao.py [--json]
"""
from __future__ import annotations

import datetime as dt
import json
import os
import sys
from pathlib import Path

_L = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "gerente-da-maquina", "lib")
if not os.path.isdir(_L):
    _L = os.path.expanduser("~/.claude/skills/gerente-da-maquina/lib")
sys.path.insert(0, _L)
import kit_config as K

ARQ = Path(K.cfg["KIT_CACHE"]) / "amostras.jsonl"
JANELA_ATUAL_MIN = 40  # com uma amostra a cada 10 min, 4 a 5 pontos


def carregar() -> list[dict]:
    if not ARQ.exists():
        return []
    out = []
    for linha in ARQ.read_text().splitlines():
        try:
            out.append(json.loads(linha))
        except ValueError:
            continue
    return out


def ritmo(amostras: list[dict]) -> float | None:
    """% por minuto por regressão linear; None com menos de 2 pontos ou 2 min de intervalo."""
    if len(amostras) < 2:
        return None
    xs = [(a["ts"] - amostras[0]["ts"]) / 60 for a in amostras]
    ys = [a["pct"] for a in amostras]
    if xs[-1] - xs[0] < 2:
        return None
    mx, my = sum(xs) / len(xs), sum(ys) / len(ys)
    den = sum((x - mx) ** 2 for x in xs)
    return max(0.0, sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / den) if den else None


def _prever_5h() -> dict:
    todas = carregar()
    if not todas:
        return {"ok": False, "motivo": "sem amostras ainda (o monitor grava a cada 10 minutos)", "limite_codificadores": 2}
    ult = todas[-1]
    janela = [a for a in todas if a.get("reset") and ult.get("reset") and abs(a["reset"] - ult["reset"]) < 300]
    agora = ult["ts"]
    recentes = [a for a in janela if a["ts"] >= agora - JANELA_ATUAL_MIN * 60]
    r_atual = ritmo(recentes)
    r_medio = ritmo(janela)
    pct = ult["pct"]
    reset = ult.get("reset")
    res = {
        "ok": True,
        "uso_pct": round(pct, 1),
        "reset": dt.datetime.fromtimestamp(reset).astimezone().isoformat(timespec="minutes") if reset else None,
        "ritmo_atual_pct_h": round(r_atual * 60, 1) if r_atual is not None else None,
        "ritmo_medio_pct_h": round(r_medio * 60, 1) if r_medio is not None else None,
        "amostras_na_janela": len(janela),
    }
    r = r_atual if r_atual is not None else r_medio
    if r is None or r == 0 or reset is None:
        res["previsao_esgota"] = None
        res["limite_codificadores"] = 0 if pct >= 85 else 4 if r == 0 else 2
        res["motivo"] = "ritmo ainda desconhecido" if r is None else "sem consumo recente"
        return res
    esgota = agora + (100 - pct) / r * 60
    res["excesso_pct"] = round(pct + r * (reset - agora) / 60 - 100, 1)  # uso previsto no reset, acima de 100%
    res["previsao_esgota"] = dt.datetime.fromtimestamp(esgota).astimezone().isoformat(timespec="minutes")
    folga_min = (esgota - reset) / 60
    res["folga_min"] = round(folga_min)
    if pct >= 85:
        lim = 0  # risco de parada total: nenhum codificador novo; revisões e merges seguem
    elif folga_min < 0:
        lim = 1
    elif folga_min < 30:
        lim = 2
    elif folga_min < 90:
        lim = 3
    else:
        lim = 4
    res["limite_codificadores"] = lim
    res["motivo"] = "esgota antes do reset" if folga_min < 0 else "esgota pouco depois do reset" if folga_min < 30 else "não esgota antes do reset"
    return res


RITMO_SEMANA_H = 24


def semana(ult: dict, todas: list | None = None) -> dict:
    try:
        import importlib.util
        spec = importlib.util.spec_from_file_location("meta_semana", Path(__file__).resolve().parent / "meta_semana.py")
        ms = importlib.util.module_from_spec(spec); spec.loader.exec_module(ms)
        PARADA = ms.faixas()["parada"]
    except Exception:
        PARADA = 90
    """Limite pela semana: ritmo das últimas 24 h (a média desde o início da semana pesava os dias intensos e
    cortava os agentes com a meta folgada); com menos de 24 h de semana, a média desde o início."""
    pct7, reset7, agora = ult.get("sete_dias"), ult.get("reset_semana"), ult["ts"]
    if pct7 is None or not reset7:
        return {"semana_pct": pct7, "semana_limite": 4}
    inicio = reset7 - 7 * 86400
    horas = max(1.0, (agora - inicio) / 3600)
    r7 = float(pct7) / horas  # % por hora, média da semana
    base = [a for a in (todas or []) if a.get("sete_dias") is not None and abs((a.get("reset_semana") or 0) - reset7) < 3600
            and inicio <= a["ts"] <= agora - RITMO_SEMANA_H * 3600]
    if base:  # amostra desta mesma semana de 24 h atrás (ou mais perto disso)
        b = base[-1]
        r7 = max(0.0, float(pct7) - float(b["sete_dias"])) / max(1.0, (agora - b["ts"]) / 3600)
    out = {"semana_pct": round(float(pct7), 1),
           "semana_reset": dt.datetime.fromtimestamp(reset7).astimezone().isoformat(timespec="minutes"),
           "semana_ritmo_pct_dia": round(r7 * 24, 1)}
    if r7 <= 0:
        out["semana_limite"] = 4
        return out
    esgota7 = agora + (100 - float(pct7)) / r7 * 3600
    out["semana_excesso_pct"] = round(float(pct7) + r7 * (reset7 - agora) / 3600 - 100, 1)
    folga_h = (esgota7 - reset7) / 3600
    out["semana_esgota"] = dt.datetime.fromtimestamp(esgota7).astimezone().isoformat(timespec="minutes")
    out["semana_folga_h"] = round(folga_h)
    if float(pct7) >= PARADA:
        out["semana_limite"] = 0  # risco de parada total na semana (90 com a meta de 95; segue a meta)
    elif folga_h < -24:
        out["semana_limite"] = 1
    elif folga_h < 0:
        out["semana_limite"] = 2
    elif folga_h < 24:
        out["semana_limite"] = 3
    else:
        out["semana_limite"] = 4
    out["semana_estourando"] = folga_h < 0 or float(pct7) >= PARADA
    return out


def prever_completo() -> dict:
    r = _prever_5h()
    todas = carregar()
    if not todas:
        return r
    s = semana(todas[-1], todas)
    r.update(s)
    lim5 = r.get("limite_codificadores", 2)
    lim7 = s.get("semana_limite", 4)
    r["limite_5h"] = lim5
    r["limite_codificadores"] = min(lim5, lim7)
    r["limite_por"] = "semana (7 dias)" if lim7 < lim5 else "janela de 5 h"
    return r


prever = prever_completo


def main() -> int:
    r = prever()
    if "--json" in sys.argv:
        print(json.dumps(r, ensure_ascii=False))
        return 0
    if not r["ok"]:
        print(f"Uso: {r['motivo']}. Limite de codificadores: {r['limite_codificadores']}.")
        return 0
    print(f"Uso da janela de 5 h: {r['uso_pct']}% (reset {r['reset']}).")
    print(f"Ritmo atual (40 min): {r['ritmo_atual_pct_h']} %/h; médio da janela: {r['ritmo_medio_pct_h']} %/h.")
    print(f"Previsão de esgotar: {r.get('previsao_esgota') or 'indefinida'} ({r['motivo']}).")
    if r.get("semana_pct") is not None:
        print(f"Semana: {r['semana_pct']}% (ritmo de 24 h {r.get('semana_ritmo_pct_dia')} %/dia, esgota {r.get('semana_esgota')}, renova {r.get('semana_reset')}).")
    print(f"Limite de codificadores simultâneos agora: {r['limite_codificadores']} (manda: {r.get('limite_por', 'janela de 5 h')}).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
