#!/usr/bin/env bash
# Instalador do kit do gerente da máquina (só no usuário; nada de sudo).
#   bash instalar.sh --verificar    mostra o que faria, sem mudar nada
#   bash instalar.sh                instala (guarda cópia *.antes-kit de tudo o que substitui)
#   bash instalar.sh --autoteste    roda o autoteste de cada script instalado
#   bash instalar.sh --desinstalar  para os serviços do kit e restaura as cópias *.antes-kit
# Destinos: skills → ~/.claude/skills/, hooks → ~/.claude/hooks/, bin → ~/.local/bin/,
# systemd → ~/.config/systemd/user/, settings/statusline.py → ~/.claude/statusline.py,
# settings/*.json → mesclados em ~/.claude/settings.json.
set -uo pipefail
KIT="$(cd "$(dirname "$0")" && pwd)"
CONF="$HOME/.config/gerente-maquina/kit.conf"
MODO="${1:-instalar}"
SECO=0; [ "$MODO" = "--verificar" ] && SECO=1
LISTA="$HOME/.config/gerente-maquina/instalados.txt"   # o que o kit pôs (para desinstalar)

faz() { if [ "$SECO" = 1 ]; then echo "  [faria] $*"; else "$@"; fi; }
copia() {  # origem destino [modo]
  local o="$1" d="$2" m="${3:-644}"
  if [ -e "$d" ] && ! cmp -s "$o" "$d"; then
    [ -e "$d.antes-kit" ] || faz cp -p "$d" "$d.antes-kit"
    echo "  substitui $d (cópia em $d.antes-kit)"
  elif [ ! -e "$d" ]; then echo "  novo      $d"; fi
  faz mkdir -p "$(dirname "$d")"
  faz install -m "$m" "$o" "$d"
  [ "$SECO" = 1 ] || echo "$d" >> "$LISTA"
}

servicos_do_kit() { ls "$KIT/systemd" 2>/dev/null | grep -E '\.(service|timer)$' | grep -v '@'; }

desinstalar() {
  local u f
  for u in $(servicos_do_kit); do systemctl --user disable --now "$u" 2>/dev/null && echo "  parado $u"; done
  [ -f "$LISTA" ] || { echo "nada instalado pelo kit"; return 0; }
  sort -u "$LISTA" | while read -r f; do
    if [ -e "$f.antes-kit" ]; then mv -f "$f.antes-kit" "$f"; echo "  restaurado $f"; else rm -f "$f"; echo "  removido $f"; fi
  done
  [ -e "$HOME/.claude/settings.json.antes-kit" ] && mv -f "$HOME/.claude/settings.json.antes-kit" "$HOME/.claude/settings.json" && echo "  restaurado settings.json"
  rm -f "$LISTA"; systemctl --user daemon-reload 2>/dev/null; echo "desinstalado (o kit.conf e o cache ficaram)"
}

autoteste() {
  local f ok=0 n=0
  while read -r f; do
    grep -q -- '--autoteste' "$f" 2>/dev/null || continue
    n=$((n+1))
    case "$f" in *.py) python3 "$f" --autoteste >/dev/null 2>&1 ;; *) bash "$f" --autoteste >/dev/null 2>&1 ;; esac \
      && echo "  OK    $f" || { echo "  FALHA $f"; ok=1; }
  done < <(sort -u "$LISTA" 2>/dev/null | grep -E '(\.sh|\.py|/[^./]+)$')  # só o que o kit instalou
  echo "$n autotestes; $([ $ok = 0 ] && echo todos passaram || echo HÁ FALHAS)"; return $ok
}

mescla_settings() {  # mescla settings/*.json do kit em ~/.claude/settings.json sem apagar o que já existe
  local alvo="$HOME/.claude/settings.json"
  if [ "$SECO" = 1 ]; then echo "  [faria] mesclar $(ls "$KIT"/settings/*.json 2>/dev/null | xargs -n1 basename | tr '\n' ' ')em $alvo"; return; fi
  [ -e "$alvo" ] && [ ! -e "$alvo.antes-kit" ] && cp -p "$alvo" "$alvo.antes-kit"
  python3 -I - "$alvo" "$KIT/settings" <<'PY'
import glob, json, os, sys
alvo, pasta = sys.argv[1], sys.argv[2]
home = os.path.expanduser("~")
try: s = json.load(open(alvo))
except (OSError, ValueError): s = {}
def junta(a, b):
    if isinstance(a, dict) and isinstance(b, dict):
        for k, v in b.items(): a[k] = junta(a.get(k), v) if k in a else v
        return a
    if isinstance(a, list) and isinstance(b, list):
        return a + [x for x in b if x not in a]
    return b
for f in sorted(glob.glob(os.path.join(pasta, "*.json"))):
    texto = open(f).read().replace("$HOME", home).replace("~/", home + "/")
    junta(s, json.loads(texto))
os.makedirs(os.path.dirname(alvo), exist_ok=True)
json.dump(s, open(alvo, "w"), indent=2, ensure_ascii=False)
print(f"  settings.json mesclado ({len(s.get('hooks', {}))} eventos de hook)")
PY
}

case "$MODO" in
  --desinstalar) desinstalar; exit $? ;;
  --autoteste) autoteste; exit $? ;;
  instalar|--verificar) ;;
  *) sed -n 2,9p "$0"; exit 2 ;;
esac

echo "== verificação"
for c in python3 tmux git claude systemctl; do command -v "$c" >/dev/null && echo "  ok        $c" || echo "  FALTA     $c"; done
grep -qi microsoft /proc/version 2>/dev/null && echo "  WSL detectado: veja docs/windows-wsl.md (systemd e térmica)"
systemctl --user is-system-running >/dev/null 2>&1 || echo "  aviso: systemd do usuário indisponível; os serviços não vão subir"
if [ ! -f "$CONF" ]; then
  echo "  sem $CONF: copie config/kit.conf.exemplo para lá e ajuste (o Claude Code na pasta do kit faz isso com você)"
  [ "$SECO" = 1 ] || exit 1
fi

echo "== arquivos"
[ "$SECO" = 1 ] || { mkdir -p "$(dirname "$LISTA")"; : >> "$LISTA"; }
while read -r f; do
  rel="${f#"$KIT"/skills/}"; m=644; [ -x "$f" ] && m=755
  copia "$f" "$HOME/.claude/skills/$rel" "$m"
done < <(find "$KIT/skills" -type f ! -name '*.pyc' | sort)
for f in "$KIT"/hooks/*; do [ -f "$f" ] && copia "$f" "$HOME/.claude/hooks/$(basename "$f")" 755; done
for f in "$KIT"/bin/*; do [ -f "$f" ] && copia "$f" "$HOME/.local/bin/$(basename "$f")" 755; done
for f in "$KIT"/systemd/*; do [ -f "$f" ] && copia "$f" "$HOME/.config/systemd/user/$(basename "$f")" 644; done
[ -f "$KIT/settings/statusline.py" ] && copia "$KIT/settings/statusline.py" "$HOME/.claude/statusline.py" 755
mescla_settings
faz mkdir -p "$HOME/.claude/passagem"

echo "== serviços"
faz systemctl --user daemon-reload
for u in $(servicos_do_kit); do
  # timers ligam o próprio serviço; serviço com timer homônimo não é ligado direto
  case "$u" in *.service) [ -f "$KIT/systemd/${u%.service}.timer" ] && continue ;; esac
  # relatório térmico: data a ajustar, a pessoa liga à mão (ver o .timer)
  case "$u" in termica-relatorio.*) echo "  $u: opcional, desligado (ajuste a data e ligue à mão)"; continue ;; esac
  faz systemctl --user enable --now "$u"
done
command -v loginctl >/dev/null && ! loginctl show-user "$USER" -p Linger 2>/dev/null | grep -q yes \
  && echo "  para os serviços subirem no boot sem login: sudo loginctl enable-linger $USER (rode você mesmo)"

echo "== passagem de bastão"
echo "  fica DESLIGADA até você criar a chave: touch ~/.claude/passagem/ATIVA (ver skills/gerente-da-maquina/passagem.md)"
if [ "$SECO" = 0 ]; then
  # shellcheck disable=SC1090
  . "$HOME/.claude/skills/gerente-da-maquina/lib/kit.sh"
  kit_registrar "kit: instalado de $KIT. Desfazer: bash $KIT/instalar.sh --desinstalar"
  echo "pronto. Próximo passo: bash instalar.sh --autoteste; depois abra o gerente com: gerente"
fi
