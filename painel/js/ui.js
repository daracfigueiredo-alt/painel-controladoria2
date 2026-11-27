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
  // Comunicações do CNJ (DJEN) chegam, muitas vezes, como página HTML inteira (eproc, PJe). Converte em texto legível:
  // um parágrafo por linha, cabeçalho em "RELATOR: …", sem estilos. O HTML é só LIDO (DOMParser não executa scripts
  // nem carrega imagens) e nada dele entra na página como HTML: o resultado é texto puro.
  const BLOCOS = 'p,div,center,tr,li,h1,h2,h3,h4,h5,h6,table,ul,ol,blockquote,section,article,header,footer';
  function textoLegivel(bruto) {
    if (!bruto) return '';
    const s = String(bruto);
    if (!/<[a-z!\/][^>]*>|&[a-z#0-9]+;/i.test(s)) return s.trim();
    let doc;
    try { doc = new DOMParser().parseFromString(s, 'text/html'); } catch (e) { return s; }
    const raiz = doc.body || doc.documentElement;
    raiz.querySelectorAll('script,style,head,title,meta,link,noscript').forEach(n => n.remove());
    raiz.querySelectorAll('br').forEach(n => n.replaceWith('\n'));
    raiz.querySelectorAll('td,th').forEach(n => n.append(' '));
    raiz.querySelectorAll(BLOCOS).forEach(n => { n.prepend('\n'); n.append('\n'); });
    return (raiz.textContent || '').replace(/\u00a0/g, ' ').split('\n')
      .map(l => l.replace(/[ \t]+/g, ' ').replace(/ :/g, ':').trim()).filter(Boolean).join('\n');
  }
  window.UI = { h, dataHora, data, num, tabela, aviso, textoLegivel };
})();
