#!/usr/bin/env bash
# SessionStart, global: passagem de bastão entre sessões. A cada início, /clear ou compactação das sessões do kit (o
# gerente e os projetos de KIT_PROJETOS), põe no contexto as orientações obrigatórias de início: a passagem escrita
# pela sessão anterior (~/.claude/passagem/<NOME>.md), a lista de leitura obrigatória (~/.claude/passagem/<NOME>-leitura.md,
# mantida pela própria sessão; sem ela, a lista padrão daqui) e os marcos do compactar-na-fronteira.sh (KIT_PASSAGEM_*;
# o fim é sempre /clear e o /clear sempre espera o agente trabalhando). Na retomada (--resume) não injeta nada: o
# contexto ainda está lá. Outras pastas saem sem nada. Só age com a chave ~/.claude/passagem/ATIVA (o dono liga).
# Teste: passagem-inicio.sh --autoteste
set -u
KIT_LIB="${KIT_LIB:-$HOME/.claude/skills/gerente-da-maquina/lib}"
[ -f "$KIT_LIB/kit.sh" ] || KIT_LIB="$(dirname "$(readlink -f "$0")")/../skills/gerente-da-maquina/lib"
# shellcheck disable=SC1091
. "$KIT_LIB/kit.sh"
PASS="${PASSAGEM_DIR:-$HOME/.claude/passagem}"
DONO="$KIT_DONO"; G="$KIT_GERENTE"
k1=$((KIT_PASSAGEM_AVISO_K / 1000)); k2=$((KIT_PASSAGEM_CAUTION_K / 1000)); k3=$((KIT_PASSAGEM_WARNING_K / 1000))
k4=$((KIT_PASSAGEM_CLEAR_K / 1000)); k5=$((KIT_PASSAGEM_TETO_K / 1000))
MAXIMO=9600  # caracteres do contexto injetado; o Claude Code corta a saída do hook em 10 mil

leitura_padrao() {  # nome cwd
  if [ "$1" = "$G" ]; then
    cat <<LISTA
- A skill gerente-da-maquina e as pendências (já injetadas pelo hook gerente-inicio: leia-as inteiras).
- Os aprendizados do gerente: só o arquivo do assunto em curso, em $HOME/.claude/skills/gerente-da-maquina/aprendizados/.
- As últimas 30 linhas do registro de mudanças: \`tail -30 $KIT_REGISTRO\`.
LISTA
    return
  fi
  cat <<LISTA
- A skill do orquestrador do projeto, em $2/.claude/skills/ (a que o CLAUDE.md do projeto indicar), e os arquivos de apoio que ela mandar ler no início.
- O andamento do projeto (o arquivo que o CLAUDE.md do projeto indicar como "contexto para continuação").
- \`gh pr list\` e \`git -C $2 worktree list\`.
(Lista padrão: escreva a sua, mínima e em ordem, em $PASS/$1-leitura.md.)
LISTA
}

cabe() {  # limite arquivo: tudo ou nada: cabe, imprime inteiro; não cabe, só diz onde ler, sem pedaço
  python3 -I -c 'import sys
t = sys.stdin.read(); n = max(int(sys.argv[1]), 0)
print(t if len(t) <= n else "[NÃO CABE na injeção (" + str(len(t)) + " caracteres): leia o arquivo inteiro com Read em " + sys.argv[2] + ", antes de qualquer outra ação]")' "$1" "$2"
}

saida() {  # nome cwd origem
  local nome="$1" cwd="$2" origem="$3" f="$PASS/$1.md" pre
  pre=$(orientacoes "$nome" "$cwd" "$origem")
  printf '%s\n\n' "$pre"
  if [ -s "$f" ]; then
    echo "Passagem de bastão da sessão anterior ($f, escrita em $(date -r "$f" '+%d/%m %H:%M')):"
    echo
    sed '/^PRONTA PARA O \/clear$/d' "$f" | cabe $((MAXIMO - ${#pre} - 200)) "$f"
  else
    echo "Não há passagem de bastão gravada em $f: siga pelo andamento dos trabalhos."
  fi
}

orientacoes() {  # nome cwd origem
  local nome="$1" cwd="$2" origem="$3" f="$PASS/$1.md" l="$PASS/$1-leitura.md"
  echo "ORIENTAÇÕES OBRIGATÓRIAS DE INÍCIO ($nome; hook passagem-inicio, origem: $origem)"
  echo
  echo "Esta sessão começou com o contexto novo; a memória da anterior não vem junto. Antes de qualquer outra ação, é OBRIGATÓRIO:"
  echo "1. Ler a passagem de bastão abaixo (diz o que está em curso)."
  echo "2. Ler, em ordem, a lista obrigatória abaixo. O CLAUDE.md e o MEMORY.md já vêm carregados pelo Claude Code."
  echo "3. Conferir a passagem com \`gh pr list\` e \`git worktree list\` antes de agir: ela pode estar velha. Se divergir, vale o estado real."
  echo "4. Rearmar os vigias e os agendamentos que a passagem listar, com os comandos dela."
  echo "5. Antes de seguir, escrever a $DONO 3 a 5 linhas: o que entendeu da passagem, o que a conferência mostrou de diferente e o que vai fazer agora."
  echo
  echo "Lista obrigatória de leitura ($([ -s "$l" ] && echo "$l" || echo padrão)):"
  if [ -s "$l" ]; then cabe 2500 "$l" < "$l"; else leitura_padrao "$nome" "$cwd"; fi
  echo
  echo "Limite de tamanho da sessão (vale para todas as sessões):"
  echo "- O fim é sempre /clear, nunca compactação: a passagem de bastão é tudo o que a sessão nova vai saber, então tem de ser muito boa."
  echo "- Marcos do hook compactar-na-fronteira: ${k1}k AVISO (não inicie trabalho novo; deixe finalizar o que já está em andamento: testes, codificações, revisões, CI, merges, sem interromper nenhum agente; atualize o andamento pelas regras do projeto; escreva a passagem); ${k2}k CAUTION (em ${k4}k o /clear entra à força); ${k3}k WARNING (faça a passagem já, sem iniciar nada; interromper agente não é ordem do aviso, é decisão do orquestrador); ${k4}k /clear com ou sem passagem, assim que nenhum agente estiver trabalhando (o /clear mata com SIGKILL o comando que o agente estiver rodando); ${k5}k alerta: com agente ainda trabalhando, pare tudo e mande PushNotification a $DONO; o /clear sempre espera o agente."
  echo "- A passagem fica em $f; no aviso de ${k1}k o hook diz o que ela tem de conter. Última linha exatamente \`PRONTA PARA O /clear\`; depois, encerre o turno: com a passagem pronta e nenhum agente trabalhando, a automação digita /clear."
}

if [ "${1:-}" = --autoteste ]; then
  T=$(mktemp -d); falhas=0; touch "$T/ATIVA"; mkdir -p "$T/ga" "$T/pa" "$T/pb"
  export KIT_CONF=/dev/null KIT_CACHE="$T/cache" KIT_GERENTE=Gerente KIT_GERENTE_DIR="$T/ga" KIT_PROJETOS="projA:$T/pa projB:$T/pb" KIT_LIB
  . "$KIT_LIB/kit.sh"
  roda() { printf '{"cwd":"%s","source":"%s"}' "$1" "$2" | PASSAGEM_DIR="$T" bash "$0"; }
  ctx() { python3 -I -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])'; }
  for o in startup clear compact; do
    c=$(roda "$T/pa" "$o" | ctx) || { echo "FALHA $o: não é JSON"; falhas=1; continue; }
    grep -q "OBRIGATÓRIO" <<<"$c" && grep -q "skill do orquestrador" <<<"$c" && grep -q "200k" <<<"$c" && grep -q "275k WARNING" <<<"$c" && grep -q "300k /clear" <<<"$c" \
      || { echo "FALHA $o: faltam as orientações"; falhas=1; }
    grep -q "Não há passagem" <<<"$c" || { echo "FALHA $o: inventou passagem"; falhas=1; }
  done
  printf 'Feito: X.\nPróximos: Y.\nPRONTA PARA O /clear\n' > "$T/projB.md"
  printf -- '- ler Z\n' > "$T/projB-leitura.md"
  c=$(roda "$T/pb" clear | ctx)
  grep -q "Próximos: Y" <<<"$c" || { echo "FALHA: não trouxe a passagem"; falhas=1; }
  grep -q "^- ler Z" <<<"$c" || { echo "FALHA: não usou a lista da sessão"; falhas=1; }
  grep -q "^PRONTA PARA O /clear$" <<<"$c" && { echo "FALHA: repetiu o marcador"; falhas=1; }
  c=$(roda "$T/ga" clear | ctx); grep -q "gerente-da-maquina" <<<"$c" || { echo "FALHA: gerente"; falhas=1; }
  grep -q "tail -30" <<<"$c" || { echo "FALHA: leitura do gerente sem o registro de mudanças"; falhas=1; }
  [ -z "$(roda "$T/pa" resume)" ] || { echo "FALHA: injetou na retomada"; falhas=1; }
  [ -z "$(roda /tmp startup)" ] || { echo "FALHA: injetou fora das sessões do kit"; falhas=1; }
  rm "$T/ATIVA"; [ -z "$(roda "$T/pa" clear)" ] || { echo "FALHA: injetou com a chave desligada"; falhas=1; }; touch "$T/ATIVA"
  grep -q "^5\. Antes de seguir" <<<"$c" || { echo "FALHA: sem o resumo de entendimento"; falhas=1; }
  head -c 9500 /dev/zero | tr '\0' a > "$T/projA.md"; head -c 4000 /dev/zero | tr '\0' b > "$T/projA-leitura.md"
  out=$(roda "$T/pa" clear); [ "${#out}" -lt 10000 ] || { echo "FALHA: saída com ${#out} caracteres"; falhas=1; }
  grep -q "NÃO CABE" <<<"$out" || { echo "FALHA: não avisou que não cabe"; falhas=1; }
  grep -q aaaaaaaaaa <<<"$out" && { echo "FALHA: injetou pedaço da passagem"; falhas=1; }
  grep -q bbbbbbbbbb <<<"$out" && { echo "FALHA: injetou pedaço da lista"; falhas=1; }
  rm "$T/projA-leitura.md"
  for pre in "" a; do  # as duas paridades: o corte não pode cair no meio de um caractere de 2 bytes
    python3 -I -c 'import sys; print(sys.argv[1] + "ç" * 12000)' "$pre" > "$T/projA.md"
    c=$(roda "$T/pa" clear | ctx) || { echo "FALHA: acentos no corte quebraram o JSON"; falhas=1; }
    [ "${#c}" -lt 10000 ] && grep -q "Read em $T/projA.md" <<<"$c" || { echo "FALHA: passagem grande ($pre)"; falhas=1; }
    grep -q ççççç <<<"$c" && { echo "FALHA: injetou pedaço da passagem grande ($pre)"; falhas=1; }
  done
  printf 'curta\nPRONTA PARA O /clear\n' > "$T/projA.md"
  c=$(roda "$T/pa" clear | ctx); grep -q "NÃO CABE" <<<"$c" && { echo "FALHA: recusou passagem curta"; falhas=1; }; grep -q "^curta$" <<<"$c" || { echo "FALHA: passagem curta ausente"; falhas=1; }
  # a pasta da transcrição vale mais que o cwd (cd no meio da sessão)
  d="$T/projects/$(kit_codifica_dir "$T/pb")"; mkdir -p "$d"
  c=$(printf '{"cwd":"/tmp","source":"clear","transcript_path":"%s/x.jsonl"}' "$d" | PASSAGEM_DIR="$T" bash "$0" | ctx); grep -q "(projB;" <<<"$c" || { echo "FALHA: transcrição não identificou a sessão"; falhas=1; }
  rm -rf "$T"
  [ "$falhas" = 0 ] && echo "autoteste: OK" || echo "autoteste: FALHOU"
  exit "$falhas"
fi

read -r cwd origem tr < <(python3 -I -c 'import json,sys
d=json.loads(sys.stdin.read() or "{}"); print(d.get("cwd",""), d.get("source","startup"), d.get("transcript_path","-"))' 2>/dev/null)
[ "${origem:-startup}" = resume ] && exit 0
[ -e "$PASS/ATIVA" ] || exit 0
nome=$(kit_sessao_de_transcricao "${tr:-}" "${cwd:-}")
[ -n "$nome" ] || exit 0
cwd="$(kit_dir_da_sessao "$nome")"
saida "$nome" "$cwd" "${origem:-startup}" | python3 -I -c 'import json,sys
print(json.dumps({"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": sys.stdin.read()}}, ensure_ascii=False))'
exit 0
