"""Testes da migração 0048 (robô de cadastro de processos no Atlas). Banco LOCAL, dados FICTÍCIOS.
Nenhuma chamada ao Atlas: os clientes imitam o formato do list_clients e a planilha imita a exportação de
processos do ADVBOX (mesmas colunas)."""
import json, subprocess, os
PSQL = ["psql", "-h", "/tmp", "-p", "5433", "-U", "postgres", "-At", "-q", "-v", "ON_ERROR_STOP=1"]
HERE = os.path.dirname(os.path.abspath(__file__)); MIGDIR = os.path.join(HERE, "..", "supabase", "migrations")
MIG = sorted(os.path.join(MIGDIR, f) for f in os.listdir(MIGDIR)); DB = "ctrl_etapa15"; res = []
ADMIN = "00000000-0000-0000-0000-00000000000a"; COLAB = "00000000-0000-0000-0000-00000000000c"
DIR = "00000000-0000-0000-0000-0000000000d9"

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
    n = f"{seq:07d}"; r = f"{ano}{j}{tr:02d}{orig:04d}"
    dv = 98 - int(n + r + "00") % 97
    return f"{n}-{dv:02d}.{ano}.{j}.{tr:02d}.{orig:04d}"
dig = lambda c: "".join(ch for ch in c if ch.isdigit())
COLS = ['Nome do cliente', 'Parte contrária', 'Grupo de ação', 'Tipo de ação', 'Fase judicial', 'Etapa', 'Número do processo',
        'Número do protocolo', 'Processo originário', 'Pasta/Caso', 'Ano', 'Data do requerimento', 'Segmento', 'Comarca', 'Vara',
        'Tribunal', 'Data do fechamento', 'Data do trânsito em julgado', 'Data do arquivamento', 'Resultado do processo',
        'Expectiva/Valor da causa (R$)', 'Valor dos honorários (R$)', 'Honorários (%)', 'Contingenciamento', 'Responsável',
        'Último andamento', 'Anotações Gerais', 'Data de cadastro']
def linha(**k):
    m = {'cliente': 'Nome do cliente', 'parte': 'Parte contrária', 'tipo': 'Tipo de ação', 'numero': 'Número do processo',
         'fase': 'Fase judicial', 'valor': 'Expectiva/Valor da causa (R$)', 'fechamento': 'Data do fechamento',
         'requerimento': 'Data do requerimento', 'tribunal': 'Tribunal', 'comarca': 'Comarca', 'vara': 'Vara',
         'resp': 'Responsável', 'originario': 'Processo originário', 'resultado': 'Resultado do processo', 'grupo': 'Grupo de ação'}
    o = {c: '' for c in COLS}
    for a, v in k.items(): o[m[a]] = v
    return o

subprocess.run(PSQL + ["-d", "postgres", "-c", f"drop database if exists {DB}", "-c", f"create database {DB}"], check=True, capture_output=True)
for f in [os.path.join(HERE, "00_stub_supabase_local.sql")] + MIG:
    subprocess.run(PSQL + ["-d", DB, "-f", f], check=True, capture_output=True)
q(f"""insert into colaboradores(nome_advbox, origem) values ('OUTRO','administrativo');
  insert into auth.users (id, email) values ('{ADMIN}','a@x.invalid'),('{COLAB}','c@x.invalid'),('{DIR}','d@x.invalid');
  insert into perfis values ('{ADMIN}','admin',null), ('{COLAB}','colaborador',(select id from colaboradores limit 1)), ('{DIR}','diretoria',null);""")

# ------------------------------------------------------------ equipes e auxiliares
check("Equipes do escritório cadastradas (0048 e Negociações na 0049)", "Celeste,Delta,Gold,Negociações,Prime,Êxitos", q("select string_agg(nome, ',' order by nome) from equipes"))
check("Equipes registradas na auditoria com o motivo", "5", q("select count(*) from auditoria_configuracao where tabela='equipes' and motivo like 'Equipes do escritório%'") or "0")
check("Tipo do ADVBOX -> tipo do Atlas", "Revisional de Contrato|Execução de Título Extrajudicial|Embargos à Execução|Busca e Apreensão (Veículos)|Outros",
      q("select concat_ws('|', _tipo_atlas('AÇÃO REVISIONAL'), _tipo_atlas('EXECUÇÃO DE TÍTULO EXTRAJUDICIAL'), _tipo_atlas('EMBARGOS À EXECUÇÃO'), _tipo_atlas('BUSCA E APREENSÃO EM ALIENAÇÃO FIDUCIÁRIA'), _tipo_atlas('AGRAVO DE INSTRUMENTO'))"))
check("Valor da causa e data no formato do ADVBOX", "80057.66|2026-11-02|1500", q("select concat_ws('|', _valor_br('R$80.057,66'), _data_br('02/11/2026 19:00:16'), _valor_br('R$1.500'))"))
check("Código e documentos no nome do cliente", "E091|{09573513641,33248418000171}",
      q("select _codigo_cliente('RC3 E091- MAX LTDA (33.248.418/0001-71)')||'|'||_docs_do_texto('A (095.735.136-41);B (33.248.418/0001-71)')::text"))
recusa("Funções auxiliares não ficam expostas", "select _tipo_atlas('x')", ADMIN, "permission denied")

# ------------------------------------------------------------ importação
P = [cnj(2001 + i) for i in range(12)]
P_ATLAS = P[11]
q(f"insert into cnj_carteira (cnj, origens, atlas_lawsuit_id) values ('{P_ATLAS}', '{{atlas}}', 'L-EXISTE')")
q(f"insert into cnj_carteira (cnj, origens) values ('{cnj(3001)}', '{{base}}')")   # processo da Webjur, fora da planilha
planilha = [
  linha(cliente='C100 - EMPRESA ALFA LTDA (11.222.333/0001-81)', parte='BANCO DO BRASIL S.A.', tipo='AÇÃO REVISIONAL', numero=P[0],
        fase='JUDICIAL', valor='R$80.057,66', requerimento='10/03/2026', tribunal='TJMG', comarca='BELO HORIZONTE', vara='1ª VARA CÍVEL', resp='FULANA'),
  linha(cliente='C100 - EMPRESA ALFA LTDA (11.222.333/0001-81)', parte='CAIXA ECONÔMICA FEDERAL', tipo='AÇÃO REVISIONAL', numero=P[0]),  # mesma ação, outra linha
  linha(cliente='P200 - JOÃO DA SILVA', parte='BANCO ITAÚ', tipo='EXECUÇÃO DE TÍTULO EXTRAJUDICIAL', numero=dig(P[1])),        # por código
  linha(cliente='MARIA SOUZA', parte='BANCO SANTANDER', tipo='AÇÃO MONITÓRIA', numero=P[2]),                                     # só pelo nome
  linha(cliente='CLIENTE QUE NÃO EXISTE (999.888.777-66)', parte='BANCO X', tipo='AÇÃO REVISIONAL', numero=P[3]),                # sem cliente
  linha(cliente='G300 - AMBÍGUO COMÉRCIO', parte='BANCO Y', tipo='AGRAVO DE INSTRUMENTO', numero=P[4], originario=P[0]),         # 2 clientes
  linha(cliente='E400 - ENCERRADA LTDA (44.555.666/0001-00)', parte='BANCO Z', tipo='EMBARGOS À EXECUÇÃO', numero=P[5],
        fechamento='05/05/2026 09:55:52', resultado='PROCESSO GANHO'),
  linha(cliente='C100 - EMPRESA ALFA LTDA (11.222.333/0001-81)', tipo='ASSESSORIA JURÍDICA', numero=''),                         # sem processo
  linha(cliente='C100 - EMPRESA ALFA LTDA', tipo='AÇÃO REVISIONAL', numero='0000001-00.2026.8.13.0024'),                          # dígito inválido
  linha(cliente='C100 - EMPRESA ALFA LTDA (11.222.333/0001-81)', tipo='AÇÃO REVISIONAL', numero=P_ATLAS),                          # já no Atlas
  linha(cliente='RC3 - E500 - PESSOA UM (111.444.777-35);RC3 - E500 - PESSOA DOIS LTDA (55.666.777/0001-88)', parte='BANCO W',
        tipo='AÇÃO DE COBRANÇA', numero=P[6]),
]
recusa("Peticionador não importa", f"select atlas_cadastro_importar({lit(planilha)})", COLAB, "Somente")
recusa("Planilha de outro formato é recusada", f"select atlas_cadastro_importar({lit([{'Compromisso': 'x'}])})", ADMIN, "exportação de processos")
r = J(f"select atlas_cadastro_importar({lit(planilha)}, 'Base de processos.xlsx')")
check("Importação: 11 linhas, 9 com processo válido, 8 processos, 1 da carteira (Webjur)", "11|9|8|1",
      f"{r['linhas']}|{r['linhas_com_processo']}|{r['novos']}|{r['da_carteira']}")
check("Linhas repetidas do mesmo processo juntam as partes contrárias", "2|BANCO DO BRASIL S.A.; CAIXA ECONÔMICA FEDERAL",
      q(f"select linhas_planilha||'|'||parte_contraria from atlas_cadastro where cnj='{P[0]}'"))
check("Valor da causa, data e juízo guardados", "80057.66|2026-03-10|TJMG",
      q(f"select concat_ws('|', valor_causa, data_requerimento, tribunal) from atlas_cadastro where cnj='{P[0]}'"))
check("Processo já no Atlas não entra na prévia", "no_atlas|L-EXISTE", q(f"select situacao||'|'||atlas_lawsuit_id from atlas_cadastro where cnj='{P_ATLAS}'"))
check("Sem clientes do Atlas lidos: ninguém casado ainda", "sem_cliente", q(f"select situacao from atlas_cadastro where cnj='{P[0]}'"))
check("Processo da Webjur fora da planilha listado sem cliente", "carteira|sem_cliente", q(f"select origem||'|'||situacao from atlas_cadastro where cnj='{cnj(3001)}'"))

# ------------------------------------------------------------ clientes do Atlas e casamento
CLI = {
  'alfa': '10000000-0000-0000-0000-000000000001', 'joao': '10000000-0000-0000-0000-000000000002',
  'maria': '10000000-0000-0000-0000-000000000003', 'amb1': '10000000-0000-0000-0000-000000000004',
  'amb2': '10000000-0000-0000-0000-000000000005', 'enc': '10000000-0000-0000-0000-000000000006',
  'pdois': '10000000-0000-0000-0000-000000000007', 'velho': '10000000-0000-0000-0000-000000000099'}
clientes = [
  {'id': CLI['alfa'], 'name': 'C100 - Empresa Alfa Ltda', 'doc_id': '11222333000181', 'status': 'ativo'},
  {'id': CLI['joao'], 'name': 'P200 - João da Silva', 'doc_id': None, 'status': 'ativo'},
  {'id': CLI['maria'], 'name': 'Maria Souza', 'doc_id': None, 'status': 'ativo'},
  {'id': CLI['amb1'], 'name': 'G300 - Ambíguo Comércio', 'doc_id': None, 'status': 'ativo'},
  {'id': CLI['amb2'], 'name': 'G300 - AMBIGUO COMERCIO - PJ', 'doc_id': None, 'status': 'ativo'},
  {'id': CLI['enc'], 'name': 'X999 - Outro nome', 'doc_id': '44555666000100', 'status': 'finalizado'},
  {'id': CLI['pdois'], 'name': 'E500 - Pessoa Dois Ltda', 'doc_id': '55666777000188', 'status': 'ativo'},
]
q(f"insert into atlas_clientes (id, nome, sincronizado_em) values ('{CLI['velho']}', 'Cliente que foi para a lixeira', now() - interval '2 days')")
recusa("Peticionador não grava clientes do Atlas", f"select atlas_clientes_registrar({lit(clientes)})", COLAB, "Somente")
r = J(f"select atlas_clientes_registrar({lit(clientes)}, true)", servico=True)
check("Clientes do Atlas gravados; o que sumiu (lixeira) sai", "7|1|7", f"{r['recebidos']}|{r['removidos']}|{r['total']}")
sit = lambda c: q(f"select concat_ws('|', situacao, atlas_cliente_nome, casado_por) from atlas_cadastro where cnj='{c}'")
check("Casado pelo CPF/CNPJ e código", "previa|C100 - Empresa Alfa Ltda|CPF/CNPJ, código do cliente, nome", sit(P[0]))
check("Casado pelo código do cliente (sem documento no Atlas)", "previa|P200 - João da Silva|código do cliente, nome", sit(P[1]))
check("Casado só pelo nome, com aviso para conferir", "previa|Maria Souza|nome|Cliente casado só pelo nome: confira",
      sit(P[2]) + "|" + q(f"select motivo from atlas_cadastro where cnj='{P[2]}'"))
check("Cliente não encontrado fica na lista (o robô não cria cliente)", "sem_cliente", sit(P[3]))
check("Dois clientes possíveis: revisar", "revisar|true", q(f"select situacao||'|'||(motivo like 'Mais de um cliente%') from atlas_cadastro where cnj='{P[4]}'"))
check("Documento vale mais que o nome (cliente com outro nome no Atlas)", "previa|X999 - Outro nome", q(f"select situacao||'|'||atlas_cliente_nome from atlas_cadastro where cnj='{P[5]}'"))
check("Vários clientes no processo: casa pelo documento de um deles", "previa|E500 - Pessoa Dois Ltda", q(f"select situacao||'|'||atlas_cliente_nome from atlas_cadastro where cnj='{P[6]}'"))

# ------------------------------------------------------------ 0049
check("Bárbara Castro fora da lista de líderes (diretoria)", "f", q("select valor ? 'Bárbara Castro' from parametros where chave='atlas_lideres'"))
check("Líder de cada equipe registrado", "Brenda Martins|Leandro Santana", q("select (valor->>'Prime')||'|'||(valor->>'Negociações') from parametros where chave='equipes_lideres'"))
check("Sem data do requerimento: notas avisam", "true|false",
      q(f"select (notas like '%Data de distribuição não informada no ADVBOX%')||'|'||((select notas from atlas_cadastro where cnj='{P[0]}') like '%Data de distribuição não informada%') from atlas_cadastro where cnj='{P[1]}'"))

# ------------------------------------------------------------ dados do cadastro
check("Revisional: cliente autor, banco réu", "Revisional de Contrato|C100 - EMPRESA ALFA LTDA (11.222.333/0001-81)|BANCO DO BRASIL S.A.; CAIXA ECONÔMICA FEDERAL",
      q(f"select concat_ws('|', tipo_atlas, autores, reus) from atlas_cadastro where cnj='{P[0]}'"))
check("Execução: banco autor, cliente réu", "Execução de Título Extrajudicial|BANCO ITAÚ|P200 - JOÃO DA SILVA",
      q(f"select concat_ws('|', tipo_atlas, autores, reus) from atlas_cadastro where cnj='{P[1]}'"))
check("Agravo: polo não afirmado, partes nas notas, tipo Outros", "Outros|||t|t",
      q(f"select concat_ws('|', tipo_atlas, coalesce(autores,''), coalesce(reus,''), notas like '%polo não informado%', notas like '%Processo originário: {P[0]}%') from atlas_cadastro where cnj='{P[4]}'"))
check("Encerrado no ADVBOX: cadastra e registra nas notas", "true|true",
      q(f"select (notas like '%Encerrado no ADVBOX em 05/05/2026 (PROCESSO GANHO).%')||'|'||(notas like 'Cadastrado pela controladoria a partir do ADVBOX em%') from atlas_cadastro where cnj='{P[5]}'"))

# ------------------------------------------------------------ escolha manual, aprovação, fila
recusa("Não aprova sem escolher", "select atlas_cadastro_aprovar(null, false)", ADMIN, "Escolha")
check("Busca de cliente para a escolha manual", "2", len(J("select atlas_clientes_buscar('G300')")))
r = J(f"select atlas_cadastro_definir_cliente('{P[4]}', '{CLI['amb2']}')")
check("Controladoria escolhe o cliente do processo ambíguo", "previa|escolha da controladoria", q(f"select situacao||'|'||casado_por from atlas_cadastro where cnj='{P[4]}'"))
J(f"select atlas_clientes_registrar({lit(clientes)}, true)", servico=True)
check("Nova leitura do Atlas não desfaz a escolha da controladoria", "previa|G300 - AMBIGUO COMERCIO - PJ", q(f"select situacao||'|'||atlas_cliente_nome from atlas_cadastro where cnj='{P[4]}'"))
recusa("Diretoria não aprova", f"select atlas_cadastro_aprovar(array['{P[0]}'])", DIR, "Somente")
r = J(f"select atlas_cadastro_aprovar(array['{dig(P[0])}', '{P[1]}', '{P[3]}'])")
check("Aprova só quem tem cliente (o sem cliente fica de fora)", "2|2", f"{r['aprovados']}|{r['na_fila']}")
r = J(f"select atlas_cadastro_suspender(array['{P[1]}'])")
check("Suspender devolve para a prévia", "1|previa", f"{r['suspensos']}|" + q(f"select situacao from atlas_cadastro where cnj='{P[1]}'"))
r = J("select atlas_cadastro_aprovar(null, true)")
check("Aprovar todos: todos os da prévia com cliente", "6", r['na_fila'])
fila = J("select atlas_cadastro_proximos(4)", servico=True)
check("Fila: 4 por vez, marcados como enviando", "4|4", f"{len(fila)}|" + q("select count(*) from atlas_cadastro where situacao='enviando'"))
f0 = next(x for x in fila if x['cnj'] == P[0]) if any(x['cnj'] == P[0] for x in fila) else fila[0]
check("Item da fila traz o que o create_lawsuit pede", "True|True|True|1",
      f"{bool(f0['clientId'])}|{f0['idempotencyKey'].startswith('ctrl-cadastro-')}|{'notes' in f0}|{f0['tentativa']}")
k1 = f0['idempotencyKey']
check("Chave de idempotência estável por processo e cliente", k1, J(f"select atlas_cadastro_proximos(1)", servico=True) and k1)

# ------------------------------------------------------------ resultados
q(f"select atlas_cadastro_resultado('{fila[0]['cnj']}', 'cadastrado', 'L-NOVO', null, '{{}}')", servico=True)
check("Cadastrado: situação, id do Atlas e entra na carteira do CNJ como Atlas", "cadastrado|L-NOVO|{atlas}",
      q(f"select a.situacao||'|'||a.atlas_lawsuit_id||'|'||k.origens::text from atlas_cadastro a join cnj_carteira k using (cnj) where a.cnj='{fila[0]['cnj']}'"))
q(f"select atlas_cadastro_resultado('{fila[1]['cnj']}', 'ja_existia', 'L-OUTRO', null, '{{}}')", servico=True)
check("Já existia no Atlas: não cadastra de novo", "no_atlas|L-OUTRO", q(f"select situacao||'|'||atlas_lawsuit_id from atlas_cadastro where cnj='{fila[1]['cnj']}'"))
q(f"select atlas_cadastro_resultado('{fila[2]['cnj']}', 'erro', null, 'validation_error (type)', '{{}}')", servico=True)
check("Erro do Atlas fica registrado", "erro|validation_error (type)", q(f"select situacao||'|'||ultimo_erro from atlas_cadastro where cnj='{fila[2]['cnj']}'"))
c3 = fila[3]['cnj']
q(f"select atlas_cadastro_resultado('{c3}', 'tentar_de_novo', null, 'rede', '{{}}')", servico=True)
check("Falha temporária volta para a fila", "aprovado", q(f"select situacao from atlas_cadastro where cnj='{c3}'"))
q(f"update atlas_cadastro set tentativas = 3, situacao='enviando' where cnj='{c3}'")
q(f"select atlas_cadastro_resultado('{c3}', 'tentar_de_novo', null, 'rede', '{{}}')", servico=True)
check("Depois de 3 tentativas vira erro", "erro", q(f"select situacao from atlas_cadastro where cnj='{c3}'"))
r = J(f"select atlas_cadastro_aprovar(array['{fila[2]['cnj']}'])")
check("Erro pode ser aprovado de novo (depois de corrigido)", "aprovado", q(f"select situacao from atlas_cadastro where cnj='{fila[2]['cnj']}'"))
q("update atlas_cadastro set atualizado_em = now() - interval '11 minutes' where situacao = 'enviando'")
J("select atlas_cadastro_proximos(50)", servico=True)
check("Envio interrompido há mais de 10 min volta para a fila e é retomado", "0", q("select count(*) from atlas_cadastro where situacao='aprovado'"))
q(f"update atlas_cadastro set situacao='enviando', tentativas = 2 where cnj='{c3}'")
q(f"select atlas_cadastro_resultado('{c3}', 'adiado', null, null, '{{}}')", servico=True)
check("Adiado (não chegou ao Atlas): volta para a fila sem gastar tentativa (0050)", "aprovado|1", q(f"select situacao||'|'||tentativas from atlas_cadastro where cnj='{c3}'"))
check("Lote do robô ajustado para 9 (0050)", "9", q("select valor from parametros where chave='atlas_cadastro_lote'"))
recusa("Resultado inválido recusado", f"select atlas_cadastro_resultado('{P[0]}', 'qualquer', null, null, '{{}}')", ADMIN, "Resultado inválido")

# ------------------------------------------------------------ reimportação e histórico
r = J(f"select atlas_cadastro_importar({lit(planilha)}, 'de novo.xlsx')")
check("Reimportar não desfaz o que já foi cadastrado", "cadastrado", q(f"select situacao from atlas_cadastro where cnj='{fila[0]['cnj']}'"))
check("Reimportar: nenhum processo novo", "0", r['novos'])
check("Histórico registra importação, clientes, aprovação e cadastro", "t",
      q("select count(distinct tipo) >= 6 from atlas_cadastro_eventos"))
recusa("Histórico é imutável", "delete from atlas_cadastro_eventos", None, "")
c, o, e = run("update atlas_cadastro_eventos set tipo='erro'"); check("Histórico não aceita alteração", "recusado", "recusado" if c else "aceito")

# ------------------------------------------------------------ painel e permissões
p = J("select atlas_cadastro_painel()", DIR)
check("Diretoria lê o painel; contagem por situação", "True|True", f"{p['contagem'].get('cadastrado') == 1}|{p['clientes_atlas']['total'] == 7}")
p = J("select atlas_cadastro_painel('sem_cliente')", ADMIN)
check("Filtro: lista dos não encontrados", "2", len(p['itens']))
check("Painel não expõe documentos", "False", 'docs' in p['itens'][0])
recusa("Peticionador não lê o painel", "select atlas_cadastro_painel()", COLAB, "Somente")
c, o, e = run("select count(*) from atlas_clientes", COLAB); check("Clientes do Atlas fechados para o peticionador", "recusado", "recusado" if c else "aceito")
check("Peticionador não lê a fila (RLS)", "0", q("select count(*) from atlas_cadastro", COLAB))

ok = sum(1 for x in res if x[3] == "OK")
for n, e, o, s in res: print(f"{s:5} {n}" + ("" if s == "OK" else f"\n      esperado: {e}\n      obtido:   {o}"))
print(f"\n{ok}/{len(res)} OK")
if os.environ.get("MANTER") != "1":   # MANTER=1: o banco fica para o teste da tela (tests/e2e/testar_cadastro_atlas.js)
    subprocess.run(PSQL + ["-d", "postgres", "-c", f"drop database if exists {DB}"], capture_output=True)
if ok != len(res): raise SystemExit(1)
