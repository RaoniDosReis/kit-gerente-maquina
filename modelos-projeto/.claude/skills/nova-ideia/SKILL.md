---
name: nova-ideia
description: Entrada estruturada de uma nova ideia ou requisito. Use quando o dono disser "nova ideia", "novo requisito", "e se o sistema...", "pensei em...". Faz a varredura dos docs, aponta onde a ideia se encaixa, detecta conflito com requisitos, decisões e amarrações já fechadas e, aprovada, aplica em todos os documentos (e no código, quando existir) sem quebrar o que foi feito.
---

# Nova ideia

Idioma: português. Perguntas ao dono no formato de `dono.md` da skill `orquestrador`.

## 1. Capturar
Reescreva a ideia em uma frase, na voz do usuário ("Como <papel>, quero <o quê> para <motivo>"). Confirme com o dono só se a reescrita mudar o sentido. Reserve o próximo número em `docs/processo/perguntas-abertas.md` (a ideia é registrada como pergunta do dono, estado Aberta até a decisão).

## 2. Varrer
Antes de opinar, leia o que já existe. Extraia 3 a 8 palavras-chave (e sinônimos do glossário) e procure em `docs/`. Leia por inteiro os requisitos que a varredura apontou (com casos de borda), as decisões citadas e as estruturais, as tabelas de dados e módulos que a ideia toca, as lições aprendidas (algo parecido já deu errado?) e, se houver código, os módulos e contratos tocados. Varredura grande pode ir a um agente econômico, com "não edite nada".

## 3. Classificar
- **Já coberto:** existe requisito que atende. Aponte-o. Fim, salvo ajuste de texto.
- **Extensão:** cabe em requisito, decisão ou tabela existente.
- **Novo:** pede requisito novo, talvez decisão, em uma fatia definida.
- **Conflito:** contraria algo amarrado. Faça o passo 4 antes de qualquer outra coisa.

## 4. Verificar contra as amarrações
Confira a ideia, uma a uma, contra a lista "Amarrações" do `CLAUDE.md` (regras fixas do projeto: autorização, fronteiras entre módulos, pilha, imutabilidades, ordem de entrega, glossário, contrato no mesmo PR). Nomeie cada choque com a fonte. Para cada conflito, ofereça as saídas: (a) adaptar a ideia para caber na regra; (b) manter a regra e descartar a ideia; (c) mudar a regra por decisão nova que substitui a anterior, com consequências. Nunca aplique (c) sem decisão explícita do dono.

## 5. Encaixar
Em uma linha cada: módulo(s) dono(s); fatia e prioridade; impacto em dados, contratos, decisões, requisitos não funcionais e interface; ao menos três casos de borda que o dono não mencionou; custo relativo e o que ele adia.

## 6. Relatar ao dono
```
<número>: <ideia em uma frase>
Classificação: já coberto | extensão | novo | conflito
Onde encaixa: módulos, fatia, prioridade
Conflitos: nenhum | lista com fonte e saídas (a)(b)(c)
Impacto: dados, contratos, decisões, requisitos, interface
Casos de borda previstos: ...
Sugestão do orquestrador: ...
Decisões pedidas: até 4, de múltipla escolha, se houver
```
Antes da pergunta, a explicação inteira (contexto, definições, por que, consequências, sugestão honesta, passos concretos). O que o dono não comentar está aprovado.

## 7. Aplicar, só depois da decisão
Na mesma passagem, sem deixar documento para depois: a pergunta respondida com o estado final; levantamento e requisitos (com cenários e casos de borda); modelo de dados, módulos e contratos, se tocar; decisão nova ou alterada e o índice (a substituída recebe "Substituída por"); glossário; lições aprendidas se vier de erro passado; o fragmento de andamento. Com código existente, o mesmo rastreio em PR. Sempre por branch e PR, documentação inclusive.

## 8. Não fazer
Não aplicar antes da decisão quando houver conflito ou custo grande. Não criar requisito sem origem. Não ampliar uma fatia já aprovada em silêncio: diga "entra na fatia X, já aprovada". Não reaproveitar estrutura de versões anteriores do sistema.

## Aprendizados
Leia `aprendizados/indice.md` e registre no arquivo do assunto.
