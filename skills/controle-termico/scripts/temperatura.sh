#!/usr/bin/env bash
# Linux nativo: temperatura e frequência pelo kernel, sem programa extra e sem root.
# Imprime "cpu_pacote cpu_max_nucleo mhz_medio gpu", com "-" no que não tiver leitura.
#  - Intel: hwmon "coretemp" ("Package id 0" e "Core N"); AMD: "k10temp" (Tctl); reserva: a zona
#    térmica "x86_pkg_temp".
#  - Frequência: média do "cpu MHz" do /proc/cpuinfo. GPU: nvidia-smi, se houver.
pkg=-; maxc=-
# WSL (Windows): o host não expõe hwmon nem zonas térmicas; sem leitura de temperatura, "-" (a frequência ainda vem).
if grep -qi microsoft /proc/version 2>/dev/null; then WSL=1; else WSL=0; fi
for nome in coretemp k10temp; do
  [ "$WSL" = 1 ] && break
  hw=$(grep -lx "$nome" /sys/class/hwmon/*/name 2>/dev/null | head -1); hw=${hw%/name}
  [ -n "$hw" ] || continue
  for l in "$hw"/temp*_label; do
    v=$(cat "${l%_label}_input" 2>/dev/null) || continue
    [[ "$v" =~ ^[0-9]+$ ]] || continue
    v=$((v / 1000))
    case "$(cat "$l" 2>/dev/null)" in
      "Package id 0"|Tctl) pkg=$v ;;
      Core*) if [ "$maxc" = - ] || [ "$v" -gt "$maxc" ]; then maxc=$v; fi ;;
    esac
  done
  break
done
if [ "$pkg" = - ] && [ "$WSL" = 0 ]; then
  for z in /sys/class/thermal/thermal_zone*; do
    if [ "$(cat "$z/type" 2>/dev/null)" = x86_pkg_temp ]; then
      v=$(cat "$z/temp" 2>/dev/null)
      [[ "$v" =~ ^[0-9]+$ ]] && pkg=$((v / 1000))
      break
    fi
  done
fi
mhz=$(awk -F: '/^cpu MHz/{s+=$2;n++} END{if(n) printf "%.0f", s/n; else print "-"}' /proc/cpuinfo)
g=$(timeout 5 nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -dc '0-9')
echo "$pkg $maxc $mhz ${g:--}"
