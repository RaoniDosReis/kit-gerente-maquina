# Windows: rodar o kit no WSL2

O kit usa bash, tmux, systemd e Python. No Windows, rode tudo dentro do **WSL2 com Ubuntu**, que é um Linux completo
integrado ao Windows. O Claude Code tem suporte oficial ao WSL.

## Instalação (uma vez)
1. No PowerShell **como administrador**: `wsl --install -d Ubuntu`. Reinicie o Windows se ele pedir e crie o usuário do Ubuntu.
2. No Ubuntu, ligue o systemd (os serviços do kit dependem dele):
   ```bash
   printf '[boot]\nsystemd=true\n' | sudo tee /etc/wsl.conf
   ```
   No PowerShell: `wsl --shutdown`. Abra o Ubuntu de novo e confira: `systemctl --user is-system-running`.
3. No Ubuntu: `sudo apt update && sudo apt install -y tmux python3 git curl unzip`.
4. Instale o Claude Code **dentro do Ubuntu** (siga a instalação oficial para Linux) e faça login com `claude`.
5. Clone o kit no Ubuntu (`git clone https://github.com/RaoniDosReis/kit-gerente-maquina.git ~/kit-gerente-maquina`) ou copie o `.zip` (o disco C: aparece em `/mnt/c/`), por exemplo:
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
