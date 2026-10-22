#!/usr/bin/env python3
"""Linha de status global do Claude Code: contexto, modelo, pasta, duração, consumo da conta (lido da orientação do
consumo-auto) e máquina (temperatura, ventoinhas, perfil de energia, teto da CPU). Instalada em ~/.claude/statusline.py."""
import sys, json, os, subprocess

_L = os.path.expanduser("~/.claude/skills/gerente-da-maquina/lib")
try:
    sys.path.insert(0, _L)
    import kit_config as K
    CACHE = K.cfg["KIT_CACHE"]
except Exception:
    CACHE = os.path.expanduser("~/.cache/gerente-maquina")


def fmt_tokens(n: int) -> str:
    if n >= 1_000_000:
        return f"{n / 1_000_000:.2f}M"
    if n >= 1_000:
        return f"{n / 1_000:.1f}k"
    return str(n)


def shorten_path(cwd: str) -> str:
    if not cwd:
        return ""
    home = os.path.expanduser("~")
    disp = "~" + cwd[len(home):] if cwd.startswith(home) else cwd
    parts = disp.split("/")
    if len(parts) > 4:
        return parts[0] + "/.../" + "/".join(parts[-2:])
    return disp


def last_usage_from_transcript(path: str):
    if not path or not os.path.isfile(path):
        return None
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as f:
            f.seek(max(0, size - 512 * 1024))
            tail = f.read().decode("utf-8", errors="ignore")
        for line in reversed(tail.splitlines()):
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except Exception:
                continue
            usage = (obj.get("message") or {}).get("usage")
            if usage:
                return usage
    except Exception:
        return None
    return None


def git_branch(cwd: str) -> str:
    if not cwd:
        return ""
    try:
        r = subprocess.run(
            ["git", "-C", cwd, "branch", "--show-current"],
            capture_output=True, text=True, timeout=0.4,
        )
        if r.returncode == 0:
            return r.stdout.strip()
    except Exception:
        pass
    return ""


def consumo_segs(dim: str, bold: str, reset: str):
    """Projeção da semana e agentes indicados, lidos da orientação do consumo-auto."""
    try:
        with open(os.path.join(CACHE, "orientacao.json")) as f:
            o = json.load(f)
    except Exception:
        return []
    import time
    velho = time.time() - float(o.get("ts") or 0) > 1800
    balanco = o.get("balanco") or {}
    prevista = balanco.get("prevista_pct")
    meta = float(balanco.get("meta") or 100)
    segs = []
    semana = (o.get("conta") or {}).get("semana_pct")
    if semana is not None:
        segs.append(f"Sem: {bold}{float(semana):.0f}%{reset}")
    if prevista is not None:
        cor = "\033[31m" if prevista > meta else "\033[32m"
        segs.append(f"Pr_Cons: {cor}{bold}{prevista:.0f}%{reset}")
    orc = o.get("orcamento")
    if orc is not None:
        orc = float(orc)
        segs.append(f"N°Ag: {bold}{orc:g}{reset}")
    if segs and velho:
        segs[-1] += f" {dim}(velho){reset}"
    return segs


def ler(caminho: str) -> str:
    try:
        with open(caminho) as f:
            return f.read().strip()
    except OSError:
        return ""


def maquina_segs(bold: str, reset: str):
    """CPU (média do último minuto), ventoinhas, perfil de energia e teto do processador ."""
    import glob
    import time
    hw = {ler(d + "/name"): d for d in glob.glob("/sys/class/hwmon/hwmon*")}
    temps = []
    agora = ler(hw.get("coretemp", "") + "/temp1_input")  # Package id 0
    if agora:
        temps.append(int(agora) / 1000)
    try:  # amostras do saude.log (a cada ~30 s) no último minuto, coluna cpu_pacote_C
        with open(os.path.join(CACHE, "saude.log"), "rb") as f:
            f.seek(0, 2)
            f.seek(max(0, f.tell() - 1000))
            linhas = f.read().decode(errors="ignore").splitlines()[-3:]
        limite = time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(time.time() - 60))
        for l in linhas:
            c = l.split()
            if len(c) > 10 and c[0] >= limite and c[10] != "-":
                temps.append(float(c[10]))
    except (OSError, ValueError):
        pass
    segs = []
    if temps:
        t = sum(temps) / len(temps)
        cor = "\033[31m" if t >= 80 else "\033[33m" if t >= 70 else "\033[32m"
        segs.append(f"CPU: {cor}{bold}{t:.0f}°C{reset}")
    pcts = []  # ventoinhas: qualquer hwmon que exponha fanN_input e fanN_max
    for d in glob.glob("/sys/class/hwmon/hwmon*"):
        for n in (1, 2):
            a, m = ler(f"{d}/fan{n}_input"), ler(f"{d}/fan{n}_max")
            if a.isdigit() and m.isdigit() and int(m) > 0:
                pcts.append(int(a) * 100 / int(m))
    if pcts:
        segs.append(f"Vent: {sum(pcts) / len(pcts):.0f}%")
    perfil = ""
    try:  # ao vivo pelo D-Bus (~8 ms); o state.ini só é regravado de vez em quando
        import subprocess
        r = subprocess.run(["busctl", "get-property", "org.freedesktop.UPower.PowerProfiles",
                            "/org/freedesktop/UPower/PowerProfiles", "org.freedesktop.UPower.PowerProfiles",
                            "ActiveProfile"], capture_output=True, text=True, timeout=1)
        if r.returncode == 0:
            perfil = r.stdout.split('"')[1]
    except (OSError, IndexError, subprocess.SubprocessError):
        pass
    if not perfil:
        perfil = next((l.split("=", 1)[1] for l in ler("/var/lib/power-profiles-daemon/state.ini").splitlines()
                       if l.startswith("Profile=")), "")
    if perfil:
        segs.append(f"Perfil: {perfil}")
    teto = ler("/sys/devices/system/cpu/intel_pstate/max_perf_pct")
    if teto:
        segs.append(f"Teto: {teto}%")
    return segs


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        print("statusline: invalid input")
        return

    model = data.get("model") or {}
    model_name = model.get("display_name") or model.get("id") or "?"
    model_id_blob = f"{model.get('id', '')} {model.get('display_name', '')}".lower()

    workspace = data.get("workspace") or {}
    cwd = workspace.get("current_dir") or data.get("cwd") or ""
    transcript = data.get("transcript_path") or ""
    cost = data.get("cost") or {}
    cost_usd = float(cost.get("total_cost_usd") or 0)
    duration_ms = int(cost.get("total_duration_ms") or 0)
    exceeds_200k = bool(data.get("exceeds_200k_tokens"))

    usage = last_usage_from_transcript(transcript) or {}
    tokens = (
        int(usage.get("input_tokens") or 0)
        + int(usage.get("cache_read_input_tokens") or 0)
        + int(usage.get("cache_creation_input_tokens") or 0)
        + int(usage.get("output_tokens") or 0)
    )

    is_1m = "1m" in model_id_blob or exceeds_200k or tokens > 200_000
    limit = 1_000_000 if is_1m else 200_000

    pct = int(tokens * 100 / limit) if limit else 0
    pct = max(0, min(100, pct))

    width = 12
    filled = pct * width // 100
    bar = "█" * filled + "░" * (width - filled)

    if pct >= 85:
        color = "\033[31m"
    elif pct >= 60:
        color = "\033[33m"
    else:
        color = "\033[32m"
    dim = "\033[2m"
    bold = "\033[1m"
    reset = "\033[0m"

    branch = git_branch(cwd)
    dir_disp = shorten_path(cwd)
    if branch:
        dir_disp = f"{dir_disp} {dim}({branch}){reset}"

    mins, secs = divmod(duration_ms // 1000, 60)
    hrs, mins = divmod(mins, 60)
    if hrs:
        dur = f"{hrs}h{mins:02d}m"
    elif mins:
        dur = f"{mins}m{secs:02d}s"
    else:
        dur = f"{secs}s"

    sep = f" {dim}│{reset} "
    ctx_seg = (
        f"{color}[{bar}]{reset} "
        f"{bold}{pct}%{reset} "
        f"{dim}{fmt_tokens(tokens)}/{fmt_tokens(limit)}{reset}"
    )
    parts = [
        ctx_seg,
        f"{bold}{model_name}{reset}",
        dir_disp,
        dur,
    ] + consumo_segs(dim, bold, reset) + maquina_segs(bold, reset)
    sys.stdout.write(sep.join(p for p in parts if p))
    sys.stdout.write(sep.rstrip() + "\n")


if __name__ == "__main__":
    main()
