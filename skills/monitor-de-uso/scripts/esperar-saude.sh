#!/usr/bin/env bash
# Vigia de saúde por MUDANÇA DE ESTADO: lê $KIT_CACHE/saude.log (gravado por saude-maquina.sh) e só
# termina, imprimindo o aviso, quando aparece um problema novo, quando ele piora ou quando persiste além do
# prazo de reaviso. Feito para rodar em segundo plano numa sessão: ao receber, rode de novo.
# Estado = conjunto de condições, cada uma confirmada em N amostras seguidas (padrão 4, ~2 min) para
# não acordar por oscilação:
#   temp:normal|alta|critica|sem_leitura  (pacote da CPU: alta >= 90 °C, crítica >= 96 °C; sem ele, a GPU:
#   alta >= 85 °C, crítica >= 90 °C; sem nenhuma das duas = sem_leitura). Histerese de 3 °C pelo estado
#   anterior: a CPU só desce de crítica para alta abaixo de 93 °C e de alta para normal abaixo de 87 °C; a
#   GPU, abaixo de 87 °C e de 82 °C. Subir de grau usa sempre o limite de entrada.
#   cpu_saturada (PSI cpu > 60%, sai com < 45%) · memoria_baixa (disponível < 3 GB)
#   · pressao_mem (PSI mem > 10%)
#   docker_fora (coluna de contêineres "-") · coletor_parado (última linha com mais de 3 min)
#   disco_baixo (menos de 40 GB livres na / , onde ficam o sistema e o /var/lib/docker, ou no $HOME, onde
#   ficam o repositório, os worktrees e os caches) · disco_critico (menos de 15 GB)
# Famílias e cronômetro: temp:alta e temp:critica são a família temp; disco_baixo e disco_critico, a
# família disco; as demais condições são famílias sozinhas. Uma família avisa quando aparece; enquanto
# continua presente (mesmo trocando de grau), só avisa de novo (a) depois de SAUDE_REAVISO_MIN minutos
# (padrão 30) desde o último aviso, ou (b) quando o grau sobe (alta -> crítica, baixo -> crítico) pela 1ª vez
# desde o último aviso. A descida de grau nunca avisa.
# Carência na saída: a família
# que some só tem o cronômetro apagado depois de SAUDE_CARENCIA_MIN minutos (padrão 15) seguidos ausente, em
# silêncio. Se volta antes, não é problema novo: o cronômetro e o grau continuam os do último aviso, e o
# reaviso conta a partir dele. Cronômetros em <estado>-cronometros, uma linha por família:
# "família época_do_último_aviso grau_no_último_aviso [época_em_que_sumiu]" (a 4ª coluna só existe durante a
# carência; o formato antigo, de 3 colunas, é lido igual).
# Colunas do log: data_hora l1 l5 mem swp psi_cpu psi_mem psi_io cont jobs cpu_pkg cpu_max mhz gpu ...
# A 1ª coluna é AAAA-MM-DDTHH:MM:SS desde 18/10/2026; as linhas antigas, só HH:MM:SS, também valem.
# Variáveis (para provas, sem tocar nos arquivos reais): SAUDE_LOG, SAUDE_ESTADO, SAUDE_INTERVALO_S (30),
# SAUDE_REAVISO_MIN (30) ou SAUDE_REAVISO_S (segundos, tem precedência), SAUDE_CARENCIA_MIN (15) ou
# SAUDE_CARENCIA_S, SAUDE_DISCO_GB (espaço livre falso, no lugar do df), N (4).
# Uso: esperar-saude.sh               o vigia
#      esperar-saude.sh --autoteste   cenários contra log e estado falsos (mktemp -d em $KIT_CACHE)
KITSH="$(dirname "$(readlink -f "${BASH_SOURCE[0]:-$0}")")/../../gerente-da-maquina/lib/kit.sh"
# shellcheck disable=SC1090
[ -f "$KITSH" ] && . "$KITSH"
: "${KIT_CACHE:=$HOME/.cache/gerente-maquina}"
LOG="${SAUDE_LOG:-${KIT_SAUDE_LOG:-$KIT_CACHE/saude.log}}"
EST="${SAUDE_ESTADO:-$KIT_CACHE/saude-estado}"
CRON="$EST-cronometros"
N="${N:-4}"
REAVISO_S="${SAUDE_REAVISO_S:-$(( ${SAUDE_REAVISO_MIN:-30} * 60 ))}"
CARENCIA_S="${SAUDE_CARENCIA_S:-$(( ${SAUDE_CARENCIA_MIN:-15} * 60 ))}"
INTERVALO="${SAUDE_INTERVALO_S:-30}"
AMOSTRA='^([0-9]{4}-[0-9]{2}-[0-9]{2}T)?[0-9]{2}:[0-9]{2}:[0-9]{2} '
classifica() {  # uma linha do log -> lista de condições
  # Histerese pelo estado confirmado anterior ($EST). CPU: entra em cpu_saturada com PSI > 60% e só sai com
  # < 45% (oscilava em volta de 60, 14/10). Temperatura: sai de cada grau 3 °C abaixo do limite de entrada
  # (oscilava em volta de 90 e de 96, 19/10).
  local ant lim=60 tg=0; ant=" $(cat "$EST" 2>/dev/null) "
  [[ $ant == *" cpu_saturada "* ]] && lim=45
  [[ $ant == *" temp:alta "* ]] && tg=1
  [[ $ant == *" temp:critica "* ]] && tg=2
  awk -v lim="$lim" -v tg="$tg" '
    function grau_t(v, alta, crit) {  # tg = grau anterior: 2 crítica, 1 alta, 0 o resto
      if (v >= (tg >= 2 ? crit - 3 : crit)) return " temp:critica"
      if (v >= (tg >= 1 ? alta - 3 : alta)) return " temp:alta"
      return " temp:normal" }
    {
    # CPU pelo kernel ($11, temperatura.sh); sem ela, a GPU pelo nvidia-smi ($14), com limites próprios.
    t=$11; g=$14; s="";
    if (t ~ /^[0-9]/) s=s grau_t(t+0, 90, 96)
    else if (g ~ /^[0-9]/) s=s grau_t(g+0, 85, 90)
    else s=s" temp:sem_leitura";
    if ($4+0<3) s=s" memoria_baixa"; if ($7+0>10) s=s" pressao_mem"; if ($6+0>lim) s=s" cpu_saturada";
    if ($9=="-") s=s" docker_fora";
    print substr(s,2) }' <<<"$1"
}
estado_atual() {
  [ -f "$LOG" ] || { echo "coletor_parado"; return; }
  idade=$(( $(date +%s) - $(stat -c %Y "$LOG") ))
  [ "$idade" -gt 180 ] && { echo "coletor_parado"; return; }
  # -a: um desligamento abrupto deixa bytes nulos no log, e sem ele o grep o trata como binário.
  mapfile -t L < <(grep -aE "$AMOSTRA" "$LOG" | tail -n "$N")
  [ "${#L[@]}" -lt "$N" ] && { cat "$EST" 2>/dev/null; return; }
  primeiro=$(classifica "${L[0]}")
  for l in "${L[@]:1}"; do [ "$(classifica "$l")" = "$primeiro" ] || { cat "$EST" 2>/dev/null; return; }; done
  echo "$primeiro$(disco)"
}
disco() {  # o menor espaço livre (GB) entre a / e o $HOME -> condição, ou nada
  if [ -n "${SAUDE_DISCO_GB:-}" ]; then livre=$SAUDE_DISCO_GB
  else livre=$(df -BG --output=avail / "$HOME" 2>/dev/null | tail -n +2 | tr -dc '0-9\n' | sort -n | head -1); fi
  [ -z "$livre" ] && return
  if [ "$livre" -lt 15 ]; then echo " disco_critico"; elif [ "$livre" -lt 40 ]; then echo " disco_baixo"; fi
}
# Só acorda o orquestrador por problema que pede ação. Não acordam: temp:normal, temp:sem_leitura e a volta ao normal. A cpu_saturada acorda: no
# Linux nativo não há núcleos reservados ao dono (como fazia o .wslconfig), e a CPU saturada trava a máquina
# do dia a dia dele (auditoria de 18/10).
problemas() { tr ' ' '\n' <<<"$1" | grep -vE '^(temp:normal|temp:sem_leitura)?$' | sort; }
familia() { case "$1" in temp:*) echo temp ;; disco_*) echo disco ;; *) echo "$1" ;; esac; }
grau() { case "$1" in temp:critica|disco_critico) echo 2 ;; *) echo 1 ;; esac; }

autoteste() {  # cenários de ponta a ponta: o vigia roda como filho, com log, estado e disco falsos
  local base="$KIT_CACHE" T SELF falhas=0 PID D
  SELF=$(readlink -f "${BASH_SOURCE[0]}")
  mkdir -p "$base"; T=$(mktemp -d "$base/esperar-saude-autoteste.XXXXXX") || return 1
  echo "pasta do autoteste: $T"
  linha() {  # $1 = temperatura da CPU ("-" = sem leitura), $2 = da GPU
    echo "$(date +%Y-%m-%dT%H:%M:%S) 1.0 1.0 20.0 0.0 1.00 0.00 0.00 5 0 $1 $1 2800 ${2:--} -"; }
  ok() { echo "  ok: $*"; }
  falha() { echo "  FALHA: $*"; falhas=$((falhas + 1)); }
  # --- histerese (só a classificação) ---
  echo "== histerese: grau anterior + leitura -> grau"
  EST="$T/h-estado"
  local caso ant cpu gpu esp obt
  for caso in "normal 89 - normal" "normal 90 - alta" "alta 87 - alta" "alta 86 - normal" \
              "alta 95 - alta" "alta 96 - critica" "critica 93 - critica" "critica 92 - alta" \
              "critica 86 - normal" "normal - 84 normal" "normal - 85 alta" "alta - 82 alta" \
              "alta - 81 normal" "critica - 87 critica" "critica - 86 alta"; do
    read -r ant cpu gpu esp <<<"$caso"; echo "temp:$ant" > "$EST"
    obt=$(classifica "$(linha "$cpu" "$gpu")")
    [ "$obt" = "temp:$esp" ] && ok "anterior $ant, CPU $cpu, GPU $gpu -> $obt" \
      || falha "anterior $ant, CPU $cpu, GPU $gpu -> $obt (esperado temp:$esp)"
  done
  # --- ponta a ponta ---
  # Cada cenário numa pasta; o vigia lê cada amostra (intervalo 0,2 s, amostra a cada 0,6 s, N=1: o pior
  # caso, sem a confirmação de 4 amostras).
  inicia() {  # $1 = reaviso (s), $2 = carência (s)
    SAUDE_LOG="$D/log" SAUDE_ESTADO="$D/estado" SAUDE_INTERVALO_S=0.2 SAUDE_DISCO_GB=500 N=1 \
      SAUDE_REAVISO_S="$1" SAUDE_CARENCIA_S="$2" bash "$SELF" >"$D/saida" 2>>"$D/erro" &
    PID=$!; sleep 0.6; }
  amostras() { local x; for x in "$@"; do linha "$x" >> "$D/log"; sleep 0.6; done; }
  espera_fim() {  # até $1 s; 0 = terminou (avisou)
    local i; for ((i = 0; i < $1 * 10; i++)); do kill -0 "$PID" 2>/dev/null || { wait "$PID"; return 0; }; sleep 0.1; done
    return 1; }
  para() { kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null; }  # só o filho deste cenário, pelo PID
  avisou() {  # $1 = trecho esperado na saída
    if espera_fim 5 && grep -qF -- "$1" "$D/saida"; then ok "avisou: $(head -1 "$D/saida")"
    else falha "esperava \"$1\"; saída: $(head -1 "$D/saida")"; para; fi; }
  calado() {  # o vigia segue rodando e não imprimiu nada
    if kill -0 "$PID" 2>/dev/null && [ ! -s "$D/saida" ]; then ok "nenhum aviso ($1)"; para
    else falha "avisou sem motivo ($1): $(head -1 "$D/saida")"; para; fi; }
  cenario() { D="$T/$1"; mkdir -p "$D"; echo "temp:normal" > "$D/estado"; linha 80 > "$D/log"; : > "$D/erro"
    echo "== $1"; }
  primeiro_aviso() {  # normal -> $1 °C: aviso inicial, como numa sessão
    inicia "$2" "$3"; amostras "$1"; avisou "problema novo [temp:alta]"; }

  cenario "a-oscilacao-95-89-95"
  primeiro_aviso 95 60 60
  inicia 60 60; amostras 89 95 89 95 89 95; calado "95 -> 89 -> 95, 3 vezes: 89 fica em alta pela histerese"
  inicia 60 60; amostras 85; echo "  cronômetro com 85 °C (ausente, na carência): $(cat "$D/estado-cronometros")"
  amostras 95 85 95; calado "95 -> 85 -> 95: sai da família, volta na carência"
  echo "  cronômetro depois: $(cat "$D/estado-cronometros")"

  cenario "b-piora-97-94-97"
  primeiro_aviso 95 60 60
  inicia 60 60; amostras 97; avisou "problema novo [temp:critica (piorou)]"
  inicia 60 60; amostras 94 97 94 97 92 97 92 97 88 97
  calado "97 -> 94 -> 97 (fica crítica) e 97 -> 92 -> 97 (desce e sobe de novo: já avisada)"

  cenario "c-carencia-vencida"
  primeiro_aviso 95 60 2
  inicia 60 2; amostras 80; echo "  cronômetro logo depois de sumir: $(cat "$D/estado-cronometros")"
  amostras 80 80 80 80; echo "  cronômetro depois da carência (2 s): \"$(cat "$D/estado-cronometros")\""
  [ -s "$D/estado-cronometros" ] && falha "cronômetro não apagado" || ok "cronômetro apagado"
  amostras 95; avisou "problema novo [temp:alta]"

  cenario "d-reaviso"
  primeiro_aviso 95 4 60
  inicia 4 60; local t0; t0=$(date +%s); amostras 95 95 80 95 95 95 95
  avisou "persiste [temp:alta]"; echo "  $(( $(date +%s) - t0 )) s depois de religar (reaviso de 4 s desde o aviso, com uma saída na carência no meio)"
  inicia 4 60; amostras 95 95; calado "logo depois do reaviso, o cronômetro recomeçou"

  cenario "e-cronometro-antigo-3-colunas"
  echo "temp:alta" > "$D/estado"; echo "temp $(( $(date +%s) - 5 )) 1" > "$D/estado-cronometros"
  linha 95 > "$D/log"; echo "  arquivo antigo: $(cat "$D/estado-cronometros")"
  inicia 60 60; amostras 95 95 85; echo "  depois de sumir: $(cat "$D/estado-cronometros")"
  amostras 95 97; avisou "problema novo [temp:critica (piorou)]"
  local e; echo "== saída de erro do vigia, em todos os cenários"
  for e in "$T"/*/erro; do [ -s "$e" ] && falha "${e#"$T"/}: $(head -3 "$e")"; done
  [ "$falhas" -eq 0 ] && ok "vazia"

  [ "${SAUDE_MANTER:-}" = 1 ] || rm -rf -- "$T"
  [ "$falhas" -eq 0 ] && echo "autoteste: todos os cenários ok" || echo "autoteste: $falhas FALHA(S)"
  [ "$falhas" -eq 0 ]
}
[ "${1:-}" = --autoteste ] && { autoteste; exit $?; }

declare -A C_T C_G C_S   # família -> época do último aviso / grau no último aviso / época em que sumiu
if [ -f "$CRON" ]; then
  while read -r f t g s _; do [ -n "$f" ] && C_T[$f]=$t && C_G[$f]=$g && C_S[$f]=$s; done < "$CRON"
fi
grava_cron() {
  local f tmp; tmp=$(mktemp "$CRON.XXXXXX")
  for f in "${!C_T[@]}"; do echo "$f ${C_T[$f]} ${C_G[$f]}${C_S[$f]:+ ${C_S[$f]}}"; done > "$tmp"
  mv -f -- "$tmp" "$CRON"
}
anterior=$(cat "$EST" 2>/dev/null)
if [ -z "$anterior" ]; then anterior=$(estado_atual); echo "$anterior" > "$EST"; fi
# Família já presente no estado anterior e sem cronômetro (1ª execução desta versão, ou cronômetros apagados):
# já foi avisada; arma o cronômetro agora, em silêncio.
agora=$(date +%s)
for c in $(problemas "$anterior"); do
  f=$(familia "$c"); g=$(grau "$c")
  [ -n "${C_T[$f]}" ] || { C_T[$f]=$agora; C_G[$f]=$g; }
done
grava_cron
while :; do
  atual=$(estado_atual)
  if [ -n "$atual" ]; then
    [ "$atual" != "$anterior" ] && { echo "$atual" > "$EST"; anterior="$atual"; }
    agora=$(date +%s); novos=(); persiste=(); declare -A presente=()
    for c in $(problemas "$atual"); do
      f=$(familia "$c"); g=$(grau "$c"); presente[$f]=1; unset "C_S[$f]"
      if [ -z "${C_T[$f]}" ]; then                      # aparece: aviso inicial
        novos+=("$c"); C_T[$f]=$agora; C_G[$f]=$g
      elif [ "$g" -gt "${C_G[$f]}" ]; then              # sobe de grau desde o último aviso
        novos+=("$c (piorou)"); C_T[$f]=$agora; C_G[$f]=$g
      elif [ $(( agora - C_T[$f] )) -ge "$REAVISO_S" ]; then  # persiste além do prazo
        persiste+=("$c|$(( (agora - C_T[$f]) / 60 ))"); C_T[$f]=$agora; C_G[$f]=$g
      fi
    done
    for f in "${!C_T[@]}"; do  # sumiu: carência, depois apaga em silêncio
      [ -n "${presente[$f]}" ] && continue
      [ -n "${C_S[$f]}" ] || C_S[$f]=$agora
      [ $(( agora - C_S[$f] )) -ge "$CARENCIA_S" ] && unset "C_T[$f]" "C_G[$f]" "C_S[$f]"
    done
    unset presente
    grava_cron
    if [ "${#novos[@]}" -gt 0 ] || [ "${#persiste[@]}" -gt 0 ]; then
      [ "${#novos[@]}" -gt 0 ] && echo "SAÚDE: problema novo [${novos[*]}] · estado [$atual]"
      for p in "${persiste[@]}"; do echo "SAÚDE: persiste [${p%|*}] há ${p##*|} min · estado [$atual]"; done
      grep -aE "$AMOSTRA" "$LOG" | tail -2
      exit 0
    fi
  fi
  sleep "$INTERVALO"
done
