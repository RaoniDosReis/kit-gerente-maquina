# Aprendizados: serviços do usuário, sinais e travas (scripts de máquina)

- Trap de sinal em bash 5.2 pode corromper o analisador: laço de serviço que repõe estado no SIGTERM vai em Python.
- O fd da trava (flock) é herdado pelos filhos em bash: feche-o no filho (`9>&-`) ou use Python.
- O `systemd-run` expande `$` no comando: use `--expand-environment=no`.
- O polkit `allow_active` vale num serviço `systemctl --user` enquanto há sessão gráfica ativa.

## Trap de sinal em bash 5.2 corrompe o analisador
- Sintoma: num estresse de SIGTERM em momentos ao acaso, algumas partidas falharam com "encontrado EOF inesperado" e uma instância ficou presa, com o estado de emergência aplicado.
- Regra: o trap roda no meio da análise de um `$(...)`. Um script que PRECISA agir no sinal (repor estado, soltar recurso) usa Python (`exec python3 -I - "$@" <<'PY'`, como o vez-opus.sh), com um tratador que só marca o pedido, ou que levanta exceção só durante o sono.

## O fd da trava (flock) é herdado pelos filhos em bash
- Sintoma: depois de um SIGKILL, a partida seguinte às vezes saía com "outra instância já roda".
- Regra: o `sleep` órfão herdou o `exec 9>trava` e segurou o flock. Em bash, rode os filhos com `9>&-`. Em Python, o `open()` já não deixa o descritor ser herdado.

## O `systemd-run` expande `$` no comando
- Regra: para passar `$` ao shell da unidade, use `--expand-environment=no`.

## O polkit `allow_active` num serviço `systemctl --user`
- Regra: o polkit usa a sessão gráfica do usuário quando o processo não tem sessão própria; funciona com a tela bloqueada. Sem login depois do boot (só o linger), é recusado: o script deve avisar e seguir. Confira sem mudar nada com `pkcheck --action-id <ação> --process <pid>` dentro de um `systemd-run --user`.
