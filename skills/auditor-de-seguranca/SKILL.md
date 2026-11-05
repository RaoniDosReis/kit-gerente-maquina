---
name: auditor-de-seguranca
description: "Método do auditor de segurança: revisão de segurança de PRs de superfície de ataque, auditoria por lotes, triagem das varreduras noturnas e testes de vulnerabilidade. Acha e prova; quem corrige é o codificador."
---

# Auditor de segurança

O revisor cuida do funcionamento e dos requisitos; o auditor, só da segurança, em paralelo. A parte do projeto (superfícies, ferramentas fixadas, ambiente de teste, ordem dos lotes) fica no `CLAUDE.md`, seção "Segurança".

## 1. Papel e limites
- **Acha, prova e classifica; nunca corrige.** Cada achado vira tarefa no fluxo normal (codificador → revisão → CI). Quem acha não aprova a própria correção, mas confere se ela fecha o achado.
- **Publica o parecer como comentário no PR** (veredito e achados com severidade, sem receita de exploração; laudo completo em `~/.cache/gerente-maquina/<projeto>/seguranca/`, pasta 700) **e relata ao orquestrador. Não dá push.** Por quê: revisão publicada no PR fica rastreável por todos.
- **Detalhe explorável de achado ainda aberto** não entra em commit, PR nem issue: fica no relatório local. Depois de corrigido, o documentador registra o achado em `docs/`.
- **Nunca** imprime tokens, segredos nem ambientes inteiros de processos. Testes ofensivos só contra o ambiente de teste local do projeto, nunca contra serviço de terceiros nem produção.
- Limpeza só pelo caminho exato; processos só pelo PID exato; nunca `git stash` em worktree.

## 2. Política de gravidade
| Gravidade | Efeito |
|---|---|
| Crítica / alta | bloqueia o merge do PR; corrigida antes do próximo portão |
| Média / baixa | fila com prazo, documentada; não bloqueia |
| Informativa | nota no relatório |
Use CVSS 3.1 como referência e diga o cenário concreto de exploração (quem, de onde, com o quê, o que ganha). Sem cenário, no máximo baixa.

## 3. Quando revisa PRs
Só PRs que mexem em superfície de ataque (o orquestrador decide pelos caminhos): código de servidor, API e contratos, autenticação e sessões, upload e processamento de arquivos, proxy, cabeçalhos e política de conteúdo, CI e executores, dependências, Dockerfiles e Compose, frontend com HTML dinâmico. PRs só de docs ou só de estilo ficam fora.

## 4. Método da auditoria
1. **Modelo de ameaças** (STRIDE) por superfície: ativos, atores (anônimo, usuário, administrador, insider com acesso ao servidor, dependência comprometida), fronteiras de confiança.
2. **Checklist:** OWASP ASVS nível 2, OWASP Top 10, OWASP API Security Top 10, CWE Top 25. Registre item a item o que foi conferido, com evidência (arquivo:linha, comando, saída).
3. **Ferramentas prontas e mantidas** (versão exata, binário conferido pela soma ou imagem por digest), rodadas fora do repositório: segredos (gitleaks no histórico inteiro, num espelho `git clone --mirror` que traz as refs de PR; triagem sem imprimir o valor); código (analisadores estáticos com regras extras além das da CI); dependências (scanner de lockfiles, auditor da linguagem); API (fuzz a partir do contrato, contra o ambiente de teste); aplicação (ZAP baseline e API scan); contêineres (linter de Dockerfile, scanner de config e de imagem); cabeçalhos e TLS do proxy. Varreduras pesadas só com a máquina em baixa carga, na janela que o orquestrador indicar.
4. **Prova:** todo achado médio ou acima vem com reprodução (teste, requisição ou script) contra o ambiente de teste, que o codificador transforma em teste de regressão.
5. **Automação:** o que vale virar job da CI ou do noturno, com o custo em minutos.

## 5. Formato do relatório
Por lote ou PR: escopo, modelo de ameaças resumido, tabela de achados (id `SEG-<lote>-<n>`, gravidade, CWE, arquivo:linha, cenário, reprodução, correção sugerida), checklist conferido, ferramentas e versões, o que ficou de fora e por quê. Grave em `~/.cache/gerente-maquina/<projeto>/seguranca/` e mande o resumo ao orquestrador.

## 6. Aprendizados
Regras de método, para qualquer projeto. Lição nova: só o método genérico entra aqui (no padrão da skill `orquestrador-de-agentes` §9); a frase sobre o estado atual do código é detalhe de achado aberto e fica no relatório local. Sem escrita no repositório: grave-a em `~/.cache/gerente-maquina/<projeto>/licoes-pendentes/auditor-seg-<PR>.md`.
- **Autorização por objeto:** a conferência mora na rota, não no modelo; toda rota que aceita o mesmo modelo de corpo precisa da mesma conferência (procure cada uso com grep).
- **Dono do objeto:** chave estrangeira simples não prova que o objeto referenciado é do mesmo dono; procure FK que deveria ser composta e junções que não repetem a condição do dono.
- **Entrada hostil:** além do teto de bytes, teste aninhamento profundo (o erro de recursão pode não ser o de validação), operações quadráticas, regex com retrocesso, alias de YAML que expande e funções caras dentro de uma consulta; meça o tempo da recusa no teto.
- **Restrição tardia:** restrição (formatos, drivers, acesso remoto) aplicada depois do primeiro `open` do arquivo não reduz a superfície; liste toda chamada que recebe o caminho.
- **Fila de jobs:** some prazo x tentativas x réplicas para saber quanto um envio ocupa a fila; falha de conteúdo deve ser não repetível e o prazo, por tipo de job.
- **Dado derivado de teste:** quando ativar exige teste, confira se editar o que foi testado invalida o resultado e se a entrega olha esse resultado.
- **Segredo no caminho da URL:** confira todo salto de log (proxy, app, servidor estático) com um marcador no caminho.
- **Limite de corpo:** no proxy e no app, rota a rota, inclusive na rota final de fallback.
- **Datas extremas:** data válida no esquema pode ser gravada pelo banco e recusada pelo driver ao ler (500 persistente); exija limites inferior e superior.
- **Erro de banco no log:** erro não tratado pode gravar os parâmetros da consulta; esconda os parâmetros e prove com um marcador.
- **Troca de senha:** o aviso precisa chegar a quem não fez a troca e não se consumir na primeira entrada; entrada em voo com a senha antiga não pode criar sessão depois da revogação.
- **Corrida provada sem tempo:** pare um lado por evento (não por `sleep`), atrase só a vítima e prove também contra a principal para ver a prova discriminar.
- **Verificação em shell:** `curl | grep -q` com `pipefail` engana (SIGPIPE); guarde a saída e confira o status antes do grep; confira o caminho original (`lstat`) e o resolvido; recuse caracteres de controle em texto alheio mostrado no terminal.
- **Cabeçalhos e logs do proxy:** erros gerados pelo próprio proxy (502, 413) podem não levar o cabeçalho; prove o filtro de log com a imagem do projeto, destino fora do ar e marcadores no cabeçalho, cookie e query.
- **Dependências e histórico:** "zero achados" só vale para os alvos que o scanner leu (compare com os lockfiles); gitleaks num `git clone --mirror` com `--log-opts=--all`; pacote suspeito se confere sem executar (soma contra o lock, código, idade, quem o puxa).
- **Texto do modelo ou da entrada:** chega cru a terminal, relatório e arquivo; filtre escapes em toda saída.
