#!/usr/bin/env bash
# Vigia do bastão do modelo capaz (ver vez-opus.sh). Uso: esperar-vez-opus.sh <projeto>
# Roda em segundo plano na sessão e termina com UMA linha quando:
#   (a) o bastão ficar livre ou passar para esta sessão: "SUA VEZ" (se a sessão já era a dona ao iniciar, não conta);
#   (b) esta sessão é a dona e outra está na fila há VEZ_TETO_MIN (90) min ou mais: "TETO: solte o bastão";
#   (c) o dono passou da previsão de fim em VEZ_VENCIDO_MIN (30) min sem renovar: "VENCIDO: <dono> passou da
#       previsão" (só avisa, não toma o bastão).
# Olha a cada VEZ_INTERVALO_S (30) s lendo só o arquivo de estado: sem modelo, sem token.
# Variáveis (provas): VEZ_ESTADO, VEZ_TETO_MIN, VEZ_VENCIDO_MIN, VEZ_INTERVALO_S, VEZ_SESSOES.
. "$(dirname "$(readlink -f "$0")")/../../gerente-da-maquina/lib/kit.sh" 2>/dev/null \
  || . "$HOME/.claude/skills/gerente-da-maquina/lib/kit.sh"
S="$1"; export VEZ_SESSOES="${VEZ_SESSOES:-$(kit_projetos | tr '\n' ' ')}"
case " $VEZ_SESSOES " in *" $S "*) ;; *) echo "uso: $0 <projeto de KIT_PROJETOS: $VEZ_SESSOES>" >&2; exit 2 ;; esac
export VEZ_ESTADO="${VEZ_ESTADO:-$KIT_CACHE/vez-opus.json}"
export VEZ_TETO_MIN="${VEZ_TETO_MIN:-90}" VEZ_VENCIDO_MIN="${VEZ_VENCIDO_MIN:-30}" VEZ_INTERVALO_S="${VEZ_INTERVALO_S:-30}"
exec python3 -I - "$S" <<'PY'
import json, os, sys, time
s = sys.argv[1]; est = os.environ["VEZ_ESTADO"]
teto, venc, iv = (float(os.environ[k]) for k in ("VEZ_TETO_MIN", "VEZ_VENCIDO_MIN", "VEZ_INTERVALO_S"))
def ler():
    try:
        with open(est) as f: return json.load(f)
    except (FileNotFoundError, ValueError): return {}
primeiro = True; era_dono = False
while True:
    e = ler(); d = e.get("dono"); fila = e.get("fila") or []; t = time.time()
    dono = d and d.get("sessao")
    if primeiro: era_dono = (dono == s); primeiro = False
    if not dono: print("SUA VEZ: o bastão está livre"); break
    if dono == s and not era_dono: print("SUA VEZ: o bastão passou para " + s); break
    if dono != s: era_dono = False
    if dono == s and any(x["sessao"] != s and t - x["desde"] >= teto * 60 for x in fila):
        o = next(x for x in fila if x["sessao"] != s)
        print(f"TETO: solte o bastão ({o['sessao']} espera há {(t - o['desde'])/60:.0f} min; termine o agente atual e não lance outro)"); break
    if t - d["previsao_fim"] >= venc * 60:
        print(f"VENCIDO: {dono} passou da previsão de fim em {(t - d['previsao_fim'])/60:.0f} min sem renovar"); break
    time.sleep(iv)
PY
