#!/usr/bin/env bash
# Início de sessão do projeto: liga o guarda local contra push na principal e mostra o que o
# orquestrador precisa ver antes de agir (passagens de agentes pendentes, worktrees, ferramentas).
# Não grava nada no sistema. Personalize: confira aqui a versão da linguagem do projeto.
set -u
proj="${CLAUDE_PROJECT_DIR:-$(pwd)}"
[ -d "$proj/.githooks" ] && git -C "$proj" config core.hooksPath .githooks 2>/dev/null || true
for f in git gh tmux; do command -v "$f" >/dev/null 2>&1 || echo "aviso: '$f' não encontrado; instale antes de orquestrar."; done
# nome do projeto no kit, se a pasta estiver em KIT_PROJETOS
nome=""
if [ -f "$HOME/.claude/skills/gerente-da-maquina/lib/kit.sh" ]; then
  # shellcheck disable=SC1091
  . "$HOME/.claude/skills/gerente-da-maquina/lib/kit.sh" 2>/dev/null
  nome="$(kit_sessao_de_dir "$proj" 2>/dev/null || true)"
fi
cache="${KIT_CACHE:-$HOME/.cache/gerente-maquina}/${nome:-$(basename "$proj")}"
if [ -d "$cache/passagem-agentes" ] && ls "$cache"/passagem-agentes/*.md >/dev/null 2>&1; then
  echo "Passagens de agentes pendentes (continue com agente novo e apague ao fim):"
  ls -1 "$cache"/passagem-agentes/*.md | sed 's/^/- /'
fi
if [ -d "$cache/aprendizados-pendentes" ] && ls "$cache"/aprendizados-pendentes/*.md >/dev/null 2>&1; then
  echo "Lições pendentes para o documentador: $(ls -1 "$cache"/aprendizados-pendentes/*.md | wc -l) arquivo(s) em $cache/aprendizados-pendentes/"
fi
n=$(git -C "$proj" worktree list 2>/dev/null | wc -l)
[ "$n" -gt 1 ] && echo "Worktrees ativos: $((n - 1)) (git worktree list). Confira se algum é de agente morto."
# Exemplo de checagem de versão (descomente e ajuste):
# command -v python3.12 >/dev/null 2>&1 || echo "CONFLITO DE AMBIENTE: python3.12 não encontrado. Avise o dono."
exit 0
