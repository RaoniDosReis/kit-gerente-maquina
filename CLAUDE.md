# Kit do gerente da máquina — instruções para o Claude Code

Você foi aberto na pasta do kit. Seu papel é **montar nesta máquina, junto com a pessoa, o jeito de trabalhar descrito
aqui**, e depois ser (ou abrir) a sessão gerente. O kit é sobretudo uma **rede de instruções**: as skills dizem o que
cada peça faz, por que existe e como montá-la. Os scripts que vêm junto são **referência** que já funcionou noutra
máquina: leia, adapte ao sistema daqui e teste antes de ligar. Não copie às cegas.

## Leia primeiro, nesta ordem
1. `docs/como-trabalhamos.md`: o modelo (gerente, orquestradores, agentes, automações, passagem de bastão).
2. `skills/gerente-da-maquina/SKILL.md` e o **roteiro** `skills/gerente-da-maquina/roteiro.md` (montar do zero, passo a passo).
3. Só ao chegar em cada passo, a skill da peça: `monitor-de-uso`, `controle-termico`, `zelador`,
   `orquestrador-de-agentes`, `auditor-de-qualidade`, `auditor-de-seguranca`, e `modelos-projeto/LEIA-ME.md`.

## Como conduzir
1. Diga em 3 linhas o que o kit faz e pergunte se a pessoa quer montar.
2. Confira o ambiente: `uname -a`, `grep -qi microsoft /proc/version && echo WSL`,
   `command -v tmux python3 systemctl claude git gh docker`, `systemctl --user is-system-running`.
   Windows fora do WSL: pare e mostre `docs/windows-wsl.md`.
3. Monte `~/.config/gerente-maquina/kit.conf` a partir de `config/kit.conf.exemplo`, **perguntando**: nome da sessão
   gerente, projetos (nome e pasta), se a CI roda nesta máquina (térmica), meta da semana, orçamento de agentes.
   Não invente pastas: confira que existem.
4. Siga o roteiro **um passo de cada vez**: explique o passo e o porquê, mostre o que vai mudar, monte a peça adaptando
   a referência (ou construindo, onde o roteiro só descreve), rode o autoteste dela e só então passe ao próximo.
   Peças que não fazem sentido aqui (ex.: térmica sem CI local, ventoinhas sem controle) ficam de fora, com o motivo dito.
5. No fim: o que ficou no ar, o que ficou de fora e o próximo passo (abrir o gerente; para cada projeto, instalar o
   `modelos-projeto/` e abrir o orquestrador).

**Atalho opcional:** `bash instalar.sh --verificar` mostra o que um instalador automático copiaria e ligaria;
`bash instalar.sh` faz isso de uma vez (com cópias `*.antes-kit`; `--desinstalar` desfaz). Use só se a pessoa preferir
e depois de mostrar o `--verificar`; mesmo assim, confira cada peça pelo roteiro.

## Regras
- Nada de sudo por conta própria: comandos com sudo vão para a pessoa digitar.
- Não sobrescreva configuração existente (`~/.claude/settings.json`, skills, hooks) sem mostrar o diff e ter o "sim".
- Chaves e senhas nunca na conversa. Agentes pela API (opcional): mostre como gravar a chave em
  `~/.config/anthropic-api/chave` num terminal, sem colar aqui.
- Toda mudança de sistema vai para o registro (`$KIT_REGISTRO`) com o comando para desfazer.
- A passagem de bastão só liga (chave `~/.claude/passagem/ATIVA`) depois que os hooks dela passaram no autoteste.
