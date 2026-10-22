#!/usr/bin/env python3
"""Balanço do uso semanal contra a meta (KIT_META_SEMANA; os projetos dividem a semana, o resto fica para o dono).

Lê as amostras do monitor ($KIT_CACHE/amostras.jsonl) e o número de agentes capazes em curso
($KIT_CACHE/agentes, um inteiro que o consumo-auto grava; só agentes capazes contam).
Calcula o ritmo da semana nas últimas horas, o ritmo sustentável até a meta e sugere quantos
agentes capazes manter. Uso: balanco.py [--meta 95] [--json]
"""
from __future__ import annotations
import json, os, sys, time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import meta_semana
import kit_config as K

DIR = Path(K.cfg["KIT_CACHE"])
META = meta_semana.atual()  # a meta do kit.conf ou a troca temporária de meta-semana.json
JANELA_H = 6.0  # 6 h: com 3 h a previsão pulava de 76% para 122% em 1 h e trocava de faixa à toa


def balanco(meta: float | None = None) -> dict:
    meta = meta_semana.atual() if meta is None else meta
    amostras = [json.loads(l) for l in (DIR / "amostras.jsonl").read_text().splitlines() if l.strip()]
    semana = [a for a in amostras if a.get("sete_dias") is not None and a.get("reset_semana")]
    if not semana:
        return {"ok": False, "motivo": "sem amostras"}
    ult = semana[-1]
    reset = ult["reset_semana"]
    # só amostras do mesmo ciclo semanal (mesma renovação), dentro da janela
    ciclo = [a for a in semana if abs(a["reset_semana"] - reset) < 3600]
    # a semana também zera fora da renovação (troca de plano): começa depois da última queda
    for i in range(len(ciclo) - 1, 0, -1):
        if float(ciclo[i]["sete_dias"]) < float(ciclo[i - 1]["sete_dias"]) - 5:
            ciclo = ciclo[i:]
            break
    desde = ult["ts"] - JANELA_H * 3600
    base = next((a for a in ciclo if a["ts"] >= desde), ciclo[0])
    horas = (ult["ts"] - base["ts"]) / 3600
    pct = float(ult["sete_dias"])
    ritmo = (pct - float(base["sete_dias"])) / horas if horas >= 0.5 else None
    restante_h = max((reset - time.time()) / 3600, 0.1)
    sustentavel = max(meta - pct, 0) / restante_h
    try:
        agentes = float((DIR / "agentes").read_text().strip())
    except (OSError, ValueError):
        agentes = None
    sugerido = None
    if ritmo and agentes:
        por_agente = ritmo / agentes  # inclui o custo do orquestrador, rateado
        sugerido = max(0, round(sustentavel / por_agente)) if por_agente > 0 else None
    prevista = pct + (ritmo or 0) * restante_h if ritmo is not None else None
    return {"ok": True, "semana_pct": pct, "meta": meta, "horas_medidas": round(horas, 1),
            "ritmo_pct_h": None if ritmo is None else round(ritmo, 2),
            "sustentavel_pct_h": round(sustentavel, 2), "horas_ate_renovar": round(restante_h, 1),
            "prevista_pct": None if prevista is None else round(prevista, 1),
            "agentes_capazes": agentes, "agentes_sugeridos": sugerido,
            "freio": pct >= meta}


def texto(b: dict) -> str:
    if not b.get("ok"):
        return "Balanço: sem dados."
    if b["freio"]:
        return f"BALANÇO: semana em {b['semana_pct']:g}%, meta de {b['meta']:g}% atingida: nenhum agente novo."
    r = "medindo" if b["ritmo_pct_h"] is None else f"{b['ritmo_pct_h']:g}%/h nas últimas {b['horas_medidas']:g} h"
    s = f"BALANÇO: semana {b['semana_pct']:g}% · ritmo {r} · sustentável {b['sustentavel_pct_h']:g}%/h até {b['meta']:g}%"
    if b["prevista_pct"] is not None:
        s += f" · prevista {b['prevista_pct']:g}%"
    if b["agentes_sugeridos"] is not None:
        s += f" · agentes capazes: {b['agentes_capazes']:g} agora, sugerido {b['agentes_sugeridos']}"
    return s + "."


if __name__ == "__main__":
    meta = float(sys.argv[sys.argv.index("--meta") + 1]) if "--meta" in sys.argv else META
    b = balanco(meta)
    print(json.dumps(b, ensure_ascii=False) if "--json" in sys.argv else texto(b))
