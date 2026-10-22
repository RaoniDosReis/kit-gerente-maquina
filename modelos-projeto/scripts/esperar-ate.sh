#!/usr/bin/env bash
# Espera curta, que mantém o cache do agente morno: espera no máximo 270 s por um padrão num arquivo ou pelo fim de um
# processo e devolve o resultado; quem chama roda de novo enquanto a resposta for "ainda não".
#
# Uso:
#   scripts/esperar-ate.sh arquivo <caminho> <regex> [--prazo <s>]
#   scripts/esperar-ate.sh pid <pid> [--prazo <s>]
#
# Saída: 0 = pronto; 1 = ainda não (rodar de novo); 2 = erro de uso (argumento, prazo acima de
# 270 s, regex inválida). O prazo padrão é 270 s, e nunca passa disso: um pedido maior é recusado.
# Só lê: nunca mata nada, nunca usa pgrep -f (casa a linha do próprio shell). PID que não
# existe conta como terminado (o processo acabou antes da chamada), com aviso na saída de erro.
set -uo pipefail

readonly MAX_PRAZO=270

uso() {
  echo "uso: esperar-ate.sh arquivo <caminho> <regex> [--prazo <s>] | pid <pid> [--prazo <s>]" >&2
  echo "prazo: inteiro de 1 a $MAX_PRAZO s (padrão $MAX_PRAZO)" >&2
  exit 2
}

[ $# -ge 1 ] || uso
modo="$1"
shift
alvo=()
prazo="$MAX_PRAZO"
while [ $# -gt 0 ]; do
  case "$1" in
    --prazo)
      [ $# -ge 2 ] || uso
      prazo="$2"
      shift 2
      ;;
    *)
      alvo+=("$1")
      shift
      ;;
  esac
done

if ! [[ "$prazo" =~ ^[0-9]+$ ]] || [ "$((10#$prazo))" -lt 1 ]; then
  echo "prazo inválido: '$prazo'" >&2
  uso
fi
prazo=$((10#$prazo))
if [ "$prazo" -gt "$MAX_PRAZO" ]; then
  echo "prazo de $prazo s recusado: o máximo é $MAX_PRAZO s (espera maior esfria o cache)." >&2
  echo "Rode de novo em blocos de até $MAX_PRAZO s." >&2
  exit 2
fi

# pronto devolve 0 (pronto), 1 (ainda não) ou 2 (erro).
case "$modo" in
  arquivo)
    [ "${#alvo[@]}" -eq 2 ] || uso
    caminho="${alvo[0]}"
    regex="${alvo[1]}"
    [ -n "$regex" ] || { echo "regex vazia" >&2; uso; }
    # Regex inválida é erro de uso, não "ainda não": confere uma vez antes do laço.
    printf '' | grep -Eq -- "$regex"
    [ $? -le 1 ] || { echo "regex inválida: '$regex'" >&2; exit 2; }
    pronto() {
      [ -f "$caminho" ] || return 1
      grep -Eq -- "$regex" "$caminho"
      local rc=$?
      [ "$rc" -le 1 ] || return 2
      return "$rc"
    }
    descricao="o padrão em $caminho"
    ;;
  pid)
    [ "${#alvo[@]}" -eq 1 ] || uso
    pid="${alvo[0]}"
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || { echo "pid inválido: '$pid'" >&2; uso; }
    pronto() {
      # Zumbi (estado Z) já terminou: só falta o pai recolhê-lo.
      if [ -r "/proc/$pid/stat" ]; then
        local estado
        estado="$(sed -E 's/^.*\) ([A-Za-z]).*$/\1/' "/proc/$pid/stat" 2>/dev/null)"
        [ "$estado" = Z ] && return 0
        return 1
      fi
      if [ -d /proc/self ]; then return 0; fi
      ps -p "$pid" >/dev/null 2>&1 && return 1
      return 0
    }
    descricao="o fim do processo $pid"
    if ! [ -e "/proc/$pid" ] && [ -d /proc/self ]; then
      echo "pid $pid não existe (já terminou ou nunca existiu)" >&2
    fi
    ;;
  *)
    uso
    ;;
esac

inicio=$SECONDS
while :; do
  pronto
  rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "pronto: $descricao"
    exit 0
  fi
  [ "$rc" -eq 1 ] || { echo "erro ao ler $descricao" >&2; exit 2; }
  if [ $((SECONDS - inicio)) -ge "$prazo" ]; then
    echo "ainda não: $descricao (${prazo} s); rode de novo"
    exit 1
  fi
  sleep 1
done
