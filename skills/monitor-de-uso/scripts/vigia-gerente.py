#!/usr/bin/env python3
"""Vigia único da sessão gerente: ela só acorda com o que é dela. O trivial é do zelador.

Cadeia de escalação: automações (saude-auto, parados-auto, consumo-auto) -> *-escalados.log -> zelador
(esperar-zelador.sh, age pela tabela) -> gerente (SendMessage do zelador, ou este vigia).
Este vigia não tem prazo e só termina em três casos, imprimindo a(s) linha(s):
  1. CRÍTICO: linha nova nos mesmos logs do zelador que casa KIT_VIGIA_CRITICOS (padrão abaixo). Usa contagem
     própria (<log>.visto-gerente); a do zelador (<log>.visto) nunca é tocada. Na 1ª vez parte do fim.
  2. AUTOMAÇÃO PARADA persistente: serviço de proteção fora há VIGIA_PARADA_S (10 min): o zelador religa em
     1 min; se não voltou, ele não resolve. Só com systemd do usuário.
  3. QUEDA: sessão de projeto (KIT_PROJETOS) ou o zelador fora do ar há KIT_VIGIA_FORA_S (5 min); vigia do
     zelador desarmado há VIGIA_ZELADOR_VIGIA_S (30 min). A linha traz o comando para reabrir.
Sessão "no ar" = um ~/.claude/sessions/*.json com "name" igual ao nome e o "pid" vivo (vale no Linux, no WSL e
no Windows). Projeto fechado de propósito: crie ~/.claude/passagem/ENCERRAR-<NOME> (apague ao reabrir).
Zelador: modo "sessao" (tmux próprio) confere a sessão e o vigia; modo "agente" (dentro do gerente) só o vigia
(esperar-zelador.pid). Um vigia só: vigia-gerente.pid.
Armar (só o gerente): python3 ~/.claude/skills/monitor-de-uso/scripts/vigia-gerente.py (run_in_background, sem
timeout); rearmar quando terminar. Outros usos: --uma (uma olhada, sem esperar o prazo) e --autoteste.
Provas: VIGIA_DIR, VIGIA_SESSOES, VIGIA_PASSAGEM, ESPERA_S, VIGIA_QUEDA_ESPERA_S, KIT_VIGIA_FORA_S, VIGIA_SEM_SYSTEMD.
"""
import json, os, re, shutil, signal, subprocess, sys, tempfile, time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "gerente-da-maquina", "lib"))
import kit_config as K  # noqa: E402

E = os.environ
KC = K.cfg
CRITICOS = E.get("KIT_VIGIA_CRITICOS", r"(DISCO CRÍTICO|DOCKER FORA|SESSÃO SEM AUTO|MONITOR DE USO PARADO)")
LOGS = ("saude-escalados.log", "parados-escalados.log", "consumo-escalados.log")
SERVICOS = ("saude-auto", "parados-auto", "consumo-auto")


def cfg():
    return {
        "D": os.path.expanduser(E.get("VIGIA_DIR", KC["KIT_CACHE"])),
        "SESSOES": os.path.expanduser(E.get("VIGIA_SESSOES", "~/.claude/sessions")),
        "PASSAGEM": os.path.expanduser(E.get("VIGIA_PASSAGEM", "~/.claude/passagem")),
        "ESPERA": float(E.get("ESPERA_S", "30")),
        "QUEDA_ESPERA": float(E.get("VIGIA_QUEDA_ESPERA_S", "60")),
        "FORA": float(E.get("KIT_VIGIA_FORA_S", KC.get("KIT_VIGIA_FORA_S", "300"))),
        "ZEL_VIGIA": float(E.get("VIGIA_ZELADOR_VIGIA_S", "1800")),
        "PARADA": float(E.get("VIGIA_PARADA_S", "600")),
        "SYSTEMD": not E.get("VIGIA_SEM_SYSTEMD") and shutil.which("systemctl") is not None,
    }


C = cfg()


def vivo(pid):
    """O PID existe? Só lê: no Windows pelo tasklist (lá os.kill(pid, 0) encerraria o processo)."""
    try:
        pid = int(pid)
    except (TypeError, ValueError):
        return False
    if pid <= 0:
        return False
    if os.name == "nt":
        try:
            r = subprocess.run(["tasklist", "/FI", f"PID eq {pid}", "/NH"], capture_output=True, text=True, timeout=10)
            return re.search(rf"\b{pid}\b", r.stdout) is not None
        except (OSError, subprocess.SubprocessError):
            return True  # sem como conferir: não acusa queda
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def ler_pid(arq):
    try:
        return int(open(arq).read().strip())
    except (OSError, ValueError):
        return 0


def sessoes_no_ar():
    """{nome: pid} das sessões do Claude Code vivas, pelos arquivos de ~/.claude/sessions."""
    no_ar = {}
    try:
        nomes = os.listdir(C["SESSOES"])
    except OSError:
        return no_ar
    for f in nomes:
        if not f.endswith(".json"):
            continue
        try:
            d = json.load(open(os.path.join(C["SESSOES"], f)))
        except (OSError, ValueError):
            continue
        if d.get("name") and vivo(d.get("pid")):
            no_ar[d["name"]] = d["pid"]
    return no_ar


def zelador_modo():
    m = KC.get("KIT_ZELADOR_MODO", "auto")
    if m in ("sessao", "agente"):
        return m
    return "sessao" if shutil.which("tmux") else "agente"


def problemas():
    """[(chave, resumo, como reabrir)] do que está fora agora (sessões e zelador)."""
    probs, no_ar, z = [], sessoes_no_ar(), KC["KIT_ZELADOR"]
    for nome, _, _ in K.projetos():
        if nome in no_ar or os.path.exists(os.path.join(C["PASSAGEM"], f"ENCERRAR-{nome}")):
            continue
        probs.append((f"sessao|{nome}", f"SESSÃO {nome} fora do ar (sem sessão com --name {nome} viva)",
                      f"sessao-projeto {nome} (ou reabra à mão na pasta do projeto); fechada de propósito: "
                      f"touch {C['PASSAGEM']}/ENCERRAR-{nome}"))
    modo = zelador_modo()
    if modo == "sessao" and z not in no_ar:
        probs.append(("zelador|sessao", f"ZELADOR: a sessão {z} não está no ar", "abrir-zelador"))
    elif not vivo(ler_pid(os.path.join(C["D"], "esperar-zelador.pid"))):
        como = (f"mande ao zelador (to: \"{z}\") rearmar o esperar-zelador.sh" if modo == "sessao"
                else "confira o agente zelador no painel; sem ele, relance pela §4 da skill zelador (modo agente)")
        probs.append(("zelador|vigia", "ZELADOR: o esperar-zelador.sh não está armado", como))
    return probs


def quedas(desde, agora):
    probs = problemas()
    chaves = {p[0] for p in probs}
    for k in [k for k in desde if k not in chaves]:
        del desde[k]
    saida = []
    for chave, resumo, como in probs:
        t = desde.setdefault(chave, agora)
        limite = C["ZEL_VIGIA"] if chave == "zelador|vigia" else C["FORA"]
        if agora - t >= limite:
            saida.append(f"QUEDA há {int((agora - t) // 60)} min: {resumo}. Reabrir: {como}")
    return saida


def iniciar_vistos():
    for log in LOGS:
        p = os.path.join(C["D"], log)
        v = p + ".visto-gerente"
        if not os.path.exists(v):
            n = contar(p)
            open(v, "w").write(f"{n}\n")


def contar(p):
    try:
        with open(p, "rb") as f:
            return sum(1 for l in f if l.endswith(b"\n"))
    except OSError:
        return 0


def novas_criticas():
    crit, rx = [], re.compile(CRITICOS)
    for log in LOGS:
        p = os.path.join(C["D"], log)
        v = p + ".visto-gerente"
        n = ler_pid(v)
        try:
            linhas = [l for l in open(p, encoding="utf-8", errors="replace").read().splitlines(keepends=True)
                      if l.endswith("\n")]
        except OSError:
            continue
        if len(linhas) < n:
            n = 0  # log rodado
        if len(linhas) > n:
            crit += [l.rstrip("\n") for l in linhas[n:] if rx.search(l)]
            open(v, "w").write(f"{len(linhas)}\n")
    return crit


def paradas(fora, agora):
    if not C["SYSTEMD"]:
        return []
    saida = []
    for s in SERVICOS:
        r = subprocess.run(["systemctl", "--user", "is-active", s], capture_output=True, text=True, timeout=20)
        estado = r.stdout.strip()
        if estado == "active" or estado == "":
            fora.pop(s, None)
            continue
        if subprocess.run(["systemctl", "--user", "cat", s], capture_output=True, timeout=20).returncode != 0:
            continue  # serviço não instalado
        t = fora.setdefault(s, agora)
        if agora - t >= C["PARADA"]:
            saida.append(f"AUTOMAÇÃO PARADA há {int((agora - t) // 60)} min: {s} ({estado}); o zelador não a trouxe "
                         f"de volta. Veja: systemctl --user status {s}; journalctl --user -u {s} -n 20")
    return saida


def vigiar(uma=False):
    os.makedirs(C["D"], exist_ok=True)
    trava = os.path.join(C["D"], "vigia-gerente.pid")
    outro = ler_pid(trava)
    if outro and outro != os.getpid() and vivo(outro):
        print(f"VIGIA-GERENTE: já há outro vigia armado (PID {outro}); este saiu sem vigiar (não rearme este).")
        return 1
    open(trava, "w").write(f"{os.getpid()}\n")
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    try:
        iniciar_vistos()
        desde, fora, ultima = {}, {}, -1e9
        while True:
            agora = time.time()
            crit = novas_criticas() + paradas(fora, agora)
            if uma or time.monotonic() - ultima >= C["QUEDA_ESPERA"]:
                ultima = time.monotonic()
                crit += quedas(desde, agora)
            if crit or uma:
                print("\n".join(crit) if crit else "nada fora do normal")
                return 0
            time.sleep(C["ESPERA"])
    finally:
        if ler_pid(trava) == os.getpid():
            os.remove(trava)


def autoteste():
    global C
    falhas = []

    def confere(nome, cond, det=""):
        if not cond:
            falhas.append(nome)
            print(f"FALHA {nome}: {str(det)[:300]}")

    T = tempfile.mkdtemp()
    filhos = []
    try:
        for d in ("cache", "sessoes", "passagem", "pa", "pb"):
            os.makedirs(os.path.join(T, d))
        E.update({"VIGIA_DIR": os.path.join(T, "cache"), "VIGIA_SESSOES": os.path.join(T, "sessoes"),
                  "VIGIA_PASSAGEM": os.path.join(T, "passagem"), "VIGIA_SEM_SYSTEMD": "1", "ESPERA_S": "0.1",
                  "VIGIA_QUEDA_ESPERA_S": "0", "KIT_VIGIA_FORA_S": "300", "VIGIA_ZELADOR_VIGIA_S": "1800"})
        KC.update({"KIT_PROJETOS": f"pa:{T}/pa pb:{T}/pb", "KIT_ZELADOR": "zelador", "KIT_ZELADOR_MODO": "sessao"})
        C = cfg()
        # processos do próprio teste: só eles contam como "vivos"; o morto é um que o teste criou e esperou
        vivo1 = subprocess.Popen(["sleep", "60"]); vivo2 = subprocess.Popen(["sleep", "60"]); filhos += [vivo1, vivo2]
        morto = subprocess.Popen(["true"]); morto.wait()

        def sessao(nome, pid):
            json.dump({"pid": pid, "name": nome}, open(os.path.join(T, "sessoes", f"{nome}.json"), "w"))

        sessao("pa", vivo1.pid); sessao("pb", morto.pid); sessao("zelador", vivo2.pid)
        open(os.path.join(T, "cache", "esperar-zelador.pid"), "w").write(f"{vivo2.pid}\n")
        chaves = [p[0] for p in problemas()]
        confere("só pb fora (pid morto)", chaves == ["sessao|pb"], chaves)
        desde = {}
        confere("antes dos 5 min não acusa", quedas(desde, 1000.0) == [], desde)
        q = quedas(desde, 1000.0 + 301)
        confere("depois de 5 min acusa QUEDA com o comando", len(q) == 1 and "QUEDA há 5 min: SESSÃO pb" in q[0]
                and "sessao-projeto pb" in q[0], q)
        sessao("pb", vivo1.pid)
        confere("voltou: esquece", quedas(desde, 2000.0) == [] and desde == {}, desde)
        open(os.path.join(T, "passagem", "ENCERRAR-pa"), "w").close()
        os.remove(os.path.join(T, "sessoes", "pa.json"))
        confere("ENCERRAR-<NOME> não acusa", [p[0] for p in problemas()] == [], problemas())
        os.remove(os.path.join(T, "sessoes", "zelador.json"))
        confere("zelador fora (sessão)", [p[0] for p in problemas()] == ["zelador|sessao"], problemas())
        sessao("zelador", vivo2.pid)
        open(os.path.join(T, "cache", "esperar-zelador.pid"), "w").write(f"{morto.pid}\n")
        desde = {}
        quedas(desde, 0.0)
        confere("vigia do zelador: 30 min de prazo", quedas(desde, 600.0) == [] and len(quedas(desde, 1801.0)) == 1, desde)
        KC["KIT_ZELADOR_MODO"] = "agente"
        os.remove(os.path.join(T, "sessoes", "zelador.json"))
        confere("modo agente: não cobra a sessão, só o vigia", [p[0] for p in problemas()] == ["zelador|vigia"], problemas())
        open(os.path.join(T, "cache", "esperar-zelador.pid"), "w").write(f"{vivo2.pid}\n")
        # críticos: só linhas novas que casam; contagem própria, a do zelador fica
        esc = os.path.join(T, "cache", "saude-escalados.log")
        open(esc, "w").write("2026 DISCO CRÍTICO: velho\n")
        iniciar_vistos()
        open(esc, "a").write("2026 MEMÓRIA BAIXA: x\n2026 DISCO CRÍTICO: novo\n")
        c = novas_criticas()
        confere("crítico novo, só o que casa", c == ["2026 DISCO CRÍTICO: novo"], c)
        confere("não relê", novas_criticas() == [])
        confere("contagem do zelador intocada", not os.path.exists(esc + ".visto"))
        # o laço inteiro, em outro processo: sai com o crítico; um segundo vigia recusa
        env = {**E}
        p = subprocess.Popen([sys.executable, "-I", os.path.abspath(__file__)], env=env, stdout=subprocess.PIPE, text=True)
        filhos.append(p)
        trava = os.path.join(T, "cache", "vigia-gerente.pid")
        for _ in range(100):
            if ler_pid(trava) == p.pid:
                break
            time.sleep(0.05)
        r = subprocess.run([sys.executable, "-I", os.path.abspath(__file__)], env=env, capture_output=True, text=True, timeout=20)
        confere("segundo vigia recusa", "já há outro" in r.stdout and r.returncode == 1, r.stdout)
        open(esc, "a").write("2026 DOCKER FORA: teste\n")
        out, _ = p.communicate(timeout=20)
        confere("laço sai com o crítico", out.strip() == "2026 DOCKER FORA: teste", out)
        confere("trava liberada na saída", not os.path.exists(trava))
    finally:
        for f in filhos:
            if f.poll() is None:
                f.kill()
                f.wait()
        shutil.rmtree(T, ignore_errors=True)
    print("autoteste: OK" if not falhas else "autoteste: FALHOU")
    return 1 if falhas else 0


if __name__ == "__main__":
    if "--autoteste" in sys.argv:
        sys.exit(autoteste())
    sys.exit(vigiar(uma="--uma" in sys.argv))
