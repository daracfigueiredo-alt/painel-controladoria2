/* Teste ponta a ponta — Etapa 8 (área "Tarefas de análise pendentes").
 * Banco LOCAL novo (todas as migrações, RLS real) + servidor_local.js + Chromium. Dados FICTÍCIOS:
 * publicações dos e-mails fictícios da Etapa 6 e intimações no formato que a extensão envia. */
'use strict';
const { chromium } = require('playwright');
const { execFileSync, spawn } = require('child_process');
const fs = require('fs'), path = require('path'), crypto = require('crypto');
const DB = 'ctrl_e2e_an', PORTA = 8793, BASE = `http://127.0.0.1:${PORTA}/painel/`;
const RAIZ = path.join(__dirname, '..', '..'), FX = path.join(RAIZ, 'tests', 'webjur', 'fixtures');
const SAIDA = path.join(__dirname, 'out'); fs.mkdirSync(SAIDA, { recursive: true });
const ADMIN = '00000000-0000-0000-0000-00000000000a';
const res = []; const check = (n, e, o) => res.push([n, String(e), String(o), String(e) === String(o) ? 'OK' : 'FALHA']);
const psql = (sql, db = DB) => execFileSync('psql', ['-h', '/tmp', '-p', '5433', '-U', 'postgres', '-At', '-q', '-v', 'ON_ERROR_STOP=1', '-d', db], { input: sql, encoding: 'utf8' }).trim();
const comoAdmin = sql => psql(`set role authenticated; set request.jwt.claims = '{"sub":"${ADMIN}"}';\n${sql}`);
const dol = (t, s) => `$${t}$${s}$${t}$`;
let srv = null; process.on('exit', () => { if (srv) srv.kill(); });

(async () => {
  execFileSync('python3', [path.join(RAIZ, 'tests', 'webjur', 'gerar_fixtures.py')]);
  psql(`drop database if exists ${DB}`, 'postgres'); psql(`create database ${DB}`, 'postgres');
  for (const f of [path.join(RAIZ, 'tests', '00_stub_supabase_local.sql'), ...fs.readdirSync(path.join(RAIZ, 'supabase', 'migrations')).sort().map(f => path.join(RAIZ, 'supabase', 'migrations', f))])
    execFileSync('psql', ['-h', '/tmp', '-p', '5433', '-U', 'postgres', '-q', '-v', 'ON_ERROR_STOP=1', '-d', DB, '-f', f], { stdio: 'pipe' });
  psql(`insert into colaboradores(nome_advbox, origem) values ('TESTE COLAB A','administrativo');
        insert into perfis values ('${ADMIN}','admin',null), ('00000000-0000-0000-0000-00000000000c','colaborador',(select id from colaboradores limit 1));
        update parametros set valor = '"advbox"' where chave = 'tarefa_analise_destino';`);
  const W = require(path.join(RAIZ, 'painel', 'js', 'webjur_email.js'));
  for (const nome of ['email_ficticio_1.html', 'email_ficticio_divergente.html']) for (const r of W.lerEmails(new Uint8Array(fs.readFileSync(path.join(FX, nome))), nome)) {
    const rem = { formato: r.formato, recebido_em: r.recebido_em, secoes: r.secoes.map(s => ({ ordem: s.ordem, caderno: s.caderno, data: s.data, declarado: s.declarado })), avisos: r.avisos };
    comoAdmin(`select pub_registrar_remessa('${nome}','${crypto.createHash('sha256').update(r.texto_bloco).digest('hex')}',${dol('R', JSON.stringify(rem))}::jsonb,${dol('P', JSON.stringify(r.publicacoes.map(p => W.paraRegistro(p, r))))}::jsonb)`);
  }
  const CORPO = t => `PROCEDIMENTO COMUM CIVEL ADV: ADVOGADA FICTICIA DE TESTE (OAB 999999/MG) AUTOR: Empresa Ficticia Ltda REU: Outra Empresa Ficticia S.A. ${t} POLO ATIVO: EMPRESA FICTICIA LTDA`;
  const it = (post, cnj, d, t, law = '600000001', cap = '2026-10-05T01:21:00-03:00') => ({ post_id: post, cnj, data_publicacao: d, tribunal: 'TJAL', orgao: 'TJAL - 1ª VARA CÍVEL FICTÍCIA', capturada_em: cap, lawsuit_id: law, partes: 'T001', teor: `TJAL - 1ª VARA CÍVEL FICTÍCIA\nProcesso: ${cnj}\n${t}`, situacao: 'Pendente' });
  const ints = [it('700000001', '0000101-95.2026.8.02.0001', '06/10/2026', CORPO('Primeiro despacho ficticio: cite-se.')),
                it('700000002', '0000101-95.2026.8.02.0001', '06/10/2026', CORPO('Segundo despacho ficticio: intime-se o perito.')),
                it('700000003', '0000201-72.2026.8.13.0024', '05/10/2026', 'PROCESSOS DISTRIBUÍDOS PROCESSO: 0000201-72.2026.8.13.0024 CLASSE JUDICIAL: APELACAO CIVEL APELANTE: EMPRESA FICTICIA LTDA DATA DISTRIBUICAO: 05/10/2026', null),
                it('700000004', '0000103-65.2026.8.02.0001', '07/10/2026', CORPO('Outro texto sobre prazo ficticio unico.'), '600000003', '2026-10-06T01:21:00-03:00')];
  comoAdmin(`select ext_registrar_varredura(${dol('V', JSON.stringify({ pagina: '/publications', filtro: { intervalo: 'nos últimos 3 dias' }, recebido_de: '05/10/2026', recebido_ate: '06/10/2026', total_informado: 4, erros: [] }))}::jsonb, ${dol('I', JSON.stringify(ints))}::jsonb)`);

  comoAdmin("select double_check_executar('2026-10-05','2026-10-07')");
  srv = spawn(process.execPath, [path.join(__dirname, 'servidor_local.js')], { env: { ...process.env, PORTA: String(PORTA), DB }, stdio: ['ignore', 'pipe', 'inherit'] });
  await new Promise(ok => srv.stdout.once('data', ok));
  const browser = await chromium.launch();
  const page = await (await browser.newContext({ viewport: { width: 1360, height: 900 } })).newPage();
  const erros = []; page.on('console', m => { if (m.type() === 'error') erros.push(m.text()); }); page.on('pageerror', e => erros.push(e.message));
  const http = []; page.on('response', r => { if (r.status() >= 400) http.push(`${r.status()} ${r.url().replace(/^.*\/(rest|auth)\/v1\//, '')}`); });
  const tela = n => page.screenshot({ path: path.join(SAIDA, n + '.png'), fullPage: true });
  async function entrar(email, senha) { await page.goto(BASE); await page.fill('#login-email', email); await page.fill('#login-senha', senha); await page.click('#btn-entrar'); await page.waitForSelector('#tela-app:not([hidden])'); }
  const esperarLista = () => page.waitForFunction(() => document.querySelector('#dc-total'));

  const n = sql => Number(comoAdmin(sql));
  const prep = n("select count(*) from tarefas_analise where status='preparada'");
  check('Base: double check preparou tarefas de análise', 'true', prep >= 2);
  await entrar('admin.teste@exemplo.invalid', 'senha-admin-teste');
  await page.click('#menu a:has-text("Tarefas de análise pendentes")');
  await page.waitForSelector('#an-contagem');
  check('Área abre e lista as preparadas', 'true', new RegExp(`Preparada — aguarda aprovação: ${prep}`).test(await page.textContent('#an-contagem')));
  check('Aviso da mudança de etapa (NEGOCIAÇÃO / ANÁLISE DO CASO) visível', 'true', /NEGOCIAÇÃO \/ ANÁLISE DO CASO/.test(await page.textContent('#conteudo')));
  await tela('an_01_lista');
  // revisão de uma: descrição com o teor
  await page.click('#an-lista button.an-abrir >> nth=0');
  await page.waitForSelector('#an-aprovar');
  check('Revisão mostra a descrição que vai para o ADVBOX (teor integral)', 'true', /TEOR INTEGRAL DA PUBLICAÇÃO/.test(await page.textContent('dialog.detalhe')));
  await tela('an_02_revisao');
  await page.click('dialog.detalhe button:text-is("Fechar")');
  // aprovação em lote
  await page.click('button:text-is("Marcar todas as preparadas")');
  await page.waitForSelector('#an-aprovar-marcadas');
  await page.click('#an-aprovar-marcadas');
  await page.waitForSelector('#an-saida .aviso');
  check('Aprovar as marcadas: todas aprovadas no banco', `${prep}`, comoAdmin("select count(*) from tarefas_analise where status='aprovada'"));
  // extensão: bloqueio por processo ambíguo (simulado no banco, como a extensão faz)
  const id = comoAdmin("select (ext_analise_fila()->>'proxima')");
  comoAdmin(`select analise_iniciar_criacao(${id})`);
  comoAdmin(`select analise_bloquear_criacao(${id}, 'processo_ambiguo', '{"busca":"x","opcoes":[{"lawsuit_id":"111","texto":"CLIENTE A - PROC"},{"lawsuit_id":"222","texto":"CLIENTE B - PROC"}]}'::jsonb)`);
  await page.click('#an-atualizar'); await page.waitForTimeout(800);
  check('Bloqueio aparece na lista com a explicação', 'true', /Bloqueada: Há mais de um cadastro/.test(await page.textContent('#an-lista')));
  await page.click('#an-lista button:text-is("Resolver")');
  await page.waitForSelector('#an-processo');
  await page.selectOption('#an-processo', '222');
  await page.fill('#an-nota', 'Cliente B é o desta publicação');
  await page.click('#an-liberar');
  await page.waitForFunction(() => !document.querySelector('dialog.detalhe').open);
  check('Escolha do processo grava e libera nova tentativa', '222|', comoAdmin(`select advbox_lawsuit_id||'|'||coalesce(bloqueio_criacao,'') from tarefas_analise where id=${id}`));
  // verificar no ADVBOX -> registrar o ID pelo painel
  comoAdmin(`select analise_iniciar_criacao(${id})`); comoAdmin(`select analise_falha_criacao(${id}, 'sem confirmação', false)`);
  await page.click('#an-atualizar'); await page.waitForTimeout(800);
  await page.click('#an-lista button:text-is("Conferir")');
  await page.waitForSelector('#an-id-advbox');
  await tela('an_03_verificar');
  await page.fill('#an-id-advbox', '297000001'); await page.fill('#an-nota', 'Achei no ADVBOX');
  await page.click('button:text-is("Foi criada: registrar o ID")');
  await page.waitForFunction(() => !document.querySelector('dialog.detalhe').open);
  check('Verificar no ADVBOX → criada com o ID informado', 'criada|297000001', comoAdmin(`select status||'|'||advbox_tarefa_id from tarefas_analise where id=${id}`));
  check('Link da tarefa criada na lista', 'true', !!(await page.$('#an-lista a[href="https://app.advbox.com.br/0?t=297000001"]')));
  // tarefa de teste
  await page.click('#an-teste-preparar');
  await page.waitForFunction(() => /TESTE — TESTE 1\.0/.test(document.querySelector('#an-lista').textContent));
  check('Tarefa de teste preparada pelo painel (TESTE 1.0)', '1', comoAdmin("select count(*) from tarefas_analise where teste and busca_advbox='TESTE 1.0' and status='preparada'"));
  await page.fill('#an-teste-busca', 'BANCO REAL'); await page.click('#an-teste-preparar');
  await page.waitForSelector('#an-teste .aviso-erro');
  check('Teste fora de caso de TESTE: recusado com mensagem', 'true', /TESTE/.test(await page.textContent('#an-teste .aviso-erro')));
  await tela('an_04_final');
  check('Sem erros de console (exceto o 400 da recusa esperada)', '1', erros.length === 1 && /400/.test(erros[0]) ? '1' : erros.join(' | '));
  check('Sem respostas HTTP de erro inesperadas', '', http.filter(x => !/^400 rpc\/analise_preparar_teste/.test(x)).join(' | '));
  await browser.close();
  const w = Math.max(...res.map(r => r[0].length));
  for (const [nn, e, o, s] of res) console.log(`${s.padEnd(5)} ${nn.padEnd(w)}` + (s === 'OK' ? '' : `  esperado=${e} obtido=${o}`));
  const ok = res.filter(r => r[3] === 'OK').length; console.log(`\n${ok}/${res.length} OK`); process.exit(ok === res.length ? 0 : 1);
})().catch(e => { console.error(e); process.exit(1); });
