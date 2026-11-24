/* Teste ponta a ponta — reagendamento pedido pelo peticionador (0058, 17/11/2026). Usa o banco do
 * tests/test_etapa18.py rodado com MANTER=1 (dados FICTÍCIOS). Nenhuma chamada ao Atlas real. */
'use strict';
const { chromium } = require('playwright');
const { execFileSync, spawn } = require('child_process');
const fs = require('fs');
const path = require('path');

const DB = process.env.DB || 'ctrl_etapa18', PORTA = 8796, BASE = `http://127.0.0.1:${PORTA}/painel/`;
const SAIDA = path.join(__dirname, 'out'); fs.mkdirSync(SAIDA, { recursive: true });
const res = [];
const check = (n, e, o) => res.push([n, String(e), String(o), String(e) === String(o) ? 'OK' : 'FALHA']);
const psql = sql => execFileSync('psql', ['-h', '/tmp', '-p', '5433', '-U', 'postgres', '-At', '-q', '-v', 'ON_ERROR_STOP=1', '-d', DB, '-c', sql], { encoding: 'utf8' }).trim();
const du = n => psql(`select somar_dias_uteis(hoje_brasilia(), ${n})`);
let srv = null;
process.on('exit', () => { if (srv) srv.kill(); });

(async () => {
  srv = spawn(process.execPath, [path.join(__dirname, 'servidor_local.js')], { env: { ...process.env, PORTA: String(PORTA), DB }, stdio: ['ignore', 'pipe', 'inherit'] });
  await new Promise(ok => srv.stdout.once('data', ok));
  const browser = await chromium.launch();
  const page = await (await browser.newContext({ viewport: { width: 1360, height: 900 } })).newPage();
  const erros = []; page.on('pageerror', e => erros.push(e.message));
  page.on('console', m => { if (m.type() === 'error' && !/Failed to load resource|functions\/v1/.test(m.text())) erros.push(m.text()); });
  async function entrar(email, senha) {
    await page.goto(BASE); await page.fill('#login-email', email); await page.fill('#login-senha', senha); await page.click('#btn-entrar');
    await page.waitForSelector('#tela-app:not([hidden])');
  }
  const sair = async () => { await page.click('#btn-sair'); await page.waitForSelector('#tela-login:not([hidden])'); };
  const antes = Number(psql('select count(*) from solicitacoes'));

  // ------------------------------------------------ peticionador: pede pela Minha pauta
  await entrar('colab.teste@exemplo.invalid', 'senha-colab-teste');
  await page.goto(BASE + '#/minha-pauta'); await page.waitForSelector('.pauta-item');
  const cartao = page.locator('.pauta-item').filter({ hasText: 'Contestar ação revisional' });
  await cartao.locator('summary').first().click();
  await cartao.locator('details.pedido-reagendamento > summary').click();
  const form = cartao.locator('.form-reagendamento');
  await form.waitFor();
  check('Minha pauta: formulário de pedido na tarefa do Atlas', 'true', /Quem decide: o líder da sua equipe/.test(await form.textContent()));
  await form.locator('input[type=date]').fill(du(10)); await form.locator('input[type=date]').dispatchEvent('input');
  check('Nova data depois do D-4: o formulário avisa que decide a controladoria', 'true', /quem decide é a controladoria/.test(await form.textContent()));
  await form.locator('input[type=date]').fill(du(3)); await form.locator('input[type=date]').dispatchEvent('input');
  await form.locator('textarea').fill('curta');
  await form.locator('button:text-is("Pedir reagendamento")').click();
  await form.locator('.erro:not(:empty)').waitFor();
  check('Justificativa curta: o banco recusa e a tela mostra', 'true', /Justificativa obrigatória/.test(await form.locator('.erro').textContent()));
  await form.locator('textarea').fill('Aguardando os extratos do cliente para a contestação');
  await form.locator('button:text-is("Pedir reagendamento")').click();
  await cartao.locator('.form-reagendamento .aviso').waitFor();
  check('Pedido enviado: aguardando o líder', 'true', /Aguardando o líder/.test(await cartao.locator('.form-reagendamento .aviso').textContent()));
  await page.screenshot({ path: path.join(SAIDA, '70_reagendamento_peticionador.png'), fullPage: false });
  const pedido = JSON.parse(psql(`select to_jsonb(s) from solicitacoes s order by id desc limit 1`));
  check('Banco: pedido do peticionador com a nova data', `${antes + 1}|aguardando_lider|${du(3)}|colaborador`,
    `${psql('select count(*) from solicitacoes')}|${pedido.status}|${pedido.dados.nova_data}|${pedido.solicitante_papel}`);

  // na tela de solicitações: vê o próprio pedido, pode cancelar, não decide
  await page.goto(BASE + '#/solicitacoes'); await page.waitForSelector('#conteudo table');
  check('Solicitações: formulário "Pedir reagendamento" para o peticionador', 'true', await page.locator('#conteudo h2:text-is("Pedir reagendamento")').count() === 1);
  const linha = page.locator('#conteudo tr').filter({ hasText: `${pedido.id}` }).filter({ hasText: 'Aguardando o líder' });
  check('Peticionador vê o pedido com "Aguardando o líder" e o botão Cancelar, sem Aprovar', '1|1|0',
    `${await linha.count()}|${await linha.locator('button:text-is("Cancelar")').count()}|${await linha.locator('button:text-is("Aprovar")').count()}`);
  await sair();

  // ------------------------------------------------ líder: analisa e aprova
  await entrar('lider.teste@exemplo.invalid', 'senha-lider-teste');
  await page.goto(BASE + '#/solicitacoes'); await page.waitForSelector('#conteudo table');
  const linhaL = page.locator('#conteudo tr').filter({ hasText: 'Aguardando os extratos do cliente' });
  check('Líder vê o pedido da equipe com Analisar, Aprovar e Recusar', '1|1|1',
    `${await linhaL.locator('button:text-is("Analisar a pauta")').count()}|${await linhaL.locator('button:text-is("Aprovar")').count()}|${await linhaL.locator('button:text-is("Recusar")').count()}`);
  await linhaL.locator('button:text-is("Analisar a pauta")').click();
  await linhaL.locator('p.sutil', { hasText: 'Pauta em' }).waitFor();
  check('Análise da pauta mostrada para quem decide', 'true', /capacidade/.test(await linhaL.locator('p.sutil', { hasText: 'Pauta em' }).textContent()));
  await page.screenshot({ path: path.join(SAIDA, '71_reagendamento_lider.png'), fullPage: false });
  await linhaL.locator('button:text-is("Aprovar")').click();
  await linhaL.locator('textarea').fill('Pauta da equipe comporta a nova data');
  await linhaL.locator('button:text-is("Confirmar aprovação")').click();
  await page.waitForFunction(id => true, pedido.id); await page.waitForTimeout(1500);
  // aprovado; a execução no Atlas usa a Edge Function, que não existe no servidor local (a lista mostra "Executar no Atlas")
  check('Líder aprova: banco registra a decisão do líder', 'true|Líder: Pauta da equipe comporta a nova data',
    psql(`select (status in ('aprovada','em_execucao','falhou'))::text || '|' || (select nota from solicitacoes_historico h where h.solicitacao_id = s.id and h.status_para = 'aprovada') from solicitacoes s where id = ${pedido.id}`).replace(/^t\|/, 'true|'));
  await sair();

  check('Sem erros no console', '[]', JSON.stringify(erros));
  await browser.close();
  for (const [n, e, o, s] of res) if (s !== 'OK') console.log(`FALHA: ${n}\n  esperado: ${e}\n  obtido:   ${o}`);
  console.log(`${res.filter(r => r[3] === 'OK').length}/${res.length} OK`);
  process.exit(0);
})().catch(e => { console.error(e); process.exit(1); });
