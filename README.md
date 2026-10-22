# Kit do gerente da máquina

Um jeito organizado de trabalhar com o **Claude Code** numa estação de desenvolvimento:

- uma sessão **gerente da máquina**, sempre no ar, que cuida do hardware, das automações e do consumo da conta;
- uma sessão **orquestradora por projeto**, que conduz o desenvolvimento com agentes especializados (codificador,
  revisor independente, auditores, testador, documentador...), do branch ao merge;
- **automações** que só avisam quando algo muda: saúde da máquina, controle térmico da CI local, consumo da conta,
  processos parados;
- **passagem de bastão**: sessões longas terminam com /clear e uma passagem escrita, nunca com compactação.

Tudo funciona por skills, hooks e serviços do usuário. Nada roda como root.

## Começar
1. **Linux**: clone o kit e abra o Claude Code dentro da pasta:
   ```bash
   git clone https://github.com/RaoniDosReis/kit-gerente-maquina.git ~/kit-gerente-maquina && cd ~/kit-gerente-maquina && claude
   ```
   **Windows**: siga primeiro `docs/windows-wsl.md`, porque o kit roda no WSL2.
2. O Claude Code lê o `CLAUDE.md` do kit e conduz a montagem com você, peça por peça, pelo roteiro
   `skills/gerente-da-maquina/roteiro.md`: o kit é uma rede de **instruções** (o que cada peça faz, por que, como montar);
   os scripts que vêm junto são referência, adaptados à sua máquina antes de ligar. Atalho opcional: `bash instalar.sh
   --verificar` e `bash instalar.sh` copiam e ligam tudo de uma vez.
3. Abra o gerente (o lançador `gerente`, montado no passo 3 do roteiro, ou pelo celular, na sessão com o nome configurado).
4. Para cada projeto: copie `modelos-projeto/` para a pasta do projeto, preencha o `CLAUDE.md` e abra o orquestrador
   com `sessao-projeto NOME`. Ver `modelos-projeto/LEIA-ME.md`.

## Requisitos
- Claude Code com login num plano (Pro/Max/Team) ou chave de API. O monitor de consumo foi feito para planos por assinatura.
- Linux com systemd de usuário (Ubuntu, Debian, Fedora...) ou Windows com WSL2.
- `tmux`, `python3` (3.10+), `git`; `gh` para os orquestradores; `docker` opcional.

## O que vem no kit
| Pasta | Conteúdo |
|---|---|
| `docs/` | **como-trabalhamos.md** (comece por aqui) e windows-wsl.md; o detalhe de cada peça fica na skill dela |
| `skills/gerente-da-maquina/` | papel da sessão gerente, mapa das peças, regras, procedimentos, biblioteca de configuração |
| `skills/monitor-de-uso/` | consumo da conta, orientação única, orçamento de agentes, bastão, saúde, processos parados, agentes pela API |
| `skills/controle-termico/` | perfil da CI local: teto de desempenho que sobe e desce pela temperatura, ventoinhas, relatórios |
| `skills/zelador/` | o agente que age nas escalações |
| `skills/orquestrador-de-agentes/` | método do orquestrador: papéis, paralelismo, ciclo do PR, aprendizados |
| `skills/auditor-de-qualidade/`, `skills/auditor-de-seguranca/` | métodos dos auditores |
| `hooks/` | início das sessões, passagem de bastão, teto dos agentes, limites de tamanho |
| `bin/` | `limpar-sessao` e `agente-api` prontos; os lançadores (`gerente`, `sessao-projeto`...) vêm descritos no roteiro |
| `systemd/` | serviços do usuário: gerente, saúde, parados, consumo, térmica, timers |
| `settings/` | trechos do `~/.claude/settings.json` (hooks, permissões, barra de status) que o instalador mescla |
| `modelos-projeto/` | o que vai para a pasta de cada projeto: CLAUDE.md modelo, papéis dos agentes, skills de papel, processo |
| `config/kit.conf.exemplo` | a configuração única do kit |

## Segurança
- O kit não traz chave nem segredo. A chave da API (opcional) fica em `~/.config/anthropic-api/` com modo 600; o
  `agente-api` recusa rodar com outro modo.
- `kit.conf` é lido com `source` pelos scripts: mantenha-o só seu (`chmod 600`), como o `.bashrc`.
- `settings/permissoes.json` nega ao Claude Code a leitura de chaves e credenciais comuns. As regras `Read(...)` não
  cobrem todo comando de shell: não guarde segredo fora desses caminhos.
- O monitor de consumo lê o token de login do Claude Code (`~/.claude/.credentials.json`) para consultar o uso da conta
  num endpoint da Anthropic que não é documentado e pode mudar. O token só vai, por HTTPS, a `api.anthropic.com`.
- Os hooks injetam no contexto arquivos do próprio usuário (pendências, passagens) e o hook de início do projeto. Antes
  de abrir no Claude Code um repositório de terceiros, revise a pasta `.claude/` dele.
- Nada roda como root; os comandos com sudo são mostrados para o dono digitar.

## Desinstalar
Cada mudança fica no registro (`$KIT_REGISTRO`) com o desfazer. Se usou o atalho: `bash instalar.sh --desinstalar`
para os serviços e restaura os arquivos `*.antes-kit` que o instalador guardou.

## Licença
MIT (ver `LICENSE`).
