# Ciclo de uma etapa (execução neste projeto)

Parte da skill `orquestrador`. O método geral está na skill global `orquestrador-de-agentes` §3 a §5; aqui ficam os caminhos e comandos deste projeto.

1. **Briefing** em `docs/processo/etapas/<etapa>.md` (modelo: `docs/processo/modelo-de-briefing.md`). Commitado e empurrado na branch da etapa antes de acionar o codificador. Briefing por subetapa: o Registro e as entregas de cada subetapa em arquivo ou trecho próprio, para o codificador e o revisor lerem só o seu.
2. **Codificador**, no modelo capaz, pelo papel `codificador`. Prompt: branch, briefing, a vaga, limite de linhas com a divisão prevista, "perguntas numeradas, com sugestão; adiante o que não depende de resposta", contagem de linhas antes do PR, as três provas. O briefing cita a seção "Regras de operação de todo agente" do `CLAUDE.md`, não a copia. Lance sempre pelo papel de `.claude/agents/` (`subagent_type`), nunca por bifurcação. Papéis capazes herdam o modelo do orquestrador; nos econômicos passe o modelo econômico no parâmetro `model` da chamada.
   - **Agente novo a cada tarefa e a cada rodada.** Perto de 150 mil o agente grava a passagem e termina com PARCIAL; continue com `<nome>b`, worktree novo da branch e a passagem no briefing; apague a passagem ao fim.
   - **Fim de agente:** encerre-o (`TaskStop`) e confira as sobras na pasta dele.
3. **CI** em tarefa de fundo: `~/.claude/skills/orquestrador-de-agentes/scripts/esperar-ci.sh <dono/repo> <PR>`, sempre a execução do head exato. Vermelha: vigia da CI diagnostica e um codificador NOVO corrige (até 5 ciclos).
   - **Quarentena de teste instável:** só para intermitente com causa nomeada e sem trava (trava é defeito): PR de uma linha, com dono e prazo, tira o teste dos jobs obrigatórios até o conserto.
4. **Revisor** só com a CI verde, modelo capaz, em todo PR e toda rodada, sem o contexto do codificador, parecer como comentário no PR. Bloqueante volta a um codificador; a rodada seguinte é de um revisor novo, com a revisão anterior. Leia os achados inteiros: bloqueante de arquitetura vira pergunta ao dono ou decisão registrada. **Auditor de segurança** em paralelo, já com a CI rodando, nos PRs de superfície de ataque; crítico ou alto bloqueia o merge.
   - **PR só de registro** (só docs que registram o já decidido, sem código, script, CI, contrato, requisito nem regra nova) pode dispensar o revisor: com a CI verde, grave o status como dispensado (`gh api repos/<dono/repo>/statuses/<sha> -f state=success -f context=revisor-independente -f description='Dispensado: PR só de registro'`). Na dúvida, revisor.
5. **Testador-usuário** nas etapas com interface (skill `ambiente-de-teste`); relatório em `docs/processo/testes-de-usuario/`.
6. **Portão e merge:** `portoes.md`.
7. **Próxima etapa** pela ordem do plano, dentro da dosagem. O dependente fica encadeado (correção → revisor → merge → próximo codificador).
8. **Retrospectiva** (cinco perguntas da skill global §8) antes da próxima etapa. **Lições pendentes:** esvazie `<pasta de trabalho>/aprendizados-pendentes/`: mande os arquivos ao documentador no próximo PR de docs e apague cada um pelo caminho exato depois do merge.
