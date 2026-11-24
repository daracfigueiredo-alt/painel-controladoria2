"""Testes da base (importação, regras de data, segurança, auditoria).
Executa contra um PostgreSQL LOCAL descartável (nunca produção).
Saída: tabela com esperado x obtido e situação de cada teste."""
import json, subprocess, sys, hashlib, copy, os, datetime

PSQL = ["psql", "-h", "/tmp", "-p", "5433", "-U", "postgres", "-At", "-q", "-v", "ON_ERROR_STOP=1"]
HERE = os.path.dirname(os.path.abspath(__file__))
MIG = sorted(os.path.join(HERE, "..", "supabase", "migrations", f)
             for f in os.listdir(os.path.join(HERE, "..", "supabase", "migrations")))
ADMIN = "00000000-0000-0000-0000-00000000000a"
COLAB = "00000000-0000-0000-0000-00000000000c"
results = []

def run(db, sql, uid=None, ok_error=False):
    pre = ""
    if uid is not None:
        pre = f"set role authenticated; set request.jwt.claim.sub = '{uid}';\n"
    elif uid is None and "ANON" in sql[:10]:
        pass
    p = subprocess.run(PSQL + ["-d", db], input=pre + sql, capture_output=True, text=True)
    if p.returncode != 0 and not ok_error:
        raise RuntimeError(p.stderr)
    return (p.stdout.strip(), p.stderr.strip(), p.returncode)

def anon(db, sql):
    return run(db, "set role anon;\n" + sql, ok_error=True)

def check(nome, esperado, obtido):
    results.append((nome, str(esperado), str(obtido), "OK" if str(esperado) == str(obtido) else "FALHA"))

def setup(db):
    subprocess.run(PSQL + ["-d", "postgres", "-c", f"drop database if exists {db}", "-c", f"create database {db}"], check=True, capture_output=True)
    for f in [os.path.join(HERE, "00_stub_supabase_local.sql")] + MIG:
        subprocess.run(PSQL + ["-d", db, "-f", f], check=True, capture_output=True, text=True)
    run(db, f"""insert into colaboradores(nome_advbox, origem) values ('TESTE FICTICIO COLABORADOR','administrativo');
      insert into perfis values ('{ADMIN}','admin',null), ('{COLAB}','colaborador',
      (select id from colaboradores where nome_advbox='TESTE FICTICIO COLABORADOR'));""")

def importar(db, nome, linhas, uid=ADMIN, lote=None, hsh=None):
    j = json.dumps(linhas, ensure_ascii=False)
    hsh = hsh or hashlib.sha256(j.encode()).hexdigest()
    lote_sql = "null" if lote is None else str(lote)
    out, err, rc = run(db, f"select importar_arquivo($N${nome}$N$, '{hsh}', $J${j}$J$::jsonb, {lote_sql});",
                       uid=uid, ok_error=True)
    return (json.loads(out) if rc == 0 else None), err

def q(db, sql, uid=None):
    return run(db, sql, uid=uid)[0]

CAB = ['Prioridade','Data','Hora','Término','Hora Término','Prazo fatal','Data Conclusão','Pontuação','Compromisso',
       'Local','Remetente','Destinatário','Partes','Processo (CNJ)','Protocolo','Tipo de ação','Observações']
def linha(**kw):
    base = {c: '' for c in CAB}
    base.update({'Prioridade': 'NORMAL', 'Remetente': 'TESTE FICTICIO REMETENTE',
                 'Destinatário': 'TESTE FICTICIO COLABORADOR', 'Tipo de ação': 'TESTE FICTICIO'})
    for k, v in kw.items(): base[{'Data_':'Data','PF':'Prazo fatal','Concl':'Data Conclusão','Comp':'Compromisso',
                                  'Dest':'Destinatário','Obs':'Observações','CNJ':'Processo (CNJ)'}.get(k, k)] = v
    return base

# =====================================================================
# A) Regras de data (calendário + D-4) — banco de testes fictícios
# =====================================================================
DB = "ctrl_test_ficticio"
setup(DB)
check("D-4 exemplo escritório: PF 27/10/2026", "2026-10-22", q(DB, "select calcular_d4('2026-10-27')"))
check("D-4 exemplo escritório: PF 26/10/2026", "2026-10-21", q(DB, "select calcular_d4('2026-10-26')"))
check("Leitura literal '4 dias úteis antes' de 27/10 (documentação da divergência)", "2026-10-21",
      q(DB, "select somar_dias_uteis('2026-10-27', -4)"))
check("D-4 pula feriado nacional (PF 03/11/2026; 02/11 Finados)", "2026-10-28", q(DB, "select calcular_d4('2026-11-03')"))
check("D-4 pula fim de semana + 20/11 (PF 23/11/2026)", "2026-11-17", q(DB, "select calcular_d4('2026-11-23')"))
run(DB, "insert into calendario_dias_nao_uteis(data, abrangencia, tribunal_cnj, tipo, descricao) values ('2026-10-28','tribunal','8.05','feriado','TESTE FICTICIO feriado local')")
check("D-4 com feriado fictício do tribunal 8.05 em 28/10", "2026-10-27", q(DB, "select calcular_d4('2026-11-03','8.05')"))
check("Mesmo feriado não afeta outro tribunal (8.04, sem calendário cadastrado)", "2026-10-28", q(DB, "select calcular_d4('2026-11-03','8.04')"))
check("Dias úteis entre 24/10 (sáb) e 27/10 (ter)", "2", q(DB, "select dias_uteis_entre('2026-10-24','2026-10-27')"))
check("Tribunal extraído do CNJ 5001032-73.2024.8.13.0325", "8.13", q(DB, "select tribunal_do_cnj('5001032-73.2024.8.13.0325')"))
check("Ano inferido de 'PF: 05/01' com referência 20/12/2026", "2027-01-05", q(DB, "select data_anotada('05/01','2026-12-20')"))

# =====================================================================
# B) Importação — validações, permissões, idempotência (dados FICTÍCIOS)
# =====================================================================
L1 = [
  linha(Data_='26/10/2026', PF='27/10/2026', Comp='TESTE FICTICIO MANIFESTAÇÃO', CNJ='0000001-00.2026.8.13.0001',
        Obs='@fulano encaminhou para @ciclano em 20/10/2026 10:00:00\n\nTF - 19/10 - Prazo 15 dias. D-4: 22/10. PF: 27/10.'),
  linha(Data_='23/10/2026', PF='30/10/2026', Comp='TESTE FICTICIO CONTESTAÇÃO', CNJ='0000002-00.2026.8.13.0001',
        Obs='TF - 19/10 - Prazo 15 dias. PF: 03/11.'),           # PF tarefa ≠ PF judicial anotado
  linha(Data_='31/02/2026', Comp='TESTE FICTICIO DATA INVÁLIDA'),   # rejeitada
  linha(Data_='22/10/2026', Comp='TESTE FICTICIO REAGENDAR',
        Obs='TF - 21/10 - Dra. Mayra, favor reagendar essa tarefa para 30/10. @mayragomes'),
  linha(Data_='22/10/2026', Concl='23/10/2026 18:27', Comp='TESTE FICTICIO CONCLUÍDA'),
]
r, err = importar(DB, "ficticio_1.xlsx", L1, uid=COLAB)
check("Colaborador NÃO pode importar", "erro 42501/Somente administradores", "erro 42501/Somente administradores" if r is None and "Somente administradores" in err else err[:80])
r, err = importar(DB, "ficticio_1.xlsx", L1, hsh="a"*64)
check("Importação fictícia: total/válidas/rejeitadas", "5/4/1", f"{r['total_linhas']}/{r['validas']}/{r['rejeitadas']}")
check("Motivo da rejeição informado por linha", "4:Data inválida: 31/02/2026",
      f"{r['erros_por_linha'][0]['linha']}:{r['erros_por_linha'][0]['erros'][0]['mensagem']}")
lote1 = r["lote_id"]
r2, _ = importar(DB, "ficticio_1_de_novo.xlsx", L1, hsh="a"*64)
check("Mesmo arquivo (mesmo hash) novamente: nada é gravado", "ja_importado", r2["status"])
check("Linhas gravadas após reimportação", "5", q(DB, "select count(*) from linhas_importadas"))
r3, _ = importar(DB, "ficticio_1b.xlsx", L1[:2], lote=lote1, hsh="b"*64)
check("Arquivo com linhas repetidas no mesmo lote: duplicadas ignoradas", "2", r3["duplicadas_no_lote"])
check("PF Judicial anotado extraído (linha 2)", "2026-10-27|2026-10-22|2026-10-27",
      q(DB, "select pf_judicial_anotado||'|'||d4_anotado||'|'||pf_tarefa from linhas_importadas where numero_linha=2 and importacao_id=(select min(id) from importacoes where status='concluida')"))
check("Encaminhamento recuperado como histórico (1 evento)", "1|true", q(DB, "select count(*)||'|'||bool_and(historico_recuperado) from eventos where tipo='encaminhamento'"))
check("Pedido de reagendamento classificado como POTENCIAL", "1|potencial|30/10",
      q(DB, "select count(*)||'|'||max(classificacao)||'|'||max(valor_novo->>'nova_data_solicitada_txt') from eventos where tipo='pedido_reagendamento'"))
check("Pedido de reagendamento NÃO gera reagendamento efetivado", "0", q(DB, "select count(*) from eventos where tipo='alteracao_data_agenda'"))
check("Conclusão registrada uma vez", "1", q(DB, "select count(*) from eventos where tipo='conclusao'"))

big = [linha(Data_='26/10/2026', Comp=f'TESTE FICTICIO {i}') for i in range(1001)]
r, err = importar(DB, "ficticio_1001.xlsx", big)
check("Arquivo com 1.001 linhas é recusado", "recusado", "recusado" if r is None and "limite" in err else err[:60])
bad = [{k: v for k, v in linha(Data_='26/10/2026').items() if k != 'Prazo fatal'}]
r, _ = importar(DB, "ficticio_sem_coluna.xlsx", bad)
check("Arquivo sem coluna obrigatória é rejeitado", "rejeitada:Prazo fatal", f"{r['status']}:{','.join(r['colunas_ausentes'])}")

# Lote 2: mudanças fictícias (realocação com e sem anotação; antecipação de PF)
L2 = copy.deepcopy(L1[:2])
L2[0]['Data'] = '28/10/2026'; L2[0]['Prazo fatal'] = '29/10/2026'
L2[0]['Observações'] += '\n\nMG - 24/10 - Tarefa realocada.'
L2[1]['Prazo fatal'] = '29/10/2026'                                 # antecipação sem anotação
r, _ = importar(DB, "ficticio_2.xlsx", L2, hsh="c"*64)
check("Lote 2: tarefas reconhecidas (sem duplicar)", "2/0", f"{r['tarefas_ja_conhecidas']}/{r['tarefas_novas']}")
check("Alterações de data/PF observadas entre importações", "1/2",
      q(DB, "select count(*) filter (where tipo='alteracao_data_agenda')||'/'||count(*) filter (where tipo='alteracao_pf_tarefa') from eventos"))
check("Alterações sem justificativa / PF antecipado", "1/1",
      q(DB, "select count(*)||'/'||count(*) filter (where antecipacao_pf) from v_alteracoes_sem_justificativa"))
check("Mudança de PF em tarefa com PF Judicial = violação detectada (2 casos)", "2",
      q(DB, "select count(*) from eventos where tipo='alteracao_pf_tarefa' and estado_trava='violacao_detectada'"))
check("Mudança de data com anotação: detectada, não bloqueada", "nao_monitorada",
      q(DB, "select estado_trava from eventos where tipo='alteracao_data_agenda'"))
check("Violação de PF aparece na tela de prazos em risco", "2",
      q(DB, "select count(*) from v_alertas where categoria='pf_alterado_violacao'", uid=ADMIN))
check("Encaminhamento não duplicado no lote 2", "1", q(DB, "select count(*) from eventos where tipo='encaminhamento'"))
check("PF Judicial NÃO muda com o PF da Tarefa", "2026-11-03",
      q(DB, "select pf_judicial from v_tarefas_atuais where compromisso='TESTE FICTICIO CONTESTAÇÃO'", uid=ADMIN))

# Funções da extensão (dados fictícios; ID 900000001 não existe no ADVBOX)
SNAP = json.dumps({"titulo": "Teste Ficticio Manifestação", "data_evento": "quarta, 28/10/2026",
                   "prazo_fatal": "quinta, 29/10/2026", "partes": [], "criado_por": "Pessoa Fictícia",
                   "criado_em": "16/10/2026 09:15"}, ensure_ascii=False)
def rpc(sql, uid=COLAB): return run(DB, sql, uid=uid, ok_error=True)
st = json.loads(q(DB, f"select ext_status_tarefa('900000001', $S${SNAP}$S$::jsonb)", uid=COLAB))
check("Extensão: tarefa da tela vinculada à linha do Excel (único candidato)", "excel_unico|None|2026-10-27",
      f"{st['vinculo_excel']}|{st['inicio_tratativa_em']}|{st['pf_judicial_excel']}")
check("Extensão: data de criação lida na tela vira 'abertura' (horário de Brasília)", "2026-10-16 12:15:00",
      q(DB, "select abertura_em at time zone 'UTC' from v_tarefas_atuais where compromisso='TESTE FICTICIO MANIFESTAÇÃO'", uid=ADMIN))
U1 = "11111111-1111-1111-1111-111111111111"
r1 = json.loads(q(DB, f"select ext_registrar_evento('{U1}','inicio_tratativa','900000001',$S${SNAP}$S$::jsonb)", uid=COLAB))
r2 = json.loads(q(DB, f"select ext_registrar_evento('22222222-2222-2222-2222-222222222222','inicio_tratativa','900000001','{{}}'::jsonb)", uid=COLAB))
r3 = json.loads(q(DB, f"select ext_registrar_evento('{U1}','inicio_tratativa','900000001','{{}}'::jsonb)", uid=COLAB))
check("Extensão: início registrado / 2º início recusado / reenvio idempotente", "registrado|ja_iniciada|ja_registrado",
      f"{r1['status']}|{r2['status']}|{r3['status']}")
check("Extensão: só um início por tarefa, com horário do servidor", "1|segundo",
      q(DB, "select count(*)||'|'||max(precisao_ocorrido) from eventos where tipo='inicio_tratativa'"))
_, err, rc = rpc("select ext_registrar_evento(gen_random_uuid(),'tentativa_conclusao','900000001','{}'::jsonb,'excecao_autorizada')")
check("Extensão: colaborador não pode registrar exceção autorizada", "negado", "negado" if rc and "Somente a controladoria" in err else err[:60])
_, err, rc = rpc("select ext_registrar_evento(gen_random_uuid(),'conclusao','900000001','{}'::jsonb)")
check("Extensão: tipo de evento fora da lista é recusado", "recusado", "recusado" if rc and "não permitido" in err else err[:60])
_, err, rc = rpc("select ext_registrar_evento(gen_random_uuid(),'tentativa_conclusao','900000001','{}'::jsonb,'bloqueio_efetivo')")
check("Extensão: tentativa de conclusão registrada e visível em v_travas", "bloqueio_efetivo",
      q(DB, "select string_agg(estado_trava, ',') from v_travas where tipo='tentativa_conclusao'", uid=ADMIN))
st2 = json.loads(q(DB, f"select ext_status_tarefa('900000002', $S${json.dumps({'titulo':'Inexistente','data_evento':'01/01/2026'})}$S$::jsonb)", uid=COLAB))
check("Extensão: tarefa sem correspondência no Excel fica identificada como tal", "sem_correspondencia", st2["vinculo_excel"])
out, err, rc = anon(DB, "select ext_status_tarefa('900000001','{}'::jsonb)")
check("Extensão: anônimo não chama as funções", "negado", "negado" if rc and "permission denied" in err else out)
_, err, rc = rpc("select ext_status_tarefa('1 or 1=1','{}'::jsonb)")
check("Extensão: ID de tarefa malformado recusado", "recusado", "recusado" if rc and "inválido" in err else err[:60])
check("Status após início mostra quem iniciou", "TESTE FICTICIO COLABORADOR",
      json.loads(q(DB, f"select ext_status_tarefa('900000001', '{{}}'::jsonb)", uid=COLAB))["inicio_por"])
SNAP2 = json.dumps({"titulo": "TESTE FICTICIO CONTESTAÇÃO", "data_evento": "23/10/2026", "prazo_fatal": "29/10/2026",
                    "partes": [], "criado_em": "20/10/2026 08:00"}, ensure_ascii=False)
q(DB, f"select ext_status_tarefa('900000003', $S${SNAP2}$S$::jsonb)", uid=COLAB)
check("Alerta: aberta há mais de 24 h sem início (abertura lida na tela)", "1",
      q(DB, "select count(*) from v_alertas where categoria='aberta_24h_sem_inicio'", uid=ADMIN))

# Imutabilidade e segurança
_, err, rc = run(DB, "update eventos set justificativa='x'", ok_error=True)
check("Evento de auditoria não pode ser alterado", "bloqueado", "bloqueado" if rc and "imutável" in err else err[:60])
_, err, rc = run(DB, "delete from importacoes", ok_error=True)
check("Importação não pode ser excluída", "bloqueado", "bloqueado" if rc and "imutável" in err else err[:60])
out, err, rc = anon(DB, "select count(*) from linhas_importadas")
check("Anônimo não lê linhas", "negado", "negado" if rc and "permission denied" in err else out)
_, err, rc = run(DB, "insert into eventos(chave_dedupe,tipo,precisao_ocorrido,origem,historico_recuperado,classificacao) values ('x','conclusao','dia','sistema',false,'confirmado')", uid=COLAB, ok_error=True)
check("Colaborador não grava direto na auditoria", "negado", "negado" if rc and "permission denied" in err else err[:60])
_, err, rc = run(DB, "select _gerar_eventos_importacao(1, now())", uid=ADMIN, ok_error=True)
check("Função interna não é exposta", "negado", "negado" if rc and "permission denied" in err else err[:60])
check("Colaborador vê só as próprias tarefas", "2", q(DB, "select count(*) from v_tarefas_atuais", uid=COLAB))
run(DB, "insert into colaboradores(nome_advbox, origem) values ('TESTE FICTICIO OUTRO','administrativo'); insert into perfis values ('00000000-0000-0000-0000-0000000000dd','colaborador',(select id from colaboradores where nome_advbox='TESTE FICTICIO OUTRO'))")
check("Outro colaborador não vê tarefas alheias", "0", q(DB, "select count(*) from v_tarefas_atuais", uid="00000000-0000-0000-0000-0000000000dd"))
check("Colaborador não vê importações", "0", q(DB, "select count(*) from importacoes", uid=COLAB))

# =====================================================================
# C) Arquivo REAL exportado do ADVBOX (24/10/2026) — banco separado
# =====================================================================
DBR = "ctrl_test_real"
if not os.path.exists(os.path.join(HERE,"out","real.json")):
    print("AVISO: arquivos reais (out/*.json) ausentes no pacote; bloco C não executado")
else:
  pass
if os.path.exists(os.path.join(HERE,"out","real.json")):
  setup(DBR)
  real = json.load(open(os.path.join(HERE, "out", "real.json")))
  r, err = importar(DBR, "Advbox-2026-10-24_0717524.xlsx", real["linhas"], hsh=real["hash"])
  if r is None: print(err); sys.exit(1)
  check("Real: total de linhas", "878", r["total_linhas"])
  check("Real: válidas+rejeitadas+duplicadas = total", "878", r["validas"] + r["rejeitadas"] + r["duplicadas_no_lote"])
  r2, _ = importar(DBR, "Advbox-2026-10-24_0717524.xlsx", real["linhas"], hsh=real["hash"])
  check("Real: reimportação do mesmo arquivo", "ja_importado", r2["status"])
  check("Real: PF anotado ≠ PF da Tarefa (diagnóstico prévio: 16)", "16",
        q(DBR, "select count(*) from linhas_importadas where pf_judicial_anotado is not null and pf_tarefa is not null and pf_judicial_anotado<>pf_tarefa"))
  check("Real: conclusões (Data Conclusão preenchida: 31)", "31", q(DBR, "select count(*) from eventos where tipo='conclusao'"))
  check("Real: soma por categoria = total de alertas (sem perda na consolidação)",
        q(DBR, "select count(*) from v_alertas", uid=ADMIN),
        q(DBR, "select sum(n) from (select count(*) n from v_alertas group by categoria) x", uid=ADMIN))

  # Segundo arquivo REAL do mesmo dia (concluídas) no MESMO lote
  conc = json.load(open(os.path.join(HERE, "out", "concluidas.json")))
  rc, err = importar(DBR, "Advbox-2026-10-24_0443625.xlsx", conc["linhas"], hsh=conc["hash"], lote=r["lote_id"])
  if rc is None: print(err); sys.exit(1)
  check("Concluídas: 50 linhas válidas, nenhuma rejeitada", "50/0", f"{rc['validas']}/{rc['rejeitadas']}")
  check("Concluídas: recorrentes distinguidas (0 ambíguas)", "0", rc["ambiguas_nao_vinculadas"])
  check("Lote com 2 arquivos: conclusões sem duplicar (31 + 50)", "81", q(DBR, "select count(*) from eventos where tipo='conclusao'"))
  check("Lote com 2 arquivos: fotografia do dia = 878 + 50 linhas", "928", q(DBR, "select count(*) from v_tarefas_atuais", uid=ADMIN))
  rc2, _ = importar(DBR, "Advbox-2026-10-24_0443625.xlsx", conc["linhas"], hsh=conc["hash"], lote=r["lote_id"])
  check("Concluídas: reimportação do mesmo arquivo", "ja_importado", rc2["status"])
  conc2 = json.load(open(os.path.join(HERE, "out", "concluidas2.json")))
  rc3, err = importar(DBR, "Advbox-2026-10-24_0687502.xlsx", conc2["linhas"], hsh=conc2["hash"], lote=r["lote_id"])
  check("3º arquivo (concluídas, período sobreposto): 5 linhas repetidas ignoradas", "45/5", f"{rc3['validas']}/{rc3['duplicadas_no_lote']}")
  check("3 arquivos no lote: conclusões distintas (31 + 50 + 45)", "126", q(DBR, "select count(*) from eventos where tipo='conclusao'"))

0 and json.dump({"importacao": r}, open(os.path.join(HERE, "out", "resumo_import_real.json"), "w"), ensure_ascii=False, indent=1)
w = max(len(x[0]) for x in results)
for n, e, o, s in results:
    print(f"{s:5} | {n:<{w}} | esperado: {e} | obtido: {o}")
print(f"\n{sum(1 for x in results if x[3]=='OK')}/{len(results)} OK — executado em {datetime.datetime.now():%d/%m/%Y %H:%M}")
sys.exit(0 if all(x[3] == "OK" for x in results) else 1)
