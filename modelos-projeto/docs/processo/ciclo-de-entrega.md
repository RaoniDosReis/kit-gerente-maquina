# Ciclo de entrega automatizado

Modelo: ajuste os nomes. O dono atua como gestor da automação: o ciclo de cada entrega roda sem intervenção dele, salvo os portões que ele reservou. Este documento é a regra; as skills dos papéis a executam; o método geral está na skill global `orquestrador-de-agentes`.

## Papéis
| Papel | Modelo | Pode | Não pode |
|---|---|---|---|
| Orquestrador | capaz | planejar, briefar, aprovar e fazer merge, abrir a próxima etapa, acionar agentes dentro do orçamento recebido | revisar, codificar |
| Codificador | capaz; agente novo por etapa e por rodada | implementar em branch, rodar verificações, abrir o PR, terminar sem esperar a CI; corrigir CI (diagnosticada pelo vigia) e achados; mostrar as três provas | fazer merge, decidir fora do briefing |
| Revisor | capaz; agente novo por PR e por rodada, sem o contexto do codificador | publicar no PR a revisão: bloqueantes (correção, requisito, contrato, segurança, regra perdida), não bloqueantes, "sem objeções"; conferir as três provas | aprovar, fazer merge, alterar código |
| Auditor de segurança | capaz | revisar a segurança em paralelo ao revisor; crítico/alto bloqueia, médio/baixo vão para a fila | corrigir |
| Auditor de qualidade | capaz; semanal e sob demanda | relatório de conflitos, regras vencidas, redundâncias e desperdícios | alterar qualquer coisa |
| Testador-usuário | econômico; só navegador | executar as tarefas do manual como um humano e relatar | ler código, alterar |
| Documentador, mantenedor de branches, vigia da CI | econômico | registrar decisões; atualizar branches; diagnosticar CI | decidir, mexer em lógica, corrigir |
| Dono | | portões reservados (abaixo) | |

## Ciclo de uma etapa
1. O orquestrador abre a branch a partir da principal e escreve o briefing (`etapas/<etapa>.md`, modelo em `modelo-de-briefing.md`).
2. Codificador implementa, roda as verificações locais, abre o PR com o modelo e termina.
3. CI. Vermelha: o vigia diagnostica e um codificador novo corrige (no máximo 5 ciclos; depois, "precisa de humano" e o orquestrador decide ou escala ao dono). A rede de segurança é a CI inteira toda noite na principal.
4. Revisor publica a revisão (o PR só de registro, sem código nem regra nova, a dispensa). Bloqueante volta ao passo 3 com o achado no briefing.
5. Se há interface: o orquestrador sobe o ambiente de teste e aciona o testador-usuário com o manual. Erro volta ao passo 3; sugestões vão ao dono (desempenho e segurança o orquestrador aciona um codificador e avisa).
6. Tudo verde, revisor sem bloqueio, testador sem erro: o orquestrador arma o merge (squash) e abre a próxima etapa. O andamento entra pelo fragmento do PR (`andamento.md`).

## Entradas e saídas obrigatórias
- Briefing: `etapas/<etapa>.md` (o contrato da etapa).
- PR: título com o requisito/etapa; corpo pelo modelo; rastreabilidade pergunta → requisito → decisão.
- Revisão: comentário no PR com "Veredito:"; o workflow grava o status `revisor-independente`, obrigatório na principal protegida.
- Relatório do testador: o orquestrador o grava em `testes-de-usuario/<etapa>-<data>.md` e resume no PR.
- Manual do usuário (`docs/manual/`): ente em evolução; toda etapa que muda a tela o atualiza no mesmo ciclo.

## Portões reservados ao dono
- Decisão que mude drasticamente funcionalidade já amarrada ou seja mudança significativa de arquitetura (as técnicas, seguras e eficientes, o orquestrador aceita e registra).
- Revisão geral da documentação e do plano.
- Mudança de filosofia, escopo de fatia ou ordem de entrega.
- Sugestões do testador que não sejam desempenho ou segurança.
- Fim de cada fatia: demonstração e "pode seguir" antes da seguinte. Enquanto ele testa, o orquestrador pode preparar briefings, mas nenhum PR de código da fatia seguinte é aberto.
Fora disso, o ciclo avança sozinho e o dono recebe o resumo e, quando precisar agir, o aviso.

## Limitações conhecidas
As sessões agem com a conta do dono no GitHub: a revisão do agente aparece em nome dele e não conta como aprovação formal. O veredito vira o status `revisor-independente` (workflow `.github/workflows/status-do-revisor.yml`), obrigatório na regra de proteção da principal; o GitHub só mescla com a CI e esse status verdes no head.
