# Passagem de bastão: mecanismo completo

Regra: o fim de toda sessão longa é **/clear com uma passagem escrita, nunca compactação**. A passagem é tudo o que a sessão nova vai saber, então tem de ser muito boa. Vale para o gerente e para todos os orquestradores.

## Peças
| Peça | Evento | Função |
|---|---|---|
| `hooks/compactar-na-fronteira.sh` | Stop | mede o contexto, avisa por marcos, despacha o /clear |
| `bin/limpar-sessao` | chamado em segundo plano pelo hook | espera o pane ocioso, digita /clear e a mensagem de retomada |
| `hooks/passagem-inicio.sh` | SessionStart | injeta orientações obrigatórias, lista de leitura e a passagem na sessão nova |
| `hooks/custo-de-inicio.sh` | Stop | avisa se a documentação de início custa mais de 25 mil tokens |
| `hooks/conversa-atual.sh` | SessionStart | grava o id da conversa atual de cada sessão de projeto (para os lançadores retomarem a certa) |
| chave `~/.claude/passagem/ATIVA` | — | sem ela nada age. O dono liga; emergência: `rm` e avisar |

Referência pronta no kit: `hooks/compactar-na-fronteira.sh` e `hooks/passagem-inicio.sh` (com `--autoteste`). As demais peças: construa seguindo esta descrição.

## Marcos (tokens de contexto da última resposta; kit.conf)
| Marco | Padrão | O que acontece |
|---|---|---|
| `KIT_PASSAGEM_AVISO_K` | 200000 | AVISO: não inicie trabalho novo, deixe terminar o que está em andamento, escreva a passagem |
| `KIT_PASSAGEM_CAUTION_K` | 250000 | o aviso volta; no marco do /clear ele entra à força |
| `KIT_PASSAGEM_WARNING_K` | 275000 | faça a passagem já; o aviso não manda interromper agente (decisão do orquestrador) |
| `KIT_PASSAGEM_CLEAR_K` | 300000 | /clear, com ou sem passagem, no primeiro fim de turno sem agente trabalhando |
| `KIT_PASSAGEM_TETO_K` | 330000 | com agente ainda trabalhando: a sessão para tudo e manda PushNotification ao dono; o /clear continua esperando o agente |
| `KIT_COMPACT_REDE` | 360000 | `CLAUDE_CODE_AUTO_COMPACT_WINDOW`: última rede, só pega turno longo que passe do teto antes do hook rodar |

Uma mensagem por etapa e por conversa (o hook sai com código 2 e o texto vai ao Claude). Com `stop_hook_active` o hook deixa encerrar, para não entrar em laço.

## Agente trabalhando
Subagente sem `"finished": true` no `.meta.json` e com transcrição escrita há menos de 2 h (o agente que espera um comando longo não escreve nada). Sem `.meta.json` (agente vindo de antes de um /clear): escrita há menos de 3 min. Com `finished`: nunca conta, ele acabou de entregar. **O /clear sempre espera o agente**, porque o /clear mata com SIGKILL o comando que o agente estiver rodando (o agente em si sobrevive e entrega à sessão nova).

## A passagem
Arquivo `~/.claude/passagem/<NOME>.md` (NOME = nome do gerente ou do projeto). **Última linha exatamente `PRONTA PARA O /clear`**, depois encerra o turno. Pronta = existe, é mais nova que o marco do 1º aviso (`<sid>.aviso`) e tem a marca. Conteúdo: o que foi feito; estado de cada trabalho e próximos passos imediatos; PRs abertos (número, head SHA, passo do ciclo, achados, dono); agentes ainda trabalhando (papel, worktree, branch, como reconhecer o fim); vigias e crons a rearmar, com o comando exato; bastão e orçamento; situação da main e defeitos de CI; decisões e perguntas pendentes do dono; decisões e lições fora do repositório; limpezas pendentes e promessas com prazo; seção **Armadilhas** (o que não funcionou). Até ~150 linhas, o mais importante no começo. Não copie o que já está em arquivo: aponte-o. Até ~6 mil caracteres entra inteira na sessão nova; acima disso o hook só aponta o arquivo e a sessão nova o lê com Read.

## Lista de leitura
`~/.claude/passagem/<NOME>-leitura.md`, mantida pela própria sessão, mínima e em ordem (até 2.500 caracteres). Sem ela vale a lista padrão do `passagem-inicio.sh`. Sugestão: as lições do projeto inteiras, o andamento, `gh pr list`, `git worktree list`; o resto sob demanda.

## O que o hook de início injeta (SessionStart; não age em `resume`)
Cinco passos obrigatórios: ler a passagem; ler a lista; conferir com `gh pr list` e `git worktree list` (ela pode estar velha: vale o estado real); rearmar vigias e agendamentos; escrever ao dono 3 a 5 linhas (o que entendeu, o que a conferência mostrou de diferente, o que fará). Depois a lista, os marcos e a passagem. **Tudo ou nada:** cabe, entra inteira; não cabe, só o caminho (a saída de um hook é cortada em 10 mil caracteres; o hook usa 9.600). A sessão é identificada pela **pasta da transcrição** (`kit_sessao_de_transcricao`), não pelo cwd, que muda com `cd`.

## O /clear (limpar-sessao)
Uso: `limpar-sessao <socket tmux> <pane> <NOME> <session_id> [pronta|forcado]`. Espera o pane ocioso e com a caixa de digitação vazia (texto cinza de sugestão automática não conta; "esc to interrupt" ou "… (Ns" indicam trabalho), digita `/clear`, espera 10 s e digita a mensagem de retomada ("cumpra as orientações obrigatórias de início; se a passagem listar agentes trabalhando, eles entregam aqui: espere-os e não os relance"). Desiste após 10 min sem fronteira e libera o hook para tentar no próximo fim de turno. Fora do tmux o hook não consegue digitar: manda a sessão avisar o dono para digitar /clear. Teste do `ocioso` com 5 casos (vazia, ocupada, rascunho, sugestão em cinza, sem prompt).

## Custo de início
No fim do 1º turno de uma conversa nova (`custo-de-inicio.sh`), soma CLAUDE.md e MEMORY.md, texto dos hooks de início, descrições das skills do usuário e do projeto e as leituras até o 1º texto ao dono depois de ferramenta (tokens ≈ caracteres / 2). Acima de 25 mil: avisa a sessão para enxugar (uma ideia por frase, sem repetir regra, sem histórico que já está no andamento).

## Log e estado
`$KIT_CACHE/compactar/<sid>.{etapa,aviso,limpando}`; log `$KIT_CACHE/passagem.log`.

## Limite de uso da conta
O monitor-de-uso substitui os antigos hooks de limite de uso (avisar a retomada pendente e digitar "continue" no pane após o reset).
