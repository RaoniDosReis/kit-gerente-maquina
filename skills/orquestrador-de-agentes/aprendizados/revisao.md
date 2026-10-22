# Revisão independente

- Prove mutação e código antigo sem editar o worktree de revisão.
- Reproduza o merge que a CI testa num clone descartável.
- Primitiva de concorrência própria: procure a biblioteca na versão atual e meça a fome.
- Segredo no texto de uma exceção de validação.
- Teste de uma defesa por cabeçalho: mutação mental.
- Aprendizado de auditor escrito sobre o estado atual do código é pista de achado aberto.
- Acessibilidade: teste no foco real, pelo teclado.

## Mutação e código antigo sem editar o worktree
- Origem: revisão de correção com teste novo.
- Sintoma: era preciso provar que o teste pega uma mutação do produto e reproduzir a falha da CI com o código antigo.
- Causa e regra: extraia uma cópia com `git archive <commit> <pastas necessárias> | tar -x -C <pasta>` (os testes procuram dados e arquivos irmãos: só uma pasta pode quebrar), rode da cópia com `PYTHONPATH=<cópia>/...` na frente do pacote instalado e confira com `python -c "import pacote; print(pacote.__file__)"`. Para simular carga, um plugin do pytest num diretório à parte que embrulha a função com `time.sleep`. "Mesmo instante" prova a comparação estrita.
- Prova: a mutação faz o teste falhar.

## Reproduzir o merge que a CI testa
- Origem: revisão de script que depende da base ou da branch do PR.
- Sintoma: a CI testa o commit de merge (`refs/pull/N/merge`) com clone raso; provar sem esperar a CI.
- Causa e regra: num clone descartável, avance a principal depois do corte da branch e faça `git merge --no-ff <branch>` nela; anote o SHA; numa pasta vazia, `git init` e `git fetch --depth 2 <clone> <sha>`; rode o script com as variáveis da CI (`GITHUB_ACTIONS=true GITHUB_EVENT_NAME=pull_request GITHUB_HEAD_REF=<branch>`). Repita com `push` e `schedule`, e com `--depth 1` para a mensagem de falta do pai.
- Prova: saídas dos três eventos.

## Primitiva de concorrência própria: procure a biblioteca e meça a fome
- Origem: PR que montou trava de leitura e escrita entre processos.
- Sintoma: o PR dizia que a biblioteca "só tem trava exclusiva"; o teste passava mesmo sem a proteção contra fome do escritor, porque usava poucos leitores.
- Causa e regra: o `flock` do Linux deixa o escritor passar fome com leitores em revezamento contínuo. Confira a alegação instalando a versão atual da biblioteca num venv descartável e listando o que ela oferece (não confie na versão travada nem na memória). Meça a fome com o número real de processos e aplique a mutação (tire a proteção; o teste deve falhar).
- Prova: espera do escritor com 5 leitores, com e sem a proteção.

## Trava de arquivo em pasta comum entre usuários
- Origem: trava por vaga em `/tmp`, dividida entre o executor da CI e a sessão da pessoa.
- Sintoma: com `fs.protected_regular = 2`, abrir com `O_CREAT` um arquivo de outro usuário dá permissão negada.
- Causa e regra: para provar sem sudo, use um arquivo que outro usuário já criou. No bash, o `{fd}` de `exec {fd}<` não é close-on-exec: um filho que sobra segura o `flock` depois que o script morre. `(umask 000 && : >>f)` cria com modo 666. A mensagem de "em uso" deve ensinar a achar quem segura (`fuser -v`).
- Prova: `bash -c 'exec {fd}<f; flock -n $fd; sleep 3 & exit'` e `flock -n f -c true` no pai.

## Segredo no texto de uma exceção
- Origem: revisão de "nunca em log".
- Sintoma: `str(ValidationError)` do Pydantic traz `input_value`, inclusive de campos secretos, cortado ou inteiro.
- Causa e regra: procure `reason=str(exc)` e afins perto de log; use `hide_input_in_errors=True` ou `exc.errors(include_input=False)`. Vale para qualquer exceção que carregue o valor de entrada.
- Prova: provocar o erro com um marcador e procurar o marcador no log.

## Defesa por cabeçalho: faça a mutação mental
- Origem: revisão de política de conteúdo gerada no build e de cabeçalho de confiança entre proxy e servidor.
- Sintoma: (a) uma política só com hashes, calculada sobre toda a saída do build, libera também o `<script>` cru vindo do conteúdo; (b) mandar o cabeçalho forjado num caminho que a autenticação já protege não prova que o cabeçalho é apagado.
- Causa e regra: (a) acrescente um `<script>` a um capítulo numa cópia e veja se o build passa; recuse HTML ativo na fonte ou limite os hashes ao que o tema gera, e confira o reforço com os recursos legítimos do tema. (b) pergunte "se eu apagar a linha, o teste falha?"; se não, o teste não prova a remoção. Lista permitida de destinos confira por atributo (`href`, `src`, `srcset`, `action`, `formaction`), não por elemento.
- Prova: o build com o `<script>` plantado.

## Aprendizado de auditor sobre o estado atual do código é pista de achado aberto
- Origem: revisão de PR de regras e skills.
- Sintoma: aprendizados novos do auditor diziam "onde procurar" afirmando o estado do código de hoje; eram achados abertos do relatório local, agora num commit.
- Causa e regra: o método genérico é aprendizado; a frase sobre o estado atual é detalhe de achado. Compare cada aprendizado novo do auditor com os achados abertos e mantenha só o método até a correção entrar.
- Prova: `grep -n` das frases contra o relatório local e o código da principal.

## Acessibilidade: confira no foco real, pelo teclado
- Origem: revisões de interface com dicas e descrições.
- Sintoma: o teste conferia o atributo depois do hover e passava, mas a descrição só nascia 1 s depois do foco e um clique cancelava a dica; `locator.focus()` depois de um clique não é `:focus-visible`.
- Causa e regra: o leitor de tela anuncia a descrição no foco e não a relê. Leia a árvore de acessibilidade (protocolo do navegador) no instante do foco e depois do atraso; teste também clique e toque; em teste de foco use `keyboard.press("Tab")`. Ao revisar dois PRs que se tocam, cruze os testes de um com as regras do outro.
- Prova: descrição vazia no foco e completa 1 s depois.

## Corrida no banco provada sem `sleep`
- Origem: correção de concorrência entre duas transações.
- Sintoma: era preciso um teste que falhasse no código antigo, sem espera por tempo.
- Causa e regra: cada lado numa thread com o seu motor; um lado para logo depois de um comando escolhido (evento do driver e um `threading.Event`) segurando as travas que já tem; o teste espera o outro lado terminar ou aparecer como esperando trava na visão de atividade do banco, e só então solta o primeiro. Um teste por ordem de chegada e ordem única de travas para não criar impasse. Atrase só a vítima (depois da preparação), não tudo.
- Prova: o mesmo teste mostra as duas falhas, sem trava e com trava.
