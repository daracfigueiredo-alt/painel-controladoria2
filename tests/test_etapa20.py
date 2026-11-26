"""Testes da migração 0062 (senha definida pela controladoria, 26/11/2026). Banco LOCAL, dados FICTÍCIOS.
A troca de senha em si é feita pela Edge Function admin-senha (tests/admin/testar_senha.mjs); aqui fica a
conferência do perfil, o motivo obrigatório e o registro no histórico."""
import json, subprocess, os
PSQL = ["psql", "-h", os.environ.get("PGHOST", "/tmp"), "-p", os.environ.get("PGPORT", "5433"), "-U", "postgres", "-At", "-q", "-v", "ON_ERROR_STOP=1"]
HERE = os.path.dirname(os.path.abspath(__file__)); MIGDIR = os.path.join(HERE, "..", "supabase", "migrations")
MIG = sorted(os.path.join(MIGDIR, f) for f in os.listdir(MIGDIR)); DB = "ctrl_etapa20"; res = []
ADMIN = "00000000-0000-0000-0000-00000000000a"; COLAB = "00000000-0000-0000-0000-00000000000c"
LIDER = "00000000-0000-0000-0000-0000000000b1"; DIRET = "00000000-0000-0000-0000-0000000000d1"
SEM = "00000000-0000-0000-0000-0000000000ee"

def run(sql, uid=None):
    pre = f"set role authenticated; set request.jwt.claim.sub = '{uid}';\n" if uid else ""
    p = subprocess.run(PSQL + ["-d", DB], input=pre + sql, capture_output=True, text=True)
    return p.returncode, p.stdout.strip(), p.stderr.strip()
def q(sql, uid=None):
    c, o, e = run(sql, uid)
    if c: raise RuntimeError(sql[:300] + "\n" + e)
    return o.split("\n")[-1] if o else o
def check(n, e, o): res.append((n, str(e), str(o), "OK" if str(e) == str(o) else "FALHA"))
def recusa(n, sql, uid, trecho):
    c, o, e = run(sql, uid); check(n, f"recusado ({trecho})", f"recusado ({trecho})" if c and trecho in e else f"aceito/outro: {(o or e)[:200]}")

subprocess.run(PSQL + ["-d", "postgres", "-c", f"drop database if exists {DB}", "-c", f"create database {DB}"], check=True, capture_output=True)
for f in [os.path.join(HERE, "00_stub_supabase_local.sql")] + MIG:
    subprocess.run(PSQL + ["-d", DB, "-f", f], check=True, capture_output=True)
q(f"""insert into colaboradores(nome_advbox, origem) values ('OUTRO','administrativo');
  insert into auth.users (id, email) values ('{ADMIN}','admin@x.invalid'),('{COLAB}','c@x.invalid'),
    ('{LIDER}','brendamartinsoecadv@gmail.com'),('{DIRET}','marianacamiloadv@gmail.com'),('{SEM}','sem@x.invalid');
  insert into perfis values ('{ADMIN}','admin',null),('{COLAB}','colaborador',(select id from colaboradores where nome_advbox='OUTRO'));""")
check("Contas dos acessos previstos ganharam perfil (0061)", "lider|diretoria",
      q(f"select (select papel from perfis where user_id='{LIDER}') || '|' || (select papel from perfis where user_id='{DIRET}')"))

antes = int(q("select count(*) from eventos"))
r = json.loads(q(f"select admin_registrar_alteracao_senha('{LIDER}', 'Primeiro acesso da líder da Prime')", ADMIN))
check("Controladoria: pedido aceito e devolve o e-mail", "brendamartinsoecadv@gmail.com", r["email"])
ev = json.loads(q("select evidencia from eventos where evidencia->>'operacao' = 'alterar_senha'"))
check("Histórico: um evento novo", antes + 1, q("select count(*) from eventos"))
check("Histórico: operação, conta, motivo e quem fez", f"alterar_senha|{LIDER}|Primeiro acesso da líder da Prime|{ADMIN}",
      f"{ev['operacao']}|{ev['conta']}|{ev['motivo']}|{ev['usuario']}")
check("Histórico: nenhuma senha gravada", "False", str(any("senha" in k for k in ev.keys())))
check("Evento classificado como administrativo", "administrativo", q("select _auditoria_categoria(tipo) from eventos where evidencia->>'operacao' = 'alterar_senha'"))

recusa("Motivo curto é recusado", f"select admin_registrar_alteracao_senha('{LIDER}', 'curto')", ADMIN, "Informe o motivo")
recusa("Conta inexistente é recusada", "select admin_registrar_alteracao_senha('00000000-0000-0000-0000-000000000999', 'Motivo suficiente aqui')", ADMIN, "Usuário inexistente")
for nome, uid in [("Peticionador", COLAB), ("Líder", LIDER), ("Diretoria", DIRET), ("Conta sem perfil", SEM)]:
    recusa(f"{nome} não troca senha", f"select admin_registrar_alteracao_senha('{ADMIN}', 'Tentativa de trocar a senha')", uid, "Somente a controladoria")
c, o, e = run(f"set role anon; select admin_registrar_alteracao_senha('{LIDER}', 'Tentativa sem login no painel')")
check("Sem login (anon) não chama a função", "recusado", "recusado" if c and "permission denied" in e else f"aceito/outro: {(o or e)[:200]}")
c, o, e = run(f"select admin_registrar_alteracao_senha('{LIDER}', 'Chave de serviço sem pessoa')")
check("Sem pessoa logada (chave de serviço, rotina) não troca senha", "recusado", "recusado" if c and "Somente a controladoria" in e else f"aceito/outro: {(o or e)[:200]}")
check("Recusas não deixam registro", antes + 1, q("select count(*) from eventos"))

for n, e, o, s in res: print(f"[{s}] {n}" + ("" if s == "OK" else f"\n    esperado: {e}\n    obtido:   {o}"))
falhas = sum(1 for r in res if r[3] != "OK"); print(f"\n{len(res) - falhas}/{len(res)} verificações OK")
if not os.environ.get("MANTER"): subprocess.run(PSQL + ["-d", "postgres", "-c", f"drop database {DB}"], capture_output=True)
raise SystemExit(1 if falhas else 0)
