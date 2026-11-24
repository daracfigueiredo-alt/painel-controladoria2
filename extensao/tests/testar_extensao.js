/* Testes da extensão (dados FICTÍCIOS), versão 0.2.0:
 *  A) leitura da tela e regras (Node, funções puras), com texto no formato da tela REAL
 *  B) interceptação em navegador (Chromium/Playwright) numa RÉPLICA da estrutura real do
 *     ADVBOX conferida em 06/11/2026 (advbox_real_ficticio.html), com handlers jQuery
 *     delegados no documento — o mesmo mecanismo do ADVBOX.
 * A validação da leitura na tela real está em docs/ETAPA5_EXTENSAO.md. O bloqueio real
 * (clicar em Concluir/Editar numa tarefa verdadeira) depende de tarefa de teste autorizada. */
const path = require('path');
const fs = require('fs');
const { chromium } = require('playwright');
const P = require('../lib/advbox_parse.js');
const res = [];
const check = (nome, esp, obt) => res.push([nome, String(esp), String(obt), String(esp) === String(obt) ? 'OK' : 'FALHA']);

// ---------------- A) funções puras ----------------
// Texto no formato do innerText da janela real (ordem e ícones conferidos em 06/11/2026), conteúdo fictício
const texto = `done\nConcluir\nshare\nCopiar link\nedit\nEditar\ndelete\nExcluir\nclear\nAnálise do Caso\n50pts
TF - 19/10 - Prazo 15 dias. PF: 27/10.\nTexto fictício.\nResponsável\nSituação\nPendente (1)\nData do evento\ntoday\nsegunda, 19/10/2026 (O dia inteiro)
Prazo fatal\ntoday\nterça, 27/10/2026\nAnexos (1)\nArquivo fictício.pdf\nCriado por\nPessoa Fictícia\n16/10/2026 09:15 (8 dias atrás)\nProcesso\n0000001-00.2026.8.13.0001 content_copy\nVisualizar processo
Partes envolvidas\nT001 - Cliente Fictício Ltda\nT001 - Banco Fictício S.A.\nGrupo de ação\nBancário`;
const t = P.lerTela(texto, '900000001');
check('Título (tipo da tarefa, como na tela real)', 'Análise do Caso', t.titulo);
check('Descrição sem a pontuação "50pts"', 'TF - 19/10 - Prazo 15 dias. PF: 27/10.|Texto fictício.', (t.descricao || '').replace('\n', '|'));
check('Data do evento', '19/10/2026', t.data_evento);
check('Prazo fatal (PF da Tarefa)', '27/10/2026', t.prazo_fatal);
check('Criado por / em (abertura)', 'Pessoa Fictícia|16/10/2026 09:15', `${t.criado_por}|${t.criado_em}`);
check('Processo: só o CNJ (sem o ícone "content_copy")', '0000001-00.2026.8.13.0001', t.processo);
check('Partes', 'T001 - Cliente Fictício Ltda|T001 - Banco Fictício S.A.', t.partes.join('|'));
check('PF Judicial anotado (texto/data)', '27/10|2026-10-27', `${t.pf_judicial_tela.texto}|${t.pf_judicial_tela.data}`);
check('Rótulo "Prazo fatal" da tela NÃO vira PF Judicial', 'null', String(P.lerTela(texto.replace(' PF: 27/10.', ''), '1').pf_judicial_tela));
check('Responsáveis a partir do title "Nome: Situação"', 'Pessoa Um|Pendente|296462',
  (r => `${r.nome}|${r.situacao}|${r.usuario_id}`)(P.lerResponsaveis([{ title: 'Pessoa Um: Pendente', classe: 'user-296462' }])[0]));
check('ID: botão e URL iguais', '900000001|false', (r => `${r.id}|${r.conflito}`)(P.idDaTarefa('900000001', 'https://app.advbox.com.br/0?t=900000001')));
check('ID: divergência entre botão e URL = não monitorar', 'null|true', (r => `${r.id}|${r.conflito}`)(P.idDaTarefa('900000001', 'https://app.advbox.com.br/0?t=123')));
check('ID: sem parâmetro na URL usa o botão', '900000001', P.idDaTarefa('900000001', 'https://app.advbox.com.br/').id);
check('Título a partir da linha da lista', 'MANIFESTAÇÃO SIMPLES|INTIMAÇÃO JUDICIAL', P.tituloDaLista('MANIFESTAÇÃO SIMPLES: TF - 05/11 - texto') + '|' + P.tituloDaLista('INTIMAÇÃO JUDICIAL'));
const stBloq = { inicio_tratativa_em: null, modos: { conclusao: 'bloquear', pf: 'bloquear', realocacao: 'bloquear' }, papel: 'colaborador', justificativa_minima: 15 };
const sit = a => a.decisao + '/' + a.estado;
check('Conclusão sem início (bloquear)', 'bloquear/bloqueio_efetivo', sit(P.avaliarConclusao(stBloq)));
check('Conclusão com início', 'permitir/permitida_apos_validacao', sit(P.avaliarConclusao({ ...stBloq, inicio_tratativa_em: '2026-10-24T12:00:00Z' })));
check('Conclusão sem início (observar)', 'permitir/violacao_detectada', sit(P.avaliarConclusao({ ...stBloq, modos: { conclusao: 'observar' } })));
check('Conclusão sem conexão', 'permitir/nao_monitorada', sit(P.avaliarConclusao(null)));
const ed = (o = {}) => ({ editing: '1', date: { atual: '19/10/2026', original: '19/10/2026' }, hour: { atual: '', original: '' },
  date_deadline: { atual: '27/10/2026', original: '27/10/2026' }, guests: ['296462'], guests_ao_abrir: ['296462'], ...o });
const tSemJud = { ...t, pf_judicial_tela: null };
check('Edição sem mudar data/PF/responsável: nenhuma trava', '0', P.avaliarEdicao(ed(), t, stBloq, '').length);
check('Edição: PF alterado em tarefa com PF Judicial (mesmo admin)', 'tentativa_alteracao_pf/bloqueio_efetivo',
  (a => a.tipo + '/' + a.estado)(P.avaliarEdicao(ed({ date_deadline: { atual: '30/10/2026', original: '27/10/2026' } }), t, { ...stBloq, papel: 'admin' }, 'Justificativa suficientemente longa.')[0]));
check('Edição: PF não judicial, admin com justificativa', 'permitida_apos_validacao',
  P.avaliarEdicao(ed({ date_deadline: { atual: '30/10/2026', original: '27/10/2026' } }), tSemJud, { ...stBloq, papel: 'admin' }, 'Autorizado pela controladoria: cliente pediu prazo.')[0].estado);
check('Edição: PF não judicial, colaborador', 'bloqueio_efetivo',
  P.avaliarEdicao(ed({ date_deadline: { atual: '30/10/2026', original: '27/10/2026' } }), tSemJud, stBloq, 'Justificativa suficientemente longa.')[0].estado);
check('Edição: data alterada sem justificativa = realocação bloqueada', 'tentativa_realocacao/bloqueio_efetivo/data',
  (a => `${a.tipo}/${a.estado}/${a.extra.alteracoes}`)(P.avaliarEdicao(ed({ date: { atual: '21/10/2026', original: '19/10/2026' } }), t, stBloq, 'ok')[0]));
check('Edição: responsável trocado com justificativa = realocação permitida', 'permitida_apos_validacao/responsavel',
  (a => `${a.estado}/${a.extra.alteracoes}`)(P.avaliarEdicao(ed({ guests: ['296463'] }), t, stBloq, 'MG - redistribuição por férias da responsável.')[0]));
check('Encaminhar sem justificativa: registra violação mas NUNCA bloqueia', 'permitir/violacao_detectada',
  sit(P.avaliarEncaminhamento({ user: 'X' }, stBloq, '')));

// ---------------- B) navegador ----------------
(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage();
  const lib = fs.readFileSync(path.join(__dirname, '..', 'lib', 'advbox_parse.js'), 'utf8');
  const content = fs.readFileSync(path.join(__dirname, '..', 'content.js'), 'utf8');
  const URL_BASE = 'file://' + path.join(__dirname, 'advbox_real_ficticio.html');

  async function abrir(mock, query = '?t=900000001') {
    await page.goto(URL_BASE + query);
    await page.evaluate(m => {
      window.__mock = m; window.__eventos = []; window.__pedidos = [];
      window.chrome = { runtime: { lastError: null, sendMessage: (msg, cb) => {
        window.__pedidos.push(msg.tipo);
        const atraso = msg.tipo === 'status' ? (window.__mock.atrasoStatus || 0) : 0;
        setTimeout(() => {
          if (msg.tipo === 'status') return cb(window.__mock.status ? { ok: true, dados: JSON.parse(JSON.stringify(window.__mock.status)) } : { ok: false, erro: 'sem_sessao' });
          if (msg.tipo === 'inicios') return cb(window.__mock.status ? { ok: true, dados: { modos: window.__mock.status.modos, inicios: window.__mock.inicios || {} } } : { ok: false, erro: 'sem_sessao' });
          if (msg.tipo === 'reedicao') { (window.__reed = window.__reed || []).push(msg);
            return cb({ ok: true, dados: { status: 'ligada', tarefa_id: 1 } }); }
          if (msg.tipo === 'evento') { window.__eventos.push(msg.evento);
            return cb({ ok: true, dados: { status: 'registrado', ocorrido_em: '2026-11-06T15:00:00Z' } }); }
        }, atraso);
      } } };
    }, mock);
    await page.addScriptTag({ content: lib });
    await page.addScriptTag({ content });
    await page.waitForTimeout(mock.atrasoStatus ? 450 : 700);
  }
  const ev = async () => { await page.waitForTimeout(150); return page.evaluate(() => window.__eventos.map(e => `${e.p_tipo}:${e.p_estado_trava}`).join(',')); };
  const g = n => page.evaluate(k => window[k], n);
  const concluir = () => page.click('.task-container a.toggle[data-id]');
  const status = (o = {}) => ({ inicio_tratativa_em: null, pf_judicial_excel: null, papel: 'colaborador', justificativa_minima: 15, vinculo_excel: 'excel_unico',
    modos: { conclusao: 'bloquear', pf: 'bloquear', realocacao: 'bloquear' }, ...o });

  // 1. janela: painel, bloqueio e início
  await abrir({ status: status(), inicios: { '900000003': '2026-11-05T12:00:00Z' } });
  check('Painel exibido na janela da tarefa', 'Tratativa ainda não iniciada.Iniciar tratativa', await page.textContent('.oc-painel').then(s => s.split('PF')[0]));
  const snap = await page.evaluate(() => 1) && JSON.parse(await page.evaluate(() => JSON.stringify(window.__mockSnap || null)));
  await concluir();
  check('Janela: Concluir sem início NÃO chega ao ADVBOX', '0', await g('__concluido'));
  check('Janela: tentativa registrada como bloqueio', 'tentativa_conclusao:bloqueio_efetivo', await ev());
  const enviado = await page.evaluate(() => window.__eventos[0].p_snapshot);
  check('Leitura enviada ao banco: título, datas, CNJ e responsável', 'Análise do Caso|19/10/2026|27/10/2026|0000001-00.2026.8.13.0001|Pessoa Fictícia Um',
    `${enviado.titulo}|${enviado.data_evento}|${enviado.prazo_fatal}|${enviado.processo}|${(enviado.responsaveis[0] || {}).nome}`);
  await page.click('.oc-painel button'); await page.waitForTimeout(200);
  await concluir();
  check('Janela: após "Iniciar tratativa", Concluir passa', '1', await g('__concluido'));

  // 2. lista: conclusão direto pelo círculo "Resolvido"
  await page.waitForTimeout(300); await page.evaluate(() => { window.__eventos = []; });
  await page.click('a.change-status[data-post="900000002"]');
  check('Lista: Concluir sem início bloqueado (não chega ao ADVBOX)', '|tentativa_conclusao:bloqueio_efetivo',
    `${(await g('__listaConcluida')).join(',')}|${await ev()}`);
  check('Lista: título lido da linha', 'MANIFESTAÇÃO SIMPLES', await page.evaluate(() => window.__eventos[0].p_snapshot.titulo));
  await page.waitForTimeout(300); await page.evaluate(() => { window.__eventos = []; });
  await page.click('a.change-status[data-post="900000003"]');
  check('Lista: tarefa com início registrado conclui normalmente', '900000003|tentativa_conclusao:permitida_apos_validacao',
    `${(await g('__listaConcluida')).join(',')}|${await ev()}`);
  check('Lista: consulta em lote feita (um pedido para as linhas visíveis)', 'true', (await g('__pedidos')).includes('inicios'));
  await page.waitForTimeout(300); await page.evaluate(() => { window.__eventos = []; });
  await page.click('a.change-status[data-post="900000009"]');
  check('Lista: intimação (grupo "publication") fora da trava: conclui sem registro', '900000003,900000009|',
    `${(await g('__listaConcluida')).join(',')}|${await ev()}`);
  await page.click('a.change-status[data-field="important"]');
  check('Lista: outros ícones (Importante) não são afetados', '0', await page.evaluate(() => window.__eventos.length));

  // 3. "Atribuir tarefa" cria tarefa NOVA: nenhuma trava, nenhum registro
  await abrir({ status: status() });
  await page.fill('form.modal-body-comment [name=date]', '30/10/2026');
  await page.fill('form.modal-body-comment [name=date_deadline]', '31/10/2026');
  await page.click('form.modal-body-comment button[type=submit]');
  check('"Atribuir tarefa" (cria tarefa nova) não é tratado como realocação', '30/10/2026|', `${(await g('__atribuido') || {}).date}|${await ev()}`);

  // 4. "Editar tarefa": campo de justificativa inserido, sem name (não vai para o ADVBOX)
  check('Editar tarefa: campo "Justificativa (controladoria)" inserido', 'true', await page.isVisible('form.modal-inner-create textarea[data-oc="justificativa"]'));
  await page.fill('form.modal-inner-create [name=date_deadline]', '30/10/2026');
  await page.click('form.modal-inner-create button[type=submit]');
  check('Editar: PF alterado em tarefa com PF Judicial bloqueado', 'null|tentativa_alteracao_pf:bloqueio_efetivo', `${JSON.stringify(await g('__editado'))}|${await ev()}`);

  await abrir({ status: status() });
  await page.click('form.modal-inner-create button.dia');
  check('Clique num dia do calendário (button sem type) não é tratado como envio', '', await ev());
  await page.fill('form.modal-inner-create [name=date]', '21/10/2026');
  await page.click('form.modal-inner-create button[type=submit]');
  check('Editar: data alterada sem justificativa bloqueada', 'null|tentativa_realocacao:bloqueio_efetivo', `${JSON.stringify(await g('__editado'))}|${await ev()}`);
  await page.fill('form.modal-inner-create textarea[data-oc="justificativa"]', 'MG - 06/11 - Realocada a pedido do responsável, aguardando cliente.');
  await page.waitForTimeout(1600);
  await page.click('form.modal-inner-create button[type=submit]');
  await page.waitForTimeout(300);
  const editado = await g('__editado');
  check('Editar: com justificativa passa e a justificativa NÃO é enviada ao ADVBOX', '21/10/2026|false',
    `${(editado || {}).date}|${JSON.stringify(editado).includes('Realocada a pedido')}`);
  check('Editar: justificativa registrada no evento da controladoria', 'true',
    await page.evaluate(() => window.__eventos.some(e => e.p_tipo === 'tentativa_realocacao' && /Realocada a pedido/.test(e.p_justificativa || ''))));
  // 4b. ADVBOX recria a tarefa ao salvar a edição (novo ID): a extensão liga o novo ao antigo
  await page.evaluate(() => {
    history.replaceState(null, '', location.pathname + '?t=900000077');
    document.querySelectorAll('.task-container [data-id="900000001"]').forEach(e => e.setAttribute('data-id', '900000077'));
    const c = document.querySelector('.task-container'); c.style.display = 'none';
    setTimeout(() => { c.style.display = ''; }, 400);
  });
  await page.waitForTimeout(1500);
  const reed = await g('__reed');
  check('Edição salva: tarefa recriada pelo ADVBOX é ligada à original (antigo -> novo)', '900000001->900000077|1',
    reed ? `${reed[0].antigo}->${reed[0].novo}|${reed.length}` : 'nenhum');
  check('Edição salva: a ligação é pedida uma única vez', 'null', String(await page.evaluate(() => sessionStorage.getItem('oc_reedicao'))));

  check('Token da página nunca é enviado', 'false', await page.evaluate(() => JSON.stringify(window.__eventos).includes('NAO-DEVE-SER-LIDO')));

  await abrir({ status: status() });
  await page.evaluate(() => { const g = document.querySelector('form.modal-inner-create [name="guests[]"]'); g.value = '296463'; });
  await page.fill('form.modal-inner-create textarea[data-oc="justificativa"]', 'Redistribuição por férias da responsável (fictício).');
  await page.click('form.modal-inner-create button[type=submit]');
  check('Editar: troca de responsável detectada como realocação (com justificativa: passa)', '296463|tentativa_realocacao:permitida_apos_validacao',
    `${(await g('__editado') || {})['guests[]']}|${await ev()}`);

  // 5. modo observar (padrão das travas 2 e 3)
  await abrir({ status: status({ modos: { conclusao: 'bloquear', pf: 'observar', realocacao: 'observar' } }) });
  await page.fill('form.modal-inner-create [name=date_deadline]', '30/10/2026');
  await page.click('form.modal-inner-create button[type=submit]');
  check('Editar em modo observar: passa e registra violação', '30/10/2026|tentativa_alteracao_pf:violacao_detectada',
    `${(await g('__editado') || {}).date_deadline}|${await ev()}`);

  // 6. Encaminhar: registra, não bloqueia
  await abrir({ status: status() });
  await page.waitForTimeout(800);
  check('Campo de justificativa inserido UMA vez por formulário, dentro dele', '1|1|0',
    await page.evaluate(() => [document.querySelectorAll('form.modal-inner-create textarea[data-oc]').length,
      document.querySelectorAll('form.form-event textarea[data-oc]').length,
      [...document.querySelectorAll('textarea[data-oc]')].filter(t => !t.closest('form')).length].join('|')));
  await page.click('form.form-event button[type=submit]');
  check('Encaminhar sem justificativa: passa e registra violação', '900000001|tentativa_realocacao:violacao_detectada',
    `${(await g('__encaminhado') || {}).post_id}|${await ev()}`);

  // 7. sem login/conexão
  await abrir({ status: null });
  await concluir();
  check('Sem login → não monitorada (não bloqueia)', '1|tentativa_conclusao:nao_monitorada', `${await g('__concluido')}|${await ev()}`);
  check('Painel avisa que não há monitoramento', 'true', await page.textContent('.oc-painel').then(s => /NÃO está sendo monitorada/.test(s)));
  await page.click('a.change-status[data-post="900000002"]');
  check('Sem login, lista: não bloqueia e registra não monitorada', '900000002', (await g('__listaConcluida')).join(','));

  // 8. consulta em andamento
  await abrir({ status: status(), atrasoStatus: 1500 });
  await concluir();
  check('Clique antes da verificação é segurado (sem registro)', '0|', `${await g('__concluido')}|${await ev()}`);

  // 9. ID divergente entre botão e URL
  await abrir({ status: status() }, '?t=123');
  check('ID divergente (botão x URL): não monitora e avisa', 'true', await page.textContent('.oc-painel').then(s => /divergente/.test(s)));

  // 10. reabertura reconsulta (A9)
  await abrir({ status: status() });
  const n1 = (await g('__pedidos')).filter(x => x === 'status').length;
  await page.evaluate(() => { document.querySelector('.task-container').style.display = 'none'; });
  await page.waitForTimeout(500);
  await page.evaluate(() => { document.querySelector('.task-container').style.display = ''; });
  await page.waitForTimeout(700);
  check('Reabrir a janela consulta o status de novo', String(n1 + 1), (await g('__pedidos')).filter(x => x === 'status').length);

  await browser.close();
  const w = Math.max(...res.map(r => r[0].length));
  for (const [n, e, o, s] of res) console.log(`${s.padEnd(5)} | ${n.padEnd(w)} | esperado: ${e} | obtido: ${o}`);
  console.log(`\n${res.filter(r => r[3] === 'OK').length}/${res.length} OK`);
  process.exit(res.every(r => r[3] === 'OK') ? 0 : 1);
})().catch(e => { console.error(e); process.exit(2); });
