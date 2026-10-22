# CI, fluxos agendados e testes instáveis

- Confira todo dia as issues e as execuções dos fluxos agendados.
- Varredura verde só vale para os alvos que ela leu.
- Item instável: peça a causa, não o prazo maior.
- Teste com linha de comando e app: um relógio só.
- Vigia que engole erro deixa a sessão parada.

## Confira todo dia as issues e as execuções dos fluxos agendados
- Origem: varredura noturna de dependências.
- Sintoma: falhou três noites seguidas pela mesma vulnerabilidade crítica, o fluxo abriu três issues e ninguém olhou: o orquestrador só acompanhava a CI dos PRs e a da principal.
- Causa e regra: ao começar o dia, `gh issue list` e `gh run list --workflow <agendados> -L 3`. Para cada falha, abra o log, ache a causa e crie a tarefa no mesmo dia. Feche as issues repetidas apontando para a mais nova.
- Prova: issues abertas pelo fluxo sem resposta.

## Varredura verde: confira quais arquivos o scanner de fato leu
- Origem: correção de vulnerabilidade em dependência.
- Sintoma: o resumo do scanner listava só dois lockfiles; o terceiro (do gerenciador de pacotes Python) ficava de fora, com um aviso de falha de leitura. As dependências Python nunca entravam na varredura, e o job seguia verde.
- Causa e regra: "Total: 0" só vale para os alvos do resumo, e lockfile ilegível vira aviso, não falha. No briefing de toda varredura, peça a lista de alvos comparada com `git ls-files | grep -i lock` e os avisos do scanner. O alvo que faltar vira tarefa própria.
- Prova: resumo do scanner versus lista de lockfiles.

## Item instável de verificação automática: peça o motivo, não o prazo
- Origem: verificador de acessibilidade que ficava "a conferir" só com a CI carregada.
- Sintoma: a tentação era aumentar o prazo ou pôr o item em exceção. A causa: a fonte dos ícones ainda baixando; a ferramenta media o ícone como texto.
- Causa e regra: peça (1) o motivo que a própria ferramenta dá, (2) a reprodução determinística da condição de carga (bloquear ou atrasar o recurso), (3) a correção nas duas pontas: a condição esperada no teste e o produto robusto sem ela. Recuse prazo maior.
- Prova: o teste reproduz a falha bloqueando o recurso.

## Teste que mistura linha de comando e app: um relógio só, passado de forma explícita
- Origem: teste que falhava só com a máquina carregada.
- Sintoma: o app do teste usava relógio parado, a linha de comando lia o relógio de parede; se a preparação passava de 5 s, o link antigo seguia aceito.
- Causa e regra: falha "só sob carga" com relógio injetável costuma ser dois relógios no mesmo teste. Reproduza atrasando a etapa lenta; corrija fazendo o código aceitar o relógio por parâmetro e o teste passar o mesmo, nunca prazo maior. No briefing peça a lista de quem lê o relógio, a prova com o produto nos relógios reais e a varredura dos outros testes com o mesmo par.
- Prova: atrasar a etapa lenta em alguns segundos reproduz a falha.

## "Ninguém acordou": comece pelos vigias que engolem erro
- Origem: sessão parada por mais de 5 h com a CI pendente.
- Sintoma: o vigia da CI ficou mudo porque a versão do `gh` instalada não tinha uma opção que o script usava, e o erro ia para `2>/dev/null`.
- Causa e regra: todo vigia tem prazo máximo, conta de consultas com erro e mensagem de saída; teste-o à mão contra a versão da ferramenta da máquina. Procure `2>/dev/null || echo` em laço, ausência de prazo e estado em arquivo dividido entre sessões.
- Prova: `gh <comando> --help` da versão instalada.

## Junção de relatórios de vários jobs pelo nome sobrescreve em silêncio
- Origem: revisão de PR que dividiu a CI em jobs paralelos.
- Sintoma: copiar arquivos de várias pastas de artefatos para uma plana deixava a última pasta sobrescrever o relatório de mesmo nome.
- Causa e regra: use lista permitida por pasta ou recuse nome repetido. Com poucos executores e muitos jobs na fila, o "caminho crítico" não é o tempo até o verde: confira os horários de início dos jobs da execução (`gh run view --json jobs`). Medição antiga perde a validade quando o PR é rebaseado sobre outro que acrescentou testes.
- Prova: plantar um relatório de mesmo nome na pasta copiada por último.
