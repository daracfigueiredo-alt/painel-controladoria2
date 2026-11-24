"""Testes da 0033 (homologação, 10/11/2026): importações sucessivas com troca de Remetente
(encaminhamento no ADVBOX). Banco LOCAL, dados FICTÍCIOS."""
import json, subprocess, hashlib, os, sys
PSQL = ["psql", "-h", "/tmp", "-p", "5433", "-U", "postgres", "-At", "-q", "-v", "ON_ERROR_STOP=1"]
HERE = os.path.dirname(os.path.abspath(__file__)); MIGDIR = os.path.join(HERE, "..", "supabase", "migrations")
MIG = sorted(os.path.join(MIGDIR, f) for f in os.listdir(MIGDIR)); DB = "ctrl_etapa10"; res = []
ADMIN = "00000000-0000-0000-0000-00000000000a"
def run(sql, uid=None, ok_error=False):
    pre = f"set role authenticated; set request.jwt.claim.sub = '{uid}';\n" if uid else ""
    p = subprocess.run(PSQL + ["-d", DB], input=pre + sql, capture_output=True, text=True)
    if p.returncode and not ok_error: raise RuntimeError(sql[:300] + "\n" + p.stderr)
    return p.stdout.strip()
q = lambda sql, uid=None: run(sql, uid)
def check(n, e, o): res.append((n, str(e), str(o), "OK" if str(e) == str(o) else "FALHA"))
def cnj(seq, ano=2026, j='8', tr='13', foro='0024'):
    n = f"{seq:07d}"; dd = 98 - (int(f"{n}{ano}{j}{tr}{foro}") * 100 % 97); return f"{n}-{dd:02d}.{ano}.{j}.{tr}.{foro}"
CAB = ['Prioridade','Data','Hora','Término','Hora Término','Prazo fatal','Data Conclusão','Pontuação','Compromisso',
       'Local','Remetente','Destinatário','Partes','Processo (CNJ)','Protocolo','Tipo de ação','Observações']
def linha(data, comp, proc, rem, dest, obs, partes='A x B', concl='', pf='20/11/2026'):
    b = {c: '' for c in CAB}
    b.update({'Prioridade':'NORMAL','Data':data,'Prazo fatal':pf,'Compromisso':comp,'Remetente':rem,'Destinatário':dest,
              'Partes':partes,'Processo (CNJ)':proc,'Tipo de ação':'TESTE','Observações':obs,'Data Conclusão':concl})
    return b
def importar(nome, linhas, lote=None):
    j = json.dumps(linhas, ensure_ascii=False); h = hashlib.sha256((nome + j).encode()).hexdigest()
    return json.loads(q(f"select importar_arquivo($N${nome}$N$,'{h}',$J${j}$J$::jsonb,{'null' if lote is None else lote},null,false)", ADMIN))
tar = lambda proc, lote: q(f"select string_agg(distinct coalesce(t.unificada_em,t.id)::text, ',') from linhas_importadas l join tarefas t on t.id=l.tarefa_id where l.processo_cnj='{proc}' and l.lote_id={lote}")

subprocess.run(PSQL + ["-d", "postgres", "-c", f"drop database if exists {DB}", "-c", f"create database {DB}"], check=True, capture_output=True)
for f in [os.path.join(HERE, "00_stub_supabase_local.sql")] + MIG:
    subprocess.run(PSQL + ["-d", DB, "-f", f], check=True, capture_output=True)
q(f"""insert into colaboradores(nome_advbox, origem) values ('TESTE COLAB A','administrativo'),('TESTE COLAB B','administrativo'),('TESTE REM 1','administrativo'),('TESTE REM 2','administrativo');
  insert into perfis values ('{ADMIN}','admin',null);""")
P = [cnj(i) for i in range(1, 8)]
ENC = "\n\n@colaba encaminhou para @colabb em 09/11/2026 10:00:00"
# lote 1 (07/11)
l1 = importar('l1.xlsx', [
  linha('10/11/2026', 'AGRAVO', P[0], 'TESTE REM 1', 'TESTE COLAB A', 'TF - 07/11 - elaborar agravo.'),            # A: será encaminhada
  linha('10/11/2026', 'APELACAO', P[1], 'TESTE REM 1', 'TESTE COLAB A', 'TF - 07/11 - apelação.'),                 # B: igual nos dois dias
  linha('10/11/2026', 'MANIFESTACAO', P[2], 'TESTE REM 1', 'TESTE COLAB A', 'TF - 07/11 - manifestar.'),          # C1 \ duas tarefas iguais
  linha('10/11/2026', 'MANIFESTACAO', P[2], 'TESTE REM 2', 'TESTE COLAB A', 'TF - 07/11 - manifestar.'),          # C2 / (remetentes diferentes)
  linha('05/11/2026', 'CONTESTACAO', P[3], 'TESTE REM 1', 'TESTE COLAB A', 'TF - 05/11 - contestar.', concl='06/11/2026 10:00'),  # D: concluída
])
A1, B1 = tar(P[0], l1['lote_id']), tar(P[1], l1['lote_id'])
# lote 2 (10/11): A encaminhada (Remetente e Destinatário mudam, data muda, Observações ganham a linha automática)
l2 = importar('l2.xlsx', [
  linha('12/11/2026', 'AGRAVO', P[0], 'TESTE COLAB A', 'TESTE COLAB B', 'TF - 07/11 - elaborar agravo.' + ENC),
  linha('10/11/2026', 'APELACAO', P[1], 'TESTE REM 1', 'TESTE COLAB A', 'TF - 07/11 - apelação.'),
  linha('10/11/2026', 'MANIFESTACAO', P[2], 'TESTE COLAB A', 'TESTE COLAB B', 'TF - 07/11 - manifestar.'),        # 2 candidatas: não liga
  linha('12/11/2026', 'CONTESTACAO', P[3], 'TESTE REM 2', 'TESTE COLAB A', 'TF - 05/11 - contestar.'),            # anterior concluída: não liga
])
check("Encaminhada (Remetente mudou): ligada à MESMA tarefa de 07/11", A1, tar(P[0], l2['lote_id']))
check("Sem mudança: mesma tarefa (chave normal)", B1, tar(P[1], l2['lote_id']))
check("Duas tarefas anteriores equivalentes: NÃO liga (continua nova)", "False", tar(P[2], l2['lote_id']) in tar(P[2], l1['lote_id']).split(','))
check("Anterior concluída: NÃO liga", "False", tar(P[3], l2['lote_id']) == tar(P[3], l1['lote_id']))
check("Resumo da importação: 2 conhecidas, 2 novas", "2|2", f"{l2['tarefas_ja_conhecidas']}|{l2['tarefas_novas']}")
ev = q(f"select string_agg(tipo, ',' order by tipo) from eventos where origem='comparacao_importacoes' and tarefa_id in (select t.id from tarefas t where coalesce(t.unificada_em,t.id)={A1})")
check("Encaminhamento detectado entre os dias: troca de responsável e de data", "alteracao_data_agenda,alteracao_responsavel", ev)
check("Log registra o vínculo apesar da troca de Remetente", "1", q("select count(*) from log_integracao where operacao='vinculo_sem_remetente'"))

# ---------------------------------------------------------------- reparo (como no banco real: lote importado antes da 0033)
q("update parametros set valor='false' where chave='importacao_vinculo_sem_remetente'")
l3 = importar('l3.xlsx', [
  linha('15/11/2026', 'AGRAVO', P[0], 'TESTE COLAB B', 'TESTE COLAB A', 'TF - 07/11 - elaborar agravo.' + ENC + "\n\n@colabb encaminhou para @colaba em 10/11/2026 11:00:00"),
  linha('10/11/2026', 'APELACAO', P[1], 'TESTE REM 1', 'TESTE COLAB A', 'TF - 07/11 - apelação.'),
])
nova = tar(P[0], l3['lote_id'])
check("Sem o vínculo (situação anterior à 0033): vira tarefa nova", "True", nova != A1)
r = json.loads(q(f"select _reparar_vinculo_sem_remetente({l3["lote_id"]})"))
check("Reparo: 1 par único unificado", "1", r["unificadas"])
check("Reparo: a tarefa nova aponta para a anterior", A1, tar(P[0], l3['lote_id']))
check("Reparo: alterações entre os lotes geradas para a tarefa reparada", "2",
      q(f"select count(*) from eventos e join linhas_importadas l on l.id=e.linha_id where e.origem='comparacao_importacoes' and l.lote_id={l3['lote_id']} and l.processo_cnj='{P[0]}'"))
check("Reparo: evento de unificação com o motivo", "remetente_mudou_no_encaminhamento",
      q(f"select evidencia->>'motivo' from eventos where chave_dedupe='unif-rem:{nova}'"))
r2 = json.loads(q(f"select _reparar_vinculo_sem_remetente({l3["lote_id"]})"))
check("Reparo repetido não faz nada (idempotente)", "0", r2["unificadas"])
check("Integridade sem unificação em cadeia", "0", q("select count(*) from tarefas t join tarefas p on p.id=t.unificada_em where p.unificada_em is not null"))

w = max(len(r[0]) for r in res)
for n, e, o, s in res: print(f"{s:5} {n}" + ("" if s == "OK" else f"\n      esperado={e}\n      obtido  ={o}"))
ok = sum(r[3] == "OK" for r in res); print(f"\n{ok}/{len(res)} OK"); sys.exit(0 if ok == len(res) else 1)
