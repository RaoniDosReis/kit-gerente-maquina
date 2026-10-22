#!/usr/bin/env bash
# PostToolUse dos agentes pagos pela API (só entra pelo --settings do agente-api). Aplica o teto de contexto dos
# agentes:
#   KIT_AGENTE_AVISO_K (150k)  AVISO: fechar o item, commit WIP (sem push sem verificação verde), passagem em
#         $KIT_CACHE/<projeto>/passagem-agentes/<nome>.md e terminar com "PARCIAL".
#   último aviso 15k antes da compactação (a compactação em KIT_AGENTE_COMPACT é a rede, via
#         CLAUDE_CODE_AUTO_COMPACT_WINDOW do agente-api).
# Uma mensagem por marco e por sessão. Variáveis: AGENTE_API_NOME, AGENTE_API_PROJETO.
# Teste: --autoteste
set -u
[ -f "$HOME/.claude/skills/gerente-da-maquina/lib/kit.sh" ] && . "$HOME/.claude/skills/gerente-da-maquina/lib/kit.sh"
: "${KIT_CACHE:=$HOME/.cache/gerente-maquina}" "${KIT_AGENTE_AVISO_K:=150000}" "${KIT_AGENTE_COMPACT:=200000}"
K1="${AGENTE_API_AVISO_K:-$KIT_AGENTE_AVISO_K}"; K2="${AGENTE_API_ULTIMO_K:-$((KIT_AGENTE_COMPACT - 15000))}"
EST="${AGENTE_API_ESTADO:-$KIT_CACHE/api-agentes/.avisos}"

contexto() {  # tokens de entrada da última resposta do agente
  python3 -I - "$1" <<'PY'
import json, os, sys
p = sys.argv[1]
try:
    with open(p, "rb") as f:
        f.seek(max(0, os.path.getsize(p) - 2_000_000)); linhas = f.read().splitlines()
except OSError:
    print(0); sys.exit()
for l in reversed(linhas):
    try: d = json.loads(l)
    except ValueError: continue
    if d.get("type") != "assistant" or d.get("isSidechain"): continue
    u = d.get("message", {}).get("usage") or {}
    print(u.get("input_tokens", 0) + u.get("cache_read_input_tokens", 0) + u.get("cache_creation_input_tokens", 0)); break
else:
    print(0)
PY
}

principal() {
  local entrada sid tr k nome proj marco msg
  entrada="$(cat)"
  sid="$(printf '%s' "$entrada" | python3 -I -c 'import json,sys; print(json.load(sys.stdin).get("session_id",""))' 2>/dev/null)"
  tr="$(printf '%s' "$entrada" | python3 -I -c 'import json,sys; print(json.load(sys.stdin).get("transcript_path",""))' 2>/dev/null)"
  [ -n "$sid" ] && [ -f "$tr" ] || exit 0
  k="$(contexto "$tr")"
  nome="${AGENTE_API_NOME:-agente}"; proj="${AGENTE_API_PROJETO:-projeto}"
  if [ "$k" -ge "$K2" ]; then marco=2; elif [ "$k" -ge "$K1" ]; then marco=1; else exit 0; fi
  mkdir -p "$EST"; [ -e "$EST/$sid-$marco" ] && exit 0; : > "$EST/$sid-$marco"
  msg="TETO DE CONTEXTO ($((k / 1000))k de $((K1 / 1000))k; regra de contexto dos agentes): não comece nada novo. Feche o item atual, faça commit WIP (sem push sem verify verde), escreva a passagem em $KIT_CACHE/$proj/passagem-agentes/$nome.md (feito/falta, branch, SHA, worktree, provas, processos deixados) e termine a resposta com PARCIAL."
  [ "$marco" = 2 ] && msg="ÚLTIMO AVISO, $((k / 1000))k: a compactação está próxima. $msg"
  python3 -I -c 'import json,sys; print(json.dumps({"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": sys.argv[1]}}, ensure_ascii=False))' "$msg"
}

autoteste() {
  local d f saida ok=0
  d="$(mktemp -d)"; f="$d/t.jsonl"
  gera() { printf '{"type":"assistant","message":{"usage":{"input_tokens":10,"cache_read_input_tokens":%s,"cache_creation_input_tokens":0}}}\n' "$1" > "$f"; }
  roda() { printf '{"session_id":"s1","transcript_path":"%s"}' "$f" | AGENTE_API_ESTADO="$d/est" AGENTE_API_NOME=cod1 "$0"; }
  gera 100000; saida="$(roda)"; [ -z "$saida" ] || { echo "FALHA: avisou abaixo de 150k"; ok=1; }
  gera 160000; saida="$(roda)"; printf '%s' "$saida" | grep -q 'passagem-agentes/cod1.md' || { echo "FALHA: sem aviso em 160k"; ok=1; }
  saida="$(roda)"; [ -z "$saida" ] || { echo "FALHA: repetiu o aviso de 150k"; ok=1; }
  gera 190000; saida="$(roda)"; printf '%s' "$saida" | grep -q 'ÚLTIMO AVISO' || { echo "FALHA: sem último aviso em 190k"; ok=1; }
  printf '%s' "$saida" | python3 -I -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null || { echo "FALHA: saída não é JSON"; ok=1; }
  rm -rf "$d"; [ "$ok" = 0 ] && echo "autoteste OK"; return "$ok"
}

if [ "${1:-}" = "--autoteste" ]; then autoteste; exit $?; fi
principal
