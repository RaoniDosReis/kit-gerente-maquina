#!/usr/bin/env bash
# Autoteste do vez-opus.sh: sessão única, rodízio com 2 e 3 projetos e projeto único fixo.
# Uso: vez-opus-teste.sh [script]   (padrão: o vez-opus.sh ao lado)
V="${1:-$(dirname "$0")/vez-opus.sh}"; T=$(mktemp -d); f=0
export VEZ_ESTADO=$T/e.json VEZ_LOCK=$T/l VEZ_LOG=$T/log KIT_CONF=$T/kit.conf KIT_CACHE=$T/cache
printf 'KIT_BASTAO_PROPORCAO=2\n' > "$KIT_CONF"
ok(){ if eval "$2"; then :; else echo "FALHA: $1"; f=1; fi; }
dono(){ python3 -c 'import json,sys;e=json.load(open(sys.argv[1]));d=e.get("dono");print((d or {}).get("sessao","-"),len(e["fila"]),e.get("unica","-"))' $VEZ_ESTADO; }
zera(){ rm -f "$VEZ_ESTADO" "$VEZ_LOG"; }

# --- dois projetos, sessão única ---
export VEZ_SESSOES="AAA BBB"
bash $V pegar AAA "a" >/dev/null; bash $V pegar AAA "b" >/dev/null; bash $V pegar BBB "c" >/dev/null
ok "estado inicial: AAA dono, 2 na fila" '[ "$(dono)" = "AAA 2 -" ]'
bash $V unica AAA >/dev/null
ok "unica dá a tarefa de sessão única ao dono" 'bash $V ver | grep -q "tarefa: sessão única ativa"'
ok "unica AAA: fixo, fila vazia" '[ "$(dono)" = "AAA 0 AAA" ]'
bash $V pegar AAA "d" >/dev/null; r=$?
ok "pegar do fixo dá 0" '[ $r = 0 ]'
ok "pegar do fixo não enfileira" '[ "$(dono)" = "AAA 0 AAA" ]'
bash $V soltar AAA >/dev/null; bash $V sair AAA >/dev/null
ok "soltar/sair não larga" '[ "$(dono)" = "AAA 0 AAA" ]'
ok "ver mostra fixo" 'bash $V ver | grep -q "fixo, única sessão ativa"'
bash $V unica BBB >/dev/null
ok "troca o fixo para BBB" '[ "$(dono)" = "BBB 0 BBB" ]'
bash $V unica nenhuma >/dev/null
ok "nenhuma: volta o rodízio, dono segue" '[ "$(dono)" = "BBB 0 -" ]'
bash $V soltar BBB >/dev/null
ok "sem fixo, soltar larga" '[ "$(dono)" = "- 0 -" ]'
n=$(wc -l <$VEZ_LOG); bash $V unica AAA >/dev/null; bash $V unica AAA >/dev/null
ok "unica repetido não grava evento de novo" '[ $(($(wc -l <$VEZ_LOG) - n)) = 1 ]'
bash $V pegar ZZZ "x" >/dev/null 2>&1; ok "sessão fora de KIT_PROJETOS é recusada" '[ $? = 2 ]'

# --- três projetos, proporção 2: AAA AAA BBB AAA AAA CCC (todos sempre na fila) ---
zera; export VEZ_SESSOES="AAA BBB CCC"; seq=""
bash $V pegar AAA "t" >/dev/null
for i in 1 2 3 4 5 6; do
  bash $V pegar AAA "t" >/dev/null; bash $V pegar BBB "t" >/dev/null; bash $V pegar CCC "t" >/dev/null
  seq="$seq $(dono | cut -d' ' -f1)"; bash $V soltar "$(dono | cut -d' ' -f1)" >/dev/null
done
ok "rodízio 2:1 com 3 projetos (obtido:$seq)" '[ "$seq" = " AAA AAA BBB AAA AAA CCC" ]'
zera; bash $V pegar BBB "t" >/dev/null; bash $V pegar CCC "t" >/dev/null; bash $V soltar BBB >/dev/null
ok "prioritário fora da fila: vai ao 1º da fila" '[ "$(dono)" = "CCC 0 -" ]'

# --- proporção 3 ---
printf 'KIT_BASTAO_PROPORCAO=3\n' > "$KIT_CONF"; zera; export VEZ_SESSOES="AAA BBB"; seq=""
bash $V pegar AAA "t" >/dev/null
for i in 1 2 3 4; do
  bash $V pegar AAA "t" >/dev/null; bash $V pegar BBB "t" >/dev/null
  seq="$seq $(dono | cut -d' ' -f1)"; bash $V soltar "$(dono | cut -d' ' -f1)" >/dev/null
done
ok "proporção 3 (obtido:$seq)" '[ "$seq" = " AAA AAA AAA BBB" ]'

# --- projeto único: fixo, sem unica explícito ---
zera; export VEZ_SESSOES="AAA"
bash $V pegar AAA "a" >/dev/null; r=$?
ok "projeto único: pegar dá 0" '[ $r = 0 ]'
bash $V soltar AAA >/dev/null
ok "projeto único: soltar não larga" '[ "$(dono)" = "AAA 0 AAA" ]'
bash $V pegar AAA "b" >/dev/null; r=$?
ok "projeto único: pegar de novo dá 0" '[ $r = 0 ]'

rm -rf "$T"; [ $f = 0 ] && echo "vez-opus: OK"; exit $f
