#!/usr/bin/env bash
# Amostra a saúde da máquina a cada N s (padrão 30) e grava uma linha por amostra em
# $KIT_CACHE/saude.log: data e hora (AAAA-MM-DDTHH:MM:SS), carga 1/5 min, memória disponível,
# swap usada, pressão (PSI, média de 60 s) de CPU, memória e disco, contêineres rodando e jobs da
# CI em curso (processos que casam KIT_CI_PADRAO).
# Temperatura e frequência pelo kernel (temperatura.sh: coretemp, k10temp ou x86_pkg_temp), "-" sem
# leitura.
# Colunas do fim (cgroups v2 do Linux nativo, só leitura e sem docker.sock): no Docker Engine com o
# driver systemd, cada contêiner é um system.slice/docker-<id>.scope (somados); os executores da CI
# ficam em system.slice/KIT_CI_CGROUP; as sessões do usuário (desktop, terminais,
# Claude Code), em user.slice. Núcleos = CPU usada no intervalo / duração do intervalo ("-" na
# primeira amostra); docker_psi_mem é a pressão de memória do system.slice (Docker e executores),
# média de 60 s. Só lê /proc, /sys e contagens; não imprime ambiente nem argumentos de processos.
set -u
KITSH="$(dirname "$(readlink -f "${BASH_SOURCE[0]:-$0}")")/../../gerente-da-maquina/lib/kit.sh"
# shellcheck disable=SC1090
[ -f "$KITSH" ] && . "$KITSH"
: "${KIT_CACHE:=$HOME/.cache/gerente-maquina}"
INT="${1:-30}"; LOG="${SAUDE_LOG:-$KIT_CACHE/saude.log}"
mkdir -p "$(dirname "$LOG")"
HEADER="data_hora carga1 carga5 mem_disp_GB swap_GB psi_cpu psi_mem psi_io_full conteineres jobs_ci cpu_pacote_C cpu_nucleo_max_C cpu_mhz gpu_C docker_nucleos docker_mem_GB ci_nucleos ci_mem_GB sessoes_nucleos docker_psi_mem"
# Cabeçalho novo quando as colunas mudam (o log antigo fica como está, acima dele).
[ "$(grep -aE '^(hora|data_hora) ' "$LOG" 2>/dev/null | tail -1)" = "$HEADER" ] || echo "$HEADER" >> "$LOG"
psi() { awk -v k="$2" '$1==k{for(i=2;i<=NF;i++) if($i ~ /^avg60=/){sub("avg60=","",$i); print $i}}' "/proc/pressure/$1"; }
CG=/sys/fs/cgroup
CG_SYS="$CG/system.slice"; CG_CI="${KIT_CI_CGROUP:-/nao-configurado}"; CG_SESS="$CG/user.slice"
usec() { awk '/^usage_usec/{print $2}' "$1/cpu.stat" 2>/dev/null || true; }
memgb() { awk '{printf "%.1f",$1/1073741824}' "$1/memory.current" 2>/dev/null || echo -; }
# Soma de todos os contêineres (docker-*.scope): CPU em µs e memória em GB; sem contêiner, vazio e "-".
usec_docker() { cat "$CG_SYS"/docker-*.scope/cpu.stat 2>/dev/null | awk '/^usage_usec/{s+=$2;n++} END{if(n) printf "%d",s}'; }
memgb_docker() { cat "$CG_SYS"/docker-*.scope/memory.current 2>/dev/null | awk '{s+=$1;n++} END{if(n) printf "%.1f",s/1073741824; else print "-"}'; }
nucleos() {  # nucleos <usec agora> <usec antes> <µs do intervalo>; negativo (contêiner que saiu) vira 0
  if [ -n "$1" ] && [ -n "$2" ]; then awk -v a="$1" -v b="$2" -v d="$3" 'BEGIN{x=(a-b)/d; if(x<0)x=0; printf "%.2f",x}'; else echo -; fi
}
prev_t=""; prev_d=""; prev_c=""; prev_s=""
while :; do
  read -r l1 l5 _ < /proc/loadavg
  mem=$(awk '/MemAvailable/{printf "%.1f",$2/1048576}' /proc/meminfo)
  swp=$(awk '/SwapTotal/{t=$2}/SwapFree/{f=$2}END{printf "%.1f",(t-f)/1048576}' /proc/meminfo)
  # Sem o Docker (serviço parado), "-": a mensagem de erro não pode ser contada como contêineres.
  if docker info >/dev/null 2>&1; then cont=$(docker ps -q 2>/dev/null | wc -l); else cont=-; fi
  # O pgrep -c já imprime 0 quando não acha (e sai com 1): sem "|| echo 0", que gravava "0" duas
  # vezes e quebrava a linha do log.
  jobs=$(pgrep -c "$KIT_CI_PADRAO" 2>/dev/null); jobs=${jobs:-0}
  temp=$("$(dirname "$0")/temperatura.sh" 2>/dev/null); [ -n "$temp" ] || temp="- - - -"
  now_t=$(awk '{printf "%d",$1*1000000}' /proc/uptime)
  now_d=$(usec_docker); now_c=$(usec "$CG_CI"); now_s=$(usec "$CG_SESS")
  if [ -n "$prev_t" ]; then
    dt=$((now_t - prev_t))
    dn=$(nucleos "$now_d" "$prev_d" "$dt"); cn=$(nucleos "$now_c" "$prev_c" "$dt"); sn=$(nucleos "$now_s" "$prev_s" "$dt")
  else
    dn=-; cn=-; sn=-
  fi
  prev_t=$now_t; prev_d=$now_d; prev_c=$now_c; prev_s=$now_s
  dpsi=$(awk '$1=="some"{for(i=2;i<=NF;i++) if($i ~ /^avg60=/){sub("avg60=","",$i); print $i}}' "$CG_SYS/memory.pressure" 2>/dev/null || true)
  echo "$(date +%Y-%m-%dT%H:%M:%S) $l1 $l5 $mem $swp $(psi cpu some) $(psi memory some) $(psi io full) $cont $jobs $temp $dn $(memgb_docker) $cn $(memgb "$CG_CI") $sn ${dpsi:--}" >> "$LOG"
  sleep "$INT"
done
