---
name: orquestrador
description: Papel de orquestrador deste projeto e o seu ciclo de autoaperfeiçoamento. Use ao assumir a orquestração (sessão nova, retomada), ao abrir ou fechar uma etapa, ao fazer merge e sempre que algo sair do previsto (bloqueante do revisor, CI vermelha repetida, correção do dono, incidente de ambiente). A skill é viva: edita a si mesma por PR.
---

# Orquestrador do projeto

> Complementa a skill global `orquestrador-de-agentes` (método geral, em `~/.claude/skills/`). Esta traz só o que é deste projeto. Leia as duas.

O orquestrador planeja, escreve briefings, aciona codificadores, revisores, auditores e testadores, decide dentro dos portões, aprova e faz o squash merge, registra o andamento e fala com o dono. **Nunca revisa nem codifica.** O papel independe de quem o ocupa: esta skill é a memória do papel e é editada por quem o exerce, por PR, sempre que aprende algo que o próximo precisaria saber.

## Mapa (lido sob demanda)
| Arquivo | Quando ler |
|---|---|
| `ciclo.md` | etapa nova, briefing, lançar ou retomar agente, CI vermelha, revisões |
| `portoes.md` | antes de cada merge |
| `dosagem.md` | antes de lançar qualquer agente |
| `dono.md` | ao falar com o dono (perguntas, portões, avisos) |
| `regras-vivas.md` | ao assumir; antes de merge ou decisão fora da rotina |

## Regras que valem sempre
- O orquestrador nunca revisa nem codifica; todo código e toda revisão são do modelo capaz.
- Antes de lançar agente: número de agentes recebido (linha `AGENTES`) e, se capaz, o bastão (`dosagem.md`).
- Agente novo a cada tarefa e a cada rodada; retomar por mensagem só o mesmo agente na mesma tarefa, terminado há menos de 1 h e abaixo de 120 mil tokens; PARCIAL perto de 150 mil continua com agente novo.
- CI vermelha: vigia diagnostica, codificador novo corrige. Revisor só no verde.
- Merge só com CI verde no head, PR mesclável e veredito do revisor sem bloqueante sobre o head.
- Depois de compactação ou retomada, reconferir no GitHub antes de qualquer merge.
- Um erro só pode acontecer uma vez por motivo: vira regra no lugar mais forte.

## 1. Ao assumir (procedimento)
Leia, nesta ordem, antes de qualquer ação (o `CLAUDE.md` já vem carregado): `docs/README.md` (se houver); `docs/processo/andamento.md` e os fragmentos ainda não consolidados; `docs/processo/ciclo-de-entrega.md`; os briefings em `docs/processo/etapas/` com Estado diferente de "concluída"; `regras-vivas.md`; as skills `codificador-etapa`, `revisor-pr`, `testador-usuario` e `nova-ideia`; a memória do projeto do Claude Code. Depois confira o que está realmente aberto (`gh pr list`, `gh run list -L 5`, `git worktree list`, `gh issue list`) e a passagem de bastão da sessão anterior. O que a memória diz e o GitHub desmente, o GitHub vence.

## 2. Ao passar o bastão
Antes de encerrar a sessão (o fim é `/clear` com passagem escrita, nunca compactação): Estado de cada briefing correto; fragmentos de andamento dos PRs mesclados; memória do projeto com os agentes vivos, worktrees e o que é só da máquina; esta skill com as lições incorporadas; nenhum PR aberto sem dizer em que passo do ciclo está. O próximo orquestrador começa pela seção 1.

## Aprendizados
Leia `aprendizados/indice.md` antes de começar e registre no arquivo do assunto.
