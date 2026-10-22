# Regras aprendidas em vigor (vivas)

Parte da skill `orquestrador`. Cada regra cita a lição de origem. Formato: `- **<assunto>:** <o que fazer>. <porquê>. (<quem decidiu>; substitui <regra antiga>)`. Ao acrescentar, siga a checagem da skill `orquestrador-de-agentes` §9.3; ao promover a verificação automática ou ao `CLAUDE.md`, apague daqui e deixe "(ex-regra viva <assunto>)" no destino.

- **Exceção de tamanho:** decida antes do PR, por escrito, e exija que os briefings seguintes nasçam dentro do limite; codificadores passam do limite quando o briefing não divide.
- **Docs compartilhados em PRs paralelos:** resolva mantendo os dois lados, confira a verificação de docs pelo código de saída e compare com a principal (`git diff origin/<principal>...HEAD -- <arquivo>`) para tirar linhas duplicadas.
- **Depois de compactação ou retomada:** reconfira no GitHub e no repositório (ids, head, CI, worktrees) antes de qualquer merge ou decisão.
- **CI do head exato:** filtre `gh run list --branch <b> --workflow <ci> --json databaseId,headSha --jq '.[] | select(.headSha | startswith("<sha>")) | .databaseId'`; saída vazia, repita a cada 10 s; com o id, `gh run watch <id> --exit-status`.
- **Arquivo de projeto engolido pelo `.gitignore`:** o guarda de push o barra; versione o arquivo, nunca contorne sem entender o motivo.
- **Head mudado depois do revisor:** mescle só com veredito sem bloqueante sobre o head, dado pelo revisor ou levado na atualização com a principal por merge; rebase com force-push pede nova rodada.
- **Decisão técnica do orquestrador:** datada no briefing ou na decisão registrada como "sob delegação do dono"; toda pergunta ao dono é numerada e registrada.

(Acrescente aqui as regras do projeto conforme aparecerem.)
