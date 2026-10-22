#!/usr/bin/env bash
# Espera a próxima linha do alertas.log, imprime as linhas novas e termina.
# Feito para rodar em segundo plano numa sessão: ela só é acordada quando chega um aviso; ao receber, rode de novo.
# (Um `tail -F | grep -m1` não serve: o tail só morre na escrita seguinte, e o comando ficaria parado.)
. "$(dirname "$(readlink -f "$0")")/../../gerente-da-maquina/lib/kit.sh" 2>/dev/null \
  || . "$HOME/.claude/skills/gerente-da-maquina/lib/kit.sh"
f="$KIT_CACHE/alertas.log"
touch "$f"
n=$(wc -l < "$f")
until [ "$(wc -l < "$f")" -gt "$n" ]; do sleep 15; done
tail -n +"$((n + 1))" "$f"
