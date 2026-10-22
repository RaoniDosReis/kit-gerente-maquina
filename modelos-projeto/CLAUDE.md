# <NOME DO PROJETO> — <uma linha do que é>

> Modelo: preencha tudo que está entre `<...>` e apague esta nota. Mantenha este arquivo curto (alvo: menos de 3 mil tokens): ele entra em toda sessão de todo agente. Regra que só vale para um papel vai na skill do papel; truque técnico vai em `aprendizados/`.

<Dois ou três parágrafos: para quem é, o que faz, em que fase está.>

## Regras para qualquer agente que trabalhar aqui
- Idioma do projeto: português em documentação, commits e conversa; código e identificadores em `<inglês | português>`.
- Pilha: `<linguagens, frameworks, banco, contêineres>`. Versão única de `<linguagem>`: `<versão>`; confira antes de qualquer teste; mudar de versão exige decisão registrada.
- Conflito de versão ou de ambiente é grave: avise o dono na hora, com a causa e o impacto, e corrija por PR registrando a lição.
- `docs/` é a fonte de verdade: nada é implementado sem estar descrito lá antes. Toda decisão relevante vira registro em `docs/<decisões>/`; toda pergunta ao dono e a resposta ficam em `docs/processo/perguntas-abertas.md`.
- Mudança de contrato entre módulos atualiza esquema, testes e documentação no mesmo PR. Nenhum módulo acessa o interno de outro.
- Nova ideia ou requisito do dono, em qualquer fase: skill `nova-ideia`.
- **Tudo por PR:** CI verde, revisor independente (dispensado no PR só de registro), testador-usuário se há interface. O orquestrador mescla sozinho quando a CI está verde, o revisor aprovou o head e os auditores cabíveis não bloquearam. Portões do dono: `docs/processo/ciclo-de-entrega.md`.

## Lugares (preencha uma vez)
- Repositório: `<dono>/<repo>`; principal: `main`. Clone principal: `<pasta>` (fica na principal; ninguém edita nele).
- Nome do projeto no kit: `<NOME>` (igual ao de `KIT_PROJETOS`). Pasta de trabalho dos agentes: `~/.cache/gerente-maquina/<NOME>/` (`passagem-agentes/`, `aprendizados-pendentes/`, `seguranca/`, `auditoria-qualidade/`). Em todos os papéis, "pasta de trabalho" é esta.
- Worktrees: `~/worktrees/<etapa ou PR>-<papel>[-r<rodada>]`; ambientes: `~/.cache/gerente-maquina/<NOME>/venvs/<mesmo nome>`.
- Vagas (ambiente local por agente): `docs/processo/ambiente-local.md`.

## Comandos (preencha)
- Verificação local, as mesmas da CI: `<comando>` (grupos: `<...>`).
- Subir / conferir / descer o ambiente de teste: `<...>`.
- Marca de rastreabilidade dos testes: `<ex.: @RF-xxx>`.

## Papéis e modelos
- **Orquestrador** (skill `orquestrador`, modelo capaz): orquestração, arquitetura, briefings, aprovação e merge; nunca revisa nem codifica. Como fala com o dono: `orquestrador/dono.md`.
- **Modelo capaz:** todo código, de produção e de teste (skill `codificador-etapa`, com as três provas); toda revisão, inclusive a do delta (skill `revisor-pr`, sem o contexto do codificador); os auditores.
- **Modelo econômico:** documentador, mantenedor de branches, vigia da CI, testador-usuário e pesquisa.
- Cada papel tem a definição em `.claude/agents/<papel>.md` (modelo, esforço, skill pré-carregada, ferramentas negadas, `maxTurns`); o orquestrador lança pelo nome do papel.
- **Auditores:** o de segurança (skill `auditor-de-seguranca`) revê os PRs de superfície de ataque em paralelo ao revisor; o de qualidade (skill `auditor-de-qualidade`) só lê e entrega relatório, toda semana e sob demanda. Só o orquestrador altera as regras.
- **Dosagem:** quem decide quantos agentes é o gerente da máquina; o orquestrador recebe o número (`orquestrador/dosagem.md`).

## Regras de operação de todo agente
Valem em todo briefing; o briefing só cita esta seção.
- **Segredos:** nunca imprimir, colar, gravar ou commitar token, senha, chave ou o ambiente inteiro de um processo. Token vai por variável de ambiente, nunca no argv. Achou um em claro: diga só o arquivo e a linha.
- **Git:** nunca `git stash` (a pilha é a mesma em todos os worktrees); para guardar, commit WIP na própria branch ou cópia numa pasta própria; para provar contra o código antigo: `git status --short` vazio, `git show <base>:<arquivo> > <arquivo>`, rode o teste, reponha com `git checkout HEAD -- <arquivo>` e confira `git status`; nunca `git checkout -- .`. Nunca push na principal. `gh pr edit <n>` sempre com o número. Nunca `git add -A` sem olhar `git status --short`.
- **Arquivos:** limpeza só pelo caminho exato, numa variável (`rm -rf -- "$pasta"`), nunca com glob. Temporários com `mktemp -d` dentro do scratchpad ou da pasta de trabalho. No scratchpad, nomes com o prefixo da etapa ou do PR (é compartilhado entre agentes).
- **Processos:** pare só o que é seu: liste com `ps -o pid,user,args -u "$USER"`, confira `readlink /proc/<pid>/cwd` no seu worktree e mate pelo PID exato; nunca `pkill -f`, `pgrep -f` nem `ps | grep` (casam o próprio shell). Espere pelo PID ou por arquivo de fim com `scripts/esperar-ate.sh`. Não deixe vigia nem processo em segundo plano ao terminar.
- **Esperas:** em primeiro plano só em blocos de até 270 s (`scripts/esperar-ate.sh arquivo <log> <regex>` ou `pid <pid>`), repetidos, com o prazo da ferramenta de shell em 280 s; nunca `sleep` acima de 270 s; espera de mais de cerca de 50 min: entregue e termine. Por quê: parado mais de 5 min, o agente relê todo o contexto a preço cheio.
- **Ambiente:** um worktree, um ambiente de dependências e uma vaga por agente, com o nome dado no briefing; se o nome já existe, é de outro agente: use outro, nunca reaproveite nem remova; nunca symlink de ambiente; nunca editar o clone principal. Ambiente local (contêineres, portas) só na vaga do briefing, sempre com nome de projeto explícito; `down -v` só no seu projeto.
- **Máquina do dono:** é a do dia a dia dele. Nenhum agente usa `sudo` nem muda a configuração do sistema (serviço, pacote, rede, energia, certificados). Script só imprime o comando, com o de desfazer, para o dono rodar; a mudança é registrada no registro do kit (`$KIT_REGISTRO`).
- **Documentação e andamento (OBRIGATÓRIA):** todo PR atualiza os docs que deixa velhos e escreve o fragmento `docs/processo/andamento.d/<branch>.<tipo>.md` (`docs/processo/andamento.md`).
- **Commits e PR:** português; nunca nome de modelo em código, commit, PR ou docs (use "modelo capaz" e "modelo econômico"); termine commits e PRs com as linhas de atribuição que a sessão indicar. O codificador abre o PR depois da verificação local e termina sem esperar a CI.
- **Trava é defeito:** job cortado pelo prazo, teste parado pelo timeout ou execução sem saída é defeito, nunca instável. Depois de vermelho intermitente, o merge exige causa nomeada e 2 verdes seguidos (todas as tentativas lidas).
- **Principal vermelha:** só entra o PR de conserto; ninguém mais mescla; agentes seguem com commit local, sem push. Após cada merge, o orquestrador vigia a CI do commit dele até o fim.

## Como registrar regras e aprendizados
- **Um lugar só, o mais forte que couber:** verificação automática; este `CLAUDE.md`; a skill do papel; o briefing; `aprendizados/` da skill do papel; a memória do orquestrador. Método: skill global `orquestrador-de-agentes` §9.
- **Antes de inserir,** `grep -rniE '<2-3 termos>' CLAUDE.md .claude/skills docs/processo`. Igual: não crie. Parecida: funda. Contraditória: reescreva a antiga em todos os lugares; regra nova nunca fica ao lado da velha.
- **Regra:** até 3 linhas, `- **<assunto>:** <o que fazer>. <porquê>. (<quem decidiu>; substitui <regra antiga>)`.
- **Aprendizado:** cada skill tem `aprendizados/` com `indice.md` e um arquivo por assunto; uma linha por lição: `- <regra no imperativo>: <sintoma> → <causa>. (<origem>)`. Papel sem escrita no repositório grava em `<pasta de trabalho>/aprendizados-pendentes/`, e o orquestrador manda ao documentador.
- **Decisão do dono:** vai à memória na hora e ao repositório no próximo PR do documentador.

## Amarrações do projeto (regras fixas que a ideia nova e a revisão conferem)
1. <Ex.: autorização sempre no backend.>
2. <Ex.: nenhum módulo acessa o interno de outro.>
3. <Ex.: histórico nunca apagado.>
(Liste de 5 a 12; o revisor e a skill `nova-ideia` as usam como lista de conferência.)

## Segurança (usada pelo auditor de segurança)
- Superfícies de ataque: <servidor/API, autenticação, upload, proxy, CI, dependências, frontend...> com os caminhos de cada uma.
- Ambiente de teste ofensivo permitido: <perfil e vaga>. Ferramentas fixadas: <versões>. Ordem dos lotes: <...>.

## Estado atual
<Fase, onde está o estado e as pendências: `docs/processo/andamento.md`; PRs: `gh pr list`.>
