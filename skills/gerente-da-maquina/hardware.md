# Hardware e sistema da estação (modelo: preencha o seu)

Mantenha aqui só o que muda decisões: o que o gerente precisa saber para não quebrar a máquina. Uma linha por item, com o porquê.

- **Máquina:** modelo, CPU, GPU, RAM, sistema e versão, sessão gráfica (X11/Wayland, `DISPLAY`).
- **Vídeo/monitores:** ligações e quirks (tela quebrada, escala, GPU primária).
- **Ventoinhas e CPU:** onde ficam os controles (hwmon, `KIT_FAN_BOOST`), se a troca de perfil de energia zera algo, quais arquivos de `intel_pstate` o seu usuário pode gravar (regra udev/tmpfiles), sensor de temperatura usado. Antes de trocar o perfil à mão no meio de uma CI, consulte o `--estado` do controle-termico: a troca conta como mudança à mão e para o ajuste.
- **Discos:** o que é sistema, o que é dados, bind mounts, o que nunca apagar (partição de boot, recuperação do fabricante).
- **VMs/serviços locais:** o que sobe com a máquina e depende de qual montagem.
- **Executores de CI** (serviços do sistema): nomes e vagas; ninguém mexe neles sem o orquestrador.
- **Acesso remoto sem login:** linger do usuário ligado (`loginctl enable-linger $USER`); a tela de login não pode suspender a máquina.
- **Ferramentas ausentes** e substitutas.
- **No WSL:** não há controle de ventoinha nem de CPU; veja `windows-wsl.md`.
