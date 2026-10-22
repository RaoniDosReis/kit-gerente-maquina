#!/usr/bin/env bash
# Vigia único do agente zelador: as automações saude-auto, parados-auto e consumo-auto (serviços do usuário)
# fazem o trabalho; este vigia só termina quando há algo que elas não resolveram:
#   - linhas novas em saude-escalados.log, parados-escalados.log ou consumo-escalados.log ($KIT_CACHE/);
#   - "AUTOMAÇÃO PARADA <serviço>" se um dos dois serviços não está ativo em 2 olhadas seguidas;
#   - "AUTOMAÇÃO TRAVADA <serviço>" se a batida do estado dele está velha (3 intervalos + 2 min).
# Linhas já vistas: <log>.visto (contagem); na primeira vez parte do fim. Ao receber, aja e rode de novo.
# ZELADOR_DIR e ESPERA_S (padrão 30) trocam a pasta e a espera; ZELADOR_SEM_SERVICOS=1 pula a checagem (provas).
set -u
KITSH="$(dirname "$(readlink -f "${BASH_SOURCE[0]:-$0}")")/../../gerente-da-maquina/lib/kit.sh"
# shellcheck disable=SC1090
[ -f "$KITSH" ] && . "$KITSH"
: "${KIT_CACHE:=$HOME/.cache/gerente-maquina}"
D="${ZELADOR_DIR:-$KIT_CACHE}"; ESPERA="${ESPERA_S:-30}"
mkdir -p "$D"
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
  if [ -z "${ZELADOR_SEM_SERVICOS:-}" ]; then
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
