---
name: monitor-de-uso
description: Consumo da conta do Claude Code (janela de 5 h e semana do plano), orçamento de agentes capazes, bastão do modelo capaz, meta da semana, vigias por mudança de estado e agentes extras pela API. Use ao montar o monitor na máquina, ao armar vigias, ao receber um aviso e ao dosar os agentes.
---

# Monitor de uso e orçamento de agentes

Esta skill é uma **receita**: diz o que cada peça faz, por que existe, as regras e os limiares, e o que o gerente da máquina
deve fazer para montá-la do zero ou adaptá-la. Os scripts em `scripts/` são o código de **referência** que já funciona;
leia, rode e adapte à máquina (outro sistema, outra conta, outros projetos). Os nomes de projetos e do gerente vêm sempre do
`kit.conf` (`KIT_PROJETOS`, `KIT_GERENTE`); nunca escreva nomes no código.

Antes de mexer nos scripts, leia `aprendizados/` (um arquivo por assunto).

## 1. O que existe e por quê

| Peça | O que faz | Por que existe |
|---|---|---|
| **Monitor** (`monitor-uso.py`) | A cada 10 min lê o uso da conta e grava uma amostra; prevê quando o uso acaba; avisa só quando algo muda | A conta tem dois limites que param o trabalho: a **janela de 5 h** (recupera em horas) e a **semana do plano** (estourar para por dias). Sem medir, os agentes gastam às cegas |
| **Previsão** (`uso-previsao.py`) | Transforma as amostras num limite de agentes | Os orquestradores não fazem contas: recebem um número |
| **Meta da semana** (`meta_semana.py`, `balanco.py`) | Compara o ritmo da semana com a meta (padrão `KIT_META_SEMANA`=95%) | Os últimos 5% ficam para o uso pessoal do dono; o balanço diz se dá para intensificar ou frear |
| **Consumo central** (`consumo-auto.py`, serviço `consumo-auto`) | Mede o consumo por projeto, conta os agentes rodando, mantém o bastão e publica a **orientação única** | Uma fonte só de verdade para todos os projetos; os orquestradores não consultam nada |
| **Bastão** (`vez-opus.sh`) | Só uma sessão por vez roda agente capaz | O modelo capaz é o que mais consome; dividir a conta sem briga entre projetos |
| **Vigias** (`esperar-*.sh`) | Terminam com uma linha quando algo **muda** | A sessão só é acordada quando importa; vigiar custa zero de modelo |
| **Barra de status** (`settings/statusline.py`) | Mostra contexto, modelo, semana, previsão, número de agentes e a máquina | O dono vê o consumo sem perguntar |
| **Agente extra pela API** (`bin/agente-api`, `hooks/agente-api-teto.sh`) | Agentes `claude -p` pagos pela API além dos da cota | Opcional: mais trabalho em paralelo, com gasto limitado e separado da assinatura |

## 2. O que o monitor mede

- **Janela de 5 h**: o mesmo número do `/usage` do Claude Code, lido com o token que o próprio Claude Code guarda em
  `~/.claude/.credentials.json` (endereço `https://api.anthropic.com/api/oauth/usage`, cabeçalho `anthropic-beta: oauth-2025-04-20`).
  O token **não é impresso nem gravado**. Campos: `five_hour.utilization/resets_at` e `seven_day.utilization/resets_at`.
- **Semana do plano (7 dias)**: não se recupera em horas. O monitor guarda o percentual e o horário de renovação.
- Ritmo da janela: regressão linear dos últimos 40 min (4 a 5 amostras); fim previsto = agora + (100 − uso) / ritmo;
  folga = fim previsto − renovação da janela.
- Ritmo da semana: das **últimas 24 h** (inclui a noite; a média da semana inteira pesava os primeiros dias e travava os
  agentes). Com menos de 24 h de semana, a média desde o início.
- O percentual vem inteiro, então nos primeiros minutos de uma janela a previsão oscila; firma na 2ª ou 3ª consulta.
- Falhas: rede, token vencido (o Claude Code renova sozinho enquanto está em uso) ou 429. No 429 espere o tempo pedido,
  com espera crescente até 15 min; nunca reinicie o monitor em série (cada partida consulta).

### Tabela de limites (a orientação única usa o **mais restritivo** entre as duas)

| Janela de 5 h | Limite |
|---|---|
| uso ≥ 85% | 0 |
| esgota antes da renovação | 1 |
| esgota até 30 min depois | 2 |
| sobram 30 a 90 min | 3 |
| sobram mais de 90 min | 4 |
| sem ritmo ainda | 2 |

| Semana | Limite |
|---|---|
| uso ≥ meta − 5 (90% com meta 95; 98% com meta 100) | 0 |
| esgota mais de 24 h antes da renovação | 1 |
| esgota antes da renovação | 2 |
| sobram menos de 24 h | 3 |
| sobram 24 h ou mais | 4 |

## 3. A orientação única e o orçamento de agentes

O `consumo-auto` (a cada 60 s) publica `orientacao.json` e `orientacao.txt` em `$KIT_CACHE`:
conta (janela, semana, prevista), **modo**, **orçamento**, quanto cada projeto roda, o que está livre, o bastão e o consumo por projeto.

- **Modo** (faixa da previsão da semana, com histerese e 2 amostras seguidas): `acima` = só o caminho crítico;
  `meta` = ritmo normal; `abaixo` = pode intensificar. Entra em `acima` com previsão ≥ meta+5, sai com ≤ meta−5; entra
  em `abaixo` com ≤ meta−15, sai com ≥ meta−12.
- **Orçamento de agentes** = o limite do monitor (tabela acima), valendo para **todos os projetos juntos**; **0** com a meta atingida.
  Pode haver um orçamento mínimo temporário (`orcamento-extra.json`, janelas únicas ou semanais) para um trabalho combinado com o dono.
- **Corte por previsão**: se a previsão da semana passa de **110%**, reduz o orçamento pela tabela da semana; só solta com **105% ou menos**.
- **Regra de contagem**: só agentes **capazes (opus ou fable)** contam, 1 cada, de qualquer papel. Sonnet, haiku e o zelador valem **0**.
  O orquestrador fica fora da conta. O arquivo `agentes` guarda quantos estão **rodando agora**, nunca o teto, e só o `consumo-auto` o escreve.
  O modelo de cada tarefa vem da criticidade dela, nunca da pressão de uso. Sob pressão reduza o **número** de agentes, não o modelo.
- **Como o `consumo-auto` sabe quem roda**: lê os `.meta.json` dos subagentes em `~/.claude/projects/<pasta>/<sessão>/subagents/`;
  vale quem não tem `finished` e escreveu a transcrição há menos de 10 min, ou (até 3 h) quem espera uma tarefa em segundo
  plano ainda viva (um processo mantém aberto `tasks/<ID>.output`). Vigias (`esperar-*.sh`) não contam. O projeto de cada
  agente sai do nome da pasta (o caminho com `-` no lugar de símbolos; vale o prefixo mais longo entre as pastas de `KIT_PROJETOS`).
- **Consumo por projeto** (aproximado, só para repartir): soma incremental das transcrições desde o início da semana, custo =
  tokens × peso do tipo (entrada 1, escrita de cache 1,25 ou 2, leitura de cache 0,1, saída 5) × peso do modelo (capaz 5, intermediário 3, econômico 1).
- **O orquestrador de projeto não vê o monitor.** Recebe só o número: no início da sessão pelo hook `garantir-monitor.sh`
  (linha `AGENTES (<projeto>)`) e, a cada mudança, por mensagem do zelador. Até a próxima mensagem vale o último número.
- **Prioridade ao abrir uma vaga**: revisão de PR pronto (destrava o merge e custa pouco), depois o codificador do caminho
  crítico, depois correções de revisão, por fim o apoio. Decida só quando chega um aviso e quando um agente termina. Nunca
  interrompa um agente que já trabalha: só deixe de lançar o próximo.
- **Escalações ao zelador** (`consumo-escalados.log`): orçamento mudou (`AGENTES`), monitor parado após 3 tentativas do
  `garantir-monitor.sh`, consulta falhando há 1 h, meta atingida (uma vez por semana) e o **relatório semanal** (gravado em
  `relatorios/` quando a semana renova; a renovação oscila 1 s entre consultas, então arredonde à hora cheia).

## 4. O bastão do modelo capaz (`vez-opus.sh`)

Só quem tem o bastão roda agente capaz; sem ele a sessão faz CI e tarefas do modelo econômico.
- Comandos: `ver`, `pegar <projeto> "<tarefa>" [min]` (0 = pegou; 3 = ocupado, entrou na fila), `soltar`, `renovar`, `sair <projeto> [motivo]`, `unica <projeto|nenhuma>`.
- **N projetos**: o 1º de `KIT_PROJETOS` é o prioritário e recebe `KIT_BASTAO_PROPORCAO` rodadas (padrão 2) para cada 1 de um dos outros (os outros seguem pela ordem da fila). Se o prioritário não pediu a próxima rodada, o bastão vai direto ao 1º da fila.
- **Um projeto só**, ou só uma sessão de projeto no ar: o bastão fica **fixo** nela, sem fila; `pegar` sempre dá 0 e `soltar` não larga. O `consumo-auto` liga e desliga isso (`unica <projeto>` / `unica nenhuma`) olhando `~/.claude/sessions/*.json` (processo `claude` vivo; o projeto vem da pasta).
- O `consumo-auto` solta sozinho o dono sem agente capaz há **15 min** (5 min se outro espera, depois de 10 min de posse) e renova por 30 min enquanto o agente capaz trabalha. Teto de **90 min** por vez quando outro espera (`dono-teto`: solte ao terminar o agente atual).
- Estado em `$KIT_CACHE/vez-opus.json` (log `vez-opus.log`, trava `vez-opus.lock`), gravado de forma atômica sob `flock`. Sem modelo, sem rede.
- Prova: `scripts/vez-opus-teste.sh`.

## 5. Meta da semana

Padrão `KIT_META_SEMANA` (95). Troca temporária em `$KIT_CACHE/meta-semana.json`: `{"meta": 100, "ate": <época>, "por": "..."}`; volta sozinha ao padrão depois de `ate`.
Leem a meta o `balanco.py`, o `monitor-uso.py` (faixas), o `uso-previsao.py` (agentes a 0 a partir de meta−5; com meta 100, a partir de 98) e o `consumo-auto.py`.
O `balanco.py` mede o ritmo em 6 h (com 3 h a previsão pulava de 76% para 122% e trocava de faixa à toa) e sugere quantos agentes capazes manter.
Teste da previsão semanal: `python3 scripts/teste-semana-uso-previsao.py scripts/uso-previsao.py`.

## 6. Vigias por mudança de estado

A sessão arma o vigia **em segundo plano** (`Bash run_in_background`, timeout de 2 h); ele termina com uma linha quando algo muda;
ao receber, aja e rearme. Nunca use a ferramenta Monitor com `tail -F` (expira a cada 30 min) nem `tail -F | grep -m1` (só termina na escrita seguinte).
- `esperar-orientacao.sh <projeto> [--quero-vaga]`: acorda só com mudança de modo, de orçamento, bastão que veio para você / teto, e vaga que abriu (só com `--quero-vaga`). Chave vista em `orientacao-visto-<projeto>`.
- `esperar-aviso-relevante.sh`: acorda com mudança do estado do uso, da faixa da semana (<85, 85–89, ≥90) ou da faixa da previsão. O limite de agentes sozinho grava em silêncio.
- `esperar-aviso.sh`: qualquer linha nova do `alertas.log`.
- `esperar-vez-opus.sh <projeto>`: `SUA VEZ`, `TETO: solte o bastão`, `VENCIDO` (dono 30 min além da previsão, só avisa).
- Princípio: o aviso só dispara em **mudança de estado**; o que oscila (percentual, sugestão) fica gravado em silêncio, com histerese e confirmação em 2 amostras. Em orquestradores de projeto, o único vigia que importa é o do zelador/gerente; eles recebem o número por mensagem.

Avisos do monitor em `alertas.log`: `USO ADEQUADO`, `USO ULTRAPASSANDO` (qual período passa do limite), `FALHA na consulta do uso`, `Consulta do uso voltou a funcionar`, `Monitor iniciado`. Só há aviso quando o limite sobe/cai, a semana cruza 70/80/85/90%, a janela cruza 85% ou o estado de ultrapassar muda. Não há aviso periódico.

## 7. Arquivos de estado (`$KIT_CACHE`)

`amostras.jsonl` (uma amostra a cada 10 min: `ts, pct, reset, sete_dias, reset_semana`) · `estado.json` (última previsão e faixas) ·
`alertas.log` · `monitor.pid` (confira que o PID é do monitor: depois de um boot o número pode ser de outro processo) ·
`orientacao.{json,txt}` · `agentes` · `meta-semana.json` · `orcamento-extra.json` · `vez-opus.{json,log,lock}` ·
`consumo-auto-estado.json` · `consumo-auto.log` · `consumo-escalados.log` · `relatorios/` · `api-agentes/`, `api-limite`.

## 8. O que o gerente deve fazer

**Montar do zero** (cada passo funciona sozinho; use os scripts como modelo):
1. Confirme `~/.config/gerente-maquina/kit.conf` (projetos, meta, orçamento máximo, proporção) e a biblioteca `gerente-da-maquina/lib`.
2. Monitor: script que, a cada 10 min, consulta o uso, anexa a amostra (`amostras.jsonl`), roda a previsão, grava `estado.json` e escreve em `alertas.log` só na mudança. Um processo por máquina (trava por `monitor.pid`).
3. Previsão e limites pelas tabelas da seção 2; meta e faixas pela seção 5.
4. `consumo-auto`: serviço do usuário (`systemd/consumo-auto.service`, `systemctl --user enable --now consumo-auto`). Implemente a medição por projeto, a contagem de agentes capazes, o bastão e a orientação (seção 3). Prove com uma pasta de teste (`CONSUMO_DIR`, `CONSUMO_PROJETOS`, `CONSUMO_SESSOES`, `CONSUMO_GARANTIR`) e `--uma-vez`.
5. Bastão (`vez-opus.sh`) e vigias (`esperar-*.sh`): copie e rode `vez-opus-teste.sh`.
6. Hook de início de sessão `garantir-monitor.sh` (garante o monitor, e entrega a cada sessão o que é dela: o orquestrador recebe só o número de agentes; o gerente recebe o estado do monitor e o comando do vigia). Registre o hook e a barra de status em `~/.claude/settings.json` sem apagar o que existe (o `instalar.sh` da raiz do kit faz isso como atalho; preserve a barra que o usuário já tiver).
7. Barra de status: `settings/statusline.py` vai para `~/.claude/statusline.py`. Mostra `Sem` (semana), `Pr_Cons` (previsão, vermelho acima da meta), `N°Ag` (orçamento) e marca `(velho)` se a orientação tem mais de 30 min. A parte da máquina lê `$KIT_CACHE/saude.log` (coluna 11, temperatura do pacote) se existir.
8. Registre toda mudança de sistema com o desfazer (`kit_registrar`).

**Adaptar** a outro ambiente: troque a fonte da consulta de uso se o endereço mudar; ajuste os pesos de custo e os limiares de soltura do bastão ao ritmo do dono; se não houver `systemd`, rode o `consumo-auto.py` sob outro supervisor.

**Regras de conduta**: o gerente pede, não obriga, os orquestradores; só interfere em integridade, segurança ou acima do nível deles. Antes de trocar um script em uso por vigia, veja `aprendizados/vigias-por-estado.md`.

## 9. Agentes extras pela API (opcional)

Para ter mais agentes em paralelo além da cota da assinatura, o orquestrador lança trabalhadores `claude -p` pagos pela API:
`agente-api [--papel P] [--modelo M] [--projeto NOME] <nome> <worktree> <briefing.md>` (em segundo plano); `agente-api --estado` mostra rodando, limite e gasto.
- **Chave**: só em `~/.config/anthropic-api/chave` e `~/.config/anthropic-api/workspace` (modo 600). **Nunca** em conversa, no kit, em variável de ambiente da sessão ou em commit. Ela entra pelo `apiKeyHelper` do `--settings` do agente (`cat <arquivo>`), então não vai ao ambiente nem à sessão do orquestrador.
- **Limite de gasto**: configure no Console da Anthropic, no **workspace** dedicado (o ID dele vai no cabeçalho `anthropic-workspace-id`). O `agente-api` soma o `total_cost_usd` dos resultados (aproximado; o Console é a fonte oficial).
- **Limite de simultâneos**: `$KIT_CACHE/api-limite` (padrão `KIT_API_LIMITE`). O gerente ajusta com o dono. Recusa com código 3 quando cheio.
- **Só em worktree**: recusa a pasta pessoal, a do gerente e qualquer pasta de `KIT_PROJETOS`, porque ali o hook da passagem de bastão confundiria o agente com a sessão do orquestrador.
- **Mesmas regras de contexto** dos agentes da cota: o hook `hooks/agente-api-teto.sh` (PostToolUse, só pelo `--settings` do agente) avisa aos `KIT_AGENTE_AVISO_K` (150k): fechar o item, commit WIP (sem push sem verificação verde), escrever a passagem em `$KIT_CACHE/<projeto>/passagem-agentes/<nome>.md` e terminar com `PARCIAL`; último aviso 15k antes de `KIT_AGENTE_COMPACT` (200k), onde a compactação (`CLAUDE_CODE_AUTO_COMPACT_WINDOW`) é só a rede. O orquestrador continua com `<nome>b` e a passagem.
- Para montar: crie o workspace e o limite no Console, grave a chave e o ID nos dois arquivos, `chmod 600`, e rode `agente-api --estado`.

## 10. Saúde da máquina e processos parados

`saude-maquina.sh` amostra a cada 30 s e grava `$KIT_CACHE/saude.log`: carga, memória disponível, swap, pressão (PSI) de CPU/memória/disco, contêineres, jobs da CI (processos que casam `KIT_CI_PADRAO`), temperatura e frequência (`temperatura.sh`); sem docker, GPU ou cgroup a coluna fica `-`. O serviço `saude-auto` lê o log a cada 60 s e resolve sozinho: reinicia o coletor parado e o `ci-termica`; repõe as ventoinhas (`KIT_FAN_BOOST`) a 255 durante a CI; limpa disco por faixas (`docker builder prune` abaixo de 50 GB com 6 h, abaixo de 40 GB com 2 h e depois 1 h; `uv cache prune` abaixo de 15 GB; cada um só se o programa existir); grava o `teto-maquina` (`KIT_TETO_AGENTES`, ou `KIT_TETO_AGENTES_CARGA` se a carga de 1 min passou de `KIT_CARGA_ALTA` nos últimos 30 min). Só escala em `saude-escalados.log` o que não resolve: SESSÃO SEM AUTO, DOCKER FORA, TEMPERATURA CRÍTICA, MEMÓRIA BAIXA, PRESSÃO DE MEMÓRIA, CPU SATURADA, DISCO CRÍTICO, COLETOR PARADO, CI-TÉRMICA FORA, VENTOINHAS…, RELATÓRIO TÉRMICO. O serviço `parados-auto` examina a cada 5 min os processos descendentes do Claude Code: mata sozinho o inequívoco (cwd apagada, laço que casa a própria linha, ocioso há 2 h fora de repositório nos projetos de `KIT_PARADOS_MATA_OCIOSO`); protege vigias, `gh run watch`, testes em andamento, worktrees vivos e `KIT_PARADOS_EXCECOES`; o resto vai a `parados-escalados.log` como DECIDIR, INFORMAR ou FALHA. `esperar-zelador.sh` é o único vigia armado (pelo zelador); `esperar-saude.sh` e `esperar-processos-parados.sh` são ferramentas manuais que avisam só em mudança de estado. No WSL, ventoinhas, ci-termica e docker ausente são pulados sem escalar; disco e carga valem.
