"""Testes da Etapa 2 (migração 0008): processos/CNJ, calendário por foro, equipes,
publicações Webjur, double check, tarefas de análise, logs, conferência de alertas.
PostgreSQL LOCAL descartável; dados FICTÍCIOS (CNJs gerados, não são processos reais)."""
import json, subprocess, hashlib, os, sys, datetime
PSQL = ["psql", "-h", "/tmp", "-p", "5433", "-U", "postgres", "-At", "-q", "-v", "ON_ERROR_STOP=1"]
HERE = os.path.dirname(os.path.abspath(__file__))
MIGDIR = os.path.join(HERE, "..", "supabase", "migrations")
MIG = sorted(os.path.join(MIGDIR, f) for f in os.listdir(MIGDIR))
ADMIN, COLAB, COLAB2 = ("00000000-0000-0000-0000-00000000000a", "00000000-0000-0000-0000-00000000000c",
                        "00000000-0000-0000-0000-0000000000dd")
DB = "ctrl_etapa2"
res = []

def run(sql, uid=None, ok_error=False, role=None):
    pre = f"set role authenticated; set request.jwt.claim.sub = '{uid}';\n" if uid else (f"set role {role};\n" if role else "")
    p = subprocess.run(PSQL + ["-d", DB], input=pre + sql, capture_output=True, text=True)
    if p.returncode and not ok_error: raise RuntimeError(sql[:200] + "\n" + p.stderr)
    return p.stdout.strip(), p.stderr.strip(), p.returncode
def q(sql, uid=None): return run(sql, uid)[0]
def erro(sql, uid=None, role=None):
    _, e, rc = run(sql, uid, ok_error=True, role=role); return e if rc else ''
def check(nome, esperado, obtido):
    res.append((nome, str(esperado), str(obtido), "OK" if str(esperado) == str(obtido) else "FALHA"))

def cnj_ficticio(seq, ano=2026, j='8', tr='05', foro='0024'):
    """Gera um CNJ com dígito verificador correto (cálculo independente do banco)."""
    n = f"{seq:07d}"; dd = 98 - (int(f"{n}{ano}{j}{tr}{foro}") * 100 % 97)
    return f"{n}-{dd:02d}.{ano}.{j}.{tr}.{foro}"

subprocess.run(PSQL + ["-d", "postgres", "-c", f"drop database if exists {DB}", "-c", f"create database {DB}"], check=True, capture_output=True)
for f in [os.path.join(HERE, "00_stub_supabase_local.sql")] + MIG:
    subprocess.run(PSQL + ["-d", DB, "-f", f], check=True, capture_output=True)
run(f"""insert into colaboradores(nome_advbox, origem) values ('TESTE COLAB A','administrativo'),('TESTE COLAB B','administrativo');
  insert into perfis values ('{ADMIN}','admin',null),
   ('{COLAB}','colaborador',(select id from colaboradores where nome_advbox='TESTE COLAB A')),
   ('{COLAB2}','colaborador',(select id from colaboradores where nome_advbox='TESTE COLAB B'));""")

# ================================================================= CNJ
C1, C2, C3 = cnj_ficticio(1), cnj_ficticio(2), cnj_ficticio(3, foro='0702')
check("CNJ: só dígitos -> formato padrão", C1, q(f"select normalizar_cnj('{C1.replace('-','').replace('.','')}')"))
check("CNJ: espaços e pontuação extra", C1, q(f"select normalizar_cnj(' {C1.replace('.', ' . ')} ')"))
check("CNJ: menos de 20 dígitos -> nulo", "", q("select normalizar_cnj('123-45.2026')"))
check("CNJ: dígito verificador correto (cálculo independente em Python)", "t", q(f"select cnj_digito_valido('{C1}')"))
errado = C1[:8] + ('00' if C1[8:10] != '00' else '01') + C1[10:]
check("CNJ: dígito verificador errado detectado", "f", q(f"select cnj_digito_valido('{errado}')"))
check("CNJ: foro (OOOO) extraído", "0702", q(f"select foro_do_cnj('{C3}')"))

# ================================================================= importação -> processos
CAB = ['Prioridade','Data','Hora','Término','Hora Término','Prazo fatal','Data Conclusão','Pontuação','Compromisso',
       'Local','Remetente','Destinatário','Partes','Processo (CNJ)','Protocolo','Tipo de ação','Observações']
def linha(data, pf, comp, cnj='', obs='', dest='TESTE COLAB A', concl=''):
    b = {c: '' for c in CAB}
    b.update({'Prioridade':'NORMAL','Remetente':'TESTE REMETENTE','Destinatário':dest,'Tipo de ação':'TESTE',
              'Data':data,'Prazo fatal':pf,'Compromisso':comp,'Observações':obs,'Data Conclusão':concl,'Processo (CNJ)':cnj})
    return b
def importar(nome, linhas, lote=None, extra=''):
    j = json.dumps(linhas, ensure_ascii=False); h = hashlib.sha256((nome + j).encode()).hexdigest()
    return json.loads(q(f"select importar_arquivo($N${nome}$N$,'{h}',$J${j}$J$::jsonb,{'null' if lote is None else lote}{extra})", ADMIN))
r = importar('e2_lote1.xlsx', [
    linha('26/10/2026','03/11/2026','TESTE FORO', C3, 'TF - Prazo 15 dias. PF: 03/11.'),
    linha('26/10/2026','03/11/2026','TESTE OUTRO FORO', C1, 'TF - PF: 03/11.'),
    linha('26/10/2026','30/10/2026','TESTE COLAB B', C2, 'TF - PF: 30/10.', dest='TESTE COLAB B'),
    linha('26/10/2026','30/10/2026','TESTE SEM CNJ', '', 'x')])
check("Importação registra processos (3 CNJs distintos)", "3|3", f"{r['processos_novos']}|{q('select count(*) from processos')}")
check("Processo: tribunal e foro derivados do CNJ", "8.05|0702|true", q(f"select tribunal_cnj||'|'||foro_cnj||'|'||cnj_digito_valido from processos where cnj='{C3}'"))
check("Colaborador vê só processos das próprias tarefas", "2", q("select count(*) from processos", COLAB))

# ================================================================= calendário por foro
check("Colaborador não cadastra feriado", "negado",
      "negado" if "Somente administradores" in erro("select admin_cadastrar_dia_nao_util('2026-10-28','foro','feriado','x','y','8.05','0702')", COLAB) else "?")
check("Feriado sem fundamento é recusado", "recusado",
      "recusado" if "fundamento" in erro("select admin_cadastrar_dia_nao_util('2026-10-28','foro','feriado','Feriado municipal fictício','','8.05','0702')", ADMIN) else "?")
q("select admin_cadastrar_dia_nao_util('2026-10-28','foro','feriado','TESTE feriado municipal fictício','Lei municipal fictícia','8.05','0702')", ADMIN)
check("D-4 com feriado MUNICIPAL do foro (PF 03/11; 02/11 Finados; 28/10 no foro)", "2026-10-27", q("select calcular_d4('2026-11-03','8.05','0702')"))
check("Mesmo tribunal, outro foro: feriado municipal não se aplica", "2026-10-28", q("select calcular_d4('2026-11-03','8.05','0024')"))
check("Função de 2 argumentos mantida (compatibilidade)", "2026-10-28", q("select calcular_d4('2026-11-03','8.05')"))
check("Painel aplica o foro do CNJ ao D-4", "2026-10-27|2026-10-28",
      q("select string_agg(d4_regra::text, '|' order by compromisso) from v_tarefas_atuais where compromisso in ('TESTE FORO','TESTE OUTRO FORO')", ADMIN))
check("Cadastro de feriado auditado", "1", q("select count(*) from eventos where tipo='cadastro_administrativo' and evidencia->>'operacao'='cadastrar_dia_nao_util'"))
check("Abrangência foro exige código de 4 dígitos", "recusado",
      "recusado" if "calendario_abrangencia_check" in erro("select admin_cadastrar_dia_nao_util('2026-10-29','foro','feriado','x','y','8.05','72')", ADMIN) else "?")

# ================================================================= equipes
cid = q("select id from colaboradores where nome_advbox='TESTE COLAB A'")
check("Colaborador não define equipe", "negado", "negado" if "Somente administradores" in erro(f"select admin_definir_equipe({cid},'Bancário')", COLAB) else "?")
q(f"select admin_definir_equipe({cid},'TESTE EQUIPE BANCÁRIO')", ADMIN)
check("Equipe definida e auditada", "TESTE EQUIPE BANCÁRIO|1",
      q(f"select e.nome||'|'||(select count(*) from eventos where tipo='cadastro_administrativo' and evidencia->>'operacao'='definir_equipe') from colaboradores c join equipes e on e.id=c.equipe_id where c.id={cid}"))
check("Equipe disponível no painel (filtro)", "t", q("select bool_and(equipe_id is not null) from v_tarefas_atuais where responsavel='TESTE COLAB A'", ADMIN))

# ================================================================= publicações
def pub(cnj, teor, data='04/11/2026', disp='03/11/2026'):
    return json.dumps({"cnj": cnj, "data_publicacao": data, "data_disponibilizacao": disp, "tribunal": "TJMG",
                       "orgao_julgador": "TESTE 1ª Vara Fictícia", "teor": teor}, ensure_ascii=False)
def registrar(p, origem='webjur_portal', idorig=None, uid=ADMIN):
    io = 'null' if idorig is None else f"'{idorig}'"
    return json.loads(q(f"select pub_registrar($P${p}$P$::jsonb,'{origem}',{io})", uid))
TEOR_A = "TESTE FICTÍCIO. Intimação: manifeste-se a parte autora sobre o laudo no prazo de 15 dias.\nLinha 2 do teor."
pa = registrar(pub(C1, TEOR_A), idorig='portal-1')
check("Publicação nova registrada", "nova|t", f"{pa['status']}|{str(pa['cnj_digito_valido']).lower()[0]}")
pa2 = registrar(pub(C1, TEOR_A), idorig='portal-1')
check("Mesma publicação, mesma fonte: não duplica", "ja_registrada|False", f"{pa2['status']}|{pa2['coleta_nova']}")
pa3 = registrar(pub(C1.replace('-', '').replace('.', ''), "  " + TEOR_A.upper() + "  "), origem='webjur_gmail', idorig='msg-abc')
check("Mesma publicação pelo Gmail (CNJ sem pontuação, teor com espaços/maiúsculas): 1 publicação, 2 coletas",
      f"ja_registrada|{pa['publicacao_id']}|2", f"{pa3['status']}|{pa3['publicacao_id']}|{q('select count(*) from publicacoes_coletas')}")
pb = registrar(pub(C1, "TESTE FICTÍCIO. Outra publicação do mesmo processo e mesma data: designada audiência."), idorig='portal-2')
check("Publicação diferente, mesmo processo e data: NÃO é eliminada", "nova|2", f"{pb['status']}|{q(f'select count(*) from publicacoes where cnj=$${C1}$$')}")
check("Teor integral preservado sem alteração", "t", q(f"select teor = $T${TEOR_A}$T$ from publicacoes where id={pa['publicacao_id']}", ADMIN))
pv = registrar(json.dumps({"cnj": C2, "teor": "   "}))
check("Publicação sem teor: rejeitada, com log e evento de erro", "rejeitada|1|1",
      f"{pv['status']}|{q('select count(*) from log_integracao where nivel=$$erro$$')}|{q('select count(*) from eventos where tipo=$$erro_integracao$$')}")
check("Colaborador não registra publicação", "negado", "negado" if "Somente a controladoria" in erro(f"select pub_registrar($P${pub(C1,'x')}$P$::jsonb,'webjur_portal')", COLAB) else "?")
check("Colaborador não lê publicações", "0", q("select count(*) from publicacoes", COLAB))
check("Publicação é imutável", "bloqueado", "bloqueado" if "imutável" in erro("update publicacoes set teor='x'") else "?")
PNC = cnj_ficticio(9999)
pc = registrar(pub(PNC, "TESTE FICTÍCIO. Processo que não existe no ADVBOX: cite-se."), idorig='portal-3')
pd = registrar(pub(C2, "TESTE FICTÍCIO. Publicação encontrada no ADVBOX."), idorig='portal-4')
pe = registrar(pub(C3, "TESTE FICTÍCIO. Conferência com erro de acesso."), idorig='portal-5')
pf_ = registrar(pub(C3, "TESTE FICTÍCIO. Correspondência inconclusiva."), idorig='portal-6')

# ================================================================= double check
def conferir(pid, sit, area, evid, uid=ADMIN, ok=False):
    sql = f"select pub_registrar_conferencia({pid},'{sit}','{area}',$E${json.dumps(evid, ensure_ascii=False)}$E$::jsonb,'77001')"
    return run(sql, uid, ok_error=ok)
_, e, rc = conferir(pd['publicacao_id'], 'encontrada_advbox', 'publicacoes', {"processo": "localizado"}, ok=True)
check("'Encontrada' sem a publicação específica no ADVBOX é recusada", "recusado", "recusado" if rc and "check" in e else e[:80])
conferir(pd['publicacao_id'], 'encontrada_advbox', 'publicacoes', {"publicacao_advbox": {"data": "04/11/2026", "trecho": "Publicação encontrada"}})
_, e, rc = conferir(pe['publicacao_id'], 'erro_acesso_advbox', 'nenhuma', {}, ok=True)
check("Erro de acesso exige descrição do erro", "recusado", "recusado" if rc else "aceito")
conferir(pe['publicacao_id'], 'erro_acesso_advbox', 'nenhuma', {"erro": "sessão do ADVBOX expirada"})
conferir(pf_['publicacao_id'], 'inconclusiva', 'publicacoes', {"motivo": "duas publicações parecidas"})
check("Erro de acesso e inconclusiva NÃO preparam tarefa", "0", q(f"select count(*) from tarefas_analise where publicacao_id in ({pe['publicacao_id']},{pf_['publicacao_id']})"))
ra = json.loads(conferir(pa['publicacao_id'], 'nao_encontrada_advbox', 'ambas', {"publicacoes_listadas": 3, "movimentacoes_listadas": 10})[0])
check("Ausente no ADVBOX prepara tarefa de análise", "preparada", q(f"select status from tarefas_analise where id={ra['tarefa_analise_preparada']}"))
ta = ra['tarefa_analise_preparada']; PA_ID = pa['publicacao_id']
obs = q(f"select observacoes from tarefas_analise where id={ta}")
check("Observações começam com a origem WEBJUR e a data", "True", obs.startswith("WEBJUR — Disponibilizada em 03/11/2026."))
check("Observações trazem número, tribunal, órgão e o TEOR INTEGRAL", "True",
      all(s in obs for s in [f"Número do processo: {C1}.", "Tribunal: TJMG.", "Órgão julgador: TESTE 1ª Vara Fictícia.",
                              "TEOR INTEGRAL DA PUBLICAÇÃO:", TEOR_A]))
check("Responsável e tipo da tarefa", "Mayra Gomes|ANÁLISE DO CASO (50 pts)", q(f"select responsavel||'|'||tipo from tarefas_analise where id={ta}"))
check("Tarefa vinculada ao processo", "t", q(f"select processo_id = (select id from processos where cnj='{C1}') from tarefas_analise where id={ta}"))
ra2 = json.loads(conferir(pa['publicacao_id'], 'nao_encontrada_advbox', 'ambas', {"repeticao": True})[0])
check("Nova conferência da mesma publicação NÃO cria 2ª tarefa", f"None|{ta}|1",
      f"{ra2['tarefa_analise_preparada']}|{ra2['tarefa_analise_existente']}|{q(f'select count(*) from tarefas_analise where publicacao_id={PA_ID}')}")
rc_ = json.loads(conferir(pc['publicacao_id'], 'processo_nao_cadastrado', 'nenhuma', {"busca_cnj": PNC, "resultado": "nenhum processo"})[0])
tc = rc_['tarefa_analise_preparada']
check("Processo não cadastrado: sem vínculo inventado, marcada para cadastro", "true||true",
      q(f"select requer_cadastro||'|'||coalesce(processo_id::text,'')||'|'||(observacoes like '%ATENÇÃO: processo não localizado no ADVBOX%' and observacoes like '%{PNC}%') from tarefas_analise where id={tc}"))

# ================================================================= aprovação e criação
check("Colaborador não aprova", "negado", "negado" if "Somente a controladoria" in erro(f"select analise_decidir({ta},'aprovar')", COLAB) else "?")
check("Criação antes da aprovação é recusada", "recusado", "recusado" if "não permitida" in erro(f"select analise_iniciar_criacao({ta})", ADMIN) else "?")
check("Rejeição sem motivo é recusada", "recusado", "recusado" if "motivo" in erro(f"select analise_decidir({ta},'rejeitar')", ADMIN) else "?")
q(f"select analise_decidir({ta},'aprovar','Conferido: ausente no ADVBOX')", ADMIN)
payload = json.loads(q(f"select analise_iniciar_criacao({ta})", ADMIN))
check("Início da criação devolve o conteúdo a lançar", "Mayra Gomes|ANÁLISE DO CASO (50 pts)|True",
      f"{payload['responsavel']}|{payload['tipo']}|{payload['observacoes'] == obs}")
check("Segunda tentativa de criação (extensão reaberta) é recusada", "recusado",
      "recusado" if "criacao_em_andamento" in erro(f"select analise_iniciar_criacao({ta})", ADMIN) else "?")
q(f"select analise_falha_criacao({ta},'Tempo esgotado ao salvar no ADVBOX', false)", ADMIN)
check("Falha incerta -> verificar no ADVBOX antes de recriar", "verificar_no_advbox|recusado",
      f"{q(f'select status from tarefas_analise where id={ta}')}|" + ("recusado" if "verificar_no_advbox" in erro(f"select analise_iniciar_criacao({ta})", ADMIN) else "?"))
q(f"""select analise_confirmar_criacao({ta},'888001','{{"conferido_na_lista":true}}'::jsonb)""", ADMIN)
check("Confirmação com o ID da tarefa criada", "criada|888001", q(f"select status||'|'||advbox_tarefa_id from tarefas_analise where id={ta}"))
check("Tarefa criada não volta a ser criada", "recusado", "recusado" if erro(f"select analise_iniciar_criacao({ta})", ADMIN) else "?")
check("Histórico completo da tarefa de análise", "preparada>aprovada>criacao_em_andamento>verificar_no_advbox>criada",
      q(f"select string_agg(status_novo,'>' order by id) from tarefas_analise_historico where tarefa_analise_id={ta}"))
check("Histórico é imutável", "bloqueado", "bloqueado" if "imutável" in erro("update tarefas_analise_historico set nota='x'") else "?")
check("Decisões registradas na auditoria geral", "4", q(f"select count(*) from eventos where tipo='tarefa_analise_status' and evidencia->>'tarefa_analise_id'='{ta}'"))
# aprovação recusada quando a conferência mais recente encontrou a publicação
conferir(pc['publicacao_id'], 'encontrada_advbox', 'publicacoes', {"publicacao_advbox": {"id": "x"}, "nota": "processo cadastrado depois"})
check("Aprovação recusada se a última conferência encontrou a publicação", "recusado",
      "recusado" if "Aprovação recusada" in erro(f"select analise_decidir({tc},'aprovar')", ADMIN) else "?")
q(f"select analise_decidir({tc},'ja_tratada','Publicação já capturada após cadastro do processo')", ADMIN)
check("Marcada como já tratada", "ja_tratada", q(f"select status from tarefas_analise where id={tc}"))

# ================================================================= relatório diário
d = json.loads(q("select row_to_json(v) from v_double_check_diario v", ADMIN))
# recebidas: pa, pb, pc, pd, pe, pf_ = 6 ; última conferência: pa ausente, pc encontrada, pd encontrada, pe erro, pf_ inconclusiva, pb sem conferência
check("Relatório diário: recebidas/com conferência/encontradas/ausentes/não cadastrado",
      "6|5|2|1|0", f"{d['recebidas']}|{d['com_conferencia']}|{d['encontradas']}|{d['ausentes']}|{d['processo_nao_cadastrado']}")
check("Relatório diário: inconclusivas/erros/aprovadas/criadas", "1|1|1|1",
      f"{d['inconclusivas']}|{d['erros_integracao']}|{d['tarefas_aprovadas']}|{d['tarefas_criadas']}")
check("% ausentes só sobre conferidas efetivas (1 de 3), sem erros e inconclusivas", "33.3", d['pct_ausentes_sobre_conferidas'])

# ================================================================= log, alertas, segurança
# 0029 (Etapa 9): o log só é gravado pelas funções do próprio banco; ninguém grava direto.
q("insert into log_integracao (origem, nivel, operacao, mensagem) values ('advbox_extensao','aviso','teste','TESTE aviso fictício')")
check("Colaborador NÃO grava log de integração direto (0029)", "recusado", "recusado" if run("select registrar_log_integracao('advbox_extensao','aviso','teste','x')", COLAB, ok_error=True)[2] else "aceito")
check("Colaborador não lê o log", "0", q("select count(*) from log_integracao", COLAB))
lin = q("select linha_id from v_alertas where categoria='pf_judicial_vencido' and compromisso='TESTE COLAB B'", ADMIN)
check("Há alerta de PF Judicial vencido para conferir (fixture)", "True", lin != '')
check("Nota curta demais na conferência do alerta é recusada", "recusado",
      "recusado" if erro(f"select admin_conferir_alerta({lin},'pf_judicial_vencido','providencia_em_outra_tarefa','curta')", ADMIN) else "?")
q(f"select admin_conferir_alerta({lin},'pf_judicial_vencido','providencia_em_outra_tarefa','Protocolo feito na tarefa de PROTOCOLO da mesma pasta em 29/10.')", ADMIN)
check("Alerta conferido aparece como conferido; os demais seguem pendentes", "conferido|providencia_em_outra_tarefa|true",
      q(f"select max(situacao_conferencia) filter (where linha_id={lin} and categoria='pf_judicial_vencido')||'|'||max(conferencia_resultado) filter (where linha_id={lin})||'|'||bool_or(situacao_conferencia='pendente_conferencia') from v_alertas_conferencia", ADMIN))
check("Anônimo não executa funções da Webjur", "negado", "negado" if "permission denied" in erro(f"select pub_registrar('{{}}'::jsonb,'manual')", role='anon') else "?")
tabs = ['processos','equipes','publicacoes','publicacoes_coletas','conferencias_publicacao','tarefas_analise',
        'tarefas_analise_historico','log_integracao','conferencias_alerta']
check("Anônimo não lê nenhuma tabela nova", "9", sum(1 for t in tabs if "permission denied" in erro(f"select count(*) from {t}", role='anon')))
check("Colaborador não grava direto nas tabelas novas", "9",
      sum(1 for t in tabs if "permission denied" in erro(f"delete from {t}", COLAB)))
check("Funções internas não expostas ao usuário", "negado", "negado" if "permission denied" in erro("select _analise_status(1, array['x'], 'y', null)", ADMIN) else "?")

w = max(len(x[0]) for x in res)
for n, e, o, s in res:
    print(f"{s:5} | {n:<{w}} | esperado: {e} | obtido: {o}")
print(f"\n{sum(1 for x in res if x[3]=='OK')}/{len(res)} OK — executado em {datetime.datetime.now():%d/%m/%Y %H:%M}")
sys.exit(0 if all(x[3] == "OK" for x in res) else 1)
