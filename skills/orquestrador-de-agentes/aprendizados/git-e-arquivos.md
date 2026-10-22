# Git, worktrees e arquivos compartilhados entre agentes

- `git stash` é compartilhado entre worktrees: nunca use.
- Scratchpad, worktree e venv são compartilhados: nome com prefixo e papel.
- Saída de execução dentro do repositório entra num `git add -A` quando a regra do `.gitignore` sai.
- Limpeza só pelo caminho exato, nunca com glob.

## `git stash` é compartilhado entre worktrees: nunca use
- Origem: dois codificadores em paralelo.
- Sintoma: um `git stash -- <caminho>` falhou em silêncio e o `git stash pop` seguinte aplicou o stash de OUTRO worktree nos arquivos dele.
- Causa e regra: a pilha mora em `refs/stash` do repositório principal e é a mesma para todos os worktrees. Para guardar trabalho, faça commit WIP na própria branch (desfaça com `git reset --soft HEAD~1`) ou copie os arquivos para uma pasta própria. Para provar um teste contra o código antigo: `git show <base>:<arquivo> > <arquivo>`, rode, reponha com `git checkout HEAD -- <arquivo>` e confira `git status`.
- Prova: `git stash list` mostra entradas de worktrees que você não conhece.

## Scratchpad, worktree e venv são compartilhados: o nome leva a etapa e o papel
- Origem: dois codificadores e dois revisores do mesmo PR em paralelo.
- Sintoma: um apagou o `pr-body.md` do outro; dois revisores escolheram o mesmo nome de worktree e de venv, um passou a rodar testes no ambiente do outro e o `uv venv` do primeiro falhou.
- Causa e regra: no briefing, dê o nome pronto `<etapa ou PR>-<papel>[-r<rodada>]` e mande usar prefixo próprio em tudo o que é temporário (corpos de PR, logs, provas). Se `git worktree add` ou a criação do venv disser que o nome já existe, é de outro agente: use outro nome, nunca reaproveite nem remova.
- Prova: `git worktree list` com nomes repetidos.

## Saída de execução dentro do repositório entra no commit seguinte
- Origem: PR que tirou uma pasta de relatórios do `.gitignore`.
- Sintoma: o relatório local (um JSON grande) foi commitado na mesma rodada por um `git add -A`; no `range-diff` parece conteúdo de documento.
- Causa e regra: ao tirar uma regra de ignorar, confira `git ls-files` contra os nomes que o script gera, deixe um teste que falha se algum for versionado, ignore pelo nome do arquivo gerado (não pela pasta) e sugira nas mensagens uma pasta fora do repositório. Rode `git show --stat` no commit novo.
- Prova: `git show --stat HEAD`.

## Limpeza sem glob, até para arquivos de teste
- Origem: limpeza de arquivos temporários de teste.
- Sintoma: um `rm` com glob escapou antes da limpeza correta.
- Causa e regra: liste a pasta, confira os nomes e apague cada arquivo pelo caminho completo, guardado numa variável (`rm -rf -- "$pasta"`).
- Prova: o `ls` antes do `rm`.

## Atualizar o ambiente de dependências com o comando errado desinstala pacotes
- Origem: projeto com vários pacotes num workspace de dependências.
- Sintoma: `uv run` sem a opção de todos os pacotes re-sincroniza o ambiente só com o projeto raiz e desinstala os outros; depois, o verificador de tipos acusa import não encontrado.
- Causa e regra: rode os testes pelo binário do ambiente do agente, ou refaça a sincronização completa antes da verificação. Registre o comando certo no CLAUDE.md do projeto.
- Prova: `pip list` antes e depois.
