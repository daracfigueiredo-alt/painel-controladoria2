"""Testes da migração 0061 (acessos dos líderes e da diretoria, 24/11/2026). Banco LOCAL, dados FICTÍCIOS.
A conta criada no Auth com um e-mail previsto recebe o perfil sozinha; perfil existente nunca é sobrescrito."""
import json, subprocess, os
PSQL = ["psql", "-h", os.environ.get("PGHOST", "/tmp"), "-p", os.environ.get("PGPORT", "5433"), "-U", "postgres", "-At", "-q", "-v", "ON_ERROR_STOP=1"]
HERE = os.path.dirname(os.path.abspath(__file__)); MIGDIR = os.path.join(HERE, "..", "supabase", "migrations")
MIG = sorted(os.path.join(MIGDIR, f) for f in os.listdir(MIGDIR)); DB = "ctrl_etapa19"; res = []
ADMIN = "00000000-0000-0000-0000-00000000000a"; COLAB = "00000000-0000-0000-0000-00000000000c"
BRENDA = "00000000-0000-0000-0000-0000000000b1"; RAQUEL = "00000000-0000-0000-0000-0000000000b2"
MARIANA = "00000000-0000-0000-0000-0000000000d1"; BARBARA = "00000000-0000-0000-0000-0000000000d2"
PEDRO = "00000000-0000-0000-0000-0000000000b4"; ESTRANHO = "00000000-0000-0000-0000-0000000000ff"

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
perfil = lambda u: q(f"select coalesce((select papel || '|' || coalesce((select nome_advbox from colaboradores where id = colaborador_id), '-') from perfis where user_id = '{u}'), 'sem perfil')")
equipes = lambda u: q(f"select coalesce(string_agg(e.nome, ',' order by e.nome), '-') from lideres_equipes le join equipes e on e.id = le.equipe_id where le.user_id = '{u}'")

subprocess.run(PSQL + ["-d", "postgres", "-c", f"drop database if exists {DB}", "-c", f"create database {DB}"], check=True, capture_output=True)
subprocess.run(PSQL + ["-d", DB, "-f", os.path.join(HERE, "00_stub_supabase_local.sql")], check=True, capture_output=True)
# conta da Raquel criada ANTES da migração (a migração aplica no fim)
for f in MIG:
    if os.path.basename(f).startswith("0061"):
        q("""insert into equipes(nome) values ('Prime'),('Gold'),('Celeste'),('Êxitos'),('Delta') on conflict do nothing;
             insert into colaboradores(nome_advbox, origem) values ('BRENDA MARTINS','administrativo'),('Raquel Guerra','administrativo'),('OUTRO','administrativo');""")
        q(f"""insert into auth.users (id, email) values ('{ADMIN}','admin@x.invalid'),('{COLAB}','c@x.invalid'),('{RAQUEL}','RaquelGuerraOecadv@gmail.com');
              insert into perfis values ('{ADMIN}','admin',null),('{COLAB}','colaborador',(select id from colaboradores where nome_advbox='OUTRO'));""")
    subprocess.run(PSQL + ["-d", DB, "-f", f], check=True, capture_output=True)

check("9 acessos previstos (6 líderes, 3 diretoria)", "diretoria:3|lider:6",
      q("select string_agg(papel || ':' || n, '|' order by papel) from (select papel, count(*) n from acessos_previstos group by papel) s"))
check("Conta já existente (Raquel, e-mail em maiúsculas) recebe o acesso na migração", "lider|Raquel Guerra", perfil(RAQUEL))
check("Raquel liga à equipe Gold", "Gold", equipes(RAQUEL))

# contas novas: o gatilho aplica sozinho
q(f"""insert into auth.users (id, email) values ('{BRENDA}','brendamartinsoecadv@gmail.com'),('{MARIANA}','marianacamiloadv@gmail.com'),
        ('{PEDRO}','pedrofrejahoecadv@gmail.com'),('{ESTRANHO}','estranho@x.invalid')""")
check("Brenda: líder, colaborador achado sem diferenciar maiúsculas", "lider|BRENDA MARTINS", perfil(BRENDA))
check("Brenda liga à equipe Prime", "Prime", equipes(BRENDA))
check("Mariana: diretoria", "diretoria|-", perfil(MARIANA))
check("Pedro: líder sem colaborador cadastrado (fica para ligar depois)", "lider|-", perfil(PEDRO))
check("Pedro liga à equipe Êxitos (acento)", "Êxitos", equipes(PEDRO))
check("Observação do Pedro avisa do colaborador", "t", q("select observacao like '%Colaborador de mesmo nome%' from acessos_previstos where email='pedrofrejahoecadv@gmail.com'"))
check("E-mail não previsto não ganha perfil", "sem perfil", perfil(ESTRANHO))
check("Criação registrada na auditoria com motivo", "t",
      q(f"select bool_and(motivo like 'Acesso previsto na 0061%') from auditoria_configuracao where tabela='perfis' and chave in ('{BRENDA}','{MARIANA}','{PEDRO}','{RAQUEL}')"))

# perfil existente nunca é sobrescrito (Bárbara já era admin, por exemplo)
q(f"insert into perfis values ('{BARBARA}','admin',null)")
q(f"insert into auth.users (id, email) values ('{BARBARA}','barbaracastrooecadv@gmail.com')")
check("Perfil existente não é trocado", "admin|-", perfil(BARBARA))
check("…e a observação registra", "t", q("select observacao like 'A conta já tinha perfil (admin)%' from acessos_previstos where email='barbaracastrooecadv@gmail.com'"))

# função da controladoria
r = json.loads(q("select admin_aplicar_acessos_previstos()", ADMIN))
sit = {x["email"]: x["situacao"] for x in r}
check("Painel: Brenda com acesso criado", "acesso criado", sit["brendamartinsoecadv@gmail.com"])
check("Painel: Guilherme aguardando a conta", "aguardando a conta no Supabase", sit["guilhermeladeiaoecadv@gmail.com"])
check("Painel: Bárbara com conta e observação", "conta existe; ver observação", sit["barbaracastrooecadv@gmail.com"])
recusa("Colaborador não usa a função", "select admin_aplicar_acessos_previstos()", COLAB, "Somente administradores")
recusa("Colaborador não chama a função interna", f"select _aplicar_acesso_previsto('{ESTRANHO}')", COLAB, "permission denied")
check("Colaborador não lê a lista de acessos", "0", q("select count(*) from acessos_previstos", COLAB))
check("Mariana (diretoria) não lê a lista de acessos", "0", q("select count(*) from acessos_previstos", MARIANA))
recusa("E-mail inválido é recusado", "insert into acessos_previstos (email, nome, papel) values ('pedrofrejá@oecadv.gmail.com','X','diretoria')", None, "acessos_previstos_email_check")

# a Mariana enxerga como diretoria; a Brenda vê só o que é dela (sem acesso de controladoria)
check("Diretoria: pode_ler_tudo", "t", q("select pode_ler_tudo()", MARIANA))
check("Líder: não é admin", "f", q("select is_admin()", BRENDA))

for n, e, o, s in res: print(f"[{s}] {n}" + ("" if s == "OK" else f"\n    esperado: {e}\n    obtido:   {o}"))
falhas = sum(1 for r in res if r[3] != "OK"); print(f"\n{len(res) - falhas}/{len(res)} verificações OK")
if not os.environ.get("MANTER"): subprocess.run(PSQL + ["-d", "postgres", "-c", f"drop database {DB}"], capture_output=True)
raise SystemExit(1 if falhas else 0)
