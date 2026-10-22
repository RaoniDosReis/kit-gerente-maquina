# Como trabalhar com o dono

Parte da skill `orquestrador`, lida ao falar com o dono, ao abrir ou fechar um portão e ao decidir se uma decisão é dele.

## Perguntas e decisões
- Antecipe casos de uso e de borda que ele não mencionou. Pergunte por número e registre a resposta em `docs/processo/perguntas-abertas.md`; apresente histórias para revisão por número: o que ele não comentar está aprovado.
- **Formato:** de múltipla escolha, pela ferramenta de perguntas, com o contexto no texto e a recomendada como 1.ª opção, marcada "(Recomendado)"; nunca pergunta aberta em texto corrido; até 4 por vez, cada uma com o seu número. Ele decide escolhendo, sem digitar.
- **Explicação inteira antes da pergunta:** contexto (de onde surgiu), definições, por que fazer, consequências de não fazer, sugestão honesta e, havendo ação dele, passos concretos dizendo o que é cada campo e o que é escolha nossa. Ele é gestor, não desenvolvedor. Cite pendência pelo número e pelo título, nunca pelo apelido.
- **Questão secundária não para o trabalho:** guarda de forma (nome, redação, ordem dos docs) se contorna na hora, o trabalho segue e o contorno vira lição; só segurança, integridade, qualidade do produto e CI param o trabalho. Questão de forma que tem contorno não vai ao dono.
- **Delegação de decisões técnicas:** decisão extremamente técnica, segura e eficiente, o orquestrador aceita pelo ciclo de revisão e registra "aceito sob a delegação do dono". Só pergunte quando a decisão mudar drasticamente funcionalidade já amarrada ou for mudança significativa de arquitetura.

## Portões e ordem
- Fases têm portão de aprovação: espere o "pode seguir" antes de abrir a próxima. Fim de cada fatia: demonstração ao dono e "pode seguir" antes da seguinte.
- Comece pelo simples; a ordem de entrega está no levantamento de requisitos.
- Nada entra na principal sem verificação: o dono só decide os portões reservados (`docs/processo/ciclo-de-entrega.md`). Push na principal é recusado pela regra de proteção do GitHub e pelo guarda local.

## Avisos fora da sessão (celular)
Só em 3 casos: decisão dele pendente, portão pronto e trabalho parado que o orquestrador não destrava (sessão caída, cota, `sudo`; este só de dia). Uma linha dizendo o que ele precisa fazer. Fora deles, silêncio: resposta a aviso do monitor, fim de agente e merge, no máximo uma linha. A última mensagem de cada turno diz, em uma linha, o que se espera dele, se houver.
