/* Testes da extensão no Atlas Gestor (0.5.0, 11/11/2026; 0.7.0, 17/11/2026) — dados FICTÍCIOS.
 * Parte 1: regras puras (lib/atlas_regras.js).
 * Parte 2: página SIMULADA no endereço do Atlas (Chromium), com a ponte (atlas_ponte.js) e o
 * script da extensão (atlas_content.js) de verdade; o "background" e a "API do Atlas" são
 * simulados. Valida que a gravação bloqueada NÃO chega ao servidor. Não usa o Atlas real. */
'use strict';
const fs = require('fs'), path = require('path');
const { chromium } = require('playwright');
const A = require('../lib/atlas_regras.js');
const res = []; const check = (n, e, o) => res.push([n, String(e), String(o), String(e) === String(o) ? 'OK' : 'FALHA']);
const T1 = 'aaaaaaaa-0000-4000-8000-00000000000a', T2 = 'bbbbbbbb-0000-4000-8000-00000000000b', U1 = '11111111-1111-4111-8111-111111111111';
const BASE = 'https://tdhgpaurcjinhbandmvb.supabase.co/rest/v1/';

// ------------------------------------------------------------ parte 1
const conh = new Map([[T1, { status: 'todo', due_date: '2026-11-20', fatal_date: '2026-11-25', user_id: U1, assignees: [U1] }]]);
const ops = (m, u, c) => A.interpretarGravacao(m, BASE + u, JSON.stringify(c), conh);
check('PATCH status done = conclusão', 'true', ops('PATCH', `tasks?id=eq.${T1}`, { status: 'done' })[0].conclusao);
check('Upsert com o mesmo vencimento: nada a conferir', 0, ops('POST', 'tasks?on_conflict=id', [{ id: T1, due_date: '2026-11-20', title: 'x' }]).length);
check('Upsert mudando vencimento e prazo fatal', '2026-11-20>2026-11-22|2026-11-25>2026-11-30',
  (o => `${o.due.de}>${o.due.para}|${o.fatal.de}>${o.fatal.para}`)(ops('POST', 'tasks?on_conflict=id', [{ id: T1, due_date: '2026-11-22', fatal_date: '2026-11-30' }])[0]));
check('Tarefa desconhecida (criação): não confere', 0, ops('POST', 'tasks', [{ id: T2, status: 'done' }]).length);
check('Baixa de um responsável (task_assignees com completed_at) = conclusão', 'true|true',
  (o => `${o.conclusao}|${o.baixa_parcial}`)(ops('PATCH', `task_assignees?task_id=eq.${T1}&user_id=eq.${U1}`, { completed_at: '2026-11-11T10:00:00Z' })[0]));
check('"Dar baixa na minha parte" (rotina complete_task_assignee_tx) = conclusão', 'true|true',
  (o => `${o.conclusao}|${o.baixa_parcial}`)(A.interpretarGravacao('POST', BASE + 'rpc/complete_task_assignee_tx', JSON.stringify({ p_task_id: T1, p_user_id: U1 }), conh)[0]));
check('Desfazer a baixa (uncomplete) não é conferido', 0, A.interpretarGravacao('POST', BASE + 'rpc/uncomplete_task_assignee_tx', JSON.stringify({ p_task_id: T1, p_user_id: U1 }), conh).length);
check('Responsável novo = realocação', '1', ops('POST', 'task_assignees?on_conflict=task_id,user_id', [{ task_id: T1, user_id: '22222222-2222-4222-8222-222222222222' }])[0].responsaveis.adicionados.length);
check('Leitura nunca é conferida', 0, A.interpretarGravacao('GET', BASE + 'tasks?select=*', null, conh).length);
const st = (x = {}) => Object.assign({ papel: 'colaborador', inicio_tratativa_em: null, pf_judicial_excel: null, justificativa_minima: 15,
  modos: { conclusao: 'bloquear', realocacao: 'bloquear', pf: 'bloquear' } }, x);
check('Concluir sem início: bloqueia', 'bloquear|bloqueio_efetivo', (a => `${a.decisao}|${a.estado}`)(A.avaliarOperacao({ conclusao: true }, st())[0]));
check('Concluir com início: permite', 'permitida_apos_validacao', A.avaliarOperacao({ conclusao: true }, st({ inicio_tratativa_em: '2026-11-11T10:00:00Z' }))[0].estado);
check('Mudar vencimento sem justificativa: bloqueia e pede justificativa', 'bloquear|true', (a => `${a.decisao}|${a.precisa_justificativa}`)(A.avaliarOperacao({ due: { de: 'a', para: 'b' } }, st())[0]));
check('Com justificativa: permite', 'permitida_apos_validacao', A.avaliarOperacao({ due: { de: 'a', para: 'b' } }, st(), 'cliente pediu nova reunião')[0].estado);
check('Líder muda vencimento: exceção autorizada', 'permitir|excecao_autorizada',
  (a => `${a.decisao}|${a.estado}`)(A.avaliarOperacao({ due: { de: 'a', para: 'b' } }, st({ papel: 'lider', modos: { conclusao: 'bloquear', realocacao: 'lider_livre', pf: 'lider_livre' } }))[0]));
check('Líder concluindo sem início: continua bloqueado', 'bloquear',
  A.avaliarOperacao({ conclusao: true }, st({ papel: 'lider', modos: { conclusao: 'bloquear', realocacao: 'lider_livre', pf: 'lider_livre' } }))[0].decisao);
check('Prazo fatal com PF Judicial: bloqueia sem opção de justificar', 'bloquear|false',
  (a => `${a.decisao}|${!!a.precisa_justificativa}`)(A.avaliarOperacao({ fatal: { de: '2026-11-25', para: '2026-11-30' } }, st({ papel: 'admin', pf_judicial_excel: '2026-11-25' }))[0]));
check('Sem conexão/login: não monitorada (permite)', 'permitir|nao_monitorada', (a => `${a.decisao}|${a.estado}`)(A.avaliarOperacao({ conclusao: true }, null)[0]));
// 0.7.0: conclusão com justificativa e "em andamento" = início da tratativa
const comInicio = { inicio_tratativa_em: '2026-11-11T10:00:00Z', conclusao_exige_justificativa: true };
check('0.7.0 Concluir com início e sem justificativa: bloqueia e pede justificativa', 'bloquear|true|true',
  (a => `${a.decisao}|${a.precisa_justificativa}|${a.extra.justificativa_conclusao}`)(A.avaliarOperacao({ conclusao: true }, st(comInicio))[0]));
check('0.7.0 Concluir com justificativa: permite', 'permitida_apos_validacao', A.avaliarOperacao({ conclusao: true }, st(comInicio), 'Contestação protocolada no prazo')[0].estado);
check('0.7.0 Justificativa curta: continua bloqueado', 'bloquear', A.avaliarOperacao({ conclusao: true }, st(comInicio), 'feito')[0].decisao);
check('0.7.0 Sem início: o bloqueio de início vem antes e não é justificável', 'bloquear|false',
  (a => `${a.decisao}|${!!a.precisa_justificativa}`)(A.avaliarOperacao({ conclusao: true }, st({ conclusao_exige_justificativa: true }))[0]));
check('0.7.0 Líder também justifica a conclusão', 'bloquear|true',
  (a => `${a.decisao}|${a.precisa_justificativa}`)(A.avaliarOperacao({ conclusao: true }, st(Object.assign({ papel: 'lider', modos: { conclusao: 'bloquear', realocacao: 'lider_livre', pf: 'lider_livre' } }, comInicio)))[0]));
check('0.7.0 Regra desligada no servidor: conclusão com início passa sem justificativa', 'permitida_apos_validacao',
  A.avaliarOperacao({ conclusao: true }, st({ inicio_tratativa_em: '2026-11-11T10:00:00Z', conclusao_exige_justificativa: false }))[0].estado);
check('0.7.0 Baixa na minha parte também pede justificativa', 'true', A.avaliarOperacao({ conclusao: true, baixa_parcial: true }, st(comInicio))[0].precisa_justificativa);
check('0.7.0 Mudar para "em andamento" = operação de início', 'true', ops('PATCH', `tasks?id=eq.${T1}`, { status: 'doing' })[0].em_andamento);
check('0.7.0 "Em andamento" não é trava (nenhuma avaliação)', 0, A.avaliarOperacao({ atlas_id: T1, em_andamento: true }, st()).length);
check('0.7.0 Já em andamento: não repete', 0,
  A.interpretarGravacao('PATCH', BASE + `tasks?id=eq.${T1}`, JSON.stringify({ status: 'doing' }), new Map([[T1, { status: 'doing' }]])).length);
check('0.7.0 Voltar de concluída para andamento: não conta (reabertura)', 0,
  A.interpretarGravacao('PATCH', BASE + `tasks?id=eq.${T1}`, JSON.stringify({ status: 'doing' }), new Map([[T1, { status: 'done' }]])).length);

// ------------------------------------------------------------ parte 2: página simulada
const PAGINA = `<!doctype html><html><head><meta charset="utf-8"><title>Atlas Gestor (SIMULADO)</title></head><body>
<p id="erro"></p><div id="raiz"></div>
<script>
  const T1='${T1}', U1='${U1}', BASE='${BASE}';
  async function salvar(url, metodo, corpo) {
    const r = await fetch(BASE + url, { method: metodo, headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(corpo) });
    document.getElementById('erro').textContent = r.ok ? 'salvo' : 'erro: ' + (await r.json()).message;
  }
  window.abrirTarefa = function () {
    const d = document.createElement('div'); d.setAttribute('role', 'dialog');
    d.innerHTML = '<h2>Reunião (teste)</h2><div><button id="editar">Editar</button><button id="concluir">Concluir</button></div>';
    d.__reactFiber$teste = { memoizedProps: { task: { id: T1, title: 'Reunião (teste)', status: 'todo', dueDate: '2026-11-20', fatalDate: '2026-11-25', userId: U1,
      assignees: [{ userId: U1, name: 'Ana Teste', isPrincipal: true }] }, currentUser: { id: U1, name: 'Ana Teste', email: 'NAO-DEVE-SAIR' } }, return: null };
    document.getElementById('raiz').append(d);
    d.querySelector('#concluir').onclick = () => salvar('tasks?id=eq.' + T1, 'PATCH', { status: 'done' });
  };
  fetch(BASE + 'tasks?select=*').then(r => r.json());
</script></body></html>`;

(async () => {
  const navegador = await chromium.launch();
  const pag = await navegador.newPage();
  const noServidor = [];         // gravações que CHEGARAM ao "Atlas"
  const eventos = []; let cenario = {};
  const execChamadas = [];
  const execucao = { encontrada: true, tarefa_id: 77, exigido: false, completo: false, modo: 'bloquear', pode_editar: true, anexo_tamanho_maximo_mb: 20,
    modalidade: { nome: 'Contestação', ativa: false, link_treinamento: 'https://treinamento.exemplo/c', link_notebooklm: 'https://notebooklm.google.com/notebook/x', orientacoes: 'Orientação fictícia' },
    checklist: [{ id: 'prazos', texto: 'Conferi os prazos', marcado: false }, { id: 'notebooklm', texto: 'Conferi no NotebookLM', marcado: false }],
    anexos: [], pendencias: ['Checklist: Conferi os prazos', 'Anexar a peça produzida', 'Anexar o parecer de autoavaliação'] };
  const exc = { encontrada: true, ativa: false, d4: '2026-11-19', pf_judicial: '2026-11-25', pode_definir: true, justificativa_minima: 15 }; const excChamadas = [];
  await pag.route('https://gestor.atlasjus.com/**', r => r.fulfill({ contentType: 'text/html', body: PAGINA }));
  await pag.route(BASE + '**', async r => {
    const req = r.request();
    if (req.method() === 'GET') return r.fulfill({ contentType: 'application/json', body: JSON.stringify([{ id: T1, status: 'todo', due_date: '2026-11-20', fatal_date: '2026-11-25', user_id: U1 },
      { id: T2, status: 'todo', due_date: '2026-11-21', fatal_date: null, user_id: U1 }]) });
    noServidor.push({ metodo: req.method(), url: req.url(), corpo: req.postData() });
    return r.fulfill({ contentType: 'application/json', body: '[]' });
  });
  // "background" simulado: status da controladoria por cenário e registro dos eventos
  await pag.exposeFunction('__bg', msg => {
    if (msg.tipo === 'status') return { ok: true, dados: Object.assign(st(), cenario) };
    if (msg.tipo === 'evento') { eventos.push(msg.evento); if (msg.evento.p_tipo === 'inicio_tratativa') cenario.inicio_tratativa_em = '2026-11-11T13:00:00Z'; return { ok: true, dados: { status: 'registrado' } }; }
    if (msg.tipo === 'execucao') return { ok: true, dados: Object.assign({}, execucao) };   // 0039
    if (msg.tipo === 'execucao_marcar') { execChamadas.push(msg); execucao.checklist.find(i => i.id === msg.item).marcado = msg.marcado; return { ok: true, dados: execucao }; }
    if (msg.tipo === 'anexo') { execChamadas.push(Object.assign({}, msg, { base64: msg.base64.length })); return { ok: true, dados: execucao }; }
    if (msg.tipo === 'excecao_d4') {   // 0037
      if (typeof msg.ativa === 'boolean') { excChamadas.push(msg); Object.assign(exc, { ativa: msg.ativa, justificativa: msg.justificativa, por: 'Brenda Martins', em: '2026-11-11T19:00:00Z' }); }
      return { ok: true, dados: Object.assign({}, exc) };
    }
    return { ok: false };
  });
  const ler = f => fs.readFileSync(path.join(__dirname, '..', f), 'utf8');
  await pag.addInitScript({ content: ler('lib/atlas_regras.js') + '\n' + ler('atlas_ponte.js') });
  await pag.addInitScript({ content: `window.chrome = { runtime: { lastError: null, sendMessage: (m, cb) => window.__bg(m).then(cb) } };` });
  await pag.addInitScript({ content: `document.addEventListener('DOMContentLoaded', () => { ${ler('lib/atlas_regras.js')}\n${ler('atlas_content.js')} });` });
  await pag.goto('https://gestor.atlasjus.com/#/tasks');
  await pag.waitForTimeout(300);

  // painel na janela da tarefa
  await pag.evaluate(() => window.abrirTarefa());
  await pag.waitForSelector('.oc-painel button');
  check('Janela da tarefa: painel com "Iniciar tratativa"', 'Iniciar tratativa', await pag.textContent('.oc-painel button'));
  await pag.waitForSelector('.oc-d4');
  check('Painel mostra o D-4 (entrega) e o PF Judicial', 'true', /D-4 \(entrega\): 19\/11\/2026 · PF Judicial: 25\/11\/2026/.test(await pag.textContent('.oc-d4')));
  check('Líder/controladoria: botão de exceção de D-4', 'Autorizar entrega após o D-4', await pag.textContent('.oc-d4 button'));
  // concluir sem início: bloqueado, não chega ao servidor
  await pag.click('#concluir');
  await pag.waitForSelector('dialog.oc-dialogo');
  check('Concluir sem início: diálogo de bloqueio', 'true', /bloqueada/.test(await pag.textContent('dialog.oc-dialogo h2')));
  await pag.click('dialog.oc-dialogo .oc-btn');
  await pag.waitForFunction(() => /erro/.test(document.getElementById('erro').textContent));
  check('Bloqueado: a gravação NÃO chegou ao Atlas', 0, noServidor.length);
  check('Bloqueado: o Atlas recebe o erro com o motivo', 'true', /controladoria/i.test(await pag.textContent('#erro')));
  check('Bloqueio registrado como evento', 'tentativa_conclusao|bloqueio_efetivo|' + T1, (e => `${e.p_tipo}|${e.p_estado_trava}|${e.p_advbox_id}`)(eventos[eventos.length - 1]));
  // "Dar baixa na minha parte" sem início: bloqueada antes de sair
  const pb = pag.evaluate(() => salvar('rpc/complete_task_assignee_tx', 'POST', { p_task_id: T1, p_user_id: U1 }));
  await pag.waitForSelector('dialog.oc-dialogo');
  await pag.click('dialog.oc-dialogo .oc-btn');
  await pb;
  check('Baixa na minha parte sem início: bloqueada e não chega ao Atlas', 0, noServidor.length);
  // iniciar tratativa e concluir
  await pag.click('.oc-painel button');
  await pag.waitForFunction(() => /iniciada/.test(document.querySelector('.oc-painel').textContent));
  check('Início da tratativa registrado com o ID do Atlas', 'inicio_tratativa|' + T1, (e => `${e.p_tipo}|${e.p_advbox_id}`)(eventos.find(e => e.p_tipo === 'inicio_tratativa')));
  await pag.click('#concluir');
  await pag.waitForFunction(() => document.getElementById('erro').textContent === 'salvo');
  check('Com início: conclusão chega ao Atlas', 'PATCH|{"status":"done"}', `${noServidor[0].metodo}|${noServidor[0].corpo}`);
  await pag.waitForTimeout(200);
  check('Conclusão permitida registrada depois da confirmação do Atlas', 'permitida_apos_validacao', eventos[eventos.length - 1].p_estado_trava);
  // realocação: pede justificativa
  const mudarData = () => pag.evaluate(() => salvar('tasks?on_conflict=id', 'POST', [{ id: '${T1}'.replace('${T1}', T1), due_date: '2026-11-27' }]));
  noServidor.length = 0;
  const p1 = mudarData();
  await pag.waitForSelector('dialog.oc-dialogo textarea');
  await pag.click('dialog.oc-dialogo .oc-btn-sec');
  await p1;
  check('Mudar vencimento e cancelar a justificativa: nada gravado', '0|true', `${noServidor.length}|${/cancelada/.test(await pag.textContent('#erro'))}`);
  const p2 = mudarData();
  await pag.waitForSelector('dialog.oc-dialogo textarea');
  await pag.fill('dialog.oc-dialogo textarea', 'curta');
  await pag.click('dialog.oc-dialogo .oc-btn:not(.oc-btn-sec)');
  check('Justificativa curta: recusada no diálogo', 'true', /ao menos 15/.test(await pag.textContent('dialog.oc-dialogo .oc-erro')));
  await pag.fill('dialog.oc-dialogo textarea', 'Cliente pediu para remarcar a reunião');
  await pag.click('dialog.oc-dialogo .oc-btn:not(.oc-btn-sec)');
  await p2; await pag.waitForTimeout(200);
  check('Com justificativa: gravado e registrado', `1|tentativa_realocacao|permitida_apos_validacao|Cliente pediu para remarcar a reunião`,
    (e => `${noServidor.length}|${e.p_tipo}|${e.p_estado_trava}|${e.p_justificativa}`)(eventos[eventos.length - 1]));
  // líder: sem diálogo
  cenario.papel = 'lider'; cenario.modos = { conclusao: 'bloquear', realocacao: 'lider_livre', pf: 'lider_livre' };
  noServidor.length = 0;
  await pag.evaluate(() => salvar('tasks?on_conflict=id', 'POST', [{ id: T1, due_date: '2026-12-01', fatal_date: '2026-12-05' }]));
  await pag.waitForTimeout(300);
  check('Líder muda vencimento e prazo fatal: grava sem diálogo', '1|0', `${noServidor.length}|${await pag.locator('dialog.oc-dialogo').count()}`);
  check('Líder: registrado como exceção autorizada', 'excecao_autorizada,excecao_autorizada', eventos.slice(-2).map(e => e.p_estado_trava).join(','));
  // criação de tarefa nova: passa direto
  noServidor.length = 0; const nEv = eventos.length;
  await pag.evaluate(() => salvar('tasks', 'POST', [{ id: 'cccccccc-0000-4000-8000-00000000000c', title: 'Nova', status: 'todo' }]));
  check('Criação de tarefa nova: passa direto, sem evento', `1|${nEv}`, `${noServidor.length}|${eventos.length}`);
  // exceção de D-4 (0037): pede justificativa, vai só para a controladoria (nada é gravado no Atlas)
  noServidor.length = 0;
  await pag.click('.oc-d4 button');
  await pag.waitForSelector('dialog.oc-dialogo textarea');
  check('Exceção de D-4: diálogo próprio', 'Controladoria: autorizar entrega após o D-4', await pag.textContent('dialog.oc-dialogo h2'));
  await pag.fill('dialog.oc-dialogo textarea', 'Cliente enviará documentos na véspera');
  await pag.click('dialog.oc-dialogo .oc-btn:not(.oc-btn-sec)');
  await pag.waitForFunction(() => /autorizada/.test((document.querySelector('.oc-d4') || {}).textContent || ''));
  check('Exceção enviada à controladoria com a justificativa', `1|true|Cliente enviará documentos na véspera|${T1}`,
    `${excChamadas.length}|${excChamadas[0].ativa}|${excChamadas[0].justificativa}|${excChamadas[0].advbox_id}`);
  check('Exceção não grava nada no Atlas', 0, noServidor.length);
  check('Painel mostra quem autorizou e oferece retirar', 'true|Retirar exceção',
    `${/Brenda Martins/.test(await pag.textContent('.oc-d4'))}|${await pag.textContent('.oc-d4 button')}`);
  // execução da modalidade (0039): bloco na janela, checklist, anexo e trava de conclusão
  await pag.waitForSelector('.oc-exec summary');
  check('Bloco de execução com modalidade, links e checklist', 'true|2|2',
    `${/Execução — Contestação \(modelo inativo\)/.test(await pag.textContent('.oc-exec summary'))}|${await pag.locator('.oc-exec a').count()}|${await pag.locator('.oc-checklist input').count()}`);
  await pag.click('.oc-exec summary');
  await pag.locator('.oc-checklist input').first().check();
  await pag.waitForTimeout(200);
  check('Marcar item do checklist vai para a controladoria', 'execucao_marcar|prazos|true|' + T1,
    (c => `${c.tipo}|${c.item}|${c.marcado}|${c.advbox_id}`)(execChamadas[0]));
  await pag.setInputFiles('.oc-exec input[type=file]', { name: 'contestação final.pdf', mimeType: 'application/pdf', buffer: Buffer.from('PDF fictício de teste') });
  await pag.click('.oc-exec button:has-text("Anexar")');
  await pag.waitForTimeout(300);
  check('Anexo enviado pela extensão (arquivo em base64, tamanho e tarefa)', `anexo|peca|77|${Buffer.from('PDF fictício de teste').length}|${Buffer.from('PDF fictício de teste').toString('base64').length}`,
    (c => `${c.tipo}|${c.tipo_anexo}|${c.tarefa_id}|${c.tamanho}|${c.base64}`)(execChamadas[1]));
  Object.assign(execucao, { exigido: true, modalidade: Object.assign(execucao.modalidade, { ativa: true }) });
  noServidor.length = 0;
  const pBaixa = pag.evaluate(() => salvar('rpc/complete_task_assignee_tx', 'POST', { p_task_id: T1, p_user_id: U1 }));
  await pag.waitForSelector('dialog.oc-dialogo');
  check('Concluir com pendência da modalidade ativa: bloqueado com as pendências', 'true', /pendências da modalidade Contestação/.test(await pag.textContent('dialog.oc-dialogo')));
  await pag.click('dialog.oc-dialogo .oc-btn'); await pBaixa;
  check('Pendência de execução: nada chega ao Atlas e o evento traz as pendências', '0|bloqueio_efetivo|3',
    `${noServidor.length}|${eventos[eventos.length - 1].p_estado_trava}|${(eventos[eventos.length - 1].p_evidencia.pendencias_execucao || []).length}`);
  Object.assign(execucao, { completo: true, pendencias: [] });
  await pag.evaluate(() => salvar('rpc/complete_task_assignee_tx', 'POST', { p_task_id: T1, p_user_id: U1 }));
  await pag.waitForTimeout(300);
  check('Execução completa: a baixa passa', '1', noServidor.length);
  // 0.7.0: conclusão exige justificativa
  cenario.conclusao_exige_justificativa = true; noServidor.length = 0;
  const pJ1 = pag.evaluate(() => salvar('rpc/complete_task_assignee_tx', 'POST', { p_task_id: T1, p_user_id: U1 }));
  await pag.waitForSelector('dialog.oc-dialogo');
  check('0.7.0 Baixa: diálogo próprio de justificativa da conclusão', 'Controladoria: justificativa da conclusão|Concluir com justificativa|Cancelar conclusão',
    `${await pag.textContent('dialog.oc-dialogo h2')}|${await pag.textContent('dialog.oc-dialogo .oc-btn:not(.oc-btn-sec)')}|${await pag.textContent('dialog.oc-dialogo .oc-btn-sec')}`);
  await pag.click('dialog.oc-dialogo .oc-btn-sec'); await pJ1;
  check('0.7.0 Cancelar a justificativa: a baixa não chega ao Atlas', '0|true', `${noServidor.length}|${/cancelada/.test(await pag.textContent('#erro'))}`);
  const pJ2 = pag.evaluate(() => salvar('rpc/complete_task_assignee_tx', 'POST', { p_task_id: T1, p_user_id: U1 }));
  await pag.waitForSelector('dialog.oc-dialogo');
  await pag.fill('dialog.oc-dialogo textarea', 'Petição protocolada e comprovante anexado');
  await pag.click('dialog.oc-dialogo .oc-btn:not(.oc-btn-sec)'); await pJ2;
  await pag.waitForTimeout(300);
  check('0.7.0 Com justificativa: a baixa chega ao Atlas e o evento leva a justificativa', '1|tentativa_conclusao|permitida_apos_validacao|Petição protocolada e comprovante anexado',
    (e => `${noServidor.length}|${e.p_tipo}|${e.p_estado_trava}|${e.p_justificativa}`)(eventos[eventos.length - 1]));
  // 0.7.0: mudar a tarefa para "em andamento" registra o início da tratativa
  cenario.inicio_tratativa_em = null; noServidor.length = 0; const nEv2 = eventos.length;
  await pag.evaluate(() => salvar('tasks?id=eq.bbbbbbbb-0000-4000-8000-00000000000b', 'PATCH', { status: 'doing' }));
  await pag.waitForTimeout(300);
  const ini = eventos.slice(nEv2).find(e => e.p_tipo === 'inicio_tratativa');
  check('0.7.0 "Em andamento": grava no Atlas sem diálogo e registra o início', `1|0|${T2}|status_em_andamento_atlas`,
    `${noServidor.length}|${await pag.locator('dialog.oc-dialogo').count()}|${ini && ini.p_advbox_id}|${ini && ini.p_evidencia.acao}`);
  check('Dados do usuário além de id e nome não saem da página', 'false', JSON.stringify(eventos).includes('NAO-DEVE-SAIR'));
  await navegador.close();

  const w = Math.max(...res.map(r => r[0].length));
  for (const [n, e, o, s] of res) console.log(`${s.padEnd(5)} ${n.padEnd(w)}` + (s === 'OK' ? '' : `  esperado=${e} obtido=${o}`));
  const ok = res.filter(r => r[3] === 'OK').length; console.log(`\n${ok}/${res.length} OK`); process.exit(ok === res.length ? 0 : 1);
})().catch(e => { console.error(e); process.exit(1); });
