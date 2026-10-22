# Medição: tokens, processo e fontes de conflito

- Some o `usage` por `message.id`, nunca por linha.
- O cache dos agentes esfria em 5 min: meça a reescrita antes de culpar a documentação.
- Papel pela frase "Você é o …" do primeiro prompt.
- Leitura por shell: tire o `cd … &&` antes de classificar.
- Rodada extra se classifica pela causa, não pela contagem.
- Fila, trava e instável se medem por tentativa e por job.
- Diários da memória são a maior fonte de regra vencida.
- Decisão do dono só na memória conflita com o repositório.
- Lição de segurança operacional de um papel não protege os outros.
- O tamanho do contexto do agente explica regra lida e não aplicada.

## Some o `usage` por `message.id`, nunca por linha
- Origem: auditoria de tokens.
- Sintoma: a mesma mensagem aparece em várias linhas do JSONL (uma por bloco), as primeiras com `output_tokens` parcial.
- Causa e regra: deduplique pelo `message.id` e fique com o maior `output_tokens`. Mensagens do coordenador aos agentes são `user` com `isMeta` ou `attachment` `queued_command`. As transcrições dos agentes ficam em `~/.claude/projects/<proj>/<sessão>/subagents/agent-<id>.jsonl`.
- Prova: script curto com `python3 -I` que imprime só números, nunca conteúdo.

## O cache dos agentes esfria em 5 min: meça a reescrita antes da documentação
- Origem: auditoria de tokens (ler documentos custava pouco; o grosso era memória longa e esfriamento).
- Sintoma: proposta de "enxugar os textos" com ganho pequeno.
- Causa e regra: subagentes só escrevem cache de 5 min; a sessão principal escreve de 1 h. Conte como despertar frio a chamada com intervalo de 300 s ou mais e escrita maior que 50% do contexto, e classifique pela ferramenta da chamada anterior (laço de `sleep`, `timeout` longo). Decomponha leitura, escrita, reescrita e saída por papel antes de propor corte de texto. Converta em % da semana pelos pesos do consumo da conta, porque tokens soltos não dizem nada ao dono.
- Prova: tabela por papel com as quatro parcelas.

## Papel pela frase de abertura, leitura por shell sem `cd`
- Origem: auditoria de tokens.
- Sintoma: as descrições dos agentes mandavam codificadores para "segurança" por citarem palavras do `CLAUDE.md`; a leitura de documentos saiu 10 vezes menor que a real porque os agentes leem com `cd <worktree> && sed -n …`.
- Causa e regra: case o papel na frase "Você é o …" do primeiro prompt; remova o prefixo `cd` antes de casar `cat`, `sed`, `head` e atribua tokens pelo delta de contexto entre chamadas.
- Prova: contagens antes e depois do ajuste.

## Rodada extra se classifica pela causa
- Origem: auditoria de PRs com 3 rodadas.
- Sintoma: "3 rodadas" sozinho não diz o que mudar.
- Causa e regra: para cada bloqueante, classifique: (a) regra escrita e não aplicada, que pede verificação automática ou regra mais perto da tarefa; (b) regressão criada pela correção anterior, que pede roteiro de rodada; (c) caso novo, que pede lista de riscos no PR; (d) prova enviesada, que pede regra de prova.
- Prova: as revisões do PR (`gh api repos/O/R/pulls/N/reviews`).

## Fila, trava e instável se medem por tentativa e por job
- Origem: auditoria da CI.
- Sintoma: "rodado de novo, passou" escondia travas; "a CI leva 1 h" misturava fila, trava e execução.
- Causa e regra: por execução, leia `run_attempt` e `actions/runs/<id>/attempts/<n>/jobs`; fila = criado→iniciado, execução = iniciado→concluído; timeout é `cancelled` com duração perto do prazo; liste também as execuções da principal depois de cada merge; `git log -S <teste>` diz se o culpado nasceu no PR. Lacunas acima de 30 min entre mensagens do assistente na transcrição mostram sessão parada.
- Prova: script curto por branch, horários no fuso do dono.

## Diários da memória e decisões só na memória
- Origem: todas as auditorias.
- Sintoma: arquivo de estado acrescentado em vez de reescrito, com itens feitos ao lado dos vigentes; decisão do dono gravada só na memória enquanto o repositório diz outra coisa, e o orquestrador repete a decisão em todo briefing.
- Causa e regra: estado vira diário quando se acrescenta; proponha o estado reescrito pronto (até 40 linhas) e tire listas longas para arquivos fora do índice. Para cada decisão datada da memória, faça `git grep` do tema na principal e cobre o prazo de levá-la ao repositório. Compare cada aprendizado novo com o bloco de regras de operação do `CLAUDE.md`: se o erro pode vir de qualquer papel, a regra mora lá.
- Prova: `wc -l -w` nos arquivos da memória, vezes 1,8; `grep -rn` do termo na memória e no repositório.

## O tamanho do contexto do agente explica regra lida e não aplicada
- Origem: agente reaproveitado por mensagem com contexto enorme.
- Sintoma: regra do `CLAUDE.md` e do briefing violada por agente que recebeu uma nova tarefa com mais de 300 mil tokens de contexto.
- Causa e regra: compare o contexto do agente na hora da tarefa com a violação; a correção é agente novo (skill `orquestrador-de-agentes` §4), não regra mais longa.
- Prova: soma de `input`, `cache_read` e `cache_creation` por chamada, no horário da tarefa.
