import importlib.util,sys
def carrega(p):
    spec=importlib.util.spec_from_file_location("u",p); u=importlib.util.module_from_spec(spec); spec.loader.exec_module(u); return u
u=carrega(sys.argv[1]); H=3600; reset=1000*H; ini=reset-7*86400
def amostra(t,p): return {"ts":t,"sete_dias":p,"reset_semana":reset+60}
falhas=0
def ok(nome,c):
    global falhas
    if not c: print("FALHA",nome); falhas=1
# semana com início intenso (60% em 3 dias) e últimas 24 h calmas (8%): 78% a 56 h do fim
agora=reset-56*H
todas=[amostra(ini+3*86400,60),amostra(agora-24*H,70),amostra(agora,78)]
s=u.semana(todas[-1],todas); ok("24h calmas sobem o limite (3)", s["semana_limite"]==3)
ok("ritmo de 24 h = 8%/dia", abs(s["semana_ritmo_pct_dia"]-8.0)<0.01)
# últimas 24 h intensas (20%): corta
todas=[amostra(agora-24*H,58),amostra(agora,78)]
ok("24h intensas cortam (1)", u.semana(todas[-1],todas)["semana_limite"]==1)
# sem amostra de 24 h atrás nesta semana: média desde o início
t2=ini+10*H; todas=[amostra(ini+H,1),amostra(t2,5)]
ok("início da semana: média", abs(u.semana(todas[-1],todas)["semana_ritmo_pct_dia"]-12.0)<0.01)
# amostra de outra semana não entra
todas=[{"ts":agora-24*H,"sete_dias":99,"reset_semana":reset-7*86400},amostra(agora,78)]
ok("outra semana ignorada", u.semana(todas[-1],todas)["semana_ritmo_pct_dia"]>0)
print("OK" if not falhas else "FALHOU"); sys.exit(falhas)
