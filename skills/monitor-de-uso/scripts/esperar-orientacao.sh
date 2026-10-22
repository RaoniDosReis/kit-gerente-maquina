#!/usr/bin/env bash
# Vigia de um orquestrador. Uso:
#   esperar-orientacao.sh <projeto> [--quero-vaga]
# A orientação de uso é uma só para todos os projetos (consumo-auto, em $KIT_CACHE/orientacao.json).
# Só termina quando há AÇÃO para este projeto, imprimindo a orientação:
#   - o modo mudou (faixa da previsão: intensificar, normal ou só o caminho crítico);
#   - o orçamento de agentes mudou;
#   - o bastão veio para você ("dono") ou o teto de 90 min chegou ("dono-teto": solte ao terminar o agente atual);
#   - abriu vaga, SÓ com --quero-vaga (arme assim quando tiver agente esperando vaga; sem trabalho na fila, não).
# Não acorda com: vaga que fecha, vaga que abre sem --quero-vaga, bastão que passa entre os outros ou fica livre
# (quem quer capaz chama vez-opus.sh pegar, que dá na hora se estiver livre). Chave vista: orientacao-visto-<proj>.
# CONSUMO_DIR e ESPERA_S (padrão 30) trocam a pasta e a espera.
. "$(dirname "$(readlink -f "$0")")/../../gerente-da-maquina/lib/kit.sh" 2>/dev/null \
  || . "$HOME/.claude/skills/gerente-da-maquina/lib/kit.sh"
S="$1"
case " $(kit_projetos | tr '\n' ' ') " in *" $S "*) ;; *) echo "uso: $0 <projeto de KIT_PROJETOS> [--quero-vaga]" >&2; exit 2 ;; esac
QUER=0; [ "${2:-}" = "--quero-vaga" ] && QUER=1
export D="${CONSUMO_DIR:-$KIT_CACHE}" ESPERA="${ESPERA_S:-30}" QUER
exec python3 -I - "$S" <<'PY'
import json, os, sys, time
s, d, espera, quer = sys.argv[1], os.environ["D"], float(os.environ["ESPERA"]), os.environ["QUER"] == "1"
visto = os.path.join(d, f"orientacao-visto-{s}")
def ler():
    try:
        with open(os.path.join(d, "orientacao.json")) as f: return json.load(f)
    except (OSError, ValueError): return {}
def chave(o): return (o.get("chave") or {}).get(s)
def acao(ant, k):
    """Lista do que mudou e pede ação; vazio = só registra."""
    r = []
    for c in ("modo", "orcamento"):
        if k.get(c) != ant.get(c): r.append(f"{c} {ant.get(c)} -> {k.get(c)}")
    if k.get("vez") != ant.get("vez") and k.get("vez") in ("dono", "dono-teto"):
        r.append(f"vez {ant.get('vez')} -> {k.get('vez')}")
    if quer and k.get("vaga") == "sim" and ant.get("vaga") != "sim":
        r.append("vaga não -> sim")
    return r
try:
    ant = json.load(open(visto))
except (OSError, ValueError):
    ant = None
if quer and ant is not None and (chave(ler()) or {}).get("vaga") == "sim":
    ant = dict(ant, vaga="não")  # pediu vaga e ela já está aberta: avisa na hora
while True:
    o = ler(); k = chave(o)
    if k is None: time.sleep(espera); continue
    if ant is None:
        ant = k; json.dump(k, open(visto, "w"))
    if k != ant:
        mud = acao(ant, k)
        json.dump(k, open(visto, "w"))
        if mud:
            print("ORIENTAÇÃO MUDOU para " + s + ": " + ", ".join(mud)); print(o.get("texto", "")); break
        ant = k
    time.sleep(espera)
PY
