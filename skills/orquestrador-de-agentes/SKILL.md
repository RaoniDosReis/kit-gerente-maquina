---
name: orquestrador-de-agentes
description: Método para conduzir um projeto de software como orquestrador de agentes (codificadores, revisores, auditores, testadores e apoio), com o dono como gestor. Use ao assumir a orquestração, distribuir trabalho, decidir modelo e paralelismo, conduzir branch → PR → CI → revisão → merge e registrar regras e aprendizados. A skill `orquestrador` do projeto complementa esta.
---

# Orquestrador de agentes

Este é o método geral. O orquestrador é a sessão principal do Claude Code aberta na pasta do projeto. Ele planeja, escreve os briefings, distribui o trabalho a agentes, confere os portões, faz o merge, registra o que aprendeu e fala com o dono. **Ele não escreve código de produção e não revisa.**

A skill `orquestrador` do próprio projeto (`.claude/skills/orquestrador/`) vence esta nos detalhes (caminhos, comandos, nomes). Esta dá o método; a do projeto dá a execução.

## 1. Papéis

| Papel | Quem | Modelo | Faz | Não faz |
|---|---|---|---|---|
| Dono | a pessoa | | decide escopo, prioridade, filosofia e o que muda funcionalidade já combinada; aprova ideias | não precisa ler código nem acompanhar ferramentas |
| Gerente da máquina | outra sessão, na pasta pessoal | o mais capaz | cuida do hardware, das automações, do consumo da conta e do bastão do modelo capaz; diz quantos agentes cada projeto pode usar | não desenvolve |
| Orquestrador | a sessão do projeto | o mais capaz disponível | briefing, distribuição, portões, merge, registro, conversa com o dono | não escreve código de produção nem revisa |
| Codificador | agente novo por etapa e por rodada | capaz | implementa na branch, roda as verificações, abre o PR, corrige CI e achados | não faz merge; não decide fora do briefing |
| Revisor | agente novo por PR e por rodada, sem o contexto do codificador | capaz, inclusive no delta | lê o diff contra os docs, roda os testes, publica o parecer no PR com "Veredito:" | não aprova, não faz merge, não altera código |
| Testador-usuário | agente novo por etapa com interface | econômico | usa o sistema só pelo navegador e pelo manual, como um humano | não lê código |
| Documentador | apoio | econômico | grava nos docs decisões já tomadas | não decide |
| Mantenedor de branches | apoio | econômico | atualiza a branch com a principal, conflitos de documentação, duplicatas | não mexe em lógica |
| Vigia da CI | apoio | econômico | lê os logs da CI vermelha, separa falha real de intermitente, entrega o diagnóstico | não corrige |
| Auditor de segurança | agente fixo por PR ou lote | capaz | revisa a segurança dos PRs de superfície de ataque, em paralelo ao revisor (skill `auditor-de-seguranca`) | não corrige |
| Auditor de qualidade | periódico e sob demanda | capaz | lê regras, memória, skills e aprendizados; relata conflitos, redundâncias e desperdício e propõe melhorias (skill `auditor-de-qualidade`) | não altera nada além dos próprios aprendizados |

Pesquisa pontual (varrer docs e código e devolver um relatório) vai a um agente econômico com a instrução "não edite nada".

**O orquestrador não revisa nem codifica, mesmo sabendo fazer.** Ele cuida do todo: planeja, distribui, decide o que é técnico, administra o orçamento e faz o merge depois da CI verde e do veredito do revisor. Por quê: quem olha o todo não deve se perder em tarefa específica, e a revisão só vale se for independente de quem escreveu.

**Três provas do codificador:** o teste novo falhando contra o código antigo, a evidência de cada afirmação e um caso de borda.

**Limite de trabalho em andamento:** com 3 ou mais PRs esperando revisão, não acione codificador novo até a fila baixar para 2 ou menos, mesmo que o orçamento permita. Código novo só aumentaria a fila parada; o orçamento vai para revisar e mesclar.

## 2. Modelo, paralelismo e orçamento

**Modelo.**
- **Capaz** em todo código (produção e teste), em toda revisão (inclusive a do delta) e nos auditores. O modelo barato em código gerou rodadas de revisão que custaram mais do que economizaram; a revisão independente do capaz pegou o que dois revisores baratos tinham aprovado. Quando o modelo do revisor muda, vale uma revisão retroativa.
- **Econômico** em documentador, mantenedor de branches, vigia da CI, testador-usuário e pesquisa.
- Não troque o modelo de um agente no meio da tarefa. Troca de modelo e de paralelismo é do dono; o orquestrador traz os dados (tokens por trabalho, achados por revisão, defeitos que escaparam).

**Quantos agentes (o orçamento é do gerente).** O orquestrador não faz conta de consumo nem vigia o uso da conta. Ele recebe só o número de agentes que pode usar: no início da sessão (linha `AGENTES` que o hook de abertura mostra) e a cada mudança, por mensagem do gerente ou do zelador; até a próxima, vale o último número. Unidade: agente capaz conta 1, econômico 0,5; o orquestrador fica fora da conta.
- Orçamento 0: nenhum agente novo; só o que não custa (conferir PR, merge).
- Antes de lançar qualquer agente, confira que há vaga no orçamento e, para agente capaz, que a máquina tem folga (arquivo de teto de carga indicado pelo gerente).
- **Bastão do modelo capaz:** só quem tem o bastão roda agente capaz. Peça com o comando de bastão da skill `monitor-de-uso` (`vez-opus.sh pegar NOME "<tarefa>" [minutos]`): saída 0 = pode lançar; ocupado = você entrou na fila e faz só o que é de CI ou do modelo econômico. A troca é nas pausas naturais (o trabalho entrou em CI, o agente terminou), com teto de cerca de 90 min quando o outro espera. Para ficar com a rodada seguinte, peça a próxima ainda sendo o dono. O gerente solta o bastão sozinho quando o dono fica sem agente capaz.
- Previsão acima do teto da semana: nada novo fora do caminho crítico, sem interromper quem já roda. Previsão muito abaixo: adiante a fila e lance mais agentes, dentro do número recebido.
- **Fila de prioridade:** revisão de PR pronto > caminho crítico (o que segura o próximo portão) > correções > apoio > melhorias. Folga vai para os auditores. Nunca interrompa agente rodando; correções do mesmo PR vão juntas numa rodada. O dependente fica encadeado (correção → revisão → merge → próxima etapa).
- Agente derrubado pelo limite da conta é retomado por mensagem, sem recomeçar, se estiver na exceção de retomada (§4).

## 3. Rotina de uma etapa
1. **Briefing** num arquivo do repositório, que é o contrato da etapa. Contém: estado, branch e tamanho (limite de linhas e divisão prevista se passar); dependências e objetivo; decisões do orquestrador, datadas; requisitos e cenários; leitura obrigatória com links; entregas numeradas, testes de destaque, o que não fazer e as verificações; um Registro, preenchido durante a etapa. Commitado na branch da etapa antes de acionar o codificador.
2. **Codificador**: um agente com worktree, ambiente e vaga próprios. O prompt tem a forma do §5. Ele abre o PR depois da verificação local verde e **termina sem esperar a CI**.
3. **CI** vigiada por script, não por agente: o orquestrador roda em segundo plano `~/.claude/skills/orquestrador-de-agentes/scripts/esperar-ci.sh <dono/repo> <PR>`, que só o acorda quando a CI termina. É **sempre a execução do commit exato** (logo depois do push, "a última execução" ainda é a do commit anterior). Vermelha: o vigia da CI diagnostica e um codificador NOVO corrige, com o diagnóstico e a passagem do anterior (no máximo 5 ciclos; no sexto, quem corrige para e avisa o orquestrador com o resumo das tentativas).
4. **Revisor** só com a CI verde. Bloqueante volta a um codificador novo, e a rodada seguinte é revista sobre o diff novo por um revisor novo, com a revisão anterior. Leia o parecer inteiro, não só o veredito. Um bloqueante que questiona o desenho vira pergunta ao dono, não remendo. O **auditor de segurança** roda em paralelo, já com a CI rodando, nos PRs de superfície de ataque.
5. **Testador-usuário** nas etapas com interface.
6. **Portão de merge.** Tudo isto precisa valer: CI verde no head atual e PR mesclável; última rodada do revisor sem bloqueante e nenhum código mudado depois dela sem nova rodada; exceção de tamanho decidida por escrito antes do PR; docs de acompanhamento atualizados no próprio PR; nenhum achado crítico ou alto do auditor aberto.
7. **Merge** (squash), atualização da principal, vigia da CI do commit do merge até o fim, remoção da branch e do worktree, aviso de atualização aos PRs paralelos que tocam docs compartilhados.
8. **Retrospectiva** em cinco perguntas, antes da próxima etapa (§7).

**Principal protegida (a regra que sustenta o resto).** Ninguém faz push direto na principal: a regra da plataforma exige PR com as verificações obrigatórias e o status do revisor (`revisor-independente`) verdes no head. O workflow do revisor grava esse status a partir do "Veredito:" do parecer publicado no PR (verde para SEM OBJEÇÕES e NÃO BLOQUEANTES, vermelho para BLOQUEANTE); um guarda local (`pre-push`) recusa o push antes. O orquestrador arma o merge com `gh pr merge <n> --auto --squash --match-head-commit <sha>` e o GitHub mescla sozinho quando tudo está verde nesse head, e só nele. Atrás da principal: atualize a branch por **merge** da principal (`gh pr update-branch <n>`), nunca por rebase com force-push, que perde o status do revisor. Cabe ao dono nunca ter de clicar em merge: o orquestrador mescla sozinho quando o portão fecha, salvo os portões reservados ao dono.

**Principal vermelha.** Com a CI da principal vermelha ou travada, só entra o PR de conserto (mesclar em cima esconde a causa); ninguém mais mescla. Agentes seguem com commit local, sem push. Depois de cada merge, o orquestrador vigia a CI do commit dele até o fim.

**Trava é defeito.** Job cortado pelo prazo, teste parado pelo timeout ou execução sem saída é defeito, nunca "instável": "rodar de novo" esconde a trava. Depois de vermelho intermitente, o merge exige causa nomeada, 2 verdes seguidos (todas as tentativas lidas) e, se houve trava, o culpado repetido várias vezes em paralelo.

**Tamanho.** Um teto de linhas de produção por PR (cerca de 800), para o revisor ler por inteiro. O briefing já nasce com a divisão prevista; o codificador conta antes de abrir o PR e para se passar. A exceção desconta o que não é código novo (DDL, espelhos de esquema, metadados copiados).

**Não reinventar a roda.** Nos pedidos ao codificador e nos critérios do revisor, exigir que se procure primeiro uma biblioteca pronta e mantida (versão fixa, licença conferida); código próprio só para a regra do domínio.

## 4. Agentes: contexto, ambiente e passagem
- **Agente novo a cada tarefa e a cada rodada.** Correção é agente novo com a passagem do anterior; revisor e auditores são sempre novos, pela independência. Única exceção: retomar por mensagem o MESMO agente na MESMA tarefa quando ele terminou há menos de 1 h e está abaixo de 120 mil tokens. Por quê: cada passo de um agente com 400 mil tokens custa várias vezes o de um novo, e regra lida em contexto enorme é regra esquecida.
- **Leitura obrigatória no corpo de `.claude/agents/<papel>.md`** (versionado, por PR), com a skill do papel pré-carregada por `skills:`. O briefing traz só o específico da tarefa (etapa, PR, worktree, vaga, passagem do anterior). Lance sempre pelo papel definido (`subagent_type`), nunca por bifurcação (fork), que relê o contexto inteiro do orquestrador.
- **Aviso de 150 mil tokens.** Perto desse ponto o agente fecha o item em curso, faz commit WIP (push só com a verificação verde), grava a passagem em `~/.cache/gerente-maquina/<projeto>/passagem-agentes/<nome-do-agente>.md` (feito e falta, branch, SHA, worktree, provas, processos deixados) e termina o relatório com a palavra **PARCIAL** sozinha na última linha. O orquestrador continua com um agente novo `<nome>b`, worktree novo da branch e a passagem no briefing, e apaga a passagem ao fim da tarefa. Compactação do agente configurada em 200 mil (`autoCompactWindow`).
- **Hook `SubagentStop`** (opcional, vem no modelo do projeto): confere no fim de cada agente o relatório, a passagem do PARCIAL e os processos deixados no worktree, e segura o agente uma vez.
- **Worktree, venv e vaga por agente**, com nome único `<etapa ou PR>-<papel>[-r<rodada>]` dado no briefing. Nunca dois agentes na mesma branch, nunca editar no clone principal. Se o nome já existe, é de outro agente: use outro, nunca reaproveite nem remova. Vaga de Compose/portas só a que o briefing indicar. Scratchpad é compartilhado: nomes com o prefixo da etapa ou do PR.
- **Fim de agente:** a cada aviso de fim, encerre o agente (`TaskStop` derruba as tarefas de fundo dele) e confira as sobras na pasta dele. Agente não deixa vigia nem processo em segundo plano, e não espera a CI.
- **Guardas automáticos:** recusar push direto na principal; recusar arquivo de projeto engolido por regra genérica do `.gitignore`.

## 5. Como escrever o prompt de cada agente
O agente só sabe o que está no prompt (e no corpo do papel). Tudo o que importa vai escrito:
- **Codificador:** onde trabalhar (worktree, branch, ambiente, vaga); o arquivo do briefing; o que fazer, numerado; os limites (tamanho, o que não tocar); como perguntar (uma pergunta por vez, numerada, com sugestão; adiantar o que não depende dela); o formato dos commits e do PR e as verificações antes do push; o que responder no fim (PR, commit, contagem, verificações, desvios).
- **Revisor:** o PR, o commit e o comando do diff; o contrato da etapa; os pontos de atenção; publicar no PR com "Veredito:" e responder com o veredito e os achados separados; nunca aprovar, fazer merge ou alterar.
- **Nova rodada de revisão:** o diff entre os commits, o que foi corrigido e o que conferir. Se houve rebase, aponte o commit dos ajustes, não o diff entre os heads.
- **Rodada de conserto:** os achados e a passagem. Item fixo: "para cada conserto de entrada hostil, escreva o pior caso contra o próprio conserto antes do PR" (o conserto de uma rodada já criou custo quadrático).
- **Ao repassar achados:** cada item com arquivo, linha e cenário de falha, mais a decisão do orquestrador quando houver escolha.
- **Item instável de verificação automática:** peça o motivo que a ferramenta dá, a reprodução determinística da carga e a correção nas duas pontas (condição esperada no teste e produto robusto); recuse prazo maior como correção.

## 6. Com o dono
- **O que é dele:** escopo, prioridade, filosofia, mudança drástica de funcionalidade já combinada, troca de modelo e de paralelismo. O que é técnico e seguro, o orquestrador decide e registra como decisão própria, dizendo isso. Nunca atribua ao dono uma decisão que foi sua.
- **Perguntas:** numeradas e registradas num log com a resposta, de preferência de múltipla escolha, com a recomendada em primeiro. Antes da pergunta vem a explicação inteira: contexto, definições, por que fazer e a consequência de não fazer, a sugestão honesta em uma linha e, se houver ação dele, passos concretos dizendo o que é cada campo e o que é escolha nossa. Ele é gestor, não desenvolvedor.
- **Questão secundária não para o trabalho:** guarda de forma (nome, redação, ordem) se contorna na hora e o contorno vira lição; só segurança, integridade, qualidade do produto e CI param o trabalho.
- **Novas ideias:** varrer os documentos (agente de pesquisa), classificar (já coberta, extensão, nova, conflito), separar o que o orquestrador aplica do que é do dono e perguntar só o que é dele. O que ele não comentar está aprovado.
- **Ausente:** adiantar tudo o que não depende dele e acumular as perguntas. Cada mensagem termina dizendo, em uma linha, o que se espera dele, ou que não há nada.
- **Mudança de regra de trabalho** (modelo, paralelismo, papéis): gravar na memória na hora e nos documentos do repositório no próximo PR.
- **Aviso fora da sessão** (celular) só para: decisão dele pendente, portão pronto e trabalho parado que o orquestrador não destrava. Fora disso, silêncio.

## 7. Ambiente e continuidade
- **Sessão do orquestrador** dentro de um multiplexador de terminal (tmux), aberta pelo comando do kit (`sessao-projeto NOME`), que retoma a conversa pelo id dela. Um hook do evento de falha por limite mantém o computador acordado e agenda um "continue" depois do reset; depois de um limite, confira os agentes e retome os que pararam.
- **Saúde da máquina e processos parados não são do orquestrador:** as automações e o zelador cuidam deles. O orquestrador só responde quando o zelador pergunta se pode finalizar um processo dele.
- **Sessão duplicada:** antes de agir depois de uma retomada, confirme que só uma sessão orquestradora está viva.
- **Fim de sessão é passagem de bastão, nunca compactação:** estado de cada briefing correto, memória do projeto com os agentes vivos e os worktrees, regras e lições da sessão incorporadas, nenhum PR aberto sem dizer em que passo do ciclo está. Se houver compactação mesmo assim, reconfira no repositório e no serviço de Git (PRs, commits, CI, worktrees) antes de qualquer merge: o que a memória diz e o GitHub desmente, o GitHub vence.
- **Todo dia, ao começar:** `gh issue list` e as últimas execuções dos fluxos agendados. Falha noturna repetida passa despercebida se o orquestrador só acompanha a CI dos PRs.
- **Memória:** o que é da máquina e dos agentes vivos vai para a memória do Claude Code. O que é do projeto vai para o repositório.

## 8. Autoaperfeiçoamento
**Um erro só pode acontecer uma vez por motivo.** Gatilhos (qualquer um obriga a parar e registrar): bloqueante do revisor; CI vermelha repetida; PR acima do limite; conflito de merge; merge desfeito logo depois; correção do dono; incidente de ambiente; decisão tomada com dado velho; descoberta que o próximo orquestrador precisaria saber.

**Formato da lição:** o fato, a causa (não o sintoma), a regra derivada e **o lugar onde a regra foi aplicada**. Lição sem lugar de aplicação não está pronta. Só o incidente que mudou uma regra vira lição numerada; o truque técnico vai em uma linha para `aprendizados/` do papel.

**Onde cada regra mora, do mais forte ao mais fraco:** 1. verificação automática (script, CI, hook, teste); 2. `CLAUDE.md` do projeto (vale para todo agente); 3. skill do papel; 4. briefing da etapa; 5. `aprendizados/` do papel; 6. memória (máquina, estado vivo, preferência do dono); 7. esta skill (método de qualquer projeto). Regra que só vive na memória de um modelo se perde na troca de modelo. Lição repetida em duas etapas sobe para a verificação automática.

**Auditor de qualidade.** Depois de muitas interações as regras tendem a se contradizer e os aprendizados a crescer. O orquestrador ou o dono chama o auditor (skill `auditor-de-qualidade`) toda semana, no reinício do uso, e sob demanda, quando houver: falha ou rodada extra repetida em 2 PRs; regra que contradiz outra, ou correção do dono; limites da §9.4 passados; CI ou ciclo mais lentos sem motivo claro; fim de fase ou portão. Ele só lê e relata; **só o orquestrador altera** as regras, a partir do relatório. Decisão que dependa do dono vai a ele antes, com contexto completo.

**Retrospectiva da etapa**, respostas no Registro do briefing:
- O que o briefing não disse e o codificador precisou perguntar ou adivinhar?
- O que o revisor achou que o briefing deveria ter prevenido?
- Quanto passou do tamanho, e por quê?
- O que custou tokens ou tempo à toa?
- O que o dono precisou corrigir?

**Retrospectiva da fase:** auditor de qualidade, aplicar o relatório de uma vez; reler as lições; promover a que se repetiu; marcar como superada a que a mudança tornou inútil; podar regras já viradas verificação automática.

## 9. Como registrar regras e aprendizados
**Objetivo:** cada regra num lugar só, curta, sem contradizer outra; o que se lê em toda sessão fica mínimo.

**9.1 Onde mora** (use o primeiro que couber): 1. checável por máquina → verificação automática, e a regra escrita vira uma linha que aponta para ela; 2. vale para todo agente → `CLAUDE.md`; 3. só para um papel → skill do papel; 4. só para uma etapa → briefing; 5. truque técnico que custou tempo → `aprendizados/<assunto>.md` da skill do papel; 6. máquina, estado vivo ou preferência do dono → memória; 7. método para qualquer projeto → esta skill.

**Não registre** o que já está escrito noutro lugar (cite), estado (vai para a memória de estado, reescrita), o que o `git log` guarda, o que vale uma vez, opinião sem decisão nem dado.

**9.2 Modelos fixos**
- **Regra** (até 3 linhas ou 60 palavras): `- **<assunto>:** <o que fazer, no imperativo>. <porquê em meia frase>. (<quem decidiu>; substitui <regra antiga>)`
- **Aprendizado:** um arquivo por assunto, com `indice.md` de uma linha por assunto; uma lição por item, até 6 linhas: `## <título que já diz a regra>` e as linhas Origem, Sintoma, Causa e regra, Prova. Papel sem escrita no repositório (revisor, auditores, vigia da CI) grava a lição em `~/.cache/gerente-maquina/<projeto>/aprendizados-pendentes/<papel>-<PR ou data>.md`, e o orquestrador a manda ao documentador.
- **Memória:** até 25 linhas, só o que vale hoje; o histórico vai para um arquivo fora do índice; índice de uma linha por memória.

**9.3 Checagem antes de inserir (obrigatória):** procure regra igual ou vizinha com `grep -rniE '<termos>'` na memória, nas skills, no `CLAUDE.md` e nos docs de processo. Igual: não crie. Parecida: funda. Contraditória: reescreva a antiga em todos os lugares, marque "substitui …" e apague a velha. Decisão do dono: memória na hora; repositório no próximo PR do documentador.

**9.4 Manutenção:** fim de etapa, aprendizado novo entra no arquivo do assunto. Aprendizado que virou regra ou verificação sai, deixando "(ex-aprendizado <assunto>)" na regra. Alerta para consolidar: índice da memória com mais de 15 linhas, memória com mais de 25, `CLAUDE.md` com mais de 3 mil tokens, aprendizados de um papel com mais de 5 mil.

## 10. Lições que valem para qualquer projeto
- Briefing sem divisão prevista gera PR de 1.000 a 1.600 linhas; com a divisão e a contagem antes do PR, o tamanho fica sob controle.
- Docs compartilhados (progresso, contexto, instruções) conflitam em todo PR paralelo. Por isso o andamento é escrito em fragmentos, um por PR, e consolidado por script (`docs/processo/andamento.md` do modelo). Nos que sobram, mantenha os dois lados e depois compare com a principal, porque "os dois lados" duplica uma linha editada por dois commits.
- O agente que aplica uma decisão tende a decidir junto o que não foi pedido. O revisor separa "decisão do dono" de "proposta do orquestrador" e de "escolha do codificador", e cada uma fica marcada no documento.
- Varredura grande vai a um agente econômico: o relatório volta pronto para virar perguntas ao dono, e o contexto do orquestrador fica livre.
- Recomendação de merge vem sempre com o critério de prova ("causa nomeada e N verdes seguidos"), nunca "se passar".
- Esperar em primeiro plano só em blocos curtos (até cerca de 270 s): sessão parada mais de 5 min relê o contexto inteiro a preço cheio. Espera longa se entrega e se termina.
- Cada despertar de vigia relê o contexto: vigia só avisa em mudança de estado.

Os aprendizados técnicos desta skill estão em `aprendizados/` (leia o assunto da tarefa).
