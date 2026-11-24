"""Auditoria (Etapa 1) — testes de hipóteses de falha encontradas na leitura do código.
Banco LOCAL descartável, dados FICTÍCIOS. Cada teste informa o comportamento OBSERVADO;
'ACHADO' significa que o comportamento atual diverge do requisito do Prompt Mestre."""
import json, subprocess, hashlib, os, sys
PSQL = ["psql", "-h", "/tmp", "-p", "5433", "-U", "postgres", "-At", "-q", "-v", "ON_ERROR_STOP=1"]
HERE = os.path.dirname(os.path.abspath(__file__))
MIGDIR = os.path.join(HERE, "..", "supabase", "migrations")
MIG = sorted(os.path.join(MIGDIR, f) for f in os.listdir(MIGDIR))
ADMIN = "00000000-0000-0000-0000-00000000000a"
COLAB = "00000000-0000-0000-0000-00000000000c"
COLAB2 = "00000000-0000-0000-0000-0000000000dd"
DB = "ctrl_auditoria"
res = []

def run(sql, uid=None, ok_error=False):
    pre = f"set role authenticated; set request.jwt.claim.sub = '{uid}';\n" if uid else ""
    p = subprocess.run(PSQL + ["-d", DB], input=pre + sql, capture_output=True, text=True)
    if p.returncode and not ok_error: raise RuntimeError(p.stderr)
    return p.stdout.strip(), p.stderr.strip(), p.returncode
q = lambda sql, uid=None: run(sql, uid)[0]

def caso(nome, requisito, obtido, conforme):
    res.append((("OK    " if conforme is True else "DECIDIR" if conforme is None else "ACHADO"), nome, requisito, obtido))

subprocess.run(PSQL + ["-d", "postgres", "-c", f"drop database if exists {DB}", "-c", f"create database {DB}"], check=True, capture_output=True)
for f in [os.path.join(HERE, "00_stub_supabase_local.sql")] + MIG:
    subprocess.run(PSQL + ["-d", DB, "-f", f], check=True, capture_output=True)
run(f"""insert into colaboradores(nome_advbox, origem) values ('TESTE COLAB A','administrativo'),('TESTE COLAB B','administrativo');
  insert into perfis values ('{ADMIN}','admin',null),
   ('{COLAB}','colaborador',(select id from colaboradores where nome_advbox='TESTE COLAB A')),
   ('{COLAB2}','colaborador',(select id from colaboradores where nome_advbox='TESTE COLAB B'));""")

CAB = ['Prioridade','Data','Hora','Término','Hora Término','Prazo fatal','Data Conclusão','Pontuação','Compromisso',
       'Local','Remetente','Destinatário','Partes','Processo (CNJ)','Protocolo','Tipo de ação','Observações']
def linha(data, pf, comp, obs='', dest='TESTE COLAB A', concl=''):
    b = {c: '' for c in CAB}
    b.update({'Prioridade':'NORMAL','Remetente':'TESTE REMETENTE','Destinatário':dest,'Tipo de ação':'TESTE',
              'Data':data,'Prazo fatal':pf,'Compromisso':comp,'Observações':obs,'Data Conclusão':concl})
    return b
def importar(nome, linhas, lote=None):
    j = json.dumps(linhas, ensure_ascii=False); h = hashlib.sha256((nome + j).encode()).hexdigest()
    return json.loads(q(f"select importar_arquivo($N${nome}$N$,'{h}',$J${j}$J$::jsonb,{'null' if lote is None else lote})", ADMIN))
def snap(titulo, data, pf, criado='01/11/2026 09:00'):
    return json.dumps({"titulo": titulo, "data_evento": data, "prazo_fatal": pf, "partes": [], "criado_em": criado}, ensure_ascii=False)
def status(adv, s, uid=COLAB): return json.loads(q(f"select ext_status_tarefa('{adv}',$S${s}$S$::jsonb)", uid))
def iniciar(adv, s, uid=COLAB):
    return json.loads(q(f"select ext_registrar_evento(gen_random_uuid(),'inicio_tratativa','{adv}',$S${s}$S$::jsonb)", uid))

# ---------------------------------------------------------------- H1
# Tarefa recorrente (mesmo texto, datas diferentes) -> chave de OCORRÊNCIA (inclui datas e responsável).
# A extensão vincula o ID do ADVBOX, a tratativa é iniciada; depois a tarefa é realocada e reimportada.
L1 = [linha('10/11/2026','20/11/2026','TESTE PARCELA','Pagar parcela'),
      linha('10/12/2026','20/12/2026','TESTE PARCELA','Pagar parcela')]
r1 = importar('h1_lote1.xlsx', L1)
s1 = snap('TESTE PARCELA','10/11/2026','20/11/2026')
st = status('910000001', s1)
iniciar('910000001', s1)
L2 = [linha('12/11/2026','20/11/2026','TESTE PARCELA','Pagar parcela\n\nMG - 05/11 - Tarefa realocada a pedido.'),
      linha('10/12/2026','20/12/2026','TESTE PARCELA','Pagar parcela')]
r2 = importar('h1_lote2.xlsx', L2)
ini = q("select coalesce(inicio_tratativa_em::text,'NULO') from v_tarefas_atuais where d7_data_agenda='2026-11-12'", ADMIN)
alerta = q("select count(*) from v_alertas a join v_tarefas_atuais t on t.linha_id=a.linha_id where t.d7_data_agenda='2026-11-12' and a.categoria='d7_atingido_sem_inicio'", ADMIN)
pend = q("select count(*) from v_tarefas_sem_linha_atual where advbox_id='910000001' and inicio_tratativa_em is not null", ADMIN)
caso("H1 Recorrente realocada: antes de reabrir a tarefa",
     "o início não se perde em silêncio: a tarefa aparece em v_tarefas_sem_linha_atual (vínculo a refazer)",
     f"lote2 tarefas_novas={r2['tarefas_novas']}; início na visão atual={ini}; listada como sem linha atual={pend}",
     pend == '1')
st_depois = status('910000001', snap('TESTE PARCELA','12/11/2026','20/11/2026'))
ini_depois = q("select coalesce(inicio_tratativa_em::text,'NULO') from v_tarefas_atuais where d7_data_agenda='2026-11-12'", ADMIN)
unif = q("select count(*) from eventos where tipo='unificacao_tarefa' and evidencia->>'advbox_id'='910000001'")
caso("H1b Recorrente realocada: depois de reabrir a tarefa na extensão",
     "extensão e painel mostram o mesmo início; unificação auditada",
     f"extensão início={st_depois['inicio_tratativa_em'] is not None}; painel início={'sim' if ini_depois!='NULO' else 'não'}; eventos de unificação={unif}",
     st_depois['inicio_tratativa_em'] is not None and ini_depois != 'NULO' and unif == '1')

# ---------------------------------------------------------------- H2
# Tarefa criada no ADVBOX DEPOIS da exportação: extensão cria tarefa 'A:' (sem correspondência).
# Na importação seguinte ela aparece no Excel -> o sistema funde ou duplica?
s2 = snap('TESTE NOVA APOS EXPORT','20/11/2026','27/11/2026')
st2 = status('910000002', s2); iniciar('910000002', s2)
r3 = importar('h2_lote3.xlsx', L2 + [linha('20/11/2026','27/11/2026','TESTE NOVA APOS EXPORT','Texto único H2')])
n_tar = q("select count(distinct coalesce(unificada_em,id)) from tarefas where chave_identificacao like 'A:910000002' or id in (select tarefa_id from v_tarefas_atuais where compromisso='TESTE NOVA APOS EXPORT')", ADMIN)
ini2 = q("select coalesce(inicio_tratativa_em::text,'NULO') from v_tarefas_atuais where compromisso='TESTE NOVA APOS EXPORT'", ADMIN)
caso("H2 Tarefa vista pela extensão antes de aparecer no Excel",
     "uma única tarefa (registros unificados); início visível no painel",
     f"vínculo inicial={st2['vinculo_excel']}; tarefas distintas={n_tar}; unificadas na importação={r3.get('tarefas_unificadas_pelo_id_advbox')}; início na visão atual={ini2}",
     n_tar == '1' and ini2 != 'NULO')

# ---------------------------------------------------------------- H3
# Responsável (colaborador A) vê o início registrado por OUTRA pessoa (admin ou colaborador B)?
L4 = L2 + [linha('20/11/2026','27/11/2026','TESTE NOVA APOS EXPORT','Texto único H2'),
           linha('06/11/2026','30/11/2026','TESTE H3 INICIO POR OUTRO','Texto único H3')]
importar('h3_lote4.xlsx', L4)
s3 = snap('TESTE H3 INICIO POR OUTRO','06/11/2026','30/11/2026')
status('910000003', s3, ADMIN); iniciar('910000003', s3, ADMIN)
v_admin = q("select coalesce(inicio_tratativa_em::text,'NULO') from v_tarefas_atuais where compromisso='TESTE H3 INICIO POR OUTRO'", ADMIN)
v_resp = q("select coalesce(inicio_tratativa_em::text,'NULO') from v_tarefas_atuais where compromisso='TESTE H3 INICIO POR OUTRO'", COLAB)
caso("H3 Início registrado pelo admin, visto pelo responsável",
     "o responsável enxerga o mesmo início que o admin",
     f"admin vê={'sim' if v_admin!='NULO' else 'não'}; responsável vê={'sim' if v_resp!='NULO' else 'não'}",
     (v_admin != 'NULO') == (v_resp != 'NULO'))

# ---------------------------------------------------------------- H4
# Colaborador B consulta/inicia tarefa cujo responsável é A
stB = status('910000003', s3, COLAB2)
caso("H4 Colaborador consulta tarefa de outro responsável pela extensão",
     "permitido por decisão do escritório de 05/11/2026; o autor do início fica registrado",
     f"colaborador B recebeu status (início={stB['inicio_tratativa_em'] is not None}, PF judicial={stB['pf_judicial_excel']})",
     True)

# ---------------------------------------------------------------- H5
# O estado da trava é declarado pelo cliente e aceito sem verificação
out, err, rc = run("select ext_registrar_evento(gen_random_uuid(),'tentativa_conclusao','910000099','{}'::jsonb,'permitida_apos_validacao')", COLAB2, ok_error=True)
gravado = q("select estado_trava||'|'||(evidencia->>'estado_declarado') from eventos where tipo='tentativa_conclusao' and evidencia->>'advbox_id'='910000099'")
caso("H5 Conclusão 'permitida' em tarefa SEM início",
     "servidor recusa ou reclassifica (preservando o que foi declarado)",
     f"aceito={rc==0}; gravado como={gravado}", rc != 0 or gravado == 'violacao_detectada|permitida_apos_validacao')

# ---------------------------------------------------------------- H6
# Funções criadas em 0006 fora da lista de revogação
priv = q("select string_agg(p.proname||'='||has_function_privilege('anon', p.oid, 'execute'), ', ' order by p.proname) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname in ('_dt_tela','_ts_tela','is_admin','importar_arquivo','ext_status_tarefa')")
caso("H6 Privilégio de execução para anon", "anon não executa nenhuma função",
     priv, 'true' not in priv)

# ---------------------------------------------------------------- H7
# Importar um arquivo de concluídas como NOVO lote (sem informar o lote do dia)
antes = q("select count(*) from v_tarefas_atuais", ADMIN)
importar('h7_so_concluidas.xlsx', [linha('01/11/2026','03/11/2026','TESTE CONCLUIDA H7','x', concl='04/11/2026 10:00')])
depois = q("select count(*) from v_tarefas_atuais", ADMIN)
caso("H7 Arquivo de concluídas importado como lote novo por engano",
     "a fotografia atual não deve ser substituída por um arquivo parcial sem aviso",
     f"tarefas na visão atual: antes={antes}, depois={depois}", depois >= antes)

w = max(len(r[1]) for r in res)
for s, n, rq, ob in res:
    print(f"{s:7}| {n:<{w}} | requisito: {rq}\n{'':7}| {'':<{w}} | observado: {ob}")
print(f"\n{sum(r[0].strip()=='OK' for r in res)} conformes, {sum(r[0]=='ACHADO' for r in res)} achados, {sum(r[0]=='DECIDIR' for r in res)} a decidir, de {len(res)} verificações")
