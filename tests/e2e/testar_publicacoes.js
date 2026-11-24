/* Teste ponta a ponta — Etapa 6 (área "Publicações Webjur").
 * Banco PostgreSQL LOCAL novo (todas as migrações, RLS real) + servidor_local.js + Chromium.
 * E-mails FICTÍCIOS de tests/webjur/fixtures. Compara a tela com o banco. */
'use strict';
const { chromium } = require('playwright');
const { execFileSync, spawn } = require('child_process');
const fs = require('fs');
const path = require('path');

const DB = 'ctrl_e2e_pub', PORTA = 8791, BASE = `http://127.0.0.1:${PORTA}/painel/`;
const RAIZ = path.join(__dirname, '..', '..'), FX = path.join(RAIZ, 'tests', 'webjur', 'fixtures');
const SAIDA = path.join(__dirname, 'out'); fs.mkdirSync(SAIDA, { recursive: true });
const ADMIN_UID = '00000000-0000-0000-0000-00000000000a';
const res = [];
const check = (n, e, o) => res.push([n, String(e), String(o), String(e) === String(o) ? 'OK' : 'FALHA']);
const psql = (sql, db = DB) => execFileSync('psql', ['-h', '/tmp', '-p', '5433', '-U', 'postgres', '-At', '-q', '-v', 'ON_ERROR_STOP=1', '-d', db, '-c', sql], { encoding: 'utf8' }).trim();
const comoAdmin = sql => psql(`set role authenticated; set request.jwt.claims = '{"sub":"${ADMIN_UID}"}'; ${sql}`);
let srv = null;
process.on('exit', () => { if (srv) srv.kill(); });

(async () => {
  execFileSync('python3', [path.join(RAIZ, 'tests', 'webjur', 'gerar_fixtures.py')]);
  psql(`drop database if exists ${DB}`, 'postgres'); psql(`create database ${DB}`, 'postgres');
  const migs = fs.readdirSync(path.join(RAIZ, 'supabase', 'migrations')).sort().map(f => path.join(RAIZ, 'supabase', 'migrations', f));
  for (const f of [path.join(RAIZ, 'tests', '00_stub_supabase_local.sql'), ...migs])
    execFileSync('psql', ['-h', '/tmp', '-p', '5433', '-U', 'postgres', '-q', '-v', 'ON_ERROR_STOP=1', '-d', DB, '-f', f], { stdio: 'pipe' });
  psql(`insert into colaboradores(nome_advbox, origem) values ('TESTE COLAB A','administrativo');
        insert into perfis values ('00000000-0000-0000-0000-00000000000a','admin',null),
                                  ('00000000-0000-0000-0000-00000000000c','colaborador',(select id from colaboradores limit 1));`);

  srv = spawn(process.execPath, [path.join(__dirname, 'servidor_local.js')], { env: { ...process.env, PORTA: String(PORTA), DB }, stdio: ['ignore', 'pipe', 'inherit'] });
  await new Promise(ok => srv.stdout.once('data', ok));
  const browser = await chromium.launch();
  const ctxB = await browser.newContext({ viewport: { width: 1360, height: 900 } });
  const page = await ctxB.newPage();
  const erros = []; page.on('console', m => { if (m.type() === 'error') erros.push(m.text()); }); page.on('pageerror', e => erros.push(e.message));
  const falhasHttp = []; page.on('response', async r => { if (r.status() >= 400) falhasHttp.push(`${r.status()} ${r.url().replace(/^.*\/(rest|auth)\/v1\//, '')}`); });
  const tela = n => page.screenshot({ path: path.join(SAIDA, n + '.png'), fullPage: true });
  async function entrar(email, senha) {
    await page.goto(BASE); await page.fill('#login-email', email); await page.fill('#login-senha', senha); await page.click('#btn-entrar');
    await page.waitForSelector('#tela-app:not([hidden])');
  }
  const abrirArea = async () => { await page.click('#menu a:has-text("Publicações Webjur")'); await page.waitForSelector('#conteudo h1:text-is("Publicações Webjur")'); };
  const totalTela = async () => { await page.waitForSelector('#pub-total'); return page.textContent('#pub-total'); };
  const esperarLista = async () => { await page.waitForFunction(() => document.querySelector('#pub-lista-corpo') && !/Carregando/.test(document.querySelector('#pub-lista-corpo').textContent)); };

  await entrar('admin.teste@exemplo.invalid', 'senha-admin-teste');
  await abrirArea();
  await page.waitForSelector('#pub-remessas table');
  check('Área abre com remessas vazias', 'true', /Nenhum e-mail importado ainda/.test(await page.textContent('#pub-remessas')));

  // ---- dois arquivos: um completo e um divergente
  await page.setInputFiles('#pub-arquivos', [path.join(FX, 'email_ficticio_1.html'), path.join(FX, 'email_ficticio_divergente.html')]);
  await page.waitForFunction(() => document.querySelectorAll('.pub-previa').length === 2);
  const cards = page.locator('.pub-previa');
  check('Prévia: 2 cartões', 2, await cards.count());
  check('Completo: aviso de conferência e botão habilitado', 'true|false|Registrar 4 publicação(ões)',
    `${/Conferido: as 4 publicações/.test(await cards.nth(0).textContent())}|${await cards.nth(0).locator('.pub-registrar').isDisabled()}|${(await cards.nth(0).locator('.pub-registrar').textContent()).trim()}`);
  check('Completo: 4 linhas de publicação, 1 com alerta (sem identificador)', '4|1',
    `${await cards.nth(0).locator('h3:text-is("Publicações") + .tab-rolagem tbody tr').count()}|${await cards.nth(0).locator('tr.linha-alerta').count()}`);
  check('Divergente: aviso, botão desabilitado até confirmar', 'true|true',
    `${/Contagem divergente/.test(await cards.nth(1).textContent())}|${await cards.nth(1).locator('.pub-registrar').isDisabled()}`);
  await tela('60_previa');

  await cards.nth(0).locator('.pub-registrar').click();
  await cards.nth(0).locator('.pub-resultado .aviso').waitFor();
  check('Registro: resultado da remessa na tela', 'true', /4 nova\(s\), 0 já registrada\(s\), 0 rejeitada\(s\)/.test(await cards.nth(0).locator('.pub-resultado').textContent()));
  await cards.nth(1).locator('.pub-confirma-divergente').check();
  await cards.nth(1).locator('.pub-registrar').click();
  await cards.nth(1).locator('.pub-resultado .aviso').waitFor();
  check('Divergente registrado com a divergência', 'true', /Contagem divergente registrada/.test(await cards.nth(1).locator('.pub-resultado').textContent()));
  await page.waitForFunction(() => document.querySelectorAll('#pub-remessas tbody tr').length === 2);
  check('Remessas: 2 linhas, uma divergente marcada', '2|1',
    `${await page.locator('#pub-remessas tbody tr').count()}|${await page.locator('#pub-remessas tr.linha-alerta').count()}`);

  // ---- mesmo arquivo de novo
  await page.setInputFiles('#pub-arquivos', path.join(FX, 'email_ficticio_1.html'));
  await page.waitForFunction(() => document.querySelectorAll('.pub-previa').length === 1);
  await page.click('.pub-previa .pub-registrar');
  await page.locator('.pub-previa .pub-resultado .aviso').waitFor();
  check('Mesmo arquivo: "já foi importado", nada gravado', 'true|2', `${/já foi importado/.test(await page.textContent('.pub-previa .pub-resultado'))}|${psql('select count(*) from webjur_remessas')}`);

  // ---- texto colado (revisão)
  const W = require(path.join(RAIZ, 'painel', 'js', 'webjur_email.js'));
  await page.fill('#pub-texto', W.htmlParaTexto(fs.readFileSync(path.join(FX, 'email_ficticio_2_revisao.html'), 'utf8')).join('\n'));
  await page.click('#pub-ler-texto');
  await page.waitForFunction(() => /texto colado/.test((document.querySelector('.pub-previa h2') || {}).textContent || ''));
  await page.click('.pub-previa .pub-registrar');
  await page.locator('.pub-previa .pub-resultado .aviso').waitFor();
  check('Texto colado (revisão): 1 nova e 1 já registrada', 'true', /1 nova\(s\), 1 já registrada\(s\)/.test(await page.textContent('.pub-previa .pub-resultado')));

  // ---- encaminhamento com 2 e-mails da Webjur no mesmo arquivo
  await page.setInputFiles('#pub-arquivos', path.join(FX, 'encaminhamento_dois_emails.html'));
  await page.waitForFunction(() => document.querySelectorAll('.pub-previa').length === 2);
  check('Arquivo com 2 e-mails: 2 cartões ("e-mail 1 de 2", "e-mail 2 de 2")', 'true|true',
    `${/e-mail 1 de 2/.test(await page.locator('.pub-previa h2').nth(0).textContent())}|${/e-mail 2 de 2/.test(await page.locator('.pub-previa h2').nth(1).textContent())}`);
  await page.locator('.pub-previa').nth(1).locator('.pub-confirma-divergente').check();
  await page.locator('.pub-previa').nth(1).locator('.pub-registrar').click();
  await page.locator('.pub-previa').nth(1).locator('.pub-resultado .aviso').waitFor();
  check('O 2º e-mail é o mesmo já importado em outro arquivo: reconhecido pelo texto', 'true',
    /já foi importado/.test(await page.locator('.pub-previa').nth(1).locator('.pub-resultado').textContent()));

  // ---- exportação do portal (CSV): mesmas publicações do e-mail 1 + 1 só do portal
  await page.setInputFiles('#pub-arquivos', path.join(FX, 'portal_exportacao_1.csv'));
  await page.waitForFunction(() => /Exportação do portal/.test((document.querySelector('.pub-previa .pub-fonte') || {}).textContent || ''));
  check('Portal: prévia com contagem conferida e códigos Webjur', 'true|true',
    `${/batem com o total informado no fim do arquivo/.test(await page.textContent('.pub-previa'))}|${/AL · 8000000001/.test(await page.textContent('.pub-previa'))}`);
  await page.click('.pub-previa .pub-registrar');
  await page.locator('.pub-previa .pub-resultado .aviso').waitFor();
  check('Portal após o e-mail: 1 nova, 4 já registradas (sem duplicar)', 'true',
    /1 nova\(s\), 4 já registrada\(s\)/.test(await page.textContent('.pub-previa .pub-resultado')));

  // ---- lista
  await page.fill('#pub-ini', '2026-10-01'); await page.dispatchEvent('#pub-ini', 'change'); await esperarLista();
  const nBanco = psql('select count(*) from publicacoes');
  check('Lista: total da tela = banco', `${nBanco} publicação(ões).`, (await totalTela()).split(' Sem')[0].trim());
  check('Lista: uma linha por publicação', nBanco, await page.locator('#pub-lista-corpo tbody tr').count());
  await page.fill('#pub-busca', '0000101-95'); await page.waitForFunction(() => /^2 publica/.test((document.querySelector('#pub-total') || {}).textContent || ''));
  check('Busca por CNJ: 2 publicações do mesmo processo e data', 2, await page.locator('#pub-lista-corpo tbody tr').count());
  await page.fill('#pub-busca', ''); await page.selectOption('#pub-situacao', 'com_alerta');
  await page.waitForFunction(() => /^1 publica/.test((document.querySelector('#pub-total') || {}).textContent || ''));
  check('Filtro "com alerta da leitura"', 1, await page.locator('#pub-lista-corpo tbody tr').count());
  await page.selectOption('#pub-situacao', ''); await esperarLista();
  await page.fill('#pub-busca', '900000001'); await page.waitForFunction(() => /^1 publica/.test((document.querySelector('#pub-total') || {}).textContent || ''));
  check('Fontes: publicação vista em 2 e-mails e no portal', 'true|true', `${/\(3×\)/.test(await page.textContent('#pub-lista-corpo tbody tr'))}|${/Portal/.test(await page.textContent('#pub-lista-corpo tbody tr'))}`);
  await tela('61_lista');

  // ---- detalhe
  await page.click('#pub-lista-corpo .pub-abrir');
  await page.waitForSelector('dialog.detalhe[open] .pub-teor');
  const id = psql("select id from publicacoes where id_documento='900000001'");
  const det = JSON.parse(comoAdmin(`select pub_detalhe(${id})`));
  check('Detalhe: teor completo igual ao do banco', det.publicacao.teor, await page.textContent('dialog.detalhe .pub-teor'));
  check('Detalhe: coletas = banco', det.coletas.length, await page.locator('dialog.detalhe h3:has-text("Coletas") + .tab-rolagem tbody tr').count());
  check('Detalhe: link do documento com rel=noopener', 'noopener noreferrer', await page.getAttribute('dialog.detalhe a[target=_blank]', 'rel'));
  await tela('62_detalhe');
  await page.click('dialog.detalhe button:has-text("Fechar")');

  // ---- celular
  await page.setViewportSize({ width: 390, height: 844 });
  await page.waitForTimeout(200);
  check('Celular: sem rolagem horizontal da página', 'true', await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1));
  await tela('63_celular');
  await page.setViewportSize({ width: 1360, height: 900 });

  // ---- colaborador
  await page.click('#btn-sair'); await page.waitForSelector('#tela-login:not([hidden])');
  await entrar('colab.teste@exemplo.invalid', 'senha-colab-teste');
  const temMenu = await page.locator('#menu a:has-text("Publicações Webjur")').count();
  if (temMenu) { await page.click('#menu a:has-text("Publicações Webjur")'); await page.waitForTimeout(300); }
  check('Colaborador: área restrita (sem dados de publicações)', 'true',
    !temMenu || /restrita ao administrador/.test(await page.textContent('#conteudo')));

  check('Sem erros de console', '', erros.join(' | '));
  check('Sem respostas HTTP de erro', '', falhasHttp.join(' | '));
  await browser.close();

  const w = Math.max(...res.map(x => x[0].length));
  const txt = res.map(([n, e, o, s]) => `${s.padEnd(5)} | ${n.padEnd(w)} | esperado: ${e.slice(0, 50)} | obtido: ${o.slice(0, 50)}`).join('\n')
    + `\n\n${res.filter(x => x[3] === 'OK').length}/${res.length} OK — executado em ${new Date().toLocaleString('pt-BR')}`;
  console.log(txt);
  process.exit(res.every(x => x[3] === 'OK') ? 0 : 1);
})().catch(e => { console.error(e); process.exit(1); });
