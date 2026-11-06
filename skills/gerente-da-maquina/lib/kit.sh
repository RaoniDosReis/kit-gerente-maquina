# Configuração do kit para scripts bash: source "$HOME/.claude/skills/gerente-da-maquina/lib/kit.sh"
# Lê ~/.config/gerente-maquina/kit.conf (KEY=VALUE) e aplica os padrões. Ver config/kit.conf.exemplo.
KIT_CONF="${KIT_CONF:-$HOME/.config/gerente-maquina/kit.conf}"
# shellcheck disable=SC1090
[ -f "$KIT_CONF" ] && . "$KIT_CONF"
# Plataforma, Python e GPU (linux, wsl, windows com Git Bash): ver plataforma.sh.
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/plataforma.sh"
: "${KIT_PY:=$(kit_python || echo python3)}"
# Onde não há "python3" (Windows: python ou py -3), os scripts que chamam python3 usam o comando achado.
if [ "$KIT_PY" != python3 ]; then python3() { command $KIT_PY "$@"; }; export KIT_PY; export -f python3; fi
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
: "${KIT_GPU:=auto}" "${KIT_CI_ROTULOS:=}" "${KIT_TERM_WINDOWS:=0}"
: "${KIT_ZELADOR:=zelador}" "${KIT_ZELADOR_MODELO:=sonnet}" "${KIT_ZELADOR_MODO:=auto}" "${KIT_VIGIA_FORA_S:=300}"
export KIT_DONO KIT_GERENTE KIT_GERENTE_TMUX KIT_GERENTE_DIR KIT_PROJETOS KIT_CACHE KIT_MODO KIT_REGISTRO \
  KIT_META_SEMANA KIT_ORCAMENTO_MAX KIT_BASTAO_PROPORCAO KIT_TETO_AGENTES KIT_TETO_AGENTES_CARGA KIT_CARGA_ALTA \
  KIT_TERM_ATIVA KIT_CI_PADRAO KIT_TERM_TETO_INICIAL KIT_TERM_SOBE_C KIT_TERM_DESCE_C KIT_TERM_CRITICO_C KIT_TERM_CALOR_C KIT_FAN_BOOST \
  KIT_PASSAGEM_AVISO_K KIT_PASSAGEM_CAUTION_K KIT_PASSAGEM_WARNING_K KIT_PASSAGEM_CLEAR_K KIT_PASSAGEM_TETO_K \
  KIT_COMPACT_REDE KIT_AGENTE_AVISO_K KIT_AGENTE_COMPACT KIT_API_LIMITE KIT_PY KIT_GPU KIT_CI_ROTULOS KIT_TERM_WINDOWS \
  KIT_ZELADOR KIT_ZELADOR_MODELO KIT_ZELADOR_MODO KIT_VIGIA_FORA_S
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
# Como o Claude Code nomeia a pasta das transcrições. No Windows ele vê C:\Users\..., não /c/Users/...
kit_codifica_dir() { kit_caminho_nativo "$1" | sed 's/[^A-Za-z0-9]/-/g'; }
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
kit_no_wsl() { [ "$(kit_plataforma)" = wsl ]; }
kit_zelador_modo() {  # sessao (tmux próprio) | agente (em segundo plano dentro do gerente, sem tmux)
  case "$KIT_ZELADOR_MODO" in sessao|agente) echo "$KIT_ZELADOR_MODO" ;; *) kit_tem_tmux && echo sessao || echo agente ;; esac
}
kit_tmux_projetos() { echo "tmux -S /tmp/tmux-$(id -u)/default"; }  # as sessões dos projetos ficam no tmux padrão
kit_tmux_gerente() { echo "tmux -L $KIT_GERENTE_TMUX"; }           # a do gerente tem servidor próprio

if [ "${BASH_SOURCE[0]}" = "$0" ] && [ "${1:-}" = --autoteste ]; then
  falhas=0; T=$(mktemp -d)
  [ "$(KIT_PLATAFORMA=linux kit_codifica_dir /srv/u/p.x)" = -srv-u-p-x ] || { echo "FALHA codifica linux"; falhas=1; }
  mkdir -p "$T/bin"; printf '#!/bin/sh\necho "C:\\\\Users\\\\u\\\\p"\n' > "$T/bin/cygpath"; chmod +x "$T/bin/cygpath"
  r=$(KIT_PLATAFORMA=windows PATH="$T/bin:$PATH" kit_codifica_dir /c/Users/u/p)
  [ "$r" = C--Users-u-p ] || { echo "FALHA codifica windows: $r"; falhas=1; }
  r=$(KIT_ZELADOR_MODO=agente kit_zelador_modo); [ "$r" = agente ] || { echo "FALHA modo do zelador forçado: $r"; falhas=1; }
  r=$(KIT_ZELADOR_MODO=auto PATH="$T/bin" kit_zelador_modo); [ "$r" = agente ] || { echo "FALHA zelador sem tmux: $r"; falhas=1; }
  # sem python3 no caminho, o kit.sh acha o python e os scripts que chamam python3 continuam funcionando
  mkdir -p "$T/py"; for c in bash sh grep sed uname cat dirname mkdir env tr; do ln -s "$(command -v "$c")" "$T/py/$c"; done
  ln -s "$(command -v python3)" "$T/py/python"
  r=$(env -i HOME="$T" PATH="$T/py" KIT_CONF=/dev/null KIT_PLATAFORMA=windows bash -c ". '$0'; echo \$KIT_PY; python3 -c 'print(40+2)'")
  [ "$r" = "python
42" ] || { echo "FALHA python sem python3: $r"; falhas=1; }
  rm -rf "$T"
  [ "$falhas" = 0 ] && echo "autoteste: OK" || echo "autoteste: FALHOU"
  exit "$falhas"
fi
