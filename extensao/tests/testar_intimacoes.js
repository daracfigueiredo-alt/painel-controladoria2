/* Testes da leitura de "Intimações recebidas" (Etapa 7), dados FICTÍCIOS.
 *  A) funções puras com texto no formato da janela REAL (06/11/2026);
 *  B) navegador: réplica da tela servida no endereço do ADVBOX (rotas do Playwright), com as
 *     janelas das intimações respondidas pela réplica; confere que só há pedidos GET. */
const path = require('path'), fs = require('fs');
const { chromium } = require('playwright');
const I = require('../lib/advbox_intimacoes.js');
const res = [];
const check = (n, e, o) => res.push([n, String(e), String(o), String(e) === String(o) ? 'OK' : 'FALHA']);

// Texto da janela no formato do textContent real (ordem dos rótulos e ruído da IA do ADVBOX), conteúdo fictício
const janela = (orgao, cnjTeor, teor, vinculo, criado = '06/10/2026 01:21 (12 horas atrás)') => [
  'done Concluir', 'share Copiar link', 'clear', 'A assistente ainda não leu essa intimação.', 'Ver intimação publicada', 'today', 'today', 'help',
  'Data do compromisso', 'Hora', 'Prazo fatal', 'Criar tarefa', 'Refinar análise', 'Enviar', 'clear',
  'Agradecemos o seu feedback e iremos analisá-lo com a maior brevidade possível.clear',
  orgao, `Processo: ${cnjTeor}`, ...teor, 'Inteiro Teor: https://exemplo.invalid/teor/123?instancia=1',
  'Responsável', 'Situação', 'Pendente (1)', 'Data de entrega', 'today', 'quarta, 07/10/2026', 'Nome pesquisado', 'Advogada Ficticia de Teste',
  'Data da publicação', 'today 06/10/2026', 'Prazo', 'today 06/10/2026', 'Criado por', orgao, criado,
  'Processo', ...(vinculo ? [cnjTeor, 'content_copy', 'Visualizar processo'] : ['Nenhum processo vinculado', 'Cadastrar um novo processo']),
  'Partes envolvidas', 'Encaminhar'].join('\n   ');
const TEOR1 = ['TJAL - 1ª VARA CÍVEL FICTÍCIA', 'PROCEDIMENTO COMUM CÍVEL', 'Primeiro despacho ficticio: cite-se.', 'Intimado(s) / Citado(s)', ' - EMPRESA FICTICIA LTDA'];
const j1 = I.lerIntimacao(janela('TJAL - 1ª VARA CÍVEL FICTÍCIA', '0000101-95.2026.8.02.0001', TEOR1, true));
check('Janela: órgão, CNJ do teor, data da publicação, captura', 'TJAL - 1ª VARA CÍVEL FICTÍCIA|0000101-95.2026.8.02.0001|06/10/2026|2026-10-06T01:21:00-03:00',
      [j1.orgao, j1.cnj_teor, j1.data_publicacao, j1.capturada_em].join('|'));
check('Janela: teor do órgão até o "Inteiro Teor" (sem a parte da IA)', 'true|false|true',
      `${/Primeiro despacho ficticio/.test(j1.teor)}|${/feedback|Refinar/.test(j1.teor)}|${/Inteiro Teor:/.test(j1.teor)}`);
check('Janela: link do inteiro teor e nome pesquisado', 'https://exemplo.invalid/teor/123?instancia=1|Advogada Ficticia de Teste', `${j1.url_inteiro_teor}|${j1.nome_pesquisado}`);
check('Janela: processo vinculado', 'true', j1.processo_vinculado);
const j3 = I.lerIntimacao(janela('TJRJ - 4ª VARA CÍVEL FICTÍCIA', '0000102-80.2026.8.02.0001', ['DESPACHO/DECISÃO', 'Texto ficticio sem processo vinculado.'], false));
check('Janela "N/A": "Nenhum processo vinculado" → vínculo falso, CNJ só pelo teor', 'false|0000102-80.2026.8.02.0001', `${j3.processo_vinculado}|${j3.cnj_teor}`);
check('Janela com estrutura desconhecida: erro explícito, nada inventado', 'null|1', (r => `${r.teor}|${r.erros.length >= 1 ? 1 : 0}`)(I.lerIntimacao('Outra tela qualquer\nsem rótulos')));
const L = I.lerLista([{ celulas: ['T001 - EMPRESA', '06/10/2026', 'TJAL', '0000101-95.2026.8.02.0001', '', 'description Pendente', ''], hrefs: ['posts/1/edit', 'lawsuits/9/edit'] },
                      { celulas: ['N/A', '06/10/2026', '', '', '', 'description Pendente', ''], hrefs: ['posts/2/edit'] }], '1-2 de 5', { de: 'De: 05/10/2026', ate: 'Até: 06/10/2026' });
check('Lista: rodapé "1-2 de 5" → incompleta na tela', 'false|5|2', `${L.completa_na_tela}|${L.total_informado}|${L.exibidas}`);
check('Lista: linha N/A sem processo e sem CNJ', 'true|null', `${L.itens[1].sem_processo}|${L.itens[1].cnj}`);
check('Lista: período do filtro lido', '05/10/2026|06/10/2026', `${L.recebido_de}|${L.recebido_ate}`);
check('Registro: CNJ da lista ou, se ausente, do teor', '0000102-80.2026.8.02.0001', I.paraRegistro(L.itens[1], j3).cnj);

// ---------------- B) navegador
(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage();
  const pedidos = [];
  const html = fs.readFileSync(path.join(__dirname, 'advbox_intimacoes_ficticio.html'), 'utf8');
  const janelas = {
    700000001: janela('TJAL - 1ª VARA CÍVEL FICTÍCIA', '0000101-95.2026.8.02.0001', TEOR1, true),
    700000002: janela('TJAL - 1ª VARA CÍVEL FICTÍCIA', '0000101-95.2026.8.02.0001', ['Segundo despacho ficticio: intime-se o perito.'], true),
    700000003: janela('TRF1 - VARA FICTÍCIA', '0000201-72.2026.8.13.0024', ['APELACAO CIVEL', 'Ata ficticia.'], false)
  };
  let recusar = null;
  await page.route('https://app.advbox.com.br/**', route => {
    const u = new URL(route.request().url()); pedidos.push(route.request().method() + ' ' + u.pathname);
    if (recusar && u.pathname === `/posts/${recusar}/edit`) return route.fulfill({ status: 413, body: '' });
    if (u.pathname === '/publications') return route.fulfill({ contentType: 'text/html', body: html });
    const m = u.pathname.match(/^\/posts\/(\d+)\/edit$/);
    if (m && janelas[m[1]]) return route.fulfill({ contentType: 'text/html', body: `<div class="modal">${janelas[m[1]].split('\n').map(l => `<p>${l}</p>\n`).join('')}<script>x=1</script></div>` });
    return route.fulfill({ status: 404, body: '' });
  });
  async function abrir(info, conhecidas = []) {
    await page.goto('https://app.advbox.com.br/publications');
    if (info) await page.evaluate(t => { document.querySelector('.dataTables_info').textContent = t; }, info);
    await page.evaluate(conh => {
      window.__ocIntervaloTeste = 50; window.__conhecidas = conh;
      window.__varreduras = [];
      window.chrome = { runtime: { lastError: null, sendMessage: (msg, cb) => setTimeout(() => {
        if (msg.tipo === 'estado') return cb({ ok: true, email: 'admin.teste@exemplo.invalid' });
        if (msg.tipo === 'intimacoes_conhecidas') return cb({ ok: true, dados: window.__conhecidas.filter(p => msg.posts.includes(p)) });
        if (msg.tipo === 'varredura') { window.__varreduras.push(msg);
          return cb({ ok: true, dados: { varredura_id: 1, lidas: msg.intimacoes.length, novas: msg.intimacoes.length, completa: msg.varredura.erros.length === 0 } }); }
      }, 5) } };
    }, conhecidas);
    await page.addScriptTag({ content: fs.readFileSync(path.join(__dirname, '..', 'lib', 'advbox_intimacoes.js'), 'utf8') });
    await page.addScriptTag({ content: fs.readFileSync(path.join(__dirname, '..', 'intimacoes.js'), 'utf8') });
    await page.waitForSelector('#oc-varredura button');
  }
  await abrir();
  check('Botão da controladoria aparece na tela de intimações', 'Registrar as intimações desta tela', await page.textContent('#oc-varredura button'));
  await page.click('#oc-varredura button');
  await page.waitForFunction(() => window.__varreduras.length === 1, null, { timeout: 10000 });
  const v = await page.evaluate(() => window.__varreduras[0]);
  check('Varredura: 3 intimações, total do rodapé 3, sem erros', '3|3|0', `${v.intimacoes.length}|${v.varredura.total_informado}|${v.varredura.erros.length}`);
  check('Varredura: período do filtro', '05/10/2026|06/10/2026|Hoje', `${v.varredura.recebido_de}|${v.varredura.recebido_ate}|${v.varredura.filtro.intervalo}`);
  check('Intimação 1: CNJ, data, processo vinculado, teor', '0000101-95.2026.8.02.0001|06/10/2026|600000001|true',
        `${v.intimacoes[0].cnj}|${v.intimacoes[0].data_publicacao}|${v.intimacoes[0].lawsuit_id}|${/Primeiro despacho/.test(v.intimacoes[0].teor)}`);
  check('Intimação "N/A": sem processo, CNJ vindo do teor', 'null|false|0000201-72.2026.8.13.0024',
        `${v.intimacoes[2].lawsuit_id}|${v.intimacoes[2].processo_vinculado}|${v.intimacoes[2].cnj}`);
  check('Token do formulário não é lido nem enviado', 'false', JSON.stringify(v).includes('NAO-DEVE-SER-LIDO'));
  check('Somente pedidos GET ao ADVBOX (nenhum clique, envio ou alteração)', 'true', pedidos.every(p => p.startsWith('GET ')));
  check('Resultado mostrado na tela', 'true', /Varredura #1: 3 intimações/.test(await page.textContent('.oc-varredura-saida')));

  await abrir('1-3 de 84');
  await page.click('#oc-varredura button');
  await page.waitForFunction(() => window.__varreduras.length === 1, null, { timeout: 10000 });
  const v2 = await page.evaluate(() => window.__varreduras[0]);
  check('Tela paginada (3 de 84): varredura enviada com erro de incompletude', 'true', v2.varredura.erros.some(e => /mostra 3 de 84/.test(e)));
  check('Tela paginada: aviso "INCOMPLETA" ao usuário', 'true', /INCOMPLETA/.test(await page.textContent('.oc-varredura-saida')));
  // intimação já conhecida: não é aberta de novo; recusa do ADVBOX: para e registra como incompleta
  pedidos.length = 0;
  await abrir(null, ['700000001']);
  recusar = '700000003';
  await page.click('#oc-varredura button');
  await page.waitForFunction(() => window.__varreduras.length === 1, null, { timeout: 15000 });
  const v3 = await page.evaluate(() => window.__varreduras[0]);
  check('Intimação já conhecida no banco: janela não é aberta de novo', 'false|true',
        `${pedidos.includes('GET /posts/700000001/edit')}|${pedidos.includes('GET /posts/700000002/edit')}`);
  check('Recusa do ADVBOX (HTTP 413): varredura interrompida e marcada com erro', 'true|3',
        `${v3.varredura.erros.some(e => /recusou a leitura \(HTTP 413\)/.test(e))}|${v3.intimacoes.length}`);
  recusar = null;
  await browser.close();

  const w = Math.max(...res.map(x => x[0].length));
  const txt = res.map(([n, e, o, s]) => `${s.padEnd(5)} | ${n.padEnd(w)} | esperado: ${e.slice(0, 50)} | obtido: ${o.slice(0, 50)}`).join('\n')
    + `\n\n${res.filter(x => x[3] === 'OK').length}/${res.length} OK — ${new Date().toLocaleString('pt-BR')}`;
  console.log(txt); fs.writeFileSync(path.join(__dirname, 'resultado_testes_intimacoes.txt'), txt + '\n');
  process.exit(res.every(x => x[3] === 'OK') ? 0 : 1);
})().catch(e => { console.error(e); process.exit(1); });
