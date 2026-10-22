#!/usr/bin/env bash
# Hook SessionStart geral: garante o monitor de uso rodando (um só por máquina) e diz a cada sessão o que é dela.
# As automações que servem a todos os projetos são do zelador e do gerente. A sessão de projeto só recebe o número de
# agentes que pode usar, aqui no início e, quando ele muda, por mensagem do zelador (escalação AGENTES do
# consumo-auto). O gerente recebe o estado do monitor e o comando do vigia da orientação.
. "$(dirname "$(readlink -f "$0")")/../../gerente-da-maquina/lib/kit.sh" 2>/dev/null \
  || . "$HOME/.claude/skills/gerente-da-maquina/lib/kit.sh"
dir="${CONSUMO_DIR:-$KIT_CACHE}"; base="$(cd "$(dirname "$0")" && pwd)"

mensagem() {  # sessão (nome do gerente | projeto | "") -> texto para o contexto
  python3 -I - "$dir" "$1" "$KIT_GERENTE" "$KIT_PROJETOS" "$base" <<'PY'
import json, os, sys
d, s, gerente, projetos, base = sys.argv[1:6]
nomes = [p.split(":")[0] for p in projetos.split()]
def n(x): return f"{x:g}".replace(".", ",")
def ler(arq):
    try: return json.load(open(os.path.join(d, arq)))
    except (OSError, ValueError): return {}
if s in nomes:
    o = ler("orientacao.json")
    orc = o.get("orcamento")
    rod = (o.get("rodando") or {})
    outros = sum((rod.get(x) or {}).get("unidades", 0) for x in nomes if x != s)
    if orc is None:
        print(f"AGENTES ({s}): o número de agentes ainda não está disponível; lance no máximo 1 agente capaz até o zelador avisar.")
    else:
        print(f"AGENTES ({s}): a conta permite agora até {n(orc)} agente(s) capaz(es) (opus ou fable) para os projetos juntos "
              f"(sonnet e haiku não contam: lance-os sem consumir vaga)"
              + (f"; os outros projetos usam {n(outros)} agora, então o seu limite é {n(max(0, orc - outros))}" if outros else "")
              + ". Quando esse número aumentar ou diminuir, o zelador avisa por mensagem; até lá, vale este. "
              "Consumo da conta, saúde da máquina, processos, térmica e as demais automações compartilhadas NÃO são "
              "da sua sessão: o zelador e o gerente cuidam delas. Não arme vigias de uso nem de saúde "
              "(esperar-orientacao.sh, esperar-saude.sh, esperar-processos-parados.sh) e não consulte o consumo-auto.")
    sys.exit()
if s != gerente: sys.exit()  # sessão fora dos projetos e da casa: nada
r = ler("estado.json").get("previsao") or {}
if not r: sys.exit()
print(f"Monitor de uso ativo: {r.get('uso_pct')}% da janela de 5 h, reset {r.get('reset')}, limite de agentes "
      f"{r.get('limite_codificadores')} ({r.get('motivo')}). Para receber os avisos (só quando o modo, o orçamento ou o "
      "bastão mudam), rode em segundo plano (Bash run_in_background, timeout de 2 h; rode de novo ao receber): "
      f"bash ~/.claude/skills/monitor-de-uso/scripts/esperar-orientacao.sh {nomes[0] if nomes else '<projeto>'}. Antes de lançar agente: "
      "consumo-auto.py --ver. Regras na skill monitor-de-uso.")
PY
}

sessao_de() {  # json do hook -> gerente | projeto | ""; a pasta da transcrição vale mais que o cwd
  python3 -I -c 'import json,os,re,sys
try: d=json.loads(sys.stdin.read() or "{}")
except ValueError: d={}
enc=lambda p: re.sub(r"[^A-Za-z0-9]","-",os.path.realpath(os.path.expanduser(p)))
pasta=os.path.basename(os.path.dirname(d.get("transcript_path") or "/x/x")); cwd=d.get("cwd") or ""
ger,gdir=sys.argv[1],sys.argv[2]
itens=[(p.split(":")[0],p.split(":")[1]) for p in sys.argv[3].split() if ":" in p]
if pasta==enc(gdir): print(ger); sys.exit()
for n,p in itens:
    if pasta==enc(p): print(n); sys.exit()
for n,p in itens:
    p=os.path.realpath(os.path.expanduser(p))
    if cwd==p or cwd.startswith(p+"/"): print(n); sys.exit()
if os.path.realpath(cwd)==os.path.realpath(gdir): print(ger)' "$KIT_GERENTE" "$KIT_GERENTE_DIR" "$KIT_PROJETOS"
}

if [ "${1:-}" = --autoteste ]; then
  T=$(mktemp -d); falhas=0; dir="$T"; KIT_GERENTE=Gerente; KIT_GERENTE_DIR=$T/g; KIT_PROJETOS="AAA:$T/a BBB:$T/b"
  confere() { grep -q -- "$2" <<<"$3" || { echo "FALHA $1: '$2' ausente em: $3"; falhas=1; }; }
  nao() { grep -q -- "$2" <<<"$3" && { echo "FALHA $1: '$2' presente"; falhas=1; }; }
  echo '{"previsao":{"uso_pct":4,"reset":"x","limite_codificadores":2,"motivo":"m"}}' > "$T/estado.json"
  echo '{"orcamento":2,"rodando":{"AAA":{"unidades":1},"BBB":{"unidades":1}}}' > "$T/orientacao.json"
  s=$(echo "{\"cwd\":\"$T/a/sub\"}" | sessao_de); [ "$s" = AAA ] || { echo "FALHA sessão AAA: $s"; falhas=1; }
  s=$(echo "{\"cwd\":\"$T/g\"}" | sessao_de); [ "$s" = Gerente ] || { echo "FALHA sessão gerente: $s"; falhas=1; }
  m=$(mensagem AAA); confere AAA "até 2 agente(s) capaz" "$m"; confere AAA2 "o seu limite é 1" "$m"; nao AAA3 "rode em segundo plano" "$m"
  m=$(mensagem Gerente); confere G "esperar-orientacao.sh AAA" "$m"
  m=$(mensagem ""); [ -z "$m" ] || { echo "FALHA sessão de fora recebeu: $m"; falhas=1; }
  rm "$T/orientacao.json"; m=$(mensagem BBB); confere sem "no máximo 1 agente" "$m"
  rm -rf "$T"; [ "$falhas" = 0 ] && echo "autoteste: OK" || echo "autoteste: FALHOU"; exit "$falhas"
fi

entrada=$([ -t 0 ] || timeout 2 cat)
pidf="$dir/monitor.pid"
# O pid tem de ser do monitor: depois de um boot o número pode ser de outro processo.
if ! { [ -f "$pidf" ] && tr '\0' ' ' < "/proc/$(cat "$pidf")/cmdline" 2>/dev/null | grep -q monitor-uso.py; }; then
  setsid nohup python3 "$base/monitor-uso.py" >/dev/null 2>&1 &
  sleep 2
fi
# O coletor de saúde (se o kit o instalou) também não volta sozinho depois de um reinício da máquina.
[ -f "$base/saude-maquina.sh" ] && { pgrep -f "$base/saude-maquina.sh" >/dev/null || setsid nohup bash "$base/saude-maquina.sh" >/dev/null 2>&1 < /dev/null & }
mensagem "$(sessao_de <<<"$entrada")"
exit 0
