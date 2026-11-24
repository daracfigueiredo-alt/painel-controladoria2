/* Script de conteúdo — roda na página do ADVBOX (somente com a extensão instalada e ativa).
 * 1) Janela da tarefa: lê os dados visíveis, consulta a controladoria e mostra o painel
 *    com "Iniciar tratativa". Reconsulta a cada reabertura (o status pode ter mudado).
 * 2) Trava 1 — Concluir sem início: na janela (botão "Concluir") e na LISTA (círculo
 *    "Resolvido"), interceptando o clique ANTES do ADVBOX (fase de captura).
 * 3) Travas 2 e 3 — formulário "Editar tarefa": data, prazo fatal e responsáveis.
 *    Insere o campo "Justificativa (controladoria)" e avalia no envio.
 * 4) "Encaminhar": registra, com justificativa, sem bloquear (efeito a confirmar).
 * "Atribuir tarefa" cria uma tarefa NOVA: não é tratado como realocação.
 * Sem extensão ativa, nada disso acontece — por isso a importação diária continua
 * detectando, depois, conclusões sem início e alterações sem justificativa.
 */
(function () {
  'use strict';
  const P = globalThis.OCParse;
  const estado = new Map();   // advbox_id -> { tela, status, carregado }
  const inicios = new Map();  // advbox_id -> { inicio_tratativa_em, quando }  (lista)
  let modosLista = null, statusListaDisponivel = null;

  const enviar = msg => new Promise(res => {
    try { chrome.runtime.sendMessage(msg, r => res(chrome.runtime.lastError ? { ok: false, erro: chrome.runtime.lastError.message } : r)); }
    catch (e) { res({ ok: false, erro: e.message }); }
  });
  const uuid = () => crypto.randomUUID();
  // offsetParent é null em elementos com position:fixed — a janela da tarefa aberta por link
  // (app.advbox.com.br/0?t=ID) é um modal fixo. Visível = tem caixa na tela e não está oculto.
  const visivel = el => !!(el && el.getClientRects().length > 0 && getComputedStyle(el).visibility !== 'hidden');

  // ---------------------------------------------------------------- janela da tarefa
  function containerAberto() {
    return [...document.querySelectorAll('.task-container')].find(c => visivel(c) && c.querySelector('a.toggle[data-id]'));
  }
  function idDe(container) {
    const a = container && container.querySelector('a.toggle[data-id]');
    return P.idDaTarefa(a ? a.getAttribute('data-id') : null, location.href);
  }
  function responsaveisDe(container) {
    return P.lerResponsaveis([...container.querySelectorAll('ul.task-item-users li[title]')]
      .map(li => ({ title: li.getAttribute('title'), classe: li.className })));
  }

  // Texto da janela da tarefa SEM o painel da controladoria (que fica dentro dela e confundiria o título).
  function textoSemPainel(container) {
    const ps = [...container.querySelectorAll('.oc-painel')], antes = ps.map(p => p.style.display);
    ps.forEach(p => { p.style.display = 'none'; });
    try { return container.innerText; } finally { ps.forEach((p, i) => { p.style.display = antes[i]; }); }
  }
  let aberto = null; // { container, id }
  async function aoAbrir(container) {
    const r = idDe(container);
    if (r.conflito) { painelDe(container).textContent = 'Controladoria: identificação da tarefa divergente (botão x endereço) — NÃO monitorada.'; return; }
    const id = r.id;
    if (!id || (aberto && aberto.container === container && aberto.id === id)) return;
    aberto = { container, id };
    const tela = P.lerTela(textoSemPainel(container), id);
    tela.responsaveis = responsaveisDe(container);
    const reed = lerReedicao();
    if (reed) {
      limparReedicao();   // só a PRIMEIRA janela aberta depois do envio da edição pode ser a tarefa recriada
      if (reed.antigo !== id && Date.now() - reed.quando < 120000) {
        const rr = await enviar({ tipo: 'reedicao', antigo: reed.antigo, novo: id, snap_novo: tela, snap_antigo: reed.tela || {} });
        if (!(rr && rr.ok && rr.dados && /ligada/.test(rr.dados.status || '')))
          avisar('Edição não ligada à tarefa original', 'O ADVBOX recriou a tarefa com outro número e a controladoria não conseguiu ligá-la à original'
                 + ((rr && rr.dados && rr.dados.motivo) ? ': ' + rr.dados.motivo : (rr && rr.erro ? ': ' + rr.erro : '.')) + ' Avise a controladoria.');
      }
    }
    estado.set(id, { tela, status: null, carregado: false });
    const painel = painelDe(container);
    painel.className = 'oc-painel'; painel.textContent = 'Controladoria: consultando…';
    const resp = await enviar({ tipo: 'status', advbox_id: id, snapshot: tela });
    const st = estado.get(id);
    st.carregado = true;
    if (resp && resp.ok) { st.status = resp.dados; inicios.set(id, { inicio_tratativa_em: resp.dados.inicio_tratativa_em, quando: Date.now() }); }
    if (aberto && aberto.id === id) desenhar(container, id);
  }

  // O painel fica DENTRO da caixa da tarefa, logo abaixo da barra "Concluir / Editar".
  // No ADVBOX real o container é a camada escura do modal (07/11/2026): um clique nela fecha
  // a janela; por isso os cliques no painel não sobem para o container.
  function painelDe(container) {
    let p = container.querySelector('.oc-painel');
    if (!p) {
      p = document.createElement('div'); p.className = 'oc-painel';
      ['click', 'mousedown', 'mouseup', 'pointerdown', 'pointerup'].forEach(ev => p.addEventListener(ev, e => e.stopPropagation()));
      const toggle = container.querySelector('a.toggle[data-id]');
      const barra = toggle && (toggle.closest('.header') || toggle.parentElement);
      if (barra && barra !== container && container.contains(barra)) barra.after(p); else container.prepend(p);
    }
    return p;
  }

  function desenhar(container, id) {
    const st = estado.get(id); const p = painelDe(container);
    p.className = 'oc-painel'; p.textContent = '';
    if (!st.status) {
      p.classList.add('oc-alerta');
      p.textContent = 'Controladoria: sem login ou sem conexão — esta tarefa NÃO está sendo monitorada.';
      return;
    }
    const s = st.status;
    if (s.inicio_tratativa_em) {
      p.classList.add('oc-ok');
      p.textContent = `Tratativa iniciada em ${new Date(s.inicio_tratativa_em).toLocaleString('pt-BR', { timeZone: 'America/Sao_Paulo' })}` +
        (s.inicio_por ? ` por ${s.inicio_por}` : '') + '.';
    } else {
      const t = document.createElement('span'); t.textContent = 'Tratativa ainda não iniciada.';
      const b = document.createElement('button'); b.type = 'button'; b.textContent = 'Iniciar tratativa';
      b.addEventListener('click', () => iniciar(container, id, b));
      p.append(t, b);
    }
    if (st.tela.pf_judicial_tela) {
      const j = document.createElement('span');
      j.textContent = `PF Judicial anotado: ${st.tela.pf_judicial_tela.texto}.`;
      p.append(j);
    }
    if (s.vinculo_excel && s.vinculo_excel !== 'excel_unico') {
      const v = document.createElement('span'); v.className = 'oc-sutil';
      v.textContent = s.vinculo_excel === 'ambiguo' ? 'Vínculo com a planilha: ambíguo (não associado).' : 'Ainda não localizada na planilha importada.';
      p.append(v);
    }
  }

  async function iniciar(container, id, botao) {
    botao.disabled = true; botao.textContent = 'Registrando…';
    const st = estado.get(id);
    const r = await enviar({ tipo: 'evento', evento: {
      p_id_cliente: uuid(), p_tipo: 'inicio_tratativa', p_advbox_id: id, p_snapshot: st.tela,
      p_estado_trava: null, p_justificativa: null, p_evidencia: { acao: 'botao_iniciar_tratativa' },
      p_horario_cliente: new Date().toISOString() } });
    if (r && r.ok && r.dados) {
      st.status.inicio_tratativa_em = r.dados.ocorrido_em;
      inicios.set(id, { inicio_tratativa_em: r.dados.ocorrido_em, quando: Date.now() });
      desenhar(container, id);
    } else {
      botao.disabled = false; botao.textContent = 'Iniciar tratativa';
      avisar('Não foi possível registrar o início', r && r.enfileirado
        ? 'Sem conexão: o registro ficou na fila e será reenviado. O início só vale após a confirmação.'
        : (r && r.erro) || 'Erro desconhecido.');
    }
  }

  function avisar(titulo, texto) {
    const d = document.createElement('div'); d.className = 'oc-aviso'; d.setAttribute('role', 'alert');
    const b = document.createElement('b'); b.textContent = titulo; d.append(b, document.createTextNode(texto));
    document.body.append(d); setTimeout(() => d.remove(), 9000);
  }

  function registrar(id, tipo, av, justificativa, snapshot) {
    const st = estado.get(id) || {};
    enviar({ tipo: 'evento', evento: {
      p_id_cliente: uuid(), p_tipo: tipo, p_advbox_id: id, p_snapshot: snapshot || st.tela || {},
      p_estado_trava: av.estado, p_justificativa: justificativa || null,
      p_evidencia: Object.assign({ motivo: av.motivo, modo: av.modo || null }, av.extra || {}),
      p_horario_cliente: new Date().toISOString() } });
  }
  const segurar = ev => { ev.preventDefault(); ev.stopImmediatePropagation(); };
  const CHAVE_REED = 'oc_reedicao';
  function guardarReedicao(antigo, tela) {
    try { sessionStorage.setItem(CHAVE_REED, JSON.stringify({ antigo: String(antigo), tela: tela || {}, quando: Date.now() })); } catch (e) { /* sem armazenamento: segue sem ligar */ }
  }
  function lerReedicao() { try { return JSON.parse(sessionStorage.getItem(CHAVE_REED) || 'null'); } catch (e) { return null; } }
  function limparReedicao() { try { sessionStorage.removeItem(CHAVE_REED); } catch (e) { /* nada */ } }

  // ---------------------------------------------------------------- lista: início já registrado?
  let pedidoPendente = null;
  // Intimações capturadas pelo ADVBOX aparecem na lista no grupo "publication": não são tarefas
  // e ficam fora da trava da tratativa (decisão a confirmar pelo escritório).
  const ehPublicacao = a => { const t = a.closest('table[data-group]'); return !!(t && t.getAttribute('data-group') === 'publication'); };
  function idsDaLista() {
    return [...new Set([...document.querySelectorAll('a.change-status[data-field="completed"][data-post]')]
      .filter(a => visivel(a) && !ehPublicacao(a)).map(a => a.getAttribute('data-post')).filter(v => /^\d{1,15}$/.test(v)))];
  }
  async function atualizarInicios(forcar) {
    const agora = Date.now();
    const faltam = idsDaLista().filter(id => forcar || !inicios.has(id) || agora - inicios.get(id).quando > 120000).slice(0, 200);
    if (!faltam.length || pedidoPendente) return;
    pedidoPendente = enviar({ tipo: 'inicios', ids: faltam });
    const r = await pedidoPendente; pedidoPendente = null;
    statusListaDisponivel = !!(r && r.ok);
    if (r && r.ok) {
      modosLista = r.dados.modos;
      for (const id of faltam) inicios.set(id, { inicio_tratativa_em: (r.dados.inicios || {})[id] || null, quando: Date.now() });
    }
  }

  // ---------------------------------------------------------------- Trava 1: Concluir (janela e lista)
  window.addEventListener('click', ev => {
    if (!(ev.target instanceof Element)) return;
    // (a) janela da tarefa
    const a = ev.target.closest('.task-container a.toggle[data-id]');
    if (a && /Concluir/i.test(a.textContent || '')) {
      const id = a.getAttribute('data-id');
      const st = estado.get(id);
      if (st && !st.carregado) { segurar(ev); avisar('Aguarde', 'A controladoria ainda está verificando esta tarefa. Tente novamente em instantes.'); return; }
      const av = P.avaliarConclusao(st && st.carregado ? st.status : null);
      if (av.decisao === 'bloquear') { segurar(ev); avisar('Conclusão bloqueada pela controladoria', av.motivo); }
      registrar(id, 'tentativa_conclusao', av, null);
      return;
    }
    // (b) lista: círculo "Resolvido" (data-value=1 conclui; 0 reabre)
    const l = ev.target.closest('a.change-status[data-field="completed"][data-post]');
    if (l && l.getAttribute('data-value') === '1' && !ehPublicacao(l)) {
      const id = l.getAttribute('data-post');
      const linha = l.closest('tr');
      const titulo = linha ? P.tituloDaLista((linha.querySelector('a.show-event') || {}).textContent) : null;
      const snap = { titulo, origem: 'lista' };
      const conhecido = inicios.get(id);
      if (statusListaDisponivel === false && !conhecido) { registrar(id, 'tentativa_conclusao', P.avaliarConclusao(null), null, snap); return; }
      if (!conhecido) { segurar(ev); atualizarInicios(true); avisar('Aguarde', 'A controladoria está verificando esta tarefa. Clique novamente em instantes.'); return; }
      const av = P.avaliarConclusao({ inicio_tratativa_em: conhecido.inicio_tratativa_em, modos: modosLista || {} });
      av.extra = Object.assign({ local: 'lista' }, av.extra || {});
      if (av.decisao === 'bloquear') { segurar(ev); avisar('Conclusão bloqueada pela controladoria', av.motivo); }
      registrar(id, 'tentativa_conclusao', av, null, snap);
    }
  }, true);

  // ---------------------------------------------------------------- Travas 2 e 3: Editar tarefa
  const guestsAoAbrir = new WeakMap();
  function prepararEdicao(form) {
    if (form.dataset.ocPreparado) return;
    form.dataset.ocPreparado = '1';
    guestsAoAbrir.set(form, [...form.querySelectorAll('[name="guests[]"]')].map(e => String(e.value)).filter(Boolean));
    inserirJustificativa(form, 'Justificativa (controladoria) — obrigatória ao alterar data, prazo fatal ou responsáveis');
  }
  function inserirJustificativa(form, rotulo) {
    if (form.querySelector('.oc-justificativa')) return;
    const box = document.createElement('label'); box.className = 'oc-justificativa';
    const t = document.createElement('span'); t.textContent = rotulo;
    const ta = document.createElement('textarea'); ta.rows = 2; ta.setAttribute('data-oc', 'justificativa');   // sem name: não vai para o ADVBOX
    box.append(t, ta);
    // sempre DENTRO do formulário, logo antes da área do botão de envio
    const ancora = form.querySelector('button[type=submit], button.btn-primary');
    if (!ancora) form.append(box);
    else if (ancora.parentElement === form) ancora.before(box);
    else ancora.parentElement.before(box);
  }
  const justificativaDe = form => { const t = form.querySelector('textarea[data-oc="justificativa"]'); return t ? t.value : ''; };

  const ultimoEnvio = new WeakMap();
  function aoEnviarEdicao(ev, form) {
    const agora = Date.now(); if (agora - (ultimoEnvio.get(form) || 0) < 1500) return; // clique e submit do mesmo envio
    const container = form.closest('.task-container'); const r = container ? idDe(container) : { id: null };
    const ed = P.lerEdicao(form, guestsAoAbrir.get(form));
    const id = r.id || (ed.editing && /^\d+$/.test(ed.editing) ? ed.editing : null);
    if (!id) return;
    const st = estado.get(id);
    const avs = P.avaliarEdicao(ed, st && st.tela, st && st.carregado ? st.status : null, justificativaDe(form));
    // No ADVBOX, salvar a edição EXCLUI a tarefa e cria outra (novo ID). Guarda o ID antigo para ligar os dois
    // quando a janela da tarefa recriada abrir (vale também para edições sem alteração monitorada).
    if (!avs.some(a => a.decisao === 'bloquear')) guardarReedicao(id, st && st.tela);
    if (!avs.length) { ultimoEnvio.set(form, agora); return; }
    const bloqueios = avs.filter(a => a.decisao === 'bloquear');
    if (bloqueios.length) { segurar(ev); avisar('Alteração bloqueada pela controladoria', bloqueios.map(b => b.motivo).join(' ')); }
    else ultimoEnvio.set(form, agora);
    avs.forEach(av => registrar(id, av.tipo, av, justificativaDe(form)));
  }
  const formEdicao = el => { const f = el && el.closest && el.closest('form.modal-inner-create'); return f && f.querySelector('[name="editing"]') && f.querySelector('[name="editing"]').value ? f : null; };
  window.addEventListener('submit', ev => { const f = ev.target instanceof HTMLFormElement ? formEdicao(ev.target) : null; if (f) aoEnviarEdicao(ev, f); }, true);
  window.addEventListener('click', ev => {
    if (!(ev.target instanceof Element)) return;
    const b = ev.target.closest('button'); const f = b && formEdicao(b);
    // Só o botão de envio do formulário. Botões do calendário também são <button> e, sem type,
    // o navegador os trata como "submit" (08/11/2026: um clique no dia gerava registro).
    if (f && (b.getAttribute('type') === 'submit' || /^\s*(Editar tarefa|Salvar)\s*$/i.test(b.textContent || ''))) aoEnviarEdicao(ev, f);
  }, true);

  // ---------------------------------------------------------------- Encaminhar (registra, não bloqueia)
  window.addEventListener('submit', ev => {
    const f = ev.target instanceof HTMLFormElement && ev.target.matches('form.form-event') ? ev.target : null;
    if (!f || !f.querySelector('[name="post_id"]')) return;
    const id = String(f.querySelector('[name="post_id"]').value || '');
    if (!/^\d{1,15}$/.test(id)) return;
    const sel = f.querySelector('select[name="user"]');
    const campos = { user: sel && sel.selectedOptions[0] ? sel.selectedOptions[0].textContent.trim() : null };
    const st = estado.get(id);
    const av = P.avaliarEncaminhamento(campos, st && st.carregado ? st.status : null, justificativaDe(f));
    registrar(id, av.tipo, av, justificativaDe(f));
  }, true);

  // ---------------------------------------------------------------- observa a página
  let agendado = false;
  function varrer() {
    const c = containerAberto();
    if (c) aoAbrir(c); else aberto = null;   // janela fechada: a próxima abertura reconsulta
    for (const f of document.querySelectorAll('form.modal-inner-create')) if (visivel(f) && formEdicao(f)) prepararEdicao(f);
    for (const f of document.querySelectorAll('form.form-event')) if (visivel(f) && f.querySelector('[name="post_id"]'))
      inserirJustificativa(f, 'Justificativa (controladoria) do encaminhamento');
    atualizarInicios(false);
  }
  new MutationObserver(() => {
    if (agendado) return; agendado = true;
    setTimeout(() => { agendado = false; varrer(); }, 300);
  }).observe(document.documentElement, { childList: true, subtree: true, attributes: true, attributeFilter: ['style', 'class'] });
  varrer();
})();
