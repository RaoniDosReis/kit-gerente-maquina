---
paths:
  - "deploy/**"
  - "**/Dockerfile"
---

# Exemplo de regra por caminho (apague ou adapte)
Regras em `.claude/rules/` só carregam quando o agente lê ou edita um arquivo que casa com `paths`. Use para o que vale só numa área (contêineres, frontend, banco), em vez de pôr no `CLAUDE.md`, que entra em toda sessão. Exemplo:
- **Vaga:** ambiente local de contêineres só na vaga que o briefing indicar; o projeto da sua vaga tem nome explícito (`<projeto>-verify-<vaga>`); nunca toque na pilha de outra vaga nem na instalação do dono.
