#!/usr/bin/env python3
"""Linha de status do Claude Code: modelo, contexto e a previsão de uso do monitor
(monitor-uso.py grava $KIT_CACHE/estado.json a cada minuto)."""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / ".." / ".." / "gerente-da-maquina" / "lib"))
sys.path.insert(1, str(Path.home() / ".claude/skills/gerente-da-maquina/lib"))
import kit_config as K

try:
    j = json.load(sys.stdin)
except ValueError:
    j = {}
partes = [f"[{(j.get('model') or {}).get('display_name', '?')}]"]
ctx = (j.get("context_window") or {}).get("used_percentage")
if ctx is not None:
    partes.append(f"ctx {round(float(ctx))}%")
try:
    e = json.loads((Path(K.cfg["KIT_CACHE"]) / "estado.json").read_text())
    r = e.get("previsao") or {}
    if e.get("falhando"):
        partes.append("uso: consulta falhando")
    elif r.get("ok"):
        prev = (r.get("previsao_esgota") or "")[11:16] or "-"
        partes.append(f"5h {r['uso_pct']:.0f}% · reset {(r.get('reset') or '')[11:16]} · esgota {prev} · agentes {r['limite_codificadores']}")
except (OSError, ValueError, KeyError):
    partes.append("uso: monitor parado")
print("  ".join(partes))
