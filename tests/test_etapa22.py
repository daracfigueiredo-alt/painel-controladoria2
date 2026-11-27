"""Testes dos Workflows jurídicos (0063 fase 1 e 0065 prazos recursais, 26–27/11/2026). Banco LOCAL, dados FICTÍCIOS.
As duas migrações foram escritas no computador da Dara e já estão aplicadas no Supabase. Aqui se confere o motor
(dependências, condições, sub-fluxos, PF a confirmar, decisão do líder) e as permissões. Nada é criado no Atlas."""
import json, subprocess, os, uuid
PSQL = ["psql", "-h", os.environ.get("PGHOST", "/tmp"), "-p", os.environ.get("PGPORT", "5433"), "-U", "postgres", "-At", "-q", "-v", "ON_ERROR_STOP=1"]
HERE = os.path.dirname(os.path.abspath(__file__)); MIGDIR = os.path.join(HERE, "..", "supabase", "migrations")
MIG = sorted(os.path.join(MIGDIR, f) for f in os.listdir(MIGDIR)); DB = "ctrl_etapa22"; res = []
ADMIN = "00000000-0000-0000-0000-00000000000a"; ADV = "00000000-0000-0000-0000-00000000000c"; OUTRO = "00000000-0000-0000-0000-00000000000e"
LIDER = "00000000-0000-0000-0000-0000000000b1"; DIRET = "00000000-0000-0000-0000-0000000000d1"

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
tid = lambda inst, pref: q(f"select id from wf_tarefas where instancia_id={inst} and titulo like '{pref}%'")
lit = lambda o: "$J$" + json.dumps(o, ensure_ascii=False) + "$J$::jsonb"

subprocess.run(PSQL + ["-d", "postgres", "-c", f"drop database if exists {DB}", "-c", f"create database {DB}"], check=True, capture_output=True)
for f in [os.path.join(HERE, "00_stub_supabase_local.sql")] + MIG:
    subprocess.run(PSQL + ["-d", DB, "-f", f], check=True, capture_output=True)
q(f"""insert into equipes(nome) values ('Prime'),('Gold') on conflict do nothing;
  insert into colaboradores(nome_advbox, origem, equipe_id, atlas_user_id) values
    ('ADVOGADA PRIME','administrativo',(select id from equipes where nome='Prime'),'{uuid.uuid4()}'),
    ('ASSISTENTE PRIME','administrativo',(select id from equipes where nome='Prime'),'{uuid.uuid4()}'),
    ('BRENDA MARTINS','administrativo',(select id from equipes where nome='Prime'),'{uuid.uuid4()}'),
    ('ADVOGADO GOLD','administrativo',(select id from equipes where nome='Gold'),'{uuid.uuid4()}');
  insert into equipes_assistentes(equipe_id, colaborador_id) values ((select id from equipes where nome='Prime'),(select id from colaboradores where nome_advbox='ASSISTENTE PRIME'));
  insert into auth.users (id, email) values ('{ADMIN}','admin@x.invalid'),('{ADV}','adv@x.invalid'),('{OUTRO}','gold@x.invalid'),
    ('{LIDER}','brendamartinsoecadv@gmail.com'),('{DIRET}','marianacamiloadv@gmail.com');
  insert into perfis values ('{ADMIN}','admin',null),('{ADV}','colaborador',(select id from colaboradores where nome_advbox='ADVOGADA PRIME')),
    ('{OUTRO}','colaborador',(select id from colaboradores where nome_advbox='ADVOGADO GOLD'));
  select set_config('controladoria.motivo','teste local',false);
  update perfis set colaborador_id = (select id from colaboradores where nome_advbox='BRENDA MARTINS') where user_id = '{LIDER}';
  update parametros set valor = '"controladoria@x.invalid"' where chave = 'wf_controladoria_email';""")
PRIME = q("select id from equipes where nome='Prime'"); ADVID = q("select id from colaboradores where nome_advbox='ADVOGADA PRIME'")
HOJE = q("select hoje_brasilia()"); PF = q("select somar_dias_uteis(hoje_brasilia(), 15)")
check("Brenda (0061) entra como líder da Prime", "lider|Prime",
      q(f"select p.papel || '|' || e.nome from perfis p join lideres_equipes le on le.user_id = p.user_id join equipes e on e.id = le.equipe_id where p.user_id = '{LIDER}'"))
check("Criação no Atlas começa desligada", "false", q("select valor #>> '{}' from parametros where chave = 'wf_criar_no_atlas'"))
check("Modelos: mestre, decisão, 11 recursos e rotinas", "18", q("select count(*) from wf_modelos"))

base = {"cnj": "0000001-65.2026.8.13.0024", "cliente": "C362 - CLIENTE FICTÍCIO", "origem_tipo": "manual", "data_recebimento": HOJE,
        "data_ciencia": HOJE, "modalidade_intimacao": "DJEN", "natureza": "Despacho", "providencia": "MANIFESTAÇÃO",
        "advogado_colaborador_id": int(ADVID), "equipe_id": int(PRIME), "pf": PF}
recusa("Triagem incompleta é recusada", f"select wf_iniciar({lit({k: v for k, v in base.items() if k != 'pf'})})", ADMIN, "Falta: prazo fatal (PF)")
for nome, uid in [("Advogado", ADV), ("Líder", LIDER), ("Diretoria", DIRET)]:
    recusa(f"{nome} não abre fluxo (triagem é da controladoria)", f"select wf_iniciar({lit(base)})", uid, "Somente a controladoria")

# ---------------------------------------------------------------- fluxo-mestre
d = J(f"select wf_iniciar({lit(base)})"); M = d["id"]
st = lambda det: {e["codigo"]: e["status"] for e in det["etapas"]}
check("Mestre: análise liberada para a advogada; o resto espera a análise terminar", "liberada|ADVOGADA PRIME|aguardando|aguardando",
      f"{st(d)['analise']}|{[e for e in d['etapas'] if e['codigo']=='analise'][0]['responsavel']}|{st(d)['peca']}|{st(d)['documentos']}")
recusa("Advogado de outra equipe não vê o fluxo", f"select wf_detalhe({M})", OUTRO, "Somente quem participa")
check("A advogada do fluxo vê", M, J(f"select wf_detalhe({M})", ADV)["id"])
check("A líder da equipe vê", M, J(f"select wf_detalhe({M})", LIDER)["id"])
check("Lista da advogada: 1 fluxo; do advogado da Gold: 0", "1|0", f"{len(J('select wf_listar()', ADV)['itens'])}|{len(J('select wf_listar()', OUTRO)['itens'])}")
recusa("Advogado de outra equipe não decide", f"select wf_decidir({M}, '{{\"precisa_peca\": true}}')", OUTRO, "Somente o advogado do fluxo")
d = J(f"select wf_decidir({M}, '{{\"precisa_peca\": true, \"precisa_documentos\": false, \"precisa_comunicacao\": false}}')", ADV)
check("Decisões registradas antes de concluir a análise: as etapas continuam esperando a análise", "aguardando|aguardando|aguardando",
      f"{st(d)['documentos']}|{st(d)['peca']}|{st(d)['ciencia']}")
recusa("Advogado não muda decisão já registrada", f"select wf_decidir({M}, '{{\"precisa_peca\": false}}')", ADV, "só a controladoria corrige")
recusa("Conclusão manual exige justificativa", f"select wf_etapa_manual({tid(M, 'ANALISAR')}, 'concluir', 'curta')", ADMIN, "justificativa")
d = J(f"select wf_etapa_manual({tid(M, 'ANALISAR')}, 'concluir', 'Análise feita fora do Atlas (teste)')")
check("Análise concluída: documentos, comunicação e ciência dispensados pelas decisões", "dispensada|dispensada|dispensada",
      f"{st(d)['documentos']}|{st(d)['comunicacao']}|{st(d)['ciencia']}")
check("Análise concluída: a peça é liberada com prazo até PF − 3 dias úteis", f"liberada|{q(f'select somar_dias_uteis(hoje_brasilia(), 3)')}",
      f"{st(d)['peca']}|{[e for e in d['etapas'] if e['codigo']=='peca'][0]['prazo']}")
check("Etapa da controladoria vai para o e-mail do parâmetro (sem erro de responsável)", "0",
      q(f"select count(*) from wf_tarefas where instancia_id in (select id from wf_instancias where raiz_id={M}) and status='sem_responsavel'"))
check("Sem a criação ligada, nada vai para o Atlas", "False|0", f"{J('select wf_para_criar()')['ligado']}|{len(J('select wf_para_criar()')['tarefas'])}")
recusa("Cancelar exige motivo", f"select wf_cancelar({M}, 'curto')", ADMIN, "motivo")
J(f"select wf_cancelar({M}, 'Fluxo de teste encerrado pela controladoria')")
check("Cancelado: nenhuma etapa aberta", "cancelado|0", q(f"select status || '|' || (select count(*) from wf_tarefas where instancia_id={M} and status not in ('concluida','dispensada','cancelada')) from wf_instancias where id={M}"))
recusa("Histórico dos fluxos é imutável", "delete from wf_eventos", None, "")

# ---------------------------------------------------------------- decisão judicial e recurso (0065)
s = J(f"select wf_sugerir_pf('APELACAO', '{HOJE}', false, '{base['cnj']}')")
check("PF sugerido da Apelação: 15 dias úteis do TJMG", q(f"select somar_dias_uteis('{HOJE}'::date, 15, '8.13')"), s["pf"])
check("Prazo em dobro: 30 dias úteis", q(f"select somar_dias_uteis('{HOJE}'::date, 30, '8.13')"), J(f"select wf_sugerir_pf('APELACAO', '{HOJE}', true, '{base['cnj']}')")["pf"])
dec = dict(base, modelo="DECISAO", natureza="Sentença", origem_id="t-dec-1", origem_tipo="manual", dados={"tipo_decisao": "Sentença", "resultado": "Desfavorável"})
d = J(f"select wf_iniciar({lit(dec)})"); D = d["id"]
check("Decisão: análise para a advogada e comunicação aberta como fluxo filho", "liberada|em_subfluxo", f"{st(d)['analise']}|{st(d)['comunicacao']}")
recusa("Escolha múltipla com opção inexistente", f"select wf_decidir({D}, '{{\"recorrer\": true, \"recurso\": [\"XYZ\"]}}')", ADV, "Opção inválida")
d = J(f"select wf_decidir({D}, '{{\"embargos\": false, \"recorrer\": true, \"recurso\": [\"APELACAO\"]}}')", ADV)
J(f"select wf_etapa_manual({tid(D, 'ANALISAR')}, 'concluir', 'Análise feita fora do Atlas (teste)')")
d = J(f"select wf_detalhe({D})")
check("Só a Apelação vira fluxo; Embargos e dispensa ficam de fora", "em_subfluxo|dispensada|dispensada|dispensada",
      f"{st(d)['rec_apelacao']}|{st(d)['rec_recurso_especial']}|{st(d)['embargos']}|{st(d)['dispensa']}")
ap = [e for e in d["etapas"] if e["codigo"] == "rec_apelacao"][0]["filho"]
check("Apelação com o PF sugerido, a confirmar: peça espera o PF; análise e comunicação não se repetem",
      f"False|{s['pf']}|aguardando_pf|dispensada|dispensada", f"{ap['pf_confirmado']}|{ap['pf_sugerido']}|{st(ap)['peca']}|{st(ap)['analise']}|{st(ap)['comunicacao']}")
AP = ap["id"]
recusa("Advogado não confirma o PF", f"select wf_confirmar_pf({AP}, '{s['pf']}')", ADV, "Somente a controladoria")
outro_pf = q(f"select somar_dias_uteis('{s['pf']}'::date, -1)")
recusa("PF diferente do sugerido exige motivo", f"select wf_confirmar_pf({AP}, '{outro_pf}')", ADMIN, "informe o motivo")
d = J(f"select wf_confirmar_pf({AP}, '{s['pf']}')")
ap = [e for e in d["etapas"] if e["codigo"] == "rec_apelacao"][0]["filho"]
check("PF confirmado: a peça da Apelação é liberada para a advogada", "True|liberada", f"{ap['pf_confirmado']}|{st(ap)['peca']}")
recusa("PF já confirmado não muda por aqui", f"select wf_confirmar_pf({AP}, '{outro_pf}', 'Tentativa de mudar o PF depois')", ADMIN, "já foi confirmado")

# ---------------------------------------------------------------- dispensa de recurso: só o líder aprova (0065)
d = J(f"select wf_iniciar({lit(dict(dec, origem_id='t-dec-2'))})"); D2 = d["id"]
J(f"select wf_decidir({D2}, '{{\"embargos\": false, \"recorrer\": false}}')", ADV)
J(f"select wf_etapa_manual({tid(D2, 'ANALISAR')}, 'concluir', 'Análise feita fora do Atlas (teste)')")
d = J(f"select wf_detalhe({D2})"); dis = [e for e in d["etapas"] if e["codigo"] == "dispensa"][0]["filho"]
J(f"select wf_etapa_manual({tid(dis['id'], 'REGISTRAR JUSTIFICATIVA')}, 'concluir', 'Justificativa registrada (teste)')")
d = J(f"select wf_detalhe({dis['id']})")
check("Aprovação da dispensa vai para a líder da equipe", "liberada|BRENDA MARTINS",
      f"{st(d)['aprovar']}|{[e for e in d['etapas'] if e['codigo']=='aprovar'][0]['responsavel']}")
recusa("A advogada não aprova a própria dispensa", f"select wf_decidir({dis['id']}, '{{\"dispensa_aprovada\": true}}')", ADV, "Somente o líder da equipe ou a controladoria")
J(f"select wf_decidir({dis['id']}, '{{\"dispensa_aprovada\": true}}')", LIDER); d = J(f"select wf_detalhe({dis['id']})")
check("Decisão da líder registrada; as etapas seguintes esperam a tarefa de aprovação ser concluída", "aguardando|aguardando",
      f"{st(d)['comunicar']}|{st(d)['reavaliar']}")
J(f"select wf_etapa_manual({tid(dis['id'], 'APROVAR')}, 'concluir', 'Aprovação concluída (teste)')"); d = J(f"select wf_detalhe({dis['id']})")
check("Aprovação concluída: comunicação ao cliente liberada para a assistente; reavaliação dispensada", "liberada|ASSISTENTE PRIME|dispensada",
      f"{st(d)['comunicar']}|{[e for e in d['etapas'] if e['codigo']=='comunicar'][0]['responsavel']}|{st(d)['reavaliar']}")
check("Diretoria vê, mas não decide", "True|False", f"{J(f'select wf_detalhe({D2})', DIRET)['id'] == D2}|{J(f'select wf_detalhe({D2})', DIRET)['pode_decidir']}")

for n_, e, o, s_ in res: print(f"[{s_}] {n_}" + ("" if s_ == "OK" else f"\n    esperado: {e}\n    obtido:   {o}"))
falhas = sum(1 for r in res if r[3] != "OK"); print(f"\n{len(res) - falhas}/{len(res)} verificações OK")
if not os.environ.get("MANTER"): subprocess.run(PSQL + ["-d", "postgres", "-c", f"drop database {DB}"], capture_output=True)
raise SystemExit(1 if falhas else 0)
