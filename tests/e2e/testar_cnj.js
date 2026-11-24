/* Teste ponta a ponta — Intimações CNJ e double check CNJ × Webjur (0044). Usa o banco do tests/test_etapa14.py
 * (dados FICTÍCIOS): rode aquele teste antes. Compara o que a TELA mostra com o que o BANCO calcula.
 * Não chama a API do CNJ (os botões de consulta só são conferidos quanto a quem os vê). */
'use strict';
const { chromium } = require('playwright');
const { execFileSync, spawn } = require('child_process');
const fs = require('fs');
const path = require('path');

const DB = process.env.DB || 'ctrl_etapa14', PORTA = 8794, BASE = `http://127.0.0.1:${PORTA}/painel/`;
const SAIDA = path.join(__dirname, 'out'); fs.mkdirSync(SAIDA, { recursive: true });
const res = [];
const check = (n, e, o) => res.push([n, String(e), String(o), String(e) === String(o) ? 'OK' : 'FALHA']);
const ADMIN = '00000000-0000-0000-0000-00000000000a';
const psql = sql => execFileSync('psql', ['-h', '/tmp', '-p', '5433', '-U', 'postgres', '-At', '-q', '-v', 'ON_ERROR_STOP=1', '-d', DB, '-c', sql], { encoding: 'utf8' }).trim();
let srv = null;
process.on('exit', () => { if (srv) srv.kill(); });

(async () => {
  srv = spawn(process.execPath, [path.join(__dirname, 'servidor_local.js')], { env: { ...process.env, PORTA: String(PORTA), DB }, stdio: ['ignore', 'pipe', 'inherit'] });
  await new Promise(ok => srv.stdout.once('data', ok));
  const browser = await chromium.launch();
  const page = await (await browser.newContext({ viewport: { width: 1360, height: 900 } })).newPage();
  const erros = []; page.on('console', m => { if (m.type() === 'error') erros.push(m.text()); }); page.on('pageerror', e => erros.push(e.message));
  const tela = n => page.screenshot({ path: path.join(SAIDA, n + '.png'), fullPage: true });
  async function entrar(email, senha) {
    await page.goto(BASE); await page.fill('#login-email', email); await page.fill('#login-senha', senha); await page.click('#btn-entrar');
    await page.waitForSelector('#tela-app:not([hidden])');
  }
  const sair = async () => { await page.click('#btn-sair'); await page.waitForSelector('#tela-login:not([hidden])'); };

  // ------------------------------------------------ controladoria
  await entrar('admin.teste@exemplo.invalid', 'senha-admin-teste');
  check('Menu: Intimações CNJ no grupo Publicações e intimações', '1',
        await page.locator('#menu .menu-grupo[aria-labelledby="menu-g-webjur"] a[href="#/intimacoes-cnj"]').count());
  await page.goto(BASE + '#/intimacoes-cnj'); await page.waitForSelector('#conteudo table');
  check('Título da área', 'Intimações CNJ', await page.textContent('#conteudo h1'));
  const total = psql("select count(*) from cnj_comunicacoes where data_disponibilizacao >= hoje_brasilia() - 7");
  const semWebjur = psql(`set role authenticated; set request.jwt.claims = '{"sub":"${ADMIN}"}'; select jsonb_array_length(cnj_painel(null,null,null,'sem_webjur',1000)->'itens')`).split('\n').pop();
  check('Tela mostra as comunicações dos últimos 7 dias (banco)', total, await page.locator('#conteudo tbody tr').count());
  check('Comunicações sem captura da Webjur marcadas (banco)', semWebjur, await page.locator('#conteudo tbody .tag-erro').count());
  check('Link da certidão no CNJ em cada comunicação', total, await page.locator('#conteudo tbody a:text-is("Certidão no CNJ")').count());
  check('Controladoria vê os botões de consulta', '3', await page.locator('#conteudo .acoes button').count());
  await tela('30_intimacoes_cnj');
  await page.selectOption('#conteudo .filtros-barra select', 'sem_webjur'); await page.click('#conteudo .filtros-barra button[type=submit]');
  await page.waitForFunction(n => document.querySelectorAll('#conteudo tbody tr').length === Number(n), semWebjur);
  check('Filtro "sem captura da Webjur" (banco)', semWebjur, await page.locator('#conteudo tbody tr').count());
  await page.fill('#conteudo input[type=search]', '0001004'); await page.selectOption('#conteudo .filtros-barra select', '');
  await page.click('#conteudo .filtros-barra button[type=submit]');
  await page.waitForFunction(() => document.querySelectorAll('#conteudo tbody tr').length === 1);
  check('Busca por processo', '1', await page.locator('#conteudo tbody tr').count());

  await page.goto(BASE + '#/inconsistencias'); await page.waitForSelector('#conteudo table');
  check('Double check: título', 'Double check de intimações', await page.textContent('#conteudo h1'));
  const capt = psql("select count(*) from inconsistencias where situacao='aberta' and tipo='captura_divergente'");
  check('Double check: indicador da captura CNJ × Webjur (banco)', capt,
        (await page.locator('.kpi:has(.kpi-rotulo:text-is("Captura divergente CNJ × Webjur")) .kpi-valor').textContent()).trim());
  check('Double check: botões do CNJ e da sincronização do Atlas (módulo ligado em 16/11)', '1|1',
        `${await page.locator('#conteudo button:text-is("Consultar o CNJ pela OAB")').count()}|${await page.locator('#conteudo button:text-is("Sincronizar intimações do Atlas")').count()}`);
  await tela('31_double_check_cnj');
  await sair();

  // ------------------------------------------------ diretoria: lê, não consulta
  await entrar('diretoria.teste@exemplo.invalid', 'senha-diretoria-teste');
  await page.goto(BASE + '#/intimacoes-cnj'); await page.waitForSelector('#conteudo table');
  check('Diretoria lê as intimações do CNJ', total, await page.locator('#conteudo tbody tr').count());
  check('Diretoria não vê os botões de consulta', '0', await page.locator('#conteudo .acoes button').count());
  await sair();
  // ------------------------------------------------ peticionador: área restrita
  await entrar('colab.teste@exemplo.invalid', 'senha-colab-teste');
  await page.goto(BASE + '#/intimacoes-cnj'); await page.waitForSelector('#conteudo h1');
  check('Peticionador não abre a área', 'false', String(await page.locator('#conteudo table').count() > 0));
  check('Sem erros no console', '[]', JSON.stringify(erros.filter(e => !/401|403|Failed to load resource/.test(e))));

  await browser.close();
  const ok = res.filter(r => r[3] === 'OK').length;
  for (const [n, e, o, s] of res) console.log(`${s.padEnd(5)} ${n}` + (s === 'OK' ? '' : `\n      esperado: ${e}\n      obtido:   ${o}`));
  console.log(`\n${ok}/${res.length} OK — executado em ${new Date().toLocaleString('pt-BR')}`);
  process.exit(ok === res.length ? 0 : 1);
})().catch(e => { console.error(e); process.exit(1); });
