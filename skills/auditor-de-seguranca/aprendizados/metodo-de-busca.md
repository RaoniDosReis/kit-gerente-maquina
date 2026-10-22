# Onde procurar: lições de método

- Autorização por objeto: toda rota com o mesmo modelo de corpo precisa da mesma conferência.
- Chave estrangeira simples não prova que o objeto é do mesmo dono.
- Entrada hostil: aninhamento, custo quadrático, regex cúbica, alias que expande.
- Restrição que vem depois do primeiro `open` não reduz a superfície.
- Prazo do job é de quem o define: confira o teto do worker e a repetição.
- Dado derivado do teste sobrevive à edição do que foi testado.
- Segredo no caminho da URL: confira todos os logs de acesso.
- Limite de corpo: proxy E app, rota a rota, inclusive a rota final.
- Datas extremas: o banco grava, o driver não lê.
- Aviso de troca de senha: a quem ele chega; entrada em voo cria sessão depois da revogação.
- Erro de banco não tratado põe os parâmetros no log.
- Verificação em shell: `curl | grep -q` com `pipefail`; link de outro usuário.
- Cabeçalho e log do proxy: prove com a imagem do projeto e destino fora do ar.
- Dependências e histórico: alvos lidos, espelho com refs de PR, alcance de CVE.
- Texto do modelo ou da entrada chega a terminal, relatório e arquivo.

## Toda rota que aceita o mesmo modelo de corpo precisa da mesma conferência
- Origem: auditoria de API.
- Sintoma: uma rota confere o objeto referenciado e a rota irmã grava o mesmo modelo sem conferir; o download do recurso protegido vem junto.
- Causa e regra: a conferência mora na rota, não na validação do modelo. Para cada campo que referencia objeto, procure com grep todo lugar que usa o modelo e confira cada caminho.
- Prova: criar pelo caminho irmão e pedir o recurso protegido.

## Chave estrangeira simples não prova que o objeto é do mesmo dono
- Origem: auditoria de API.
- Sintoma: um item de rascunho do atacante aponta para a camada de um objeto finalizado da vítima, e a junção que não repete a condição do dono duplica dados do atacante na leitura da vítima.
- Causa e regra: procure FK que deveria ser composta com o dono e junções que não repetem a condição do dono. Prove sem subir o ambiente inteiro, com os fixtures de usuários e linhas diretas do próprio repositório, um teste por vez, com `nice`.
- Prova: inserir pelo motor do teste e ler como a vítima.

## Entrada hostil que dá 500 ou custo desproporcional
- Origem: auditorias de API e de ferramentas que processam JSON, YAML, Markdown e SQL.
- Sintoma: (a) `json.loads` da biblioteca padrão levanta `RecursionError` (não é `ValueError`) a partir de cerca de 10 mil níveis, enquanto o `model_validate_json` do Pydantic devolve 422; (b) o `uniqueItems` do `jsonschema` é quadrático e ignora `maxItems`; (c) alias do YAML expande no `repr` da mensagem de erro (centenas de bytes viram centenas de MB); (d) regex de título com dois `[ \t]*` em volta de um opcional é cúbica; (e) o `progress_handler` do SQLite não interrompe `instr`, `replace` e `LIKE`, que são O(n·m) dentro de uma instrução.
- Causa e regra: procure `json.loads` de entrada externa sem captura de `RecursionError`; teto de bytes não basta, peça orçamento de nós antes da validação; procure `!r` e `repr(` com valor do YAML e recuse âncoras; meça regex com linha longa; meça o pior caso de cada função liberada no teto de tamanho do SQLite. Meça o tempo da recusa no teto.
- Prova: uma entrada de poucas centenas de bytes que segura a chamada por dezenas de segundos.

## Restrição que vem depois do primeiro `open` não reduz a superfície
- Origem: workers que abrem arquivo de terceiros.
- Sintoma: uma lista fechada de formatos parece lista permitida, mas funções de metadados já abriram o arquivo com todos os drivers.
- Causa e regra: liste toda chamada que recebe o caminho e confira se a restrição (parâmetro de driver, variável de ambiente que desliga drivers) vem antes; desligue o acesso remoto da biblioteca se o processo não usa. Para provar alcance de LFI/SSRF e estouro de dimensões sem subir tudo: rode o detector de tipo do serviço real sobre o arquivo de prova e calcule a grade resultante sem escrever o arquivo; nunca imprima o conteúdo lido de `/etc/passwd` ou `/proc`. Confira também `cpus`, `pids_limit` e teto de largura x altura antes de ler pixel.
- Prova: número de drivers carregados no processo do worker.

## O prazo do job é do núcleo: confira o teto do worker e a repetição
- Origem: workers com fila.
- Sintoma: o heartbeat corre em outra thread, então o worker parece vivo durante uma leitura longa; o núcleo só devolve o job depois de 1 h, com várias tentativas.
- Causa e regra: some prazo x tentativas x réplicas e veja quanto tempo um único envio ocupa a fila; exceção não tratada vira falha repetível, então cada defeito de conteúdo multiplica o custo. Peça prazo por tipo de job no worker e falha de conteúdo não repetível.
- Prova: constantes de prazo e tentativas e o `except Exception` do runner.

## Dado derivado do teste sobrevive à edição do que foi testado
- Origem: fonte externa cadastrada pelo administrador, cuja URL vai ao navegador.
- Sintoma: a ativação exige teste e a edição "apaga o último teste", mas a fonte ativa editada continua entregue e o modelo de URL lido do documento antigo junta o host antigo com a chave nova.
- Causa e regra: liste os campos que o teste grava e, para cada campo editável, confira se a edição invalida o derivado e se a entrega olha o resultado do teste. Confira marcadores no host (`{chave}`, `{s}`) que escapam da conferência literal.
- Prova: teste que edita a fonte ativa e pede a entrega.

## Segredo no caminho da URL e limite de corpo
- Origem: auditorias de proxy.
- Sintoma: link de senha ou token de download no caminho aparece no log do servidor de arquivos estáticos (que herda o log padrão da imagem); corpo enorme anônimo numa rota pública derruba o processo por falta de memória porque o limite do proxy valia só nas rotas "perigosas".
- Causa e regra: confira cada salto de log (proxy, app, servidor estático), o log de requisição com o modelo da rota e não o caminho cru, e o nível de isolamento quando uma correção de corrida troca `FOR UPDATE` por trava em outra linha mais reconferência (a reconferência só enxerga o commit alheio em READ COMMITTED). Confira o limite de corpo no proxy E no app, inclusive na rota final de fallback.
- Prova: requisição com marcador no caminho e procura nos três logs; corpo grande em rota pública.

## Datas extremas e erro de banco não tratado
- Origem: auditoria de API.
- Sintoma: uma data válida no esquema (ano 1 em UTC) é gravada pelo banco e recusada pelo driver ao ler, e toda consulta que lê a linha passa a dar 500, com dano persistente; um erro de banco não tratado grava no log os parâmetros do SQL (valores protegidos).
- Causa e regra: procure campos de data sem limite inferior e superior em UTC, na API e em datas vindas de arquivo; ligue `hide_parameters` no motor e provoque um 500 de banco com um marcador, procurando-o na saída.
- Prova: gravar e ler a data num banco temporário em rede própria, derrubando tudo pelo nome exato.

## Troca de senha: o aviso e a sessão em voo
- Origem: auditoria de autenticação.
- Sintoma: (a) o aviso "senha redefinida" sai na primeira entrada depois da troca, mas quem o recebe é sempre o próprio autor da troca; (b) a troca revoga as sessões existentes, mas uma entrada com a senha antiga, ainda conferindo o hash, cria a sessão depois da revogação (a trava `FOR NO KEY UPDATE` não conflita com o `FOR KEY SHARE` da chave estrangeira da sessão nova).
- Causa e regra: exija um rastro que ninguém na conta apague (histórico de acessos visível ao titular) e aviso que não se consome na primeira entrada; a entrada lê o usuário com `FOR SHARE` ou relê o hash travado antes de criar a sessão. Prova de corrida: aplique o `monkeypatch` depois da preparação, atrase só a vítima e dispare a ação concorrente por um `threading.Event`, não por tempo; prove também contra a principal para ver a prova discriminar.
- Prova: sessão antiga com 200 depois da troca na principal e 401 no PR.

## Verificações em shell
- Origem: instaladores com `--check`.
- Sintoma: `if curl -D - | grep -qi '^alt-svc:'` parece reprovar o cabeçalho proibido, mas o `grep -q` sai no casamento, o curl leva SIGPIPE e o `pipefail` torna o pipeline falso; curl sem resposta também cai no "ok". Conferir só o caminho resolvido de uma pasta deixa passar o link de outro usuário; `git` rodando como root numa cópia lê `.git/config` de qualquer dono (`core.fsmonitor` roda já no `git status`). Confirmação "veja e aceite" de conteúdo de outro usuário que aceita caracteres de controle manda sequências de escape ao terminal.
- Causa e regra: guarde a saída (`h="$(curl … || true)"`), confira `HTTP/*` e só então `grep <<<"$h"`; confira o caminho original (com `lstat`) e o resolvido; confira a árvore inteira antes de rodar `git` como root; recuse caracteres de controle; prove corridas esperando um efeito visível, e conte o sucesso pela saída, não pelo código.
- Prova: função que grava a linha, dorme 0,2 s e grava outra: `PIPESTATUS=141 0`.

## Proxy: cabeçalhos e logs
- Origem: auditoria de proxy reverso.
- Sintoma: `header ?Campo valor` põe o cabeçalho no 200 e no 404 do destino, mas não no 502 nem no 413 gerados pelo próprio proxy; ler o filtro de log não diz se o caminho do campo casa com o que o proxy grava.
- Causa e regra: para cobrir erros do proxy use o bloco de tratamento de erros; para provar filtro de log, rode a imagem do projeto fixada por digest com um destino fora do ar, mande marcadores no cabeçalho, no cookie e na query (HTTP/1.1 e HTTP/2) e procure os marcadores nos logs do contêiner. Remova o contêiner pelo nome exato.
- Prova: 502 nas três requisições e nenhum marcador no log.

## Dependências, histórico e texto do modelo
- Origem: varreduras e ferramentas que usam modelo de linguagem.
- Sintoma: o scanner recusa o lockfile de workspace do gerenciador Python e as dependências somem da varredura sem alarme; clone de trabalho só tem as branches, então o gitleaks não vê commits de PRs fechados; tarball de pacote npm com CVE precisa de conferência sem executar nada; o texto devolvido pelo modelo (nome de ferramenta, argumentos) chega cru ao placar, ao comparador e ao relatório.
- Causa e regra: exporte o lockfile para `requirements.txt` e rode o auditor da linguagem; espelhe com `git clone --mirror` e rode o gitleaks com `--log-opts="--all" --redact=100`; para pacote npm, `npm pack` numa pasta própria, compare o sha512 com o `integrity` do lock, leia o código sem executar, confira procedência e idade da versão, e rastreie quem puxa o pacote e em que estágio do build; filtre a saída do modelo em todo `print` e `write` (escapes de terminal) e meça o falso positivo do detector de vazamento sobre o texto visível normalizado. Compare só o que o harness pôs, não as chamadas roteirizadas.
- Prova: lista de alvos do resumo comparada com os lockfiles do repositório.
