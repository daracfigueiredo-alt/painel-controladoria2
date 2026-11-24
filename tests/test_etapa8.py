"""Testes da Etapa 8 (0026/0027): tarefas de análise — aprovação, fila da extensão, bloqueio,
confirmação e tarefa de teste. Banco LOCAL, dados FICTÍCIOS (mesma base da Etapa 7)."""
import json, subprocess, os, sys
PSQL = ["psql", "-h", "/tmp", "-p", "5433", "-U", "postgres", "-At", "-q", "-v", "ON_ERROR_STOP=1"]
HERE = os.path.dirname(os.path.abspath(__file__)); RAIZ = os.path.join(HERE, "..")
MIGDIR = os.path.join(RAIZ, "supabase", "migrations"); FX = os.path.join(HERE, "webjur", "fixtures")
MIG = sorted(os.path.join(MIGDIR, f) for f in os.listdir(MIGDIR)); DB = "ctrl_etapa8"; res = []
ADMIN, COLAB = "00000000-0000-0000-0000-00000000000a", "00000000-0000-0000-0000-00000000000c"
def run(sql, uid=None, ok_error=False):
    pre = f"set role authenticated; set request.jwt.claim.sub = '{uid}';\n" if uid else ""
    p = subprocess.run(PSQL + ["-d", DB], input=pre + sql, capture_output=True, text=True)
    if p.returncode and not ok_error: raise RuntimeError(sql[:300] + "\n" + p.stderr)
    return p.stdout.strip(), p.stderr.strip(), p.returncode
q = lambda sql, uid=None: run(sql, uid)[0]
J = lambda sql, uid=ADMIN: json.loads(q(sql, uid))
def check(n, e, o): res.append((n, str(e), str(o), "OK" if str(e) == str(o) else "FALHA"))
def recusa(n, sql, uid=ADMIN, trecho=""):
    _, e, rc = run(sql, uid, ok_error=True)
    check(n, "recusado", "recusado" if rc and trecho in e else (e[:120] or "aceito"))

subprocess.run(["python3", os.path.join(HERE, "webjur", "gerar_fixtures.py")], check=True, capture_output=True)
subprocess.run(PSQL + ["-d", "postgres", "-c", f"drop database if exists {DB}", "-c", f"create database {DB}"], check=True, capture_output=True)
for f in [os.path.join(HERE, "00_stub_supabase_local.sql")] + MIG:
    subprocess.run(PSQL + ["-d", DB, "-f", f], check=True, capture_output=True)
q(f"""insert into colaboradores(nome_advbox, origem) values ('TESTE COLAB A','administrativo');
  insert into perfis values ('{ADMIN}','admin',null), ('{COLAB}','colaborador',(select id from colaboradores limit 1));
  -- estes testes cobrem a criação pela extensão no ADVBOX (destino 'advbox'); o destino Atlas está em test_etapa11.py
  update parametros set valor = '"advbox"' where chave = 'tarefa_analise_destino';""")
LER = """const W=require(process.argv[1]),fs=require('fs'),c=require('crypto');const f=process.argv[2];
const rs=W.lerEmails(new Uint8Array(fs.readFileSync(f)),f);
console.log(JSON.stringify(rs.map(r=>({sha:c.createHash('sha256').update(r.texto_bloco).digest('hex'),
 remessa:{formato:r.formato,recebido_em:r.recebido_em,secoes:r.secoes.map(s=>({ordem:s.ordem,caderno:s.caderno,data:s.data,declarado:s.declarado})),avisos:r.avisos},
 publicacoes:r.publicacoes.map(p=>W.paraRegistro(p,r))}))));"""
out = subprocess.run(["node", "-e", LER, os.path.join(RAIZ, "painel", "js", "webjur_email.js"), os.path.join(FX, "email_ficticio_1.html")], capture_output=True, text=True, check=True).stdout
for d in json.loads(out):
    J(f"select pub_registrar_remessa('f1','{d['sha']}',$R${json.dumps(d['remessa'], ensure_ascii=False)}$R$::jsonb,$P${json.dumps(d['publicacoes'], ensure_ascii=False)}$P$::jsonb)")
P1, P2 = q("select id from publicacoes order by id limit 1"), q("select id from publicacoes order by id offset 1 limit 1")
CNJ1 = q(f"select cnj from publicacoes where id={P1}")
J(f"select pub_registrar_conferencia({P1}, 'nao_encontrada_advbox', 'intimacoes', '{{}}'::jsonb, null, 'manual')")
J(f"select pub_registrar_conferencia({P2}, 'processo_nao_cadastrado', 'intimacoes', '{{}}'::jsonb, null, 'manual')")
T1, T2 = q(f"select id from tarefas_analise where publicacao_id={P1}"), q(f"select id from tarefas_analise where publicacao_id={P2}")

# ---------------------------------------------------------------- parâmetros e preparo
check("Tipo da tarefa = nome exato do ADVBOX, confirmado", "ANÁLISE DO CASO (50 pts)|true",
      q("select valor #>> '{}' || '|' || confirmado from parametros where chave='tarefa_analise_tipo'"))
check("IDs do ADVBOX: tipo 8849391, responsável 296462", "8849391|296462",
      q("select (select valor #>> '{}' from parametros where chave='tarefa_analise_tipo_advbox_id')||'|'||(select valor #>> '{}' from parametros where chave='tarefa_analise_responsavel_advbox_id')"))
check("Tarefa nova preparada já com o tipo exato", "ANÁLISE DO CASO (50 pts)", q(f"select tipo from tarefas_analise where id={T1}"))
check("Prazo fatal previsto = data + 1 dia útil (trigger na criação)", "t",
      q(f"select (pf_previsto = somar_dias_uteis(data_prevista, 1) and pf_previsto > data_prevista)::text::char from tarefas_analise where id={T1}"))

# ---------------------------------------------------------------- fila e travas
check("Fila vazia antes da aprovação", "None|0", (lambda d: f"{d['proxima']}|{d['aprovadas']}")(J("select ext_analise_fila()")))
check("Colaborador não vê a fila", "False", J("select ext_analise_fila()", COLAB)["admin"])
recusa("Criar sem aprovação: recusado", f"select analise_iniciar_criacao({T1})", trecho="não permitida")
J(f"select analise_decidir({T1}, 'aprovar', 'ok')"); J(f"select analise_decidir({T2}, 'aprovar', 'ok')")
check("Fila devolve a primeira aprovada", f"{T1}|2", (lambda d: f"{d['proxima']}|{d['aprovadas']}")(J("select ext_analise_fila()")))
recusa("Colaborador não inicia criação", f"select analise_iniciar_criacao({T1})", COLAB, "Somente")
ini = J(f"select analise_iniciar_criacao({T1})")
check("Início devolve o conteúdo exato (tipo, IDs ADVBOX, busca pelo CNJ, datas)",
      f"ANÁLISE DO CASO (50 pts)|8849391|296462|{CNJ1}|True",
      f"{ini['tipo']}|{ini['tipo_advbox_id']}|{ini['responsavel_advbox_id']}|{ini['busca']}|{bool(ini['pf_previsto'] and ini['data_prevista'])}")
recusa("Segundo início da mesma tarefa (duas abas): recusado", f"select analise_iniciar_criacao({T1})", trecho="criacao_em_andamento")
check("Em andamento sai da fila", f"{T2}", J("select ext_analise_fila()")["proxima"])

# bloqueio: processo ambíguo, nada enviado
op = json.dumps({"busca": CNJ1, "opcoes": [{"lawsuit_id": "14149776", "texto": "A"}, {"lawsuit_id": "14149777", "texto": "B"}]})
J(f"select analise_bloquear_criacao({T1}, 'processo_ambiguo', '{op}'::jsonb)")
check("Bloqueio: volta a aprovada, com motivo, e sai da fila", f"aprovada|processo_ambiguo|{T2}|1",
      q(f"select status||'|'||bloqueio_criacao from tarefas_analise where id={T1}") + "|" + (lambda d: f"{d['proxima']}|{d['bloqueadas']}")(J("select ext_analise_fila()")))
recusa("Iniciar tarefa bloqueada: recusado", f"select analise_iniciar_criacao({T1})", trecho="bloqueada")
recusa("Desbloquear ambíguo sem escolher o processo: recusado", f"select analise_desbloquear({T1}, null, 'conferido no ADVBOX')", trecho="Escolha")
recusa("Desbloquear com processo fora das opções: recusado", f"select analise_desbloquear({T1}, '999', 'conferido no ADVBOX')", trecho="não está entre")
J(f"select analise_desbloquear({T1}, '14149777', 'É o cadastro do cliente B')")
check("Desbloqueio grava o processo escolhido e devolve à fila", f"14149777|{T1}",
      q(f"select advbox_lawsuit_id from tarefas_analise where id={T1}") + "|" + str(J("select ext_analise_fila()")["proxima"]))
ini = J(f"select analise_iniciar_criacao({T1})")
check("Novo início já informa o processo escolhido; tentativas contadas", "14149777|2",
      f"{ini['advbox_processo_id']}|" + q(f"select tentativas from tarefas_analise where id={T1}"))
recusa("Confirmação com ID inválido: recusada", f"select analise_confirmar_criacao({T1}, 'abc', '{{}}'::jsonb)", trecho="inválido")
J(f"""select analise_confirmar_criacao({T1}, '297747789', '{{"lawsuit_id":"14149777","url":"https://app.advbox.com.br/0?t=297747789"}}'::jsonb)""")
check("Confirmada: criada, com ID e processo; processo do cadastro ligado", "criada|297747789|14149777|14149777",
      q(f"select t.status||'|'||t.advbox_tarefa_id||'|'||t.advbox_lawsuit_id||'|'||coalesce(p.advbox_lawsuit_id,'-') from tarefas_analise t left join processos p on p.id=t.processo_id where t.id={T1}"))

# interrompida: em andamento há mais de 10 min -> verificar
J(f"select analise_iniciar_criacao({T2})")
q(f"alter table tarefas_analise disable trigger user; update tarefas_analise set atualizada_em = now() - interval '11 minutes' where id={T2}; alter table tarefas_analise enable trigger user;")
d = J("select ext_analise_fila()")
check("Criação interrompida > 10 min vai para 'verificar no ADVBOX' e não volta à fila", "verificar_no_advbox|None|1",
      q(f"select status from tarefas_analise where id={T2}") + f"|{d['proxima']}|{d['verificar']}")
recusa("Verificar no ADVBOX não pode ser recriada direto", f"select analise_iniciar_criacao({T2})", trecho="não permitida")
J(f"select analise_confirmar_nao_criada({T2}, 'Conferido: não existe no ADVBOX')")
check("Após conferência 'não criada', volta à fila", f"{T2}", J("select ext_analise_fila()")["proxima"])

# conferência revista depois da aprovação: criação recusada
J(f"select pub_registrar_conferencia({P2}, 'encontrada_advbox', 'intimacoes', '{{\"publicacao_advbox\":\"1\"}}'::jsonb, null, 'manual')")
recusa("Publicação reconferida como encontrada: criação recusada", f"select analise_iniciar_criacao({T2})", trecho="conferência mais recente")

# ---------------------------------------------------------------- tarefa de teste
recusa("Teste fora de caso de TESTE: recusado", "select analise_preparar_teste('BANCO X', null)", trecho="TESTE")
recusa("Colaborador não prepara teste", "select analise_preparar_teste('TESTE 1.0', null)", COLAB, "Somente")
TT = J("select analise_preparar_teste('TESTE 1.0', null)")["id"]
check("Teste preparado sem publicação, busca 'TESTE 1.0', tipo exato", "preparada|t|TESTE 1.0|ANÁLISE DO CASO (50 pts)",
      q(f"select status||'|'||teste::text::char||'|'||busca_advbox||'|'||tipo from tarefas_analise where id={TT}"))
J(f"select analise_decidir({TT}, 'aprovar', 'teste')")
check("Teste aprovado tem prioridade na fila", f"{TT}", J("select ext_analise_fila()")["proxima"])
ini = J(f"select analise_iniciar_criacao({TT})")
check("Início do teste busca pelo caso de teste", "TESTE 1.0|True", f"{ini['busca']}|{ini['teste']}")
recusa("Tabela: tarefa comum sem publicação é recusada",
       "insert into tarefas_analise (requer_cadastro,tipo,responsavel,observacoes,status) values (false,'x','y','z','preparada')", None, "origem")

# ---------------------------------------------------------------- painel
L = J("select analise_listar(null)")
check("Lista do painel: em andamento primeiro, com bloqueio/teste/datas", f"{TT}|True",
      f"{L[0]['id']}|{L[0]['teste']}")
recusa("Colaborador não lista", "select analise_listar(null)", COLAB, "Somente")
D = J(f"select analise_detalhe({T1})")
check("Detalhe traz o histórico completo (preparada→aprovada→andamento→bloqueio→…→criada)", "criada",
      D["historico"][-1]["para"])
check("Histórico registra o bloqueio e a resolução", "2", q(f"select count(*) from tarefas_analise_historico where tarefa_analise_id={T1} and status_anterior='aprovada' and status_novo='aprovada' or (tarefa_analise_id={T1} and nota like 'Criação não enviada%')"))


# ---------------------------------------------------------------- 0028: cadastro confirmado ao criar
P3 = q("select id from publicacoes order by id offset 2 limit 1")
J(f"select pub_registrar_conferencia({P3}, 'processo_nao_cadastrado', 'intimacoes', '{{}}'::jsonb, null, 'manual')")
T3 = q(f"select id from tarefas_analise where publicacao_id={P3} and status='preparada'")
q(f"update tarefas_analise set processo_id = null where id={T3}")   # como no banco real: processo ausente da base
CNJ3 = q(f"select cnj from tarefas_analise where id={T3}")
J(f"select analise_decidir({T3}, 'aprovar', 'ok')"); J(f"select analise_iniciar_criacao({T3})")
J(f"""select analise_confirmar_criacao({T3}, '297000003', '{{"lawsuit_id":"19000003"}}'::jsonb)""")
check("Processo não cadastrado: ao criar, cadastro confirmado e processo ligado com o ID do ADVBOX", "t|t|19000003",
      q(f"select (t.cadastro_confirmado_em is not null)::text::char||'|'||(t.processo_id is not null)::text::char||'|'||coalesce(p.advbox_lawsuit_id,'-') from tarefas_analise t left join processos p on p.id=t.processo_id where t.id={T3}"))
check("Lista do painel traz a confirmação do cadastro", "True", any(x["id"] == int(T3) and x["cadastro_confirmado_em"] for x in J("select analise_listar(null)")))

w = max(len(r[0]) for r in res)
for n, e, o, s in res: print(f"{s:5} {n}" + ("" if s == "OK" else f"\n      esperado={e}\n      obtido  ={o}"))
ok = sum(r[3] == "OK" for r in res); print(f"\n{ok}/{len(res)} OK"); sys.exit(0 if ok == len(res) else 1)
