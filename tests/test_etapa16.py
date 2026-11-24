"""Testes da migração 0051 (painel de audiências). Banco LOCAL, dados FICTÍCIOS.
As intimações imitam os formatos reais vistos no CNJ e na Webjur em 14/11/2026 (texto reescrito, partes fictícias)."""
import json, subprocess, hashlib, os
PSQL = ["psql", "-h", "/tmp", "-p", "5433", "-U", "postgres", "-At", "-q", "-v", "ON_ERROR_STOP=1"]
HERE = os.path.dirname(os.path.abspath(__file__)); MIGDIR = os.path.join(HERE, "..", "supabase", "migrations")
MIG = sorted(os.path.join(MIGDIR, f) for f in os.listdir(MIGDIR)); DB = "ctrl_etapa16"; res = []
ADMIN = "00000000-0000-0000-0000-00000000000a"; COLAB = "00000000-0000-0000-0000-00000000000c"
LIDER = "00000000-0000-0000-0000-0000000000d1"; DIR = "00000000-0000-0000-0000-0000000000d9"
OUTRO_U = "00000000-0000-0000-0000-0000000000e2"
U_ANA = "11111111-1111-4111-8111-111111111111"

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
def cnj(seq, ano=2026, j=8, tr=13, orig=24):
    n = f"{seq:07d}"; r = f"{ano}{j}{tr:02d}{orig:04d}"
    dv = 98 - int(n + r + "00") % 97
    return f"{n}-{dv:02d}.{ano}.{j}.{tr:02d}.{orig:04d}"

subprocess.run(PSQL + ["-d", "postgres", "-c", f"drop database if exists {DB}", "-c", f"create database {DB}"], check=True, capture_output=True)
for f in [os.path.join(HERE, "00_stub_supabase_local.sql")] + MIG:
    subprocess.run(PSQL + ["-d", DB, "-f", f], check=True, capture_output=True)
q(f"""insert into colaboradores(nome_advbox, origem, equipe_id) values ('ANA ADVOGADA','administrativo',(select id from equipes where nome='Celeste')),
    ('OUTRO','administrativo',(select id from equipes where nome='Gold')), ('BRENDA','administrativo',(select id from equipes where nome='Celeste'));
  insert into auth.users (id, email) values ('{ADMIN}','a@x.invalid'),('{COLAB}','c@x.invalid'),('{LIDER}','l@x.invalid'),('{DIR}','d@x.invalid'),('{OUTRO_U}','o@x.invalid');
  insert into perfis values ('{ADMIN}','admin',null), ('{COLAB}','colaborador',(select id from colaboradores where nome_advbox='ANA ADVOGADA')),
    ('{LIDER}','lider',(select id from colaboradores where nome_advbox='BRENDA')), ('{DIR}','diretoria',null),
    ('{OUTRO_U}','colaborador',(select id from colaboradores where nome_advbox='OUTRO'));
  insert into lideres_equipes (user_id, equipe_id) values ('{LIDER}', (select id from equipes where nome='Celeste'));""")
ANA = q("select id from colaboradores where nome_advbox='ANA ADVOGADA'")
HOJE = q("select hoje_brasilia()")
d = lambda n: q(f"select (hoje_brasilia() + {n})::text")
br = lambda iso: f"{iso[8:10]}/{iso[5:7]}/{iso[0:4]}"
MESES = ['janeiro','fevereiro','março','abril','maio','junho','julho','agosto','setembro','outubro','novembro','dezembro']
ext = lambda iso: f"{int(iso[8:10])} de {MESES[int(iso[5:7]) - 1]} de {iso[0:4]}"
P = {k: cnj(5000 + i) for i, k in enumerate(["video", "estacao", "projudi", "eproc", "deixo", "redesig", "semtarefa", "outraeq", "passada"])}

# ------------------------------------------------------------ extração (formatos reais)
X = lambda texto, ref=HOJE: q(f"select coalesce((_audiencia_extrair($T${texto}$T$, '{ref}') - 'trecho')::text, 'null')")
check("Formato TRT (videoconferência, dd/mm/aaaa às hh:mm)", '{"data": "' + d(5) + '", "hora": "08:23", "link": null, "tipo": "Conciliação", "modalidade": "virtual", "redesignacao": false}',
      X(f"Diante do interesse conciliatório manifestado, designo audiência para conciliação por videoconferência no dia {br(d(5))} às 08:23 horas e esclareço"))
check("Data por extenso e estação passiva = presencial; depoimento pessoal = instrução",
      '{"data": "' + d(9) + '", "hora": "14:30", "link": null, "tipo": "Instrução (depoimento/testemunhas)", "modalidade": "presencial", "redesignacao": false}',
      X(f"Defiro o depoimento pessoal e, para tanto, designo audiencia para o dia {ext(d(9))}, as 14:30 horas. Devera comparecer na estacao passiva localizada na Comarca"))
check("Projudi: data entre parênteses é a do ato (sem data da audiência)", '{"data": null, "hora": null, "link": null, "tipo": "Conciliação", "modalidade": null, "redesignacao": false}',
      X(f"Intimação referente ao movimento (seq. 68) AUDIÊNCIA DE CONCILIAÇÃO DESIGNADA ({br(d(-9))}). Acesse o sistema Projudi"))
check("eproc com HTML: data do evento não é a da audiência", '{"data": null, "hora": null, "link": null, "tipo": "Conciliação", "modalidade": null, "redesignacao": false}',
      X(f"<p>O ato refere-se ao seguinte evento:</p><p>Evento 29 - {br(d(-80))} - Audiência de Conciliação designada conduzida por Juiz(a)</p>"))
for n, t in [("deixo de designar", "adequo o procedimento e deixo de designar a audiencia de conciliacao do art. 334 do CPC"),
             ("interesse na realização", "Manifestem as partes sobre o interesse na realizacao de audiencia de conciliacao"),
             ("eventual audiência", "eventual audiencia sera realizada por videoconferencia, atraves da plataforma Microsoft Teams"),
             ("resultado infrutífero", "Tendo em vista o resultado infrutífero da audiência de conciliação, determino"),
             ("conveniência da audiência", "deixo para momento oportuno a analise da conveniencia da audiencia de conciliacao")]:
    check(f"Não é designação: {n}", "null", X(t))
check("Redesignação híbrida com link do Teams", '{"data": "' + d(20) + '", "hora": "09:30", "link": "https://teams.microsoft.com/l/meetup-join/abc123", "tipo": "Instrução e julgamento", "modalidade": "híbrida", "redesignacao": true}',
      X(f"Fica redesignada a audiência de instrução e julgamento para o dia {br(d(20))}, às 9h30, de forma híbrida. Link: https://teams.microsoft.com/l/meetup-join/abc123."))
check("'Anteriormente designada' ignorada; vale a nova (ano com 2 dígitos)", '{"data": "' + d(25) + '", "hora": "15:00", "link": null, "tipo": "Conciliação", "modalidade": "virtual", "redesignacao": true}',
      X(f"Considerando que a audiência anteriormente designada restou prejudicada, DESIGNO nova audiência de conciliação para o dia {br(d(25))[:6]}{d(25)[2:4]}, às 15h, por videoconferência"))

ANO = d(80)
check("Ano com ponto (\"2.027\") e link encurtado do Teams (0052)", '{"data": "' + ANO + '", "hora": "14:30", "link": "https://tinyurl.com/e9f6nf2c", "tipo": "Conciliação", "modalidade": "virtual", "redesignacao": false}',
      X(f"bem como de que foi designada audiencia de Conciliacao, na modalidade virtual, para o dia {int(ANO[8:10])} de {MESES[int(ANO[5:7]) - 1].capitalize()} de {ANO[0]}.{ANO[1:4]}, as 14h30, horario oficial. Clicar no link: https://tinyurl.com/e9f6nf2c, sendo que"))
CEJUSC = ("Considerando que a audiência anteriormente designada restou prejudicada, DEFIRO a renovação. Determino a remessa dos autos ao CEJUSC para designação de nova data "
          "para audiência de conciliação. A citação deverá ocorrer com antecedência mínima de 20 (vinte) dias da audiência, conforme art. 334. Intime-se a parte autora acerca da nova data designada.")
check("Não é designação: remessa ao CEJUSC para designar nova data (0052)", "null", X(CEJUSC))
check("Não é designação: 'designada' da frase seguinte não vale para a anterior (0053)", "null",
      X("Requer a renovação da citação, bem como a redesignação da audiência de conciliação. Considerando que a audiência anteriormente designada restou prejudicada, DEFIRO."))
check("'Mantenho a audiência designada' = audiência existente, sem data", '{"data": null, "hora": null, "link": null, "tipo": "Conciliação", "modalidade": null, "redesignacao": false}',
      X("3) MANTENHO a audiencia de conciliacao designada. CUMPRA-SE o expediente da audiencia."))

# releitura (0052): audiência lida pela regra antiga é descartada ou ganha a data, sem apagar nada
PR1, PR2 = cnj(5900), cnj(5901)
for i, (proc, texto) in enumerate([(PR1, CEJUSC), (PR2, f"foi designada audiencia de Conciliacao para o dia {int(ANO[8:10])} de {MESES[int(ANO[5:7]) - 1]} de {ANO[0]}.{ANO[1:4]}, as 14h30")]):
    q(f"""insert into cnj_comunicacoes (id, cnj, numero_processo, data_disponibilizacao, texto, dados) values ({990 + i}, '{proc}', '{proc}', '{HOJE}', $T${texto}$T$, '{{}}');
          insert into audiencias (chave, cnj, disponibilizada_em) values ('{proc}|sem-data:{HOJE}|', '{proc}', '{HOJE}');
          insert into audiencia_fontes (origem, origem_id, audiencia_id, achou, data_disponibilizacao) values ('cnj', '{990 + i}', (select id from audiencias where cnj='{proc}'), true, '{HOJE}');""")
r = J("select _audiencias_reler()", servico=True) if False else json.loads(q("select _audiencias_reler()"))
check("Releitura: 1 descartada e 1 atualizada com a data", "1|1", f"{r['descartadas']}|{r['atualizadas']}")
check("Releitura: a falsa fica 'descartada' (não apagada) e a outra ganha data e hora", f"descartada|{ANO}|14:30",
      f"{q(f'select situacao from audiencias where cnj={chr(39)}{PR1}{chr(39)}')}|{q(f'select data from audiencias where cnj={chr(39)}{PR2}{chr(39)}')}|{q(f'select hora from audiencias where cnj={chr(39)}{PR2}{chr(39)}')}")

# ------------------------------------------------------------ leitura das intimações (CNJ + Webjur)
def com(i, proc, texto, disp=HOJE):
    q(f"""insert into cnj_comunicacoes (id, cnj, numero_processo, data_disponibilizacao, texto, nome_orgao, link, dados)
          values ({i}, '{proc}', '{proc}', '{disp}', $T${texto}$T$, 'Vara Fictícia', 'https://comunica.pje.jus.br/x/{i}', '{{}}')""")
def pub(i, proc, texto, disp=HOJE):
    q(f"""insert into publicacoes (cnj, cnj_digito_valido, data_disponibilizacao, tribunal, teor, teor_hash, conteudo_original, chave_dedupe, id_documento)
          values ('{proc}', true, '{disp}', 'TJMG', $T${texto}$T$, md5('{i}'), '{{}}', 'pub-{i}', null)""")
T_VIDEO = f"designo audiência para conciliação por videoconferência no dia {br(d(5))} às 08:23 horas"
com(1, P["video"], T_VIDEO); com(2, P["video"], T_VIDEO); pub(1, P["video"], T_VIDEO.upper())      # 2 destinatários no CNJ + Webjur
pub(2, P["estacao"], f"designo audiencia para o dia {ext(d(9))}, as 14:30 horas. Devera comparecer na estacao passiva")
com(3, P["projudi"], f"AUDIÊNCIA DE CONCILIAÇÃO DESIGNADA ({br(d(-2))}). Acesse o sistema Projudi", d(-1))
pub(3, P["deixo"], "deixo de designar a audiencia de conciliacao do art. 334 do CPC")
com(4, P["redesig"], f"designo audiência de conciliação para o dia {br(d(12))}, às 10:00, presencial", d(-3))
com(5, P["semtarefa"], f"designo audiência de conciliação para o dia {br(d(3))}, às 11:00")
com(6, P["outraeq"], f"designo audiência de conciliação para o dia {br(d(4))}, às 16:00")
com(7, P["passada"], f"designo audiência de mediação para o dia {br(d(-1))}, às 13:00", d(-6))
# clientes: equipe pela letra do código (C = Celeste, G = Gold)
for k, nome in [("video", "C100 - Cliente Vídeo Ltda"), ("estacao", "C200 - Cliente Estação"), ("semtarefa", "C300 - Cliente Tarefa"),
                ("outraeq", "G400 - Cliente Gold"), ("passada", "C500 - Cliente Passado"), ("redesig", "C600 - Cliente Redesignado")]:
    q(f"insert into cnj_carteira (cnj, origens, cliente) values ('{P[k]}', '{{atlas}}', '{nome}')")

recusa("Peticionador não roda a leitura", "select audiencias_ler()", COLAB, "Somente")
r = J("select audiencias_ler()")
check("Leitura: 10 intimações, 9 com audiência, 7 audiências", "10|9|7", f"{r['lidas']}|{r['com_audiencia']}|{r['novas']}")
check("Mesma audiência em 2 comunicações do CNJ e na Webjur = 1 audiência com 3 fontes", "1|3",
      q(f"select count(*)||'|'||(select count(*) from audiencia_fontes f join audiencias a2 on a2.id=f.audiencia_id where a2.cnj='{P['video']}') from audiencias where cnj='{P['video']}'"))
check("'Deixo de designar' não vira audiência (fonte lida sem audiência)", "0|false",
      q(f"select (select count(*) from audiencias where cnj='{P['deixo']}')||'|'||(select achou from audiencia_fontes where origem='webjur' and origem_id=(select id::text from publicacoes where cnj='{P['deixo']}'))"))
check("Projudi sem data: audiência com data a confirmar", "|Conciliação", q(f"select coalesce(data::text,'')||'|'||tipo from audiencias where cnj='{P['projudi']}'"))
r = J("select audiencias_ler()")
check("Nova leitura não relê o que já foi lido", "0", r["lidas"])
com(8, P["redesig"], f"Fica redesignada a audiência de conciliação para o dia {br(d(15))}, às 10:00")
J("select audiencias_ler()")
check("Redesignação: a anterior passa a 'redesignada' e a nova fica agendada", f"{d(12)}:redesignada,{d(15)}:agendada",
      q(f"select string_agg(data||':'||situacao, ',' order by data) from audiencias where cnj='{P['redesig']}'"))

# ------------------------------------------------------------ painel, equipes e pendências
p = J("select audiencias_painel(null, null, null, null, null)", DIR)
check("Sem cobrança de tarefa no Atlas por padrão (0055: a equipe ainda não usa o Atlas para audiências)", "False",
      any("sem_tarefa_atlas" in x["pendencias"] for x in p["itens"]))
q("update parametros set valor = 'true'::jsonb where chave = 'audiencias_cobrar_tarefa_atlas'")   # o resto da suíte cobre a cobrança ligada
q(f"insert into cnj_carteira (cnj, origens, cliente) values ('{cnj(5998)}', '{{atlas}}', 'A662 - Cliente da equipe extinta')")
check("Regra da equipe confirmada; código 'A' (equipe extinta) fica sem equipe", "t|",
      q("select confirmado from parametros where chave='equipes_por_letra'") + "|" + q(f"select coalesce(_audiencia_cliente_equipe('{cnj(5998)}')->>'equipe', '')"))
p = J("select audiencias_painel(null, null, null, null, null)", DIR)
by = {x["cnj"]: x for x in p["itens"] if x["situacao"] == "agendada"}
check("Diretoria lê o painel; equipe pela letra do código do cliente", "Celeste|Gold|C100 - Cliente Vídeo Ltda",
      f"{by[P['video']]['equipe']}|{by[P['outraeq']]['equipe']}|{by[P['video']]['cliente']}")
check("Pendências: sem data", "['sem_data', 'sem_advogado']", by[P["projudi"]]["pendencias"])
check("Pendências: em 3 dias, sem advogado e sem tarefa no Atlas", "True",
      set(by[P["semtarefa"]]["pendencias"]) >= {"sem_advogado", "sem_tarefa_atlas"})
check("Audiência que já passou sem ata", "['sem_ata']", [x for x in p["itens"] if x["cnj"] == P["passada"]][0]["pendencias"])
check("Indicadores do painel", "True", p["contagem"]["sem_data"] == 1 and p["contagem"]["sem_ata"] == 1 and p["contagem"]["proximos_7"] >= 3)
check("Filtro por equipe", "1", len(J("select audiencias_painel(null, null, 'Gold', null, null)", DIR)["itens"]))
check("Filtro por pendência", "1", len(J("select audiencias_painel(null, null, null, 'sem_data', null)", DIR)["itens"]))
check("Link da certidão do CNJ nas fontes", "True", any(f["link"] for f in by[P["video"]]["fontes"] if f["origem"] == "cnj"))

# tarefa de audiência no Atlas (título com 'audiência' e o número do processo, vencendo antes) tira a pendência
nomes = {U_ANA: "ANA ADVOGADA"}
tarefas = [{"id": "a0000000-0000-4000-8000-000000000001", "title": f"Audiência de conciliação {P['semtarefa']}", "description": "preparar cliente",
            "due_date": d(1), "fatal_date": d(3), "assignees": [{"user_id": U_ANA, "name": "ANA ADVOGADA", "is_principal": True, "completed_at": None}]}]
linhas = subprocess.run(["node", os.path.join(HERE, "atlas", "linhas_ficticias.mjs"), "json", json.dumps(nomes), json.dumps(tarefas)],
                        capture_output=True, text=True, check=True).stdout
J(f"select atlas_mapear_usuarios({lit([{'id': U_ANA, 'name': 'ANA ADVOGADA'}])})")
J(f"select importar_arquivo('Atlas e16','{hashlib.sha256(linhas.encode()).hexdigest()}',$J${linhas}$J$::jsonb,null,now(),false)")
p = J("select audiencias_painel(null, null, null, null, null)", DIR)
by = {x["cnj"]: x for x in p["itens"] if x["situacao"] == "agendada"}
check("Com a tarefa de audiência no Atlas a pendência some", "False", "sem_tarefa_atlas" in by[P["semtarefa"]]["pendencias"])
check("Outra audiência continua sem tarefa", "True", "sem_tarefa_atlas" in by[P["outraeq"]]["pendencias"])

# ------------------------------------------------------------ designar, confirmar, corrigir, resultado e permissões
A = lambda k: q(f"select id from audiencias where cnj='{P[k]}' and situacao in ('agendada') order by id limit 1")
recusa("Peticionador não designa", f"select audiencia_designar({A('semtarefa')}, {ANA}, null)", COLAB, "Somente")
recusa("Líder não designa em equipe que não acompanha (Gold)", f"select audiencia_designar({A('outraeq')}, {ANA}, null)", LIDER, "Somente")
SEMP = "00000000-0000-0000-0000-0000000000ff"; q(f"insert into auth.users (id, email) values ('{SEMP}','s@x.invalid') on conflict do nothing")
recusa("Usuário sem perfil não designa nem registra ata", f"select audiencia_designar({A('semtarefa')}, {ANA}, null)", SEMP, "Somente")
recusa("Diretoria não designa", f"select audiencia_designar({A('semtarefa')}, {ANA}, null)", DIR, "Somente")
r = J(f"select audiencia_designar({A('semtarefa')}, {ANA}, 'Preposto Fictício')", LIDER)
check("Líder da equipe (Celeste) designa advogado e preposto", "ANA ADVOGADA", r["advogado"])
recusa("Confirmar sem advogado é recusado", f"select audiencia_confirmar({A('outraeq')}, 'x')", ADMIN, "Designe o advogado")
J(f"select audiencia_confirmar({A('semtarefa')}, 'Cliente avisado por telefone')", COLAB)
p = J("select audiencias_painel(null, null, null, null, null)", COLAB)
check("Advogado designado confirma e vê só as suas audiências", "1|ANA ADVOGADA|True",
      f"{len(p['itens'])}|{p['itens'][0]['advogado']}|{p['itens'][0]['confirmada_em'] is not None}")
check("Outro peticionador não vê audiências que não são suas", "0", len(J("select audiencias_painel(null, null, null, null, null)", OUTRO_U)["itens"]))
recusa("Correção exige motivo", f"select audiencia_corrigir({A('projudi')}, '{d(30)}', '10:00', null, 'presencial', null, 'curto')", ADMIN, "motivo")
recusa("Correção valida a hora", f"select audiencia_corrigir({A('projudi')}, '{d(30)}', '25:00', null, 'presencial', null, 'Data conferida no processo')", ADMIN, "Hora")
J(f"select audiencia_corrigir({A('projudi')}, '{d(30)}', '10:00', null, 'presencial', null, 'Data conferida no Projudi pela controladoria')")
check("Data completada pela controladoria: sai de 'sem data'", f"{d(30)}|10:00|False",
      f"{q('select data from audiencias where cnj=' + chr(39) + P['projudi'] + chr(39))}|{q('select hora from audiencias where cnj=' + chr(39) + P['projudi'] + chr(39))}|"
      + str("sem_data" in [x for x in J("select audiencias_painel(null, null, null, null, null)", DIR)["itens"] if x["cnj"] == P["projudi"]][0]["pendencias"]))
PAS = q(f"select id from audiencias where cnj='{P['passada']}'")
recusa("Resultado antes da audiência é recusado", f"select audiencia_registrar_resultado({A('semtarefa')}, 'acordo', 'Acordo fechado em audiência com desconto')", ADMIN, "no dia da audiência")
recusa("Ata curta é recusada", f"select audiencia_registrar_resultado({PAS}, 'acordo', 'ok')", ADMIN, "mínimo 20")
J(f"select audiencia_registrar_resultado({PAS}, 'acordo', 'Acordo homologado em audiência: pagamento em 10 parcelas.')", LIDER)
check("Líder registra a ata; audiência realizada sem pendência", "realizada|acordo|[]",
      f"{q('select situacao from audiencias where id=' + PAS)}|{q('select resultado from audiencias where id=' + PAS)}|"
      + json.dumps([x for x in J("select audiencias_painel(null, null, null, null, null)", DIR)["itens"] if x["id"] == int(PAS)][0]["pendencias"]))
check("Histórico da audiência (identificada, designação, confirmação, correção, resultado)", "t",
      q("select count(distinct tipo) >= 6 from audiencia_eventos"))
c, o, e = run("update audiencia_eventos set tipo='correcao'"); check("Histórico imutável", "recusado", "recusado" if c else "aceito")
check("Lista de advogados para controladoria e líder", "True", len(J('select audiencias_advogados()', LIDER)) >= 3)
recusa("Lista de advogados fechada para o peticionador", "select audiencias_advogados()", COLAB, "Somente")
c, o, e = run("select count(*) from audiencias", COLAB); check("Tabela fechada (só pelas funções)", "recusado", "recusado" if c else "aceito")

# ------------------------------------------------------------ double check
J("select double_check_atlas_executar(null, 'manual')", ADMIN)
inc = q("select string_agg(dados->>'pendencia', ',' order by dados->>'pendencia') from inconsistencias where tipo='audiencia_pendente' and situacao='aberta'")
check("Double check: pendências das audiências entram no relatório", "True", "sem_tarefa_atlas" in inc and "sem_advogado" in inc and "sem_ata" not in inc)
check("Double check: audiência em até 7 dias sem tarefa = gravidade alta", "1",
      q(f"select gravidade from inconsistencias where tipo='audiencia_pendente' and cnj='{P['outraeq']}' and dados->>'pendencia'='sem_tarefa_atlas'"))

ok = sum(1 for x in res if x[3] == "OK")
for n, e, o, s in res: print(f"{s:5} {n}" + ("" if s == "OK" else f"\n      esperado: {e}\n      obtido:   {o}"))
print(f"\n{ok}/{len(res)} OK")
if os.environ.get("MANTER") != "1":
    subprocess.run(PSQL + ["-d", "postgres", "-c", f"drop database if exists {DB}"], capture_output=True)
if ok != len(res): raise SystemExit(1)
