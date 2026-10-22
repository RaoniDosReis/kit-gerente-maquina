#!/usr/bin/env bash
# SessionStart do gerente: a cada início, retomada, /clear ou compactação da conversa do gerente (cwd = KIT_GERENTE_DIR),
# põe no contexto o essencial para ele nunca esquecer quem é e o que está aberto: a checagem de abertura já rodada, a
# skill gerente-da-maquina e as pendências. Outras pastas (os projetos) saem sem nada. Uso: gerente-inicio.sh
# skill|pendencias (duas entradas no settings.json, para cada saída ficar abaixo do limite de 10 mil caracteres do
# hook). Teste: gerente-inicio.sh --autoteste
set -u
KIT_LIB="${KIT_LIB:-$HOME/.claude/skills/gerente-da-maquina/lib}"
[ -f "$KIT_LIB/kit.sh" ] || KIT_LIB="$(dirname "$(readlink -f "$0")")/../skills/gerente-da-maquina/lib"
# shellcheck disable=SC1091
. "$KIT_LIB/kit.sh"
G="${G_TESTE:-$HOME/.claude/skills/gerente-da-maquina}"
[ -f "$G/SKILL.md" ] || G="$(dirname "$KIT_LIB")"
parte="${1:-skill}"

checagem() {
  echo "Checagem de abertura (rodada pelo hook agora):"
  local s
  for s in saude-auto parados-auto consumo-auto ci-termica controle-termico gerente; do  # só as unidades que existem
    systemctl --user cat "$s" >/dev/null 2>&1 || continue
    echo "- $s: $(systemctl --user is-active "$s" 2>&1)"
  done
  if pgrep -f 'scripts/esperar-zelador\.sh' >/dev/null; then echo "- zelador: armado"
  else echo "- zelador: SEM ZELADOR. Relance pela §4 da skill zelador antes de qualquer outra coisa."; fi
  local f pid cmd nome modo
  for f in "$HOME"/.claude/sessions/*.json; do
    [ -f "$f" ] || continue
    pid=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("pid",""))' "$f" 2>/dev/null)
    [ -n "$pid" ] && [ -r "/proc/$pid/cmdline" ] || continue
    cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline")
    case "$cmd" in claude*) ;; *) continue ;; esac
    nome=$(sed -n 's/.*--name \([^ ]*\).*/\1/p' <<<"$cmd")
    case "$cmd" in *dangerously-skip-permissions*|*"permission-mode bypassPermissions"*) modo="SEM AUTO (reiniciar em auto)";;
                   *"permission-mode auto"*) modo="auto";; *) modo="modo padrão";; esac
    echo "- sessão ${nome:-sem nome} (PID $pid): $modo"
  done
}

saida() {
  local origem="$1"
  if [ "$parte" = pendencias ]; then
    printf 'Pendências do gerente (%s/pendencias.md, injetadas pelo hook):\n\n' "$G"
    python3 -I -c 'import sys
t = open(sys.argv[1]).read(); n = 9500
print(t if len(t) <= n else "[PENDÊNCIAS NÃO CABEM na injeção (" + str(len(t)) + " caracteres): leia o arquivo inteiro com Read em " + sys.argv[1] + " antes de qualquer outra ação; enxugue-o]")' "$G/pendencias.md"
    return
  fi
  echo "Você é o gerente ($KIT_GERENTE): a sessão da máquina ($KIT_GERENTE_DIR), gerente do hardware, das automações, do zelador e das sessões de produção ($(kit_projetos | paste -sd, - | sed 's/,/, /g')). Hook gerente-inicio, origem: $origem."
  echo
  checagem
  if [ "$origem" = resume ]; then
    echo
    echo "Retomada: a skill gerente-da-maquina já está nesta conversa. Se a checagem mostrar algo fora do normal, resolva pela skill."
    return
  fi
  echo
  echo "A skill gerente-da-maquina vem abaixo, inteira (não precisa carregá-la de novo; os arquivos de detalhe ficam em $G):"
  echo
  sed '1,/^---$/{/^---$/!d};1,/^---$/d' "$G/SKILL.md" | python3 -I -c 'import sys
t = sys.stdin.read(); n = 9000
print(t if len(t) <= n else "[SKILL NÃO CABE na injeção (" + str(len(t)) + " caracteres): leia-a inteira com Read em " + sys.argv[1] + " antes de qualquer outra ação; enxugue a SKILL.md para menos de 9 mil caracteres]")' "$G/SKILL.md"
}

if [ "${1:-}" = --autoteste ]; then
  falhas=0; T=$(mktemp -d); mkdir -p "$T/pa"
  export KIT_CONF=/dev/null KIT_CACHE="$T/cache" KIT_GERENTE=Gerente KIT_GERENTE_DIR="$T/ga" KIT_PROJETOS="projA:$T/pa" KIT_LIB; mkdir -p "$T/ga"
  for o in startup compact resume; do
    out=$(printf '{"cwd":"%s","source":"%s"}' "$T/ga" "$o" | bash "$0" skill)
    ctx=$(python3 -I -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])' <<<"$out") \
      || { echo "FALHA $o: saída não é JSON válido"; falhas=1; continue; }
    grep -q "Você é o gerente (Gerente)" <<<"$ctx" && grep -q "zelador:" <<<"$ctx" || { echo "FALHA $o: sem identidade ou checagem"; falhas=1; }
    if [ "$o" = resume ]; then grep -q "## Mapa" <<<"$ctx" && { echo "FALHA resume: repetiu a skill"; falhas=1; }
    else grep -q "## Mapa" <<<"$ctx" || { echo "FALHA $o: sem a skill"; falhas=1; }; fi
    [ "${#out}" -lt 10000 ] || { echo "FALHA $o: saída com ${#out} caracteres"; falhas=1; }
    if [ "$o" != resume ]; then grep -qF -- "$(grep -v '^$' "$G/SKILL.md" | tail -1 | cut -c1-80)" <<<"$ctx" || { echo "FALHA $o: a skill não chegou inteira (última linha ausente)"; falhas=1; }; fi
    grep -q "SKILL NÃO CABE" <<<"$ctx" && { echo "FALHA $o: a SKILL.md passou de 9 mil caracteres e foi cortada; enxugue"; falhas=1; }
  done
  out=$(printf '{"cwd":"%s","source":"startup"}' "$T/ga" | bash "$0" pendencias)
  grep -q "Pendências" <<<"$out" || { echo "FALHA: pendências"; falhas=1; }
  [ "${#out}" -lt 10000 ] || { echo "FALHA: pendências com ${#out} caracteres"; falhas=1; }
  grep -q "NÃO CABEM" <<<"$out" && { echo "FALHA: as pendências passaram de 9.500 caracteres; enxugue"; falhas=1; }
  G2=$(mktemp -d); cp "$G/SKILL.md" "$G2/"; python3 -I -c 'print("ç" * 20000)' > "$G2/pendencias.md"
  out=$(printf '{"cwd":"%s","source":"startup"}' "$T/ga" | G_TESTE="$G2" bash "$0" pendencias)
  grep -q "NÃO CABEM" <<<"$out" && ! grep -q ççççç <<<"$out" || { echo "FALHA: pendências grandes não viraram só o caminho"; falhas=1; }
  python3 -I -c 'print("---\nname: x\n---\n" + "ç" * 20000)' > "$G2/SKILL.md"
  out=$(printf '{"cwd":"%s","source":"startup"}' "$T/ga" | G_TESTE="$G2" bash "$0" skill)
  grep -q "SKILL NÃO CABE" <<<"$out" && ! grep -q ççççç <<<"$out" || { echo "FALHA: skill grande não virou só o caminho"; falhas=1; }
  rm -rf "$G2"
  out=$(printf '{"cwd":"%s","source":"startup"}' "$T/pa" | bash "$0" skill)
  [ -z "$out" ] || { echo "FALHA: injetou fora da pasta do gerente"; falhas=1; }
  d="$T/projects/$(kit_codifica_dir "$T/ga")"; mkdir -p "$d"
  out=$(printf '{"cwd":"/tmp","source":"startup","transcript_path":"%s/x.jsonl"}' "$d" | bash "$0" skill)
  [ -n "$out" ] || { echo "FALHA: a pasta da transcrição não identificou o gerente"; falhas=1; }
  rm -rf "$T"
  [ "$falhas" = 0 ] && echo "autoteste: OK" || echo "autoteste: FALHOU"
  exit "$falhas"
fi

entrada=$(cat)
read -r cwd origem tr < <(python3 -I -c 'import json,sys
d=json.loads(sys.stdin.read() or "{}"); print(d.get("cwd",""), d.get("source","startup"), d.get("transcript_path","-"))' <<<"$entrada" 2>/dev/null)
# a pasta da transcrição vale mais que o cwd, que muda com cd
[ "$(kit_sessao_de_transcricao "${tr:-}" "${cwd:-}")" = "$KIT_GERENTE" ] || exit 0
saida "${origem:-startup}" | python3 -I -c 'import json,sys
print(json.dumps({"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": sys.stdin.read()}}, ensure_ascii=False))'
exit 0
