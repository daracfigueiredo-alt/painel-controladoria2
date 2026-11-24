"""Testes da migração 0058 (decisões da controladoria de 17/11/2026). Banco LOCAL, dados FICTÍCIOS.
1) conclusão de tarefa do Atlas com justificativa (servidor + rede de segurança no double check);
2) tarefa "em andamento" no Atlas = início da tratativa (sincronização);
3) reagendamento pedido pelo peticionador: até o D-4 o líder decide; depois do D-4, só a controladoria."""
import json, subprocess, hashlib, os, uuid
PSQL = ["psql", "-h", "/tmp", "-p", "5433", "-U", "postgres", "-At", "-q", "-v", "ON_ERROR_STOP=1"]
HERE = os.path.dirname(os.path.abspath(__file__)); MIGDIR = os.path.join(HERE, "..", "supabase", "migrations")
MIG = sorted(os.path.join(MIGDIR, f) for f in os.listdir(MIGDIR)); DB = "ctrl_etapa18"; res = []
ADMIN = "00000000-0000-0000-0000-00000000000a"; COLAB = "00000000-0000-0000-0000-00000000000c"
LIDER = "00000000-0000-0000-0000-0000000000d1"; LIDER_B = "00000000-0000-0000-0000-0000000000d2"
PEDRO_U = "00000000-0000-0000-0000-0000000000e2"
U_OUTRO, U_PEDRO = "11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222"

def run(sql, uid=None):
    pre = f"set role authenticated; set request.jwt.claim.sub = '{uid}';\n" if uid else ""
    p = subprocess.run(PSQL + ["-d", DB], input=pre + sql, capture_output=True, text=True)
    return p.returncode, p.stdout.strip(), p.stderr.strip()
def q(sql, uid=None):
    c, o, e = run(sql, uid)
    if c: raise RuntimeError(sql[:300] + "\n" + e)
    return o.split("\n")[-1] if o else o
J = lambda sql, uid=ADMIN: json.loads(q(sql, uid))
def check(n, e, o): res.append((n, str(e), str(o), "OK" if str(e) == str(o) else "FALHA"))
def recusa(n, sql, uid, trecho):
    c, o, e = run(sql, uid); check(n, f"recusado ({trecho})", f"recusado ({trecho})" if c and trecho in e else f"aceito/outro: {(o or e)[:200]}")

subprocess.run(PSQL + ["-d", "postgres", "-c", f"drop database if exists {DB}", "-c", f"create database {DB}"], check=True, capture_output=True)
for f in [os.path.join(HERE, "00_stub_supabase_local.sql")] + MIG:
    subprocess.run(PSQL + ["-d", DB, "-f", f], check=True, capture_output=True)
q(f"""insert into equipes(nome) values ('Equipe A'),('Equipe B');
  insert into colaboradores(nome_advbox, origem, equipe_id) values ('OUTRO','administrativo',(select id from equipes where nome='Equipe A')),
    ('Brenda Martins','administrativo',(select id from equipes where nome='Equipe A')),('PEDRO','administrativo',(select id from equipes where nome='Equipe B')),
    ('Raquel Guerra','administrativo',(select id from equipes where nome='Equipe B'));
  insert into auth.users (id, email) values ('{ADMIN}','a@x.invalid'),('{COLAB}','c@x.invalid'),('{LIDER}','l@x.invalid'),('{LIDER_B}','lb@x.invalid'),('{PEDRO_U}','p@x.invalid');
  insert into perfis values ('{ADMIN}','admin',null), ('{COLAB}','colaborador',(select id from colaboradores where nome_advbox='OUTRO')),
    ('{LIDER}','lider',(select id from colaboradores where nome_advbox='Brenda Martins')),
    ('{LIDER_B}','lider',(select id from colaboradores where nome_advbox='Raquel Guerra')),
    ('{PEDRO_U}','colaborador',(select id from colaboradores where nome_advbox='PEDRO'));""")
J(f"select admin_definir_lider_equipes('{LIDER}', array[(select id from equipes where nome='Equipe A')], 'Brenda lidera a equipe A')")
J(f"select admin_definir_lider_equipes('{LIDER_B}', array[(select id from equipes where nome='Equipe B')], 'Raquel lidera a equipe B')")
lit = lambda o: "$J$" + json.dumps(o, ensure_ascii=False) + "$J$::jsonb"
J(f"select atlas_mapear_usuarios({lit([{'id': U_OUTRO, 'name': 'OUTRO'}, {'id': U_PEDRO, 'name': 'PEDRO'}])})")
OUTRO = q("select id from colaboradores where nome_advbox='OUTRO'")

# ------------------------------------------------------------ base fictícia (datas relativas a hoje)
du = lambda n: q(f"select somar_dias_uteis(hoje_brasilia(), {n})")
HOJE = q("select hoje_brasilia()")
resp = lambda u, n, c=None: [{"user_id": u, "name": n, "is_principal": True, "completed_at": c}]
ha_1h = q("select to_char((now() - interval '1 hour') at time zone 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"')")
T = {k: f"b0000000-0000-4000-8000-0000000000{i:02d}" for i, k in enumerate(
    ["semd4", "d4longe", "d4passou", "andamento", "concl_sem", "concl_com", "pedro", "escalar", "lider2"], start=1)}
tarefas = [
  {"id": T["semd4"], "title": "Manifestar sobre documentos", "due_date": du(1), "fatal_date": None, "assignees": resp(U_OUTRO, "OUTRO")},
  {"id": T["d4longe"], "title": "Contestar ação revisional", "due_date": du(1), "fatal_date": du(12), "assignees": resp(U_OUTRO, "OUTRO")},
  {"id": T["d4passou"], "title": "Embargos de declaração", "due_date": HOJE, "fatal_date": du(2), "assignees": resp(U_OUTRO, "OUTRO")},
  {"id": T["andamento"], "title": "Réplica", "status": "doing", "due_date": du(2), "fatal_date": None, "assignees": resp(U_OUTRO, "OUTRO")},
  {"id": T["concl_sem"], "title": "Petição simples (sem justificativa)", "status": "done", "due_date": HOJE, "fatal_date": None,
   "assignees": resp(U_OUTRO, "OUTRO", ha_1h), "updated_at": ha_1h},
  {"id": T["concl_com"], "title": "Petição simples (com justificativa)", "status": "done", "due_date": HOJE, "fatal_date": None,
   "assignees": resp(U_OUTRO, "OUTRO", ha_1h), "updated_at": ha_1h},
  {"id": T["pedro"], "title": "Apelação do banco", "due_date": du(1), "fatal_date": du(15), "assignees": resp(U_PEDRO, "PEDRO")},
  {"id": T["escalar"], "title": "Impugnação", "due_date": du(1), "fatal_date": du(10), "assignees": resp(U_OUTRO, "OUTRO")},
  {"id": T["lider2"], "title": "Memoriais", "due_date": du(1), "fatal_date": du(10), "assignees": resp(U_OUTRO, "OUTRO")},
]
linhas = subprocess.run(["node", os.path.join(HERE, "atlas", "linhas_ficticias.mjs"), "json", json.dumps({U_OUTRO: "OUTRO", U_PEDRO: "PEDRO"}), json.dumps(tarefas)],
                        capture_output=True, text=True, check=True).stdout
s = J(f"select importar_arquivo('Atlas e18','{hashlib.sha256(linhas.encode()).hexdigest()}',$J${linhas}$J$::jsonb,null,now(),false)")
check("Base fictícia: 9 tarefas do Atlas", "9", s["validas"])
LOTE = s["lote_id"]
tar = lambda k: q(f"select id from tarefas where atlas_id = '{T[k]}'")

# ============================================================ parâmetros
check("Parâmetros da 0058", "true|2026-11-18|true",
      q("select string_agg(valor #>> '{}', '|' order by chave) from parametros where chave in "
        "('atlas_conclusao_exige_justificativa','atlas_conclusao_justificativa_desde','atlas_em_andamento_inicia_tratativa')"))

# ============================================================ 2) "em andamento" = início da tratativa
recusa("Peticionador não registra o andamento da sincronização", f"select atlas_registrar_em_andamento({LOTE})", COLAB, "Somente a controladoria")
r = J(f"select atlas_registrar_em_andamento({LOTE})")
check("Sincronização: a tarefa em andamento ganha início da tratativa", 1, r["registrados"])
ev = J(f"select to_jsonb(e) from eventos e where tipo='inicio_tratativa' and tarefa_id = {tar('andamento')}")
check("Início: origem sistema, responsável da tarefa, fonte Atlas", f"sistema|{OUTRO}|atlas_em_andamento|entre_importacoes",
      f"{ev['origem']}|{ev['colaborador_id']}|{ev['evidencia']['fonte']}|{ev['precisao_ocorrido']}")
check("Rodar de novo não duplica", 0, J(f"select atlas_registrar_em_andamento({LOTE})")["registrados"])
st = J(f"select ext_status_tarefa('{T['andamento']}', '{{}}'::jsonb)", COLAB)
check("A extensão vê a tratativa iniciada (sem novo início)", "True", str(st["inicio_tratativa_em"] is not None))
check("Painel: a tarefa sai de 'sem início da tratativa'", "1",
      q(f"select count(*) from v_tarefas_atuais where tarefa_id = {tar('andamento')} and inicio_tratativa_em is not null", ADMIN))
check("Tarefas a fazer continuam sem início", "0",
      q(f"select count(*) from eventos where tipo='inicio_tratativa' and tarefa_id in ({tar('semd4')}, {tar('d4longe')})"))
J("select admin_definir_parametro('atlas_em_andamento_inicia_tratativa', 'false'::jsonb, true, 'teste: regra desligada')")
check("Regra desligada: nada é registrado", "True", str(J(f"select atlas_registrar_em_andamento({LOTE})").get("desligado")))
J("select admin_definir_parametro('atlas_em_andamento_inicia_tratativa', 'true'::jsonb, true, 'teste: regra religada')")

# ============================================================ 1) conclusão com justificativa
st = J(f"select ext_status_tarefa('{T['semd4']}', '{{}}'::jsonb)", COLAB)
check("Extensão: conclusão no Atlas exige justificativa", "True", str(st["conclusao_exige_justificativa"]))
ini = lambda k: J(f"select ext_registrar_evento('{uuid.uuid4()}','inicio_tratativa','{T[k]}','{{}}'::jsonb,null,null,'{{}}'::jsonb,now())", COLAB)
ini("concl_com"); ini("concl_sem")
e1 = J(f"select ext_registrar_evento('{uuid.uuid4()}','tentativa_conclusao','{T['concl_com']}','{{}}'::jsonb,'permitida_apos_validacao',"
       f"'Petição protocolada e comprovante anexado','{{}}'::jsonb,now())", COLAB)
check("Conclusão com justificativa: registrada como permitida", "permitida_apos_validacao", e1["estado_trava"])
e2 = J(f"select ext_registrar_evento('{uuid.uuid4()}','tentativa_conclusao','{T['concl_sem']}','{{}}'::jsonb,'permitida_apos_validacao',"
       f"null,'{{}}'::jsonb,now())", COLAB)
check("Conclusão declarada sem justificativa (extensão antiga): o servidor reclassifica", "violacao_detectada", e2["estado_trava"])
check("O motivo do servidor fica no evento", "Conclusão no Atlas sem justificativa (exigida desde 17/11/2026).",
      q(f"select evidencia->>'motivo_servidor' from eventos where id = '{e2['evento_id']}'"))

# rede de segurança: double check aponta a conclusão sem justificativa (a partir do dia do parâmetro)
J(f"select admin_definir_parametro('atlas_conclusao_justificativa_desde', to_jsonb((hoje_brasilia() + 1)::text), false, 'teste: ainda não vale')")
J("select double_check_atlas_executar(null, 'manual')")
check("Antes do dia de início: nenhuma conclusão apontada", "0", q("select count(*) from inconsistencias where tipo='conclusao_sem_justificativa'"))
J(f"select admin_definir_parametro('atlas_conclusao_justificativa_desde', to_jsonb((hoje_brasilia() - 1)::text), false, 'teste: já vale')")
J("select double_check_atlas_executar(null, 'manual')")
inc = J("select coalesce(jsonb_agg(to_jsonb(i)), '[]') from inconsistencias i where tipo='conclusao_sem_justificativa'")
check("Double check: só a conclusão sem justificativa é apontada", f"1|{T['concl_sem']}|2|aberta",
      f"{len(inc)}|{inc[0]['atlas_tarefa_id'] if inc else '-'}|{inc[0]['gravidade'] if inc else '-'}|{inc[0]['situacao'] if inc else '-'}")
check("Rotina automática (sem usuário, chave de serviço) aponta igual", "1",
      q("set request.jwt.claims = '{\"role\":\"service_role\"}'; select (double_check_atlas_executar(null, 'automatico')->>'abertas')::int >= 1; "
        "select count(*) from inconsistencias where tipo='conclusao_sem_justificativa' and situacao='aberta'"))
check("Descrição cita a tarefa e o responsável", "True", str(bool(inc) and 'Petição simples (sem justificativa)' in inc[0]['descricao'] and 'OUTRO' in inc[0]['descricao']))
J("select double_check_atlas_executar(null, 'manual')")
check("Rodar de novo não duplica", "1", q("select count(*) from inconsistencias where tipo='conclusao_sem_justificativa'"))
J(f"select ext_registrar_evento('{uuid.uuid4()}','tentativa_conclusao','{T['concl_sem']}','{{}}'::jsonb,'permitida_apos_validacao',"
  f"'Justificativa registrada depois pela controladoria','{{}}'::jsonb,now())", COLAB)
J("select double_check_atlas_executar(null, 'manual')")
check("Com a justificativa registrada, a inconsistência se regulariza", "regularizada",
      q("select situacao from inconsistencias where tipo='conclusao_sem_justificativa'"))
J("select admin_definir_parametro('atlas_conclusao_exige_justificativa', 'false'::jsonb, true, 'teste: regra desligada')")
check("Regra desligada: a extensão não pede justificativa", "False", str(J(f"select ext_status_tarefa('{T['semd4']}', '{{}}'::jsonb)", COLAB)["conclusao_exige_justificativa"]))
J("select admin_definir_parametro('atlas_conclusao_exige_justificativa', 'true'::jsonb, true, 'teste: regra religada')")
check("Relatório gerencial reconhece o tipo novo", "True",
      str(any(g["titulo"] == "Apontadas no período, por situação" for g in J("select relatorio_gerencial('inconsistencias')")["graficos"])))

# ============================================================ 3) reagendamento pedido pelo peticionador
PED = lambda k, d, j="Aguardando documentos do cliente para a peça": f"select solicitacao_reagendamento_pedir({tar(k)}, '{d}', '{j}')"
recusa("Líder não usa o pedido do peticionador", PED("semd4", du(2)), LIDER, "Somente o peticionador")
recusa("Controladoria não usa o pedido do peticionador", PED("semd4", du(2)), ADMIN, "Somente o peticionador")
recusa("Peticionador não pede reagendamento de tarefa de outro", PED("pedro", du(2)), COLAB, "suas tarefas")
recusa("Justificativa curta", PED("semd4", du(2), "curta"), COLAB, "Justificativa obrigatória")
recusa("Data no passado", PED("semd4", q("select hoje_brasilia() - 1")), COLAB, "anterior a hoje")
recusa("Data depois do prazo fatal", PED("d4longe", du(13)), COLAB, "prazo fatal")
recusa("Data igual à atual", PED("semd4", du(1)), COLAB, "igual à data atual")
s1 = J(PED("semd4", du(2)), COLAB)
check("Sem D-4 (tarefa sem prazo fatal): vai para o líder", "aguardando_lider|False|peticionador|colaborador",
      f"{s1['status']}|{s1['exige_controladoria']}|{s1['dados']['origem']}|{s1['solicitante_papel']}")
recusa("Pedido repetido para a mesma tarefa", PED("semd4", du(3)), COLAB, "Já existe")
s2 = J(PED("d4longe", du(3)), COLAB)
check("Nova data até o D-4: vai para o líder", "aguardando_lider", s2["status"])
J(f"select solicitacao_cancelar({s2['id']}, 'O cliente mandou os documentos')", COLAB)
check("O peticionador cancela o próprio pedido enquanto aguarda o líder", "cancelada", q(f"select status from solicitacoes where id={s2['id']}"))
s3 = J(PED("d4longe", du(10)), COLAB)
check("Nova data depois do D-4: só a controladoria", "aguardando_controladoria|True|1",
      f"{s3['status']}|{s3['exige_controladoria']}|{sum('Nova data depois do D-4' in m for m in s3['motivos_controladoria'])}")
s4 = J(PED("d4passou", du(1)), COLAB)
check("Pedido feito depois do D-4: só a controladoria", "aguardando_controladoria|1",
      f"{s4['status']}|{sum('Pedido feito depois do D-4' in m for m in s4['motivos_controladoria'])}")
# exceção de D-4 autorizada: volta a ser decisão do líder
J(f"select excecao_d4_definir({tar('escalar')}, true, 'Cliente enviará os documentos na véspera')")
s5 = J(PED("escalar", du(9)), COLAB)
check("Com exceção de D-4 autorizada: decisão do líder", "aguardando_lider", s5["status"])
J(f"select excecao_d4_definir({tar('escalar')}, false, 'Exceção retirada para o teste de escalada')")

# decisões
recusa("Peticionador não decide", f"select solicitacao_decidir({s1['id']}, true, 'aprovando o próprio pedido')", COLAB, "Somente o líder")
recusa("Líder de outra equipe não decide", f"select solicitacao_decidir({s1['id']}, true, 'pauta comporta a data')", LIDER_B, "Somente o líder")
recusa("Líder não decide o que está com a controladoria", f"select solicitacao_decidir({s3['id']}, true, 'pauta comporta a data')", LIDER, "Somente a controladoria")
recusa("Decisão sem motivo", f"select solicitacao_decidir({s1['id']}, true, 'ok')", LIDER, "motivo da decisão")
d1 = J(f"select solicitacao_decidir({s1['id']}, true, 'Pauta comporta a nova data')", LIDER)
check("Líder da equipe aprova antes do D-4", "aprovada|Líder: Pauta comporta a nova data",
      f"{d1['status']}|{q(f'select nota from solicitacoes_historico where solicitacao_id={s1[chr(105)+chr(100)]} order by id desc limit 1')}")
d3 = J(f"select solicitacao_decidir({s3['id']}, false, 'Prazo processual próximo: manter a data')")
check("Controladoria decide o pedido depois do D-4", "recusada", d3["status"])
d4 = J(f"select solicitacao_decidir({s4['id']}, true, 'Autorizado: peça quase pronta')")
check("Controladoria aprova o pedido feito depois do D-4", "aprovada", d4["status"])
# líder que aprova depois que o D-4 passou: sobe para a controladoria
s6 = J(PED("lider2", du(2)), COLAB)
q(f"update solicitacoes set dados = dados || jsonb_build_object('d4', hoje_brasilia() - 1) where id = {s6['id']}")
d6 = J(f"select solicitacao_decidir({s6['id']}, true, 'Pauta comporta a nova data')", LIDER)
check("Líder aprova depois do D-4: o pedido sobe para a controladoria", "aguardando_controladoria|True|True",
      f"{d6['status']}|{d6.get('encaminhada_controladoria')}|{d6['exige_controladoria']}")
# pedido parado com o líder que chega ao D-4: o double check sobe para a controladoria
d4_esc = q(f"select (dados->>'d4') from solicitacoes where id = {s5['id']}")
check("Antes do D-4 o pedido fica com o líder", "0", q(f"select _solicitacoes_escalar(hoje_brasilia())"))
check("No próprio dia do D-4 o pedido continua com o líder", "0", q(f"select _solicitacoes_escalar('{d4_esc}')"))
check("Depois do D-4 o pedido sobe para a controladoria", "1", q(f"select _solicitacoes_escalar(('{d4_esc}'::date + 1))"))
check("Histórico registra a subida", "aguardando_controladoria|Passou do D-4 sem decisão do líder: subiu para a controladoria",
      q(f"select status_para || '|' || nota from solicitacoes_historico where solicitacao_id={s5['id']} order by id desc limit 1"))

# visibilidade
check("Peticionador vê os próprios pedidos", "6", str(len(J("select solicitacoes_listar(null, 200)", COLAB))))
check("Outro peticionador não vê", "0", str(len(J("select solicitacoes_listar(null, 200)", PEDRO_U))))
check("Líder da equipe vê os pedidos da equipe", "6", str(len(J("select solicitacoes_listar(null, 200)", LIDER))))
check("Líder de outra equipe não vê", "0", str(len(J("select solicitacoes_listar(null, 200)", LIDER_B))))

# execução no Atlas (a Edge Function chama estas funções)
recusa("Peticionador não executa no Atlas", f"select solicitacao_para_execucao({s1['id']})", COLAB, "Somente líderes")
recusa("Líder de outra equipe não executa", f"select solicitacao_para_execucao({s1['id']})", LIDER_B, "Somente quem pediu")
ex = J(f"select solicitacao_para_execucao({s1['id']})", LIDER)
ed = next(o for o in ex["operacoes"] if o["op"] == "edit_task")
check("Líder executa: troca só a data no Atlas", f"{T['semd4']}|{du(2)}|False",
      f"{ed['data']['taskId']}|{ed['data']['dueDate']}|{'assigneeUserId' in ed['data']}")
r = J(f"select solicitacao_resultado({s1['id']}, true, '{{\"feitas\": 2}}'::jsonb)", LIDER)
check("Resultado registrado pelo líder", "executada", r["status"])

ok = sum(1 for r_ in res if r_[3] == "OK")
for n, e, o, s_ in res:
    if s_ != "OK": print(f"FALHA: {n}\n  esperado: {e}\n  obtido:   {o}")
print(f"{ok}/{len(res)} OK")
if os.environ.get("MANTER") != "1":
    subprocess.run(PSQL + ["-d", "postgres", "-c", f"drop database if exists {DB}"], capture_output=True)
