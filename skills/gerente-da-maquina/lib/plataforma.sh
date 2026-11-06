#!/usr/bin/env bash
# Detecção da plataforma, do Python e da GPU, para o kit.sh, o instalar.sh e os hooks.
#   source plataforma.sh   (o kit.sh já faz)        bash plataforma.sh --resumo   bash plataforma.sh --autoteste
# Funções (todas só leem; nenhuma muda o sistema):
#   kit_plataforma      linux | wsl | windows (Git Bash, MSYS, Cygwin) | macos | outro
#   kit_python          o comando do Python 3.8+: python3, python ou "py -3" (KIT_PY no kit.conf força um)
#   kit_tem_systemd     0 se o systemd do usuário responde
#   kit_tem_tmux        0 se há tmux
#   kit_gpu             nvidia | amd | intel | nenhuma (KIT_GPU no kit.conf força; padrão auto)
#   kit_rotulos_ci      rótulos sugeridos para o executor local da CI (KIT_CI_ROTULOS força)
#   kit_termica         "sim" ou o motivo de a térmica ficar de fora
#   kit_ventoinhas      "sim" ou o motivo de o controle de ventoinhas ficar de fora
#   kit_caminho_nativo  caminho como o Claude Code o vê (no Windows, C:\...; nos outros, o mesmo)
# Provas: KIT_PLATAFORMA, KIT_PROC (/proc), KIT_DRM_DIR (/sys/class/drm), KIT_TEM_SYSTEMD (0/1), KIT_NVIDIA_SMI e
# KIT_ROCM_SMI trocam a detecção.

kit_plataforma() {
  if [ -n "${KIT_PLATAFORMA:-}" ]; then echo "$KIT_PLATAFORMA"; return 0; fi
  case "$(uname -s 2>/dev/null)" in
    Linux) if grep -qi microsoft "${KIT_PROC:-/proc}/version" 2>/dev/null; then echo wsl; else echo linux; fi ;;
    MINGW*|MSYS*|CYGWIN*) echo windows ;;
    Darwin) echo macos ;;
    *) echo outro ;;
  esac
}

kit_python() {
  if [ -n "${KIT_PY:-}" ]; then echo "$KIT_PY"; return 0; fi
  local c
  # No Linux basta existir. No Windows o "python3" pode ser o atalho da loja, que não roda: confere de verdade.
  # type -P e "command": só programas do PATH, nunca a função python3 que o kit.sh define.
  if [ "$(kit_plataforma)" != windows ] && type -P python3 >/dev/null 2>&1; then echo python3; return 0; fi
  for c in python3 python "py -3"; do
    type -P "${c%% *}" >/dev/null 2>&1 || continue
    # shellcheck disable=SC2086
    command $c -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' </dev/null >/dev/null 2>&1 && { echo "$c"; return 0; }
  done
  return 1
}

kit_tem_systemd() {
  case "${KIT_TEM_SYSTEMD:-}" in 1) return 0 ;; 0) return 1 ;; esac
  command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1
}

kit_tem_tmux() { command -v tmux >/dev/null 2>&1; }

kit_gpu() {
  case "${KIT_GPU:-auto}" in nvidia|amd|intel|nenhuma) echo "$KIT_GPU"; return 0 ;; esac
  local smi="${KIT_NVIDIA_SMI:-nvidia-smi}" rocm="${KIT_ROCM_SMI:-rocm-smi}"
  if command -v "$smi" >/dev/null 2>&1 && timeout 5 "$smi" -L 2>/dev/null | grep -q .; then echo nvidia; return 0; fi
  if command -v "$rocm" >/dev/null 2>&1; then echo amd; return 0; fi
  local c v achou=""
  for c in "${KIT_DRM_DIR:-/sys/class/drm}"/card*; do
    case "${c##*/}" in *-*) continue ;; esac   # card0-HDMI-A-1 etc. são saídas de vídeo, não placas
    v=$(cat "$c/device/vendor" 2>/dev/null) || continue
    case "$v" in
      0x10de) echo nvidia; return 0 ;;          # placa NVIDIA sem nvidia-smi: tipo certo, sem leitura
      0x1002) achou=amd ;;
      0x8086) [ -n "$achou" ] || achou=intel ;;
    esac
  done
  echo "${achou:-nenhuma}"
}

kit_rotulos_ci() {
  if [ -n "${KIT_CI_ROTULOS:-}" ]; then echo "$KIT_CI_ROTULOS"; return 0; fi
  local so arq g r
  case "$(kit_plataforma)" in linux|wsl) so=Linux ;; windows) so=Windows ;; macos) so=macOS ;; *) so=Linux ;; esac
  case "$(uname -m 2>/dev/null)" in aarch64|arm64) arq=ARM64 ;; *) arq=X64 ;; esac
  r="self-hosted,$so,$arq"
  g=$(kit_gpu)
  # Só GPU que roda computação ganha rótulo; a integrada da Intel não.
  case "$g" in nvidia|amd) r="$r,gpu,gpu-$g" ;; esac
  echo "$r"
}

kit_termica() {
  [ "${KIT_TERM_ATIVA:-1}" = 0 ] && { echo "desligada no kit.conf (KIT_TERM_ATIVA=0)"; return 1; }
  case "$(kit_plataforma)" in
    windows) echo "Windows nativo: sem /sys, /proc nem systemd para ler a temperatura e limitar a CPU"; return 1 ;;
    macos|outro) echo "sistema sem /sys do Linux"; return 1 ;;
    wsl) [ "${KIT_TERM_WINDOWS:-0}" = 1 ] || { echo "WSL: o Linux não vê o sensor nem a CPU do host (modo opcional KIT_TERM_WINDOWS=1)"; return 1; } ;;
  esac
  kit_tem_systemd || { echo "sem systemd do usuário: o serviço ci-termica não sobe"; return 1; }
  echo sim
}

kit_ventoinhas() {
  [ "$(kit_plataforma)" = linux ] || { echo "só no Linux nativo (o arquivo de ventoinha fica no /sys)"; return 1; }
  [ -n "${KIT_FAN_BOOST:-}" ] || { echo "KIT_FAN_BOOST vazio no kit.conf (nenhum controle de ventoinha escolhido)"; return 1; }
  local f
  # shellcheck disable=SC2086
  for f in $KIT_FAN_BOOST; do [ -e "$f" ] && { echo sim; return 0; }; done
  echo "o glob KIT_FAN_BOOST não casa nenhum arquivo"; return 1
}

kit_caminho_nativo() {
  if [ "$(kit_plataforma)" = windows ] && command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s\n' "$1"; fi
}

kit_plataforma_resumo() {  # usado pelo instalar.sh --verificar
  local p py g t v
  p=$(kit_plataforma); py=$(kit_python) || py="FALTA (instale o Python 3.8+)"; g=$(kit_gpu)
  echo "  plataforma: $p"
  echo "  python: $py"
  if kit_tem_systemd; then echo "  systemd do usuário: sim"; else echo "  systemd do usuário: não"; fi
  if kit_tem_tmux; then echo "  tmux: sim"; else echo "  tmux: não"; fi
  echo "  GPU: $g$([ "$g" = nenhuma ] && echo " (sem leitura de GPU e sem rótulo de GPU na CI)")"
  echo "  rótulos sugeridos para o executor da CI: $(kit_rotulos_ci)"
  t=$(kit_termica); echo "  térmica: $t"
  v=$(kit_ventoinhas); echo "  ventoinhas: $v"
}

kit_fica_de_fora() {  # uma linha por peça que não funciona aqui, com o motivo
  local p t v; p=$(kit_plataforma)
  if [ "$p" = windows ]; then
    echo "serviços do usuário (systemd/): o Windows nativo não tem systemd"
    echo "automações saude-auto, parados-auto e consumo-auto e o zelador: dependem do systemd e do /proc"
    echo "controle térmico e ventoinhas: o Windows nativo não expõe /sys; use o WSL2 para isso"
  elif ! kit_tem_systemd; then
    echo "serviços do usuário (systemd/), automações e zelador: o systemd do usuário não responde (no WSL: systemd=true no /etc/wsl.conf)"
  fi
  if ! kit_tem_tmux; then
    echo "lançadores em tmux (gerente-laco, sessao-projeto, abrir-zelador) e o /clear automático: sem tmux, abra as sessões à mão e digite /clear quando o hook pedir"
  fi
  if [ "$p" != windows ]; then
    t=$(kit_termica) || echo "controle térmico (ci-termica e timers termica-*): $t"
    v=$(kit_ventoinhas) || echo "controle de ventoinhas: $v"
  fi
  [ "$(kit_gpu)" = nenhuma ] && echo "leitura de temperatura da GPU e rótulo de GPU na CI: nenhuma GPU detectada (KIT_GPU força)"
  return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    --resumo) kit_plataforma_resumo; kit_fica_de_fora | sed 's/^/  fica de fora: /'; exit 0 ;;
    --autoteste) ;;
    *) sed -n 2,14p "$0"; exit 2 ;;
  esac
  falhas=0; T=$(mktemp -d)
  ok() { [ "$2" = "$3" ] || { echo "FALHA $1: obtido '$2', esperado '$3'"; falhas=1; }; }
  # plataforma pelo /proc/version falso
  mkdir -p "$T/proc"; echo "Linux version 6 (gcc) #1 SMP" > "$T/proc/version"
  [ "$(uname -s)" = Linux ] && ok "linux" "$(KIT_PROC="$T/proc" kit_plataforma)" linux
  echo "Linux version 5.15-microsoft-standard-WSL2" > "$T/proc/version"
  [ "$(uname -s)" = Linux ] && ok "wsl" "$(KIT_PROC="$T/proc" kit_plataforma)" wsl
  mkdir -p "$T/bin"; printf '#!/bin/sh\necho MINGW64_NT-10.0\n' > "$T/bin/uname"; chmod +x "$T/bin/uname"
  ok "windows (uname do Git Bash)" "$(PATH="$T/bin:$PATH" kit_plataforma)" windows
  # GPU pelo /sys/class/drm falso, sem nvidia-smi nem rocm-smi no caminho
  semgpu() { KIT_NVIDIA_SMI="$T/vazio/nvidia-smi" KIT_ROCM_SMI="$T/vazio/rocm-smi" "$@"; }
  mkdir -p "$T/vazio" "$T/drm/card0-eDP-1/device" "$T/drm/card0/device" "$T/drm/card1/device"
  echo 0x10de > "$T/drm/card0-eDP-1/device/vendor"   # saída de vídeo: não conta
  echo 0x8086 > "$T/drm/card0/device/vendor"; echo 0x1002 > "$T/drm/card1/device/vendor"
  ok "gpu amd vence intel" "$(KIT_GPU=auto KIT_DRM_DIR="$T/drm" semgpu kit_gpu)" amd
  rm -r "$T/drm/card1"
  ok "gpu intel" "$(KIT_GPU=auto KIT_DRM_DIR="$T/drm" semgpu kit_gpu)" intel
  echo 0x10de > "$T/drm/card0/device/vendor"
  ok "gpu nvidia sem nvidia-smi" "$(KIT_GPU=auto KIT_DRM_DIR="$T/drm" semgpu kit_gpu)" nvidia
  rm -r "$T/drm/card0"
  ok "sem gpu" "$(KIT_GPU=auto KIT_DRM_DIR="$T/drm" semgpu kit_gpu)" nenhuma
  printf '#!/bin/sh\necho "GPU 0: Falsa (UUID: x)"\n' > "$T/vazio/nvidia-smi"; chmod +x "$T/vazio/nvidia-smi"
  ok "gpu nvidia pelo nvidia-smi" "$(KIT_GPU=auto KIT_DRM_DIR="$T/drm" semgpu kit_gpu)" nvidia
  rm "$T/vazio/nvidia-smi"
  ok "KIT_GPU força" "$(KIT_GPU=amd KIT_DRM_DIR="$T/drm" semgpu kit_gpu)" amd
  # rótulos da CI: sem GPU, sem rótulo de GPU
  r=$(KIT_PLATAFORMA=linux KIT_GPU=nenhuma KIT_CI_ROTULOS='' kit_rotulos_ci)
  case "$r" in self-hosted,Linux,*) ;; *) echo "FALHA rótulos base: $r"; falhas=1 ;; esac
  grep -q gpu <<<"$r" && { echo "FALHA: rótulo de GPU sem GPU ($r)"; falhas=1; }
  r=$(KIT_PLATAFORMA=linux KIT_GPU=nvidia KIT_CI_ROTULOS='' kit_rotulos_ci); grep -q ',gpu,gpu-nvidia$' <<<"$r" || { echo "FALHA rótulo nvidia: $r"; falhas=1; }
  r=$(KIT_PLATAFORMA=linux KIT_GPU=intel KIT_CI_ROTULOS='' kit_rotulos_ci); grep -q gpu <<<"$r" && { echo "FALHA: intel integrada ganhou rótulo ($r)"; falhas=1; }
  ok "KIT_CI_ROTULOS força" "$(KIT_CI_ROTULOS=a,b kit_rotulos_ci)" a,b
  # térmica e ventoinhas
  ok "térmica linux" "$(KIT_PLATAFORMA=linux KIT_TEM_SYSTEMD=1 KIT_TERM_ATIVA=1 kit_termica)" sim
  KIT_PLATAFORMA=windows kit_termica >/dev/null && { echo "FALHA: térmica no Windows nativo"; falhas=1; }
  KIT_PLATAFORMA=wsl KIT_TERM_WINDOWS=0 KIT_TEM_SYSTEMD=1 kit_termica >/dev/null && { echo "FALHA: térmica no WSL sem o modo Windows"; falhas=1; }
  ok "térmica wsl com powercfg" "$(KIT_PLATAFORMA=wsl KIT_TERM_WINDOWS=1 KIT_TEM_SYSTEMD=1 KIT_TERM_ATIVA=1 kit_termica)" sim
  KIT_PLATAFORMA=linux KIT_TEM_SYSTEMD=0 KIT_TERM_ATIVA=1 kit_termica >/dev/null && { echo "FALHA: térmica sem systemd"; falhas=1; }
  KIT_PLATAFORMA=linux KIT_TEM_SYSTEMD=1 KIT_TERM_ATIVA=0 kit_termica >/dev/null && { echo "FALHA: térmica desligada no kit.conf"; falhas=1; }
  touch "$T/fan1_boost"
  ok "ventoinhas" "$(KIT_PLATAFORMA=linux KIT_FAN_BOOST="$T/fan*_boost" kit_ventoinhas)" sim
  KIT_PLATAFORMA=linux KIT_FAN_BOOST="$T/nada*" kit_ventoinhas >/dev/null && { echo "FALHA: glob vazio de ventoinha"; falhas=1; }
  KIT_PLATAFORMA=wsl KIT_FAN_BOOST="$T/fan*_boost" kit_ventoinhas >/dev/null && { echo "FALHA: ventoinha fora do Linux nativo"; falhas=1; }
  # o que fica de fora, com o motivo
  f=$(KIT_PLATAFORMA=windows KIT_GPU=nenhuma kit_fica_de_fora)
  grep -q "systemd" <<<"$f" && grep -q "térmico" <<<"$f" && grep -q "GPU" <<<"$f" || { echo "FALHA fica de fora (windows): $f"; falhas=1; }
  f=$(KIT_PLATAFORMA=linux KIT_TEM_SYSTEMD=1 KIT_GPU=nvidia KIT_TERM_ATIVA=1 KIT_FAN_BOOST="$T/fan*_boost" PATH="$T/bin2:$PATH" kit_fica_de_fora)
  grep -qE "systemd|térmico|ventoinhas|GPU" <<<"$f" && { echo "FALHA fica de fora (linux completo): $f"; falhas=1; }
  # python: KIT_PY força; sem python3, acha o python
  ok "KIT_PY força" "$(KIT_PY='py -3' kit_python)" "py -3"
  mkdir -p "$T/py"; for c in bash sh grep sed uname cat env; do ln -s "$(command -v "$c")" "$T/py/$c"; done
  ln -s "$(command -v python3)" "$T/py/python"
  ok "python sem python3" "$(KIT_PY='' KIT_PLATAFORMA=windows PATH="$T/py" kit_python)" python
  # caminho nativo: no Windows passa pelo cygpath
  printf '#!/bin/sh\necho "C:\\\\Users\\\\x"\n' > "$T/bin/cygpath"; chmod +x "$T/bin/cygpath"
  ok "caminho nativo windows" "$(KIT_PLATAFORMA=windows PATH="$T/bin:$PATH" kit_caminho_nativo /c/Users/x)" 'C:\Users\x'
  ok "caminho nativo linux" "$(KIT_PLATAFORMA=linux kit_caminho_nativo /srv/x)" /srv/x
  rm -rf "$T"
  [ "$falhas" = 0 ] && echo "autoteste: OK" || echo "autoteste: FALHOU"
  exit "$falhas"
fi
