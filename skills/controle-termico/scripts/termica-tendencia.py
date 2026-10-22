#!/usr/bin/env python3
"""Tendência térmica da CI: acompanha, em CSV, se o ponto de equilíbrio do computador está piorando (poeira, pasta térmica).

  --coletar    (timer termica-coletar, diário) acrescenta, sem repetir, em $KIT_CACHE/ci-termica/:
               tendencia-sessoes.csv: uma linha por sessão da CI do ci-termica (ENTROU ... SAIU), com perfil e teto
                 inicial e final, teto médio ponderado pelo tempo, reduções, subidas, degraus de perfil, temperatura do
                 pacote da CPU (média, p95, máxima, amostras >= 96 °C) e o contexto, tirado do saude.log: jobs
                 simultâneos, carga, CPU usada pela CI, frequência da CPU (queda = o processador se segurando), PSI de
                 CPU e temperatura da GPU;
               tendencia-jobs.csv (só com KIT_CI_REPO=dono/repositorio e o `gh` autenticado): uma linha por job
                 concluído no GitHub, com o teto, o perfil, a temperatura e os jobs simultâneos durante ele, para ver
                 se o teto custa tempo.
  --relatorio  (timer termica-relatorio, opcional, com data a configurar; ou à mão) agrega por semana, calcula a
               inclinação das tendências (teto médio, temperatura, duração dos jobs mais frequentes), grava
               relatorios/termica-<data>.txt e, sem --sem-aviso, escala ao zelador (saude-escalados.log:
               "RELATÓRIO TÉRMICO"), que avisa o gerente.
Só lê logs e a API do GitHub (gh); não mexe em nada da máquina.
"""
import csv, datetime as dt, json, os, re, statistics as st, subprocess, sys, time

sys.path.insert(0, os.path.expanduser("~/.claude/skills/gerente-da-maquina/lib"))
sys.path.insert(1, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "gerente-da-maquina", "lib"))
import kit_config as K

H = os.path.expanduser
DIR = H(os.environ.get("TENDENCIA_DIR", os.path.join(K.cfg["KIT_CACHE"], "ci-termica")))
LOG_CI = os.path.join(DIR, "ci-termica.log")
SAUDE = os.path.join(K.cfg["KIT_CACHE"], "saude.log")
SESSOES = os.path.join(DIR, "tendencia-sessoes.csv")
JOBS = os.path.join(DIR, "tendencia-jobs.csv")
ESCALADOS = os.path.join(K.cfg["KIT_CACHE"], "saude-escalados.log")
REPO = os.environ.get("KIT_CI_REPO") or K.cfg.get("KIT_CI_REPO", "")  # dono/repositório no GitHub; vazio = sem a tabela de jobs
CAMPOS_S = ["inicio", "fim", "duracao_min", "jobs", "perfil_inicial", "teto_inicial", "perfil_final", "teto_final",
            "teto_min", "teto_max", "teto_medio_ponderado", "reducoes", "subidas", "degraus_perfil", "voltas_perfil",
            "temp_media", "temp_p95", "temp_max", "amostras_ge96", "amostras", "jobs_simultaneos_media",
            "carga1_media", "ci_nucleos_media", "cpu_mhz_media", "psi_cpu_media", "gpu_temp_media", "gpu_temp_max",
            "ventoinhas_repostas", "fim_motivo"]
CAMPOS_J = ["job_id", "run_id", "nome", "inicio", "duracao_min", "resultado", "executor", "teto_medio", "perfil",
            "temp_media", "temp_max", "jobs_simultaneos_media", "gpu_temp_media"]
COLS = {"cpu_pacote_C": "temp", "jobs_ci": "jobs", "carga1": "carga", "ci_nucleos": "ci", "cpu_mhz": "mhz",
        "psi_cpu": "psi", "gpu_C": "gpu"}


def ts(s):
    return dt.datetime.fromisoformat(s).timestamp()


def ler_temps():
    out, cab = [], None
    try:
        f = open(SAUDE, errors="replace")
    except OSError:
        return out
    for l in f:
        c = l.split()
        if not c:
            continue
        if c[0] in ("data_hora", "hora"):
            cab = c
            continue
        if not cab or cab[0] != "data_hora" or len(c) != len(cab) or "T" not in c[0]:
            continue
        d = dict(zip(cab, c))
        try:
            r = {"t": time.mktime(time.strptime(c[0], "%Y-%m-%dT%H:%M:%S"))}
        except ValueError:
            continue
        for k, nome in COLS.items():
            try:
                r[nome] = float(d[k])
            except (KeyError, ValueError):
                r[nome] = None
        out.append(r)
    return out


def media(rows, k, nd=1):
    v = [r[k] for r in rows if r.get(k) is not None]
    return round(st.mean(v), nd) if v else ""


def sessoes():
    """Reconstrói as sessões da CI a partir do log do ci-termica."""
    res, s = [], None
    for l in open(LOG_CI, errors="replace"):
        m = re.match(r"(\S+) (.*)", l.strip())
        if not m:
            continue
        t, txt = ts(m.group(1)), m.group(2)
        if txt.startswith("ENTROU no perfil da CI"):
            ap = re.search(r"aplicado: perfil=(\S+) \S+ max_perf_pct=(\d+)", txt)
            jobs = re.search(r"jobs: (\S+)", txt)
            s = {"inicio": t, "perfil": ap.group(1) if ap else "?", "teto": int(ap.group(2)) if ap else None,
                 "eventos": [(t, int(ap.group(2)) if ap else None)], "perfil_inicial": ap.group(1) if ap else "?",
                 "reducoes": 0, "subidas": 0, "degraus": 0, "voltas": 0, "vent": 0, "jobs": jobs.group(1) if jobs else ""}
        elif s is None:
            continue
        elif (m2 := re.match(r"TETO (reduzido|subiu) (\d+) -> (\d+)%", txt)):
            s["teto"] = int(m2.group(3)); s["eventos"].append((t, s["teto"]))
            s["reducoes" if m2.group(1) == "reduzido" else "subidas"] += 1
        elif (m2 := re.match(r"PERFIL da CI (voltou )?(\S+) -> (\S+), teto (\d+)%", txt)):
            s["perfil"] = m2.group(3); s["teto"] = int(m2.group(4)); s["eventos"].append((t, s["teto"]))
            s["voltas" if m2.group(1) else "degraus"] += 1
        elif txt.startswith("VENTOINHAS repostas"):
            s["vent"] += 1
        elif txt.startswith("SAIU do perfil da CI"):
            mot = re.search(r"\(([^)]*)\)", txt)
            s["fim"] = t; s["motivo"] = mot.group(1) if mot else ""
            res.append(s); s = None
    return res


def linha_sessao(s, temps):
    ini, fim = s["inicio"], s["fim"]
    ev = s["eventos"] + [(fim, None)]
    pond, total = 0.0, 0.0
    for (t0, v), (t1, _) in zip(ev, ev[1:]):
        if v is not None:
            pond += v * (t1 - t0); total += t1 - t0
    tetos = [v for _, v in s["eventos"] if v is not None]
    rows = [r for r in temps if ini <= r["t"] <= fim]
    tt = sorted(r["temp"] for r in rows if r["temp"] is not None)
    gpu = [r["gpu"] for r in rows if r["gpu"] is not None]
    p95 = tt[min(len(tt) - 1, int(len(tt) * 0.95))] if tt else ""
    return {"inicio": dt.datetime.fromtimestamp(ini).isoformat(timespec="seconds"),
            "fim": dt.datetime.fromtimestamp(fim).isoformat(timespec="seconds"),
            "duracao_min": round((fim - ini) / 60, 1), "jobs": s["jobs"], "perfil_inicial": s["perfil_inicial"],
            "teto_inicial": tetos[0] if tetos else "", "perfil_final": s["perfil"], "teto_final": s["teto"],
            "teto_min": min(tetos) if tetos else "", "teto_max": max(tetos) if tetos else "",
            "teto_medio_ponderado": round(pond / total, 1) if total else "", "reducoes": s["reducoes"],
            "subidas": s["subidas"], "degraus_perfil": s["degraus"], "voltas_perfil": s["voltas"],
            "temp_media": round(st.mean(tt), 1) if tt else "", "temp_p95": p95, "temp_max": max(tt) if tt else "",
            "amostras_ge96": sum(x >= 96 for x in tt), "amostras": len(tt),
            "jobs_simultaneos_media": media(rows, "jobs", 2), "carga1_media": media(rows, "carga"),
            "ci_nucleos_media": media(rows, "ci", 2), "cpu_mhz_media": media(rows, "mhz", 0), "psi_cpu_media": media(rows, "psi"),
            "gpu_temp_media": round(st.mean(gpu), 1) if gpu else "", "gpu_temp_max": max(gpu) if gpu else "",
            "ventoinhas_repostas": s["vent"],
            "fim_motivo": s["motivo"]}


def ler_csv(caminho):
    try:
        with open(caminho, newline="") as f:
            return list(csv.DictReader(f))
    except OSError:
        return []


def acrescentar(caminho, campos, linhas):
    novo = not os.path.exists(caminho)
    with open(caminho, "a", newline="") as f:
        w = csv.DictWriter(f, fieldnames=campos)
        if novo:
            w.writeheader()
        w.writerows(linhas)


def teto_no_tempo(todas):
    """Função t -> (teto, perfil) pelos eventos de todas as sessões; fora da CI, (None, None)."""
    marcos = []
    for s in todas:
        for t, v in s["eventos"]:
            marcos.append((t, v, s))
    marcos.sort(key=lambda x: x[0])
    def f(t):
        ult = None
        for tt, v, s in marcos:
            if tt > t:
                break
            ult = (v, s)
        if not ult or not (ult[1]["inicio"] <= t <= ult[1].get("fim", 1e18)):
            return None
        return ult[0]
    return f


def coletar():
    temps = ler_temps()
    vistos = {r["inicio"] for r in ler_csv(SESSOES)}
    todas = sessoes()
    teto_em = teto_no_tempo(todas)
    novas = [linha_sessao(s, temps) for s in todas]
    novas = [r for r in novas if r["inicio"] not in vistos]
    acrescentar(SESSOES, CAMPOS_S, novas)
    if not REPO:
        print(f"coletadas {len(novas)} sessões (KIT_CI_REPO vazio: sem jobs do GitHub)")
        return
    # Jobs do repositório desde o último coletado (na 1ª vez, desde 30 dias atrás)
    jobs_vistos = {r["job_id"] for r in ler_csv(JOBS)}
    ult = max((r["inicio"] for r in ler_csv(JOBS)), default=(dt.datetime.now() - dt.timedelta(days=30)).isoformat(timespec="seconds"))
    desde = ult[:10]
    novos, pagina = [], 1
    while True:
        r = subprocess.run(["gh", "api", f"repos/{REPO}/actions/runs?created=>={desde}&status=completed&per_page=100&page={pagina}",
                            "-q", "[.workflow_runs[].id]"], capture_output=True, text=True, timeout=120)
        try:
            ids = json.loads(r.stdout or "[]")
        except ValueError:
            ids = []
        if not ids:
            break
        for rid in ids:
            rj = subprocess.run(["gh", "api", f"repos/{REPO}/actions/runs/{rid}/jobs?per_page=100", "-q", ".jobs"],
                                capture_output=True, text=True, timeout=120)
            try:
                jobs = json.loads(rj.stdout or "[]")
            except ValueError:
                continue
            if not isinstance(jobs, list):
                continue  # resposta de erro da API: tenta de novo na próxima coleta
            for j in jobs:
                if not isinstance(j, dict):
                    continue
                if str(j["id"]) in jobs_vistos or not j.get("started_at") or not j.get("completed_at"):
                    continue
                if j.get("conclusion") in ("skipped", "cancelled"):
                    continue
                a, b = ts(j["started_at"].replace("Z", "+00:00")), ts(j["completed_at"].replace("Z", "+00:00"))
                rows = [r for r in temps if a <= r["t"] <= b]
                tetos = [x for x in (teto_em(t) for t in range(int(a), int(b) + 1, 30)) if x is not None]
                tt = [r["temp"] for r in rows if r["temp"] is not None]
                sess = next((s for s in todas if s["inicio"] <= a <= s.get("fim", 1e18)), None)
                novos.append({"job_id": j["id"], "run_id": rid, "nome": j["name"],
                              "inicio": dt.datetime.fromtimestamp(a).isoformat(timespec="seconds"),
                              "duracao_min": round((b - a) / 60, 2), "resultado": j.get("conclusion"),
                              "executor": ",".join(j.get("labels") or []),
                              "teto_medio": round(st.mean(tetos), 1) if tetos else "",
                              "perfil": sess["perfil_inicial"] if sess else "", "temp_media": round(st.mean(tt), 1) if tt else "",
                              "temp_max": max(tt) if tt else "", "jobs_simultaneos_media": media(rows, "jobs", 2),
                              "gpu_temp_media": media(rows, "gpu")})
                jobs_vistos.add(str(j["id"]))
        pagina += 1
        if pagina > 10:
            break
    acrescentar(JOBS, CAMPOS_J, sorted(novos, key=lambda x: x["inicio"]))
    print(f"coletadas {len(novas)} sessões e {len(novos)} jobs")


def inclinacao(pontos):
    """Inclinação por semana (mínimos quadrados) de [(semana_idx, valor)]."""
    if len(pontos) < 2:
        return None
    xs, ys = [p[0] for p in pontos], [p[1] for p in pontos]
    mx, my = st.mean(xs), st.mean(ys)
    den = sum((x - mx) ** 2 for x in xs)
    return sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / den if den else None


def relatorio(avisar=True):
    S = [r for r in ler_csv(SESSOES) if r["perfil_inicial"] == "performance" and r["teto_medio_ponderado"]]  # sessões com teto dinâmico
    J = [r for r in ler_csv(JOBS) if r["resultado"] == "success" and "self-hosted" in r["executor"]]
    sem = lambda iso: dt.date.fromisoformat(iso[:10]).isocalendar()[:2]
    semanas = sorted({sem(r["inicio"]) for r in S} | {sem(r["inicio"]) for r in J})
    idx = {w: i for i, w in enumerate(semanas)}
    L = [f"Relatório de tendência térmica da CI · gerado em {dt.datetime.now():%d/%m/%Y %H:%M}",
         f"Regra: ver a SKILL.md do controle-termico (teto inicial, sobe com máxima baixa, desce com média alta, piso, cascata de perfis). "
         f"Sessões analisadas: {len(S)}. Dados: {SESSOES} e {JOBS}.", ""]
    cab = f"{'semana':<10} {'CIs':>4} {'h CI':>6} {'teto méd':>8} {'teto fim':>8} {'degrau%':>7} {'T méd':>6} {'T p95':>6} {'T máx':>6} {'>=96':>5}"
    L.append(cab)
    ser = {"teto": [], "temp": [], "p95": []}
    for w in semanas:
        ss = [r for r in S if sem(r["inicio"]) == w]
        if not ss:
            continue
        horas = sum(float(r["duracao_min"]) for r in ss) / 60
        pes = [float(r["duracao_min"]) for r in ss]
        teto = sum(float(r["teto_medio_ponderado"]) * p for r, p in zip(ss, pes)) / sum(pes)
        tfim = st.mean(float(r["teto_final"]) for r in ss)
        deg = 100 * sum(int(r["degraus_perfil"]) > 0 for r in ss) / len(ss)
        tm = [float(r["temp_media"]) for r in ss if r["temp_media"]]
        p95 = [float(r["temp_p95"]) for r in ss if r["temp_p95"]]
        tmax = max((float(r["temp_max"]) for r in ss if r["temp_max"]), default=0)
        ge96 = sum(int(r["amostras_ge96"]) for r in ss)
        L.append(f"{w[0]}-S{w[1]:<4} {len(ss):>4} {horas:>6.1f} {teto:>8.1f} {tfim:>8.1f} {deg:>7.0f} "
                 f"{st.mean(tm) if tm else 0:>6.1f} {st.mean(p95) if p95 else 0:>6.1f} {tmax:>6.0f} {ge96:>5}")
        ser["teto"].append((idx[w], teto))
        if tm:
            ser["temp"].append((idx[w], st.mean(tm)))
        if p95:
            ser["p95"].append((idx[w], st.mean(p95)))
    L += ["", "Duração mediana dos jobs principais (min, só sucesso, executor local):"]
    nomes = {}
    for r_ in J:
        nomes[r_["nome"]] = nomes.get(r_["nome"], 0) + 1
    principais = [n for n, _ in sorted(nomes.items(), key=lambda x: -x[1])[:5]]  # os 5 jobs mais frequentes
    ser_jobs = {}
    for nome in principais:
        linha = f"  {nome:<24}"
        for w in semanas:
            d = [float(r["duracao_min"]) for r in J if r["nome"].startswith(nome) and sem(r["inicio"]) == w]
            linha += f" {w[1]}: {st.median(d):5.1f} ({len(d):>2})" if d else f" {w[1]}:   -   (0)"
            if d:
                ser_jobs.setdefault(nome, []).append((idx[w], st.median(d)))
        L.append(linha)
    L += ["", "Tendências (inclinação por semana):"]
    alertas = []
    it = inclinacao(ser["teto"]); itp = inclinacao(ser["temp"]); ip95 = inclinacao(ser["p95"])
    L.append(f"  teto médio ponderado: {it:+.1f} pontos/semana" if it is not None else "  teto: dados de 1 semana só")
    L.append(f"  temperatura média: {itp:+.1f} °C/semana · p95: {ip95:+.1f} °C/semana" if itp is not None and ip95 is not None else "  temperatura: dados de 1 semana só")
    if it is not None and it <= -3:
        alertas.append("o teto de equilíbrio está caindo (>= 3 pontos por semana)")
    if itp is not None and itp >= 1.5:
        alertas.append("a temperatura média com CI está subindo (>= 1,5 °C por semana)")
    for nome, pts in ser_jobs.items():
        ij = inclinacao(pts)
        if ij is not None:
            L.append(f"  {nome}: {ij:+.2f} min/semana")
            if pts[0][1] and ij / pts[0][1] >= 0.05:
                alertas.append(f"o job {nome} está ficando mais lento (>= 5% por semana)")
    L += ["", "Conclusão:"]
    if alertas:
        L += [f"  ATENÇÃO: {a}." for a in alertas]
        L.append("  Sugestão: limpar as ventoinhas e as saídas de ar do notebook; se persistir, trocar a pasta térmica.")
    else:
        L.append("  Sem tendência de piora: o ponto de equilíbrio e as temperaturas estão estáveis. Nada a fazer.")
    os.makedirs(os.path.join(DIR, "relatorios"), exist_ok=True)
    caminho = os.path.join(DIR, "relatorios", f"termica-{dt.date.today():%Y-%m-%d}.txt")
    with open(caminho, "w") as f:
        f.write("\n".join(L) + "\n")
    print("\n".join(L))
    if avisar:
        with open(ESCALADOS, "a") as f:
            f.write(f"{dt.datetime.now().astimezone().isoformat(timespec='seconds')} RELATÓRIO TÉRMICO: {caminho} · "
                    f"{'ATENÇÃO: ' + '; '.join(alertas) if alertas else 'sem tendência de piora'}\n")


if __name__ == "__main__":
    if "--coletar" in sys.argv:
        coletar()
    if "--relatorio" in sys.argv:
        relatorio(avisar="--sem-aviso" not in sys.argv)
