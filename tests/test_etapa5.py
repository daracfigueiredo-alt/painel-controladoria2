"""Testes da Etapa 5 (0012) no banco: consulta em lote da lista, preservação da leitura
completa da janela e correspondência com o título real ("Análise do Caso" x "ANÁLISE DO CASO").
Banco LOCAL, dados FICTÍCIOS."""
import json, subprocess, hashlib, os, sys, datetime
PSQL = ["psql", "-h", "/tmp", "-p", "5433", "-U", "postgres", "-At", "-q", "-v", "ON_ERROR_STOP=1"]
HERE = os.path.dirname(os.path.abspath(__file__)); MIGDIR = os.path.join(HERE, "..", "supabase", "migrations")
MIG = sorted(os.path.join(MIGDIR, f) for f in os.listdir(MIGDIR)); DB = "ctrl_etapa5"; res = []
ADMIN, COLAB = "00000000-0000-0000-0000-00000000000a", "00000000-0000-0000-0000-00000000000c"
def run(sql, uid=None, role=None, ok_error=False):
    pre = f"set role authenticated; set request.jwt.claim.sub = '{uid}';\n" if uid else (f"set role {role};\n" if role else "")
    p = subprocess.run(PSQL + ["-d", DB], input=pre + sql, capture_output=True, text=True)
    if p.returncode and not ok_error: raise RuntimeError(sql[:300] + "\n" + p.stderr)
    return p.stdout.strip(), p.stderr.strip(), p.returncode
q = lambda sql, uid=None: run(sql, uid)[0]
def check(n, e, o): res.append((n, str(e), str(o), "OK" if str(e) == str(o) else "FALHA"))
subprocess.run(PSQL + ["-d", "postgres", "-c", f"drop database if exists {DB}", "-c", f"create database {DB}"], check=True, capture_output=True)
for f in [os.path.join(HERE, "00_stub_supabase_local.sql")] + MIG:
    subprocess.run(PSQL + ["-d", DB, "-f", f], check=True, capture_output=True)
q(f"""insert into colaboradores(nome_advbox, origem) values ('TESTE COLAB A','administrativo');
  insert into perfis values ('{ADMIN}','admin',null), ('{COLAB}','colaborador',(select id from colaboradores limit 1));""")
CAB = ['Prioridade','Data','Hora','Término','Hora Término','Prazo fatal','Data Conclusão','Pontuação','Compromisso',
       'Local','Remetente','Destinatário','Partes','Processo (CNJ)','Protocolo','Tipo de ação','Observações']
def linha(data, pf, comp, obs):
    b = {c: '' for c in CAB}
    b.update({'Prioridade':'NORMAL','Remetente':'TESTE REMETENTE','Destinatário':'TESTE COLAB A','Tipo de ação':'TESTE',
              'Data':data,'Prazo fatal':pf,'Compromisso':comp,'Observações':obs,'Partes':'T001 - Cliente Fictício Ltda'})
    return b
def importar(nome, linhas):
    j = json.dumps(linhas, ensure_ascii=False); h = hashlib.sha256((nome + j).encode()).hexdigest()
    return json.loads(q(f"select importar_arquivo($N${nome}$N$,'{h}',$J${j}$J$::jsonb)", ADMIN))
importar('e5_lote1.xlsx', [linha('27/10/2026', '27/10/2026', 'ANÁLISE DO CASO', 'Texto fictício único 1.'),
                           linha('28/10/2026', '30/10/2026', 'PROTOCOLO', 'Texto fictício único 2.')])

# Título como aparece na janela REAL (só a 1ª letra maiúscula, com acento) x Compromisso do Excel em maiúsculas
snap = json.dumps({"titulo": "Análise do Caso", "data_evento": "27/10/2026", "prazo_fatal": "27/10/2026",
                   "partes": ["T001 - Cliente Fictício Ltda"], "criado_em": "23/10/2026 16:44"}, ensure_ascii=False)
st = json.loads(q(f"select ext_status_tarefa('291000001',$S${snap}$S$::jsonb)", COLAB))
check("Título real 'Análise do Caso' casa com 'ANÁLISE DO CASO' do Excel (upper com acento)", "excel_unico", st['vinculo_excel'])
q(f"select ext_registrar_evento(gen_random_uuid(),'inicio_tratativa','291000001',$S${snap}$S$::jsonb)", COLAB)

# Consulta em lote da lista
n_antes = q("select count(*) from tarefas")
r = json.loads(q("select ext_inicios_por_ids(array['291000001','291000099'])", COLAB))
check("Lote: tarefa com início devolve a data; desconhecida devolve nulo", "True|None",
      f"{r['inicios']['291000001'] is not None}|{r['inicios']['291000099']}")
check("Lote: devolve os modos das travas", "bloquear", r['modos']['conclusao'])
check("Lote: só leitura (não cria registro de tarefa)", n_antes, q("select count(*) from tarefas"))
_, e, rc = run("select ext_inicios_por_ids(array['12a'])", COLAB, ok_error=True)
check("Lote: ID inválido recusado", "recusado", "recusado" if rc and "inválido" in e else e[:60])
_, e, rc = run("select ext_inicios_por_ids(array(select g::text from generate_series(1,201) g))", COLAB, ok_error=True)
check("Lote: mais de 200 IDs recusado", "recusado", "recusado" if rc and "200" in e else e[:60])
_, e, rc = run("select ext_inicios_por_ids(array['1'])", role='anon', ok_error=True)
check("Lote: anônimo não executa", "negado", "negado" if rc and "permission denied" in e else e[:60])
_, e, rc = run("select ext_inicios_por_ids(array['1'])", "00000000-0000-0000-0000-0000000000ff", ok_error=True)
check("Lote: usuário sem perfil recusado", "recusado", "recusado" if rc and "sem perfil" in e else e[:60])

# Clique na lista (só título) não apaga a leitura completa da janela
snap_lista = json.dumps({"titulo": "ANÁLISE DO CASO", "origem": "lista"}, ensure_ascii=False)
q(f"select ext_registrar_evento(gen_random_uuid(),'tentativa_conclusao','291000001',$S${snap_lista}$S$::jsonb,'permitida_apos_validacao')", COLAB)
check("Leitura completa da janela preservada após clique na lista", "27/10/2026",
      q("select ultimo_snapshot->>'data_evento' from tarefas where advbox_id='291000001'"))
check("Conclusão pela lista com início registrado: permitida", "permitida_apos_validacao",
      q("select estado_trava from eventos where tipo='tentativa_conclusao' and evidencia->>'advbox_id'='291000001'"))
# Conclusão pela lista sem início, declarada 'permitida': servidor reclassifica (0007)
q(f"select ext_registrar_evento(gen_random_uuid(),'tentativa_conclusao','291000002',$S${json.dumps({'titulo':'PROTOCOLO','origem':'lista'})}$S$::jsonb,'permitida_apos_validacao')", COLAB)
check("Conclusão pela lista sem início declarada 'permitida' é reclassificada", "violacao_detectada",
      q("select estado_trava from eventos where tipo='tentativa_conclusao' and evidencia->>'advbox_id'='291000002'"))
# Realocação com justificativa do campo da extensão
q(f"select ext_registrar_evento(gen_random_uuid(),'tentativa_realocacao','291000001',$S${snap}$S$::jsonb,'permitida_apos_validacao','MG - 06/11 - Realocada a pedido do responsável.')", COLAB)
check("Realocação pelo 'Editar tarefa' com justificativa: aceita e guardada", "permitida_apos_validacao|true",
      q("select estado_trava||'|'||(justificativa like 'MG - 06/11%') from eventos where tipo='tentativa_realocacao'"))
q(f"select ext_registrar_evento(gen_random_uuid(),'tentativa_realocacao','291000001',$S${snap}$S$::jsonb,'permitida_apos_validacao','ok')", COLAB)
check("Realocação declarada 'permitida' com justificativa curta é reclassificada", "violacao_detectada",
      q("select estado_trava from eventos where tipo='tentativa_realocacao' and justificativa='ok'"))

w = max(len(x[0]) for x in res)
for n, e, o, s in res: print(f"{s:5} | {n:<{w}} | esperado: {e} | obtido: {o}")
print(f"\n{sum(1 for x in res if x[3]=='OK')}/{len(res)} OK — executado em {datetime.datetime.now():%d/%m/%Y %H:%M}")
sys.exit(0 if all(x[3] == "OK" for x in res) else 1)
