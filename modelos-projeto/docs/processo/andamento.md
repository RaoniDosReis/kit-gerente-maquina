# Andamento

Modelo. O andamento tem três partes: este arquivo (consolidado, histórico + pendências com dono + números), a pasta `andamento.d/` (um fragmento por PR, ainda não consolidado) e o estado de cada briefing. **A atualização do andamento a cada merge é obrigatória; a documentação pode ter atraso, o andamento não.**

## Por que fragmentos
Arquivos de andamento compartilhados conflitam em todo PR paralelo. Com um fragmento por PR, nomes diferentes nunca conflitam, e só o PR de consolidação toca o arquivo consolidado.

## 1. Escrever o fragmento (todo PR, menos o de consolidação)
- Nome: `andamento.d/<branch>.<tipo>.md`, branch em minúsculas com `/` trocada por `-`. Um fragmento por PR.
- Tipo: `etapa`, `correcao`, `seguranca`, `docs`, `processo`.
- Texto: o que fica valendo depois do merge, no passado, começando pelo id da etapa. Um parágrafo de uma a cinco frases; o detalhe fica no Registro do briefing, citado pelo caminho.
- Depois, opcional: uma linha `Pendências com dono:` e uma lista `- <dono>: <o quê>`.
- Proibido: título (`#`), tabela, link relativo (cite caminhos entre crases), comentário HTML, marca de conflito, fragmento vazio.

Exemplo, `f1-03-login.etapa.md`:
```
F1-03: tela de login com recuperação de senha, 9 cenários com teste (Registro em `etapas/f1-03.md`).

Pendências com dono:
- orquestrador: capítulo do manual sobre recuperação de senha.
```

## 2. Consolidar (o orquestrador manda, o documentador faz)
Consolide **a cada merge**, no mesmo dia, e antes de cada portão ou prévia ao dono. Quanto mais mecânico, melhor: o ideal é um script (`scripts/consolidar.*`) que junta os fragmentos, gera o bloco de números e copia as pendências agrupadas por dono, sem nada escrito à mão; a CI confere de forma determinística (o bloco gerado bate com o script, nenhuma pendência sumiu, só os arquivos permitidos mudaram) e dispensa o revisor nesse PR puramente mecânico. Texto livre e triagem das pendências continuam com revisor independente, em PR separado. Erro em qualquer passo: a CI falha com a mensagem do ocorrido, o orquestrador é chamado e nada entra na principal.
Sem o script ainda, os passos manuais: branch `consolidacao-andamento-<data>`; juntar os fragmentos nesta página, em ordem de data; acrescentar as pendências com dono; riscar as que foram fechadas; atualizar números e estado; apagar os fragmentos; verificação de docs; PR. Atraso na consolidação é defeito, como a principal vermelha: a linha "andamento.d: N fragmentos, o mais antigo de DD/MM" aparece no início da sessão.

## 3. PR aberto antes desta regra
Depois de atualizar a branch com a principal, copie para o fragmento o que o PR pôs aqui, restaure este arquivo da principal (`git checkout origin/<principal> -- <arquivo>`), crie o fragmento e rode a verificação de docs.

---

## Estado
Última consolidação: <data>. Fase: <...>. Números: <...>.

## Pendências com dono
- <dono>: <o quê>

## Histórico
<Itens consolidados, do mais recente ao mais antigo.>
