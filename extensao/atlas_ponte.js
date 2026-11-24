/* Ponte no Atlas Gestor (mundo da PÁGINA, carregada antes do app) — 11/11/2026.
 * O Atlas grava as tarefas pela API REST do Supabase dele, com fetch. Esta ponte:
 *  - guarda os valores das tarefas que a própria página leu (para saber o que mudou);
 *  - segura a gravação de tarefa (status concluído, vencimento, prazo fatal, executante,
 *    responsáveis) até a extensão decidir; bloqueada = a requisição nem sai do navegador e o
 *    Atlas recebe um erro com o motivo;
 *  - avisa a extensão quando a janela de uma tarefa abre (ID e dados da tarefa, ID e nome do
 *    usuário), para o painel "Iniciar tratativa".
 * Não lê nem repassa nada do escritório além da tarefa e do usuário (nada de chaves ou tokens).
 * Sem a extensão respondendo, tudo passa como antes (não monitorado). */
(function () {
  'use strict';
  if (window.__ocAtlasPonte) return; window.__ocAtlasPonte = true;
  const A = window.OCAtlas;
  if (!A) return;
  const conhecidas = new Map();
  const original = window.fetch;
  let extensaoPronta = false;
  const pendentes = new Map();
  const TAREFAS = /\.supabase\.co\/rest\/v1\/(tasks|task_assignees|rpc\/complete_task_assignee_tx)(\?|$)/;

  window.addEventListener('message', ev => {
    if (ev.source !== window || !ev.data || ev.data.__oc !== 'atlas-ext') return;
    if (ev.data.canal === 'pronto') { extensaoPronta = true; enviar({ canal: 'pronto_ok' }); verificarJanela(true); }
    if (ev.data.canal === 'decisao' && pendentes.has(ev.data.id)) { pendentes.get(ev.data.id)(ev.data); pendentes.delete(ev.data.id); }
  });
  const enviar = m => window.postMessage(Object.assign({ __oc: 'atlas-pagina' }, m), window.location.origin);
  enviar({ canal: 'ola' });

  function lembrar(t) {
    const n = A.normalizarTarefa(t); if (!n) return;
    const ant = conhecidas.get(n.id) || {};
    const novo = Object.assign({}, ant);
    for (const [k, v] of Object.entries(n)) if (v !== undefined) novo[k] = v;
    conhecidas.set(n.id, novo);
  }
  function lembrarResposta(url, dados) {
    const linhas = Array.isArray(dados) ? dados : (dados && typeof dados === 'object' ? [dados] : []);
    if (/\/rest\/v1\/tasks/.test(url)) linhas.forEach(lembrar);
    if (/\/rest\/v1\/task_assignees/.test(url)) {
      const por = new Map();
      for (const l of linhas) if (l && l.task_id && l.user_id) { const k = String(l.task_id).toLowerCase(); if (!por.has(k)) por.set(k, []); por.get(k).push(l.user_id); }
      for (const [k, us] of por) { const t = conhecidas.get(k); if (t) t.assignees = [...new Set([...(t.assignees || []), ...us])]; }
    }
  }

  function decidir(ops) {
    if (!extensaoPronta) return Promise.resolve({ permitir: true });
    return new Promise(res => {
      const id = Math.random().toString(36).slice(2) + Date.now().toString(36);
      pendentes.set(id, res);
      enviar({ canal: 'decidir', id, ops });
      // a justificativa pode demorar; sem resposta em 10 minutos, não grava (a pessoa tenta de novo)
      setTimeout(() => { if (pendentes.has(id)) { pendentes.delete(id); res({ permitir: false, mensagem: 'Controladoria: tempo esgotado. Tente salvar de novo.' }); } }, 600000);
    });
  }

  window.fetch = async function (entrada, opcoes) {
    const url = typeof entrada === 'string' ? entrada : (entrada && entrada.url) || String(entrada);
    if (!TAREFAS.test(url)) return original.apply(this, arguments);
    const metodo = String((opcoes && opcoes.method) || (entrada && entrada.method) || 'GET').toUpperCase();
    if (metodo === 'GET' || metodo === 'HEAD') {
      const r = await original.apply(this, arguments);
      try { r.clone().json().then(d => lembrarResposta(url, d)).catch(() => {}); } catch (e) { /* sem corpo */ }
      return r;
    }
    let corpo = opcoes && opcoes.body;
    if (corpo === undefined && entrada && typeof entrada.clone === 'function') { try { corpo = await entrada.clone().text(); } catch (e) { corpo = null; } }
    let ops = [];
    try { ops = A.interpretarGravacao(metodo, url, typeof corpo === 'string' ? corpo : null, conhecidas); } catch (e) { ops = []; }
    if (!ops.length) return original.apply(this, arguments);
    const d = await decidir(ops);
    if (!d.permitir) {
      return new Response(JSON.stringify({ message: d.mensagem || 'Alteração bloqueada pela controladoria.', code: 'OC_CONTROLADORIA', details: null, hint: null }),
        { status: 403, headers: { 'Content-Type': 'application/json' } });
    }
    const r = await original.apply(this, arguments);
    enviar({ canal: 'resultado', id: d.id, ok: r.ok, status: r.status });
    if (r.ok) {
      for (const op of ops) {
        const t = conhecidas.get(op.atlas_id); if (!t) continue;
        if (op.conclusao && !op.baixa_parcial) t.status = 'done';
        if (op.em_andamento) t.status = 'doing';
        if (op.due) t.due_date = op.due.para;
        if (op.fatal) t.fatal_date = op.fatal.para;
        if (op.executante) t.user_id = op.executante.para;
        if (op.responsaveis && op.responsaveis.adicionados) t.assignees = [...new Set([...(t.assignees || []), ...op.responsaveis.adicionados])];
      }
    }
    return r;
  };

  // ------------------------------------------------------------ janela da tarefa
  // A janela do Atlas é um [role=dialog] com o botão "Concluir"; os dados da tarefa estão nas
  // propriedades do componente React (task, currentUser). Só id/título/datas/responsáveis saem daqui.
  function propsDaJanela(el) {
    const k = Object.keys(el).find(x => x.startsWith('__reactFiber'));
    let f = k ? el[k] : null, n = 0, tarefa = null, usuario = null;
    while (f && n < 60 && !(tarefa && usuario)) {
      const p = f.memoizedProps || {};
      if (!tarefa && p.task && typeof p.task === 'object' && A.UUID.test(String(p.task.id || ''))) tarefa = p.task;
      if (!usuario && p.currentUser && typeof p.currentUser === 'object' && p.currentUser.id) usuario = p.currentUser;
      f = f.return; n++;
    }
    return { tarefa, usuario };
  }
  let abertaId = null;
  function verificarJanela(forcar) {
    const dlg = [...document.querySelectorAll('[role="dialog"]')].find(d => [...d.querySelectorAll('button')].some(b => b.textContent.trim() === 'Concluir'));
    if (!dlg) { if (abertaId) { abertaId = null; enviar({ canal: 'tarefa_fechada' }); } return; }
    const { tarefa, usuario } = propsDaJanela(dlg);
    if (!tarefa) return;
    lembrar(tarefa);
    const id = String(tarefa.id).toLowerCase();
    if (id === abertaId && !forcar) return;
    abertaId = id;
    const n = conhecidas.get(id);
    enviar({ canal: 'tarefa_aberta', tarefa: { id, titulo: tarefa.title || null, status: n.status, vencimento: n.due_date, prazo_fatal: n.fatal_date,
      responsaveis: (tarefa.assignees || []).map(a => ({ id: a.userId || a.user_id || null, nome: a.name || a.userName || null, principal: !!(a.isPrincipal || a.is_principal) })) },
      usuario: usuario ? { id: usuario.id, nome: usuario.name || null } : null });
  }
  const iniciar = () => {
    new MutationObserver(() => { clearTimeout(iniciar.t); iniciar.t = setTimeout(() => verificarJanela(false), 150); })
      .observe(document.documentElement, { childList: true, subtree: true });
  };
  if (document.documentElement) iniciar(); else document.addEventListener('DOMContentLoaded', iniciar);
})();
