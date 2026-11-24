"""Testes da migração 0044 (intimações do CNJ / DJEN e double check CNJ × Webjur). Banco LOCAL, dados FICTÍCIOS.
Nenhuma chamada à API do CNJ nem ao Atlas: os itens imitam o formato devolvido pela API pública de comunicações."""
import json, subprocess, os
PSQL = ["psql", "-h", "/tmp", "-p", "5433", "-U", "postgres", "-At", "-q", "-v", "ON_ERROR_STOP=1"]
HERE = os.path.dirname(os.path.abspath(__file__)); MIGDIR = os.path.join(HERE, "..", "supabase", "migrations")
MIG = sorted(os.path.join(MIGDIR, f) for f in os.listdir(MIGDIR)); DB = "ctrl_etapa14"; res = []
ADMIN = "00000000-0000-0000-0000-00000000000a"; COLAB = "00000000-0000-0000-0000-00000000000c"
DIR = "00000000-0000-0000-0000-0000000000d9"; SEM = "00000000-0000-0000-0000-0000000000ff"

def run(sql, uid=None, servico=False):
    pre = f"set role authenticated; set request.jwt.claim.sub = '{uid}';\n" if uid else ""
    if servico: pre = "set request.jwt.claims = '{\"role\":\"service_role\"}';\n"
    p = subprocess.run(PSQL + ["-d", DB], input=pre + sql, capture_output=True, text=True)
    return p.returncode, p.stdout.strip(), p.stderr.strip()
def q(sql, uid=None, servico=False):
    c, o, e = run(sql, uid, servico)
    if c: raise RuntimeError(sql[:300] + "\n" + e)
    return o
J = lambda sql, uid=ADMIN, servico=False: json.loads(q(sql, uid, servico))
def check(n, e, o): res.append((n, str(e), str(o), "OK" if str(e) == str(o) else "FALHA"))
def recusa(n, sql, uid, trecho):
    c, o, e = run(sql, uid); check(n, f"recusado ({trecho})", f"recusado ({trecho})" if c and trecho in e else f"aceito/outro: {e[:200]}")
lit = lambda o: "$J$" + json.dumps(o, ensure_ascii=False) + "$J$::jsonb"

def cnj(seq, ano=2026, j=8, tr=13, orig=24):
    """Número CNJ fictício com dígito verificador correto (mod 97-10)."""
    n = f"{seq:07d}"; r = f"{ano}{j}{tr:02d}{orig:04d}"
    dv = 98 - int(n + r + "00") % 97
    return f"{n}-{dv:02d}.{ano}.{j}.{tr:02d}.{orig:04d}"
dig = lambda c: "".join(ch for ch in c if ch.isdigit())

subprocess.run(PSQL + ["-d", "postgres", "-c", f"drop database if exists {DB}", "-c", f"create database {DB}"], check=True, capture_output=True)
for f in [os.path.join(HERE, "00_stub_supabase_local.sql")] + MIG:
    subprocess.run(PSQL + ["-d", DB, "-f", f], check=True, capture_output=True)
q(f"""insert into colaboradores(nome_advbox, origem) values ('OUTRO','administrativo');
  insert into auth.users (id, email) values ('{ADMIN}','a@x.invalid'),('{COLAB}','c@x.invalid'),('{DIR}','d@x.invalid'),('{SEM}','s@x.invalid');
  insert into perfis values ('{ADMIN}','admin',null), ('{COLAB}','colaborador',(select id from colaboradores limit 1)), ('{DIR}','diretoria',null);""")
HOJE = q("select hoje_brasilia()"); ONTEM = q("select hoje_brasilia() - 1"); ANTE = q("select hoje_brasilia() - 2")
P1, P2, P3, P4 = cnj(1001), cnj(1002), cnj(1003), cnj(1004)
q(f"insert into processos (cnj, cnj_digito_valido, origem) values ('{P4}', true, 'webjur')")   # processo já conhecido (base)

# ------------------------------------------------------------ parâmetros e acesso
check("Parâmetro cnj_oabs disponível à função", '["176787/MG"]', q("select cnj_parametro('cnj_oabs')", ADMIN))
recusa("cnj_parametro não lê parâmetros de outros módulos", "select cnj_parametro('atlas_lideres')", ADMIN, "não disponível")
recusa("Peticionador não usa as funções da captura", "select cnj_conferir_acesso()", COLAB, "Somente")
check("Chave de serviço (agendamento) usa as funções da captura", "t", q("select cnj_conferir_acesso()", servico=True))
check("Módulo de intimações do Atlas ligado desde 16/11/2026 (0054)", "true", q("select valor from parametros where chave='atlas_modulo_intimacoes'"))
q("update parametros set valor = 'false'::jsonb where chave = 'atlas_modulo_intimacoes'")   # esta suíte cobre o cenário SEM o módulo (12–15/11)

# ------------------------------------------------------------ carteira
r = J(f"select cnj_carteira_registrar({lit([{'cnj': dig(P1), 'lawsuit_id': 'L1', 'cliente': 'Banco X'}, {'cnj': P2}, {'cnj': '0001234-00.2026.8.13.0024'}, {'cnj': 'lixo'}])}, 'atlas')")
check("Carteira: 2 processos válidos do Atlas + 1 da base (inválidos fora)", "3|3", f"{r['novos']}|{r['carteira']}")
check("Carteira guarda o CNJ normalizado e a origem", f"{P1}|{{atlas}}|L1", q(f"select cnj||'|'||origens::text||'|'||atlas_lawsuit_id from cnj_carteira where cnj='{P1}'"))
check("Processo da base entra com origem base", "{base}", q(f"select origens from cnj_carteira where cnj='{P4}'"))
J(f"select cnj_carteira_registrar({lit([{'cnj': P4}])}, 'atlas')")
check("Mesmo processo nas duas fontes: origens juntas", "{atlas,base}", q(f"select origens from cnj_carteira where cnj='{P4}'"))
recusa("Origem da carteira validada", "select cnj_carteira_registrar('[]'::jsonb, 'outra')", ADMIN, "Origem inválida")

# ------------------------------------------------------------ fila da varredura
fila = q("select string_agg(c, ',' order by c) from cnj_proximos(10) c", ADMIN).split(",")
check("Fila do dia: os 3 processos", "3", len(fila))
q(f"select cnj_marcar('{dig(P1)}', true, 2, null)", ADMIN)
q(f"select cnj_marcar('{P2}', false, null, 'HTTP 500: O sistema está muito ocupado')", ADMIN)
check("Consultado hoje sai da fila; falha recente espera 20 min", P4, q("select string_agg(c, ',') from cnj_proximos(10) c", ADMIN))
check("Falha registrada com o erro", "1|HTTP 500: O sistema está muito ocupado", q(f"select falhas_seguidas||'|'||ultimo_erro from cnj_carteira where cnj='{P2}'"))
q(f"update cnj_carteira set ultima_tentativa = now() - interval '30 minutes' where cnj='{P2}'")
check("Depois de 20 min a falha volta à fila, depois dos que nunca falharam", f"{P4},{P2}",
      q("select string_agg(c, ',') from cnj_proximos(10) c", ADMIN))
q(f"select cnj_marcar('{P2}', true, 0, null)", ADMIN)
check("Sucesso zera as falhas", "0|", q(f"select falhas_seguidas||'|'||coalesce(ultimo_erro,'') from cnj_carteira where cnj='{P2}'"))

# ------------------------------------------------------------ comunicações (formato da API pública do CNJ)
def com(i, proc, data, tipo="Intimação", tribunal="TJMG"):
    return {"id": i, "hash": f"h{i}", "numero_processo": dig(proc), "numeroprocessocommascara": proc, "siglaTribunal": tribunal,
            "tipoComunicacao": tipo, "tipoDocumento": "Despacho", "nomeOrgao": "1ª Vara Cível", "nomeClasse": "Procedimento Comum",
            "data_disponibilizacao": data, "texto": f"Intimação fictícia {i} no processo {proc}", "link": f"https://exemplo.invalid/{i}",
            "meiocompleto": "Diário de Justiça Eletrônico Nacional", "destinatarios": [{"nome": "PARTE"}],
            "destinatarioadvogados": [{"advogado": {"numero_oab": "176787", "uf_oab": "MG"}}], "ativo": True, "status": "P"}
itens = [com(900001, P1, ONTEM), com(900002, P2, ONTEM), com(900003, P3, ANTE, "Lista de distribuição"), com(900004, P1, HOJE)]
r = J(f"select cnj_registrar({lit(itens)}, 'oab:176787/MG')")
check("Comunicações registradas", "4|4", f"{r['recebidas']}|{r['novas']}")
r = J(f"select cnj_registrar({lit(itens[:2])}, 'processo')")
check("Repetida não duplica e soma a origem da captura", "2|0|{oab:176787/MG,processo}",
      f"{r['recebidas']}|{r['novas']}|{q('select encontrada_por from cnj_comunicacoes where id=900001')}")
check("CNJ normalizado na comunicação", P1, q("select cnj from cnj_comunicacoes where id=900001"))
recusa("Peticionador não grava comunicações", f"select cnj_registrar({lit(itens[:1])}, 'oab')", COLAB, "Somente")

# ------------------------------------------------------------ publicações Webjur fictícias
def pub(i, proc, data, id_doc, local="DJEN - Diário de Justiça Eletrônico Nacional - TJMG - 1ª Vara Cível"):
    q(f"""insert into publicacoes (cnj, cnj_digito_valido, data_disponibilizacao, tribunal, teor, teor_hash, conteudo_original, chave_dedupe, id_documento)
          values ('{proc}', true, '{data}', 'TJMG', 'teor fictício {i}', md5('{i}'), {lit({'local': local})}, 'pub-{i}', {f"'{id_doc}'" if id_doc else 'null'})""")
pub(1, P1, ONTEM, "900001")                     # mesma comunicação do CNJ (identificador exato)
pub(2, P4, ANTE, "800777")                      # DJEN na Webjur, mas o CNJ não mostra (processo já varrido)
pub(3, P3, ANTE, None, "FBH BELO HORIZONTE")    # diário estadual próprio: não está no CNJ (não cobra)

p = J("select cnj_painel(null, null, null, null, 100)", DIR)
por_id = {x["id"]: x for x in p["itens"]}
check("Painel (diretoria lê): comunicações do período", "4", len(p["itens"]))
check("Painel liga CNJ e Webjur pelo identificador exato", "True", por_id[900001]["webjur"] and por_id[900001]["webjur"]["exata"])
check("Painel aponta comunicação sem Webjur", "None", por_id[900002]["webjur"])
check("Filtro 'sem Webjur' (a 900004 não herda a Webjur da 900001, que já tem dona)", "900002,900004", ",".join(str(x["id"]) for x in sorted(J("select cnj_painel(null,null,null,'sem_webjur',100)", DIR)["itens"], key=lambda x: x["id"])))
check("Busca por processo", "2", len(J(f"select cnj_painel(null,null,'{P1}',null,100)", DIR)["itens"]))
check("Resumo da carteira", "3|3", f"{p['carteira']['total']}|{p['carteira']['do_atlas']}")
recusa("Peticionador não abre o painel do CNJ", "select cnj_painel()", COLAB, "Somente")

# ------------------------------------------------------------ execuções
q("select cnj_execucao_registrar('oab', '{\"consultas\":1,\"sucesso\":1,\"comunicacoes\":4,\"novas\":4}'::jsonb)", servico=True)
check("Execução registrada", "oab|4", q("select tipo||'|'||novas from cnj_execucoes order by id desc limit 1"))
c, o, e = run("update cnj_execucoes set novas = 0")
check("Histórico de execuções é imutável", "recusado", "recusado" if c else "aceito")

# ------------------------------------------------------------ double check com o CNJ
q(f"update cnj_carteira set ultima_consulta = case when cnj = '{P2}' then null else now() end")
r = J("select double_check_atlas_executar(null, 'manual')", ADMIN)
inc = {k: v for k, v in [l.split("=") for l in q("select chave||'='||tipo||':'||gravidade from inconsistencias where situacao='aberta'").splitlines()]}
check("CNJ × Webjur: intimação de ontem não capturada pela Webjur", "captura_divergente:2", inc.get("cnj_sem_webjur|900002"))
check("Comunicação capturada pela Webjur (mesmo identificador) não aparece", "None", inc.get("cnj_sem_webjur|900001"))
check("Lista de distribuição não é cobrada", "None", inc.get("cnj_sem_webjur|900003"))
check("Comunicação de hoje ainda não é cobrada (Webjur entrega no dia seguinte)", "None", inc.get("cnj_sem_webjur|900004"))
pid2 = q("select id from publicacoes where chave_dedupe='pub-2'")
check("Webjur (DJEN) sem a comunicação no CNJ, processo já varrido", "captura_divergente:3", inc.get(f"webjur_sem_cnj|{pid2}"))
pid3 = q("select id from publicacoes where chave_dedupe='pub-3'")
check("Diário estadual próprio (fora do DJEN) não é cobrado no CNJ", "None", inc.get(f"webjur_sem_cnj|{pid3}"))
check("Varredura incompleta vira pendência", "pendencia_controladoria:2", inc.get(f"cnj_varredura|{HOJE}"))
check("Consulta por OAB de hoje: sem pendência", "None", inc.get(f"cnj_oab|{HOJE}"))
check("Sem o módulo do Atlas, não cobra sincronização de intimações do Atlas", "None", inc.get(f"atlas_sem_sync|{HOJE}"))
q(f"select cnj_registrar({lit([com(800777, P4, ANTE)])}, 'processo')", ADMIN)
q("update cnj_carteira set ultima_consulta = now()")
J("select double_check_atlas_executar(null, 'manual')", ADMIN)
check("Regularizadas sozinhas: Webjur achada no CNJ e varredura completa", "regularizada|regularizada",
      q(f"select string_agg(situacao, '|' order by chave) from inconsistencias where chave in ('webjur_sem_cnj|{pid2}','cnj_varredura|{HOJE}')"))
check("Sem o módulo do Atlas, as publicações da Webjur continuam conferidas (0046)", "3", r["publicacoes_conferidas"])
check("Sem o módulo do Atlas, não compara com intimações do Atlas inexistentes", "0",
      q("select count(*) from inconsistencias where tipo='intimacao_nao_cadastrada'"))
# 0047: mesmo texto, processo e data, mas identificadores diferentes = comunicações distintas (não é duplicada)
q(f"""insert into publicacoes (cnj, cnj_digito_valido, data_disponibilizacao, tribunal, teor, teor_hash, conteudo_original, chave_dedupe, id_documento)
      values ('{P2}', true, '{ANTE}', 'TJMG', 'texto igual para duas partes', md5('a'), '{{}}'::jsonb, 'dup-a', '700001'),
             ('{P2}', true, '{ANTE}', 'TJMG', 'texto igual para duas partes', md5('b'), '{{}}'::jsonb, 'dup-b', '700002'),
             ('{P2}', true, '{ANTE}', 'TJMG', 'texto igual sem identificador', md5('c'), '{{}}'::jsonb, 'dup-c', null),
             ('{P2}', true, '{ANTE}', 'TJMG', 'texto igual sem identificador', md5('d'), '{{}}'::jsonb, 'dup-d', null)""")
J("select double_check_atlas_executar(null, 'manual')", ADMIN)
dup = lambda ch: q(f"select count(*) from inconsistencias where tipo='publicacao_duplicada' and publicacao_id=(select id from publicacoes where chave_dedupe='{ch}')")
check("Identificadores diferentes: não é duplicada (0047)", "0", dup("dup-b"))
check("Sem identificador e mesmo texto: continua duplicada", "1", dup("dup-d"))
check("Double check roda pela chave de serviço (rotina das 18:30)", "t",
      q("select (double_check_atlas_executar(null, 'automatico')->>'dia') is not null", servico=True))

ok = sum(1 for r in res if r[3] == "OK")
for n, e, o, s in res: print(f"{s:5} {n}" + ("" if s == "OK" else f"\n      esperado: {e}\n      obtido:   {o}"))
print(f"\n{ok}/{len(res)} verificações OK")
# o banco fica para o teste da tela (tests/e2e/testar_cnj.js)
if ok != len(res): raise SystemExit(1)
