/* Extensão no Atlas Gestor (mundo isolado) — 11/11/2026.
 * Recebe da ponte (atlas_ponte.js) as gravações de tarefa e as janelas abertas, consulta a
 * controladoria (Supabase, pelo background) e:
 *  - mostra na janela da tarefa o painel "Iniciar tratativa";
 *  - decide cada gravação: conclusão sem início (trava 1), realocação e prazo fatal (travas 2 e 3),
 *    pedindo a justificativa quando a regra permite; líderes passam, com registro;
 *  - registra tudo como evento (mesmas funções e estados do ADVBOX; o ID é o uuid do Atlas).
 * 0.7.0 (17/11/2026): conclusão (e baixa) pede justificativa; mudar a tarefa para "em andamento" registra o início. */
(function () {
  'use strict';
  const A = globalThis.OCAtlas;
  const enviarBg = msg => new Promise(res => {
    try { chrome.runtime.sendMessage(msg, r => res(chrome.runtime.lastError ? { ok: false, erro: chrome.runtime.lastError.message } : r)); }
    catch (e) { res({ ok: false, erro: e.message }); }
  });
  const paraPagina = m => window.postMessage(Object.assign({ __oc: 'atlas-ext' }, m), window.location.origin);
  const statusCache = new Map();   // atlas_id -> { dados, quando }
  const aguardando = new Map();    // id da decisão -> [{ atlas_id, av, justificativa }]
  let aberta = null;               // { tarefa, usuario }

  async function status(atlasId, snap, forcar) {
    const c = statusCache.get(atlasId);
    if (!forcar && c && Date.now() - c.quando < 60000) return c.dados;
    const r = await enviarBg({ tipo: 'status', advbox_id: atlasId, snapshot: Object.assign({ origem: 'atlas' }, snap || {}) });
    const dados = r && r.ok ? r.dados : null;
    if (dados) statusCache.set(atlasId, { dados, quando: Date.now() });
    return dados;
  }
  function registrar(atlasId, av, justificativa, snap) {
    return enviarBg({ tipo: 'evento', evento: {
      p_id_cliente: crypto.randomUUID(), p_tipo: av.tipo, p_advbox_id: atlasId, p_snapshot: Object.assign({ origem: 'atlas' }, snap || {}),
      p_estado_trava: av.estado, p_justificativa: justificativa || null,
      p_evidencia: Object.assign({ motivo: av.motivo, modo: av.modo || null, sistema: 'atlas' }, av.extra || {}),
      p_horario_cliente: new Date().toISOString() } });
  }

  function registrarInicio(atlasId, snap, evidencia) {
    return enviarBg({ tipo: 'evento', evento: { p_id_cliente: crypto.randomUUID(), p_tipo: 'inicio_tratativa', p_advbox_id: atlasId,
      p_snapshot: Object.assign({ origem: 'atlas' }, snap || {}), p_estado_trava: null, p_justificativa: null,
      p_evidencia: evidencia, p_horario_cliente: new Date().toISOString() } });
  }

  // ------------------------------------------------------------ diálogos
  function avisar(titulo, texto) {
    const d = document.createElement('div'); d.className = 'oc-aviso'; d.setAttribute('role', 'alert');
    const b = document.createElement('b'); b.textContent = titulo; d.append(b, document.createTextNode(' ' + texto));
    document.body.append(d); setTimeout(() => d.remove(), 9000);
  }
  // Pede a justificativa; resolve com o texto ou null (cancelado). Tudo com textContent (sem HTML do usuário).
  function pedirJustificativa(motivos, minimo, textos) {
    textos = textos || {};
    return new Promise(res => {
      const dlg = document.createElement('dialog'); dlg.className = 'oc-dialogo';
      const h = document.createElement('h2'); h.textContent = textos.titulo || 'Controladoria: justificativa obrigatória';
      const ul = document.createElement('ul'); motivos.forEach(m => { const li = document.createElement('li'); li.textContent = m; ul.append(li); });
      const lab = document.createElement('label'); lab.textContent = `Justificativa (mínimo ${minimo} caracteres)`;
      const ta = document.createElement('textarea'); ta.rows = 3; lab.append(ta);
      const err = document.createElement('p'); err.className = 'oc-erro';
      const ok = document.createElement('button'); ok.type = 'button'; ok.className = 'oc-btn'; ok.textContent = textos.ok || 'Salvar com justificativa';
      const cancelar = document.createElement('button'); cancelar.type = 'button'; cancelar.className = 'oc-btn oc-btn-sec'; cancelar.textContent = textos.cancelar || 'Cancelar alteração';
      const acoes = document.createElement('div'); acoes.className = 'oc-acoes'; acoes.append(cancelar, ok);
      dlg.append(h, ul, lab, err, acoes); document.body.append(dlg);
      const fim = v => { dlg.close(); dlg.remove(); res(v); };
      ok.onclick = () => { const t = ta.value.replace(/\s+/g, ' ').trim(); if (t.length < minimo) { err.textContent = `Escreva ao menos ${minimo} caracteres.`; return; } fim(t); };
      cancelar.onclick = () => fim(null);
      dlg.addEventListener('cancel', e => { e.preventDefault(); fim(null); });
      dlg.showModal(); ta.focus();
    });
  }
  function informarBloqueio(motivos) {
    return new Promise(res => {
      const dlg = document.createElement('dialog'); dlg.className = 'oc-dialogo';
      const h = document.createElement('h2'); h.textContent = 'Alteração bloqueada pela controladoria';
      const ul = document.createElement('ul'); motivos.forEach(m => { const li = document.createElement('li'); li.textContent = m; ul.append(li); });
      const ok = document.createElement('button'); ok.type = 'button'; ok.className = 'oc-btn'; ok.textContent = 'Entendi';
      const acoes = document.createElement('div'); acoes.className = 'oc-acoes'; acoes.append(ok);
      dlg.append(h, ul, acoes); document.body.append(dlg);
      const fim = () => { dlg.close(); dlg.remove(); res(); };
      ok.onclick = fim; dlg.addEventListener('cancel', e => { e.preventDefault(); fim(); });
      dlg.showModal();
    });
  }

  // ------------------------------------------------------------ decisão de cada gravação
  async function decidir(pedido) {
    const resultado = [];
    for (const op of pedido.ops) {
      const snap = aberta && aberta.tarefa && aberta.tarefa.id === op.atlas_id ? { titulo: aberta.tarefa.titulo } : {};
      let st = await status(op.atlas_id, snap, !!op.conclusao);
      if (st && op.conclusao) {   // 0039: checklist e anexos da modalidade
        const ex = await enviarBg({ tipo: 'execucao', advbox_id: op.atlas_id });
        if (ex && ex.ok && ex.dados && ex.dados.encontrada && !ex.dados.sem_acesso) st = Object.assign({}, st, { execucao: ex.dados });
      }
      resultado.push({ op, st, snap, avs: A.avaliarOperacao(op, st, '') });
    }
    let justificativa = null;
    const bloq = resultado.flatMap(r => r.avs.filter(a => a.decisao === 'bloquear'));
    if (bloq.length && bloq.every(a => a.precisa_justificativa)) {
      const minimo = (resultado.find(r => r.st) || {}).st?.justificativa_minima || 15;
      // 0.7.0: só a conclusão pede justificativa -> textos próprios
      const soConclusao = bloq.every(a => a.extra && a.extra.justificativa_conclusao);
      justificativa = await pedirJustificativa([...new Set(bloq.map(a => a.motivo))], minimo, soConclusao
        ? { titulo: 'Controladoria: justificativa da conclusão', ok: 'Concluir com justificativa', cancelar: 'Cancelar conclusão' } : null);
      if (justificativa) for (const r of resultado) r.avs = A.avaliarOperacao(r.op, r.st, justificativa);
    }
    const aindaBloq = resultado.flatMap(r => r.avs.filter(a => a.decisao === 'bloquear'));
    if (aindaBloq.length) {
      for (const r of resultado) for (const av of r.avs) if (av.decisao === 'bloquear') registrar(r.op.atlas_id, av, justificativa, r.snap);
      if (!(bloq.every(a => a.precisa_justificativa) && justificativa === null)) await informarBloqueio([...new Set(aindaBloq.map(a => a.motivo))]);
      paraPagina({ canal: 'decisao', id: pedido.id, permitir: false,
        mensagem: 'Controladoria: ' + (justificativa === null && bloq.every(a => a.precisa_justificativa) ? 'alteração cancelada (sem justificativa).' : aindaBloq[0].motivo) });
      return;
    }
    // 0.7.0: "em andamento" no Atlas = início da tratativa (registrado depois que o Atlas confirmar a gravação)
    const inicios = resultado.filter(r => r.op.em_andamento && r.st && !r.st.inicio_tratativa_em)
      .map(r => ({ atlas_id: r.op.atlas_id, inicio: true, snap: r.snap }));
    aguardando.set(pedido.id, resultado.flatMap(r => r.avs.map(av => ({ atlas_id: r.op.atlas_id, av, justificativa, snap: r.snap }))).concat(inicios));
    paraPagina({ canal: 'decisao', id: pedido.id, permitir: true });
  }
  // o evento só vale depois que o Atlas confirmou a gravação
  function aoResultado(m) {
    const lista = aguardando.get(m.id); if (!lista) return; aguardando.delete(m.id);
    if (!m.ok) return;
    for (const x of lista) {
      if (x.inicio) registrarInicio(x.atlas_id, x.snap, { acao: 'status_em_andamento_atlas', sistema: 'atlas' });
      else registrar(x.atlas_id, x.av, x.justificativa, x.snap);
      statusCache.delete(x.atlas_id);
    }
    if (lista.some(x => x.inicio)) avisar('Controladoria:', 'tarefa em andamento: início da tratativa registrado.');
    const viol = lista.filter(x => x.av && x.av.estado === 'violacao_detectada');
    if (viol.length) avisar('Controladoria:', viol[0].av.motivo);
  }

  // ------------------------------------------------------------ painel na janela da tarefa
  function janelaDom() {
    return [...document.querySelectorAll('[role="dialog"]')].find(d => [...d.querySelectorAll('button')].some(b => b.textContent.trim() === 'Concluir'));
  }
  function painel() {
    const d = janelaDom(); if (!d) return null;
    let p = d.querySelector('.oc-painel');
    if (!p) {
      p = document.createElement('div'); p.className = 'oc-painel'; p.setAttribute('role', 'status');
      const alvo = [...d.querySelectorAll('button')].find(b => b.textContent.trim() === 'Concluir');
      const barra = alvo && alvo.parentElement;
      (barra && barra.parentElement ? barra.parentElement : d).insertBefore(p, barra && barra.parentElement ? barra : null);
      p.addEventListener('click', e => e.stopPropagation());
    }
    return p;
  }
  async function aoAbrir(m) {
    aberta = { tarefa: m.tarefa, usuario: m.usuario };
    const p = painel(); if (!p) return;
    p.textContent = 'Controladoria: consultando…';
    const snap = { titulo: m.tarefa.titulo, vencimento: m.tarefa.vencimento, prazo_fatal: m.tarefa.prazo_fatal, status_atlas: m.tarefa.status,
                   usuario_atlas: m.usuario ? m.usuario.nome : null };
    const st = await status(m.tarefa.id, snap, true);
    if (!aberta || aberta.tarefa.id !== m.tarefa.id) return;
    desenhar(p, m.tarefa, st, snap);
  }
  function desenhar(p, t, st, snap) {
    desenharTratativa(p, t, st, snap);
    if (st) blocoD4(p, t).then(() => blocoExecucao(p, t)).catch(() => {});
  }
  // 0039: execução da modalidade — orientações, links, checklist e anexos (peça e parecer de autoavaliação)
  const TIPOS_ANEXO = { peca: 'Peça', parecer_autoavaliacao: 'Parecer de autoavaliação', outro: 'Outro' };
  const el = (tag, props, ...filhos) => { const e = Object.assign(document.createElement(tag), props || {}); filhos.flat().forEach(f => f !== null && f !== undefined && e.append(f)); return e; };
  function linkExterno(url, texto) { if (!/^https:\/\//.test(url || '')) return null; return el('a', { href: url, target: '_blank', rel: 'noopener noreferrer', textContent: texto }); }
  async function blocoExecucao(p, t, aberto) {
    const r = await enviarBg({ tipo: 'execucao', advbox_id: t.id });
    if (!r || !r.ok || !r.dados || !r.dados.encontrada || r.dados.sem_acesso || !p.isConnected) return;
    if (!aberta || aberta.tarefa.id !== t.id) return;
    const x = r.dados; const m = x.modalidade;
    let b = p.querySelector('.oc-exec'); if (b) b.remove();
    if (!m) return;
    const pend = x.pendencias || [];
    b = el('details', { className: 'oc-exec' + (x.exigido && pend.length ? ' oc-exec-pendente' : ''), open: !!aberto });
    b.append(el('summary', { textContent: `Execução — ${m.nome}${m.ativa ? '' : ' (modelo inativo)'}: ` +
      (!x.exigido ? 'sem exigência' : pend.length ? `${pend.length} pendência(s) para concluir` : 'pronta para concluir') }));
    if (m.orientacoes) b.append(el('p', { textContent: 'Orientações: ' + m.orientacoes }));
    const links = [linkExterno(m.link_treinamento, 'Material de treinamento'), linkExterno(m.link_notebooklm, 'Conferência técnica no NotebookLM')].filter(Boolean);
    if (links.length) b.append(el('p', {}, links.flatMap((l, i) => i ? [' · ', l] : [l])));
    const ul = el('ul', { className: 'oc-checklist' });
    for (const it of x.checklist || []) {
      const cb = el('input', { type: 'checkbox', checked: !!it.marcado, disabled: !x.pode_editar });
      cb.onchange = async () => {
        cb.disabled = true;
        const s = await enviarBg({ tipo: 'execucao_marcar', advbox_id: t.id, item: it.id, marcado: cb.checked });
        if (!s || !s.ok) { avisar('Não foi possível marcar o item.', (s && s.erro) || 'Erro desconhecido.'); cb.checked = !cb.checked; cb.disabled = false; return; }
        blocoExecucao(p, t, true).catch(() => {});
      };
      ul.append(el('li', {}, el('label', {}, cb, ' ' + it.texto)));
    }
    b.append(ul);
    const anexos = x.anexos || [];
    b.append(el('p', { textContent: 'Anexos: ' + (anexos.length ? anexos.map(a => `${TIPOS_ANEXO[a.tipo] || a.tipo}: ${a.nome}`).join('; ') : 'nenhum') }));
    if (x.pode_editar) {
      const tipo = el('select', {}, Object.entries(TIPOS_ANEXO).map(([k, v]) => el('option', { value: k, textContent: v })));
      const arq = el('input', { type: 'file', accept: '.pdf,.doc,.docx,.odt,.txt,.rtf' });
      const bt = el('button', { type: 'button', className: 'oc-btn', textContent: 'Anexar' });
      bt.onclick = async () => {
        const f = arq.files && arq.files[0];
        if (!f) { avisar('Controladoria:', 'Escolha o arquivo.'); return; }
        if (f.size > (x.anexo_tamanho_maximo_mb || 20) * 1048576) { avisar('Controladoria:', `Arquivo maior que ${x.anexo_tamanho_maximo_mb || 20} MB.`); return; }
        bt.disabled = true; bt.textContent = 'Enviando…';
        const u8 = new Uint8Array(await f.arrayBuffer()); let bin = '';
        for (let i = 0; i < u8.length; i += 0x8000) bin += String.fromCharCode.apply(null, u8.subarray(i, i + 0x8000));
        const s = await enviarBg({ tipo: 'anexo', advbox_id: t.id, tarefa_id: x.tarefa_id, tipo_anexo: tipo.value, nome: f.name, mime: f.type, tamanho: f.size, base64: btoa(bin) });
        if (!s || !s.ok) { avisar('Não foi possível anexar.', (s && s.erro) || 'Erro desconhecido.'); bt.disabled = false; bt.textContent = 'Anexar'; return; }
        blocoExecucao(p, t, true).catch(() => {});
      };
      b.append(el('div', { className: 'oc-acoes-linha' }, tipo, arq, bt));
    }
    if (x.exigido && pend.length) b.append(el('p', { className: 'oc-erro', textContent: 'Para concluir: ' + pend.join('; ') }));
    p.append(b);
  }
  // 0037: D-4 (data de entrega do advogado) e exceção "entrega após o D-4", marcada por líder ou controladoria
  const dataBr = d => d ? String(d).slice(0, 10).split('-').reverse().join('/') : null;
  async function blocoD4(p, t) {
    const r = await enviarBg({ tipo: 'excecao_d4', advbox_id: t.id });
    if (!r || !r.ok || !r.dados || !r.dados.encontrada || !p.isConnected) return;
    if (!aberta || aberta.tarefa.id !== t.id) return;
    const x = r.dados;
    if (!x.ativa && !x.d4) return;                  // sem PF Judicial e sem exceção: nada a mostrar
    let b = p.querySelector('.oc-d4'); if (b) b.remove();
    b = document.createElement('div'); b.className = 'oc-d4'; p.append(b);
    if (x.ativa) {
      const tag = document.createElement('span'); tag.className = 'oc-tag'; tag.textContent = 'entrega após o D-4 autorizada';
      b.append(tag, document.createTextNode(` ${x.d4 ? 'D-4: ' + dataBr(x.d4) + '. ' : ''}Por ${x.por || '—'}${x.em ? ' em ' + new Date(x.em).toLocaleString('pt-BR') : ''}: ${x.justificativa || ''}`));
    } else {
      b.append(document.createTextNode(`D-4 (entrega): ${dataBr(x.d4)}${x.pf_judicial ? ' · PF Judicial: ' + dataBr(x.pf_judicial) : ''}. `));
    }
    if (!x.pode_definir || (!x.ativa && t.status === 'done')) return;
    const btn = document.createElement('button'); btn.type = 'button'; btn.className = 'oc-btn oc-btn-sec';
    btn.textContent = x.ativa ? 'Retirar exceção' : 'Autorizar entrega após o D-4';
    btn.onclick = async () => {
      const just = await pedirJustificativa([x.ativa
          ? 'A tarefa volta a seguir o D-4 normalmente.'
          : 'Exceção: a tarefa poderá ser entregue depois do D-4 e sai dos alertas de D-4. O PF Judicial continua valendo.'],
        x.justificativa_minima || 15,
        { titulo: x.ativa ? 'Controladoria: retirar a exceção de D-4' : 'Controladoria: autorizar entrega após o D-4',
          ok: x.ativa ? 'Retirar exceção' : 'Autorizar', cancelar: 'Cancelar' });
      if (just === null) return;
      btn.disabled = true; btn.textContent = 'Registrando…';
      const s = await enviarBg({ tipo: 'excecao_d4', advbox_id: t.id, ativa: !x.ativa, justificativa: just });
      if (!s || !s.ok) { avisar('Não foi possível registrar a exceção.', (s && s.erro) || 'Erro desconhecido.'); }
      blocoD4(p, t).catch(() => {});
    };
    b.append(btn);
  }
  function desenharTratativa(p, t, st, snap) {
    p.textContent = '';
    const tit = document.createElement('b'); tit.textContent = 'Controladoria: '; p.append(tit);
    if (!st) { p.append(document.createTextNode('sem conexão ou sem login na extensão — esta tarefa não está sendo monitorada.')); return; }
    if (st.papel === 'lider') { const s = document.createElement('span'); s.className = 'oc-tag'; s.textContent = 'líder: alterações liberadas (registradas)'; p.append(s, document.createTextNode(' ')); }
    if (st.inicio_tratativa_em) {
      p.append(document.createTextNode(`tratativa iniciada em ${new Date(st.inicio_tratativa_em).toLocaleString('pt-BR')}${st.inicio_por ? ' por ' + st.inicio_por : ''}.`));
      return;
    }
    if (t.status === 'done') { p.append(document.createTextNode('tarefa concluída sem início da tratativa registrado.')); return; }
    p.append(document.createTextNode('tratativa não iniciada. '));
    const b = document.createElement('button'); b.type = 'button'; b.className = 'oc-btn'; b.textContent = 'Iniciar tratativa';
    b.onclick = async () => {
      b.disabled = true; b.textContent = 'Registrando…';
      const r = await registrarInicio(t.id, snap, { acao: 'botao_iniciar_tratativa', sistema: 'atlas' });
      if (r && r.ok) { statusCache.delete(t.id); const novo = await status(t.id, snap, true); desenhar(p, t, novo, snap); }
      else { b.disabled = false; b.textContent = 'Iniciar tratativa';
        avisar('Não foi possível registrar o início.', r && r.enfileirado ? 'Sem conexão: ficou na fila e será reenviado; o início só vale após a confirmação.' : (r && r.erro) || 'Erro desconhecido.'); }
    };
    p.append(b);
  }

  window.addEventListener('message', ev => {
    if (ev.source !== window || !ev.data || ev.data.__oc !== 'atlas-pagina') return;
    const m = ev.data;
    if (m.canal === 'ola') paraPagina({ canal: 'pronto' });
    if (m.canal === 'decidir' && Array.isArray(m.ops)) decidir(m).catch(e => paraPagina({ canal: 'decisao', id: m.id, permitir: true, erro: String(e) }));
    if (m.canal === 'resultado') aoResultado(m);
    if (m.canal === 'tarefa_aberta' && m.tarefa && A.UUID.test(m.tarefa.id || '')) aoAbrir(m);
    if (m.canal === 'tarefa_fechada') aberta = null;
  });
  paraPagina({ canal: 'pronto' });
})();
