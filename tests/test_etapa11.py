"""Testes da 0035 (Atlas Gestor como sistema principal, 11/11/2026). Banco LOCAL, dados FICTÍCIOS no
formato da documentação da API do Atlas (list_tasks). Nenhuma chamada ao Atlas real."""
import json, subprocess, hashlib, os, sys
PSQL = ["psql", "-h", "/tmp", "-p", "5433", "-U", "postgres", "-At", "-q", "-v", "ON_ERROR_STOP=1"]
HERE = os.path.dirname(os.path.abspath(__file__)); MIGDIR = os.path.join(HERE, "..", "supabase", "migrations")
MIG = sorted(os.path.join(MIGDIR, f) for f in os.listdir(MIGDIR)); DB = "ctrl_etapa11"; res = []
ADMIN = "00000000-0000-0000-0000-00000000000a"; COLAB = "00000000-0000-0000-0000-00000000000c"
LIDER = "00000000-0000-0000-0000-0000000000d1"; SEMPERFIL = "00000000-0000-0000-0000-0000000000ff"
TA, TB, TC, TD = ("aaaaaaaa-0000-4000-8000-00000000000a", "bbbbbbbb-0000-4000-8000-00000000000b",
                  "cccccccc-0000-4000-8000-00000000000c", "dddddddd-0000-4000-8000-00000000000d")
TNOVA = "eeeeeeee-0000-4000-8000-00000000000e"

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
node = lambda *a: subprocess.run(["node", os.path.join(HERE, "atlas", "linhas_ficticias.mjs"), *a], capture_output=True, text=True, check=True).stdout
def sincronizar(cen, nomes, lote=None):
    linhas = node(cen, json.dumps(nomes)); h = hashlib.sha256((cen + linhas).encode()).hexdigest()
    return J(f"select importar_arquivo($N$Atlas {cen}$N$,'{h}',$J${linhas}$J$::jsonb,{lote or 'null'},now(),false)")
tar = lambda atlas: q(f"select coalesce(unificada_em,id) from tarefas where atlas_id = '{atlas}'")

subprocess.run(PSQL + ["-d", "postgres", "-c", f"drop database if exists {DB}", "-c", f"create database {DB}"], check=True, capture_output=True)
for f in [os.path.join(HERE, "00_stub_supabase_local.sql")] + MIG:
    subprocess.run(PSQL + ["-d", DB, "-f", f], check=True, capture_output=True)
q(f"""insert into colaboradores(nome_advbox, origem) values ('ANA TESTE','administrativo'),('Brenda Martins','administrativo'),('OUTRO','administrativo');
  insert into auth.users (id, email) values ('{ADMIN}','a@x.invalid'),('{COLAB}','c@x.invalid'),('{LIDER}','l@x.invalid');
  insert into perfis values ('{ADMIN}','admin',null), ('{COLAB}','colaborador',(select id from colaboradores where nome_advbox='OUTRO'));""")

# ------------------------------------------------------------ usuários do Atlas
usuarios = node("usuarios")
nomes = J(f"select atlas_mapear_usuarios($J${usuarios}$J$::jsonb)")
check("Usuário do Atlas casado com colaborador existente (acento/maiúsculas): Ana Teste -> ANA TESTE", "ANA TESTE", nomes["11111111-1111-4111-8111-111111111111"])
check("Brenda (BRENDA MARTINS no Atlas) casada com 'Brenda Martins'", "Brenda Martins", nomes["33333333-3333-4333-8333-333333333333"])
check("Usuário sem correspondente vira colaborador de origem atlas", "atlas", q("select origem from colaboradores where nome_advbox='Bruno Teste'"))
check("Mapeamento repetido não duplica colaboradores (3 cadastrados + Bruno)", "4", (J(f"select atlas_mapear_usuarios($J${usuarios}$J$::jsonb)"), q("select count(*) from colaboradores"))[1])
recusa("Colaborador não chama a integração", f"select atlas_mapear_usuarios('[]')", COLAB, "Somente")
recusa("Colaborador não usa a API do Atlas", "select atlas_conferir_acesso('sincronizar')", COLAB, "Somente")

# ------------------------------------------------------------ extensão abre tarefa do Atlas antes da sincronização
J(f"select ext_status_tarefa('{TA.upper()}', '{{\"titulo\":\"Contestar\"}}')")
pre = tar(TA)
# ------------------------------------------------------------ 1ª sincronização
s1 = sincronizar("s1", nomes)
check("1ª sincronização: 4 tarefas, 0 rejeitadas", "4|0", f"{s1['validas']}|{s1['rejeitadas']}")
check("1ª sincronização: 3 novas e 1 já conhecida (a aberta antes pela extensão)", "3|1", f"{s1['tarefas_novas']}|{s1['tarefas_ja_conhecidas']}")
check("ID do Atlas gravado nas tarefas novas", "0", q("select count(*) from tarefas where metodo='atlas_id' and (atlas_id is null or advbox_id is null)"))
check("Lote marcado como Atlas", "atlas", q(f"select origem from lotes_importacao where id={s1['lote_id']}"))
check("Tarefa aberta na extensão (ID em maiúsculas) é a mesma da sincronização", pre, tar(TA))
check("Vínculo pelo ID do Atlas (sem ambiguidade)", "atlas_id|4", q(f"select string_agg(distinct metodo_vinculo, ','), count(*) from linhas_importadas where lote_id={s1['lote_id']}").replace('|', '|'))
check("Prazo fatal do Atlas vira PF Judicial (D-4 calculado)", "2026-11-25|calculado_regra",
      q(f"select pf_judicial||'|'||d4_origem from v_tarefas_atuais where tarefa_id={tar(TA)}"))
check("PF anotado na descrição prevalece sobre o do Atlas", "2026-11-28", q(f"select pf_judicial from v_tarefas_atuais where tarefa_id={tar(TC)}"))
check("Tarefa sem responsável no Atlas fica com 'SEM RESPONSÁVEL (ATLAS)'", "SEM RESPONSÁVEL (ATLAS)", q(f"select responsavel from v_tarefas_atuais where tarefa_id={tar(TD)}"))

# ------------------------------------------------------------ 2ª sincronização (mudanças no Atlas)
s2 = sincronizar("s2", nomes)
check("2ª sincronização: as 4 já conhecidas, nenhuma nova", "4|0", f"{s2['tarefas_ja_conhecidas']}|{s2['tarefas_novas']}")
ev = lambda t, tipo: q(f"select count(*) from eventos e join tarefas x on x.id=e.tarefa_id where coalesce(x.unificada_em,x.id)={tar(t)} and e.tipo='{tipo}'")
check("Mudança de data no Atlas detectada", "1", ev(TA, "alteracao_data_agenda"))
check("Troca de responsável no Atlas detectada", "1", ev(TA, "alteracao_responsavel"))
check("Mudança de prazo fatal no Atlas detectada", "1", ev(TB, "alteracao_pf_tarefa"))
check("Conclusão no Atlas registrada", "1", ev(TC, "conclusao"))
check("Tarefa repetida entre consultas entra uma vez", "4", q(f"select count(*) from linhas_importadas where lote_id={s2['lote_id']}"))

# ------------------------------------------------------------ líderes
q(f"insert into perfis values ('{LIDER}','lider',(select id from colaboradores where nome_advbox='Brenda Martins'))")
m = J(f"select ext_status_tarefa('{TA}', '{{}}')", LIDER)["modos"]
check("Líder: realocação e prazo fatal livres na extensão", "lider_livre|lider_livre", f"{m['realocacao']}|{m['pf']}")
check("Líder: trava de conclusão continua", "bloquear", m["conclusao"])
m2 = J(f"select ext_status_tarefa('{TA}', '{{}}')", COLAB)["modos"]
check("Colaborador: travas normais (valor do parâmetro)", q("select valor #>> '{}' from parametros where chave='trava_realocacao_modo'"), m2["realocacao"])
evl = J(f"select ext_registrar_evento(gen_random_uuid(), 'tentativa_realocacao', '{TA}', '{{}}', 'excecao_autorizada', null)", LIDER)
check("Líder altera data sem justificativa: registrado como exceção autorizada", "excecao_autorizada", evl["estado_trava"])
recusa("Líder não pula a trava de conclusão", f"select ext_registrar_evento(gen_random_uuid(), 'tentativa_conclusao', '{TA}', '{{}}', 'excecao_autorizada', null)", LIDER, "Somente")
recusa("Colaborador não declara exceção autorizada", f"select ext_registrar_evento(gen_random_uuid(), 'tentativa_realocacao', '{TA}', '{{}}', 'excecao_autorizada', null)", COLAB, "Somente")
check("Inícios por IDs aceita ID do Atlas", "True", TA in J(f"select ext_inicios_por_ids(array['{TA}'])", LIDER)["inicios"])
recusa("ID de tarefa em formato inválido é recusado", "select ext_status_tarefa('abc', '{}')", ADMIN, "inválido")
recusa("Papel líder exige colaborador vinculado", f"select admin_definir_perfil('{COLAB}','lider',null,'definindo líder de teste')", ADMIN, "obrigatório")
check("Painel define papel líder", "lider", J(f"select admin_definir_perfil('{COLAB}','lider',(select id from colaboradores where nome_advbox='OUTRO'),'definindo líder de teste')")["papel"])

# ------------------------------------------------------------ tarefas de análise pela API do Atlas
TT = J("select analise_preparar_teste('TESTE 1.0', 'teste atlas')")["id"]
J(f"select analise_decidir({TT}, 'aprovar', 'ok')")
check("Com destino Atlas, a extensão não pega tarefa de análise para criar no ADVBOX", "None|atlas",
      (lambda f: f"{f.get('proxima')}|{f.get('destino')}")(J("select ext_analise_fila()")))
d = J(f"select analise_dados_para_atlas({TT})")
check("Corpo do create_task: responsável pelo e-mail e chave de idempotência", "mayra.gomes.oecadv@gmail.com|True",
      f"{d['payload']['assigneeEmail']}|{d['idempotencia'].startswith('controladoria-analise-')}")
recusa("Não cria duas vezes a mesma (já em andamento)", f"select analise_dados_para_atlas({TT})", ADMIN, "não permitida")
f = J(f"select analise_falha_atlas({TT}, 'campo inválido', 'validation_error')")
check("Erro de validação do Atlas: volta para aprovada (certeza de que não criou)", "aprovada", f["status"])
d = J(f"select analise_dados_para_atlas({TT})")
check("Nova tentativa numerada", "2", d["tentativa"])
c = J(f"select analise_confirmar_atlas({TT}, 2, '{{\"success\":true,\"taskId\":\"{TNOVA}\",\"appUrl\":\"https://gestor.atlasjus.com/#/tasks?task=x\",\"warnings\":[]}}')")
check("Confirmação grava o ID da tarefa criada no Atlas", f"criada|{TNOVA}", f"{c['status']}|{q(f'select atlas_tarefa_id from tarefas_analise where id={TT}')}")
recusa("Colaborador não cria tarefa no Atlas", f"select analise_dados_para_atlas({TT})", COLAB, "Somente")
recusa("Sem perfil não chama nada", "select atlas_conferir_acesso('testar')", SEMPERFIL, "Somente")

for n, e, o, s in res: print(f"{s:5} {n}" + ("" if s == "OK" else f"\n      esperado={e}\n      obtido  ={o}"))
ok = sum(r[3] == "OK" for r in res); print(f"\n{ok}/{len(res)} OK"); sys.exit(0 if ok == len(res) else 1)
