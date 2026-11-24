/* Teste ponta a ponta — pedidos da Dra. Mariana (0038 a 0041): Painel da diretoria, Minha pauta (checklist e
 * anexos), Solicitações do líder com análise da pauta, Relatório diário de inconsistências e Configurações
 * (modalidades, capacidade, equipes do líder). Usa o banco do tests/test_etapa13.py (dados FICTÍCIOS): rode
 * aquele teste antes. Compara o que a TELA mostra com o que o BANCO calcula. */
'use strict';
const { chromium } = require('playwright');
const { execFileSync, spawn } = require('child_process');
const fs = require('fs');
const path = require('path');

const DB = process.env.DB || 'ctrl_etapa13', PORTA = 8793, BASE = `http://127.0.0.1:${PORTA}/painel/`;
const SAIDA = path.join(__dirname, 'out'); fs.mkdirSync(SAIDA, { recursive: true });
const res = [];
const check = (n, e, o) => res.push([n, String(e), String(o), String(e) === String(o) ? 'OK' : 'FALHA']);
const psql = sql => execFileSync('psql', ['-h', '/tmp', '-p', '5433', '-U', 'postgres', '-At', '-q', '-v', 'ON_ERROR_STOP=1', '-d', DB, '-c', sql], { encoding: 'utf8' }).trim();
const como = (uid, sql) => psql(`set role authenticated; set request.jwt.claims = '{"sub":"${uid}"}'; ${sql}`);
const ADMIN = '00000000-0000-0000-0000-00000000000a', COLAB = '00000000-0000-0000-0000-00000000000c', LIDER = '00000000-0000-0000-0000-0000000000d1';
let srv = null;
process.on('exit', () => { if (srv) srv.kill(); });

(async () => {
  srv = spawn(process.execPath, [path.join(__dirname, 'servidor_local.js')], { env: { ...process.env, PORTA: String(PORTA), DB }, stdio: ['ignore', 'pipe', 'inherit'] });
  await new Promise(ok => srv.stdout.once('data', ok));
  const browser = await chromium.launch();
  const contexto = await browser.newContext({ viewport: { width: 1360, height: 900 }, acceptDownloads: true });
  const page = await contexto.newPage();
  const erros = []; page.on('console', m => { if (m.type() === 'error') erros.push(m.text()); }); page.on('pageerror', e => erros.push(e.message));
  const falhasHttp = []; page.on('response', async r => { if (r.status() >= 400) falhasHttp.push(`${r.status()} ${r.url().replace(/^.*\/(rest|auth|storage)\/v1\//, '')} ${(await r.text().catch(() => '')).slice(0, 120)}`); });
  const tela = n => page.screenshot({ path: path.join(SAIDA, n + '.png'), fullPage: true });
  async function entrar(email, senha) {
    await page.goto(BASE); await page.fill('#login-email', email); await page.fill('#login-senha', senha); await page.click('#btn-entrar');
    await page.waitForSelector('#tela-app:not([hidden])');
  }
  const sair = async () => { await page.click('#btn-sair'); await page.waitForSelector('#tela-login:not([hidden])'); };

  // ------------------------------------------------ Diretoria
  await entrar('diretoria.teste@exemplo.invalid', 'senha-diretoria-teste');
  await page.waitForSelector('h1:text-is("Painel da diretoria")');
  await page.waitForSelector('.kpis');
  const abertas = psql("select count(*) from inconsistencias where situacao='aberta'");
  check('Diretoria entra no Painel da diretoria; pendências = banco', abertas,
    await page.$eval('.kpi:has(.kpi-rotulo:text-is("Inconsistências abertas")) .kpi-valor', e => e.textContent));
  check('Produtividade do Atlas com média por dia ativo', 'true', /OUTRO[\s\S]*2,5/.test(await page.textContent('#conteudo table')));
  check('Papel exibido: Diretoria', 'Diretoria', await page.textContent('#sessao-papel'));
  check('Áreas da controladoria aparecem como restritas', 'true', /Sincronização com o Atlas\s*admin/.test(await page.textContent('#menu')));
  await tela('m1_diretoria');
  await page.goto(BASE + '#/inconsistencias'); await page.waitForSelector('#conteudo table');
  check('Diretoria lê o relatório, sem botões de tratamento', `${abertas}|0|0`,
    `${await page.locator('#conteudo tbody tr').count()}|${await page.locator('button:has-text("Justificar")').count()}|${await page.locator('button:has-text("Rodar a conferência agora")').count()}`);
  await sair();

  // ------------------------------------------------ Peticionador: Minha pauta
  await entrar('colab.teste@exemplo.invalid', 'senha-colab-teste');
  await page.waitForSelector('h1:text-is("Minha pauta")');
  await page.waitForSelector('.pauta-item');
  const nPauta = JSON.parse(como(COLAB, 'select jsonb_array_length(minha_pauta(null, 30))'));
  check('Peticionador entra na Minha pauta; tarefas = banco', String(nPauta), await page.locator('.pauta-item').count());
  check('Papel exibido: Peticionador', 'Peticionador', await page.textContent('#sessao-papel'));
  const contest = page.locator('.pauta-item:has(summary b:text-is("Contestar ação revisional"))');
  check('Contestação: modalidade ativa e pronta para concluir', 'true', /Contestação[\s\S]*pronta para concluir/.test(await contest.locator('summary').textContent()));
  await contest.locator('summary').click();
  await contest.locator('.checklist').waitFor();
  check('Checklist com os 7 itens marcados e links da modalidade', '7|7|true',
    `${await contest.locator('.checklist input').count()}|${await contest.locator('.checklist input:checked').count()}|${await contest.locator('a:has-text("NotebookLM")').count() === 1}`);
  await contest.locator('.checklist input').first().uncheck();
  await contest.locator('.aviso-alerta').waitFor();
  check('Desmarcar um item cria a pendência (gravado no banco)', 'false',
    JSON.parse(como(COLAB, `select execucao_tarefa((select id from tarefas where atlas_id='a0000000-0000-4000-8000-000000000001'))`)).completo);
  await contest.locator('.checklist input').first().check();
  await contest.locator('.aviso-ok').waitFor();
  // anexo pela tela: envio ao Storage, registro com hash e download
  const manif = page.locator('.pauta-item:has(summary b:text-is("Manifestar sobre laudo"))');
  await manif.locator('summary').click();
  await manif.locator('input[type=file]').waitFor();
  const arq = path.join(SAIDA, 'peca_teste.txt'); fs.writeFileSync(arq, 'Peça fictícia de teste ' + Date.now());
  await manif.locator('select[aria-label="Tipo do anexo"]').selectOption('peca');
  await manif.locator('input[type=file]').setInputFiles(arq);
  await manif.locator('button:has-text("Anexar")').click();
  await manif.locator('table button:has-text("peca_teste.txt")').waitFor();
  const reg = psql("select tipo || '|' || tamanho || '|' || length(sha256) from anexos_tarefa where nome_arquivo = 'peca_teste.txt'");
  check('Anexo enviado ao Storage e registrado com hash', `peca|${fs.statSync(arq).size}|64`, reg);
  const [baixado] = await Promise.all([page.waitForEvent('download'), manif.locator('table button:has-text("peca_teste.txt")').click()]);
  check('Download do anexo devolve o mesmo arquivo', fs.readFileSync(arq, 'utf8'), fs.readFileSync(await baixado.path(), 'utf8'));
  await tela('m2_minha_pauta');
  await page.goto(BASE + '#/inconsistencias'); await page.waitForSelector('.aviso-info');
  check('Peticionador não abre o relatório de inconsistências', 'true', /Área restrita/.test(await page.textContent('#conteudo')));
  await sair();

  // ------------------------------------------------ Líder: solicitação com análise da pauta
  await entrar('lider.teste@exemplo.invalid', 'senha-lider-teste');
  await page.goto(BASE + '#/solicitacoes'); await page.waitForSelector('h2:text-is("Nova solicitação")');
  const outro = psql("select id from colaboradores where nome_advbox='OUTRO'");
  const dia = psql('select somar_dias_uteis(hoje_brasilia(), 1)');
  await page.selectOption('select[aria-label="Advogado"]', outro);
  await page.waitForSelector('input[aria-label="Título"]');
  await page.fill('input[aria-label="Título"]', 'Petição urgente pelo painel');
  await page.selectOption('select[aria-label="Modalidade"]', { label: 'Manifestação (1 pts)' });
  await page.fill('input[aria-label="Data na pauta"]', dia);
  await page.click('button:has-text("Analisar a pauta")');
  await page.waitForSelector('legend:text-is("Remanejamento")');
  const anal = JSON.parse(como(LIDER, `select analisar_pauta(${outro}, '${dia}', 1, true)`));
  check('Análise na tela = banco (carga, capacidade, excesso)', 'true',
    (await page.textContent('#conteudo')).includes(`Carga no dia: ${anal.carga_no_dia} + 1 ponto(s) da nova tarefa, para capacidade de ${anal.capacidade}`));
  check('Sugestões listadas com a justificativa, a primeira já escolhida', `${anal.sugestoes.length}|true`,
    `${await page.locator('fieldset.sugestoes input[type=radio]').count() - 1}|${await page.isChecked('fieldset.sugestoes input[value="0"]')}`);
  await page.fill('textarea[aria-label="Justificativa"]', 'Cliente pediu com urgência pelo painel');
  await page.click('button:has-text("Enviar solicitação")');
  await page.waitForSelector('.aviso:has-text("Solicitação #")');
  const ult = JSON.parse(psql("select to_jsonb(s) from solicitacoes s order by id desc limit 1"));
  check('Solicitação gravada com o remanejamento escolhido', `nova_tarefa|${anal.sugestoes[0].tarefa_id}|${ult.exige_controladoria ? 'aguardando_controladoria' : 'aprovada'}`,
    `${ult.tipo}|${ult.remanejamento && ult.remanejamento.tarefa_id}|${ult.status}`);
  check('Lista mostra a solicitação e o botão de executar no Atlas', 'true|true',
    `${(await page.textContent('#conteudo')).includes('Petição urgente pelo painel')}|${ult.status !== 'aprovada' || await page.locator('button:has-text("Executar no Atlas")').count() > 0}`);
  await tela('m3_solicitacao_lider');
  await sair();

  // ------------------------------------------------ Controladoria: relatório, configurações
  await entrar('admin.teste@exemplo.invalid', 'senha-admin-teste');
  await page.goto(BASE + '#/inconsistencias'); await page.waitForSelector('#conteudo table');
  const antes = psql('select count(*) from relatorios_diarios');
  await page.click('button:has-text("Rodar a conferência agora")');
  await page.waitForSelector('.aviso-ok:has-text("Conferência concluída")');
  check('Controladoria roda a conferência pelo painel', String(Number(antes) + 1), psql('select count(*) from relatorios_diarios'));
  const [csv] = await Promise.all([page.waitForEvent('download'), page.click('button:has-text("Exportar CSV")')]);
  const linhasCsv = fs.readFileSync(await csv.path(), 'utf8').trim().split('\r\n').length - 1;
  check('CSV exportado com as inconsistências da tela', String(await page.locator('#conteudo tbody tr').count()), String(linhasCsv));
  await tela('m4_relatorio');
  await page.goto(BASE + '#/configuracoes'); await page.waitForSelector('#cf-modalidades table');
  check('Configurações: 8 modalidades do modelo inicial', '8', await page.locator('#cf-modalidades tbody tr').count());
  await page.click('#cf-modalidades tr:has-text("Manifestação") button:has-text("Editar")');
  await page.fill('input[aria-label="Link do NotebookLM"]', 'https://notebooklm.google.com/notebook/manifestacao');
  await page.fill('#cf-modalidades input[aria-label="Motivo"]', 'Link da conferência técnica (teste)');
  await page.click('button:has-text("Salvar modalidade")');
  await page.waitForSelector('#cf-mod-saida .aviso');
  check('Modalidade salva com o link e auditada', 'https://notebooklm.google.com/notebook/manifestacao|1',
    psql("select link_notebooklm || '|' || (select count(*) from auditoria_configuracao where tabela='modalidades' and motivo like 'Link da conferência%') from modalidades where nome='Manifestação'"));
  check('Líder mostra as equipes que acompanha', 'true', /Equipes: Equipe A/.test(await page.textContent('#cf-usuarios')));
  check('Capacidade por advogado listada', 'true', await page.locator('#cf-capacidade input[aria-label="Capacidade de OUTRO"]').count() === 1);
  await tela('m5_configuracoes');

  check('Sem erros inesperados (console e respostas HTTP)', '', [...erros.filter(m => !/Failed to load resource/.test(m)), ...falhasHttp].join(' | '));
  await browser.close(); srv.kill();
  const w = Math.max(...res.map(r => r[0].length));
  for (const [n, e, o, s] of res) console.log(`${s.padEnd(5)} | ${n.padEnd(w)} | esperado: ${e} | obtido: ${o}`);
  console.log(`\n${res.filter(r => r[3] === 'OK').length}/${res.length} OK — executado em ${new Date().toLocaleString('pt-BR', { timeZone: 'America/Sao_Paulo' })}`);
  process.exit(res.every(r => r[3] === 'OK') ? 0 : 1);
})().catch(e => { console.error(e); if (srv) srv.kill(); process.exit(2); });
