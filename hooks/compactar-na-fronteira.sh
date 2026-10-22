#!/usr/bin/env bash
# Stop, global: passagem de bastão por tamanho da sessão. O fim é sempre /clear, nunca compactação, por isso a
# passagem tem de ser muito boa. Marcos (KIT_PASSAGEM_*, em tokens de contexto; padrões 200/250/275/300/330 mil).
# Uma mensagem por etapa e por conversa (código 2):
#   AVISO    comece a passagem: espere o trabalho em andamento terminar, atualize o andamento, escreva a passagem em
#            ~/.claude/passagem/<NOME>.md com a última linha "PRONTA PARA O /clear" e encerre o turno.
#   CAUTION  o aviso volta: no marco do /clear ele entra à força (se nenhum agente trabalhar).
#   WARNING  faça a passagem já; não manda interromper agente (decisão do orquestrador).
#   CLEAR    /clear com ou sem passagem, assim que nenhum agente estiver trabalhando (o /clear mata com SIGKILL o
#            comando que o agente estiver rodando; o agente sobrevive e entrega à sessão nova).
#   TETO     alerta: o /clear sempre espera o agente; a sessão para tudo e manda PushNotification ao dono; sem
#            agente, /clear. A compactação automática (KIT_COMPACT_REDE) é a última rede.
# Com a passagem pronta (escrita depois do 1º aviso desta conversa) e nenhum subagente trabalhando (transcrição
# escrita nos últimos 3 min, ou .meta.json sem "finished" com a transcrição escrita nas últimas 2 h), o fim do turno
# lança em segundo plano o limpar-sessao, que digita /clear no pane do tmux e manda a retomada; o passagem-inicio.sh
# (SessionStart) injeta as orientações obrigatórias e a passagem na sessão nova.
# Sessões que não são o gerente nem um projeto de KIT_PROJETOS só recebem os avisos, para o dono digitar /clear.
# Só age com a chave ~/.claude/passagem/ATIVA (o dono liga). Estado: $KIT_CACHE/compactar/; log: $KIT_CACHE/passagem.log.
# Teste: --autoteste
set -u
KIT_LIB="${KIT_LIB:-$HOME/.claude/skills/gerente-da-maquina/lib}"
[ -f "$KIT_LIB/kit.sh" ] || KIT_LIB="$(dirname "$(readlink -f "$0")")/../skills/gerente-da-maquina/lib"
# shellcheck disable=SC1091
. "$KIT_LIB/kit.sh"
K1="$KIT_PASSAGEM_AVISO_K"; K2="$KIT_PASSAGEM_CAUTION_K"; K3="$KIT_PASSAGEM_WARNING_K"; K4="$KIT_PASSAGEM_CLEAR_K"
K5="$KIT_PASSAGEM_TETO_K"; R="$KIT_COMPACT_REDE"
k1=$((K1 / 1000)); k2=$((K2 / 1000)); k3=$((K3 / 1000)); k4=$((K4 / 1000)); k5=$((K5 / 1000)); kr=$((R / 1000))
EST="${COMPACTAR_ESTADO:-$KIT_CACHE/compactar}"
PASS="${PASSAGEM_DIR:-$HOME/.claude/passagem}"
LIMPAR="${LIMPAR_CMD:-$HOME/.local/bin/limpar-sessao}"
LOG="${PASSAGEM_LOG:-$KIT_CACHE/passagem.log}"
DONO="$KIT_DONO"
MARCA='PRONTA PARA O /clear'

nome_da_sessao() { kit_sessao_de_transcricao "${2:-}" "${1:-}"; }  # cwd [transcrição] -> nome

contexto() {  # tokens de entrada da última resposta da conversa principal
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

pane_da_sessao() {  # "socket pane" do tmux cujo processo é ancestral deste hook
  [ -n "${PASSAGEM_PANE:-}" ] && { echo "$PASSAGEM_PANE"; return; }
  local anc=" " p=$$ s
  while [ "$p" -gt 1 ] 2>/dev/null; do anc="$anc$p "; p=$(awk '{print $4}' "/proc/$p/stat" 2>/dev/null || echo 1); done
  for s in /tmp/tmux-"$(id -u)"/*; do
    [ -S "$s" ] || continue
    tmux -S "$s" list-panes -a -F '#{pane_pid} #{pane_id}' 2>/dev/null | while read -r pid id; do
      case "$anc" in *" $pid "*) echo "$s $id" ;; esac
    done
  done | head -1
}

passagem_pronta() {  # arquivo, marco do 1º aviso
  [ -f "$1" ] && [ -f "$2" ] && [ "$1" -nt "$2" ] && [ "$(grep -v '^[[:space:]]*$' "$1" | tail -1)" = "$MARCA" ]
}

agente_trabalhando() {  # subagente sem "finished" no .meta.json e transcrição escrita há < 2 h (o agente que espera um
  # comando longo não escreve nada até ele acabar); sem .meta.json (o agente que veio de antes de um /clear), escrita
  # há < 3 min. Com "finished", nunca: o agente acaba de escrever o relatório e não conta como trabalhando.
  local d="${1%.jsonl}/subagents" j m
  for j in $(find "$d" -name '*.jsonl' -mmin -120 2>/dev/null); do
    m="${j%.jsonl}.meta.json"
    if [ -f "$m" ]; then grep -q '"finished": *true' "$m" || return 0
    elif [ -n "$(find "$j" -mmin -3 2>/dev/null)" ]; then return 0; fi
  done
  return 1
}

etapa_de() {  # tokens -> 0..5
  if [ "$1" -ge "$K5" ]; then echo 5; elif [ "$1" -ge "$K4" ]; then echo 4; elif [ "$1" -ge "$K3" ]; then echo 3
  elif [ "$1" -ge "$K2" ]; then echo 2; elif [ "$1" -ge "$K1" ]; then echo 1; else echo 0; fi
}

limpar() {  # modo (pronta|forcado) -> despacha o limpar-sessao
  local alvo; alvo=$(pane_da_sessao)
  touch "$EST/$sid.limpando"
  if [ -z "$alvo" ]; then
    echo "$(date -Iseconds) $nome ($sid): /clear ($1), mas não achei o pane do tmux; $DONO digita /clear" >> "$LOG"
    [ "$ativo" = true ] && exit 0
    echo "Hora do /clear ($1), mas esta sessão não roda num pane do tmux que eu ache: mande a $DONO uma PushNotification curta \"$nome: digite /clear\" e encerre o turno." >&2
    exit 2
  fi
  echo "$(date -Iseconds) $nome ($sid): /clear ($1, ${k}k); limpar-sessao em $alvo" >> "$LOG"
  # shellcheck disable=SC2086
  setsid "$LIMPAR" $alvo "$nome" "$sid" "$1" >> "$LOG" 2>&1 < /dev/null &
  exit 0
}

if [ "${1:-}" = --autoteste ]; then
  T=$(mktemp -d); falhas=0; mkdir -p "$T/pass" "$T/ga" "$T/pa" "$T/pb"; touch "$T/pass/ATIVA"
  export KIT_CONF=/dev/null KIT_CACHE="$T/cache" KIT_GERENTE=Gerente KIT_GERENTE_DIR="$T/ga" KIT_PROJETOS="projA:$T/pa projB:$T/pb"
  export KIT_PASSAGEM_AVISO_K=200000 KIT_PASSAGEM_CAUTION_K=250000 KIT_PASSAGEM_WARNING_K=275000
  export KIT_PASSAGEM_CLEAR_K=300000 KIT_PASSAGEM_TETO_K=330000 KIT_COMPACT_REDE=360000 KIT_LIB
  mk() { printf '{"type":"assistant","isSidechain":false,"message":{"usage":{"input_tokens":5,"cache_read_input_tokens":%s,"cache_creation_input_tokens":0}}}\n' "$1" > "$T/s.jsonl"; }
  roda() {  # cwd agente_ativo(0/1) stop_hook_active -> código; a mensagem fica em $T/err
    rm -rf "$T/s/subagents"; mkdir -p "$T/s/subagents"; [ "$2" = 1 ] && touch "$T/s/subagents/agent-x.jsonl"
    printf '{"session_id":"s","transcript_path":"%s","stop_hook_active":%s,"cwd":"%s"}' "$T/s.jsonl" "$3" "$1" \
      | COMPACTAR_ESTADO="$T/est" PASSAGEM_DIR="$T/pass" PASSAGEM_LOG="$T/log" PASSAGEM_PANE="/tmp/sock %9" \
        LIMPAR_CMD="$T/limpar" bash "$0" 2>"$T/err"; r=$?; sleep 0.3; echo $r  # o despacho roda em segundo plano
  }
  printf '#!/bin/sh\necho "$@" >> %s/chamadas\n' "$T" > "$T/limpar"; chmod +x "$T/limpar"
  confere() { [ "$2" = "$3" ] || { echo "FALHA $1: $2, esperado $3"; falhas=1; }; }
  chamou() { [ "$(cat "$T/chamadas" 2>/dev/null)" = "$1" ] || { echo "FALHA $2: chamadas='$(cat "$T/chamadas" 2>/dev/null)'"; falhas=1; }; }
  S="$T/pa"
  mk 190000; confere "abaixo do aviso" "$(roda "$S" 0 false)" 0
  mk 205000; confere "aviso mesmo com agente" "$(roda "$S" 1 false)" 2
  grep -q "PRONTA PARA O /clear" "$T/err" && grep -q "$T/pass/projA.md" "$T/err" || { echo "FALHA: aviso sem o protocolo"; falhas=1; }
  grep -q "Armadilhas" "$T/err" && grep -q "150 linhas" "$T/err" || { echo "FALHA: aviso sem armadilhas ou teto"; falhas=1; }
  confere "stop_hook_active: deixa encerrar" "$(roda "$S" 0 true)" 0
  mk 255000; confere "stop_hook_active: sem mensagem nem na etapa nova" "$(roda "$S" 0 true)" 0; rm -f "$T/est/s.etapa"; echo 1 > "$T/est/s.etapa"
  mk 240000; confere "mesma etapa: não repete" "$(roda "$S" 0 false)" 0
  mk 255000; confere "CAUTION" "$(roda "$S" 1 false)" 2; grep -q "CAUTION" "$T/err" && grep -q "300k" "$T/err" || { echo "FALHA: CAUTION"; falhas=1; }
  mk 280000; confere "WARNING" "$(roda "$S" 1 false)" 2; grep -q "WARNING" "$T/err" || { echo "FALHA: WARNING"; falhas=1; }
  confere "WARNING não repete" "$(roda "$S" 0 false)" 0
  chamou "" "nada despachado sem passagem abaixo do marco do /clear"
  sleep 1; printf 'Feito.\nPRONTA PARA O /clear\n' > "$T/pass/projA.md"
  confere "passagem pronta, agente trabalhando: espera" "$(roda "$S" 1 false)" 0; chamou "" "limpou com agente"
  confere "passagem pronta, turno após aviso: limpa" "$(roda "$S" 0 true)" 0; chamou "/tmp/sock %9 projA s pronta" "passagem pronta"
  confere "já despachado: não repete" "$(roda "$S" 0 false)" 0; chamou "/tmp/sock %9 projA s pronta" "despachou duas vezes"
  rm -rf "$T/est" "$T/chamadas"; mk 205000; roda "$S" 0 false >/dev/null
  printf 'velha\nPRONTA PARA O /clear\n' > "$T/pass/projA.md"; touch -d '-1 hour' "$T/pass/projA.md"
  confere "passagem anterior ao aviso: não limpa" "$(roda "$S" 0 false)" 0; chamou "" "passagem velha"
  sleep 1; printf 'sem marca\n' > "$T/pass/projA.md"
  confere "passagem sem a marca: não limpa" "$(roda "$S" 0 false)" 0; chamou "" "sem a marca"
  mk 301000; confere "marco do /clear com agente: adia e avisa" "$(roda "$S" 1 false)" 2; chamou "" "limpou com agente"
  grep -q "330k" "$T/err" || { echo "FALHA: aviso do /clear sem o teto"; falhas=1; }
  confere "com agente: não repete o aviso" "$(roda "$S" 1 false)" 0; chamou "" "limpou com agente (2)"
  roda_meta() {  # agente com o comando longo: transcrição velha, .meta.json sem finished
    rm -rf "$T/s/subagents"; mkdir -p "$T/s/subagents"; touch -d '-30 min' "$T/s/subagents/agent-y.jsonl"
    printf '{"agentType":"x"%s}' "$1" > "$T/s/subagents/agent-y.meta.json"
    printf '{"session_id":"s","transcript_path":"%s","stop_hook_active":false,"cwd":"%s"}' "$T/s.jsonl" "$S" \
      | COMPACTAR_ESTADO="$T/est" PASSAGEM_DIR="$T/pass" PASSAGEM_LOG="$T/log" PASSAGEM_PANE="/tmp/sock %9" \
        LIMPAR_CMD="$T/limpar" bash "$0" 2>"$T/err"; r=$?; sleep 0.3; echo $r
  }
  confere "agente no comando longo: espera" "$(roda_meta '')" 0; chamou "" "limpou com agente no comando longo"
  confere "agente terminado: limpa" "$(roda_meta ',"finished":true')" 0; chamou "/tmp/sock %9 projA s forcado" "sem agente"
  rm -rf "$T/est" "$T/chamadas"; mk 205000; roda "$S" 0 false >/dev/null; sleep 1; printf 'x\nPRONTA PARA O /clear\n' > "$T/pass/projA.md"
  rm -rf "$T/s/subagents"; mkdir -p "$T/s/subagents"; touch "$T/s/subagents/agent-z.jsonl"; echo '{"finished":true}' > "$T/s/subagents/agent-z.meta.json"
  printf '{"session_id":"s","transcript_path":"%s","stop_hook_active":false,"cwd":"%s"}' "$T/s.jsonl" "$S" \
    | COMPACTAR_ESTADO="$T/est" PASSAGEM_DIR="$T/pass" PASSAGEM_LOG="$T/log" PASSAGEM_PANE="/tmp/sock %9" LIMPAR_CMD="$T/limpar" bash "$0" 2>"$T/err"
  sleep 0.3; chamou "/tmp/sock %9 projA s pronta" "agente que acabou de terminar (finished, escrito agora) segurou o /clear"
  rm -rf "$T/est" "$T/chamadas"; mk 301000
  confere "marco do /clear sem agente nem passagem: limpa" "$(roda "$S" 0 false)" 0; chamou "/tmp/sock %9 projA s forcado" "marco do /clear"
  rm -rf "$T/est" "$T/chamadas"; mk 331000
  confere "teto com agente: alerta, não limpa" "$(roda "$S" 1 false)" 2; chamou "" "teto limpou com agente"
  grep -q "PushNotification" "$T/err" && grep -q "esperando agente" "$T/err" || { echo "FALHA: alerta do teto"; falhas=1; }
  confere "teto com agente: não repete o alerta" "$(roda "$S" 1 false)" 0; chamou "" "teto limpou com agente (2)"
  confere "teto sem agente: limpa" "$(roda "$S" 0 false)" 0; chamou "/tmp/sock %9 projA s forcado" "teto sem agente"
  rm -rf "$T/est" "$T/chamadas"; mv "$T/pass/ATIVA" "$T/desligada"; mk 340000
  confere "chave desligada: nada" "$(roda "$S" 0 false)" 0; chamou "" "agiu com a chave desligada"; mv "$T/desligada" "$T/pass/ATIVA"
  rm -rf "$T/est" "$T/chamadas"; mk 340000; confere "já entra acima do marco do /clear: limpa" "$(roda "$S" 0 false)" 0
  chamou "/tmp/sock %9 projA s forcado" "entrada acima do marco do /clear"
  rm -rf "$T/est" "$T/chamadas"; mk 205000; confere "pasta desconhecida: só avisa" "$(roda /tmp 0 false)" 2
  grep -q "/clear" "$T/err" || { echo "FALHA: pasta desconhecida sem o /clear"; falhas=1; }
  mk 305000; confere "pasta desconhecida no marco do /clear: avisa, não limpa" "$(roda /tmp 0 false)" 2; chamou "" "limpou em pasta desconhecida"
  rm -rf "$T/est" "$T/chamadas"; d="$T/projects/$(kit_codifica_dir "$T/ga")"; mkdir -p "$d"; mv "$T/s.jsonl" "$d/s.jsonl"; mk() { :; }
  printf '{"session_id":"s","transcript_path":"%s","stop_hook_active":false,"cwd":"/tmp"}' "$d/s.jsonl" \
    | COMPACTAR_ESTADO="$T/est" PASSAGEM_DIR="$T/pass" PASSAGEM_LOG="$T/log" PASSAGEM_PANE="/tmp/sock %9" LIMPAR_CMD="$T/limpar" bash "$0" 2>"$T/err"
  sleep 0.3; chamou "/tmp/sock %9 Gerente s forcado" "cwd mudado com cd tirou o gerente do protocolo"
  rm -rf "$T"
  [ "$falhas" = 0 ] && echo "autoteste: OK" || echo "autoteste: FALHOU"
  exit "$falhas"
fi

read -r sid tr ativo cwd < <(python3 -I -c 'import json,sys
d=json.loads(sys.stdin.read() or "{}")
print(d.get("session_id","-"), d.get("transcript_path","-"), str(d.get("stop_hook_active",False)).lower(), d.get("cwd",""))' 2>/dev/null)
[ -e "$PASS/ATIVA" ] || exit 0
ativo="${ativo:-false}"
nome=$(nome_da_sessao "${cwd:-}" "${tr:-}")
mkdir -p "$EST"
ctx=$(contexto "${tr:--}"); k=$((ctx / 1000))
etapa=$(etapa_de "$ctx")
[ "$etapa" -gt 0 ] || exit 0

if [ -n "$nome" ] && [ ! -e "$EST/$sid.limpando" ]; then
  [ "$etapa" -ge 4 ] && ! agente_trabalhando "${tr:--}" && limpar forcado  # com agente, espera sempre
  if passagem_pronta "$PASS/$nome.md" "$EST/$sid.aviso"; then
    agente_trabalhando "${tr:--}" && exit 0
    limpar pronta
  fi
fi
[ -e "$EST/$sid.limpando" ] && exit 0
[ "$ativo" = true ] && exit 0  # turno que continua depois de um aviso: sem nova mensagem, para não entrar em laço

ult=$(cat "$EST/$sid.etapa" 2>/dev/null || echo 0)
[ "$etapa" -gt "$ult" ] || exit 0
echo "$etapa" > "$EST/$sid.etapa"
if [ -z "$nome" ]; then
  echo "Contexto em ${k}k (avisos em ${k1}k, ${k2}k e ${k3}k; em ${k4}k é /clear, assim que nenhum agente estiver trabalhando; em ${k5}k, alerta se ainda houver agente: o /clear sempre espera o agente). Registre o que está no meio, mande a $DONO uma PushNotification curta \"<nome da sessão> em ${k}k: pronta para o /clear\" e encerre o turno com no máximo uma linha." >&2
  exit 2
fi
[ -f "$EST/$sid.aviso" ] || touch "$EST/$sid.aviso"
echo "$(date -Iseconds) $nome ($sid): etapa $etapa em ${k}k" >> "$LOG"
P="Escreva a passagem em $PASS/$nome.md. Ela é tudo o que a sessão nova vai saber (o fim é sempre /clear, nunca compactação), então tem de ser muito boa: o que foi feito, o estado de cada trabalho e os próximos passos imediatos e, quando houver, PRs abertos (número, head SHA, passo do ciclo, achados, dono), agentes ainda trabalhando (papel, worktree, branch, como reconhecer o fim), vigias e crons a rearmar com o comando exato, bastão e orçamento (com exceções de $DONO), situação da main e defeitos de CI, decisões e perguntas pendentes de $DONO, decisões e lições fora do repositório, limpezas pendentes e promessas com prazo, e uma seção \"Armadilhas\" (o que não funcionou e não deve ser repetido). Até ~150 linhas; com até ~6 mil caracteres ela entra inteira no início da sessão nova, acima disso o hook só aponta o arquivo e a sessão nova tem de lê-lo. Não copie o que já está em arquivo (pendências, andamento do projeto): aponte o arquivo. Última linha exatamente \`$MARCA\`; depois, encerre o turno. Esse é o seu ok: ao fim do turno, com a passagem pronta e nenhum agente trabalhando, a automação digita /clear e a sessão nova recebe as orientações obrigatórias e a passagem."
case "$etapa" in
  1) echo "AVISO DE TAMANHO DA SESSÃO: contexto em ${k}k. Comece a passagem de bastão: não inicie trabalho novo; deixe finalizar o que já está em andamento (testes, codificações, revisões, CI, merges), sem interromper nenhum agente; atualize o documento de andamento pelas regras do projeto. $P Próximos marcos: CAUTION em ${k2}k, WARNING em ${k3}k, /clear à força em ${k4}k (assim que nenhum agente estiver trabalhando) e alerta em ${k5}k se ainda houver agente (o /clear sempre espera o agente). Encerre este turno com no máximo uma linha." >&2 ;;
  2) echo "AVISO DE TAMANHO DA SESSÃO (CAUTION): contexto em ${k}k. Não inicie trabalho novo; deixe finalizar o que já está em andamento, sem interromper nenhum agente, e faça a passagem. $P Próximos marcos: WARNING em ${k3}k, /clear à força em ${k4}k com ou sem passagem (assim que nenhum agente estiver trabalhando) e alerta em ${k5}k se ainda houver agente (o /clear sempre espera o agente). Encerre este turno com no máximo uma linha." >&2 ;;
  3) echo "AVISO DE TAMANHO DA SESSÃO (WARNING): contexto em ${k}k. Faça a passagem já, sem iniciar nada novo: registre o estado de cada trabalho (agentes vivos, PRs, testes, CI). Este aviso não manda interromper nenhum agente: o que fazer com os agentes em andamento é decisão sua. $P Próximos marcos: /clear à força em ${k4}k, com ou sem passagem, assim que nenhum agente estiver trabalhando; alerta em ${k5}k se ainda houver agente (o /clear sempre espera o agente)." >&2 ;;
  4) echo "AVISO DE TAMANHO DA SESSÃO: contexto em ${k}k. O /clear está adiado só porque há agente trabalhando: ele entra no fim do primeiro turno sem agente trabalhando, com ou sem passagem; com agente, ele espera sempre e em ${k5}k vira alerta a $DONO. Não inicie nada; deixe a passagem pronta e encerre o turno com no máximo uma linha." >&2 ;;
  5) echo "ALERTA DE TAMANHO DA SESSÃO: contexto em ${k}k e ainda há agente trabalhando. O /clear sempre espera o agente: não inicie nada, não interrompa o agente, deixe a passagem pronta, mande a $DONO uma PushNotification curta \"$nome em ${k}k: esperando agente para o /clear\" e encerre o turno com no máximo uma linha. A compactação automática em ${kr}k é a última rede." >&2 ;;
esac
exit 2
