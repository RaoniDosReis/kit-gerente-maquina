# Portão de merge e merge

Parte da skill `orquestrador`, lida antes de cada merge.

**Portão.** CI verde no head atual; PR mesclável (`mergeStateStatus` `CLEAN`); atrás da principal: atualizar por **merge** da principal (`gh pr update-branch <n>` ou o mantenedor de branches; conflitos de docs resolvidos mantendo os dois lados e comparando com a principal), CI de novo, **nunca rebase com force-push** (perde o status do revisor); última rodada do revisor sem bloqueante e ajustes aplicados (ou, no PR só de registro, status dispensado); nenhum commit depois da última rodada sem nova rodada, salvo atualização com a principal sem mudança de diff; exceção de tamanho aceita por escrito antes do PR; corpo do PR completo; fragmento de andamento no PR; nenhum achado crítico ou alto do auditor aberto.

**Merge armado.** Conferido o portão e com o veredito sem bloqueante sobre o head `<sha>`:
`gh pr merge <n> --auto --squash --match-head-commit <sha>`
O GitHub mescla sozinho quando as verificações obrigatórias e o status `revisor-independente` ficam verdes nesse head, e não mescla outro head. Depois do merge: vigie a CI do commit do merge na principal até o fim; apague a branch; remova o worktree; avise os codificadores de etapas paralelas para atualizar a branch quando tocam docs compartilhados. A consolidação do andamento é o único PR que edita os arquivos consolidados (`docs/processo/andamento.md`).

**Principal vermelha:** só entra o PR de conserto; ninguém mais mescla, a CI dos outros PRs é cancelada e os agentes seguem com commit local, sem push.

**Branch de integração:** consertos que só ficam verdes juntos (cada um sofre o defeito do outro) vão numa branch de integração com PR rascunho; 2 verdes nela provam o conjunto, e só então cada PR é mesclado, em ordem.

Portões reservados ao dono: `docs/processo/ciclo-de-entrega.md`, seção "Portões reservados ao dono".
