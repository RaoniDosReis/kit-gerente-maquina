#!/usr/bin/env bash
# Espera a CI de um PR terminar, sem gastar um agente esperando, e imprime o resultado final.
# Uso (em segundo plano na sessão do orquestrador): esperar-ci.sh <dono/repositório> <número do PR>
# Termina quando nenhum check está pendente; a sessão é acordada só nessa hora.
# Nunca espera para sempre: passado ESPERA_MAXIMA (min, padrão 80) ou com 5 consultas seguidas
# com erro, sai com código 2 e diz o porquê, para o orquestrador olhar (um vigia mudo já deixou
# a sessão parada por horas).
# Variáveis: ESPERA_MAXIMA (min), ESPERA_INICIAL (s, padrão 60), STATUS_REVISOR (nome do status do
# revisor, que não conta como check da CI; padrão revisor-independente).
set -u
[ $# -eq 2 ] || { echo "uso: esperar-ci.sh <dono/repositório> <número do PR>" >&2; exit 2; }
repo="$1"; pr="$2"
revisor="${STATUS_REVISOR:-revisor-independente}"
limite=$(( $(date +%s) + ${ESPERA_MAXIMA:-80} * 60 )); erros=0
sleep "${ESPERA_INICIAL:-60}"  # dá tempo de a CI registrar os checks do push
while :; do
  # statusCheckRollup em vez de "gh pr checks --json": versões antigas do gh não têm o --json no checks
  pend=$(gh pr view "$pr" --repo "$repo" --json statusCheckRollup -q '[.statusCheckRollup[] | select((.status // "COMPLETED") != "COMPLETED" or .state == "PENDING" or .state == "EXPECTED")] | length' 2>/dev/null || echo erro)
  # sem nenhum check registrado (logo depois de um push ou update-branch) ainda não terminou
  total=$(gh pr view "$pr" --repo "$repo" --json statusCheckRollup -q "[.statusCheckRollup[] | select((.name // .context) != \"$revisor\")] | length" 2>/dev/null || echo 0)
  [ "$pend" = "0" ] && [ "$total" != "0" ] && break
  if [ "$pend" = "erro" ]; then erros=$((erros + 1)); else erros=0; fi
  [ "$erros" -ge 5 ] && { echo "PR $pr: VIGIA SEM RESPOSTA (5 consultas ao gh com erro); confira à mão"; exit 2; }
  [ "$(date +%s)" -ge "$limite" ] && { echo "PR $pr: PRAZO ESTOURADO (${ESPERA_MAXIMA:-80} min) com $pend check(s) pendente(s); veja se travou"; exit 2; }
  sleep 120
done
head=$(gh pr view "$pr" --repo "$repo" --json headRefOid -q .headRefOid)
echo "PR $pr, head ${head:0:7}: CI terminou"
gh pr view "$pr" --repo "$repo" --json statusCheckRollup -q '.statusCheckRollup[] | (.conclusion // .state) as $s | select($s != "SKIPPED" and $s != "NEUTRAL") | "\($s)  \(.name // .context)  \(.detailsUrl // .targetUrl)"'
