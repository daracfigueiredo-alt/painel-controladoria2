"""Testes da Etapa 9 (0029): auditoria e segurança. Banco LOCAL, dados FICTÍCIOS.
Inclui a chamada de TODAS as funções SECURITY DEFINER como colaborador e como usuário sem perfil."""
import json, subprocess, os, sys
PSQL = ["psql", "-h", "/tmp", "-p", "5433", "-U", "postgres", "-At", "-q", "-v", "ON_ERROR_STOP=1"]
HERE = os.path.dirname(os.path.abspath(__file__)); MIGDIR = os.path.join(HERE, "..", "supabase", "migrations")
MIG = sorted(os.path.join(MIGDIR, f) for f in os.listdir(MIGDIR)); DB = "ctrl_etapa9"; res = []
ADMIN, ADMIN2, COLAB, SEM = ("00000000-0000-0000-0000-00000000000a", "00000000-0000-0000-0000-00000000000b",
                             "00000000-0000-0000-0000-00000000000c", "00000000-0000-0000-0000-0000000000ff")
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
    check(n, "recusado", "recusado" if rc and trecho in e else (e[:140] or "aceito"))

subprocess.run(PSQL + ["-d", "postgres", "-c", f"drop database if exists {DB}", "-c", f"create database {DB}"], check=True, capture_output=True)
for f in [os.path.join(HERE, "00_stub_supabase_local.sql")] + MIG:
    subprocess.run(PSQL + ["-d", DB, "-f", f], check=True, capture_output=True)
q(f"""insert into auth.users (id, email) values ('{ADMIN}','admin@exemplo.invalid'),('{ADMIN2}','admin2@exemplo.invalid'),
       ('{COLAB}','colab@exemplo.invalid'),('{SEM}','sem@exemplo.invalid');
  insert into colaboradores(nome_advbox, origem) values ('TESTE COLAB A','administrativo');
  insert into perfis values ('{ADMIN}','admin',null), ('{COLAB}','colaborador',(select id from colaboradores limit 1));""")

# ---------------------------------------------------------------- funções SECURITY DEFINER
COLAB_PODE = {"ext_analise_fila", "ext_inicios_por_ids", "ext_registrar_evento", "ext_registrar_reedicao", "ext_status_tarefa",
              "is_admin", "meu_colaborador_id", "tratativa_da_tarefa", "tratativas_visiveis", "_auditoria_categoria",
              "ext_excecao_d4", "_excecao_d4_em",
              "ext_execucao", "ext_execucao_marcar", "ext_anexo_registrar", "solicitacoes_listar", "minha_pauta", "audiencias_painel",
              "solicitacao_reagendamento_pedir", "solicitacao_cancelar"}   # 0058: o peticionador pede e cancela o próprio reagendamento   # 0051: o advogado vê as audiências em que foi designado   # 0037: consulta da exceção de D-4 (marcar só líder/controladoria)
fns = q("""select p.proname || chr(9) || coalesce(array_to_string(array(select format_type(t,null) from unnest(p.proargtypes) t), ','), '')
             from pg_proc p join pg_namespace n on n.oid=p.pronamespace
            where n.nspname='public' and p.prosecdef and has_function_privilege('authenticated', p.oid, 'execute') order by 1""").splitlines()
falhas = []
for l in fns:
    nome, tipos = (l.split("\t") + [""])[:2]
    chamada = f"select public.{nome}({','.join('null::' + t for t in tipos.split(',') if t)})"
    for quem, rot in ((COLAB, "colaborador"), (SEM, "sem perfil")):
        _, err, rc = run(chamada, quem, ok_error=True)
        negado = rc != 0 and any(s in err for s in ("Somente", "sem perfil", "42501"))
        if nome in COLAB_PODE and rot == "colaborador": continue
        if nome in ("is_admin", "meu_colaborador_id", "tratativa_da_tarefa", "tratativas_visiveis", "ext_analise_fila", "_auditoria_categoria", "_excecao_d4_em",
                    "_pode_planejar", "meu_papel", "meus_colaboradores", "pode_ler_tudo", "pode_trabalhar_tarefa", "planejamento_colaboradores"): continue  # 0038-0040: falso/vazio sem perfil  # devolvem vazio/falso sem perfil
        if not negado: falhas.append(f"{nome} ({rot}): {err[:80] or 'aceito'}")
check(f"Todas as {len(fns)} funções SECURITY DEFINER recusam quem não deve (colaborador / sem perfil)", "", " | ".join(falhas))
check("Sem perfil: is_admin falso e fila da extensão sem acesso", "f|false", q("select is_admin()", SEM) + "|" + str(J("select ext_analise_fila()", SEM)["admin"]).lower())
recusa("Log de integração: perfil comum não grava direto", "select registrar_log_integracao('sistema','erro','x','falso erro','{}')", COLAB, "permission denied")
recusa("Log de integração: nem administradora grava direto (só o sistema)", "select registrar_log_integracao('sistema','erro','x','falso erro','{}')", ADMIN, "permission denied")

# ---------------------------------------------------------------- imutabilidade, inclusive TRUNCATE
for t in ["eventos", "log_integracao", "tarefas_analise_historico", "auditoria_configuracao", "linhas_importadas", "publicacoes"]:
    _, e, rc = run(f"truncate public.{t} cascade", None, ok_error=True)
    check(f"TRUNCATE barrado em {t} (até para o dono do banco)", "recusado", "recusado" if rc and "imutável" in e else (e[:100] or "aceito"))
check("Colaborador não vê linhas da auditoria de configuração (RLS)", "0", q("select count(*) from auditoria_configuracao", COLAB))

# ---------------------------------------------------------------- parâmetros: só por função, com motivo, auditado
recusa("Parâmetro: colaborador não altera", "select admin_definir_parametro('tarefa_analise_pf_dias_uteis','2',true,'motivo qualquer')", COLAB, "Somente")
recusa("Parâmetro: sem motivo é recusado", "select admin_definir_parametro('tarefa_analise_pf_dias_uteis','2',true,'curto')", ADMIN, "motivo")
recusa("Parâmetro: tipo diferente do atual é recusado", "select admin_definir_parametro('tarefa_analise_pf_dias_uteis','\"dois\"',true,'motivo de teste longo')", ADMIN, "tipo")
recusa("Parâmetro inexistente: só por migração", "select admin_definir_parametro('nao_existe','1',true,'motivo de teste longo')", ADMIN, "inexistente")
J("select admin_definir_parametro('tarefa_analise_pf_dias_uteis','2',true,'Teste: prazo de 2 dias úteis')")
a = J("select to_jsonb(a) from auditoria_configuracao a where tabela='parametros' and chave='tarefa_analise_pf_dias_uteis' order by id desc limit 1")
check("Parâmetro alterado: antes, depois, quem e motivo registrados", f"1|2|{ADMIN}|Teste: prazo de 2 dias úteis",
      f"{a['antes']['valor']}|{a['depois']['valor']}|{a['usuario']}|{a['motivo']}")
recusa("Auditoria de configuração é imutável", f"update auditoria_configuracao set motivo='x' where id={J('select max(id) from auditoria_configuracao')}", None, "imutável")

# ---------------------------------------------------------------- perfis
L = J("select admin_listar_usuarios()")
check("Lista de usuários: 4 contas, papel e colaborador", "admin|admin@exemplo.invalid,colaborador|colab@exemplo.invalid,None|sem@exemplo.invalid",
      ",".join(f"{u['papel']}|{u['email']}" for u in L if u['email'] != 'admin2@exemplo.invalid'))
recusa("Perfil: colaborador sem vínculo ao ADVBOX é recusado", f"select admin_definir_perfil('{SEM}','colaborador',null,'novo colaborador de teste')", ADMIN, "obrigatório")
recusa("Perfil: administradora não retira o próprio acesso", f"select admin_definir_perfil('{ADMIN}','colaborador',1,'troca de papel de teste')", ADMIN, "próprio")
J(f"select admin_definir_perfil('{ADMIN2}','admin',null,'Segunda administradora de teste')")
J(f"select admin_definir_perfil('{ADMIN2}',null,null,'Retirada do acesso de teste')")
check("Perfil criado e retirado: duas linhas na auditoria, com motivo", "INSERT:Segunda administradora de teste|DELETE:Retirada do acesso de teste",
      q(f"select string_agg(operacao||':'||motivo, '|' order by id) from auditoria_configuracao where tabela='perfis' and chave='{ADMIN2}'"))
recusa("Último administrador não pode ser removido", f"select admin_definir_perfil('{ADMIN}',null,null,'remover a ultima admin')", ADMIN, "próprio")

# ---------------------------------------------------------------- calendário
cid = J("select admin_cadastrar_dia_nao_util('2026-12-09','tribunal','feriado','Teste','Portaria fictícia','8.13',null)")
recusa("Remover dia do calendário sem motivo: recusado", f"select admin_remover_dia_nao_util({cid}, 'x')", ADMIN, "motivo")
J(f"select admin_remover_dia_nao_util({cid}, 'Cadastrado por engano no teste')")
check("Dia do calendário: cadastro e remoção na auditoria (com o dia removido guardado)", "INSERT|DELETE:Cadastrado por engano no teste:2026-12-09",
      q(f"select string_agg(operacao || case when operacao='DELETE' then ':'||motivo||':'||(antes->>'data') else '' end, '|' order by id) from auditoria_configuracao where tabela='calendario_dias_nao_uteis' and chave='{cid}'"))

# ---------------------------------------------------------------- linha do tempo e integridade
T = J("select auditoria_linha_tempo(current_date - 1, current_date, null, null, 500)")
cats = sorted({i["categoria"] for i in T["itens"]})
check("Linha do tempo junta configuração e eventos administrativos do dia", "True", {"configuracao", "administrativo"} <= set(cats))
check("Filtro por categoria", "True", all(i["categoria"] == "configuracao" for i in J("select auditoria_linha_tempo(current_date - 1, current_date, 'configuracao', null, 500)")["itens"]))
check("Busca por e-mail de quem alterou", "True", J("select auditoria_linha_tempo(current_date - 1, current_date, null, 'admin@exemplo', 500)")["total"] > 0)
check("Limite respeitado e total informado", "2|True", (lambda d: f"{len(d['itens'])}|{d['truncado']}")(J("select auditoria_linha_tempo(current_date - 1, current_date, null, null, 2)")))
recusa("Período maior que 1 ano: recusado", "select auditoria_linha_tempo('2024-01-01','2026-01-01',null,null,10)", ADMIN, "máximo")
recusa("Colaborador não consulta a linha do tempo", "select auditoria_linha_tempo(current_date, current_date, null, null, 10)", COLAB, "Somente")
q("insert into eventos (chave_dedupe, tipo, ocorrido_em, precisao_ocorrido, origem, historico_recuperado, classificacao) values ('t:rec','encaminhamento', now(), 'dia', 'excel_observacoes', true, 'anotado')")
check("Evento recuperado (anterior à implantação) marcado como recuperado", "True",
      any(i["recuperado"] and i["ref"] for i in J("select auditoria_linha_tempo(current_date - 1, current_date, 'responsavel', null, 50)")["itens"]))
I = {i["codigo"]: i for i in J("select auditoria_integridade()")["itens"]}
check("Integridade: banco limpo sem erros", "", ",".join(k for k, v in I.items() if v["gravidade"] == "erro" and v["quantidade"]))
check("Integridade: conferências de segurança presentes (RLS, anônimo, search_path, administrador)", "True",
      {"tabela_sem_rls", "anon_com_acesso", "funcao_sem_search_path", "sem_administrador"} <= set(I))
q("alter table tarefas_analise disable trigger user; insert into tarefas_analise (publicacao_id, requer_cadastro, tipo, responsavel, observacoes, status, teste, busca_advbox) values (null,false,'t','r','o','criada',true,'TESTE 1.0'); alter table tarefas_analise enable trigger user;")
check("Integridade detecta tarefa de análise 'criada' sem ID do ADVBOX", "1", next(i["quantidade"] for i in J("select auditoria_integridade()")["itens"] if i["codigo"] == "analise_criada_sem_id"))
q("alter table tarefas_analise disable trigger user; insert into tarefas_analise (publicacao_id, requer_cadastro, tipo, responsavel, observacoes, status, teste, busca_advbox) select null,false,'t','r','o','criada',true,'TESTE 1.0' from generate_series(1,24); alter table tarefas_analise enable trigger user;")
_i = next(i for i in J("select auditoria_integridade()")["itens"] if i["codigo"] == "analise_criada_sem_id")
check("Integridade: quantidade real (25), exemplos limitados a 20", "25|20", f"{_i['quantidade']}|{len(_i['exemplos'])}")
q("create table public.tabela_esquecida (id int);")
check("Integridade detecta tabela nova sem RLS", "1", next(i["quantidade"] for i in J("select auditoria_integridade()")["itens"] if i["codigo"] == "tabela_sem_rls"))

w = max(len(r[0]) for r in res)
for n, e, o, s in res: print(f"{s:5} {n}" + ("" if s == "OK" else f"\n      esperado={e}\n      obtido  ={o}"))
ok = sum(r[3] == "OK" for r in res); print(f"\n{ok}/{len(res)} OK"); sys.exit(0 if ok == len(res) else 1)
