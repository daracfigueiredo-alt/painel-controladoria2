"""Testes da 0037 (exceções de D-4, 11/11/2026). Banco LOCAL, dados FICTÍCIOS. Nenhuma chamada ao Atlas real.
Regra: D-4 = data de entrega do advogado; exceções (marcadas por líder ou controladoria, com justificativa)
podem ser entregues depois do D-4 e saem dos alertas de D-4 e do indicador "Críticas em D-4"."""
import json, subprocess, hashlib, os
PSQL = ["psql", "-h", "/tmp", "-p", "5433", "-U", "postgres", "-At", "-q", "-v", "ON_ERROR_STOP=1"]
HERE = os.path.dirname(os.path.abspath(__file__)); MIGDIR = os.path.join(HERE, "..", "supabase", "migrations")
MIG = sorted(os.path.join(MIGDIR, f) for f in os.listdir(MIGDIR)); DB = "ctrl_etapa12"; res = []
ADMIN = "00000000-0000-0000-0000-00000000000a"; COLAB = "00000000-0000-0000-0000-00000000000c"
LIDER = "00000000-0000-0000-0000-0000000000d1"
E1, E2, E3 = "e0000000-0000-4000-8000-0000000000e1", "e0000000-0000-4000-8000-0000000000e2", "e0000000-0000-4000-8000-0000000000e3"

def run(sql, uid=None):
    pre = f"set role authenticated; set request.jwt.claim.sub = '{uid}';\n" if uid else ""
    p = subprocess.run(PSQL + ["-d", DB], input=pre + sql, capture_output=True, text=True)
    return p.returncode, p.stdout.strip(), p.stderr.strip()
def q(sql, uid=None):
    c, o, e = run(sql, uid)
    if c: raise RuntimeError(sql[:300] + "\n" + e)
    return o
J = lambda sql, uid=ADMIN: json.loads(q(sql, uid))
def check(n, e, o): res.append((n, str(e), str(o), "OK" if str(e) == str(o) else "FALHA"))
def recusa(n, sql, uid, trecho):
    c, o, e = run(sql, uid); check(n, f"recusado ({trecho})", f"recusado ({trecho})" if c and trecho in e else f"aceito/outro: {e[:160]}")

subprocess.run(PSQL + ["-d", "postgres", "-c", f"drop database if exists {DB}", "-c", f"create database {DB}"], check=True, capture_output=True)
for f in [os.path.join(HERE, "00_stub_supabase_local.sql")] + MIG:
    subprocess.run(PSQL + ["-d", DB, "-f", f], check=True, capture_output=True)
q(f"""insert into colaboradores(nome_advbox, origem) values ('OUTRO','administrativo'),('Brenda Martins','administrativo');
  insert into auth.users (id, email) values ('{ADMIN}','a@x.invalid'),('{COLAB}','c@x.invalid'),('{LIDER}','l@x.invalid');
  insert into perfis values ('{ADMIN}','admin',null), ('{COLAB}','colaborador',(select id from colaboradores where nome_advbox='OUTRO')),
                            ('{LIDER}','lider',(select id from colaboradores where nome_advbox='Brenda Martins'));""")

# PF relativos a hoje (D-4 = PF - 3 dias úteis): vencido (D-4 há 2 dias úteis), hoje, próximo (amanhã útil)
pfs = {k: q(f"select somar_dias_uteis(hoje_brasilia(), {n})") for k, n in (("vencido", 1), ("hoje", 3), ("proximo", 4))}
pfs["agenda"] = q("select somar_dias_uteis(hoje_brasilia(), -6)")
nomes = {"11111111-1111-4111-8111-111111111111": "OUTRO"}
linhas = subprocess.run(["node", os.path.join(HERE, "atlas", "linhas_ficticias.mjs"), "d4", json.dumps(nomes), json.dumps(pfs)],
                        capture_output=True, text=True, check=True).stdout
h = hashlib.sha256(linhas.encode()).hexdigest()
s = J(f"select importar_arquivo('Atlas d4','{h}',$J${linhas}$J$::jsonb,null,now(),false)")
check("Sincronização fictícia: 3 tarefas", "3", s["validas"])
tar = lambda a: q(f"select id from tarefas where atlas_id = '{a}'")
cats = lambda uid=ADMIN: q("select coalesce(string_agg(categoria, ',' order by categoria), '') from v_alertas where categoria like 'd4%'", uid)
check("Sem exceção: os três alertas de D-4 aparecem", "d4_hoje,d4_proximo,d4_vencido_sem_entrega", cats())
check("Colaborador responsável vê os mesmos alertas", "d4_hoje,d4_proximo,d4_vencido_sem_entrega", cats(COLAB))
ind = lambda: q("select count(*) from indicadores_registros(hoje_brasilia() - 30, hoje_brasilia(), null, null, 'd4_criticas')")
check("Indicador Críticas em D-4 antes da exceção", "2", ind())

# ------------------------------------------------------------ permissões
recusa("Colaborador não marca exceção", f"select excecao_d4_definir({tar(E1)}, true, 'cliente pediu prazo maior')", COLAB, "Somente líderes")
recusa("Justificativa curta recusada", f"select excecao_d4_definir({tar(E1)}, true, 'curta')", LIDER, "mínimo")
recusa("Funções internas fechadas para o usuário", f"select _excecao_d4_situacao({tar(E1)})", LIDER, "permission denied")

# ------------------------------------------------------------ líder marca pela extensão (ID do Atlas)
st = J(f"select ext_excecao_d4('{E1}')", LIDER)
check("Consulta pela extensão: encontrada, sem exceção, líder pode definir", "True|False|True", f"{st['encontrada']}|{st['ativa']}|{st['pode_definir']}")
check("Consulta traz o D-4 calculado", q(f"select d4 from v_tarefas_atuais where tarefa_id={tar(E1)}"), st["d4"])
st = J(f"select ext_excecao_d4('{E1.upper()}', true, 'Cliente enviará documentos na véspera do prazo')", LIDER)
check("Líder marca exceção (ID em maiúsculas)", "True|Brenda Martins", f"{st['ativa']}|{st['por']}")
check("Exceção some do alerta de D-4 vencido", "d4_hoje,d4_proximo", cats())
check("Também para o colaborador (marcada pelo líder)", "d4_hoje,d4_proximo", cats(COLAB))
check("Indicador Críticas em D-4 desconta a exceção", "1", ind())
check("Evento registrado como exceção autorizada, origem extensão", "excecao_d4|excecao_autorizada|extensao|lider",
      q(f"select tipo||'|'||estado_trava||'|'||origem||'|'||(evidencia->>'papel') from eventos where tipo='excecao_d4'"))
J(f"select ext_excecao_d4('{E1}', true, 'Cliente enviará documentos na véspera do prazo')", LIDER)
check("Marcar de novo não duplica o evento", "1", q("select count(*) from eventos where tipo='excecao_d4'"))
st = J(f"select ext_excecao_d4('{E1}')", COLAB)
check("Colaborador vê a exceção mas não pode definir", "True|False", f"{st['ativa']}|{st['pode_definir']}")
check("Colaborador não consegue retirar", "recusado", "recusado" if run(f"select ext_excecao_d4('{E1}', false, 'retirando sem poder')", COLAB)[0] else "aceito")

# ------------------------------------------------------------ controladoria pelo painel
J(f"select excecao_d4_definir({tar(E2)}, true, 'Autorizado pela coordenação: perícia agendada')")
lst = J("select excecoes_d4_listar()", LIDER)
check("Lista de exceções ativas (líder)", "2", len(lst))
check("Lista traz compromisso e justificativa", "Prazo hoje|Autorizado pela coordenação: perícia agendada",
      next(f"{x['compromisso']}|{x['justificativa']}" for x in lst if x["id_externo"] == E2))
recusa("Colaborador não lista exceções", "select excecoes_d4_listar()", COLAB, "Somente líderes")
check("Alertas: só o D-4 próximo continua", "d4_proximo", cats())
J(f"select excecao_d4_definir({tar(E2)}, false, 'Perícia remarcada, volta ao prazo normal')", LIDER)
check("Retirar a exceção devolve o alerta", "d4_hoje,d4_proximo", cats())
check("Retirada também fica registrada (2 eventos na tarefa)", "2", q(f"select count(*) from eventos where tipo='excecao_d4' and tarefa_id={tar(E2)}"))
check("Lista de exceções ativas após retirar", "1", len(J("select excecoes_d4_listar()")))
check("Tarefa desconhecida na extensão", "False", J("select ext_excecao_d4('f0000000-0000-4000-8000-000000000000')", LIDER)["encontrada"])
check("PF Judicial continua valendo (alertas de PF não mudam com a exceção)", "1",
      q(f"select count(*) from v_alertas where tarefa_id={tar(E1)} and categoria like 'pf_judicial%'"))
check("Auditoria classifica o evento", "reagendamento", q("select _auditoria_categoria('excecao_d4')"))

ok = sum(1 for r in res if r[3] == "OK")
for r in res: print(("OK   " if r[3] == "OK" else "FALHA") + " | " + r[0] + ("" if r[3] == "OK" else f" | esperado={r[1]} obtido={r[2]}"))
print(f"\n{ok}/{len(res)} verificações OK")
raise SystemExit(0 if ok == len(res) else 1)
