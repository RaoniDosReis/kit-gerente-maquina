<!-- Título: o requisito ou a etapa e o resumo. Corpo em português. Uma história por branch e por PR. -->

## O que muda
<!-- Resumo em linguagem simples. Briefing: docs/processo/etapas/<etapa>.md -->

## Rastreabilidade
<!-- Pergunta do dono → requisito → decisão de origem. -->

## Requisitos entregues
<!-- Um por linha, o id primeiro. -->

## Requisitos parciais (cenários)
<!-- Requisito e os cenários entregues neste PR; os demais continuam pendentes. -->

## Contratos alterados
<!-- Esquema, evento, job ou endpoint: esquema, testes e docs no mesmo PR. "Nenhum" se não houver. -->

## Como foi testado
<!-- Grupos de verificação rodados localmente, testes novos, navegador usado. -->

## As três provas
<!-- 1. Teste novo falhando contra o código antigo (cole a falha). 2. Evidência de cada afirmação. 3. Um caso de borda. -->

## Riscos (responda sim ou não; "sim" pede a prova)
- [ ] Apaga, derruba ou mata algo (arquivo, pilha, rede, volume, processo)? Só pelo nome ou PID exato, do seu usuário e da sua vaga; teste com nome hostil.
- [ ] Lê entrada do cliente (corpo, JSON, arquivo)? Teste do pior caso: resposta 4xx, nunca 5xx.
- [ ] Muda contrato? Esquema, testes e docs neste PR.
- [ ] Cria trava, fila, tentativa ou outra primitiva? Biblioteca mantida conferida na versão atual.
- [ ] Rodada de correção: o que mudou além do achado? Cada mudança com prova própria.

## Operação
<!-- Só no PR que cria ou muda modo de falha ou procedimento de operação: o cenário novo no catálogo de falhas, ou "Sem cenário novo no catálogo de falhas: <motivo>". Nos demais, apague a seção. -->

## O que ficou de fora
<!-- O que o briefing pedia e não entrou, com o motivo; não bloqueantes deixados para depois. -->

## Lista de conferência
- [ ] CI verde
- [ ] Docs atualizados no mesmo PR (fragmento em `docs/processo/andamento.d/`)
- [ ] Nenhuma exceção de análise estática sem justificativa; nenhum piso de cobertura baixado
