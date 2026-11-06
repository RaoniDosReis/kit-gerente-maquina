#!/usr/bin/env python3
"""Mede o padrão de velocidade  de um repositório numa janela.
Uso: medir-velocidade.py <repo> <início UTC ISO> [fim UTC ISO]
Ex.: medir-velocidade.py dono/repo 2026-01-10T00:00:00Z
Mede: CI de PR (workflow CI, event pull_request) mediana e p90, aberto->merge,
merges/dia, funcionalidades/dia (título começando por F<número>) e, se houver,
o job lento cujo nome começa por $JOB_LENTO (padrão "Bateria"). Só leitura (gh)."""
import json, os, re, subprocess, sys, statistics as st
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
JOB = os.environ.get('JOB_LENTO', 'Bateria')
P = lambda s: datetime.fromisoformat(s.replace('Z', '+00:00'))
repo, a = sys.argv[1], P(sys.argv[2])
b = P(sys.argv[3]) if len(sys.argv) > 3 else datetime.now(timezone.utc)
gh = lambda *x: json.loads(subprocess.run(['gh', *x], capture_output=True, text=True, check=True).stdout or '[]')
runs = [r for r in gh('run', 'list', '-R', repo, '--workflow', 'CI', '--event', 'pull_request',
        '--created', f'{a:%Y-%m-%d}..{b:%Y-%m-%d}', '-L', '2000',
        '--json', 'databaseId,createdAt,updatedAt,startedAt,status,conclusion')
        if r['status'] == 'completed' and r['conclusion'] in ('success', 'failure') and a <= P(r['createdAt']) < b]
prs = [p for p in gh('pr', 'list', '-R', repo, '--state', 'merged', '--search', f'merged:>={a:%Y-%m-%d}',
       '-L', '1000', '--json', 'title,createdAt,mergedAt') if a <= P(p['mergedAt']) < b]
med = lambda l: round(st.median(l), 1) if l else None
p90 = lambda l: round(sorted(l)[max(0, int(.9 * len(l)) - 1)], 1) if l else None
ci = [(P(r['updatedAt']) - P(r['startedAt'])).total_seconds() / 60 for r in runs]
am = [(P(p['mergedAt']) - P(p['createdAt'])).total_seconds() / 60 for p in prs]
dias = (b - a).total_seconds() / 86400
feat = [p for p in prs if re.match(r'F\d', p['title'])]
def bat(i):
    js = gh('api', f'repos/{repo}/actions/runs/{i}/jobs?per_page=100', '--jq', '[.jobs[]|{name,started_at,completed_at}]')
    return [(P(j['completed_at']) - P(j['started_at'])).total_seconds() / 60 for j in js
            if j['name'].startswith(JOB) and j['started_at'] and j['completed_at']]
with ThreadPoolExecutor(8) as ex:
    bench = [d for l in ex.map(bat, [r['databaseId'] for r in runs]) for d in l if d > 0.5]
print(f"{repo} {a:%d/%m %H:%M}Z..{b:%d/%m %H:%M}Z ({dias:.2f} d): CI de PR med {med(ci)} min (p90 {p90(ci)}, n={len(ci)}) | "
      f"aberto->merge med {med(am)} min | merges {len(prs)/dias:.1f}/d | funcionalidades {len(feat)/dias:.1f}/d"
      + (f" | job lento med {med(bench)} min (n={len(bench)})" if bench else ""))
