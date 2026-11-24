"""Testes da Etapa 4 (0011): indicadores, prazos em risco, reagendamentos, tratativa.
Dados FICTÍCIOS com resposta conhecida; datas relativas a "hoje" (Brasília).
Princípios verificados: definição única (cartão = soma do detalhamento = soma por colaborador),
solicitação ≠ efetivação, PF judicial vencido = pendência de conferência, RLS por colaborador."""
import json, subprocess, hashlib, os, sys, datetime
from zoneinfo import ZoneInfo
PSQL = ["psql", "-h", "/tmp", "-p", "5433", "-U", "postgres", "-At", "-q", "-v", "ON_ERROR_STOP=1"]
HERE = os.path.dirname(os.path.abspath(__file__)); MIGDIR = os.path.join(HERE, "..", "supabase", "migrations")
MIG = sorted(os.path.join(MIGDIR, f) for f in os.listdir(MIGDIR)); DB = "ctrl_etapa4"; res = []
ADMIN, COLAB_A, COLAB_B = ("00000000-0000-0000-0000-00000000000a", "00000000-0000-0000-0000-00000000000c",
                           "00000000-0000-0000-0000-0000000000dd")
def run(sql, uid=None):
    pre = f"set role authenticated; set request.jwt.claim.sub = '{uid}';\n" if uid else ""
    p = subprocess.run(PSQL + ["-d", DB], input=pre + sql, capture_output=True, text=True)
    if p.returncode: raise RuntimeError(sql[:300] + "\n" + p.stderr)
    return p.stdout.strip()
def check(n, e, o): res.append((n, str(e), str(o), "OK" if str(e) == str(o) else "FALHA"))
subprocess.run(PSQL + ["-d", "postgres", "-c", f"drop database if exists {DB}", "-c", f"create database {DB}"], check=True, capture_output=True)
for f in [os.path.join(HERE, "00_stub_supabase_local.sql")] + MIG:
    subprocess.run(PSQL + ["-d", DB, "-f", f], check=True, capture_output=True)
run(f"""insert into colaboradores(nome_advbox, origem) values ('TESTE COLAB A','administrativo'),('TESTE COLAB B','administrativo');
  insert into perfis values ('{ADMIN}','admin',null),
   ('{COLAB_A}','colaborador',(select id from colaboradores where nome_advbox='TESTE COLAB A')),
   ('{COLAB_B}','colaborador',(select id from colaboradores where nome_advbox='TESTE COLAB B'));""")
A = run("select id from colaboradores where nome_advbox='TESTE COLAB A'"); B = run("select id from colaboradores where nome_advbox='TESTE COLAB B'")
run(f"select admin_definir_equipe({A},'TESTE EQUIPE 1')", ADMIN); run(f"select admin_definir_equipe({B},'TESTE EQUIPE 2')", ADMIN)
EQ1 = run("select id from equipes where nome='TESTE EQUIPE 1'")

HOJE = datetime.date.fromisoformat(run("select hoje_brasilia()"))
def d(n): return (HOJE + datetime.timedelta(days=n)).strftime("%d/%m/%Y")
def du(n): return run(f"select to_char(somar_dias_uteis(hoje_brasilia(), {n}),'DD/MM/YYYY')")
def ddmm(s): return s[:5]
CAB = ['Prioridade','Data','Hora','Término','Hora Término','Prazo fatal','Data Conclusão','Pontuação','Compromisso',
       'Local','Remetente','Destinatário','Partes','Processo (CNJ)','Protocolo','Tipo de ação','Observações']
def linha(data, pf, comp, obs='', dest='TESTE COLAB A', concl=''):
    b = {c: '' for c in CAB}
    b.update({'Prioridade':'NORMAL','Remetente':'TESTE REMETENTE','Destinatário':dest,'Tipo de ação':'TESTE',
              'Data':data,'Prazo fatal':pf,'Compromisso':comp,'Observações':obs,'Data Conclusão':concl,
              'Processo (CNJ)':'0000001-65.2026.8.05.0001'})
    return b
def importar(nome, linhas, lote=None):
    j = json.dumps(linhas, ensure_ascii=False); h = hashlib.sha256((nome + j).encode()).hexdigest()
    return json.loads(run(f"select importar_arquivo($N${nome}$N$,'{h}',$J${j}$J$::jsonb,{'null' if lote is None else lote})", ADMIN))

PF_JUD_PASSADO, PF_JUD_D4 = du(-2), du(2)  # PF judicial vencido; PF judicial em 2 dias úteis (D-4 = PF-3du já passou)
base = [
  linha(d(-5), d(-3), 'TESTE VENCIDA A', 'Texto 1. PF: '+ddmm(PF_JUD_PASSADO)+'.'),          # vencida + pf jud vencido
  linha(d(0),  d(0),  'TESTE HOJE A', 'Texto 2.'),                                            # vence hoje (PF tarefa)
  linha(d(-1), PF_JUD_D4, 'TESTE D4 A', 'Texto 3. PF: '+ddmm(PF_JUD_D4)+'.'),                 # D-4 crítica
  linha(d(3),  d(10), 'PROTOCOLO', 'Texto 4 protocolo futuro.'),                              # pendente comum
  linha(d(-6), d(-4), 'PROTOCOLO', 'Texto 5 protocolo vencido.', dest='TESTE COLAB B'),       # protocolo sem evidência
  linha(d(2),  d(9),  'TESTE PEDIDO B', 'Texto 6.\n\nTB - '+ddmm(d(-1))+' - Favor reagendar para '+ddmm(d(5))+'.', dest='TESTE COLAB B'),
  linha(d(1),  d(8),  'TESTE REAGENDADA A', 'Texto 7 reagendada.'),
]
conc = [linha(d(-2), d(-1), 'PROTOCOLO', 'Texto 8 protocolo concluído.', concl=d(-1)+' 10:00'),
        linha(d(-3), d(-2), 'DISTRIBUIÇÃO - NOVO PROCESSO', 'Texto 9 distribuição.', dest='TESTE COLAB B', concl=d(-2)+' 15:30'),
        linha(d(-40), d(-38), 'TESTE CONCLUIDA ANTIGA', 'Texto 10 antiga.', concl=d(-40)+' 09:00')]
r1 = importar('e4_lote1.xlsx', base + conc)
# lote 2: a tarefa 7 é reagendada (data muda) e a 1 também; lote 3: a 7 de novo -> reagendamentos sucessivos
b2 = [dict(x) for x in base]; b2[6]['Data'] = d(4); b2[0]['Data'] = d(-2)
importar('e4_lote2.xlsx', b2)
b3 = [dict(x) for x in b2]; b3[6]['Data'] = d(6)
r3 = importar('e4_lote3.xlsx', b3)
importar('e4_lote3_concluidas.xlsx', conc, lote=r3['lote_id'])   # concluídas do dia, no mesmo lote

INI, FIM = (HOJE - datetime.timedelta(days=30)).isoformat(), HOJE.isoformat()
def resumo(uid=ADMIN, ini=INI, fim=FIM, eq='null', col='null'):
    return json.loads(run(f"select indicadores_resumo('{ini}','{fim}',{eq},{col})", uid))
R = resumo(); C = R['contagens']
esperado = {'pendentes': 7, 'vencidas': 2, 'pf_judicial_vencido_conferir': 1, 'vencem_hoje': 1, 'd4_criticas': 1,
            'sem_inicio': 7, 'concluidas': 2, 'protocolos_realizados': 1, 'distribuicoes_realizadas': 1,
            'pedidos_reagendamento': 1, 'reagendamentos_efetivados': 3}
for k, v in esperado.items():
    check(f"Indicador '{k}' com resposta conhecida", v, C.get(k, 0))
check("Concluída há 40 dias fica fora do período de 30 dias", "0",
      run(f"select count(*) from indicadores_registros('{INI}','{FIM}',null,null,'concluidas') where compromisso='TESTE CONCLUIDA ANTIGA'", ADMIN))
check("Período maior inclui a conclusão antiga", "3", resumo(ini=(HOJE - datetime.timedelta(days=60)).isoformat())['contagens']['concluidas'])
check("Solicitação NÃO é contada como reagendamento efetivado (e vice-versa)", "1|3", f"{C['pedidos_reagendamento']}|{C['reagendamentos_efetivados']}")
check("PF Judicial vencido aparece como pendência de conferência, com o texto explícito", "t",
      run(f"select bool_and(detalhe like '%pendência de conferência, não perda de prazo presumida%') from indicadores_registros('{INI}','{FIM}',null,null,'pf_judicial_vencido_conferir')", ADMIN))
# reprodutibilidade
tot = run(f"select json_object_agg(indicador, n) from (select indicador, count(*) n from indicadores_registros('{INI}','{FIM}') group by 1) x", ADMIN)
check("Cartões = contagem do detalhamento (todos os indicadores)", "True", json.loads(tot) == C)
pc = json.loads(run(f"select json_agg(row_to_json(x)) from indicadores_por_colaborador('{INI}','{FIM}') x", ADMIN))
somas = {k: sum(p[k] for p in pc) for k in esperado}
check("Soma por colaborador = total do cartão (todos os indicadores)", "True", all(somas[k] == C.get(k, 0) for k in esperado))
dia = run(f"select sum(concluidas) from indicadores_concluidas_por_dia('{INI}','{FIM}')", ADMIN)
check("Gráfico de concluídas por dia soma o cartão; 1 ponto por dia do período", f"{C['concluidas']}|31",
      f"{dia}|{run(f'select count(*) from indicadores_concluidas_por_dia($${INI}$$,$${FIM}$$)', ADMIN)}")
# filtros
check("Filtro por equipe 1 (só colaborador A)", "5|1|0",
      f"{resumo(eq=EQ1)['contagens']['pendentes']}|{resumo(eq=EQ1)['contagens'].get('concluidas',0)}|{resumo(eq=EQ1)['contagens'].get('distribuicoes_realizadas',0)}")
check("Filtro por colaborador B", "2|1", f"{resumo(col=B)['contagens']['pendentes']}|{resumo(col=B)['contagens']['distribuicoes_realizadas']}")
# RLS
RA = resumo(uid=COLAB_A)['contagens']
check("Colaborador A vê só os próprios números", "5|1|0", f"{RA['pendentes']}|{RA.get('concluidas',0)}|{RA.get('distribuicoes_realizadas',0)}")
check("Colaborador A não vê registros de B no detalhamento", "0",
      run(f"select count(*) from indicadores_registros('{INI}','{FIM}') where responsavel_id={B}", COLAB_A))
# alertas novos e tela de prazos
cats = run("select string_agg(distinct categoria, ',' order by categoria) from v_prazos_risco where categoria in ('protocolo_sem_evidencia','reagendamentos_sucessivos')", ADMIN)
check("Alertas novos: protocolo sem evidência e reagendamentos sucessivos", "protocolo_sem_evidencia,reagendamentos_sucessivos", cats)
check("Reagendamentos sucessivos só na tarefa alterada 2 vezes", "TESTE REAGENDADA A",
      run("select string_agg(compromisso, ',') from v_prazos_risco where categoria='reagendamentos_sucessivos'", ADMIN))
check("Prazos em risco: criticidade e data de referência preenchidas", "0",
      run("select count(*) from v_prazos_risco where criticidade is null or (data_referencia is null and categoria <> 'pf_alterado_violacao')", ADMIN))
check("Prazos em risco: tudo pendente de conferência até alguém conferir", "t",
      run("select bool_and(situacao_conferencia='pendente_conferencia') from v_prazos_risco", ADMIN))
# reagendamentos
check("Reagendamentos: naturezas separadas (solicitação x efetivação)", "efetivacao:3,solicitacao:1",
      run("select string_agg(natureza||':'||n, ',' order by natureza) from (select natureza, count(*) n from v_reagendamentos group by 1) x", ADMIN))
check("Efetivações sem anotação de justificativa marcadas", "3", run("select count(*) from v_reagendamentos where sem_justificativa", ADMIN))
check("Texto original e autor da solicitação preservados", "TB|true",
      run("select autor||'|'||(texto_original like '%Favor reagendar%') from v_reagendamentos where natureza='solicitacao'", ADMIN))
# tratativa
check("Antes de configurar o início do monitoramento: concluídas não viram 'sem início'", "0",
      run("select count(*) from v_tratativa where status_tratativa='concluida_sem_inicio'", ADMIN))
run(f"update parametros set valor = to_jsonb('{(HOJE - datetime.timedelta(days=10)).isoformat()}T00:00:00-03:00'::text) where chave='tratativa_monitorada_desde'")
check("Depois de configurado: concluídas após a data sem início viram inconsistência", "2|1",
      run("select count(*) filter (where status_tratativa='concluida_sem_inicio')||'|'||count(*) filter (where status_tratativa='concluida_antes_do_monitoramento') from v_tratativa", ADMIN))
# tempos médios: abertura lida da tela e início pela extensão (tarefa 'TESTE HOJE A')
snap = json.dumps({"titulo": "TESTE HOJE A", "data_evento": d(0), "prazo_fatal": d(0), "partes": [],
                   "criado_em": (datetime.datetime.now(ZoneInfo('America/Sao_Paulo')) - datetime.timedelta(hours=30)).strftime("%d/%m/%Y %H:%M")})
run(f"select ext_status_tarefa('700001',$S${snap}$S$::jsonb)", COLAB_A)
run(f"select ext_registrar_evento(gen_random_uuid(),'inicio_tratativa','700001',$S${snap}$S$::jsonb)", COLAB_A)
h = run(f"select media_horas_abertura_inicio||'|'||n_abertura_inicio from indicadores_por_colaborador('{INI}','{FIM}') where responsavel='TESTE COLAB A'", ADMIN)
horas, n = h.split('|')
check("Tempo médio abertura→início calculado só com dados reais (1 tarefa, ~30 h, horário de Brasília)", "1|True", f"{n}|{29.0 <= float(horas) <= 33.0}")
check("Início registrado reduz 'sem início'", "6", resumo()['contagens']['sem_inicio'])
check("Indicador de 24 h só conta tarefas com abertura conhecida (extensão)", "0", resumo()['contagens'].get('sem_inicio_24h', 0))
q = resumo()
check("Resumo informa cobertura da extensão (abertura conhecida / início registrado)", "1|1", f"{q['pendentes_com_abertura_conhecida']}|{q['pendentes_com_inicio']}")
check("Anônimo não executa indicadores", "negado", "negado" if subprocess.run(PSQL + ["-d", DB], input=f"set role anon; select indicadores_resumo('{INI}','{FIM}');",
      capture_output=True, text=True).returncode else "permitido")

# listagens das telas (total exato + limite)
L = json.loads(run("select prazos_risco_listar(p_limite => 2)", ADMIN))
check("Prazos em risco: total exato mesmo com limite de linhas", f"{run('select count(*) from v_prazos_risco', ADMIN)}|2", f"{L['total']}|{len(L['linhas'])}")
L = json.loads(run("select prazos_risco_listar(p_processo => '0000001652026')", ADMIN))
check("Prazos em risco: busca por processo ignora pontuação", run('select count(*) from v_prazos_risco', ADMIN), L['total'])
L = json.loads(run("select reagendamentos_listar(p_natureza => 'solicitacao')", ADMIN))
check("Reagendamentos: filtro por natureza e contagem por natureza", "1|3", f"{L['total']}|{L['por_natureza']['efetivacao']}")
L = json.loads(run(f"select indicadores_detalhe('{INI}','{FIM}','pendentes', p_limite => 3)", ADMIN))
check("Detalhamento de indicador: total exato + limite", "7|3", f"{L['total']}|{len(L['linhas'])}")
L = json.loads(run("select tratativa_listar()", COLAB_B))
check("Tratativa vista pelo colaborador B: só as dele", "2", L['por_status'].get('pendente_sem_inicio', 0))

w = max(len(x[0]) for x in res)
for n_, e, o, s in res: print(f"{s:5} | {n_:<{w}} | esperado: {e} | obtido: {o}")
print(f"\n{sum(1 for x in res if x[3]=='OK')}/{len(res)} OK — executado em {datetime.datetime.now():%d/%m/%Y %H:%M}")
sys.exit(0 if all(x[3] == "OK" for x in res) else 1)
