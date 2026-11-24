/* Teste ponta a ponta — Relatórios gerenciais com pizzas (0056). Usa o banco do tests/test_etapa16.py rodado com MANTER=1
 * (dados FICTÍCIOS). Compara o que a TELA mostra (fatias, legenda, indicadores) com o que o BANCO calcula. */
'use strict';
const { chromium } = require('playwright');
const { execFileSync, spawn } = require('child_process');
const fs = require('fs');
const path = require('path');

const DB = process.env.DB || 'ctrl_etapa16', PORTA = 8797, BASE = `http://127.0.0.1:${PORTA}/painel/`;
const SAIDA = path.join(__dirname, 'out'); fs.mkdirSync(SAIDA, { recursive: true });
const res = [];
const norm = v => typeof v === 'object' ? JSON.stringify(v) : String(v);
const check = (n, e, o) => res.push([n, norm(e), norm(o), norm(e) === norm(o) ? 'OK' : 'FALHA']);
const psql = sql => execFileSync('psql', ['-h', '/tmp', '-p', '5433', '-U', 'postgres', '-At', '-q', '-v', 'ON_ERROR_STOP=1', '-d', DB, '-c', sql], { encoding: 'utf8' }).trim();
const comoUsuario = (uid, sql) => psql(`set role authenticated; set request.jwt.claim.sub = '${uid}'; ${sql}`).split('\n').pop();
const ADMIN = '00000000-0000-0000-0000-00000000000a';
const AREAS = ['diretoria', 'visao-geral', 'colaboradores', 'prazos', 'reagendamentos', 'tratativa', 'audiencias', 'minha-pauta', 'solicitacoes',
  'atlas', 'cadastro-atlas', 'intimacoes-cnj', 'publicacoes', 'inconsistencias', 'analise', 'importacao', 'double-check', 'auditoria', 'configuracoes'];
let srv = null;
process.on('exit', () => { if (srv) srv.kill(); });

(async () => {
  srv = spawn(process.execPath, [path.join(__dirname, 'servidor_local.js')], { env: { ...process.env, PORTA: String(PORTA), DB }, stdio: ['ignore', 'pipe', 'inherit'] });
  await new Promise(ok => srv.stdout.once('data', ok));
  const browser = await chromium.launch();
  const ctxNav = await browser.newContext({ viewport: { width: 1360, height: 900 } });
  const page = await ctxNav.newPage();
  const erros = []; page.on('console', m => { if (m.type() === 'error') erros.push(m.text()); }); page.on('pageerror', e => erros.push(e.message));
  const tela = (n, loc) => (loc || page).screenshot({ path: path.join(SAIDA, n + '.png'), ...(loc ? {} : { fullPage: true }) });
  async function entrar(email, senha) {
    await page.goto(BASE); await page.fill('#login-email', email); await page.fill('#login-senha', senha); await page.click('#btn-entrar');
    await page.waitForSelector('#tela-app:not([hidden])');
  }
  const sair = async () => { await page.click('#btn-sair'); await page.waitForSelector('#tela-login:not([hidden])'); };
  const abrirRel = async area => {
    await page.goto(BASE + '#/' + area); await page.waitForSelector('#conteudo details.relatorio');
    await page.click('#conteudo details.relatorio > summary');
    await page.waitForSelector('#conteudo details.relatorio .graficos, #conteudo details.relatorio .aviso-erro');
  };

  // ------------------------------------------------ controladoria
  await entrar('admin.teste@exemplo.invalid', 'senha-admin-teste');
  await abrirRel('audiencias');
  const rel = page.locator('#conteudo details.relatorio');
  check('Bloco logo abaixo do título da área', true, await page.evaluate(() => {
    const d = document.querySelector('#conteudo details.relatorio'); let p = d.previousElementSibling;
    while (p && p.matches('p')) p = p.previousElementSibling; return !!p && p.tagName === 'H1';
  }));
  const banco = JSON.parse(comoUsuario(ADMIN, "select relatorio_gerencial('audiencias')"));
  check('Uma pizza por gráfico do banco', banco.graficos.length, await rel.locator('section.grafico').count());
  check('Indicadores iguais ao banco', banco.indicadores.map(k => String(k.valor)),
    await rel.locator('.relatorio-kpis .kpi-valor').allTextContents());
  const g0 = banco.graficos.find(g => g.titulo === 'Por situação');
  const card = rel.locator('section.grafico').filter({ has: page.locator('h3:text-is("Por situação")') });
  check('Pizza "Por situação": uma fatia por item', g0.itens.length, await card.locator('svg .fatia').count());
  check('Legenda com as quantidades do banco', g0.itens.map(i => String(i.valor)), await card.locator('.legenda-valor').allTextContents());
  check('Rótulos traduzidos (agendada → Agendada)', true, (await card.locator('.legenda-rotulo').allTextContents()).includes('Agendada'));
  const pcts = (await card.locator('.legenda-pct').allTextContents()).map(t => parseFloat(t.replace(',', '.')));
  check('Percentuais somam ~100%', true, Math.abs(pcts.reduce((s, x) => s + x, 0) - 100) < 0.5);
  check('Total da pizza = banco', 'Total: ' + g0.total, (await card.locator('.pizza-total').textContent()).trim());
  check('Etiqueta "Situação atual"', 'Situação atual', (await card.locator('.etiqueta-base').textContent()).trim());
  check('Pizza tem descrição acessível (aria-label)', true, /Agendada \d+/.test(await card.locator('svg.pizza').getAttribute('aria-label')));
  // espaço de 2px entre fatias (contorno na cor da superfície)
  check('Contorno de 2px entre as fatias', '2px', await card.locator('svg .fatia').first().evaluate(e => getComputedStyle(e).strokeWidth));
  check('Cores na ordem da paleta (1ª fatia = azul #2a78d6)', 'rgb(42, 120, 214)', await card.locator('svg .fatia').first().evaluate(e => getComputedStyle(e).fill));
  // dica ao passar o mouse
  await card.locator('svg .fatia').first().dispatchEvent('mousemove', { clientX: 300, clientY: 300 });
  await page.waitForSelector('.dica-grafico:not([hidden])');
  check('Dica ao passar o mouse mostra item, quantidade e %', true, /^.+: \d+ \(\d+(,\d)?%\)$/.test((await page.textContent('.dica-grafico')).trim()));
  // tabela
  await card.locator('summary:text-is("Ver tabela")').click();
  check('Tabela com todos os itens', g0.itens.length, await card.locator('.pizza-tabela tbody tr').count());
  await tela('60_relatorio_audiencias', rel);

  // até 6 fatias: o resto vira "Outros"
  const f = await page.evaluate(() => window.Relatorios.fatias([1, 2, 3, 4, 5, 6, 7, 8].map(i => ({ rotulo: 'R' + i, valor: i }))));
  check('Mais de 6 itens: 5 maiores + "Outros (3)"', 'R8,R7,R6,R5,R4,Outros (3)|6', f.map(x => x.rotulo).join(',') + '|' + f.find(x => x.outros).valor);
  check('"Outros" na cor neutra', 'fatia-outros', f[5].cls);

  // período: atalho de 7 dias muda o "no período"
  await rel.locator('button:text-is("90 dias")').click();
  await page.waitForFunction(() => /Período: /.test(document.querySelector('.relatorio-periodo')?.textContent || ''));
  const de90 = psql("select to_char(hoje_brasilia() - 90, 'DD/MM/YYYY')");
  await page.waitForFunction(d => document.querySelector('.relatorio-periodo').textContent.includes(d), de90);
  check('Atalho "90 dias" refaz o relatório', true, (await rel.locator('.relatorio-periodo').textContent()).includes(de90));
  // período inválido mostra o erro do banco
  await rel.locator('input[aria-label="Início do período"]').fill('2026-11-10'); await rel.locator('input[aria-label="Fim do período"]').fill('2026-11-01');
  await rel.locator('button:text-is("Atualizar")').click();
  await page.waitForSelector('#conteudo details.relatorio .aviso-erro');
  check('Período invertido: aviso do banco', true, /anterior ao início/.test(await rel.locator('.aviso-erro').textContent()));

  // todas as áreas abertas para a controladoria mostram o relatório sem erro
  let semErro = 0;
  for (const a of AREAS) {
    await abrirRel(a);
    if (await page.locator('#conteudo details.relatorio .aviso-erro').count() === 0 && await page.locator('#conteudo details.relatorio section.grafico').count() >= 2) semErro++;
    else console.log('área com problema:', a);
  }
  check('As 19 áreas mostram o relatório com pizzas', AREAS.length, semErro);
  await abrirRel('diretoria'); await tela('61_relatorio_diretoria');

  // impressão: só o relatório aparece
  await abrirRel('inconsistencias');
  await page.evaluate(() => { window.print = () => { window.__impresso = { classe: document.body.classList.contains('imprimindo-relatorio') }; }; });
  await page.click('#conteudo details.relatorio button:text-is("Imprimir / PDF")');
  check('Imprimir marca a página para imprimir só o relatório', true, await page.evaluate(() => window.__impresso && window.__impresso.classe));
  await page.emulateMedia({ media: 'print' });
  check('Na impressão o menu some', 'none', await page.locator('#menu').evaluate(e => getComputedStyle(e).display));
  check('Na impressão o cabeçalho do relatório aparece', true, /período de .* gerado em/.test(await page.locator('.relatorio-impresso .relatorio-imp-cab').textContent()));
  await tela('62_relatorio_impressao');
  await page.evaluate(() => window.dispatchEvent(new Event('afterprint')));
  await page.emulateMedia({ media: 'screen' });
  check('Depois de imprimir a tela volta ao normal', false, await page.evaluate(() => document.body.classList.contains('imprimindo-relatorio')));

  // modo escuro: paleta do escuro
  await page.emulateMedia({ colorScheme: 'dark' });
  await abrirRel('audiencias');
  check('Modo escuro: 1ª fatia no azul do escuro (#3987e5)', 'rgb(57, 135, 229)', await page.locator('#conteudo svg .fatia').first().evaluate(e => getComputedStyle(e).fill));
  await tela('63_relatorio_escuro', page.locator('#conteudo details.relatorio'));
  await page.emulateMedia({ colorScheme: 'light' });
  await sair();

  // ------------------------------------------------ diretoria lê; peticionador não vê o bloco
  await entrar('diretoria.teste@exemplo.invalid', 'senha-diretoria-teste');
  await abrirRel('diretoria');
  check('Diretoria vê o relatório', true, await page.locator('#conteudo details.relatorio section.grafico').count() >= 2);
  await sair();
  await entrar('colab.teste@exemplo.invalid', 'senha-colab-teste');
  await page.goto(BASE + '#/minha-pauta'); await page.waitForSelector('#conteudo h1'); await page.waitForTimeout(400);
  check('Peticionador não vê o relatório gerencial', 0, await page.locator('#conteudo details.relatorio').count());
  await sair();

  // celular: sem rolagem horizontal
  await page.setViewportSize({ width: 390, height: 844 });
  await entrar('admin.teste@exemplo.invalid', 'senha-admin-teste');
  await abrirRel('audiencias');
  check('Celular: sem rolagem horizontal', true, await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1));
  await tela('64_relatorio_celular');

  check('Sem erros no console', '[]', JSON.stringify(erros.filter(e => !/Failed to load resource/.test(e))));
  await browser.close();
  for (const [n, e, o, s] of res) if (s !== 'OK') console.log(`FALHA: ${n}\n  esperado: ${e}\n  obtido:   ${o}`);
  console.log(`${res.filter(r => r[3] === 'OK').length}/${res.length} OK`);
  process.exit(0);
})().catch(e => { console.error(e); process.exit(1); });
