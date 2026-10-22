# Aprendizados (um por linha: sintoma → causa → regra)

## Sessões do Claude Code
- `claude --continue` ignorou a conversa aberta pelo Remote Control e abriu uma antiga → ele só vê as interativas → retome com `--resume <id do jsonl mais recente>`.
- Abrir a mesma conversa num 2º processo duplicou a sessão → `--resume` cria processo novo, não anexa → uma conversa, um processo.
- O zelador sumiu quando a sessão que o lançou acabou → o subagente vive no processo da sessão → ao abrir a sessão, confira `pgrep -f scripts/esperar-zelador.sh` e relance.
- O vigia em segundo plano expirava em 30 min e acordava o agente à toa → prazo padrão do Bash em segundo plano → `timeout: 7200000`.
- O agente que esperava o `verify` em segundo plano aparecia como terminado (`finished`) → ele encerra o turno e espera → conte como vivo o agente cuja tarefa de segundo plano ainda tem processo.
- Um vigia aparece no `ps` com outro nome → o script faz `exec` → procure pela linha do invólucro ou pelo argumento.
- Um zelador lançado em modelo econômico voltou em modelo capaz depois de um /clear → o agente retomado herda o modelo da sessão → depois de todo /clear, confira o modelo na 1ª mensagem dele.

## Automações e testes
- Relatório semanal falso → a renovação da semana informada pela conta oscila 1 s entre consultas → arredonde para a hora e aceite diferenças menores que 1 h.
- Teste que "passou" sem testar (o bash faz `exec` do último comando e o processo perde o nome) → termine o comando com `; : marcador`.
- Autoteste leu a configuração real em vez da do teste → todo teste isola os caminhos por variável.
- Teste de log intermitente → conferia o log antes de a escrita terminar → espere pelo log.
- Toda regra nova só entra depois de: autoteste passando + mutação numa cópia fazendo o teste falhar. Teste que passa de primeira é suspeito.
- `pgrep -f`/`pkill -f` num laço casa a própria linha e nunca termina → espere pelo PID (`tail --pid`) ou por arquivo; mate só pelo PID exato.
- Serviço systemd que cria o servidor do tmux mata todas as sessões ao reiniciar (cgroup) → tmux próprio por serviço (`-L nome`), nunca o padrão; para o que deve sobreviver ao serviço, `KillMode=process`.
- Teste de hook que despacha em segundo plano deu falso verde → espere o despacho (`sleep 0.3`) e rode sempre a mutação.
- O modo auto barra editar lançadores como autoalteração, mesmo com o pedido do dono → não contornar; deixe um script para o dono rodar com `! bash <script>`.

## Hardware e sistema
- Ventoinhas "zeradas" no fim da CI → trocar o perfil de energia zera o boost → o controle repõe o valor a cada amostra e depois de cada troca.
- CI com teto de 100% bateu 100 °C nos primeiros minutos → equilíbrio em 60–70% → comece em 60 e suba só com folga.
- Workflow agendado em máquina do provedor sem cota gera e-mail diário de falha → desligue o agendamento de projeto parado.
