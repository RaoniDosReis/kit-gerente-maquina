# Configuração do kit para scripts bash: source "$HOME/.claude/skills/gerente-da-maquina/lib/kit.sh"
# Lê ~/.config/gerente-maquina/kit.conf (KEY=VALUE) e aplica os padrões. Ver config/kit.conf.exemplo.
KIT_CONF="${KIT_CONF:-$HOME/.config/gerente-maquina/kit.conf}"
# shellcheck disable=SC1090
[ -f "$KIT_CONF" ] && . "$KIT_CONF"
: "${KIT_DONO:=o dono}" "${KIT_GERENTE:=Gerente}" "${KIT_GERENTE_TMUX:=gerente}" "${KIT_GERENTE_DIR:=$HOME}"
: "${KIT_PROJETOS:=}" "${KIT_CACHE:=$HOME/.cache/gerente-maquina}" "${KIT_MODO:=auto}"
: "${KIT_REGISTRO:=$KIT_CACHE/mudancas-sistema.log}"
: "${KIT_META_SEMANA:=95}" "${KIT_ORCAMENTO_MAX:=3}" "${KIT_BASTAO_PROPORCAO:=2}"
: "${KIT_TETO_AGENTES:=5}" "${KIT_TETO_AGENTES_CARGA:=3}" "${KIT_CARGA_ALTA:=24}"
: "${KIT_TERM_ATIVA:=1}" "${KIT_CI_PADRAO:=Runner.Worker}" "${KIT_TERM_TETO_INICIAL:=60}" "${KIT_TERM_SOBE_C:=70}"
: "${KIT_TERM_DESCE_C:=80}" "${KIT_TERM_CRITICO_C:=90}" "${KIT_TERM_CALOR_C:=80}" "${KIT_FAN_BOOST:=}"
: "${KIT_PASSAGEM_AVISO_K:=200000}" "${KIT_PASSAGEM_CAUTION_K:=250000}" "${KIT_PASSAGEM_WARNING_K:=275000}"
: "${KIT_PASSAGEM_CLEAR_K:=300000}" "${KIT_PASSAGEM_TETO_K:=330000}" "${KIT_COMPACT_REDE:=360000}"
: "${KIT_AGENTE_AVISO_K:=150000}" "${KIT_AGENTE_COMPACT:=200000}" "${KIT_API_LIMITE:=2}"
export KIT_DONO KIT_GERENTE KIT_GERENTE_TMUX KIT_GERENTE_DIR KIT_PROJETOS KIT_CACHE KIT_MODO KIT_REGISTRO \
  KIT_META_SEMANA KIT_ORCAMENTO_MAX KIT_BASTAO_PROPORCAO KIT_TETO_AGENTES KIT_TETO_AGENTES_CARGA KIT_CARGA_ALTA \
  KIT_TERM_ATIVA KIT_CI_PADRAO KIT_TERM_TETO_INICIAL KIT_TERM_SOBE_C KIT_TERM_DESCE_C KIT_TERM_CRITICO_C KIT_TERM_CALOR_C KIT_FAN_BOOST \
  KIT_PASSAGEM_AVISO_K KIT_PASSAGEM_CAUTION_K KIT_PASSAGEM_WARNING_K KIT_PASSAGEM_CLEAR_K KIT_PASSAGEM_TETO_K \
  KIT_COMPACT_REDE KIT_AGENTE_AVISO_K KIT_AGENTE_COMPACT KIT_API_LIMITE
mkdir -p "$KIT_CACHE" 2>/dev/null

kit_projetos() { local p; for p in $KIT_PROJETOS; do echo "${p%%:*}"; done; }
kit__campo() {  # nome campo(2=dir,3=tmux)
  local p n d t
  for p in $KIT_PROJETOS; do
    IFS=: read -r n d t <<< "$p"
    [ "$n" = "$1" ] || continue
    [ "$2" = 2 ] && { echo "$d"; return 0; }
    echo "${t:-$(printf '%s' "$n" | tr '[:upper:]' '[:lower:]')}"; return 0
  done
  return 1
}
kit_proj_dir() { kit__campo "$1" 2; }
kit_proj_tmux() { kit__campo "$1" 3; }
kit_sessao_de_dir() {  # diretório -> nome da sessão (gerente, projeto) ou vazio
  local d n; d="$(realpath -m "$1" 2>/dev/null || echo "$1")"
  [ "$d" = "$(realpath -m "$KIT_GERENTE_DIR")" ] && { echo "$KIT_GERENTE"; return; }
  for n in $(kit_projetos); do [ "$d" = "$(realpath -m "$(kit_proj_dir "$n")")" ] && { echo "$n"; return; }; done
}
kit_registrar() { mkdir -p "$(dirname "$KIT_REGISTRO")"; echo "$(date -Iseconds) $*" >> "$KIT_REGISTRO"; }

# Acrescentadas pela parte das sessões:
kit_codifica_dir() { printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'; }  # como o Claude Code nomeia a pasta das transcrições
kit_dir_da_sessao() {  # nome da sessão (gerente ou projeto) -> pasta de trabalho
  if [ "$1" = "$KIT_GERENTE" ]; then echo "$KIT_GERENTE_DIR"; else kit_proj_dir "$1"; fi
}
kit_tmux_da_sessao() {  # nome da sessão -> nome da sessão tmux
  if [ "$1" = "$KIT_GERENTE" ]; then echo "$KIT_GERENTE_TMUX"; else kit_proj_tmux "$1"; fi
}
kit_pasta_transcricoes() {  # nome da sessão -> ~/.claude/projects/<pasta codificada>
  echo "$HOME/.claude/projects/$(kit_codifica_dir "$(kit_dir_da_sessao "$1")")"
}
kit_sessao_de_transcricao() {  # [transcrição] [cwd] -> nome da sessão; a pasta da transcrição vale mais que o cwd (o cd muda o cwd)
  local pasta n d; pasta="$(basename "$(dirname "${1:-/x/x}")")"
  for n in "$KIT_GERENTE" $(kit_projetos); do
    d="$(kit_dir_da_sessao "$n")"
    for d in "$d" "$(realpath -m "$d" 2>/dev/null)"; do
      [ "$pasta" = "$(kit_codifica_dir "$d")" ] && { echo "$n"; return; }
    done
  done
  [ -n "${2:-}" ] && kit_sessao_de_dir "$2"
  return 0
}
kit_no_wsl() { grep -qi microsoft /proc/version 2>/dev/null; }
kit_tmux_projetos() { echo "tmux -S /tmp/tmux-$(id -u)/default"; }  # as sessões dos projetos ficam no tmux padrão
kit_tmux_gerente() { echo "tmux -L $KIT_GERENTE_TMUX"; }           # a do gerente tem servidor próprio
