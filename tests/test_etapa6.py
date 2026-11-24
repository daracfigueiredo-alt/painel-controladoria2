"""Testes da Etapa 6 (0013) no banco: registro de remessas do e-mail Webjur, identificação
das publicações (identificador do documento x conteúdo), completude, auditoria e acesso.
Banco LOCAL, e-mails FICTÍCIOS (tests/webjur/fixtures), lidos pelo mesmo leitor do painel."""
import json, subprocess, hashlib, os, sys, datetime
PSQL = ["psql", "-h", "/tmp", "-p", "5433", "-U", "postgres", "-At", "-q", "-v", "ON_ERROR_STOP=1"]
HERE = os.path.dirname(os.path.abspath(__file__)); RAIZ = os.path.join(HERE, "..")
MIGDIR = os.path.join(RAIZ, "supabase", "migrations"); FX = os.path.join(HERE, "webjur", "fixtures")
MIG = sorted(os.path.join(MIGDIR, f) for f in os.listdir(MIGDIR)); DB = "ctrl_etapa6"; res = []
ADMIN, COLAB = "00000000-0000-0000-0000-00000000000a", "00000000-0000-0000-0000-00000000000c"

def run(sql, uid=None, role=None, ok_error=False):
    pre = f"set role authenticated; set request.jwt.claim.sub = '{uid}';\n" if uid else (f"set role {role};\n" if role else "")
    p = subprocess.run(PSQL + ["-d", DB], input=pre + sql, capture_output=True, text=True)
    if p.returncode and not ok_error: raise RuntimeError(sql[:300] + "\n" + p.stderr)
    return p.stdout.strip(), p.stderr.strip(), p.returncode
q = lambda sql, uid=None: run(sql, uid)[0]
def check(n, e, o): res.append((n, str(e), str(o), "OK" if str(e) == str(o) else "FALHA"))
def recusa(n, sql, uid=None, role=None, trecho=""):
    _, e, rc = run(sql, uid, role, ok_error=True)
    check(n, "recusado", "recusado" if rc and trecho in e else (e[:80] or "aceito"))

subprocess.run(["python3", os.path.join(HERE, "webjur", "gerar_fixtures.py")], check=True, capture_output=True)
subprocess.run(PSQL + ["-d", "postgres", "-c", f"drop database if exists {DB}", "-c", f"create database {DB}"], check=True, capture_output=True)
for f in [os.path.join(HERE, "00_stub_supabase_local.sql")] + MIG:
    subprocess.run(PSQL + ["-d", DB, "-f", f], check=True, capture_output=True)
q(f"""insert into colaboradores(nome_advbox, origem) values ('TESTE COLAB A','administrativo');
  insert into perfis values ('{ADMIN}','admin',null), ('{COLAB}','colaborador',(select id from colaboradores limit 1));""")

LER = """const W=require(process.argv[1]),fs=require('fs');const f=process.argv[2];
const r=W.lerEmail(new Uint8Array(fs.readFileSync(f)),f);
console.log(JSON.stringify({remessa:{formato:r.formato,recebido_em:r.recebido_em,chave_cliente:r.chave_cliente,cliente:r.cliente,
secoes:r.secoes.map(s=>({ordem:s.ordem,caderno:s.caderno,data:s.data,declarado:s.declarado})),avisos:r.avisos},
publicacoes:r.publicacoes.map(p=>W.paraRegistro(p,r))}));"""
def ler(nome):
    caminho = os.path.join(FX, nome)
    out = subprocess.run(["node", "-e", LER, os.path.join(RAIZ, "painel", "js", "webjur_email.js"), caminho], capture_output=True, text=True, check=True).stdout
    return json.loads(out), hashlib.sha256(open(caminho, "rb").read()).hexdigest()
LER_TUDO = """const W=require(process.argv[1]+'/webjur_email.js'),P=require(process.argv[1]+'/webjur_portal.js'),fs=require('fs'),c=require('crypto');
const f=process.argv[2], b=new Uint8Array(fs.readFileSync(f)), csv=/\\.csv$/i.test(f);
const rs=csv?[P.lerExportacaoCsv(b,f)]:W.lerEmails(b,f);
const sha=x=>c.createHash('sha256').update(x).digest('hex');
console.log(JSON.stringify(rs.map(r=>({origem:csv?'webjur_portal':'webjur_email', sha:csv?sha(b):sha(Buffer.from(r.texto_bloco||'','utf8')),
 remessa:{formato:r.formato,recebido_em:r.recebido_em,chave_cliente:r.chave_cliente,cliente:r.cliente,
 secoes:r.secoes.map(s=>({ordem:s.ordem,caderno:s.caderno,data:s.data,declarado:s.declarado})),avisos:r.avisos},
 publicacoes:r.publicacoes.map(p=>csv?P.paraRegistro(p):W.paraRegistro(p,r))}))));"""
def remessas_de(caminho, uid=ADMIN):
    """Mesmo caminho do painel: um arquivo pode ter vários e-mails; o portal usa o hash do arquivo."""
    out = subprocess.run(["node", "-e", LER_TUDO, os.path.join(RAIZ, "painel", "js"), caminho], capture_output=True, text=True, check=True).stdout
    res = []
    for d in json.loads(out):
        res.append(json.loads(q(f"select pub_registrar_remessa($N${os.path.basename(caminho)}$N$,'{d['sha']}',$R${json.dumps(d['remessa'], ensure_ascii=False)}$R$::jsonb,"
                                f"$P${json.dumps(d['publicacoes'], ensure_ascii=False)}$P$::jsonb,'{d['origem']}')", uid)))
    return res
def contar(r, chave, valor): return sum(1 for x in r['resultados'] if x.get(chave) == valor)

def remessa(nome, uid=ADMIN, mexer=None, sha=None):
    d, h = ler(nome)
    if mexer: mexer(d)
    return json.loads(q(f"select pub_registrar_remessa($N${nome}$N$,'{sha or h}',$R${json.dumps(d['remessa'], ensure_ascii=False)}$R$::jsonb,"
                        f"$P${json.dumps(d['publicacoes'], ensure_ascii=False)}$P$::jsonb)", uid))

# ---------------------------------------------------------------- e-mail 1
r1 = remessa("email_ficticio_1.html")
check("E1: remessa importada e completa", "importada|completa", f"{r1['status']}|{r1['situacao']}")
check("E1: 4 publicações novas, nenhuma rejeitada", "4|0|0", f"{r1['novas']}|{r1['ja_registradas']}|{r1['rejeitadas']}")
check("E1: mesmo CNJ e mesma data, teores diferentes → 2 publicações", "2",
      q("select count(*) from publicacoes where cnj='0000101-95.2026.8.02.0001' and data_disponibilizacao='2026-10-05'"))
check("E1: campos gravados (disponib., publicação, tribunal, órgão, identificador, URL)",
      "2026-10-05|2026-10-06|TJAL|1ª Vara Cível Fictícia|900000001|https://exemplo.invalid/doc?x=900000001",
      q("select concat_ws('|',data_disponibilizacao,data_publicacao,tribunal,orgao_julgador,id_documento,url_origem) from publicacoes where id_documento='900000001'"))
check("E1: CNJ original e normalizado; processo criado", "0000101-95.2026.8.02.0001|00001019520268020001|t",
      q("select concat_ws('|',p.cnj_original,regexp_replace(p.cnj,'\\D','','g'),(p.processo_id is not null)::text::char) from publicacoes p where id_documento='900000001'"))
check("E1: conteúdo original guardado na publicação e na coleta", "900000001|900000001",
      q("select concat_ws('|',p.conteudo_original->>'id_documento',k.conteudo_original->>'id_documento') from publicacoes p join publicacoes_coletas k on k.publicacao_id=p.id where p.id_documento='900000001'"))
check("E1: coleta registra origem, hora de envio e remessa", "webjur_email|2026-10-05 12:40:00|t",
      q("select concat_ws('|',origem,recebido_em at time zone 'UTC',(remessa_id is not null)::text::char) from publicacoes_coletas k join publicacoes p on p.id=k.publicacao_id where p.id_documento='900000001'"))
check("E1: publicação sem identificador registrada (com alerta guardado)", "1|sem_identificador_documento",
      q("select count(*)||'|'||max(conteudo_original->'alertas'->>0) from publicacoes where id_documento is null"))
check("E1: evento 'publicacao_recebida' por publicação nova", "4", q("select count(*) from eventos where tipo='publicacao_recebida'"))

r1b = remessa("email_ficticio_1.html")
check("Mesmo arquivo de novo: não reimporta", "ja_importada", r1b['status'])
r1c = remessa("email_ficticio_1.eml")
check(".eml do mesmo e-mail (arquivo diferente): nenhuma publicação nova", "0|4", f"{r1c['novas']}|{r1c['ja_registradas']}")
check(".eml: reconhecidas pelo identificador (3) e pelo conteúdo (1, sem identificador)", "3|1",
      f"{sum(1 for x in r1c['resultados'] if x['identificada_por']=='id_documento')}|{sum(1 for x in r1c['resultados'] if x['identificada_por']=='conteudo')}")

# ---------------------------------------------------------------- e-mail 2 (revisão)
r2 = remessa("email_ficticio_2_revisao.html")
check("Revisão: 1 repetida (pelo identificador) e 1 nova", "1|1", f"{r2['ja_registradas']}|{r2['novas']}")
check("Mesmo CNJ, data e teor, identificadores diferentes → publicações distintas", "2",
      q("select count(*) from publicacoes where cnj='0000102-80.2026.8.02.0001'"))
check("Publicação vista em 3 remessas: 1 publicação, 3 coletas", "1|3",
      q("select count(distinct p.id)||'|'||count(*) from publicacoes p join publicacoes_coletas k on k.publicacao_id=p.id where p.id_documento='900000001'"))
check("Visão de remessas: novas por remessa (E1, .eml, revisão)", "4,0,1",
      q("select string_agg(novas::text, ',' order by id) from v_webjur_remessas"))

# ---------------------------------------------------------------- divergente e rejeições
r3 = remessa("email_ficticio_divergente.html")
check("Divergente: importada como 'divergente' (declara 2, chegou 1)", "divergente|2|1",
      f"{r3['situacao']}|{r3['total_declarado']}|{r3['total_recebido']}")
check("Divergente: aviso no log de integração", "1",
      q("select count(*) from log_integracao where operacao='pub_registrar_remessa' and nivel='aviso'"))
check("Divergente: avisos do leitor guardados na remessa", "2", q("select jsonb_array_length(avisos_leitor) from webjur_remessas where situacao='divergente'"))

def sem_teor(d): d['publicacoes'][0]['teor'] = '   '
r4 = remessa("email_ficticio_divergente.html", mexer=sem_teor, sha="a" * 64)
check("Publicação sem teor: rejeitada, registrada no log, contada na remessa", "1|1",
      f"{r4['rejeitadas']}|{q('select rejeitadas from v_webjur_remessas where id=' + str(r4['remessa_id']))}")
def teor_novo(d): d['publicacoes'][0]['teor'] += ' (versão corrigida pela fonte)'
r5 = remessa("email_ficticio_divergente.html", mexer=teor_novo, sha="b" * 64)
check("Mesmo identificador com teor diferente: mantém o original e avisa", "ja_registrada|True|1",
      f"{r5['resultados'][0]['status']}|{r5['resultados'][0]['teor_divergente']}|"
      f"{q('select count(*) from log_integracao where mensagem like ' + chr(39) + 'Mesmo identificador%' + chr(39))}")
check("Teor original intacto", "f", q("select (teor like '%versão corrigida%')::text::char from publicacoes where id_documento='900000010'"))

d, h = ler("email_ficticio_1.html")
recusa("Remessa sem seções 'Leitura DJ' recusada", f"select pub_registrar_remessa('x','{'c'*64}','{{\"secoes\":[]}}'::jsonb,'[]'::jsonb)", ADMIN, trecho="não foi reconhecido")
recusa("Hash inválido recusado", f"select pub_registrar_remessa('x','123',$R${json.dumps(d['remessa'])}$R$::jsonb,'[]'::jsonb)", ADMIN, trecho="Hash")
recusa("Mais de 500 publicações recusado",
       f"select pub_registrar_remessa('x','{'d'*64}',$R${json.dumps(d['remessa'])}$R$::jsonb,(select jsonb_agg('{{}}'::jsonb) from generate_series(1,501)))", ADMIN, trecho="500")

# ---------------------------------------------------------------- 0014: mesmo diário e data em 2 seções
r6 = remessa("email_ficticio_secoes_repetidas.html")
check("Mesmo diário e data em 2 seções (2 + 1): remessa completa, 3 novas", "completa|3", f"{r6['situacao']}|{r6['novas']}")
check("Recontagem do servidor por seção", "2,1", q(f"select string_agg(s->>'lidas_servidor', ',' order by (s->>'ordem')::int) from webjur_remessas, jsonb_array_elements(secoes) s where id={r6['remessa_id']}"))
def sem_ordem(d):
    for x in d['remessa']['secoes']: x.pop('ordem')
    for x in d['publicacoes']: x.pop('secao_ordem')
r7 = remessa("email_ficticio_secoes_repetidas.html", mexer=sem_ordem, sha="f" * 64)
check("Sem a ordem (leitor antigo): comportamento da 0013 (soma as seções → divergente)", "divergente", r7['situacao'])

# ---------------------------------------------------------------- 0015: exportação do portal
n0 = int(q("select count(*) from publicacoes"))
[rp] = remessas_de(os.path.join(FX, "portal_exportacao_1.csv"))
check("Portal após o e-mail: 1 nova (só no portal), 4 já registradas", "completa|1|4", f"{rp['situacao']}|{rp['novas']}|{rp['ja_registradas']}")
check("Portal x e-mail: 3 pelo identificador do documento, 1 por conteúdo equivalente (sem identificador)", "3|1",
      f"{contar(rp, 'identificada_por', 'id_documento')}|{contar(rp, 'identificada_por', 'conteudo_aproximado')}")
check("Correspondência aproximada registrada no log (auditoria)", "1", q("select count(*) from log_integracao where mensagem like 'Publicação reconhecida por conteúdo equivalente%'"))
check("Publicação vista no e-mail e no portal: origens das duas fontes", "webjur_email,webjur_portal",
      q("select origens from v_publicacoes where cnj='0000201-72.2026.8.13.0024'"))
check("Código Webjur guardado como id da coleta do portal", "8000000004",
      q("select k.id_origem from publicacoes_coletas k join publicacoes p on p.id=k.publicacao_id where p.cnj='0000201-72.2026.8.13.0024' and k.origem='webjur_portal'"))
[rp2] = remessas_de(os.path.join(FX, "portal_exportacao_2.csv"))
check("2ª exportação (período maior): 5 reconhecidas pelo código Webjur", "5", contar(rp2, 'identificada_por', 'codigo_da_fonte'))
check("Mesmo CNJ, data e teor com códigos Webjur diferentes → 2 publicações", "2|2",
      f"{rp2['novas']}|{q(chr(39).join(['select count(*) from publicacoes where teor like ', '%identica.', '']))}")
[rp3] = remessas_de(os.path.join(FX, "portal_exportacao_incompleta.csv"))
check("Exportação com total diferente do declarado: divergente", "divergente|3|2", f"{rp3['situacao']}|{rp3['total_declarado']}|{rp3['total_recebido']}")
check("Total de publicações: e-mails + 1 só do portal + 2 sem identificador", str(n0 + 3), q("select count(*) from publicacoes"))

# ---------------------------------------------------------------- dados REAIS (fora do git), se presentes
REAL = os.path.join(HERE, "out")
emails_reais = os.path.join(REAL, "webjur_real_controladoria_2026-11-06.html"); portal_real = os.path.join(REAL, "webjur_real_portal_2026-11-05.csv")
if os.path.exists(emails_reais) and os.path.exists(portal_real):
    re_ = remessas_de(emails_reais)
    check("REAL: 3 e-mails do escritório (03, 04, 05/11) importados e completos", "3|completa,completa,completa",
          f"{len(re_)}|{','.join(x['situacao'] for x in re_)}")
    [rr] = remessas_de(portal_real)
    check("REAL: exportação do portal de 05/11 (39): nenhuma nova, todas já vindas do e-mail", "completa|0|39", f"{rr['situacao']}|{rr['novas']}|{rr['ja_registradas']}")
    check("REAL: 35 pelo identificador do documento, 4 por conteúdo equivalente (DJE MG)", "35|4",
          f"{contar(rr, 'identificada_por', 'id_documento')}|{contar(rr, 'identificada_por', 'conteudo_aproximado')}")

# ---------------------------------------------------------------- compatibilidade com 0008
pr = json.loads(q("select pub_registrar('{\"cnj\":\"0000103-65.2026.8.02.0001\",\"data_disponibilizacao\":\"06/10/2026\",\"teor\":\"Teor ficticio do portal.\"}'::jsonb,'webjur_portal','portal-1')", ADMIN))
check("pub_registrar (assinatura da 0008) continua funcionando", "nova", pr['status'])

# ---------------------------------------------------------------- consultas do painel
L = json.loads(q("select pub_listar('2026-10-01','2026-10-31')", ADMIN))
N_OUT = q("select count(*) from publicacoes where coalesce(data_disponibilizacao,data_publicacao,(registrada_em at time zone 'America/Sao_Paulo')::date) between '2026-10-01' and '2026-10-31'")
check("pub_listar: total no período = banco (e todas sem conferência)", f"{N_OUT}|{N_OUT}",
      f"{L['total']}|{L['por_situacao'].get('sem_conferencia')}")
L2 = json.loads(q("select pub_listar('2026-10-01','2026-10-31','00001019520268020001')", ADMIN))
check("pub_listar: busca pelo CNJ só com dígitos", "2", L2['total'])
L3 = json.loads(q("select pub_listar('2026-10-01','2026-10-31',null,'com_alerta')", ADMIN))
check("pub_listar: filtro 'com alerta' = banco", q("select count(*) from publicacoes where coalesce(data_disponibilizacao,data_publicacao,(registrada_em at time zone 'America/Sao_Paulo')::date) between '2026-10-01' and '2026-10-31' and jsonb_array_length(coalesce(conteudo_original->'alertas','[]'))>0"), L3['total'])
L4 = json.loads(q("select pub_listar('2026-10-01','2026-10-31',null,null,'webjur_portal')", ADMIN))
check("pub_listar: filtro por origem (portal) = banco", q("select count(distinct p.id) from publicacoes p join publicacoes_coletas k on k.publicacao_id=p.id and k.origem='webjur_portal' where coalesce(data_disponibilizacao,data_publicacao,(registrada_em at time zone 'America/Sao_Paulo')::date) between '2026-10-01' and '2026-10-31'"), L4['total'])
check("pub_listar: limite respeitado com total exato", f"2|{L['total']}",
      (lambda x: f"{len(x['linhas'])}|{x['total']}")(json.loads(q("select pub_listar('2026-10-01','2026-10-31',null,null,null,2)", ADMIN))))
pid = q("select id from publicacoes where id_documento='900000001'")
D = json.loads(q(f"select pub_detalhe({pid})", ADMIN))
check("pub_detalhe: teor completo; 4 coletas (3 e-mails + portal); só a do portal com teor formatado diferente", "True|4|webjur_portal",
      f"{'Primeiro despacho' in D['publicacao']['teor']}|{len(D['coletas'])}|{','.join(c['origem'] for c in D['coletas'] if not c['teor_igual'])}")

# ---------------------------------------------------------------- acesso e imutabilidade
recusa("Colaborador não registra remessa", f"select pub_registrar_remessa('x','{'e'*64}',$R${json.dumps(d['remessa'])}$R$::jsonb,'[]'::jsonb)", COLAB, trecho="Somente a controladoria")
check("Colaborador não vê publicações (pub_listar devolve 0)", "0", json.loads(q("select pub_listar('2026-10-01','2026-10-31')", COLAB))['total'])
check("Colaborador não vê remessas", "0", q("select count(*) from v_webjur_remessas", COLAB))
recusa("Anônimo não executa pub_listar", "select pub_listar('2026-10-01','2026-10-31')", role="anon", trecho="permission denied")
recusa("Ninguém chama _pub_registrar direto", "select _pub_registrar('{}'::jsonb,'manual',null,null)", ADMIN, trecho="permission denied")
recusa("Remessa é imutável", "update webjur_remessas set situacao='completa'", trecho="")
recusa("Coleta é imutável", "delete from publicacoes_coletas", trecho="")

w = max(len(x[0]) for x in res)
for n, e, o, s in res: print(f"{s:5} | {n:<{w}} | esperado: {e[:50]} | obtido: {o[:50]}")
print(f"\n{sum(1 for x in res if x[3]=='OK')}/{len(res)} OK — executado em {datetime.datetime.now():%d/%m/%Y %H:%M}")
sys.exit(0 if all(x[3] == "OK" for x in res) else 1)
