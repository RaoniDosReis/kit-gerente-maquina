# Remote Control e passagem de bastão

- **403 no /remote-control de uma conversa retomada:** a transcrição guarda `bridge-session`; o `--resume` religa nela. Sessão remota criada antes do Trusted Devices dá 403. Regra: retomar com `--fork-session` (mantém o histórico e não copia o `bridge-session`); a nova fica gravada e as próximas retomadas normais funcionam.
- **Hook que identifica a sessão pelo `cwd` erra:** o `cd` nos comandos muda o `cwd` do hook. Regra: identificar pela pasta da transcrição (`transcript_path`), com o `cwd` de reserva.
- **/clear com agente trabalhando:** o agente sobrevive e entrega o relatório à sessão nova, mas o comando Bash que ele rodava morre com SIGKILL (exit 137). Regra: o /clear espera o agente; nunca dizer nos hooks que ele é seguro com agente trabalhando.
- **Hook de fim de turno que "espera" não acorda sozinho:** o Stop só roda no fim de um turno. Só espere por quem vai mandar notificação depois (agente sem `finished`); agente com `finished` já entregou, e a transcrição recém-escrita dele não é sinal de trabalho.
- **Conversa de projeto muda de id a cada /clear e a cada `--fork-session`:** um lançador com id fixo abre conversa antiga. Regra: o hook `conversa-atual` grava o id atual e os lançadores leem dali; sem ele, a transcrição mais recente.
- **Remote Control não ligou depois do boot:** o serviço subiu antes da rede e o `--remote-control` falhou sem tentar de novo; `After=network-online.target` não vale em serviço do usuário. Regra: o laço espera a rede (curl na API, até 2 min) antes do claude.
- **Hook SubagentStop:** dispara também depois do SubagentHandback, com `last_assistant_message` vazio; o relatório está no último `tool_use` SubagentHandback da transcrição do agente. No `claude -p` o agente não recebe SubagentHandback: teste numa sessão interativa em tmux descartável.
- **Comparar caminhos:** link simbólico de worktrees faz o git registrar o caminho real; compare sempre com `realpath` dos dois lados.
