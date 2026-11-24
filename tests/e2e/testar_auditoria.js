/* Teste ponta a ponta — Etapa 9 (áreas "Histórico de auditoria" e "Configurações administrativas").
 * Banco LOCAL novo (todas as migrações, RLS real) + servidor_local.js + Chromium. Dados FICTÍCIOS:
 * publicações dos e-mails fictícios da Etapa 6 e intimações no formato que a extensão envia. */
'use strict';
const { chromium } = require('playwright');
const { execFileSync, spawn } = require('child_process');
const fs = require('fs'), path = require('path'), crypto = require('crypto');
const DB = 'ctrl_e2e_au', PORTA = 8794, BASE = `http://127.0.0.1:${PORTA}/painel/`;
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
        insert into auth.users (id, email) values ('${ADMIN}','admin.teste@exemplo.invalid'),('00000000-0000-0000-0000-00000000000c','colab.teste@exemplo.invalid');
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

  await entrar('admin.teste@exemplo.invalid', 'senha-admin-teste');
  // ---------------------------------------------------------------- área 11: configurações
  await page.click('#menu a:has-text("Configurações administrativas")');
  await page.waitForSelector('#cf-param-resumo');
  check('Configurações: parâmetros provisórios aparecem primeiro, marcados', 'Provisório', (await page.textContent('#cf-param tbody tr:first-child td:first-child')).trim());
  await page.waitForSelector('#cf-usuarios table');
  check('Usuários: as duas contas listadas com o papel', 'true', /admin\.teste@exemplo\.invalid[\s\S]*Administradora/.test(await page.textContent('#cf-usuarios')) && /colab\.teste@exemplo\.invalid/.test(await page.textContent('#cf-usuarios')));
  await tela('au_01_configuracoes');
  // alterar parâmetro numérico provisório
  const linha = page.locator('#cf-param tbody tr', { hasText: 'alerta_dias_uteis_proximo' });
  await linha.locator('button.cf-editar').click();
  await page.waitForSelector('#cf-valor');
  await page.fill('#cf-valor', '3'); await page.check('#cf-confirmado');
  await page.fill('#cf-motivo', 'curto'); await page.click('#cf-salvar');
  await page.waitForSelector('dialog.detalhe .aviso-erro');
  check('Alterar parâmetro sem motivo suficiente: recusado com mensagem', 'true', /motivo/i.test(await page.textContent('dialog.detalhe .aviso-erro')));
  await page.fill('#cf-motivo', 'Decisão de teste da coordenação'); await page.click('#cf-salvar');
  await page.waitForFunction(() => !document.querySelector('dialog.detalhe').open);
  check('Parâmetro alterado e confirmado no banco', '3|t', comoAdmin("select valor::text||'|'||confirmado::text::char from parametros where chave='alerta_dias_uteis_proximo'"));
  // retirar o próprio acesso: recusado
  const minha = page.locator('#cf-usuarios tbody tr', { hasText: 'admin.teste@exemplo.invalid' });
  await minha.locator('select.cf-papel').selectOption(''); await minha.locator('input.cf-motivo-perfil').fill('teste de remoção do próprio acesso');
  await minha.locator('button:text-is("Salvar")').click();
  await page.waitForSelector('#cf-usuarios-saida .aviso-erro');
  check('Administradora não consegue retirar o próprio acesso', 'true', /próprio/.test(await page.textContent('#cf-usuarios-saida')));
  // calendário: incluir e remover
  await page.fill('#cf-cal-data', '2026-11-26'); await page.selectOption('#cf-cal-abr', 'tribunal'); await page.fill('#cf-cal-trib', '8.13');
  await page.selectOption('#cf-cal-tipo', 'recesso'); await page.fill('#cf-cal-desc', 'Recesso fictício de teste'); await page.fill('#cf-cal-fund', 'Portaria fictícia 1/2026');
  await page.click('#cf-cal-incluir');
  await page.waitForFunction(() => /Recesso fictício de teste/.test(document.querySelector('#cf-cal').textContent));
  await page.click('#cf-cal-lista summary');
  const dia = page.locator('#cf-cal tbody tr', { hasText: 'Recesso fictício de teste' });
  await dia.locator('input').fill('Incluído só para o teste'); await dia.locator('button:text-is("Remover")').click();
  await page.waitForFunction(() => !/Recesso fictício de teste/.test(document.querySelector('#cf-cal table').textContent));
  check('Calendário: dia incluído e removido pelo painel', '0', comoAdmin("select count(*) from calendario_dias_nao_uteis where descricao='Recesso fictício de teste'"));
  // ---------------------------------------------------------------- área 10: histórico
  await page.click('#menu a:has-text("Histórico de auditoria")');
  await page.waitForSelector('#au-total');
  const txt = await page.textContent('#au-resultado');
  check('Histórico mostra as alterações feitas agora (parâmetro com motivo, calendário)', 'true',
    /alerta_dias_uteis_proximo/.test(txt) && /Decisão de teste da coordenação|Configuração/.test(txt) && /Remoção de calendário/.test(txt));
  check('Histórico mostra publicações e conferências do double check', 'true', /Publicação recebida/.test(txt) && /Conferência no ADVBOX/.test(txt));
  await tela('au_02_historico');
  await page.selectOption('#au-cat', 'configuracao'); await page.click('#au-consultar');
  await page.waitForFunction(() => /registro/.test(document.querySelector('#au-total')?.textContent || ''));
  const cats = await page.$$eval('#au-resultado tbody tr td:nth-child(2)', tds => [...new Set(tds.map(t => t.textContent.trim()))]);
  check('Filtro por categoria: só configuração', 'Configuração', cats.join(','));
  await page.click('#au-resultado tbody tr:first-child button:text-is("Ver")');
  await page.waitForSelector('dialog.detalhe pre');
  const det = await page.textContent('dialog.detalhe[open]');
  check('Detalhe da última alteração (remoção do dia): valor anterior e motivo', 'true', /Antes/.test(det) && /Motivo/.test(det) && /Incluído só para o teste/.test(det));
  await tela('au_03_detalhe');
  await page.click('dialog.detalhe[open] button:text-is("Fechar")');
  const [dl] = await Promise.all([page.waitForEvent('download'), page.click('#au-csv')]);
  const csv = fs.readFileSync(await dl.path(), 'utf8');
  check('Exportação CSV com cabeçalho e linhas', 'true', /^﻿?quando;categoria;tipo/.test(csv) && csv.split('\r\n').length > 2);
  await page.click('#au-integridade');
  await page.waitForSelector('#au-int table');
  check('Integridade: verificação roda e mostra a tabela', 'true', /Tabela do esquema público sem RLS/.test(await page.textContent('#au-int')));
  await tela('au_04_integridade');
  // ---------------------------------------------------------------- colaborador
  await page.click('#btn-sair').catch(() => {});
  await entrar('colab.teste@exemplo.invalid', 'senha-colab-teste');
  const etiq = await page.textContent('#menu');
  check('Colaborador: as áreas 10 e 11 aparecem bloqueadas (admin)', 'true', /Histórico de auditoria\s*admin/.test(etiq) && /Configurações administrativas\s*admin/.test(etiq));
  check('Sem erros de console', '', erros.filter(e => !/400/.test(e)).join(' | '));
  check('Sem respostas HTTP de erro inesperadas', '', http.filter(x => !/^400 rpc\/(admin_definir_parametro|admin_definir_perfil)/.test(x)).join(' | '));
  await browser.close();
  const w = Math.max(...res.map(r => r[0].length));
  for (const [nn, e, o, s] of res) console.log(`${s.padEnd(5)} ${nn.padEnd(w)}` + (s === 'OK' ? '' : `  esperado=${e} obtido=${o}`));
  const ok = res.filter(r => r[3] === 'OK').length; console.log(`\n${ok}/${res.length} OK`); process.exit(ok === res.length ? 0 : 1);
})().catch(e => { console.error(e); process.exit(1); });
