# Modelo de projeto: como iniciar um orquestrador

Esta pasta é o que se copia para a pasta de um projeto novo para que a sessão do Claude Code aberta ali trabalhe como orquestrador de agentes. O método geral mora na skill `orquestrador-de-agentes` (instalada em `~/.claude/skills/`); aqui ficam as peças do projeto.

## O que tem
- `CLAUDE.md`: regras para todo agente, com lugares para preencher.
- `.claude/agents/`: os 8 papéis (codificador, revisor, auditor de segurança, auditor de qualidade, documentador, mantenedor de branches, vigia da CI, testador-usuário), cada um com modelo, esforço, skill pré-carregada, ferramentas negadas e o aviso de 150 mil tokens com passagem PARCIAL.
- `.claude/skills/`: a skill do orquestrador do projeto e as skills dos papéis, cada uma com `aprendizados/` vazio.
- `.claude/hooks/session-start.sh` e `.claude/settings.json`: guarda de push, resumo de pendências no início da sessão e compactação automática.
- `.claude/rules/`: regras por caminho (um exemplo).
- `docs/processo/`: ciclo de entrega, andamento em fragmentos, ambiente local, modelo de briefing, perguntas ao dono.
- `.githooks/pre-push`, `.github/` (modelo de PR e workflow do status do revisor), `scripts/esperar-ate.sh`.

## Passo a passo
1. **Copie** (inclusive os arquivos ocultos) para a pasta do projeto: `cp -a modelos-projeto/. ~/caminho/do/projeto/` (a própria pasta do projeto já deve ser um repositório git com remoto no GitHub). Não copie este `LEIA-ME.md` se não quiser; ele não é lido por nenhum agente.
2. **Preencha o `CLAUDE.md`**: o que é o projeto, a pilha, a versão única da linguagem, os lugares (repositório, nome do projeto, clone principal), os comandos de verificação e de ambiente de teste, as amarrações do projeto e as superfícies de ataque. Mantenha curto. Troque `NOME-DO-PROJETO` nos agentes pelo nome que usar em `KIT_PROJETOS` (`grep -rl NOME-DO-PROJETO .claude`).
3. **Preencha `docs/processo/ambiente-local.md`** com as ferramentas, as vagas e os comandos da máquina.
4. **Proteja a principal no GitHub** (Settings > Rules): exigir PR, exigir as verificações da CI e o status `revisor-independente` (grave um primeiro status de teste ou rode o workflow `status-do-revisor.yml` uma vez para ele aparecer na lista), exigir a branch em dia e proibir push direto. Permita merge por squash e auto-merge.
5. **Registre o projeto em `KIT_PROJETOS`** no `~/.config/gerente-maquina/kit.conf`: `NOME:/caminho/do/projeto[:sessao-tmux]`. O primeiro da lista tem prioridade no bastão do modelo capaz.
6. **Abra o orquestrador:** `sessao-projeto NOME`. Ele abre a sessão no tmux, na pasta do projeto, com o `CLAUDE.md`, as skills e os hooks carregados, e retoma a conversa pelo id.
7. **Primeira conversa:** diga ao orquestrador o objetivo do projeto. Ele segue a skill `orquestrador-de-agentes`: pergunta o que for do dono (uma pergunta numerada, de múltipla escolha, com a explicação inteira), escreve o primeiro briefing em `docs/processo/etapas/`, pede agentes ao gerente da máquina (a linha `AGENTES` no início da sessão diz quantos; o bastão do modelo capaz vem do comando da skill `monitor-de-uso`) e conduz branch → PR → CI → revisão independente → merge.
8. **Acompanhe sem operar:** o dono decide escopo, prioridade e portões; o resto é do orquestrador. A sessão termina sempre em `/clear` com passagem escrita, nunca por compactação.

## Notas
- O hook `SubagentStop` (conferir relatório, passagem PARCIAL e processos deixados no fim de cada agente) não vem pronto neste modelo: a regra do PARCIAL vale sem ele, como instrução do papel. Acrescente-o depois, por PR, se o projeto precisar.
- Modelo econômico: o orquestrador o passa no parâmetro `model` da chamada ao lançar documentador, mantenedor, vigia e testador (o campo `model` desses arquivos fica de fora de propósito).
- Skills de papel e `CLAUDE.md` ficam no repositório (versionadas, por PR); as skills gerais (`orquestrador-de-agentes`, auditores, `monitor-de-uso`) ficam só em `~/.claude/skills/`.
