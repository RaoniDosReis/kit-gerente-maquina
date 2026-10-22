# Como trabalhamos

Este kit organiza o desenvolvimento com o Claude Code em três camadas, cada uma com um dono claro.

```
             DONO  (decide; fala pelo terminal, celular ou claude.ai/code)
               │
     ┌─────────┴──────────────┐
     │                        │
 GERENTE DA MÁQUINA      ORQUESTRADOR de cada projeto
 (sessão na pasta         (sessão na pasta do projeto)
  pessoal)                     │
     │                    agentes: codificador, revisor,
 automações + zelador     auditores, testador, documentador,
 (saúde, térmica,         mantenedor de branches, vigia da CI
  consumo, parados)
```

## 1. O dono
- Decide o que entra, aprova o que muda regra e responde às perguntas que só ele pode responder.
- Fala com qualquer sessão de onde estiver. O Remote Control põe cada sessão no celular e no claude.ai/code com o nome dela.
- Não precisa vigiar a máquina: as automações avisam só quando o estado muda.

## 2. O gerente da máquina (skill `gerente-da-maquina`)
Uma sessão do Claude Code aberta na pasta pessoal, sempre no ar (sobe no boot pelo serviço `gerente`). Ela:
- **cuida do hardware e dos processos**: saúde (disco, memória, carga), controle térmico da CI local e processos parados;
- **cuida do consumo da conta**: mede a janela de 5 h e a semana do plano, calcula quantos agentes capazes (opus/fable) podem rodar ao mesmo tempo e a quem cabe a vez (o *bastão*), e publica isso numa **orientação única**;
- **gerencia o zelador**, um agente econômico (sonnet) que age nas escalações das automações;
- **mantém as sessões de produção**: abre, reinicia em modo auto e retoma depois de queda ou boot;
- **registra toda mudança de sistema** com o comando para desfazer.

O gerente **não desenvolve** e **não atropela os orquestradores**: branches, PRs, CI e agentes de um projeto são do orquestrador dele. O gerente só pede. Interfere direto em três casos: integridade da máquina, segurança, ou decisão acima do nível do orquestrador (custo, credenciais, regras gerais).

## 3. O orquestrador de cada projeto (skill `orquestrador-de-agentes`)
Uma sessão por projeto, aberta na pasta dele. Conduz a produção com agentes:
- **papéis**: codificador (capaz), revisor independente (capaz), auditor de segurança e auditor de qualidade (capazes), testador de usuário, documentador, mantenedor de branches e vigia da CI (econômicos);
- **ciclo**: etapa → branch → worktree próprio → PR → CI → revisão independente → correções (agente novo a cada rodada) → merge. A `main` é protegida: só squash por PR, com a CI e o status do revisor obrigatórios;
- **paralelismo** limitado pelo número de agentes que o gerente libera e pelo bastão;
- **registra regras e aprendizados** do projeto para que a próxima sessão não repita erro.

Os orquestradores ficam **fora** de saúde, térmica e consumo. Recebem do gerente só o número de agentes que podem usar (no início da sessão e a cada mudança).

## 4. Os agentes
- Um **agente novo a cada tarefa e a cada rodada**: contexto limpo, revisão independente de verdade.
- Cada um no seu worktree, com venv e vaga de serviços próprios, para não pisar no outro.
- **Teto de contexto**: aos 150k tokens recebem aviso: fecham o item, fazem commit WIP, escrevem uma passagem em `~/.cache/gerente-maquina/<projeto>/passagem-agentes/<nome>.md` (`$KIT_CACHE/<projeto>/`) e terminam com `PARCIAL`. O orquestrador continua com `<nome>b` lendo a passagem.
- Agentes extras pagos pela API (opcional): `agente-api`, com as mesmas regras e um limite próprio. Ver `skills/monitor-de-uso/SKILL.md`.

## 5. Passagem de bastão das sessões
Sessões longas perdem qualidade e custam caro. O fim de toda sessão é **/clear com uma passagem escrita**, nunca compactação automática:

| Contexto | O que acontece |
|---|---|
| 200k | AVISO: não começar nada novo; terminar o que está em andamento; escrever a passagem |
| 250k | CAUTION: o aviso volta |
| 275k | WARNING: fazer a passagem já |
| 300k | /clear automático, com ou sem passagem, assim que nenhum agente estiver trabalhando |
| 330k | alerta: com agente ainda trabalhando, a sessão para tudo e notifica o dono (o /clear sempre espera o agente) |
| 360k | compactação automática, só como última rede |

A passagem fica em `~/.claude/passagem/<SESSÃO>.md`. A última linha é `PRONTA PARA O /clear`. A sessão nova recebe, pelo hook de início, as orientações obrigatórias e a passagem. Ver `skills/gerente-da-maquina/passagem.md`.

## 6. Consumo e orçamento
- **Meta da semana** (padrão 95% do plano): o monitor prevê o fim da semana pelo ritmo das últimas 24 h.
- **Orçamento**: número máximo de agentes capazes simultâneos para todos os projetos juntos. Sonnet, haiku e o zelador não contam.
- **Bastão**: um projeto por vez lança agente capaz quando há disputa, com rodízio a favor do projeto prioritário; com um só projeto no ar, o bastão fica com ele.
- Corte automático quando a previsão passa de 110% da meta; solta com 105%.

## 7. Regras que valem para todas as sessões
- **Modo auto sempre**: as sessões rodam com `--permission-mode auto`. A proteção do modo auto barra ações arriscadas; quando barrar, a sessão para e pergunta ao dono, nunca contorna.
- **Regras de negação globais**: nada de ssh, token do gh, leitura de credenciais, sudo, push na main, `git stash` (compartilhado entre worktrees) e `pkill -f`.
- **Comandos com sudo**: a sessão abre um terminal com as instruções e o comando; quem digita a senha é o dono.
- **Uma sessão por conversa**: nunca dois processos na mesma conversa.
- **Automação primeiro**: o que se repete vira script com autoteste; o zelador só cuida do excepcional.
- **Mudar uma automação**: editar, rodar o autoteste, provar que o teste pega o defeito (mutação), reiniciar o serviço e registrar no registro de mudanças com o desfazer.
- **Arquivos de instrução curtos**: CLAUDE.md e SKILL.md com no máximo 500 linhas.
- **Segredos nunca em conversa**: chaves ficam em arquivos com permissão 600, fora dos repositórios; o que se digita numa conversa fica no histórico.
