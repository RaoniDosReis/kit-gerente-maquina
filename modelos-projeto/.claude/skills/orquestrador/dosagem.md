# Dosagem dos agentes

Parte da skill `orquestrador`, lida antes de lançar qualquer agente.

- **Quantos:** o orquestrador não faz conta de consumo. Vale o número da linha `AGENTES` (início da sessão) ou da última mensagem do gerente/zelador ("Agentes: a conta agora permite até N"). Unidade: capaz 1, econômico 0,5; o orquestrador fica fora. Orçamento 0: nenhum agente novo. Peça mais ou avise que a fila está parada por falta de orçamento falando com o gerente da máquina (mensagem entre sessões), não mexendo em arquivos de consumo.
- **Bastão do modelo capaz:** antes de lançar agente capaz, `vez-opus.sh pegar <NOME-DO-PROJETO> "<tarefa>" [minutos]` (skill `monitor-de-uso`). Saída 0 = pode lançar; ocupado = você entrou na fila: faça só o que for da CI ou do modelo econômico. Troca nas pausas naturais, com teto de cerca de 90 min quando o outro espera. Para a rodada seguinte, peça ainda sendo o dono.
- **Trabalho em andamento:** com 3 ou mais PRs esperando revisão, nenhum codificador novo; as revisões esvaziam a fila antes.
- **Fila de prioridade:** revisão de PR pronto > caminho crítico > correções > apoio > melhorias. Nunca interrompa agente rodando; correções do mesmo PR vão juntas.
- **Folga vai para os auditores:** na folga, o de segurança (lotes) ou o de qualidade. Se codificação ou revisão voltarem sem vaga, o auditor fecha o item em curso, grava o relatório parcial e para.
- **Auditoria de qualidade semanal:** no reinício do uso da conta (o gerente avisa o horário) lance o auditor de qualidade no modelo capaz; aplique o relatório por PR.
- **Três provas** que o codificador mostra antes de entregar; o revisor as confere.
- **Vagas:** cada agente que sobe ambiente local recebe uma vaga com nome de projeto, portas e sub-rede únicos (lista em `docs/processo/ambiente-local.md`).
