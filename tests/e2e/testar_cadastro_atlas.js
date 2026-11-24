/* Teste ponta a ponta — Cadastro de processos no Atlas (0048). Usa o banco do tests/test_etapa15.py rodado com
 * MANTER=1 (dados FICTÍCIOS) e a planilha fictícia fixtures/processos_advbox_ficticio.xlsx.
 * Compara o que a TELA mostra com o que o BANCO calcula. Não chama o Atlas (os botões que chamam a Edge Function
 * só são conferidos quanto a quem os vê). */
'use strict';
const { chromium } = require('playwright');
const { execFileSync, spawn } = require('child_process');
const fs = require('fs');
const path = require('path');

const DB = process.env.DB || 'ctrl_etapa15', PORTA = 8795, BASE = `http://127.0.0.1:${PORTA}/painel/`;
const SAIDA = path.join(__dirname, 'out'); fs.mkdirSync(SAIDA, { recursive: true });
const PLANILHA = path.join(__dirname, 'fixtures', 'processos_advbox_ficticio.xlsx');
const res = [];
const check = (n, e, o) => res.push([n, String(e), String(o), String(e) === String(o) ? 'OK' : 'FALHA']);
const psql = sql => execFileSync('psql', ['-h', '/tmp', '-p', '5433', '-U', 'postgres', '-At', '-q', '-v', 'ON_ERROR_STOP=1', '-d', DB, '-c', sql], { encoding: 'utf8' }).trim();
let srv = null;
process.on('exit', () => { if (srv) srv.kill(); });
const P1 = '0007001', P2 = '0007002', P3 = '0007003';

(async () => {
  srv = spawn(process.execPath, [path.join(__dirname, 'servidor_local.js')], { env: { ...process.env, PORTA: String(PORTA), DB }, stdio: ['ignore', 'pipe', 'inherit'] });
  await new Promise(ok => srv.stdout.once('data', ok));
  const browser = await chromium.launch();
  const ctxB = await browser.newContext({ viewport: { width: 1360, height: 900 }, acceptDownloads: true });
  const page = await ctxB.newPage();
  const erros = []; page.on('console', m => { if (m.type() === 'error') erros.push(m.text()); }); page.on('pageerror', e => erros.push(e.message));
  const tela = n => page.screenshot({ path: path.join(SAIDA, n + '.png'), fullPage: true });
  async function entrar(email, senha) {
    await page.goto(BASE); await page.fill('#login-email', email); await page.fill('#login-senha', senha); await page.click('#btn-entrar');
    await page.waitForSelector('#tela-app:not([hidden])');
  }
  const sair = async () => { await page.click('#btn-sair'); await page.waitForSelector('#tela-login:not([hidden])'); };
  const kpi = async rot => (await page.locator(`.kpi:has(.kpi-rotulo:text-is("${rot}")) .kpi-valor`).textContent()).trim();
  const sit = cnjIni => psql(`select situacao from atlas_cadastro where cnj like '${cnjIni}%'`);

  // ------------------------------------------------ controladoria: importar, conferir, escolher cliente, aprovar
  await entrar('admin.teste@exemplo.invalid', 'senha-admin-teste');
  check('Menu: área no grupo Atlas Gestor', '1',
        await page.locator('#menu .menu-grupo[aria-labelledby="menu-g-atlas"] a[href="#/cadastro-atlas"]').count());
  await page.goto(BASE + '#/cadastro-atlas'); await page.waitForSelector('#conteudo .kpis');
  check('Título da área', 'Cadastro de processos no Atlas', await page.textContent('#conteudo h1'));
  await page.setInputFiles('#conteudo input[type=file]', PLANILHA);
  await page.click('#conteudo button:text-is("Importar e montar a prévia")');
  await page.waitForSelector('#conteudo .aviso-ok, #conteudo .aviso-erro');
  check('Importação: 4 linhas, 3 com processo, 3 novos', true,
        /4 linha\(s\) lidas; 3 com número de processo válido; 3 processo\(s\) novo\(s\)/.test(await page.textContent('#conteudo .aviso-ok')));
  check('Processo do cliente encontrado vai para a prévia (banco)', 'previa', sit(P1));
  check('Cliente inexistente fica só na lista (banco)', 'sem_cliente', sit(P2));
  check('Dois clientes possíveis: revisar (banco)', 'revisar', sit(P3));
  await page.waitForSelector('#conteudo table');
  const nPrevia = psql("select count(*) from atlas_cadastro where situacao='previa'");
  check('Indicador da prévia igual ao banco', nPrevia, await kpi('Prévia'));
  check('Indicador "cliente não encontrado" igual ao banco', psql("select count(*) from atlas_cadastro where situacao='sem_cliente'"), await kpi('Cliente não encontrado'));
  check('Lista da prévia igual ao banco', nPrevia, await page.locator('#conteudo tbody tr').count());
  const linhaP1 = page.locator(`#conteudo tbody tr:has-text("${P1}")`);
  await linhaP1.locator('summary').click();
  check('Prévia mostra o que vai para o Atlas (tipo, valor, autores, notas)', true,
        /Revisional de Contrato · R\$ 12\.345,67/.test(await linhaP1.locator('details summary').textContent())
        && /Cadastrado pela controladoria a partir do ADVBOX/.test(await linhaP1.locator('.teor-cnj').textContent()));
  await tela('40_cadastro_atlas_previa');

  // lista dos não encontrados + CSV
  await page.click('.kpi:has(.kpi-rotulo:text-is("Cliente não encontrado"))');
  await page.waitForFunction(() => document.querySelector('.kpi-ativo .kpi-rotulo')?.textContent === 'Cliente não encontrado');
  check('Lista dos não encontrados (banco)', psql("select count(*) from atlas_cadastro where situacao='sem_cliente'"), await page.locator('#conteudo tbody tr').count());
  const [dl] = await Promise.all([page.waitForEvent('download'), page.click('#conteudo button:text-is("Baixar esta lista (CSV)")')]);
  const csv = fs.readFileSync(await dl.path(), 'utf8');
  check('CSV da lista: cabeçalho e uma linha por processo', true,
        csv.includes('Processo;Situação;Motivo') && csv.trim().split('\r\n').length === Number(psql("select count(*) from atlas_cadastro where situacao='sem_cliente'")) + 1);
  await tela('41_cadastro_atlas_nao_encontrados');

  // revisar: escolher o cliente
  await page.click('.kpi:has(.kpi-rotulo:text-is("Revisar o cliente"))');
  await page.waitForFunction(() => document.querySelector('.kpi-ativo .kpi-rotulo')?.textContent === 'Revisar o cliente');
  const linhaP3 = page.locator(`#conteudo tbody tr:has-text("${P3}")`);
  await linhaP3.locator('summary:text-is("Escolher cliente")').click();
  await linhaP3.locator('input[type=search]').fill('G300'); await linhaP3.locator('button:text-is("Buscar")').click();
  await linhaP3.locator('button:text-is("G300 - Ambíguo Comércio")').click();
  await page.waitForSelector('#conteudo .aviso-ok');
  check('Escolha do cliente pela controladoria (banco)', 'previa|escolha da controladoria',
        psql(`select situacao||'|'||casado_por from atlas_cadastro where cnj like '${P3}%'`));

  // aprovar marcados
  await page.click('.kpi:has(.kpi-rotulo:text-is("Prévia"))');
  await page.waitForFunction(() => document.querySelector('.kpi-ativo .kpi-rotulo')?.textContent === 'Prévia');
  await page.locator(`#conteudo tbody tr:has-text("${P1}") input[type=checkbox]`).check();
  await page.click('#conteudo button:text-is("Aprovar marcados")');
  await page.waitForSelector('#conteudo .aviso-ok');
  check('Aprovar marcados: só o marcado vai para a fila (banco)', 'aprovado|previa', `${sit(P1)}|${sit(P3)}`);
  check('Aprovação registrada no histórico', 't', psql("select exists(select 1 from atlas_cadastro_eventos where tipo='aprovacao' and detalhe->>'aprovados'='1')"));
  check('"Aprovar todos" pede confirmação antes', true, await (async () => {
    const b = page.locator('#conteudo button:text-is("Aprovar todos da prévia")'); await b.click();
    return await page.locator('#conteudo button', { hasText: /^Confirmar: aprovar todos os \d+ da prévia$/ }).count() === 1 && sit(P3) === 'previa';
  })());
  check('Controladoria vê importar, atualizar clientes e cadastrar agora', '1|1|1',
        `${await page.locator('#conteudo input[type=file]').count()}|${await page.locator('button:text-is("Atualizar clientes do Atlas")').count()}|${await page.locator('button:text-is("Cadastrar 5 agora")').count()}`);
  await tela('42_cadastro_atlas_aprovado');
  await sair();

  // ------------------------------------------------ diretoria: lê, não altera
  await entrar('diretoria.teste@exemplo.invalid', 'senha-diretoria-teste');
  await page.goto(BASE + '#/cadastro-atlas'); await page.waitForSelector('#conteudo .kpis');
  check('Diretoria lê a lista (banco)', psql("select count(*) from atlas_cadastro where situacao='previa'"), await page.locator('#conteudo tbody tr').count());
  check('Diretoria não importa, não aprova, não escolhe cliente', '0|0|0|0',
        `${await page.locator('#conteudo input[type=file]').count()}|${await page.locator('button:text-is("Aprovar marcados")').count()}|${await page.locator('#conteudo input[type=checkbox]').count()}|${await page.locator('summary:text-is("Escolher cliente")').count()}`);
  await sair();
  // ------------------------------------------------ peticionador: área restrita
  await entrar('colab.teste@exemplo.invalid', 'senha-colab-teste');
  await page.goto(BASE + '#/cadastro-atlas'); await page.waitForSelector('#conteudo h1');
  check('Peticionador não abre a área', 'false', String(await page.locator('#conteudo .kpis').count() > 0));
  check('Sem erros no console', '[]', JSON.stringify(erros.filter(e => !/401|403|Failed to load resource/.test(e))));

  await browser.close();
  const ok = res.filter(r => r[3] === 'OK').length;
  for (const [n, e, o, s] of res) console.log(`${s.padEnd(5)} ${n}` + (s === 'OK' ? '' : `\n      esperado: ${e}\n      obtido:   ${o}`));
  console.log(`\n${ok}/${res.length} OK — executado em ${new Date().toLocaleString('pt-BR')}`);
  process.exit(ok === res.length ? 0 : 1);
})().catch(e => { console.error(e); process.exit(1); });
