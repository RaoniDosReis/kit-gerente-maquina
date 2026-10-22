#!/usr/bin/env bash
# Como esperar-aviso.sh, mas só termina quando o aviso muda algo que afeta o trabalho:
#   o estado do uso (ADEQUADO, ULTRAPASSANDO...), a faixa da semana (<85, 85-89, >=90)
#   ou a faixa da previsão da semana ([prev:abaixo|meta|acima], calculada pelo monitor-uso.py com histerese e
#   2 amostras: abaixo = 15 pontos ou mais abaixo da meta da semana).
# Avisos que só mudam o %, a sugestão de agentes ou o limite de codificadores são gravados em silêncio; estado do
# uso, faixa da semana e faixa da previsão avisam na hora (a previsão já vem confirmada em 2 amostras pelo monitor).
# Estado guardado por sessão em $KIT_CACHE/estado-relevante-<chave>, com a chave tirada da pasta em que a sessão
# roda: com um arquivo só, a sessão que lia primeiro gravava o estado novo, e a outra não acordava. AVISO_SESSAO
# troca a chave. Ao receber, rode de novo.
. "$(dirname "$(readlink -f "$0")")/../../gerente-da-maquina/lib/kit.sh" 2>/dev/null \
  || . "$HOME/.claude/skills/gerente-da-maquina/lib/kit.sh"
f="$KIT_CACHE/alertas.log"
chave="${AVISO_SESSAO:-$(printf '%s' "$PWD" | md5sum | cut -c1-12)}"
EST="$KIT_CACHE/estado-relevante-$chave"
# Primeira vez desta sessão: parte do estado comum antigo, para não acordar por uma mudança que já viu.
[ -f "$EST" ] || cp "$KIT_CACHE/estado-relevante" "$EST" 2>/dev/null || true
touch "$f"
chave() {  # linha de aviso [+ previsão anterior] -> "ESTADO|limite|faixa|previsao"
  awk -v pant="$2" '{
    est=""; if (match($0,/ USO [A-ZÁÉÍÓÚÂÊÔÃÕÇ ]+:/)) est=substr($0,RSTART+5,RLENGTH-6);
    lim=""; if (match($0,/codificadores [0-9]+/)) lim=substr($0,RSTART+14,RLENGTH-14);
    sem=-1; if (match($0,/semana [0-9]+%/)) sem=substr($0,RSTART+7,RLENGTH-8)+0;
    fx=(sem>=90)?"ge90":(sem>=85)?"85-89":"lt85";
    pv=(pant!="")?pant:"?"; if (match($0,/\[prev:[a-z]+\]/)) pv=substr($0,RSTART+6,RLENGTH-7);
    print est "|" lim "|" fx "|" pv }' <<<"$1"
}
n=$(wc -l < "$f"); pend=""
while :; do
  until [ "$(wc -l < "$f")" -gt "$n" ]; do sleep 15; done
  novas=$(tail -n +"$((n + 1))" "$f"); n=$(wc -l < "$f")
  ult=$(grep -E 'USO ' <<<"$novas" | tail -1); [ -z "$ult" ] && continue
  ant=$(cat "$EST" 2>/dev/null); k=$(chave "$ult" "${ant##*|}")
  [ "$k" = "$ant" ] && { pend=""; continue; }
  # Estado do uso, faixa da semana ou faixa da previsão mudou: avisa na hora. Só o limite de codificadores mudou:
  # grava em silêncio (oscila a cada renovação da janela de 5 h,).
  if [ "${k%%|*}" != "${ant%%|*}" ] || [ "$(cut -d'|' -f3,4 <<<"$k")" != "$(cut -d'|' -f3,4 <<<"$ant")" ]; then
    echo "$k" > "$EST"; echo "USO MUDOU: [$ant] -> [$k]"; tail -1 <<<"$novas"; exit 0
  fi
  echo "$k" > "$EST"
done
