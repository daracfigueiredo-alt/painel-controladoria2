"""Testes da migração 0056 (relatórios gerenciais com gráficos de pizza). Banco LOCAL, dados FICTÍCIOS.
Usa o banco do tests/test_etapa16.py rodado com MANTER=1 (ctrl_etapa16), que já tem audiências, intimações,
tarefas e inconsistências fictícias; aplica a 0056 se ainda não estiver lá."""
import json, subprocess, os, time
PSQL = ["psql", "-h", "/tmp", "-p", "5433", "-U", "postgres", "-At", "-q", "-v", "ON_ERROR_STOP=1"]
HERE = os.path.dirname(os.path.abspath(__file__))
DB = os.environ.get("DB", "ctrl_etapa16"); res = []
ADMIN = "00000000-0000-0000-0000-00000000000a"; COLAB = "00000000-0000-0000-0000-00000000000c"
LIDER = "00000000-0000-0000-0000-0000000000d1"; DIR = "00000000-0000-0000-0000-0000000000d9"
SEM_PERFIL = "00000000-0000-0000-0000-0000000000f7"
AREAS = ["diretoria", "visao-geral", "colaboradores", "prazos", "reagendamentos", "tratativa", "audiencias", "minha-pauta",
         "solicitacoes", "atlas", "cadastro-atlas", "intimacoes-cnj", "publicacoes", "inconsistencias", "analise",
         "importacao", "double-check", "auditoria", "configuracoes"]

def run(sql, uid=None, anon=False):
    pre = f"set role authenticated; set request.jwt.claim.sub = '{uid}';\n" if uid else ("set role anon;\n" if anon else "")
    p = subprocess.run(PSQL + ["-d", DB], input=pre + sql, capture_output=True, text=True)
    return p.returncode, p.stdout.strip(), p.stderr.strip()
def q(sql, uid=None):
    c, o, e = run(sql, uid)
    if c: raise RuntimeError(sql[:300] + "\n" + e)
    return o.split("\n")[-1] if o else o
J = lambda sql, uid=None: json.loads(q(sql, uid))   # sem uid = superusuário (contagem de referência)
R = lambda sql, uid=ADMIN: json.loads(q(sql, uid))  # relatório como usuário
norm = lambda v: json.dumps(v, sort_keys=True, ensure_ascii=False) if isinstance(v, (dict, list)) else str(v)
def check(n, e, o): res.append((n, norm(e), norm(o), "OK" if norm(e) == norm(o) else "FALHA"))
def recusa(n, sql, uid, trecho, anon=False):
    c, o, e = run(sql, uid, anon); check(n, f"recusado ({trecho})", f"recusado ({trecho})" if c and trecho in e else f"aceito/outro: {(o or e)[:200]}")
RG = lambda area, ini="null", fim="null": f"select relatorio_gerencial('{area}', {ini}, {fim})"
fat = lambda r, titulo: {i["rotulo"]: i["valor"] for g in r["graficos"] if g["titulo"] == titulo for i in g["itens"]}
kpi = lambda r, rot: next(k["valor"] for k in r["indicadores"] if k["rotulo"] == rot)

# banco do test_etapa16 (MANTER=1); 0056 aplicada aqui se ainda não estiver
if subprocess.run(PSQL + ["-d", DB, "-c", "select 1"], capture_output=True).returncode:
    subprocess.run(["python3", os.path.join(HERE, "test_etapa16.py")], env={**os.environ, "MANTER": "1"}, capture_output=True)
if q("select count(*) from pg_proc where proname = 'relatorio_gerencial'") == "0":
    subprocess.run(PSQL + ["-d", DB, "-f", os.path.join(HERE, "..", "supabase", "migrations", "0056_relatorios_gerenciais.sql")], check=True, capture_output=True)
if q("select count(*) from pg_proc where proname = '_rg_media'") == "0":
    subprocess.run(PSQL + ["-d", DB, "-f", os.path.join(HERE, "..", "supabase", "migrations", "0057_relatorio_media_sem_dado.sql")], check=True, capture_output=True)
q(f"insert into auth.users (id, email) values ('{SEM_PERFIL}', 'sp@x.invalid') on conflict do nothing")

# ---------------- estrutura: as 19 áreas do menu respondem, com indicadores e pizzas bem formadas
tempos = []
for a in AREAS:
    t = time.time(); r = R(RG(a)); tempos.append(time.time() - t)
    ok = (r["area"] == a and isinstance(r["indicadores"], list) and len(r["indicadores"]) >= 1 and isinstance(r["graficos"], list) and len(r["graficos"]) >= 2
          and all(set(g) == {"titulo", "base", "itens", "total"} and g["base"] in ("situação atual", "no período") for g in r["graficos"])
          and all(i["valor"] > 0 and i["rotulo"] for g in r["graficos"] for i in g["itens"])
          and all(g["total"] == sum(i["valor"] for i in g["itens"]) for g in r["graficos"])
          and all(isinstance(k["valor"], int) or (k["valor"] is None and "média" in k["rotulo"].lower()) for k in r["indicadores"]))
    check(f"Área {a}: indicadores e pizzas bem formados", True, ok)
check("Todas as áreas em menos de 2 s cada (banco local)", True, max(tempos) < 2)
r = R(RG("audiencias"))
check("Fatias em ordem decrescente", True, all([i["valor"] for i in g["itens"]] == sorted([i["valor"] for i in g["itens"]], reverse=True) for g in r["graficos"]))
check("Período padrão = últimos 30 dias", q("select (hoje_brasilia() - 30)::text || '|' || hoje_brasilia()::text"), r["periodo"]["de"] + "|" + r["periodo"]["ate"])
check("Visão geral = mesmo relatório da diretoria", json.dumps(R(RG("diretoria"))["graficos"]), json.dumps(R(RG("visao-geral"))["graficos"]))

# ---------------- números iguais ao banco
dir_sit = J("select coalesce(jsonb_object_agg(situacao, n), '{}') from (select situacao, count(*) n from audiencias where situacao <> 'descartada' group by 1) x")
check("Audiências por situação (pizza) = banco", dir_sit, fat(r, "Por situação"))
check("Pendências (pizza) = _audiencia_pendencias", J("select coalesce(jsonb_object_agg(p, n), '{}') from (select p, count(*) n from audiencias a cross join lateral unnest(_audiencia_pendencias(a)) p group by 1) x"),
      fat(r, "Pendências"))
check("Audiências sem data (indicador) = banco", int(q("select count(*) from audiencias where situacao = 'agendada' and data is null")), kpi(r, "Sem data na intimação"))
d = R(RG("diretoria"))
check("Tarefas por situação = v_tarefas_atuais", J("select coalesce(jsonb_object_agg(situacao, n), '{}') from (select situacao, count(*) n from v_tarefas_atuais group by 1) x"), fat(d, "Tarefas por situação"))
check("Inconsistências abertas (indicador) = banco", int(q("select count(*) from inconsistencias where situacao = 'aberta'")), kpi(d, "Inconsistências abertas"))
ic = R(RG("inconsistencias"))
check("Inconsistências abertas por tipo = banco", J("select coalesce(jsonb_object_agg(tipo, n), '{}') from (select tipo, count(*) n from inconsistencias where situacao = 'aberta' group by 1) x"), fat(ic, "Abertas por tipo"))
cn = R(RG("intimacoes-cnj"))
check("Intimações CNJ no período = banco", int(q("select count(*) from cnj_comunicacoes where data_disponibilizacao between hoje_brasilia() - 30 and hoje_brasilia()")), kpi(cn, "Comunicações no período"))
check("Como foram encontradas: soma = total do período", kpi(cn, "Comunicações no período"), sum(fat(cn, "Como foram encontradas").values()))
cf = R(RG("configuracoes"))
check("Usuários por perfil = tabela perfis", J("select jsonb_object_agg(papel, n) from (select papel, count(*) n from perfis group by 1) x"), fat(cf, "Usuários por perfil"))
check("Parâmetros por sistema somam todos os parâmetros", int(q("select count(*) from parametros")), sum(fat(cf, "Parâmetros por sistema").values()))

tr = R(RG("tratativa", "'2020-01-01'", "'2020-01-31'"))
check("Média sem dado no período vem vazia (tela mostra —), não 0", None, kpi(tr, "Horas médias até o início (período)"))
recusa("_rg_media fechada ao usuário logado", "select _rg_media('select 1')", ADMIN, "permission denied")

# ---------------- período
q("""insert into cnj_comunicacoes (id, cnj, numero_processo, data_disponibilizacao, texto, sigla_tribunal, tipo_comunicacao, encontrada_por, dados)
     values (991701, '0001701-11.2026.8.13.0024', '0001701-11.2026.8.13.0024', hoje_brasilia() - 200, 'Intimação antiga E17', 'TJXX', 'Intimação', '{oab:MG000}', '{}'),
            (991702, '0001702-11.2026.8.13.0024', '0001702-11.2026.8.13.0024', hoje_brasilia() - 199, 'Intimação antiga E17', 'TJXX', 'Edital', '{processo}', '{}')
     on conflict (id) do nothing""", None)
ant = R(RG("intimacoes-cnj", "hoje_brasilia() - 201", "hoje_brasilia() - 199"))
check("Período antigo: só as 2 comunicações daquelas datas", 2, kpi(ant, "Comunicações no período"))
check("Período antigo: pizza por tribunal", {"TJXX": 2}, fat(ant, "Por tribunal"))
check("Período antigo: OAB × varredura", {"Pela OAB": 1, "Pela varredura dos processos": 1}, fat(ant, "Como foram encontradas"))
check("Período antigo não entra nos últimos 30 dias", "TJXX" in fat(R(RG("intimacoes-cnj")), "Por tribunal"), False)
check("Retrato atual não muda com o período (audiências por situação)", fat(r, "Por situação"),
      fat(R(RG("audiencias", "'2020-01-01'", "'2020-01-31'")), "Por situação"))
check("Período sem nada: pizza 'no período' vazia, total 0", "[]|0", (lambda g: json.dumps(g["itens"]) + "|" + str(g["total"]))(
      next(g for g in R(RG("auditoria", "'2020-01-01'", "'2020-01-31'"))["graficos"] if g["titulo"] == "Por tabela")))
recusa("Fim antes do início é recusado", RG("prazos", "'2026-11-10'", "'2026-11-01'"), ADMIN, "anterior ao início")
recusa("Período acima de 400 dias é recusado", RG("prazos", "'2024-01-01'", "'2026-11-01'"), ADMIN, "400 dias")
recusa("Área desconhecida é recusada", RG("x''; drop table perfis; --"), ADMIN, "Área sem relatório")
check("Tabela perfis intacta depois da tentativa", True, int(q("select count(*) from perfis")) > 0)

# ---------------- acesso: só controladoria e diretoria
check("Diretoria lê o relatório", "audiencias", R(RG("audiencias"), DIR)["area"])
recusa("Peticionador não lê", RG("audiencias"), COLAB, "Somente")
recusa("Líder não lê", RG("audiencias"), LIDER, "Somente")
recusa("Usuário sem perfil não lê", RG("audiencias"), SEM_PERFIL, "Somente")
recusa("Anônimo não executa", RG("audiencias"), None, "permission denied", anon=True)
recusa("Funções internas fechadas ao usuário logado", "select _rg_num('select 1')", ADMIN, "permission denied")
recusa("_rg_pizza fechada ao usuário logado", "select _rg_pizza('x','y','select 1, 1')", ADMIN, "permission denied")
q("delete from cnj_comunicacoes where id in (991701, 991702)", None)

ok = sum(1 for r_ in res if r_[3] == "OK")
for n, e, o, s in res:
    if s != "OK": print(f"FALHA: {n}\n  esperado: {e}\n  obtido:   {o}")
print(f"{ok}/{len(res)} OK")
