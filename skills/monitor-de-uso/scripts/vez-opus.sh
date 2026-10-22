#!/usr/bin/env bash
# Bastão do modelo capaz: as sessões dos projetos (KIT_PROJETOS) dividem um só bastão; só quem está com ele roda
# agente capaz (opus ou fable). Uso:
#   vez-opus.sh ver
#   vez-opus.sh pegar  <projeto> "<tarefa>" [previsao_min]   (0 = pegou; 3 = ocupado, entrou na fila; o dono
#                                                             também pode entrar na fila para a próxima rodada)
#   vez-opus.sh soltar <projeto>                             (só o dono; passa a vez a quem está na fila)
#   vez-opus.sh renovar <projeto> [previsao_min]             (só o dono; novo fim = agora + previsao_min)
#   vez-opus.sh sair <projeto> [motivo]                      (tira a sessão da fila; se for a dona, solta)
#   vez-opus.sh unica <projeto|nenhuma>                      (consumo-auto: só uma sessão de projeto no ar)
# Com um projeto só em KIT_PROJETOS, o bastão fica fixo nele: sem fila, o pegar sempre dá 0 e o soltar não larga.
# Sessão única: com as outras sessões desligadas, não há passagem de bastão: ele fica fixo com a sessão ativa, sem
# fila. O consumo-auto liga e desliga pelo `unica`.
# Rodízio: quando o 1º projeto de KIT_PROJETOS (o prioritário) e outros estão na fila, o prioritário recebe
# KIT_BASTAO_PROPORCAO rodadas para cada 1 de um dos outros (rodada = cada vez que a sessão recebe o bastão; a
# rodada de outro projeto zera a conta; os outros seguem pela ordem da fila). Se o prioritário não pediu a próxima
# rodada (não está na fila), o bastão vai direto ao primeiro da fila. Sem reserva.
# Fila: no máximo um de cada sessão. Previsão padrão: 60 min. Sem modelo, sem rede, sem token.
# Variáveis (para provas, sem tocar nos arquivos reais): VEZ_ESTADO, VEZ_LOCK, VEZ_LOG, VEZ_SESSOES (nomes separados
# por espaço, substitui KIT_PROJETOS).
. "$(dirname "$(readlink -f "$0")")/../../gerente-da-maquina/lib/kit.sh" 2>/dev/null \
  || . "$HOME/.claude/skills/gerente-da-maquina/lib/kit.sh"
D="$KIT_CACHE"
export VEZ_ESTADO="${VEZ_ESTADO:-$D/vez-opus.json}" VEZ_LOCK="${VEZ_LOCK:-$D/vez-opus.lock}" VEZ_LOG="${VEZ_LOG:-$D/vez-opus.log}"
export VEZ_SESSOES="${VEZ_SESSOES:-$(kit_projetos | tr '\n' ' ')}"
mkdir -p "$(dirname "$VEZ_ESTADO")" "$(dirname "$VEZ_LOCK")" "$(dirname "$VEZ_LOG")"
exec python3 -I - "$@" <<'PY'
import fcntl, json, os, sys, time, tempfile
est, lock, log = os.environ["VEZ_ESTADO"], os.environ["VEZ_LOCK"], os.environ["VEZ_LOG"]
SESS = tuple(os.environ.get("VEZ_SESSOES", "").split())
try:
    RODADAS = max(1, int(float(os.environ.get("KIT_BASTAO_PROPORCAO") or 2)))
except ValueError:
    RODADAS = 2
PRIO = SESS[0] if SESS else ""
PADRAO = 60.0
a = sys.argv[1:]
cmd = a[0] if a else ""
def uso():
    print("uso: vez-opus.sh ver | pegar <projeto> \"<tarefa>\" [previsao_min] | soltar <projeto> [motivo] | renovar <projeto> [previsao_min] | sair <projeto> [motivo] | unica <projeto|nenhuma>", file=sys.stderr); sys.exit(2)
def hora(t): return time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(t)) if t else "-"
def evento(msg):
    with open(log, "a") as f: f.write(f"{hora(time.time())} {msg}\n")
def ler():
    try:
        with open(est) as f: e = json.load(f)
    except (FileNotFoundError, ValueError): e = {}
    e.setdefault("dono", None); e.setdefault("fila", []); e.setdefault("seguidas_prio", 0)
    if len(SESS) == 1: e["unica"] = SESS[0]  # um projeto só: o bastão é fixo nele
    return e
def gravar(e):
    fd, tmp = tempfile.mkstemp(prefix=os.path.basename(est) + ".", dir=os.path.dirname(est))
    with os.fdopen(fd, "w") as f: json.dump(e, f, ensure_ascii=False, indent=1); f.flush(); os.fsync(f.fileno())
    os.replace(tmp, est)
def minutos(v):
    try:
        m = float(v)
        if m <= 0: raise ValueError
        return m
    except (TypeError, ValueError):
        print(f"previsão inválida: {v!r} (minutos, número positivo)", file=sys.stderr); sys.exit(2)
def sessao(v):
    if v not in SESS: print(f"sessão inválida: {v!r} (use {', '.join(SESS) or 'um nome de KIT_PROJETOS'})", file=sys.stderr); sys.exit(2)
    return v
def dar(e, s, tarefa, m, t):
    e["fila"] = [x for x in e["fila"] if x["sessao"] != s]
    e["dono"] = {"sessao": s, "desde": t, "tarefa": tarefa, "previsao_fim": t + m * 60}
    e["seguidas_prio"] = e["seguidas_prio"] + 1 if s == PRIO else 0
def proximo(e):  # rodízio: com o prioritário e outros na fila, o prioritário até completar as rodadas seguidas; depois o 1º dos outros
    q = {x["sessao"]: x for x in e["fila"]}
    outros = [x for x in e["fila"] if x["sessao"] != PRIO]
    if PRIO in q and outros:
        return q[PRIO] if e["seguidas_prio"] < RODADAS else outros[0]
    return next(iter(q.values()), None)
def passar(e, t):
    e["dono"] = None
    n = proximo(e)
    if not n: return
    dar(e, n["sessao"], n["tarefa"], n["previsao_min"], t)
    evento(f"PASSOU a vez para {n['sessao']} ({n['tarefa']})")
def mostrar(e):
    d, t = e["dono"], time.time()
    if d and e.get("unica") == d["sessao"]:
        print(f"bastão: {d['sessao']} fixo, única sessão ativa (sem rodízio nem fila) · tarefa: {d['tarefa']}")
    elif d:
        rest = (d["previsao_fim"] - t) / 60
        print(f"bastão: {d['sessao']} desde {hora(d['desde'])} · tarefa: {d['tarefa']} · previsão de fim {hora(d['previsao_fim'])} ({rest:+.0f} min)")
    else: print("bastão: LIVRE")
    if PRIO: print(f"rodízio: {PRIO} (prioritário) com {e['seguidas_prio']} rodada(s) seguida(s) de {RODADAS}")
    if e["fila"]:
        for x in e["fila"]:
            print(f"fila: {x['sessao']} desde {hora(x['desde'])} ({(t - x['desde'])/60:.0f} min) · {x['tarefa']}")
    else: print("fila: vazia")
if cmd not in ("ver", "pegar", "soltar", "renovar", "sair", "unica"): uso()
if not SESS:
    print("nenhum projeto em KIT_PROJETOS: configure ~/.config/gerente-maquina/kit.conf", file=sys.stderr); sys.exit(2)
with open(lock, "a") as lf:
    fcntl.flock(lf, fcntl.LOCK_EX)
    e = ler(); t = time.time(); rc = 0
    mudou = False
    fixo = e.get("unica")
    if cmd == "ver": mostrar(e)
    elif cmd == "unica":
        if len(a) < 2: uso()
        if a[1] == "nenhuma":
            if fixo and len(SESS) > 1:
                e.pop("unica"); mudou = True; evento(f"RODÍZIO de volta: as sessões no ar ({fixo} segue dono)")
        else:
            s = sessao(a[1])
            if fixo != s:
                e["unica"] = s; mudou = True; evento(f"FIXO com {s}: única sessão ativa, sem passagem de bastão")
                if e["dono"] and e["dono"]["sessao"] == s: e["dono"]["tarefa"] = "sessão única ativa"
            if not e["dono"] or e["dono"]["sessao"] != s:
                dar(e, s, "sessão única ativa", PADRAO, t); mudou = True
            if e["fila"]:
                e["fila"] = []; mudou = True
            if e["dono"]["previsao_fim"] < t:
                e["dono"]["previsao_fim"] = t + PADRAO * 60; mudou = True
        mostrar(e)
    elif cmd in ("soltar", "sair") and len(a) > 1 and fixo and sessao(a[1]) == fixo:
        print(f"{fixo} fica com o bastão: única sessão ativa"); mostrar(e)
    elif cmd == "sair":
        if len(a) < 2: uso()
        s = sessao(a[1]); motivo = " ".join(a[2:])
        n = len(e["fila"]); e["fila"] = [x for x in e["fila"] if x["sessao"] != s]
        if len(e["fila"]) != n:
            evento(f"SAIU da fila {s}" + (f" ({motivo})" if motivo else "")); mudou = True
        if e["dono"] and e["dono"]["sessao"] == s:
            evento(f"SOLTOU {s}" + (f" ({motivo})" if motivo else "")); passar(e, t); mudou = True
        print(f"{s} fora do bastão" if mudou else f"{s} não estava na fila nem com o bastão"); mostrar(e)
    elif cmd == "pegar":
        if len(a) < 3: uso()
        s, tarefa = sessao(a[1]), a[2]; m = minutos(a[3]) if len(a) > 3 else PADRAO
        if fixo == s and e["dono"] and e["dono"]["sessao"] == s:
            e["dono"].update(tarefa=tarefa, previsao_fim=t + m * 60); mudou = True
            evento(f"PEGOU {s} ({tarefa}) previsão {m:g} min (única sessão ativa)"); print(f"{s} pegou o bastão (única sessão ativa)")
        elif not e["dono"]:
            dar(e, s, tarefa, m, t); mudou = True
            evento(f"PEGOU {s} ({tarefa}) previsão {m:g} min"); print(f"{s} pegou o bastão")
        else:
            if not any(x["sessao"] == s for x in e["fila"]):
                e["fila"].append({"sessao": s, "desde": t, "tarefa": tarefa, "previsao_min": m}); mudou = True
                evento(f"FILA {s} ({tarefa}); dono {e['dono']['sessao']}")
            dono = e["dono"]["sessao"]
            print(f"{s} na fila para a próxima rodada" if dono == s else f"ocupado: {dono} está com o bastão; {s} na fila")
            mostrar(e); rc = 3
    else:
        if len(a) < 2: uso()
        s = sessao(a[1])
        if not e["dono"] or e["dono"]["sessao"] != s:
            print(f"{s} não é o dono do bastão", file=sys.stderr); mostrar(e); rc = 4
        elif cmd == "soltar":
            motivo = " ".join(a[2:])
            evento(f"SOLTOU {s}" + (f" ({motivo})" if motivo else ""))
            passar(e, t)
            mudou = True; print(f"{s} soltou"); mostrar(e)
        else:
            m = minutos(a[2]) if len(a) > 2 else PADRAO
            e["dono"]["previsao_fim"] = t + m * 60; mudou = True; evento(f"RENOVOU {s} por {m:g} min"); mostrar(e)
    if mudou: gravar(e)
sys.exit(rc)
PY
