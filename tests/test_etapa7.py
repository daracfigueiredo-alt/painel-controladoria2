"""Testes da Etapa 7 (0016): double check Webjur x ADVBOX. Banco LOCAL, dados FICTÍCIOS.
Publicações: e-mails fictícios da Etapa 6 (mesmo leitor do painel). Intimações do ADVBOX: no formato
que a extensão envia (ext_registrar_varredura), com a estrutura conferida na tela real em 06/11/2026."""
import json, subprocess, hashlib, os, sys, datetime
PSQL = ["psql", "-h", "/tmp", "-p", "5433", "-U", "postgres", "-At", "-q", "-v", "ON_ERROR_STOP=1"]
HERE = os.path.dirname(os.path.abspath(__file__)); RAIZ = os.path.join(HERE, "..")
MIGDIR = os.path.join(RAIZ, "supabase", "migrations"); FX = os.path.join(HERE, "webjur", "fixtures")
MIG = sorted(os.path.join(MIGDIR, f) for f in os.listdir(MIGDIR)); DB = "ctrl_etapa7"; res = []
ADMIN, COLAB = "00000000-0000-0000-0000-00000000000a", "00000000-0000-0000-0000-00000000000c"
def run(sql, uid=None, role=None, ok_error=False):
    pre = f"set role authenticated; set request.jwt.claim.sub = '{uid}';\n" if uid else (f"set role {role};\n" if role else "")
    p = subprocess.run(PSQL + ["-d", DB], input=pre + sql, capture_output=True, text=True)
    if p.returncode and not ok_error: raise RuntimeError(sql[:300] + "\n" + p.stderr)
    return p.stdout.strip(), p.stderr.strip(), p.returncode
q = lambda sql, uid=None: run(sql, uid)[0]
J = lambda sql, uid=ADMIN: json.loads(q(sql, uid))
def check(n, e, o): res.append((n, str(e), str(o), "OK" if str(e) == str(o) else "FALHA"))
def recusa(n, sql, uid=None, role=None, trecho=""):
    _, e, rc = run(sql, uid, role, ok_error=True)
    check(n, "recusado", "recusado" if rc and trecho in e else (e[:80] or "aceito"))

subprocess.run(["python3", os.path.join(HERE, "webjur", "gerar_fixtures.py")], check=True, capture_output=True)
subprocess.run(PSQL + ["-d", "postgres", "-c", f"drop database if exists {DB}", "-c", f"create database {DB}"], check=True, capture_output=True)
for f in [os.path.join(HERE, "00_stub_supabase_local.sql")] + MIG:
    subprocess.run(PSQL + ["-d", DB, "-f", f], check=True, capture_output=True)
q(f"""insert into colaboradores(nome_advbox, origem) values ('TESTE COLAB A','administrativo');
  insert into perfis values ('{ADMIN}','admin',null), ('{COLAB}','colaborador',(select id from colaboradores limit 1));""")

LER = """const W=require(process.argv[1]),fs=require('fs'),c=require('crypto');const f=process.argv[2];
const rs=W.lerEmails(new Uint8Array(fs.readFileSync(f)),f);
console.log(JSON.stringify(rs.map(r=>({sha:c.createHash('sha256').update(r.texto_bloco).digest('hex'),
 remessa:{formato:r.formato,recebido_em:r.recebido_em,secoes:r.secoes.map(s=>({ordem:s.ordem,caderno:s.caderno,data:s.data,declarado:s.declarado})),avisos:r.avisos},
 publicacoes:r.publicacoes.map(p=>W.paraRegistro(p,r))}))));"""
def importar(nome):
    out = subprocess.run(["node", "-e", LER, os.path.join(RAIZ, "painel", "js", "webjur_email.js"), os.path.join(FX, nome)], capture_output=True, text=True, check=True).stdout
    for d in json.loads(out):
        J(f"select pub_registrar_remessa('{nome}','{d['sha']}',$R${json.dumps(d['remessa'], ensure_ascii=False)}$R$::jsonb,$P${json.dumps(d['publicacoes'], ensure_ascii=False)}$P$::jsonb)")
importar("email_ficticio_1.html"); importar("email_ficticio_divergente.html"); importar("email_ficticio_secoes_repetidas.html")
pid = lambda doc: q(f"select id from publicacoes where id_documento='{doc}'")
PID_UNIAO = q("select id from publicacoes where cnj='0000201-72.2026.8.13.0024'")

CORPO = ("PROCEDIMENTO COMUM CIVEL ADV: ADVOGADA FICTICIA DE TESTE (OAB 999999/MG) AUTOR: Empresa Ficticia Ltda "
         "REU: Outra Empresa Ficticia S.A. {t} POLO ATIVO: EMPRESA FICTICIA LTDA")
def intim(post, cnj, data, teor, lawsuit="600000001", cap="2026-10-05T01:21:00-03:00", orgao="TJAL - 1ª VARA CÍVEL FICTÍCIA"):
    return {"post_id": post, "cnj": cnj, "data_publicacao": data, "tribunal": "TJAL", "orgao": orgao, "capturada_em": cap,
            "lawsuit_id": lawsuit, "partes": "T001 - EMPRESA FICTICIA LTDA", "nome_pesquisado": "Advogada Ficticia de Teste",
            "teor": f"{orgao}\nProcesso: {cnj}\n{teor}", "url_inteiro_teor": "https://exemplo.invalid/teor", "situacao": "Pendente"}
def varredura(intims, de="05/10/2026", ate="06/10/2026", total=None, erros=None, uid=ADMIN):
    v = {"pagina": "/publications", "filtro": {"intervalo": "nos últimos 3 dias", "de": f"De: {de}", "ate": f"Até: {ate}"},
         "recebido_de": de, "recebido_ate": ate, "total_informado": len(intims) if total is None else total, "erros": erros or []}
    return J(f"select ext_registrar_varredura($V${json.dumps(v, ensure_ascii=False)}$V$::jsonb,$I${json.dumps(intims, ensure_ascii=False)}$I$::jsonb)", uid)
A1, A2, A3, MG = "0000101-95.2026.8.02.0001", "0000102-80.2026.8.02.0001", "0000103-65.2026.8.02.0001", "0000201-72.2026.8.13.0024"

# ---------------------------------------------------------------- varredura e registro das intimações
v1 = varredura([
    intim("700000002", A1, "06/10/2026", CORPO.format(t="Segundo despacho ficticio: intime-se o perito.")),   # fora de ordem de propósito
    intim("700000001", A1, "06/10/2026", CORPO.format(t="Primeiro despacho ficticio: cite-se.")),
    intim("700000003", MG, "05/10/2026", "PROCESSOS DISTRIBUÍDOS PROCESSO: " + MG + " CLASSE JUDICIAL: APELACAO CIVEL APELANTE: EMPRESA FICTICIA LTDA DATA DISTRIBUICAO: 05/10/2026",
          lawsuit=None, orgao="TRF1 - VARA FICTÍCIA"),
    intim("700000004", A3, "07/10/2026", CORPO.format(t="Outro texto sobre prazo ficticio unico."), cap="2026-10-06T01:21:00-03:00"),
])
check("Varredura completa registrada (4 lidas = 4 informadas, período De/Até)", "True|4|4", f"{v1['completa']}|{v1['lidas']}|{v1['novas']}")
check("Intimação sem processo vinculado guardada sem lawsuit", "None", q("select coalesce(lawsuit_id,'None') from advbox_intimacoes where post_id='700000003'"))

r = J("select double_check_executar('2026-10-05','2026-10-07')")
sit = lambda p: q(f"select coalesce(situacao_conferencia,'(nenhuma)') from v_publicacoes where id={p}")
check("Mesmo CNJ e data, 2 intimações: cada publicação ligada à SUA intimação (pelo teor)", "encontrada_advbox|700000001|encontrada_advbox|700000002",
      f"{sit(pid('900000001'))}|{q('select evidencia_conferencia->>' + chr(39) + 'publicacao_advbox' + chr(39) + ' from v_publicacoes where id=' + pid('900000001'))}|"
      f"{sit(pid('900000002'))}|{q('select evidencia_conferencia->>' + chr(39) + 'publicacao_advbox' + chr(39) + ' from v_publicacoes where id=' + pid('900000002'))}")
check("Encontrada: evidência com semelhança, data e área 'intimacoes'", "intimacoes|true",
      q(f"select area_conferida||'|'||((evidencia->>'semelhanca')::numeric >= 0.85)::text from conferencias_publicacao where publicacao_id={pid('900000001')}"))
check("Processo vinculado gravado no cadastro de processos", "600000001", q(f"select advbox_lawsuit_id from processos where cnj='{A1}'"))
check("Publicação sem intimação no ADVBOX, varredura completa cobre a data → não encontrada", "nao_encontrada_advbox", sit(pid('900000003')))
check("Não encontrada: tarefa de análise preparada (não criada)", "preparada|f",
      q(f"select status||'|'||requer_cadastro::text::char from tarefas_analise where publicacao_id={pid('900000003')}"))
check("Intimação capturada sem processo vinculado (N/A) → processo não cadastrado", "processo_nao_cadastrado", sit(PID_UNIAO))
check("Processo não cadastrado: tarefa preparada como 'requer cadastro', sem vínculo", "preparada|t|None",
      q(f"select status||'|'||requer_cadastro::text::char||'|'||coalesce(processo_id::text,'None') from tarefas_analise where publicacao_id={PID_UNIAO}"))
check("Teor só parcialmente semelhante → inconclusiva (sem tarefa)", "inconclusiva|0",
      f"{sit(pid('900000010'))}|{q('select count(*) from tarefas_analise where publicacao_id=' + pid('900000010'))}")
check("Sem varredura que cubra 07/10 a 08/10 → aguardando (nada gravado)", "(nenhuma)|0",
      f"{sit(pid('900000020'))}|{q('select count(*) from conferencias_publicacao where publicacao_id=' + pid('900000020'))}")
check("Resultado lista as aguardando com o motivo", "True",
      any(x['resultado'] == 'aguardando_varredura' and 'cobre' in x['motivo'] for x in r['itens']))

n_conf = q("select count(*) from conferencias_publicacao")
r2 = J("select double_check_executar('2026-10-05','2026-10-07')")
check("Rodar de novo: nenhuma conferência duplicada", n_conf, q("select count(*) from conferencias_publicacao"))
check("Rodar de novo: nenhuma tarefa duplicada", "2", q("select count(*) from tarefas_analise"))

# varredura incompleta não conclui ausência
v2 = varredura([], de="07/10/2026", ate="08/10/2026", total=12)
check("Varredura incompleta (0 de 12) registrada como incompleta", "False", v2['completa'])
J("select double_check_executar('2026-10-07','2026-10-07')")
check("Varredura incompleta não transforma 'aguardando' em 'não encontrada'", "(nenhuma)", sit(pid('900000020')))
v3 = varredura([], de="07/10/2026", ate="08/10/2026", erros=["Intimação 1: janela não lida (HTTP 500)."], total=0)
check("Varredura com erro de leitura: incompleta e com log de erro", "False|1",
      f"{v3['completa']}|{q('select count(*) from log_integracao where operacao=' + chr(39) + 'ext_registrar_varredura' + chr(39))}")

# dois atos da Webjur no mesmo processo e data; o ADVBOX capturou só um
v4 = varredura([intim("700000021", A3, "08/10/2026", CORPO.format(t="Despacho ficticio: defiro a juntada dos documentos apresentados."), cap="2026-10-07T01:21:00-03:00")],
               de="07/10/2026", ate="08/10/2026")
J("select double_check_executar('2026-10-07','2026-10-07')")
check("2 atos no mesmo processo e data, ADVBOX só com um: o capturado é ligado ao ato certo", "encontrada_advbox|700000021",
      f"{sit(pid('900000021'))}|{q('select evidencia_conferencia->>' + chr(39) + 'publicacao_advbox' + chr(39) + ' from v_publicacoes where id=' + pid('900000021'))}")
check("... e o outro ato NÃO é dado como encontrado só por ser do mesmo processo", "nao_encontrada_advbox", sit(pid('900000020')))

# teor da 1ª leitura preservado
varredura([dict(intim("700000001", A1, "06/10/2026", "TEOR ALTERADO"), situacao="Resolvida")])
check("Nova leitura da mesma intimação: teor original mantido, situação atualizada", "true|Resolvida",
      q("select (teor like '%Primeiro despacho%')::text||'|'||situacao_advbox from advbox_intimacoes where post_id='700000001'"))
check("Intimações já lidas (com teor) informadas à extensão", '["700000001"]',
      json.dumps(J("select ext_intimacoes_conhecidas(array['700000001','799999999'])")))
sem_teor = dict(intim("700000002", A1, "06/10/2026", ""), teor=None, situacao="Concluído")
varredura([sem_teor])
check("Intimação conhecida enviada sem teor: teor guardado continua, situação atualizada", "true|Concluído",
      q("select (teor like '%Segundo despacho%')::text||'|'||situacao_advbox from advbox_intimacoes where post_id='700000002'"))
recusa("Colaborador não consulta intimações conhecidas", "select ext_intimacoes_conhecidas(array['1'])", COLAB, trecho="Somente a controladoria")
recusa("Intimação do ADVBOX não pode ser apagada", "delete from advbox_intimacoes", trecho="não são apagadas")
recusa("Varredura é imutável", "update advbox_varreduras set completa=true", trecho="")

# ---------------------------------------------------------------- conferência manual
p10 = pid('900000010')
cand = J(f"select double_check_candidatas({p10})")
check("Candidatas da inconclusiva: intimações do mesmo CNJ, com semelhança", "True|True", f"{'700000004' in [c['post_id'] for c in cand]}|{all('semelhanca' in c for c in cand)}")
recusa("Manual: nota curta recusada", f"select double_check_manual({p10},'encontrada_advbox','700000004','ok')", ADMIN, trecho="mínimo")
recusa("Manual: intimação já ligada a outra publicação recusada", f"select double_check_manual({p10},'encontrada_advbox','700000001','Conferido na tela do ADVBOX.')", ADMIN, trecho="já foi ligada")
J(f"select double_check_manual({p10},'encontrada_advbox','700000004','Conferido na aba Intimações do processo: mesmo despacho.')")
check("Manual: correspondência confirmada pela controladoria", "encontrada_advbox|manual|700000004",
      q(f"select situacao||'|'||origem||'|'||(evidencia->>'publicacao_advbox') from conferencias_publicacao where publicacao_id={p10} order by id desc limit 1"))
J("select double_check_executar('2026-10-05','2026-10-07')")
check("Conferência manual não é desfeita pela execução automática", "encontrada_advbox", sit(p10))

# ---------------------------------------------------------------- relatório diário
d = J("select double_check_diario('2026-10-05','2026-10-07')")
d5 = next(x for x in d if x['dia'] == '2026-10-05')
check("Relatório 05/10: recebidas, encontradas, ausentes, não cadastrado", "4|2|1|1",
      f"{d5['recebidas']}|{d5['encontradas']}|{d5['ausentes']}|{d5['processo_nao_cadastrado']}")
check("Percentual de ausentes só sobre as conferidas efetivas (2 de 4)", "50.0", d5['pct_ausentes'])
d7 = next(x for x in d if x['dia'] == '2026-10-07')
check("Relatório 07/10: 1 encontrada e 2 ausentes (varredura completa de 07 a 08/10)", "3|1|2|0|0", f"{d7['recebidas']}|{d7['encontradas']}|{d7['ausentes']}|{d7['aguardando'] + d7['inconclusivas']}|{d7['processo_nao_cadastrado']}")
L = J("select double_check_listar('2026-10-05','2026-10-07')")
check("Listagem: total, ligação com a intimação do ADVBOX e últimas varreduras", f"{q(chr(39).join(['select count(*) from publicacoes where data_disponibilizacao between ', '2026-10-05', ' and ', '2026-10-07', '']))}|700000001|6",
      f"{L['total']}|{next(x['advbox_post_id'] for x in L['linhas'] if x['publicacao_id'] == int(pid('900000001')))}|{len(L['varreduras'])}")

# ---------------------------------------------------------------- 0018: trava contra ausências em massa
q("update parametros set valor='3' where chave='double_check_dia_min_publicacoes'")
for k in range(3):
    J(f"""select pub_registrar('{{"cnj":"{['0000111-43.2026.8.02.0001','0000112-28.2026.8.02.0001','0000113-13.2026.8.02.0001'][k]}","data_disponibilizacao":"20/10/2026","data_publicacao":"21/10/2026","teor":"Teor ficticio numero {k} para a trava de cobertura com texto suficiente."}}'::jsonb,'manual','trava-{k}')""")
varredura([intim("700000090", "0000999-00.2026.8.02.0001", "21/10/2026", "Outro processo qualquer.")], de="20/10/2026", ate="21/10/2026")
rt = J("select double_check_executar('2026-10-20','2026-10-20')")
check("Dia com 3 publicações e nenhuma intimação do mesmo CNJ no ADVBOX: nada é dado como ausente", "3|0",
      f"{sum(1 for x in rt['itens'] if x['resultado']=='aguardando_varredura' and 'quase nenhuma' in x['motivo'])}|"
      f"{q(chr(39).join(['select count(*) from conferencias_publicacao c join publicacoes p on p.id=c.publicacao_id where p.data_disponibilizacao=', '2026-10-20', '']))}")
varredura([intim("700000091", "0000111-43.2026.8.02.0001", "21/10/2026", "Teor ficticio numero 0 para a trava de cobertura com texto suficiente.")], de="20/10/2026", ate="21/10/2026")
rt = J("select double_check_executar('2026-10-20','2026-10-20')")
check("Com cobertura normal no dia: a trava sai e a comparação segue (1 inconclusiva por texto curto, 2 ausentes)", "1|2",
      f"{sum(1 for x in rt['itens'] if x.get('situacao')=='inconclusiva')}|{sum(1 for x in rt['itens'] if x.get('situacao')=='nao_encontrada_advbox')}")

# ---------------------------------------------------------------- acesso
recusa("Colaborador não registra varredura", "select ext_registrar_varredura('{}'::jsonb,'[]'::jsonb)", COLAB, trecho="Somente a controladoria")
recusa("Colaborador não executa o double check", "select double_check_executar('2026-10-05','2026-10-07')", COLAB, trecho="Somente a controladoria")
check("Colaborador não vê intimações do ADVBOX", "0", q("select count(*) from advbox_intimacoes", COLAB))
recusa("Anônimo não executa", "select double_check_listar('2026-10-05','2026-10-07')", role="anon", trecho="permission denied")
recusa("Período maior que 62 dias recusado", "select double_check_executar('2026-01-01','2026-10-07')", ADMIN, trecho="Período")

w = max(len(x[0]) for x in res)
for n, e, o, s in res: print(f"{s:5} | {n:<{w}} | esperado: {e[:50]} | obtido: {o[:50]}")
print(f"\n{sum(1 for x in res if x[3]=='OK')}/{len(res)} OK — executado em {datetime.datetime.now():%d/%m/%Y %H:%M}")
sys.exit(0 if all(x[3] == "OK" for x in res) else 1)
