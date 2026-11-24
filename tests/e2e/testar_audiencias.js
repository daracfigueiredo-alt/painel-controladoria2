/* Teste ponta a ponta — Painel de audiências (0051). Usa o banco do tests/test_etapa16.py rodado com MANTER=1
 * (dados FICTÍCIOS). Compara o que a TELA mostra com o que o BANCO calcula. */
'use strict';
const { chromium } = require('playwright');
const { execFileSync, spawn } = require('child_process');
const fs = require('fs');
const path = require('path');

const DB = process.env.DB || 'ctrl_etapa16', PORTA = 8796, BASE = `http://127.0.0.1:${PORTA}/painel/`;
const SAIDA = path.join(__dirname, 'out'); fs.mkdirSync(SAIDA, { recursive: true });
const res = [];
const check = (n, e, o) => res.push([n, String(e), String(o), String(e) === String(o) ? 'OK' : 'FALHA']);
const psql = sql => execFileSync('psql', ['-h', '/tmp', '-p', '5433', '-U', 'postgres', '-At', '-q', '-v', 'ON_ERROR_STOP=1', '-d', DB, '-c', sql], { encoding: 'utf8' }).trim();
const comoUsuario = (uid, sql) => psql(`set role authenticated; set request.jwt.claim.sub = '${uid}'; ${sql}`).split('\n').pop();
const ADMIN = '00000000-0000-0000-0000-00000000000a';
let srv = null;
process.on('exit', () => { if (srv) srv.kill(); });

(async () => {
  // um processo novo, com audiência sem data, para completar pela tela
  psql(`insert into cnj_comunicacoes (id, cnj, numero_processo, data_disponibilizacao, texto, nome_orgao, link, dados)
        values (99, '0009999-30.2026.8.13.0024', '0009999-30.2026.8.13.0024', hoje_brasilia(), 'AUDIÊNCIA DE CONCILIAÇÃO DESIGNADA. Acesse o sistema', 'Vara E2E', null, '{}')
        on conflict (id) do nothing`);
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
  const kpi = async rot => (await page.locator(`.kpi:has(.kpi-rotulo:text-is("${rot}")) .kpi-valor`).textContent()).trim();
  const painel = uid => JSON.parse(comoUsuario(uid, "select audiencias_painel(null, null, null, null, null)"));

  // ------------------------------------------------ controladoria
  await entrar('admin.teste@exemplo.invalid', 'senha-admin-teste');
  check('Menu: Audiências no grupo Acompanhamento', '1', await page.locator('#menu .menu-grupo[aria-labelledby="menu-g-geral"] a[href="#/audiencias"]').count());
  await page.goto(BASE + '#/audiencias'); await page.waitForSelector('#conteudo .kpis');
  await page.click('#conteudo button:text-is("Ler intimações agora")');
  await page.waitForSelector('#conteudo .aviso-ok');
  check('Leitura pela tela acha a audiência nova', true, /1 audiência\(s\) nova\(s\)/.test(await page.textContent('#conteudo .aviso-ok')));
  await page.waitForSelector('#conteudo .audiencia');
  let p = painel(ADMIN);
  check('Agenda mostra as audiências do banco', p.itens.length, await page.locator('#conteudo .audiencia').count());
  check('Indicador "Sem data na intimação" igual ao banco', p.contagem.sem_data, await kpi('Sem data na intimação'));
  check('Indicador "Sem tarefa no Atlas" igual ao banco', p.contagem.sem_tarefa_atlas, await kpi('Sem tarefa no Atlas'));
  check('Grupo "Sem data" vem primeiro', 'Sem data na intimação (completar)', (await page.locator('#conteudo section.cartao h2').first().textContent()).trim());
  await tela('50_audiencias_agenda');

  // completar a data da audiência sem data
  const sem = page.locator('#conteudo section.cartao-alerta .audiencia').filter({ hasText: '0009999-30.2026.8.13.0024' });
  await sem.locator('summary:text-is("Completar a data")').click();
  const dia = psql("select (hoje_brasilia() + 40)::text");
  await sem.locator('input[type=date]').fill(dia); await sem.locator('input[type=time]').fill('10:30');
  await sem.locator('input[aria-label=Motivo]').fill('Data conferida no processo pela controladoria');
  await sem.locator('details:has(summary:text-is("Completar a data")) button:text-is("Salvar")').click();
  await page.waitForSelector('#conteudo .aviso-ok:text("Audiência corrigida.")');
  check('Data completada pela tela (banco)', `${dia}|10:30`, psql("select data||'|'||hora from audiencias where cnj='0009999-30.2026.8.13.0024'"));

  // designar advogado pela tela
  await page.waitForSelector('#conteudo .audiencia');
  const alvo = page.locator('#conteudo .audiencia').filter({ hasText: '0009999-30.2026.8.13.0024' });
  await alvo.locator('summary:text-is("Designar advogado/preposto")').click();
  await alvo.locator('select[aria-label=Advogado]').selectOption({ label: 'OUTRO' });
  await alvo.locator('input[aria-label=Preposto]').fill('Preposto E2E');
  await alvo.locator('details:has(summary:text-is("Designar advogado/preposto")) button:text-is("Salvar")').click();
  await page.waitForSelector('#conteudo .aviso-ok:text("Designação salva.")');
  check('Advogado e preposto designados pela tela (banco)', 'OUTRO|Preposto E2E',
        psql("select c.nome_advbox||'|'||a.preposto from audiencias a join colaboradores c on c.id=a.advogado_id where a.cnj='0009999-30.2026.8.13.0024'"));
  // filtro por pendência
  await page.click('.kpi:has(.kpi-rotulo:text-is("Sem ata/resultado"))');
  await page.waitForFunction(() => document.querySelector('.kpi-ativo .kpi-rotulo')?.textContent === 'Sem ata/resultado');
  check('Filtro pela pendência (banco)', JSON.parse(comoUsuario(ADMIN, "select audiencias_painel(null, null, null, 'sem_ata', null)")).itens.length,
        await page.locator('#conteudo .audiencia').count());
  await tela('51_audiencias_pendencia');
  await sair();

  // ------------------------------------------------ diretoria: lê, não altera
  await entrar('diretoria.teste@exemplo.invalid', 'senha-diretoria-teste');
  await page.goto(BASE + '#/audiencias'); await page.waitForSelector('#conteudo .audiencia');
  check('Diretoria vê a agenda inteira', p.itens.length + 0, await page.locator('#conteudo .audiencia').count());
  check('Diretoria não tem botões de alteração', '0|0|0', `${await page.locator('button:text-is("Ler intimações agora")').count()}|${await page.locator('summary:text-is("Designar advogado/preposto")').count()}|${await page.locator('summary:text-is("Registrar ata e resultado")').count()}`);
  await sair();
  // ------------------------------------------------ peticionador: só as suas
  await entrar('colab.teste@exemplo.invalid', 'senha-colab-teste');
  await page.goto(BASE + '#/audiencias'); await page.waitForSelector('#conteudo .kpis');
  check('Peticionador vê só as audiências em que foi designado', '1', await page.locator('#conteudo .audiencia').count());
  check('Sem erros no console', '[]', JSON.stringify(erros.filter(e => !/401|403|Failed to load resource/.test(e))));

  await browser.close();
  const ok = res.filter(r => r[3] === 'OK').length;
  for (const [n, e, o, s] of res) console.log(`${s.padEnd(5)} ${n}` + (s === 'OK' ? '' : `\n      esperado: ${e}\n      obtido:   ${o}`));
  console.log(`\n${ok}/${res.length} OK — executado em ${new Date().toLocaleString('pt-BR')}`);
  process.exit(ok === res.length ? 0 : 1);
})().catch(e => { console.error(e); process.exit(1); });
