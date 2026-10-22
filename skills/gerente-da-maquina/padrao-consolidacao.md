# Padrão de consolidação do andamento (todos os projetos)

Origem: auditoria de qualidade que achou consolidação parada por dias, dezenas de fragmentos soltos e pendências presas. Recomendação: hook/CI para o que é mecânico; revisor independente só para o que o modelo escreveu; começar pelo mais simples.

## R2, consolidação mecânica sem revisor
- Um script do projeto (`scripts/consolidar.py`) gera a consolidação inteira: junta os fragmentos, gera o bloco de números do contexto e copia as pendências agrupadas por dono. Nada escrito à mão.
- A CI confere de forma determinística (o bloco gerado bate com o script, nenhuma pendência sumiu, só os arquivos permitidos) e grava o status do revisor nesse PR puramente mecânico.
- Texto livre do contexto e triagem das pendências continuam com revisor independente, em PR separado.
- Erro em qualquer passo: a CI falha com a mensagem do ocorrido, o orquestrador é chamado e nada entra na main.

## Andamento obrigatório a cada merge
O andamento (progresso, bloco de números e pendências do contexto, PRs em andamento) é consolidado A CADA MERGE, no mesmo dia, sem prazo: o vigia de merge do orquestrador, com a CI da main verde, roda o script, abre o PR mecânico do R2 e arma o merge. A documentação pode atrasar; o andamento não.

## R1, barreira na CI (só texto livre e triagem)
- Aviso em job não obrigatório depois de 24 h de atraso; erro no job obrigatório depois de 48 h, com a mensagem do motivo. Isentos: o próprio PR de consolidação e o conserto da main vermelha.
- A linha "fragmentos: N, o mais antigo de DD/MM" aparece no início da sessão e no vigia de merge.

## Quem faz
Cada orquestrador implementa no seu repositório por PR, pelo ciclo normal. O gerente garante o padrão em cada projeto novo.
