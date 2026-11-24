"""Testes das migrações 0038 a 0041 (pedidos da Dra. Mariana, 11/11/2026). Banco LOCAL, dados FICTÍCIOS.
Itens: 6 (perfis: diretoria, líder com equipes, peticionador), 5 (modalidades, checklist, anexos, descrição padrão),
4 (planejamento da pauta e solicitações), 3 (double check Webjur × Atlas e relatório diário). Nenhuma chamada ao Atlas real."""
import json, subprocess, hashlib, os
PSQL = ["psql", "-h", "/tmp", "-p", "5433", "-U", "postgres", "-At", "-q", "-v", "ON_ERROR_STOP=1"]
HERE = os.path.dirname(os.path.abspath(__file__)); MIGDIR = os.path.join(HERE, "..", "supabase", "migrations")
MIG = sorted(os.path.join(MIGDIR, f) for f in os.listdir(MIGDIR)); DB = "ctrl_etapa13"; res = []
ADMIN = "00000000-0000-0000-0000-00000000000a"; COLAB = "00000000-0000-0000-0000-00000000000c"
LIDER = "00000000-0000-0000-0000-0000000000d1"; DIR = "00000000-0000-0000-0000-0000000000d9"
PEDRO_U = "00000000-0000-0000-0000-0000000000e2"; SEM = "00000000-0000-0000-0000-0000000000ff"
U_OUTRO, U_PEDRO = "11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222"

def run(sql, uid=None, servico=False):
    pre = f"set role authenticated; set request.jwt.claim.sub = '{uid}';\n" if uid else ""
    if servico: pre = "set request.jwt.claims = '{\"role\":\"service_role\"}';\n"
    p = subprocess.run(PSQL + ["-d", DB], input=pre + sql, capture_output=True, text=True)
    return p.returncode, p.stdout.strip(), p.stderr.strip()
def q(sql, uid=None, servico=False):
    c, o, e = run(sql, uid, servico)
    if c: raise RuntimeError(sql[:300] + "\n" + e)
    return o
J = lambda sql, uid=ADMIN, servico=False: json.loads(q(sql, uid, servico))
def check(n, e, o): res.append((n, str(e), str(o), "OK" if str(e) == str(o) else "FALHA"))
def recusa(n, sql, uid, trecho):
    c, o, e = run(sql, uid); check(n, f"recusado ({trecho})", f"recusado ({trecho})" if c and trecho in e else f"aceito/outro: {e[:200]}")
lit = lambda o: "$J$" + json.dumps(o, ensure_ascii=False) + "$J$::jsonb"

subprocess.run(PSQL + ["-d", "postgres", "-c", f"drop database if exists {DB}", "-c", f"create database {DB}"], check=True, capture_output=True)
for f in [os.path.join(HERE, "00_stub_supabase_local.sql")] + MIG:
    subprocess.run(PSQL + ["-d", DB, "-f", f], check=True, capture_output=True)
q(f"""insert into equipes(nome) values ('Equipe A'),('Equipe B');
  insert into colaboradores(nome_advbox, origem, equipe_id) values ('OUTRO','administrativo',(select id from equipes where nome='Equipe A')),
    ('Brenda Martins','administrativo',(select id from equipes where nome='Equipe A')),('PEDRO','administrativo',(select id from equipes where nome='Equipe B'));
  insert into auth.users (id, email) values ('{ADMIN}','a@x.invalid'),('{COLAB}','c@x.invalid'),('{LIDER}','l@x.invalid'),('{DIR}','d@x.invalid'),
    ('{PEDRO_U}','p@x.invalid'),('{SEM}','s@x.invalid');
  insert into perfis values ('{ADMIN}','admin',null), ('{COLAB}','colaborador',(select id from colaboradores where nome_advbox='OUTRO')),
    ('{LIDER}','lider',(select id from colaboradores where nome_advbox='Brenda Martins')),
    ('{PEDRO_U}','colaborador',(select id from colaboradores where nome_advbox='PEDRO'));""")
col = lambda n: q(f"select id from colaboradores where nome_advbox='{n}'")
OUTRO, PEDRO = col("OUTRO"), col("PEDRO")
J(f"select atlas_mapear_usuarios({lit([{'id': U_OUTRO, 'name': 'OUTRO'}, {'id': U_PEDRO, 'name': 'PEDRO'}])})")

# ------------------------------------------------------------ base fictícia (datas relativas a hoje)
du = lambda n: q(f"select somar_dias_uteis(hoje_brasilia(), {n})")
D = du(1)                    # dia em que a tarefa nova entra
nomes = {U_OUTRO: "OUTRO", U_PEDRO: "PEDRO"}
resp = lambda u, n: [{"user_id": u, "name": n, "is_principal": True, "completed_at": None}]
T = {k: f"a0000000-0000-4000-8000-0000000000{i:02d}" for i, k in enumerate(
    ["contestar", "manifestar", "urgente", "d4hoje", "pedro", "replica"], start=1)}
tarefas = [
  {"id": T["contestar"], "title": "Contestar ação revisional", "description": "Texto original do Atlas.", "due_date": D, "fatal_date": du(12),
   "assignees": resp(U_OUTRO, "OUTRO")},                                                        # 3 pts, PF judicial longe
  {"id": T["manifestar"], "title": "Manifestar sobre laudo", "description": "x", "due_date": D, "fatal_date": None, "assignees": resp(U_OUTRO, "OUTRO")},  # 1 pt, interna
  {"id": T["urgente"], "title": "Manifestação urgente", "description": "x", "priority": "urgent", "due_date": D, "fatal_date": None, "assignees": resp(U_OUTRO, "OUTRO")},
  {"id": T["d4hoje"], "title": "Embargos de declaração", "description": "x", "due_date": D, "fatal_date": du(4), "assignees": resp(U_OUTRO, "OUTRO")},  # D-4 = D
  {"id": T["pedro"], "title": "Apelação do banco", "description": "x", "due_date": D, "fatal_date": du(15), "assignees": resp(U_PEDRO, "PEDRO")},
  {"id": T["replica"], "title": "Réplica", "description": "x" * 600, "description_truncated": True, "due_date": du(3), "fatal_date": du(14),
   "assignees": resp(U_OUTRO, "OUTRO")},
]
linhas = subprocess.run(["node", os.path.join(HERE, "atlas", "linhas_ficticias.mjs"), "json", json.dumps(nomes), json.dumps(tarefas)],
                        capture_output=True, text=True, check=True).stdout
s = J(f"select importar_arquivo('Atlas e13','{hashlib.sha256(linhas.encode()).hexdigest()}',$J${linhas}$J$::jsonb,null,now(),false)")
check("Base fictícia: 6 tarefas", "6", s["validas"])
tar = lambda k: q(f"select id from tarefas where atlas_id = '{T[k]}'")
total = q("select count(*) from v_tarefas_atuais")

# ============================================================ item 6 — perfis
q(f"select admin_definir_perfil('{DIR}','diretoria',null,'Diretoria acompanha o painel')", ADMIN)
check("Diretoria cadastrada sem colaborador", "diretoria", q(f"select papel from perfis where user_id='{DIR}'"))
check("Diretoria vê todas as tarefas", total, q("select count(*) from v_tarefas_atuais", DIR))
check("Peticionador vê só as próprias (5 de OUTRO)", "5", q("select count(*) from v_tarefas_atuais", COLAB))
check("Líder sem equipe configurada vê só as próprias (0)", "0", q("select count(*) from v_tarefas_atuais", LIDER))
recusa("Só líder acompanha equipe", f"select admin_definir_lider_equipes('{COLAB}', array[1], 'motivo de teste ok')", ADMIN, "Só líderes")
J(f"select admin_definir_lider_equipes('{LIDER}', array[(select id from equipes where nome='Equipe A')], 'Brenda lidera a equipe A')")
check("Líder vê as tarefas da equipe A (5 de OUTRO), não as de PEDRO", "5|0",
      f"{q('select count(*) from v_tarefas_atuais', LIDER)}|{q(f'select count(*) from v_tarefas_atuais where responsavel_id={PEDRO}', LIDER)}")
check("Líder vê a tratativa das tarefas da equipe", "5", q("select count(*) from tratativas_visiveis() t join tarefas x on x.id=t.tarefa_id where x.atlas_id is not null", LIDER))
recusa("Diretoria não grava (parâmetro)", "select admin_definir_parametro('capacidade_pontos_dia','7'::jsonb,true,'teste de escrita')", DIR, "Somente")
recusa("Diretoria não importa", "select importar_arquivo('x','y','[]'::jsonb,null,now(),false)", DIR, "Somente")
check("Diretoria lê publicações e log (leitura geral)", "0|t", f"{q('select count(*) from publicacoes', DIR)}|{q('select pode_ler_tudo()', DIR)}")
check("Usuários listam equipes lideradas", "Equipe A",
      next(u for u in J("select admin_listar_usuarios()") if u["user_id"] == LIDER)["equipes_lideradas"][0]["nome"])
check("Chave de serviço é tratada como controladoria (rotina automática)", "t|servico", f"{q('select is_admin()', servico=True)}|{q('select meu_papel()', servico=True)}")

# ============================================================ item 5 — modalidades, checklist, anexos
ex = lambda k, uid=COLAB: J(f"select execucao_tarefa({tar(k)})", uid)
e0 = ex("contestar")
check("Contestação reconhecida pelo título; modelo inicial inativo não exige nada", "Contestação|False|False",
      f"{e0['modalidade']['nome']}|{e0['modalidade']['ativa']}|{e0['exigido']}")
mod = J("select to_jsonb(m) from modalidades m where nome='Contestação'")
recusa("Link precisa ser https", f"select admin_salvar_modalidade({lit({**mod, 'link_treinamento': 'http://x'})}, 'ajuste de teste ok')", ADMIN, "https")
recusa("Peticionador não edita modalidade", f"select admin_salvar_modalidade({lit(mod)}, 'tentativa indevida')", COLAB, "Somente")
J(f"select admin_salvar_modalidade({lit({**mod, 'ativa': True, 'link_treinamento': 'https://treinamento.exemplo/contestacao', 'link_notebooklm': 'https://notebooklm.google.com/notebook/teste'})}, 'Ativação da contestação (teste)')")
e1 = ex("contestar")
check("Ativa: 7 itens + peça + parecer pendentes", "True|9|False", f"{e1['exigido']}|{len(e1['pendencias'])}|{e1['completo']}")
check("Links e modo de trava", "https://notebooklm.google.com/notebook/teste|bloquear", f"{e1['modalidade']['link_notebooklm']}|{e1['modo']}")
recusa("Colega de outra equipe não marca checklist", f"select execucao_marcar({tar('contestar')}, 'prazos', true)", PEDRO_U, "Somente")
recusa("Item inexistente", f"select execucao_marcar({tar('contestar')}, 'nao_existe', true)", COLAB, "inexistente")
for it in e1["checklist"]:
    J(f"select execucao_marcar({tar('contestar')}, '{it['id']}', true)", COLAB)
J(f"select execucao_marcar({tar('contestar')}, 'prazos', false)", LIDER)     # líder da equipe desmarca
e2 = ex("contestar")
check("Checklist marcado (um desmarcado pelo líder): faltam 1 item + 2 anexos", "3", len(e2["pendencias"]))
caminho = f"{tar('contestar')}/contestacao.pdf"
recusa("Registrar anexo sem enviar o arquivo", f"select anexo_registrar({tar('contestar')}, 'peca', '{caminho}', 'contestacao.pdf', 1000, null)", COLAB, "não encontrado")
c, _, e = run(f"insert into storage.objects (bucket_id, name) values ('pecas', '{tar('pedro')}/x.pdf')", COLAB)
check("Storage: peticionador não envia arquivo na pasta de tarefa alheia", "recusado", "recusado" if c and "row-level security" in e else "aceito")
q(f"insert into storage.objects (bucket_id, name) values ('pecas', '{caminho}'), ('pecas', '{tar('contestar')}/parecer.pdf')", COLAB)
recusa("Anexo fora da pasta da tarefa", f"select anexo_registrar({tar('contestar')}, 'peca', '{tar('pedro')}/x.pdf', 'x.pdf', 1000, null)", COLAB, "pasta da tarefa")
recusa("Anexo maior que o limite", f"select anexo_registrar({tar('contestar')}, 'peca', '{caminho}', 'c.pdf', 99999999999, null)", COLAB, "maior que")
J(f"select anexo_registrar({tar('contestar')}, 'peca', '{caminho}', 'contestacao.pdf', 1000, '{'a'*64}')", COLAB)
J(f"select execucao_marcar({tar('contestar')}, 'prazos', true)", COLAB)
e3 = ex("contestar")
check("Falta só o parecer de autoavaliação", '["Anexar o parecer de autoavaliação"]', json.dumps(e3["pendencias"], ensure_ascii=False))
J(f"select anexo_registrar({tar('contestar')}, 'parecer_autoavaliacao', '{tar('contestar')}/parecer.pdf', 'parecer.pdf', 500, null)", COLAB)
check("Execução completa", "True|2", f"{ex('contestar')['completo']}|{len(ex('contestar')['anexos'])}")
recusa("Anexos são imutáveis", "delete from anexos_tarefa", None, "")   # postgres: gatilho barra
check("Extensão: consulta pelo ID do Atlas", "True|True", (lambda x: f"{x['encontrada']}|{x['completo']}")(J(f"select ext_execucao('{T['contestar'].upper()}')", COLAB)))
check("Extensão: tarefa alheia sem acesso", "True", J(f"select ext_execucao('{T['contestar']}')", PEDRO_U).get("sem_acesso"))
J(f"select definir_modalidade_tarefa({tar('manifestar')}, (select id from modalidades where nome='Contestação'))", LIDER)
check("Modalidade definida à mão pelo líder prevalece", "Contestação|True", (lambda x: f"{x['modalidade']['nome']}|{x['modalidade_manual']}")(ex("manifestar")))
J(f"select definir_modalidade_tarefa({tar('manifestar')}, null, true)", LIDER)
check("Removida: volta a ser reconhecida pelo título", "Manifestação", ex("manifestar")["modalidade"]["nome"])
pauta = J("select minha_pauta()", COLAB)
check("Minha pauta do peticionador: 5 tarefas, com pendências e link do Atlas", "5|True|True",
      f"{len(pauta)}|{any(p['pendencias'] for p in pauta)}|{all(p['atlas_url'] for p in pauta)}")
check("Diretoria vê a pauta de todos", "6", len(J("select minha_pauta()", DIR)))
mp = next(x for x in J("select minha_pauta()", COLAB) if x["tarefa_id"] == int(tar("contestar")))
check("Pauta calculada de uma vez = execução tarefa a tarefa (0043)", json.dumps(ex("contestar")["pendencias"]), json.dumps(mp["pendencias"]))
check("Pauta: checklist e anexos iguais aos da tarefa", f"{len(ex('contestar')['checklist'])}|{len(ex('contestar')['anexos'])}|True", f"{len(mp['checklist'])}|{len(mp['anexos'])}|{mp['pode_editar']}")
bloco = q(f"select bloco_descricao_padrao({tar('contestar')})")
check("Bloco padrão: prazos, links e checklist (sem 'PF:' que confunda a leitura do PF)", "True|True|True|False",
      f"{'Prazo judicial (fatal):' in bloco}|{'notebooklm' in bloco}|{'[ ] ' in bloco}|{'PF:' in bloco}")
lst = J("select descricoes_para_padronizar(50)")
check("Descrições a padronizar: só a contestação (única modalidade ativa)", f"{T['contestar']}|Texto original do Atlas.|False",
      "|".join(f"{x['atlas_id']}|{x['descricao_original']}|{x['truncada']}" for x in lst))
q(f"select descricao_padronizada_registrar({tar('contestar')}, '{lst[0]['hash_bloco']}', 'gravada')", ADMIN)
check("Depois de gravada não volta para a fila", "0", len(J("select descricoes_para_padronizar(50)")))
J(f"select admin_salvar_modalidade({lit({**J(chr(32).join(['select to_jsonb(m) from modalidades m where nome=' + chr(39) + 'Contestação' + chr(39)])), 'orientacoes': 'Nova orientação do escritório'})}, 'Atualização das orientações')")
check("Mudou a modalidade: volta para a fila", "1", len(J("select descricoes_para_padronizar(50)")))

# ============================================================ item 4 — planejamento e solicitações
q("update parametros set valor = '6' where chave = 'capacidade_pontos_dia'")
a = J(f"select analisar_pauta({OUTRO}, '{D}', 2, false)", LIDER)
# carga no dia D: contestar 3 + manifestar 1 + urgente 1 + embargos 2 = 7 (> 6 já); nova de 2 -> excesso 3
check("Carga do dia e excesso", "7|6|3", f"{a['carga_no_dia']}|{a['capacidade']}|{a['excesso']}")
check("Não remanejáveis: urgente e D-4 atingido", "D-4|urgente",
      "|".join(sorted(("urgente" if "urgente" in x["motivo"] else "D-4") for x in a["nao_remanejaveis"])))
sug = a["sugestoes"]
check("Sugestões: a interna primeiro, depois a processual (exige controladoria)", "Manifestar sobre laudo:False|Contestar ação revisional:True",
      "|".join(f"{x['compromisso']}:{x['exige_controladoria']}" for x in sug))
check("Nova data respeita o D-4 com folga", "True", all(x["data_para"] > D and (x["d4"] is None or x["data_para"] <= x["d4"]) for x in sug))
check("Justificativa explica a escolha", "True", "libera capacidade" in sug[0]["justificativa"] and "prazo interno" in sug[0]["justificativa"])
recusa("Líder não planeja advogado de outra equipe", f"select analisar_pauta({PEDRO}, '{D}', 1)", LIDER, "Somente")
recusa("Peticionador não planeja", f"select analisar_pauta({OUTRO}, '{D}', 1)", COLAB, "Somente")
nova = {"titulo": "Petição urgente do cliente X", "prioridade": "urgent", "data": D}
recusa("Justificativa curta", f"select solicitacao_criar('nova_tarefa', {OUTRO}, {lit(nova)}, null, 'curta')", LIDER, "Justificativa")
recusa("Remanejamento fora das sugestões seguras", f"select solicitacao_criar('nova_tarefa', {OUTRO}, {lit(nova)}, {lit({'tarefa_id': int(tar('urgente'))})}, 'Cliente pediu com urgência a petição')", LIDER, "sugestões seguras")
s1 = J(f"select solicitacao_criar('nova_tarefa', {OUTRO}, {lit(nova)}, {lit(sug[0])}, 'Cliente pediu com urgência a petição')", LIDER)
check("Nova tarefa com remanejamento interno: aprovada pelo líder", "aprovada|False", f"{s1['status']}|{s1['exige_controladoria']}")
s2 = J(f"select solicitacao_criar('nova_tarefa', {OUTRO}, {lit(nova)}, {lit(sug[1])}, 'Cliente pediu com urgência a petição')", LIDER)
check("Remanejar tarefa com PF Judicial: vai para a controladoria", "aguardando_controladoria|True", f"{s2['status']}|{s2['exige_controladoria']}")
recusa("Líder não executa sem aprovação", f"select solicitacao_para_execucao({s2['id']})", LIDER, "não está aprovada")
recusa("Líder não aprova", f"select solicitacao_decidir({s2['id']}, true, 'aprovando sem poder')", LIDER, "Somente")
J(f"select solicitacao_decidir({s2['id']}, false, 'Prazo processual próximo demais, recusado')")
check("Controladoria recusa com motivo", "recusada", q(f"select status from solicitacoes where id={s2['id']}"))
plano = J(f"select solicitacao_para_execucao({s1['id']})", LIDER)
ops = [o["op"] for o in plano["operacoes"]]
check("Execução: cria a tarefa e reagenda a remanejada (com comentário opcional)", "create_task,edit_task,add_task_comment", ",".join(ops))
ct = plano["operacoes"][0]
check("create_task com responsável do Atlas, urgência e chave de idempotência", f"{U_OUTRO}|urgent|controladoria-solic-{s1['id']}-nova",
      f"{ct['data']['assigneeUserId']}|{ct['data']['priority']}|{ct['idempotencia']}")
et = plano["operacoes"][1]["data"]
check("edit_task preserva a descrição e anota a realocação justificada", "True|True",
      f"{et['description'].startswith('x')}|{'Tarefa realocada pela controladoria' in et['description']}")
J(f"select solicitacao_resultado({s1['id']}, true, {lit({'feitas': ops})})", LIDER)
check("Executada: reagendamento registrado com justificativa (exceção autorizada do líder)", "executada|1|excecao_autorizada",
      f"{q(f'select status from solicitacoes where id={s1[chr(105)+chr(100)]}')}|{q(f'select count(*) from eventos where chave_dedupe like {chr(39)}solic:{s1[chr(105)+chr(100)]}:%{chr(39)}')}|"
      f"{q(f'select estado_trava from eventos where chave_dedupe like {chr(39)}solic:{s1[chr(105)+chr(100)]}:%{chr(39)}')}")
reag = {"tarefa_id": int(tar("contestar")), "nova_data": du(3)}
s3 = J(f"select solicitacao_criar('reagendamento', {OUTRO}, {lit(reag)}, null, 'Advogado em audiência o dia todo')", LIDER)
check("Reagendar tarefa com PF Judicial: aguarda a controladoria, com o motivo", "aguardando_controladoria|True",
      f"{s3['status']}|{any('PF Judicial' in m for m in s3['motivos_controladoria'])}")
recusa("Reagendar para depois do prazo fatal", f"select solicitacao_criar('reagendamento', {OUTRO}, {lit({**reag, 'nova_data': du(30)})}, null, 'Advogado em audiência o dia todo')", LIDER, "prazo fatal")
J(f"select solicitacao_decidir({s3['id']}, true, 'Prazo comporta, aprovado pela controladoria')")
p3 = J(f"select solicitacao_para_execucao({s3['id']})")
check("Reagendamento: edit_task com a nova data", f"edit_task|{T['contestar']}|{du(3)}", (lambda o: f"{o['op']}|{o['data']['taskId']}|{o['data']['dueDate']}")(p3["operacoes"][0]))
J(f"select solicitacao_resultado({s3['id']}, false, {lit({'erro': 'Atlas fora do ar'})})")
check("Falha no Atlas: fica 'falhou' e pode ser repetida", "falhou|em_execucao",
      f"{q(f'select status from solicitacoes where id={s3[chr(105)+chr(100)]}')}|{J(chr(32).join(['select solicitacao_para_execucao(' + str(s3['id']) + ')']), ADMIN) and q(f'select status from solicitacoes where id={s3[chr(105)+chr(100)]}')}")
check("Peticionador vê as solicitações sobre ele", "3", len(J("select solicitacoes_listar()", COLAB)))
check("Histórico da solicitação", "aprovada>em_execucao>executada", ">".join(h["para"] for h in next(x for x in J("select solicitacoes_listar()") if x["id"] == s1["id"])["historico"]))
check("Advogados que o líder pode planejar", "Brenda Martins,OUTRO", ",".join(x["nome"] for x in J("select planejamento_colaboradores()", LIDER)))

# ============================================================ item 3 — double check Webjur × Atlas
hoje = q("select hoje_brasilia()"); ontem = q("select hoje_brasilia() - 1"); antes = q("select hoje_brasilia() - 2")
C1, C2, C3, C4 = "0000001-11.2026.8.13.0024", "0000002-22.2026.8.13.0024", "0000003-33.2026.8.13.0024", "0000004-44.2026.8.13.0024"
pub = lambda cnj, d, teor, i: J(f"select pub_registrar({lit({'cnj': cnj, 'teor': teor, 'data_disponibilizacao': d, 'data_publicacao': d, 'tribunal': 'TJMG'})}, 'manual', 'p{i}')")
pub(C1, ontem, "Intimação para contestar no prazo legal.", 1)                     # há no Atlas: ok
pub(C2, ontem, "Vista à parte autora sobre o laudo pericial.", 2)                  # não cadastrada no Atlas
pub(C3, ontem, "Intimação da sentença de procedência parcial.", 3)                 # Atlas com data diferente
pub(C1, ontem, "Intimação para contestar no prazo legal.", 4)                      # duplicada (mesmo texto) -> dedupe da Webjur? (chave igual)
pub(C1, ontem, "Intimação  para contestar no  prazo legal (cópia DJE).", 5)       # quase igual: duplicada
ai = lambda i, **k: {"id": f"b0000000-0000-4000-8000-0000000000{i:02d}", "process_number": k.get("cnj"), "available_date": k.get("d"),
    "publication_date": k.get("d"), "status": k.get("status", "lida"), "handled_origin": k.get("ho"), "duplicate_status": k.get("dup"),
    "needs_manual_review": k.get("rev", False), "needs_mandatory_confirmation": False, "inferred_type": k.get("tipo", "prazo"),
    "client_id": "c0000000-0000-4000-8000-000000000001" if k.get("cli", True) else None, "client_match_status": "confirmado" if k.get("cli", True) else "pendente",
    "deadline": {"fatal_date": k["fatal"]} if k.get("fatal") else None, "tasks": k.get("tasks", []), "summary": "resumo", "app_url": "https://gestor.atlasjus.com/#/intimacoes?x",
    "updated_at": "2026-11-11T12:00:00Z"}
tk = lambda fatal, due=None: [{"id": "d0000000-0000-4000-8000-000000000001", "title": "Contestar", "status": "todo", "due_date": due or du(5), "fatal_date": fatal}]
intim = [ai(1, cnj=C1, d=ontem, fatal=du(15), tasks=tk(du(15))),                   # ok
         ai(2, cnj=C3, d=antes, fatal=du(15), tasks=tk(du(15))),                   # divergência de data (1 dia)
         ai(3, cnj=C4, d=ontem, fatal=du(10)),                                      # prazo sem tarefa
         ai(4, cnj=C4, d=antes, fatal=du(9), tasks=tk(du(11))),                    # prazo incorreto
         ai(5, cnj=C4, d=antes, dup="duplicada", status="lida", tipo="outros"),     # duplicada no Atlas
         ai(6, cnj=C1, d=antes, cli=False, rev=True, tipo="outros", status="nao_lida")]  # sem cliente + revisão + não lida
# estas verificações simulam o módulo de intimações do Atlas contratado (0041); sem ele, vale a 0044 (test_etapa14)
q("update parametros set valor = 'true'::jsonb where chave = 'atlas_modulo_intimacoes'")
r0 = J("select double_check_atlas_executar(null, 'manual')")
check("Antes da 1ª sincronização das intimações: nada comparado, só a pendência de sincronizar (0043)", "0|1",
      f"{q(chr(39).join(['select count(*) from inconsistencias where tipo=', 'intimacao_nao_cadastrada', '']))}|{q(chr(39).join(['select count(*) from inconsistencias where chave like ', 'atlas_sem_sync|%', '']))}")
recusa("Peticionador não registra intimações", f"select atlas_registrar_intimacoes({lit(intim)})", COLAB, "Somente")
check("Intimações do Atlas registradas", "6", J(f"select atlas_registrar_intimacoes({lit(intim)})")["registradas"])
r1 = J("select double_check_atlas_executar(null, 'manual')")
tipos = lambda: dict(q("select string_agg(tipo || '=' || n, ',' order by tipo) from (select tipo, count(*) n from inconsistencias where situacao='aberta' group by tipo) z").split(",") and
                     [x.split("=") for x in q("select string_agg(tipo || '=' || n, ',' order by tipo) from (select tipo, count(*) n from inconsistencias where situacao='aberta' group by tipo) z").split(",")])
t1 = tipos()
check("Não cadastrada no Atlas (C2)", "1", t1.get("intimacao_nao_cadastrada"))
check("Divergências: data (C3) e intimação sem cliente confirmado", "2", t1.get("divergencia"))
check("Prazo não lançado (intimação com prazo sem tarefa)", "1", t1.get("prazo_nao_lancado"))
check("Prazo lançado incorretamente (fatal da tarefa ≠ calculado)", "1", t1.get("prazo_incorreto"))
check("Duplicadas: cópia na Webjur e duplicata no Atlas", "2", t1.get("publicacao_duplicada"))
check("Pendências: revisão manual, não lida no fim do expediente", "True",
      int(t1.get("pendencia_controladoria", 0)) >= 2 and q("select count(*) from inconsistencias where chave like 'nao_tratada|%'") == "1")
check("Relatório diário gravado com o resumo", "manual|True", f"{q('select origem from relatorios_diarios order by id desc limit 1')}|{r1['abertas'] >= 8}")
# correção no Atlas: a intimação 3 ganhou tarefa; a 4 teve o prazo corrigido
intim[2]["tasks"] = tk(du(10)); intim[3]["tasks"] = tk(du(9), du(5))
J(f"select atlas_registrar_intimacoes({lit(intim[2:4])})")
r2 = J("select double_check_atlas_executar(null, 'automatico')", servico=True)
check("Rotina automática (chave de serviço): corrigidas no Atlas viram 'regularizada'", "2|automatico",
      f"{r2['regularizadas']}|{q('select origem from relatorios_diarios order by id desc limit 1')}")
check("Nada novo na segunda execução", "0", r2["novas"])
inc = q("select id from inconsistencias where tipo='publicacao_duplicada' and situacao='aberta' order by id limit 1")
recusa("Diretoria não trata inconsistência", f"select inconsistencia_tratar({inc}, 'justificada', 'Cópia conhecida da Webjur')", DIR, "Somente")
J(f"select inconsistencia_tratar({inc}, 'justificada', 'Cópia conhecida do caderno do DJe')")
r3 = J("select double_check_atlas_executar(null, 'manual')")
check("Justificada continua justificada na execução seguinte", "justificada", q(f"select situacao from inconsistencias where id={inc}"))
rel = J("select relatorio_inconsistencias('aberta', null, 100)", DIR)
check("Diretoria lê o relatório", "True", len(rel["itens"]) > 0 and rel["ultimo_relatorio"] is not None)
recusa("Peticionador não lê o relatório", "select relatorio_inconsistencias()", COLAB, "Somente")
J(f"select atlas_registrar_produtividade(hoje_brasilia() - 10, hoje_brasilia(), {lit([{'user_id': U_OUTRO, 'name': 'OUTRO', 'active': True, 'tasks_completed': 20, 'active_days': 8}])})")
dr = J("select diretoria_resumo()", DIR)
check("Painel da diretoria: pendências, solicitações e produtividade (média por dia ativo)", "True|0|2.5",
      f"{dr['inconsistencias_abertas'] > 0}|{dr['solicitacoes_aguardando']}|{dr['produtividade']['membros'][0]['media_por_dia_ativo']}")
check("Pendência 'Webjur não importada hoje' some quando há coleta do dia", "0", q("select count(*) from inconsistencias where chave like 'webjur_nao_importada|%' and situacao='aberta'"))

ok = sum(1 for r in res if r[3] == "OK")
for r in res: print(("OK   " if r[3] == "OK" else "FALHA") + " | " + r[0] + ("" if r[3] == "OK" else f" | esperado={r[1]} obtido={r[2]}"))
print(f"\n{ok}/{len(res)} verificações OK")
raise SystemExit(0 if ok == len(res) else 1)
