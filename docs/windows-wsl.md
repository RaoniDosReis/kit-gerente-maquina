# Windows: WSL2 (completo) ou nativo (básico)

O kit usa bash, tmux, systemd e Python. No Windows há dois caminhos, e **a escolha é de quem instala**:
- **Caminho A, WSL2 com Ubuntu (completo):** um Linux integrado ao Windows. Tudo funciona, menos o que depende do
  hardware do host (ver a tabela abaixo). O Claude Code tem suporte oficial ao WSL. Pede instalar o WSL (com
  administrador) e manter os projetos dentro do Ubuntu.
- **Caminho B, Windows nativo com Git Bash (básico):** hooks, skills, passagem de bastão e orquestração, sem instalar
  nada além do Git, do Python e do Claude Code. Sem systemd e sem tmux, as automações, o zelador em sessão própria,
  a térmica e o `/clear` automático ficam de fora. Ver a última seção.

Escolha antes de começar. O Claude Code do kit pergunta qual caminho você quer e não instala o WSL, nem leva a
instalação para lá, sem o seu "sim". Dá para começar no nativo e passar para o WSL depois.

## Caminho A: WSL2 (instalação, uma vez)
1. No PowerShell **como administrador**: `wsl --install -d Ubuntu`. Reinicie o Windows se ele pedir e crie o usuário do Ubuntu.
2. No Ubuntu, ligue o systemd (os serviços do kit dependem dele):
   ```bash
   printf '[boot]\nsystemd=true\n' | sudo tee /etc/wsl.conf
   ```
   No PowerShell: `wsl --shutdown`. Abra o Ubuntu de novo e confira: `systemctl --user is-system-running`.
3. No Ubuntu: `sudo apt update && sudo apt install -y tmux python3 git curl unzip`.
4. Instale o Claude Code **dentro do Ubuntu** (siga a instalação oficial para Linux) e faça login com `claude`.
5. Clone o kit no Ubuntu (`git clone https://github.com/RaoniDosReis/kit-gerente-maquina.git ~/kit-gerente-maquina`, ou o seu fork) ou copie o `.zip` (o disco C: aparece em `/mnt/c/`), por exemplo:
   `unzip /mnt/c/Users/<você>/Downloads/kit-gerente-maquina.zip -d ~/`
6. `cd ~/kit-gerente-maquina && claude`. O Claude Code lê o `CLAUDE.md` do kit e conduz a instalação.

**Dica:** guarde os projetos dentro do Ubuntu (`~/projetos/...`), não em `/mnt/c/`. Fica bem mais rápido.

## Manter o gerente no ar
No WSL, os serviços do usuário só rodam com o WSL aberto. Para o WSL subir sozinho no logon do Windows, crie uma tarefa
no Agendador de Tarefas do Windows:
- Gatilho: "Ao fazer logon".
- Ação: programa `wsl.exe`, argumentos `-d Ubuntu --exec /bin/true`.

Com o WSL aberto, o serviço `gerente` sobe a sessão gerente no tmux, e o Remote Control a deixa acessível pelo celular
e pelo claude.ai/code.

## O que muda no Windows
| Peça | No WSL2 |
|---|---|
| Sessões, passagem de bastão, hooks, consumo, zelador, orquestradores | funcionam igual |
| Saúde (disco, memória, carga) e processos parados | funcionam (veem o Linux do WSL) |
| Abrir terminal (`abrir-sessao-claude`, `terminal-sudo`) | usa o Windows Terminal (`wt.exe`) |
| Controle térmico da CI | o WSL não alcança a CPU nem as ventoinhas do host. Há um modo opcional (`KIT_TERM_WINDOWS=1`) que limita o desempenho máximo da CPU pelo `powercfg.exe` do Windows durante a CI e repõe ao final. Sem leitura de temperatura: o teto fica fixo |
| Docker | Docker Desktop com a integração WSL ligada |
| Executor de CI local (GitHub Actions) | instale o executor dentro do Ubuntu |

## Caminho B: Windows nativo (Git Bash), modo básico
O Claude Code para Windows usa o **Git Bash** (do Git para Windows) para o Bash e para os hooks. O kit aproveita isso.
1. Instale o Git para Windows, o Python 3.8+ (python.org; marque "Add to PATH") e o Claude Code para Windows.
2. No Git Bash: `git clone https://github.com/RaoniDosReis/kit-gerente-maquina.git ~/kit-gerente-maquina && cd ~/kit-gerente-maquina && claude`.
3. `bash instalar.sh --verificar` mostra a plataforma (`windows`), o Python achado (`python3`, `python` ou `py -3`;
   `KIT_PY` no `kit.conf` força um) e a lista **fica de fora**, com o motivo de cada peça.

| Peça | Windows nativo |
|---|---|
| Skills, `CLAUDE.md`, orquestrador e agentes | funcionam |
| Hooks (início do gerente, passagem de bastão, limite de tamanho) | funcionam no Git Bash, sem `/proc`, `systemctl` nem `pgrep` |
| Passagem de bastão | os avisos e a passagem funcionam; o `/clear` automático precisa de tmux: o hook pede ao dono para digitar `/clear` |
| Zelador | só no modo `agente` (em segundo plano no gerente), e com pouco a fazer: as automações não rodam |
| Vigia do gerente (`vigia-gerente.py`) | funciona para queda de sessão (pelos arquivos de `~/.claude/sessions`) |
| Automações (saúde, processos parados, consumo) e serviços | ficam de fora: dependem do systemd e do `/proc` |
| Controle térmico e ventoinhas | ficam de fora: o Windows não expõe `/sys`; use o WSL2 com `KIT_TERM_WINDOWS=1` |
| Lançadores em tmux (`gerente-laco`, `sessao-projeto`, `abrir-zelador`) | ficam de fora: abra as sessões à mão (`claude --name NOME --permission-mode auto`) |

Os caminhos do Git Bash (`/c/Users/...`) são convertidos para os do Windows (`C:\Users\...`) onde o Claude Code os
compara (pasta das transcrições). Em `KIT_PROJETOS`, use o formato do Git Bash.
