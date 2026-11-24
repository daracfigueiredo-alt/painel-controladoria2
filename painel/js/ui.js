/* Utilitários de interface. Todo texto vindo de dados entra por textContent (sem innerHTML). */
(function () {
  'use strict';
  function h(tag, attrs, ...filhos) {
    const el = document.createElement(tag);
    for (const [k, v] of Object.entries(attrs || {})) {
      if (v === null || v === undefined || v === false) continue;
      if (k === 'class') el.className = v;
      else if (k.startsWith('on')) el.addEventListener(k.slice(2), v);
      else if (k === 'dataset') Object.assign(el.dataset, v);
      else el.setAttribute(k, v === true ? '' : v);
    }
    for (const f of filhos.flat()) if (f !== null && f !== undefined && f !== false) el.append(f instanceof Node ? f : String(f));
    return el;
  }
  const tz = 'America/Sao_Paulo';
  const dataHora = v => v ? new Date(v).toLocaleString('pt-BR', { timeZone: tz, dateStyle: 'short', timeStyle: 'short' }) : '—';
  const data = v => { if (!v) return '—'; const [a, m, d] = String(v).slice(0, 10).split('-'); return `${d}/${m}/${a}`; };
  const num = v => (v === null || v === undefined) ? '—' : Number(v).toLocaleString('pt-BR');
  function tabela(colunas, linhas, opts = {}) {
    const t = h('table', { class: 'tab' + (opts.compacta ? ' tab-compacta' : '') },
      h('thead', {}, h('tr', {}, colunas.map(c => h('th', { scope: 'col', class: c.num ? 'num' : c.larga ? 'larga' : null }, c.titulo)))),
      h('tbody', {}, linhas.length ? linhas.map(l => h('tr', { class: opts.classeLinha ? opts.classeLinha(l) : null },
        colunas.map(c => h('td', { class: c.num ? 'num' : c.larga ? 'larga' : null, 'data-rotulo': c.titulo }, c.valor(l))))) :
        h('tr', {}, h('td', { colspan: colunas.length, class: 'vazio' }, opts.vazio || 'Nenhum registro.'))));
    return h('div', { class: 'tab-rolagem' }, t);
  }
  function aviso(tipo, ...conteudo) { return h('div', { class: 'aviso aviso-' + tipo, role: tipo === 'erro' ? 'alert' : 'status' }, ...conteudo); }
  window.UI = { h, dataHora, data, num, tabela, aviso };
})();
