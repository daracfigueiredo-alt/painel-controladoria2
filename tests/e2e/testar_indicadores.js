/* Teste ponta a ponta — Etapa 4 (Visão geral, Indicadores por colaborador, Prazos em risco,
 * Reagendamentos, Tratativa). Usa o banco do tests/test_etapa4.py (dados FICTÍCIOS com
 * resposta conhecida): rode aquele teste antes. Compara o que a TELA mostra com o que o
 * BANCO calcula e com o detalhamento. */
'use strict';
const { chromium } = require('playwright');
const { execFileSync, spawn } = require('child_process');
const fs = require('fs');
const path = require('path');

const DB = process.env.DB || 'ctrl_etapa4', PORTA = 8790, BASE = `http://127.0.0.1:${PORTA}/painel/`;
const SAIDA = path.join(__dirname, 'out'); fs.mkdirSync(SAIDA, { recursive: true });
const ADMIN_UID = '00000000-0000-0000-0000-00000000000a';
const res = [];
const check = (n, e, o) => { res.push([n, String(e), String(o), String(e) === String(o) ? 'OK' : 'FALHA']); if (process.env.PROGRESSO) console.error(`[${res.length}] ${res[res.length - 1][3]} ${n}`); };
const psql = sql => execFileSync('psql', ['-h', '/tmp', '-p', '5433', '-U', 'postgres', '-At', '-q', '-v', 'ON_ERROR_STOP=1', '-d', DB, '-c', sql], { encoding: 'utf8' }).trim();
const comoAdmin = sql => psql(`set role authenticated; set request.jwt.claims = '{"sub":"${ADMIN_UID}"}'; ${sql}`);
let srv = null;
process.on('exit', () => { if (srv) srv.kill(); });

(async () => {
  srv = spawn(process.execPath, [path.join(__dirname, 'servidor_local.js')], { env: { ...process.env, PORTA: String(PORTA), DB }, stdio: ['ignore', 'pipe', 'inherit'] });
  await new Promise(ok => srv.stdout.once('data', ok));
  const browser = await chromium.launch();
  const page = await (await browser.newContext({ viewport: { width: 1360, height: 900 } })).newPage();
  const erros = []; page.on('console', m => { if (m.type() === 'error') erros.push(m.text()); }); page.on('pageerror', e => erros.push(e.message));
  const falhasHttp = []; page.on('response', async r => { if (r.status() >= 400) falhasHttp.push(`${r.status()} ${r.url().replace(/^.*\/(rest|auth)\/v1\//, '')} ${(await r.text().catch(() => '')).slice(0, 120)}`); });
  const tela = n => page.screenshot({ path: path.join(SAIDA, n + '.png'), fullPage: true });
  async function entrar(email, senha) {
    await page.goto(BASE); await page.fill('#login-email', email); await page.fill('#login-senha', senha); await page.click('#btn-entrar');
    await page.waitForSelector('#tela-app:not([hidden])');
  }
  const hoje = psql('select hoje_brasilia()');
  const ini = psql("select (hoje_brasilia() - 29)::text");
  const resumo = JSON.parse(comoAdmin(`select indicadores_resumo('${ini}','${hoje}')`));

  // ------------------------------------------------ Visão geral
  await entrar('admin.teste@exemplo.invalid', 'senha-admin-teste');
  await page.waitForSelector('.kpis');
  const kpis = await page.$$eval('.kpi', ks => Object.fromEntries(ks.map(k => [k.querySelector('.kpi-rotulo').textContent, k.querySelector('.kpi-valor').textContent])));
  const ROT = { pendentes: 'Tarefas pendentes', vencidas: 'Vencidas (PF da Tarefa)', pf_judicial_vencido_conferir: 'PF Judicial vencido — conferir', vencem_hoje: 'Vencem hoje',
    d4_criticas: 'Críticas em D-4', sem_inicio: 'Abertas sem início', concluidas: 'Concluídas', protocolos_realizados: 'Protocolos realizados',
    distribuicoes_realizadas: 'Distribuições realizadas', pedidos_reagendamento: 'Solicitações de reagendamento', reagendamentos_efetivados: 'Reagendamentos efetivados' };
  check('Visão geral: 12 cartões (7 de posição, 5 do período)', '12', Object.keys(kpis).length);
  check('Cartões da tela = números calculados pelo banco (11 indicadores)', 'iguais',
    Object.entries(ROT).every(([k, r]) => String(resumo.contagens[k] || 0) === kpis[r]) ? 'iguais' : JSON.stringify(kpis));
  check('Valores conhecidos da base fictícia aparecem na tela', '7|2|1|1|1|2|1|3',
    ['pendentes', 'vencidas', 'pf_judicial_vencido_conferir', 'vencem_hoje', 'd4_criticas', 'concluidas', 'pedidos_reagendamento', 'reagendamentos_efetivados'].map(k => kpis[ROT[k]]).join('|'));
  check('Aviso de atualização da base exibido', 'true', /Posição atual = /.test(await page.textContent('#conteudo')));
  // detalhamento = número do cartão
  await page.click(`.kpi:has(.kpi-rotulo:text-is("${ROT.vencidas}"))`);
  await page.waitForSelector('dialog.detalhe[open] table');
  const nDet = await page.locator('dialog.detalhe tbody tr').count();
  check('Detalhamento do cartão "Vencidas" lista exatamente os registros do número', kpis[ROT.vencidas], nDet);
  check('Detalhamento explica por que cada registro está ali', 'true', /PF da Tarefa \(ADVBOX\) em .* já passou/.test(await page.textContent('dialog.detalhe')));
  await tela('10_detalhe_vencidas');
  await page.click('dialog.detalhe button:has-text("Fechar")');
  // gráficos
  const barrasDia = await page.locator('.grafico-svg .alvo').count();
  check('Gráfico 1 tem um alvo por dia do período (30) + 1 grupo por colaborador', String(30 + 2), barrasDia);
  const somaBarras = await page.$$eval('.grafico:has(h2:text-is("Tarefas concluídas por dia")) .grafico-svg .alvo', as => as.reduce((t, a) => t + Number(a.getAttribute('aria-label').match(/: (\d+) concluída/)[1]), 0));
  check('Soma das barras de concluídas por dia = cartão Concluídas', kpis[ROT.concluidas], somaBarras);
  await page.click('.grafico:has(h2:text-is("Tarefas concluídas por dia")) button:has-text("Ver como tabela")');
  check('Gráfico tem alternativa em tabela', '30', await page.locator('.grafico:has(h2:text-is("Tarefas concluídas por dia")) tbody tr').count());
  check('Legenda do gráfico de 2 séries presente', 'Concluídas no período|Pendentes (posição atual)', await page.$$eval('.legenda .leg', ls => ls.map(l => l.textContent).join('|')));
  await tela('11_visao_geral');
  // filtro de período: 60 dias inclui a conclusão antiga
  await page.selectOption('.filtros-barra select', '90');
  await page.waitForFunction(() => /90|No período/.test(document.querySelector('#conteudo').textContent) && document.querySelector('.kpis'));
  await page.waitForTimeout(400);
  const conc90 = await page.$eval(`.kpi:has(.kpi-rotulo:text-is("Concluídas")) .kpi-valor`, e => e.textContent);
  check('Filtro "Últimos 90 dias" inclui a conclusão de 40 dias atrás', '3', conc90);
  await page.selectOption('.filtros-barra select', '30');
  await page.waitForTimeout(400);
  // filtro por equipe
  const eq1 = psql("select id from equipes where nome='TESTE EQUIPE 1'");
  await page.selectOption('.filtros-barra label:has(span:text-is("Equipe")) select', eq1);
  await page.waitForTimeout(500);
  check('Filtro por equipe atualiza os cartões (pendentes da equipe 1 = 5)', '5', await page.$eval(`.kpi:has(.kpi-rotulo:text-is("${ROT.pendentes}")) .kpi-valor`, e => e.textContent));
  await page.selectOption('.filtros-barra label:has(span:text-is("Equipe")) select', '');
  await page.waitForTimeout(400);

  // ------------------------------------------------ Por colaborador
  await page.goto(BASE + '#/colaboradores'); await page.waitForSelector('#conteudo table');
  const linhasColab = await page.locator('#conteudo tbody tr').count();
  check('Indicadores por colaborador: uma linha por colaborador com tarefas', '2', linhasColab);
  const pc = JSON.parse(comoAdmin(`select json_agg(row_to_json(x) order by responsavel) from indicadores_por_colaborador('${ini}','${hoje}') x`));
  const linhaA = await page.locator('#conteudo tbody tr:has-text("TESTE COLAB A")').innerText();
  const a = pc.find(x => x.responsavel === 'TESTE COLAB A');
  check('Linha do colaborador A = banco (pendentes, vencidas, protocolos, tempo médio ~30 h)', 'true',
    linhaA.includes(String(a.pendentes)) && /30|31|29/.test(linhaA) && /n=1/.test(linhaA));
  await page.click('#conteudo tbody tr:has-text("TESTE COLAB B") .link-num >> nth=0');
  await page.waitForSelector('dialog.detalhe[open] table');
  check('Número do colaborador abre o detalhamento filtrado por ele', 'true', (await page.$$eval('dialog.detalhe tbody tr', trs => trs.every(t => t.textContent.includes('TESTE COLAB B')))));
  await page.click('dialog.detalhe button:has-text("Fechar")');
  await tela('12_por_colaborador');

  // ------------------------------------------------ Prazos em risco
  await page.goto(BASE + '#/prazos'); await page.waitForSelector('#conteudo table');
  const totalBanco = comoAdmin("select count(*) from v_prazos_risco where situacao_conferencia='pendente_conferencia'");
  const chipTodos = await page.textContent('#conteudo .chip >> nth=0');
  check('Prazos em risco: total da tela = banco (pendentes de conferência)', `Todos (${totalBanco})`, chipTodos);
  check('Criticidade exibida com ícone e rótulo (não só cor)', 'true', /● Crítica/.test(await page.textContent('#conteudo table')));
  await page.click('#conteudo .chip:has-text("Protocolo/distribuição sem evidência")');
  await page.waitForSelector('#conteudo .chip.ativo:has-text("Protocolo/distribuição sem evidência")');
  await page.waitForSelector('#conteudo tbody tr:has-text("PROTOCOLO")');
  check('Filtro por tipo de alerta', '1', await page.locator('#conteudo tbody tr').count());
  await page.click('#conteudo tbody tr button:has-text("Registrar conferência")');
  await page.selectOption('.form-conferencia select', 'providencia_em_outra_tarefa');
  await page.fill('.form-conferencia textarea', 'curta');
  await page.click('.form-conferencia button:has-text("Salvar")');
  await page.waitForFunction(() => document.querySelector('.form-conferencia .erro').textContent.length > 0);
  check('Conferência com nota curta é recusada pelo banco e explicada', 'true', /10 caracteres/.test(await page.textContent('.form-conferencia .erro')));
  await page.fill('.form-conferencia textarea', 'Protocolo feito na tarefa da mesma pasta (fictício).');
  await page.click('.form-conferencia button:has-text("Salvar")');
  await page.waitForTimeout(600);
  check('Conferência gravada e alerta sai da lista de pendentes', 'conferido|0',
    `${comoAdmin("select situacao_conferencia from v_prazos_risco where categoria='protocolo_sem_evidencia'")}|${await page.locator('#conteudo tbody tr:has-text("Protocolo/distribuição sem evidência")').count()}`);
  check('Após a conferência, a lista volta para todos os alertas pendentes', `Todos (${Number(totalBanco) - 1})`, await page.textContent('#conteudo .chip.ativo'));
  await tela('13_prazos_em_risco');
  // exceção de D-4 (0037): a controladoria autoriza a entrega depois do D-4
  const nD4 = Number(comoAdmin("select count(*) from v_alertas where categoria='d4_vencido_sem_entrega'"));
  await page.click('#conteudo .chip:has-text("D-4 vencido sem entrega")');
  await page.waitForSelector('#conteudo tbody tr button:has-text("Autorizar após o D-4")');
  await page.click('#conteudo tbody tr button:has-text("Autorizar após o D-4") >> nth=0');
  await page.fill('.form-conferencia textarea', 'Exceção fictícia autorizada pela coordenação');
  await page.click('.form-conferencia button:has-text("Autorizar")');
  await page.waitForSelector('h2:has-text("Entregas autorizadas depois do D-4")');
  check('Exceção de D-4: alerta sai e a tarefa aparece em "Entregas autorizadas"', `${nD4 - 1}|1|Exceção fictícia autorizada pela coordenação`,
    `${comoAdmin("select count(*) from v_alertas where categoria='d4_vencido_sem_entrega'")}|${comoAdmin("select jsonb_array_length(excecoes_d4_listar())")}|${comoAdmin("select justificativa from eventos where tipo='excecao_d4'")}`);

  // ------------------------------------------------ Reagendamentos
  await page.goto(BASE + '#/reagendamentos'); await page.waitForSelector('#conteudo table');
  const txtR = await page.textContent('#conteudo');
  check('Reagendamentos: solicitação e efetivação separadas', 'true', /Solicitação \(1\)/.test(txtR) && /Efetivação \(3\)/.test(txtR));
  check('Aviso: aprovação/rejeição não identificáveis na exportação', 'true', /Aprovação e rejeição de pedidos não aparecem/.test(txtR));
  check('Texto original do pedido exibido', 'true', /Favor reagendar/.test(txtR));
  await tela('14_reagendamentos');

  // ------------------------------------------------ Tratativa
  await page.goto(BASE + '#/tratativa'); await page.waitForSelector('#conteudo table');
  const txtT = await page.textContent('#conteudo');
  check('Tratativa: pendentes sem início = banco', `Pendente sem início (${comoAdmin("select count(*) from v_tratativa where status_tratativa='pendente_sem_inicio'")})`,
    (txtT.match(/Pendente sem início \(\d+\)/) || [''])[0]);
  check('Tratativa: concluídas sem início (inconsistência) aparecem após configurar o monitoramento', 'true', /Concluída sem início \(inconsistência\) \(2\)/.test(txtT));
  await page.click('#conteudo .chip:has-text("Iniciada, não concluída")');
  await page.waitForTimeout(400);
  check('Tarefa iniciada mostra quem iniciou', 'true', /por TESTE COLAB A/.test(await page.textContent('#conteudo table')));
  await tela('15_tratativa');

  // ------------------------------------------------ colaborador e celular
  await page.click('#btn-sair'); await page.waitForSelector('#tela-login:not([hidden])');
  await entrar('colab.teste@exemplo.invalid', 'senha-colab-teste');
  await page.goto(BASE + '#/visao-geral');   // 0038: o peticionador entra pela "Minha pauta"
  await page.waitForSelector('.kpis');
  check('Colaborador A vê os próprios números (pendentes = 5)', '5', await page.$eval(`.kpi:has(.kpi-rotulo:text-is("${ROT.pendentes}")) .kpi-valor`, e => e.textContent));
  check('Colaborador não vê filtros de equipe/colaborador', '0', await page.locator('.filtros-barra label:has(span:text-is("Colaborador"))').count());
  await page.setViewportSize({ width: 390, height: 844 }); await page.reload(); await page.waitForSelector('.kpis:has(.kpi-rotulo:text-is("Vencidas (PF da Tarefa)"))');
  check('Celular (390 px): sem rolagem horizontal na Visão geral', 'true', await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth));
  await tela('16_celular_visao_geral');
  // a única resposta de erro esperada é a da nota curta (recusada pelo banco de propósito no teste)
  check('Sem erros inesperados (console e respostas HTTP)', '', [...erros.filter(m => !/Failed to load resource/.test(m)),
    ...falhasHttp.filter(f => !/^400 rpc\/admin_conferir_alerta .*23514/.test(f))].join(' | '));

  await browser.close(); srv.kill();
  const w = Math.max(...res.map(r => r[0].length));
  for (const [n, e, o, s] of res) console.log(`${s.padEnd(5)} | ${n.padEnd(w)} | esperado: ${e} | obtido: ${o}`);
  console.log(`\n${res.filter(r => r[3] === 'OK').length}/${res.length} OK — executado em ${new Date().toLocaleString('pt-BR', { timeZone: 'America/Sao_Paulo' })}`);
  process.exit(res.every(r => r[3] === 'OK') ? 0 : 1);
})().catch(e => { console.error(e); if (srv) srv.kill(); process.exit(2); });
