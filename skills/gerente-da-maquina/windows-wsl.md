# Windows com WSL2 (Ubuntu)

O kit roda dentro do WSL2; o Windows só abre terminais e liga o WSL.

1. **Instalar:** no PowerShell do Windows, `wsl --install -d Ubuntu`, reiniciar, criar o usuário.
2. **Ligar o systemd:** no Ubuntu, `sudo tee /etc/wsl.conf <<< $'[boot]\nsystemd=true'`; no PowerShell, `wsl --shutdown` e abrir de novo. Conferir: `systemctl --user status`. Instalar `tmux` (`sudo apt install tmux`).
3. **Claude Code dentro do WSL** (não no Windows): instalar pelo método oficial no terminal do Ubuntu e entrar com `claude` na pasta pessoal.
4. **Abrir as sessões pelo Windows Terminal:** `wt.exe -w 0 nt wsl.exe -d Ubuntu -- gerente` (ou `sessao-projeto NOME`). Sem `wt.exe`, `cmd.exe /c start wsl.exe -d Ubuntu -- gerente`. É o que `abrir-sessao-claude` e `terminal-sudo` fazem quando `grep -qi microsoft /proc/version` acusa WSL; fora do WSL usam `gnome-terminal`, senão `x-terminal-emulator`, senão imprimem o comando para a pessoa rodar.
5. **Subir no logon do Windows:** o serviço do usuário (`gerente.service`) só sobe com o WSL aberto. Para abri-lo no logon, o **dono** cria, no Windows, uma tarefa agendada (o gerente não cria nada no Windows por conta própria). No PowerShell:
   `schtasks /Create /TN "WSL Gerente" /SC ONLOGON /TR "wsl.exe -d Ubuntu --exec true"`
   Para o WSL não desligar com o último terminal fechado, `wsl.exe -d Ubuntu --exec sleep infinity` na tarefa (ou `vmIdleTimeout=-1` em `[wsl2]` do `.wslconfig` do Windows). Desfazer: `schtasks /Delete /TN "WSL Gerente" /F`.
6. **Linger:** `loginctl enable-linger $USER` dentro do WSL.

## O que não vale no WSL
- **Controle térmico da CPU e ventoinhas:** o WSL não enxerga `intel_pstate`, hwmon nem `powerprofilesctl`. O `controle-termico` tem modo próprio para isso (só observa e avisa; não grava); deixe `KIT_TERM_ATIVA=0` se a CI não roda no WSL.
- **Suspensão do notebook:** quem manda é o Windows; ajuste o plano de energia lá. O `systemd-inhibit` do WSL não impede o Windows de dormir.
- **Hardware (`hardware.md`):** descreva o Windows e o notebook; o gerente não administra drivers.
- Arquivos do projeto: mantenha-os no disco do Ubuntu (`~/projetos`), não em `/mnt/c` (lento e sem permissões Linux).
