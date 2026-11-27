"""Testes da migração 0064 (intimações: arquivo e processos não cadastrados, 27/11/2026). Banco LOCAL, dados FICTÍCIOS.
A migração foi escrita no computador da Dara e já está aplicada no Supabase; aqui se confere que ela roda sobre as
migrações do repositório, que arquivar/desarquivar funciona e quem pode usar cada função."""
import json, subprocess, os
PSQL = ["psql", "-h", os.environ.get("PGHOST", "/tmp"), "-p", os.environ.get("PGPORT", "5433"), "-U", "postgres", "-At", "-q", "-v", "ON_ERROR_STOP=1"]
HERE = os.path.dirname(os.path.abspath(__file__)); MIGDIR = os.path.join(HERE, "..", "supabase", "migrations")
MIG = sorted(os.path.join(MIGDIR, f) for f in os.listdir(MIGDIR)); DB = "ctrl_etapa21"; res = []
ADMIN = "00000000-0000-0000-0000-00000000000a"; COLAB = "00000000-0000-0000-0000-00000000000c"
DIRET = "00000000-0000-0000-0000-0000000000d1"; LIDER = "00000000-0000-0000-0000-0000000000b1"

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
    ('{DIRET}','marianacamiloadv@gmail.com'),('{LIDER}','brendamartinsoecadv@gmail.com');
  insert into perfis values ('{ADMIN}','admin',null),('{COLAB}','colaborador',(select id from colaboradores where nome_advbox='OUTRO'));
  insert into cnj_comunicacoes (id, cnj, data_disponibilizacao, texto, dados) values (900001,'0000001-65.2026.8.13.0024',hoje_brasilia()-1,'Intimação fictícia 1','{{}}'::jsonb),(900002,'0000002-50.2026.8.13.0024',hoje_brasilia()-1,'Intimação fictícia 2','{{}}'::jsonb),(900003,'0000003-35.2026.8.13.0024',hoje_brasilia()-1,'Intimação fictícia 3','{{}}'::jsonb);""")

check("Parâmetro do cadastro automático começa desligado", "false", q("select valor #>> '{}' from parametros where chave = 'cnj_cadastro_automatico'"))
painel = lambda uid=ADMIN, f="null": json.loads(q(f"select cnj_painel(null, null, null, {f})", uid))
check("Painel: 3 pendentes, 0 arquivadas", "3|0", f"{len(painel()['itens'])}|{painel()['arquivadas_periodo']}")

r = json.loads(q("select cnj_arquivar(array[900001, 900002]::bigint[], 'Tratadas na audiência')", ADMIN))
check("Arquivar 2 intimações", 2, r["arquivadas"])
check("Painel: 1 pendente, 2 arquivadas", "1|2", f"{len(painel()['itens'])}|{painel()['arquivadas_periodo']}")
arq = painel(f="'arquivadas'")["itens"]
check("Lista das arquivadas traz motivo e quem arquivou", "2|Tratadas na audiência|admin@x.invalid",
      f"{len(arq)}|{arq[0]['arquivada']['motivo']}|{arq[0]['arquivada']['por']}")
check("Arquivar de novo não conta duas vezes", 0, json.loads(q("select cnj_arquivar(array[900001]::bigint[])", ADMIN))["arquivadas"])
check("Desarquivar 1", 1, json.loads(q("select cnj_desarquivar(array[900002]::bigint[])", ADMIN))["desarquivadas"])
check("Histórico do arquivo: arquivar e desarquivar", "arquivar,desarquivar", q("select string_agg(acao, ',' order by id) from cnj_arquivo_eventos"))
recusa("Histórico do arquivo é imutável", "delete from cnj_arquivo_eventos", None, "")
recusa("Motivo com mais de 500 caracteres", f"select cnj_arquivar(array[900003]::bigint[], repeat('x', 501))", ADMIN, "Motivo muito longo")
recusa("Lista vazia", "select cnj_arquivar(array[]::bigint[])", ADMIN, "Escolha as intimações")

for nome, uid in [("Peticionador", COLAB), ("Líder", LIDER), ("Diretoria", DIRET)]:
    recusa(f"{nome} não arquiva", "select cnj_arquivar(array[900003]::bigint[])", uid, "Somente a controladoria")
    recusa(f"{nome} não roda a detecção", "select cnj_cadastro_detectar()", uid, "Somente a controladoria")
check("Diretoria vê os processos não cadastrados (só leitura)", "True", "total" in json.loads(q("select cnj_nao_cadastrados()", DIRET))["contagem"])
recusa("Peticionador não vê os processos não cadastrados", "select cnj_nao_cadastrados()", COLAB, "Somente a controladoria e a diretoria")
recusa("Função interna fechada ao usuário", "select _cnj_cadastro_detectar()", ADMIN, "permission denied")
check("Diretoria vê as entregas autorizadas após o D-4", "[]", q("select excecoes_d4_listar()", DIRET))

d = json.loads(q("select cnj_cadastro_detectar()", ADMIN))
check("Detecção: 3 processos com intimação fora do Atlas, sem cliente", "3|0|False",
      f"{d['novos']}|{d['aprovados_automaticamente']}|{d['automatico_ligado']}")
n = json.loads(q("select cnj_nao_cadastrados()", ADMIN))
check("Processos não cadastrados: 3 aguardando cliente", "3|3", f"{n['contagem']['total']}|{n['contagem']['aguardando_cliente']}")

for n_, e, o, s in res: print(f"[{s}] {n_}" + ("" if s == "OK" else f"\n    esperado: {e}\n    obtido:   {o}"))
falhas = sum(1 for r in res if r[3] != "OK"); print(f"\n{len(res) - falhas}/{len(res)} verificações OK")
if not os.environ.get("MANTER"): subprocess.run(PSQL + ["-d", "postgres", "-c", f"drop database {DB}"], capture_output=True)
raise SystemExit(1 if falhas else 0)
