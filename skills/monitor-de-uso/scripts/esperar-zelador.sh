#!/usr/bin/env bash
# Vigia único do zelador: as automações saude-auto, parados-auto e consumo-auto (serviços do usuário) fazem o
# trabalho; este vigia só termina quando há algo que elas não resolveram:
#   - linhas novas em saude-escalados.log, parados-escalados.log ou consumo-escalados.log ($KIT_CACHE/);
#   - "AUTOMAÇÃO PARADA <serviço>" se um dos três serviços não está ativo em 2 olhadas seguidas;
#   - "AUTOMAÇÃO TRAVADA <serviço>" se a batida do estado dele está velha (3 intervalos + 2 min).
# Sem systemctl (Windows nativo, WSL sem systemd) a checagem dos serviços é pulada; os logs valem igual.
# Linhas já vistas: <log>.visto (contagem); na primeira vez parte do fim. Ao receber, aja e rode de novo.
# Enquanto roda, grava o PID em esperar-zelador.pid (o gerente e o vigia-gerente conferem por ele, sem pgrep).
# ZELADOR_DIR e ESPERA_S (padrão 30) trocam a pasta e a espera; ZELADOR_SEM_SERVICOS=1 pula a checagem (provas).
# Teste: esperar-zelador.sh --autoteste
set -u
KITSH="$(dirname "$(readlink -f "${BASH_SOURCE[0]:-$0}")")/../../gerente-da-maquina/lib/kit.sh"
# shellcheck disable=SC1090
[ -f "$KITSH" ] && . "$KITSH"
: "${KIT_CACHE:=$HOME/.cache/gerente-maquina}"

if [ "${1:-}" = --autoteste ]; then
  falhas=0; T=$(mktemp -d); mkdir -p "$T/bin"
  # 1) linha nova num log: sai com ela; o PID fica gravado enquanto roda e some na saída
  echo "velha" > "$T/saude-escalados.log"
  ZELADOR_DIR="$T" ESPERA_S=0.2 ZELADOR_SEM_SERVICOS=1 bash "$0" > "$T/out" & v=$!
  for _ in $(seq 50); do [ -s "$T/esperar-zelador.pid" ] && break; sleep 0.1; done
  [ "$(cat "$T/esperar-zelador.pid" 2>/dev/null)" = "$v" ] || { echo "FALHA: não gravou o PID ($v)"; falhas=1; }
  echo "DISCO CRÍTICO: teste" >> "$T/saude-escalados.log"
  timeout 10 tail --pid="$v" -f /dev/null; wait "$v" 2>/dev/null
  grep -qx "DISCO CRÍTICO: teste" "$T/out" || { echo "FALHA: não trouxe a linha nova ($(cat "$T/out"))"; falhas=1; }
  grep -q velha "$T/out" && { echo "FALHA: trouxe linha já vista"; falhas=1; }
  [ -e "$T/esperar-zelador.pid" ] && { echo "FALHA: o PID ficou depois da saída"; falhas=1; }
  # 2) serviço inativo em 2 olhadas: AUTOMAÇÃO PARADA
  printf '#!/bin/sh\ncase "$*" in *is-active*parados-auto*) echo inactive; exit 3;; esac; echo active; exit 0\n' > "$T/bin/systemctl"
  chmod +x "$T/bin/systemctl"
  out=$(PATH="$T/bin:$PATH" ZELADOR_DIR="$T" ESPERA_S=0.1 timeout 20 bash "$0")
  grep -q "^AUTOMAÇÃO PARADA parados-auto" <<<"$out" || { echo "FALHA: serviço parado ($out)"; falhas=1; }
  # 3) batida velha: AUTOMAÇÃO TRAVADA
  printf '#!/bin/sh\necho active; exit 0\n' > "$T/bin/systemctl"
  echo "{\"batida\": $(( $(date +%s) - 9999 ))}" > "$T/consumo-auto-estado.json"
  out=$(PATH="$T/bin:$PATH" ZELADOR_DIR="$T" ESPERA_S=0.1 timeout 20 bash "$0")
  grep -q "^AUTOMAÇÃO TRAVADA consumo-auto" <<<"$out" || { echo "FALHA: serviço travado ($out)"; falhas=1; }
  # 4) sem systemctl (Windows nativo): não acusa serviço parado, só os logs valem
  rm "$T/bin/systemctl" "$T/consumo-auto-estado.json"
  mkdir -p "$T/sem"; for c in bash sh cat wc tail head mkdir dirname readlink date sleep touch rm sed grep uname python3 tr; do
    p=$(command -v "$c") && ln -sf "$p" "$T/sem/$c"; done
  out=$(timeout 2 env PATH="$T/sem" ZELADOR_DIR="$T" ESPERA_S=0.1 bash "$0"); c=$?
  [ "$c" = 124 ] && [ -z "$out" ] || { echo "FALHA: sem systemctl acusou algo ou saiu ($c: $out)"; falhas=1; }
  rm -rf "$T"
  [ "$falhas" = 0 ] && echo "autoteste: OK" || echo "autoteste: FALHOU"
  exit "$falhas"
fi

D="${ZELADOR_DIR:-$KIT_CACHE}"; ESPERA="${ESPERA_S:-30}"
mkdir -p "$D"
echo $$ > "$D/esperar-zelador.pid"
trap '[ "$(cat "$D/esperar-zelador.pid" 2>/dev/null)" = $$ ] && rm -f "$D/esperar-zelador.pid"' EXIT
trap 'exit 143' TERM INT HUP
SERVICOS=1; [ -n "${ZELADOR_SEM_SERVICOS:-}" ] && SERVICOS=0; command -v systemctl >/dev/null 2>&1 || SERVICOS=0
declare -A parado=()
for l in saude-escalados parados-escalados consumo-escalados; do
  touch "$D/$l.log"; [ -f "$D/$l.visto" ] || wc -l < "$D/$l.log" > "$D/$l.visto"
done
batida() { python3 -I -c 'import json,sys; print(int(json.load(open(sys.argv[1])).get("batida",0)))' "$1" 2>/dev/null || echo 0; }
while :; do
  saiu=0
  for l in saude-escalados parados-escalados consumo-escalados; do
    n=$(cat "$D/$l.visto" 2>/dev/null || echo 0); total=$(wc -l < "$D/$l.log")
    if [ "$total" -gt "$n" ]; then
      tail -n +"$((n + 1))" "$D/$l.log" | head -n "$((total - n))"; echo "$total" > "$D/$l.visto"; saiu=1
    fi
  done
  [ "$saiu" = 1 ] && exit 0
  if [ "$SERVICOS" = 1 ]; then
    for s in saude-auto:60 parados-auto:300 consumo-auto:60; do
      nome=${s%%:*}; int=${s##*:}
      if systemctl --user is-active --quiet "$nome"; then parado[$nome]=0; else parado[$nome]=$(( ${parado[$nome]:-0} + 1 )); fi
      if [ "${parado[$nome]}" -ge 2 ]; then
        echo "AUTOMAÇÃO PARADA $nome: o serviço está '$(systemctl --user is-active "$nome" 2>&1)'. Veja: journalctl --user -u $nome -n 20"; exit 0
      fi
      b=$(batida "$D/$nome-estado.json")
      if [ "$b" -gt 0 ] && [ $(( $(date +%s) - b )) -gt $(( 3 * int + 120 )) ]; then
        echo "AUTOMAÇÃO TRAVADA $nome: última olhada há $(( ($(date +%s) - b) / 60 )) min. Veja: tail -3 $D/$nome.log"; exit 0
      fi
    done
  fi
  sleep "$ESPERA"
done
