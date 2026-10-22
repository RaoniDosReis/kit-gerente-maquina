# Ambiente local (modelo)

Preencha com o que a máquina do projeto precisa. Este documento é a fonte para o hook de início de sessão e para o `CLAUDE.md` ("Comandos").

## 1. Sistema
<Sistema operacional, versões do motor de contêineres, onde fica o clone principal, onde ficam os worktrees e os ambientes de dependências.>

## 2. Ferramentas, nesta ordem
1. `git`, `curl`, `gh` (`gh auth login`).
2. <Linguagem na versão única do projeto; como instalar e como conferir.>
3. <Gerenciador de dependências; opção que impede baixar outra versão da linguagem.>
4. <Motor de contêineres, navegador automatizado para testes de tela, outras.>
5. Claude Code, logado na mesma conta; o orquestrador abre num tmux na pasta do projeto (`sessao-projeto NOME`).
Registre aqui as particularidades das versões instaladas (por exemplo, uma opção do `gh` que a versão do sistema não tem e o comando alternativo).

## 3. Primeira vez no repositório
```bash
git clone <url> <pasta> && cd <pasta>
git config core.hooksPath .githooks        # o hook de início de sessão também faz isso
<criar o ambiente de dependências com a versão explícita>
<conferir a versão>
<verificação rápida>
```
Agentes criam ambiente próprio por worktree, fora do repositório, e rodam a verificação apontando para ele. Nunca compartilhe ambiente entre worktrees.

## 4. Vagas (ambiente local por agente)
Cada agente que sobe contêineres recebe uma vaga com projeto, portas e sub-rede únicos. Tabela:
| Vaga | Dono | Projeto de contêineres | Portas | Sub-rede |
|---|---|---|---|---|
| 1 a N | executores da CI (se a CI roda aqui) | | | |
| N+1 a M | agentes (uma por agente) | `<projeto>-verify-<vaga>` | | |
| última | portão do dono | `<projeto>-portao` | | |
Nunca toque na pilha de outra vaga nem na instalação do dono.

## 5. Verificação de que o ambiente está certo
<Comandos que devem passar numa máquina nova.>

## 6. CI local (se houver)
<Executores, quantos, o que a térmica faz. O gerente da máquina cuida do calor; o orquestrador não mexe.>

## 7. Relógio
O NTP fica ligado; testes com tempo usam relógio injetável, um só por teste.
