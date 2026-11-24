/* Teste ponta a ponta — Etapa 7 (área "Double check ADVBOX").
 * Banco LOCAL novo (todas as migrações, RLS real) + servidor_local.js + Chromium. Dados FICTÍCIOS:
 * publicações dos e-mails fictícios da Etapa 6 e intimações no formato que a extensão envia. */
'use strict';
const { chromium } = require('playwright');
const { execFileSync, spawn } = require('child_process');
const fs = require('fs'), path = require('path'), crypto = require('crypto');
const DB = 'ctrl_e2e_dc', PORTA = 8792, BASE = `http://127.0.0.1:${PORTA}/painel/`;
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
        insert into perfis values ('${ADMIN}','admin',null), ('00000000-0000-0000-0000-00000000000c','colaborador',(select id from colaboradores limit 1));`);
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

  srv = spawn(process.execPath, [path.join(__dirname, 'servidor_local.js')], { env: { ...process.env, PORTA: String(PORTA), DB }, stdio: ['ignore', 'pipe', 'inherit'] });
  await new Promise(ok => srv.stdout.once('data', ok));
  const browser = await chromium.launch();
  const page = await (await browser.newContext({ viewport: { width: 1360, height: 900 } })).newPage();
  const erros = []; page.on('console', m => { if (m.type() === 'error') erros.push(m.text()); }); page.on('pageerror', e => erros.push(e.message));
  const http = []; page.on('response', r => { if (r.status() >= 400) http.push(`${r.status()} ${r.url().replace(/^.*\/(rest|auth)\/v1\//, '')}`); });
  const tela = n => page.screenshot({ path: path.join(SAIDA, n + '.png'), fullPage: true });
  async function entrar(email, senha) { await page.goto(BASE); await page.fill('#login-email', email); await page.fill('#login-senha', senha); await page.click('#btn-entrar'); await page.waitForSelector('#tela-app:not([hidden])'); }
  const esperarLista = () => page.waitForFunction(() => document.querySelector('#dc-total'));

  await entrar('admin.teste@exemplo.invalid', 'senha-admin-teste');
  await page.click('#menu a:has-text("Double check ADVBOX")');
  await page.waitForSelector('#conteudo h1:text-is("Double check ADVBOX")');
  await page.fill('#dc-ini', '2026-10-05'); await page.dispatchEvent('#dc-ini', 'change');
  await page.fill('#dc-fim', '2026-10-07'); await page.dispatchEvent('#dc-fim', 'change');
  await esperarLista();
  check('Antes de executar: varredura listada como completa', 'true', /Completa/.test(await page.textContent('#dc-lista')));
  await page.click('#dc-executar');
  await page.waitForSelector('#dc-saida .aviso');
  check('Execução: resumo com encontradas, ausente, não cadastrado e inconclusiva', 'true',
    /Encontrada no ADVBOX: 2/.test(await page.textContent('#dc-saida')) && /Processo não cadastrado: 1/.test(await page.textContent('#dc-saida')) && /Inconclusiva: 1/.test(await page.textContent('#dc-saida')));
  await page.waitForFunction(() => /Encontrada no ADVBOX/.test(document.querySelector('#dc-lista').textContent));
  const banco = JSON.parse(comoAdmin("select double_check_diario('2026-10-05','2026-10-07')"));
  const d5 = banco.find(x => x.dia === '2026-10-05');
  const linha5 = await page.locator('#dc-relatorio tbody tr').filter({ hasText: '05/10/2026' }).innerText();
  check('Relatório 05/10 na tela = banco (recebidas, encontradas, ausentes, não cadastrado)', `${d5.recebidas}|${d5.encontradas}|${d5.ausentes}|${d5.processo_nao_cadastrado}`,
    linha5.split('\t').slice(1, 5).map(s => s.trim()).join('|'));
  check('% ausentes na tela = banco', `${String(d5.pct_ausentes).replace('.', ',')}%`, linha5.split('\t')[9].trim());
  check('Lista: uma linha por publicação do período', psql("select count(*) from publicacoes where data_disponibilizacao between '2026-10-05' and '2026-10-07'"), await page.locator('#dc-lista table').first().locator('tbody tr').count());
  check('Link para a intimação no ADVBOX (nova aba, noopener)', 'https://app.advbox.com.br/posts/700000001/edit|noopener noreferrer',
    `${await page.getAttribute('#dc-lista a:text-is("700000001")', 'href')}|${await page.getAttribute('#dc-lista a:text-is("700000001")', 'rel')}`);
  check('Tarefas preparadas aparecem como "aguarda aprovação"', 'true', /Preparada \(aguarda aprovação\)/.test(await page.textContent('#dc-lista')));
  await tela('70_double_check');

  // conferência manual da inconclusiva
  const linhaInc = page.locator('#dc-lista tbody tr').filter({ hasText: 'Inconclusiva' });
  check('Uma publicação inconclusiva com botão "Conferir"', 1, await linhaInc.count());
  await linhaInc.locator('.dc-conferir').click();
  await page.waitForSelector('dialog.detalhe[open] .dc-candidata');
  check('Diálogo: teor da Webjur e candidata do ADVBOX com semelhança', 'true|true',
    `${/Despacho ficticio unico/.test(await page.textContent('dialog.detalhe'))}|${/Intimação 700000004/.test(await page.textContent('dialog.detalhe .dc-candidata'))}`);
  await tela('71_conferir');
  await page.click('dialog.detalhe .dc-candidata button');
  check('Sem nota: recusado pelo banco, diálogo continua aberto', 'true', await page.locator('dialog.detalhe .pub-resultado .aviso-erro').isVisible().catch(() => false) || (await page.waitForSelector('dialog.detalhe .pub-resultado .aviso-erro'), true));
  await page.fill('#dc-nota', 'Conferido na aba Intimações do processo: mesmo despacho.');
  await page.click('dialog.detalhe .dc-candidata button');
  await page.waitForFunction(() => !document.querySelector('dialog.detalhe[open]'));
  check('Conferência manual gravada no banco', 'encontrada_advbox|manual|700000004',
    psql("select situacao||'|'||origem||'|'||(evidencia->>'publicacao_advbox') from conferencias_publicacao c join publicacoes p on p.id=c.publicacao_id where p.id_documento='900000010' order by c.id desc limit 1"));
  await page.waitForFunction(() => !/Inconclusiva/.test(document.querySelector('#dc-lista table tbody').textContent));
  check('Lista atualizada sem a inconclusiva', 0, await page.locator('#dc-lista tbody tr').filter({ hasText: 'Inconclusiva' }).count());

  await page.setViewportSize({ width: 390, height: 844 }); await page.waitForTimeout(200);
  check('Celular: sem rolagem horizontal da página', 'true', await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1));
  await tela('72_celular'); await page.setViewportSize({ width: 1360, height: 900 });

  await page.click('#btn-sair'); await page.waitForSelector('#tela-login:not([hidden])');
  await entrar('colab.teste@exemplo.invalid', 'senha-colab-teste');
  const temMenu = await page.locator('#menu a:has-text("Double check ADVBOX")').count();
  if (temMenu) { await page.click('#menu a:has-text("Double check ADVBOX")'); await page.waitForTimeout(300); }
  check('Colaborador: área restrita', 'true', !temMenu || /restrita ao administrador/.test(await page.textContent('#conteudo')));
  check('Sem erros de console', '', erros.filter(e => !/400|Bad Request/.test(e)).join(' | '));
  check('Respostas HTTP de erro: só a recusa esperada (nota curta)', 'true', http.every(x => /double_check_manual/.test(x)) && http.length === 1);
  await browser.close();
  const w = Math.max(...res.map(x => x[0].length));
  console.log(res.map(([n, e, o, s]) => `${s.padEnd(5)} | ${n.padEnd(w)} | esperado: ${e.slice(0, 50)} | obtido: ${o.slice(0, 50)}`).join('\n')
    + `\n\n${res.filter(x => x[3] === 'OK').length}/${res.length} OK — executado em ${new Date().toLocaleString('pt-BR')}`);
  process.exit(res.every(x => x[3] === 'OK') ? 0 : 1);
})().catch(e => { console.error(e); process.exit(1); });
