---
name: ambiente-de-teste
description: Como o orquestrador sobe o ambiente de teste a partir da branch de um PR, confere que está saudável e entrega ao testador-usuário só a URL, uma credencial de teste e o capítulo do manual. Use antes de acionar a skill testador-usuario, ou quando o dono pedir um ambiente para usar (demonstração).
---

# Ambiente de teste

Modelo: preencha os comandos reais do projeto em `CLAUDE.md`, "Comandos" (subir, conferir, descer). O ambiente de teste é o que o testador-usuário e o dono usam, com dados de exemplo carregados. Esta skill só vale depois que o projeto tiver o que subir.

## Pré-requisitos
- O motor de contêineres ativo na sessão. Se não estiver, o ambiente sobe na CI ou num executor próprio.
- A branch do PR com a CI verde e o revisor sem bloqueante.

## Subir
1. Num worktree próprio da branch do PR.
2. Na vaga do briefing (nome de projeto, portas e sub-rede únicos por vaga; nunca a instalação do dono nem a vaga reservada ao portão), com o comando de subida do projeto e espera pela saúde de todos os serviços.
3. Se um serviço não ficar saudável: veja o estado e os logs do serviço, filtre pelo identificador de correlação. Falha do ambiente volta ao codificador como achado do PR, não ao testador.

## Conferir
O comando de conferência do projeto termina em "instalação em ordem"; entrar com o usuário de teste do papel da etapa e abrir a tela inicial sem erro no console; os dados de exemplo da etapa existem; a tela não muda de enquadramento ao abrir.

## Entregar ao testador
Só três coisas: a URL do ambiente, uma credencial de teste do papel que a etapa pede e o capítulo do manual da etapa. Nada de código nem de `docs/` além do manual. O testador parte de `git archive <head>` do PR, nunca da pasta de trabalho.

## Depois
- O relatório volta ao orquestrador e é gravado em `docs/processo/testes-de-usuario/<etapa>-<data>.md` no PR.
- Desça o ambiente e apague os volumes do SEU projeto (confira antes a lista de projetos; nunca o do dono nem o de outra vaga) e apague pelo caminho exato os arquivos de configuração e segredos de teste gerados.
- Demonstração ao dono no fim de uma fatia: o ambiente fica no ar até o "pode seguir"; o aviso fora da sessão traz a URL e o que ele precisa fazer.

## Aprendizados
Leia `aprendizados/indice.md` e registre no arquivo do assunto.
