#!/usr/bin/env bash
# PostToolUse (Edit|Write|MultiEdit), global: CLAUDE.md, CLAUDE.local.md e SKILL.md com no máximo 500 linhas
#. Passou do limite: sai com 2 e o motivo vai ao Claude, que resume e aponta onde está o resto.
# Teste: limite-claude-md.sh --autoteste
set -u
LIMITE="${LIMITE_CLAUDE_MD:-500}"

if [ "${1:-}" = --autoteste ]; then
  T=$(mktemp -d); falhas=0
  seq 1 600 > "$T/CLAUDE.md"; seq 1 100 > "$T/SKILL.md"; seq 1 900 > "$T/outro.md"
  caso() {  # arquivo, código esperado
    printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$T/$1" | bash "$0" 2>/dev/null; c=$?
    [ "$c" = "$2" ] || { echo "FALHA $1: código $c, esperado $2"; falhas=1; }
  }
  caso CLAUDE.md 2; caso SKILL.md 0; caso outro.md 0
  printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$T/CLAUDE.md" | bash "$0" 2>&1 >/dev/null | grep -q "600 linhas" \
    || { echo "FALHA: motivo sem a contagem"; falhas=1; }
  rm -rf "$T"
  [ "$falhas" = 0 ] && echo "autoteste: OK" || echo "autoteste: FALHOU"
  exit "$falhas"
fi

f=$(python3 -I -c 'import json,sys
try: print(json.load(sys.stdin).get("tool_input",{}).get("file_path",""))
except Exception: print("")' 2>/dev/null)
case "$(basename -- "${f:-x}")" in CLAUDE.md|CLAUDE.local.md|SKILL.md) ;; *) exit 0 ;; esac
[ -f "$f" ] || exit 0
n=$(wc -l < "$f")
[ "$n" -le "$LIMITE" ] && exit 0
echo "Limite de linhas: $f tem $n linhas; o máximo é $LIMITE. Resuma agora: deixe nele só o que precisa ser carregado sempre e mova o detalhe para arquivos de apoio que não são carregados automaticamente (docs/, aprendizados/, arquivos de referência da skill), deixando no lugar uma linha curta que aponta onde está cada assunto." >&2
exit 2
