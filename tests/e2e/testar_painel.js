/* Teste ponta a ponta do painel — Etapa 3 (Importação Excel).
 * Banco PostgreSQL LOCAL (migrações 0001–0010 reais, RLS real) + servidor_local.js
 * (emulação mínima da API do Supabase) + Chromium (Playwright).
 * Arquivos reais do ADVBOX: pasta em ARQ_REAIS (não versionados). Demais: fictícios. */
'use strict';
const { chromium } = require('playwright');
const { execFileSync, spawn } = require('child_process');
const fs = require('fs');
const path = require('path');

const RAIZ = path.resolve(__dirname, '..', '..');
const DB = 'ctrl_e2e', PORTA = 8787, BASE = `http://127.0.0.1:${PORTA}/painel/`;
const FIX = path.join(__dirname, 'fixtures');
const SAIDA = path.join(__dirname, 'out'); fs.mkdirSync(SAIDA, { recursive: true });
const REAIS = process.env.ARQ_REAIS;
const ARQ = REAIS ? {
  pend: fs.readdirSync(REAIS).find(f => f.endsWith('0717524.xlsx')),
  conc1: fs.readdirSync(REAIS).find(f => f.endsWith('0443625.xlsx')),
  conc2: fs.readdirSync(REAIS).find(f => f.endsWith('0687502.xlsx'))
} : null;
const ADMIN = ['admin.teste@exemplo.invalid', 'senha-admin-teste'];
const COLAB = ['colab.teste@exemplo.invalid', 'senha-colab-teste'];

const res = [];
const check = (n, e, o) => { res.push([n, String(e), String(o), String(e) === String(o) ? 'OK' : 'FALHA']); if (process.env.PROGRESSO) console.error(`[${res.length}] ${res[res.length-1][3]} ${n}`); };
const psql = (sql, db = DB) => execFileSync('psql', ['-h', '/tmp', '-p', '5433', '-U', 'postgres', '-At', '-q', '-v', 'ON_ERROR_STOP=1', '-d', db, '-c', sql], { encoding: 'utf8' }).trim();
const espera = ms => new Promise(r => setTimeout(r, ms));

function prepararBanco() {
  psql(`drop database if exists ${DB}`, 'postgres'); psql(`create database ${DB}`, 'postgres');
  const migs = fs.readdirSync(path.join(RAIZ, 'supabase', 'migrations')).sort().map(f => path.join(RAIZ, 'supabase', 'migrations', f));
  for (const f of [path.join(RAIZ, 'tests', '00_stub_supabase_local.sql'), ...migs])
    execFileSync('psql', ['-h', '/tmp', '-p', '5433', '-U', 'postgres', '-q', '-v', 'ON_ERROR_STOP=1', '-d', DB, '-f', f], { stdio: 'pipe' });
  psql(`insert into colaboradores(nome_advbox, origem) values ('TESTE COLAB A','administrativo');
        insert into perfis values ('00000000-0000-0000-0000-00000000000a','admin',null),
          ('00000000-0000-0000-0000-00000000000c','colaborador',(select id from colaboradores where nome_advbox='TESTE COLAB A'));`);
}

let srv = null;
process.on('exit', () => { if (srv) srv.kill(); });
(async () => {
  prepararBanco();
  srv = spawn(process.execPath, [path.join(__dirname, 'servidor_local.js')], { env: { ...process.env, PORTA: String(PORTA), DB }, stdio: ['ignore', 'pipe', 'inherit'] });
  await new Promise(ok => srv.stdout.once('data', ok));
  const browser = await chromium.launch();
  const ctxB = await browser.newContext({ viewport: { width: 1360, height: 900 } });
  const page = await ctxB.newPage();
  const consoleErros = [];
  page.on('console', m => { if (m.type() === 'error') consoleErros.push(m.text()); });
  page.on('pageerror', e => consoleErros.push(e.message));
  const tela = async nome => page.screenshot({ path: path.join(SAIDA, nome + '.png'), fullPage: true });
  async function entrar([email, senha]) {
    await page.goto(BASE); await page.waitForSelector('#form-login:not([hidden]), #tela-login:not([hidden])');
    await page.fill('#login-email', email); await page.fill('#login-senha', senha); await page.click('#btn-entrar');
  }
  async function sair() { await page.click('#btn-sair'); await page.waitForSelector('#tela-login:not([hidden])'); }
  async function selecionar(arquivos, modo = 'novo') {
    await page.check(`input[name=modo][value=${modo}]`);
    await page.setInputFiles('#imp-arquivos', arquivos);
    await page.waitForSelector('#imp-previa table');
  }
  const livre = () => page.waitForSelector('#conteudo:not([data-ocupado])', { timeout: 90000 });
  async function importarEAguardar() { await page.click('#imp-confirmar'); await livre(); }
  const textoCard = i => page.locator('#imp-resultados .resultado').nth(i).innerText();
  const valorResumo = async (i, rotulo) => page.locator('#imp-resultados .resultado').nth(i).locator(`dt:text-is("${rotulo}") + dd`).innerText();

  // ------------------------------------------------ autenticação e permissões
  await entrar(['admin.teste@exemplo.invalid', 'senha-errada']);
  await page.waitForFunction(() => document.getElementById('login-erro').textContent.length > 0);
  check('Login com senha errada é recusado com mensagem', 'true', /incorretos/.test(await page.textContent('#login-erro')));
  await entrar(COLAB);
  await page.waitForSelector('#tela-app:not([hidden])');
  check('Colaborador entra e o menu mostra as 19 áreas (0038; Atlas e Excel separados em 11/11; Intimações CNJ em 12/11; Cadastro no Atlas e Audiências em 14/11)', '19', await page.locator('#menu li').count());
  check('Menu agrupado por sistema', 'Acompanhamento|Atlas Gestor|Publicações e intimações|ADVBOX (histórico)|Administração',
    (await page.locator('#menu .menu-grupo-titulo').allTextContents()).join('|'));
  await page.goto(BASE + '#/importacao'); await page.waitForSelector('#conteudo h1');
  check('Colaborador não acessa a importação na tela', 'true', /restrita ao administrador/.test(await page.textContent('#conteudo')));
  const direto = await page.evaluate(async () => {
    const k = Object.keys(sessionStorage).find(x => /auth-token/.test(x)); const s = JSON.parse(sessionStorage.getItem(k));
    const r = await fetch('/rest/v1/rpc/importar_arquivo', { method: 'POST', headers: { 'Content-Type': 'application/json', apikey: window.OC_CONFIG.SUPABASE_ANON_KEY, Authorization: 'Bearer ' + s.access_token },
      body: JSON.stringify({ p_nome_arquivo: 'x.xlsx', p_hash_arquivo: 'a'.repeat(64), p_linhas: [{}] }) });
    return r.status + '|' + (await r.json()).message;
  });
  check('Colaborador chamando a função direto (fora da tela) é barrado pelo banco', '403|Somente administradores podem importar', direto);
  check('Nenhuma importação gravada pelo colaborador', '0', psql('select count(*) from importacoes'));
  check('Sessão guardada só na aba (sessionStorage), não em localStorage', '0', await page.evaluate(() => Object.keys(localStorage).length));
  await tela('01_colaborador_area_restrita');
  // os dois passos acima provocam, de propósito, respostas 400 (senha errada) e 403 (chamada barrada)
  consoleErros.splice(0, consoleErros.length, ...consoleErros.filter(m => !/Failed to load resource: the server responded with a status of (400|403)/.test(m)));
  await sair();

  await entrar(ADMIN);
  await page.waitForSelector('#tela-app:not([hidden])');
  check('Admin entra na Visão geral', 'Visão geral', await (await page.waitForSelector('#conteudo h1')).textContent());
  await page.goto(BASE + '#/importacao'); await page.waitForSelector('#imp-nova h2');
  check('Importação do Excel (ADVBOX) abre pelo menu', 'Importação do Excel', await page.textContent('#conteudo h1'));
  check('Importação do Excel fica no grupo ADVBOX', 'true', await page.locator('#menu .menu-grupo[aria-labelledby="menu-g-advbox"] a[href="#/importacao"]').count() === 1);
  check('Sincronização do Atlas fica no grupo Atlas', 'true', await page.locator('#menu .menu-grupo[aria-labelledby="menu-g-atlas"] a[href="#/atlas"]').count() === 1);
  check('Base vazia informada', 'true', /Nenhuma importação concluída/.test(await page.textContent('#imp-base')));
  check('Opção "complementar" desabilitada sem base', 'true', await page.isDisabled('input[name=modo][value=complementar]'));
  await tela('02_admin_inicio');

  // ------------------------------------------------ arquivos inválidos (pré-conferência na tela)
  await selecionar([path.join(FIX, 'nao_e_planilha.xlsx'), path.join(FIX, 'ficticio_sem_coluna.xlsx')]);
  const prev = await page.textContent('#imp-previa');
  check('Arquivo que não é .xlsx bloqueado antes do envio', 'true', /não é uma planilha .xlsx/.test(prev));
  check('Coluna obrigatória ausente bloqueada antes do envio', 'true', /Colunas obrigatórias ausentes: Prazo fatal/.test(prev));
  check('Botão de importar desabilitado sem arquivo válido', 'true', await page.isDisabled('#imp-confirmar'));

  // ------------------------------------------------ leitor x openpyxl (arquivos reais)
  if (ARQ) {
    for (const [k, py] of [['pend', 'real.json'], ['conc1', 'concluidas.json'], ['conc2', 'concluidas2.json']]) {
      const pyj = JSON.parse(fs.readFileSync(path.join(RAIZ, 'tests', 'out', py), 'utf8'));
      const b = [...fs.readFileSync(path.join(REAIS, ARQ[k]))];
      const js = await page.evaluate(async bytes => { const u = new Uint8Array(bytes); const p = OCPlanilha.lerPlanilha(u); return { hash: await OCPlanilha.sha256Hex(u), linhas: p.linhas }; }, b);
      check(`Leitor do painel = conversor Python (openpyxl): ${ARQ[k].slice(-30)} — linhas e hash`,
        `${pyj.linhas.length}|${pyj.hash}|iguais`, `${js.linhas.length}|${js.hash}|${JSON.stringify(js.linhas) === JSON.stringify(pyj.linhas) ? 'iguais' : 'DIFERENTES'}`);
    }
  }
  const vazia = await page.evaluate(async b => OCPlanilha.lerPlanilha(new Uint8Array(b)).linhas.map(l => l['Compromisso']), [...fs.readFileSync(path.join(FIX, 'ficticio_linha_vazia.xlsx'))]);
  check('Linha vazia no meio mantida (numeração), vazias no fim descartadas', 'TESTE FICTÍCIO A||TESTE FICTÍCIO B', vazia.join('|'));

  // ------------------------------------------------ fluxo real: pendentes -> concluídas
  if (ARQ) {
    await selecionar([path.join(REAIS, ARQ.pend)]);
    const linhaPrev = await page.locator('#imp-previa tbody tr').first().innerText();
    check('Pré-conferência: 878 linhas, 31 concluídas, cria lote novo', 'true', /878/.test(linhaPrev) && /\b31\b/.test(linhaPrev) && /cria lote novo/.test(linhaPrev));
    await tela('03_previa_pendentes');
    const t0 = Date.now(); await importarEAguardar(); const ms = Date.now() - t0;
    const c0 = await textoCard(0);
    const imp1 = JSON.parse(psql("select row_to_json(i) from importacoes i order by id desc limit 1"));
    check('Importação real concluída e gravada', 'concluida|878', `${imp1.status}|${imp1.total_linhas}`);
    check('Números da tela = números gravados no banco (novas/atualizadas/ignoradas/rejeitadas/sem vínculo)',
      [imp1.tarefas_novas, imp1.tarefas_vinculadas, imp1.linhas_duplicadas, imp1.linhas_rejeitadas, imp1.linhas_ambiguas].join('|'),
      [await valorResumo(0, 'Importadas (novas)'), await valorResumo(0, 'Atualizadas (já conhecidas)'), await valorResumo(0, 'Ignoradas (repetidas no lote)'),
       await valorResumo(0, 'Rejeitadas'), await valorResumo(0, 'Sem vínculo seguro')].join('|'));
    check('Processos registrados = CNJs distintos válidos do arquivo', psql("select count(distinct normalizar_cnj(processo_cnj)) from linhas_importadas where situacao='valida' and normalizar_cnj(processo_cnj) is not null"), psql('select count(*) from processos'));
    check(`Tempo da importação de 878 linhas pela tela (${(ms / 1000).toFixed(1)} s) abaixo de 60 s`, 'true', ms < 60000);
    check('Base atual atualizada após importar', 'true', /Lote#?\s*#?1/.test((await page.textContent('#imp-base')).replace(/\s+/g, ' ')) || /#1/.test(await page.textContent('#imp-base')));
    await tela('04_resultado_pendentes');

    // concluídas selecionadas como "nova fotografia" -> aviso na prévia + confirmação do banco
    await selecionar([path.join(REAIS, ARQ.conc1)], 'novo');
    check('Prévia alerta: só concluídas como nova fotografia', 'true', /substituiriam a base atual/.test(await page.textContent('#imp-previa')));
    await page.click('#imp-confirmar');
    await page.waitForSelector('#imp-resultados .pergunta');
    check('Banco pede confirmação e nada é gravado antes dela', '1', psql('select count(*) from importacoes'));
    await tela('05_confirmacao_concluidas');
    await page.click('#imp-resultados .pergunta button:has-text("Importar no lote atual")');
    await livre();
    check('Concluídas entraram no MESMO lote das pendentes', '1|2', psql('select count(distinct lote_id)||$$|$$||count(*) from importacoes'));
    check('Visão atual = 878 + 50 linhas (fotografia do dia preservada)', '928', psql(`set role authenticated; set request.jwt.claims = '{"sub":"00000000-0000-0000-0000-00000000000a"}'; select count(*) from v_tarefas_atuais`));

    await selecionar([path.join(REAIS, ARQ.conc2)], 'complementar');
    await importarEAguardar();
    check('2º arquivo de concluídas complementando: 5 linhas repetidas ignoradas', '5', await valorResumo(0, 'Ignoradas (repetidas no lote)'));

    await selecionar([path.join(REAIS, ARQ.pend)], 'complementar');
    await importarEAguardar();
    check('Após os 3 arquivos reais: 418 processos (mesmo número da bateria do banco)', '418', psql('select count(*) from processos'));
    check('Mesmo arquivo de novo: avisado e nada alterado', 'true|3', `${/já foi importado/.test(await textoCard(0))}|${psql('select count(*) from importacoes')}`);
  }

  // ------------------------------------------------ erros por linha (fictício)
  await selecionar([path.join(FIX, 'Advbox-2026-11-05_ficticio_erros.xlsx'), path.join(FIX, 'ficticio_linha_vazia.xlsx')], ARQ ? 'complementar' : 'novo');
  await importarEAguardar();
  check('Arquivo com erros: 2 rejeitadas de 4', '2', await valorResumo(0, 'Rejeitadas'));
  const ultimaImp = psql("select id from importacoes where nome_arquivo like 'Advbox-2026-11-05_ficticio%'");
  check('Data da exportação do lote = data no nome do 1º arquivo do lote', ARQ ? '2026-10-24' : '2026-11-05', psql(`select (data_exportacao at time zone 'America/Sao_Paulo')::date from lotes_importacao l join importacoes i on i.lote_id=l.id where i.id=${ultimaImp}`));
  await page.locator('#imp-resultados .resultado').nth(0).locator('button:has-text("Ver linhas e erros")').click();
  await page.waitForSelector('#imp-detalhe table');
  const det = await page.textContent('#imp-detalhe');
  check('Detalhe mostra o erro com o número da linha da planilha', 'true', /Data inválida: 31\/02\/2026/.test(det) && /Responsável \(Destinatário\) ausente/.test(det));
  check('Detalhe mostra avisos (CNJ fora do padrão, agenda após PF)', 'true', /Número fora do padrão CNJ/.test(det) && /posterior ao Prazo fatal/.test(det));
  const linhasRej = await page.$$eval('#imp-detalhe tbody tr', trs => trs.filter(t => /Rejeitada/.test(t.textContent)).map(t => t.querySelector('td').textContent).join(','));
  check('Linhas rejeitadas identificadas pelo número da planilha (3 e 4)', '3,4', linhasRej);
  await tela('06_detalhe_erros');
  check('Linha vazia do meio rejeitada como linha 3 (numeração preservada)', '3|Data da agenda ausente',
    psql("select numero_linha||'|'||(erros->0->>'mensagem') from linhas_importadas l join importacoes i on i.id=l.importacao_id where i.nome_arquivo='ficticio_linha_vazia.xlsx' and l.situacao='rejeitada'"));

  // ------------------------------------------------ histórico e restrições de escopo
  const nHist = await page.locator('#imp-historico tbody tr').count();
  check('Histórico lista todas as importações gravadas', psql('select count(*) from importacoes'), nHist);
  check('Não há botão de excluir importação nem exportar CSV', '0', await page.locator('button:has-text("Excluir"), button:has-text("CSV"), a:has-text("CSV")').count());

  // ------------------------------------------------ celular
  await page.setViewportSize({ width: 390, height: 844 });
  await page.reload(); await page.waitForSelector('#imp-historico table');
  check('Celular (390 px): sem rolagem horizontal da página', 'true', await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth));
  await tela('07_celular');

  check('Sem erros no console do navegador (inclui violações de CSP)', '', consoleErros.join(' | '));
  await browser.close(); srv.kill();
  const w = Math.max(...res.map(r => r[0].length));
  for (const [n, e, o, s] of res) console.log(`${s.padEnd(5)} | ${n.padEnd(w)} | esperado: ${e} | obtido: ${o}`);
  console.log(`\n${res.filter(r => r[3] === 'OK').length}/${res.length} OK — executado em ${new Date().toLocaleString('pt-BR', { timeZone: 'America/Sao_Paulo' })}`);
  process.exit(res.every(r => r[3] === 'OK') ? 0 : 1);
})().catch(e => { console.error(e); if (srv) srv.kill(); process.exit(2); });
