#!/usr/bin/env bash
# Linux nativo: temperatura e frequência pelo kernel, sem programa extra e sem root.
# Imprime "cpu_pacote cpu_max_nucleo mhz_medio gpu", com "-" no que não tiver leitura.
#  - Intel: hwmon "coretemp" ("Package id 0" e "Core N"); AMD: "k10temp" (Tctl); reserva: a zona
#    térmica "x86_pkg_temp".
#  - Frequência: média do "cpu MHz" do /proc/cpuinfo.
#  - GPU pelo tipo detectado (kit_gpu; KIT_GPU no kit.conf força): nvidia pelo nvidia-smi; amd pelo hwmon
#    "amdgpu" (temp1, a borda) ou, sem ele, pelo rocm-smi; intel pelo hwmon "i915"/"xe" se houver; nenhuma: "-".
#  - WSL e Windows nativo: sem hwmon do host, a temperatura da CPU fica "-".
# Provas: TEMP_SYS (/sys) e TEMP_PROC (/proc) trocam a origem. Teste: temperatura.sh --autoteste
set -u
LIB="$(dirname "$(readlink -f "${BASH_SOURCE[0]:-$0}")")/../../gerente-da-maquina/lib/plataforma.sh"
# shellcheck disable=SC1090
[ -f "$LIB" ] && . "$LIB"
command -v kit_gpu >/dev/null 2>&1 || kit_gpu() { command -v nvidia-smi >/dev/null 2>&1 && echo nvidia || echo nenhuma; }
command -v kit_plataforma >/dev/null 2>&1 || kit_plataforma() { echo linux; }
SYS="${TEMP_SYS:-/sys}"; PROC="${TEMP_PROC:-/proc}"

hwmon() { local h; h=$(grep -lx "$1" "$SYS"/class/hwmon/*/name 2>/dev/null | head -1); echo "${h%/name}"; }
milesimos() { local v; v=$(cat "$1" 2>/dev/null) || return 1; [[ "$v" =~ ^[0-9]+$ ]] || return 1; echo $((v / 1000)); }

ler_gpu() {
  local h v
  case "$(kit_gpu)" in
    nvidia) v=$(timeout 5 "${KIT_NVIDIA_SMI:-nvidia-smi}" --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -dc '0-9') ;;
    amd)
      h=$(hwmon amdgpu); [ -n "$h" ] && v=$(milesimos "$h/temp1_input")
      [ -n "${v:-}" ] || v=$(timeout 5 "${KIT_ROCM_SMI:-rocm-smi}" --showtemp 2>/dev/null | grep -m1 -oE '[0-9]+(\.[0-9]+)?c' | tr -dc '0-9.' | cut -d. -f1) ;;
    intel) for n in i915 xe; do h=$(hwmon "$n"); [ -n "$h" ] && v=$(milesimos "$h/temp1_input") && break; done ;;
  esac
  echo "${v:--}"
}

medir() {
  local pkg=- maxc=- p nome hw l v z mhz
  p=$(kit_plataforma)
  if [ "$p" = linux ]; then
    for nome in coretemp k10temp; do
      hw=$(hwmon "$nome"); [ -n "$hw" ] || continue
      for l in "$hw"/temp*_label; do
        v=$(milesimos "${l%_label}_input") || continue
        case "$(cat "$l" 2>/dev/null)" in
          "Package id 0"|Tctl) pkg=$v ;;
          Core*) if [ "$maxc" = - ] || [ "$v" -gt "$maxc" ]; then maxc=$v; fi ;;
        esac
      done
      break
    done
    if [ "$pkg" = - ]; then
      for z in "$SYS"/class/thermal/thermal_zone*; do
        [ "$(cat "$z/type" 2>/dev/null)" = x86_pkg_temp ] || continue
        v=$(milesimos "$z/temp") && pkg=$v; break
      done
    fi
  fi
  mhz=$(awk -F: '/^cpu MHz/{s+=$2;n++} END{if(n) printf "%.0f", s/n; else print "-"}' "$PROC/cpuinfo" 2>/dev/null)
  echo "$pkg $maxc ${mhz:--} $(ler_gpu)"
}

if [ "${1:-}" = --autoteste ]; then
  falhas=0; T=$(mktemp -d)
  mk() { mkdir -p "$(dirname "$1")"; echo "$2" > "$1"; }
  mk "$T/sys/class/hwmon/hwmon0/name" coretemp
  mk "$T/sys/class/hwmon/hwmon0/temp1_label" "Package id 0"; mk "$T/sys/class/hwmon/hwmon0/temp1_input" 71000
  mk "$T/sys/class/hwmon/hwmon0/temp2_label" "Core 0"; mk "$T/sys/class/hwmon/hwmon0/temp2_input" 69000
  mk "$T/sys/class/hwmon/hwmon0/temp3_label" "Core 1"; mk "$T/sys/class/hwmon/hwmon0/temp3_input" 74000
  mk "$T/sys/class/hwmon/hwmon1/name" amdgpu; mk "$T/sys/class/hwmon/hwmon1/temp1_input" 55000
  printf 'cpu MHz\t\t: 1000.0\ncpu MHz\t\t: 3000.0\n' > "$T/cpuinfo"; mkdir -p "$T/proc"; mv "$T/cpuinfo" "$T/proc/"
  mkdir -p "$T/bin"; printf '#!/bin/sh\necho 63\n' > "$T/bin/nvidia-smi"; chmod +x "$T/bin/nvidia-smi"
  roda() { env TEMP_SYS="$T/sys" TEMP_PROC="$T/proc" KIT_NVIDIA_SMI="$T/bin/nvidia-smi" KIT_ROCM_SMI="$T/nada" "$@" bash "$0"; }
  ok() { [ "$2" = "$3" ] || { echo "FALHA $1: obtido '$2', esperado '$3'"; falhas=1; }; }
  ok "linux, gpu amd" "$(roda KIT_PLATAFORMA=linux KIT_GPU=amd)" "71 74 2000 55"
  ok "linux, gpu nvidia" "$(roda KIT_PLATAFORMA=linux KIT_GPU=nvidia)" "71 74 2000 63"
  ok "linux, sem gpu" "$(roda KIT_PLATAFORMA=linux KIT_GPU=nenhuma)" "71 74 2000 -"
  ok "linux, intel sem sensor" "$(roda KIT_PLATAFORMA=linux KIT_GPU=intel)" "71 74 2000 -"
  ok "wsl: sem temperatura da CPU" "$(roda KIT_PLATAFORMA=wsl KIT_GPU=nenhuma)" "- - 2000 -"
  rm -r "$T/sys/class/hwmon/hwmon0"; mk "$T/sys/class/thermal/thermal_zone3/type" x86_pkg_temp; mk "$T/sys/class/thermal/thermal_zone3/temp" 66000
  ok "zona térmica de reserva" "$(roda KIT_PLATAFORMA=linux KIT_GPU=nenhuma)" "66 - 2000 -"
  rm -rf "$T"
  [ "$falhas" = 0 ] && echo "autoteste: OK" || echo "autoteste: FALHOU"
  exit "$falhas"
fi

medir
