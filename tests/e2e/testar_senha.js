/* Teste ponta a ponta — "Definir senha" em Configurações › Usuários (0062, 26/11/2026). Usa o banco do
 * tests/test_etapa20.py rodado com MANTER=1 (dados FICTÍCIOS). A Edge Function admin-senha é simulada
 * pelo navegador do teste (o servidor local não tem Edge Functions): confere o que a tela envia. */
'use strict';
const { chromium } = require('playwright');
const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');

const DB = process.env.DB || 'ctrl_etapa20', PORTA = 8797, BASE = `http://127.0.0.1:${PORTA}/painel/`;
const SAIDA = path.join(__dirname, 'out'); fs.mkdirSync(SAIDA, { recursive: true });
const res = [];
const check = (n, e, o) => res.push([n, String(e), String(o), String(e) === String(o) ? 'OK' : 'FALHA']);
let srv = null;
process.on('exit', () => { if (srv) srv.kill(); });

(async () => {
  srv = spawn(process.execPath, [path.join(__dirname, 'servidor_local.js')], { env: { ...process.env, PORTA: String(PORTA), DB }, stdio: ['ignore', 'pipe', 'inherit'] });
  await new Promise(ok => srv.stdout.once('data', ok));
  const browser = await chromium.launch();
  const page = await (await browser.newContext({ viewport: { width: 1360, height: 900 } })).newPage();
  const erros = []; page.on('pageerror', e => erros.push(e.message));
  const pedidos = []; let resposta = { status: 200, corpo: { ok: true, email: 'brendamartinsoecadv@gmail.com' } };
  await page.route('**/functions/v1/admin-senha', async rota => {
    pedidos.push({ corpo: JSON.parse(rota.request().postData()), auth: rota.request().headers().authorization || '' });
    await rota.fulfill({ status: resposta.status, contentType: 'application/json', body: JSON.stringify(resposta.corpo) });
  });
  await page.goto(BASE); await page.fill('#login-email', 'admin.teste@exemplo.invalid'); await page.fill('#login-senha', 'senha-admin-teste');
  await page.click('#btn-entrar'); await page.waitForSelector('#tela-app:not([hidden])');
  await page.goto(BASE + '#/configuracoes'); await page.waitForSelector('#cf-usuarios table');
  check('Texto explica que a senha é definida pela controladoria', 'true', /A senha é definida pela controladoria/.test(await page.locator('#cf-usuarios').textContent()));
  const linha = page.locator('#cf-usuarios tr').filter({ hasText: 'brendamartinsoecadv@gmail.com' });
  check('Brenda aparece como líder (0061)', 'true', /Líder/.test(await linha.textContent()));
  const caixa = linha.locator('details.cf-senha');
  await caixa.locator('summary').click();
  const [senha, conf] = [caixa.locator('input[type=password]').nth(0), caixa.locator('input[type=password]').nth(1)];
  const motivo = caixa.locator('input[type=text]'), salvar = caixa.locator('button:text-is("Salvar senha")'), msg = caixa.locator('.erro');

  await senha.fill('curta'); await conf.fill('curta'); await motivo.fill('Primeiro acesso da líder'); await salvar.click();
  check('Senha curta: a tela avisa e não envia', 'A senha precisa ter pelo menos 8 caracteres.|0', `${await msg.textContent()}|${pedidos.length}`);
  await senha.fill('Senha-Forte-2026'); await conf.fill('Senha-Forte-2027'); await salvar.click();
  check('Senhas diferentes: a tela avisa e não envia', 'As duas senhas não são iguais.|0', `${await msg.textContent()}|${pedidos.length}`);
  await conf.fill('Senha-Forte-2026'); await motivo.fill('curto'); await salvar.click();
  check('Motivo curto: a tela avisa e não envia', 'Informe o motivo (mínimo 10 caracteres).|0', `${await msg.textContent()}|${pedidos.length}`);

  await motivo.fill('Primeiro acesso da líder da Prime'); await salvar.click();
  await page.locator('#cf-usuarios-saida .aviso').waitFor();
  check('Enviado à função com conta, senha e motivo', `1|${JSON.stringify(['user_id', 'senha', 'motivo'])}|Senha-Forte-2026|Primeiro acesso da líder da Prime`,
    `${pedidos.length}|${JSON.stringify(Object.keys(pedidos[0].corpo))}|${pedidos[0].corpo.senha}|${pedidos[0].corpo.motivo}`);
  check('Enviado com o login da controladoria', 'true', /^Bearer ey/.test(pedidos[0].auth));
  check('Confirmação na tela', 'true', /senha definida/.test(await page.locator('#cf-usuarios-saida').textContent()));
  check('Campos limpos depois de salvar', '||', `${await senha.inputValue()}|${await conf.inputValue()}|${await motivo.inputValue()}`);
  await page.screenshot({ path: path.join(SAIDA, '80_definir_senha.png') });

  resposta = { status: 403, corpo: { erro: 'Somente a controladoria' } };
  await caixa.locator('summary').click();
  await senha.fill('Outra-Senha-2026'); await conf.fill('Outra-Senha-2026'); await motivo.fill('Teste de recusa pelo servidor'); await salvar.click();
  await msg.filter({ hasText: /\S/ }).waitFor();
  check('Recusa do servidor aparece na tela', 'Somente a controladoria', await msg.textContent());
  check('Sem erros de JavaScript', '0', erros.length + (erros.length ? ': ' + erros.join(' | ') : ''));

  await browser.close();
  for (const [n, e, o, s] of res) console.log(`[${s}] ${n}` + (s === 'OK' ? '' : `\n    esperado: ${e}\n    obtido:   ${o}`));
  const falhas = res.filter(r => r[3] !== 'OK').length; console.log(`\n${res.length - falhas}/${res.length} verificações OK`);
  process.exit(falhas ? 1 : 0);
})().catch(e => { console.error(e); process.exit(1); });
