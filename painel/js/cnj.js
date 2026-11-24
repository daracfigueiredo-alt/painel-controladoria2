/* Intimações CNJ (12/11/2026): comunicações capturadas na API pública do CNJ (DJEN), por OAB e por processo
 * da carteira (processos do Atlas + processos já conhecidos). Substitui o módulo de intimações do Atlas, que o
 * escritório decidiu não contratar. Cada comunicação mostra se a Webjur também capturou (identificador exato,
 * ou processo e data). Toda permissão é decidida no banco. */
(function () {
  'use strict';
  const { h, num, data, dataHora, aviso, tabela } = UI;
  const ehAdmin = ctx => ctx.perfil.papel === 'admin';
  const msgErro = e => (e && (e.message || e.erro)) || String(e);
  const hojeISO = () => new Date().toLocaleDateString('sv-SE', { timeZone: 'America/Sao_Paulo' });
  const menosDias = (iso, n) => { const d = new Date(iso + 'T12:00:00'); d.setDate(d.getDate() - n); return d.toISOString().slice(0, 10); };
  const TIPO_EXEC = { oab: 'Consulta por OAB (automática)', lote: 'Varredura por processo', carteira: 'Atualização da carteira', manual: 'Consulta pelo painel' };

  async function chamar(ctx, corpo) {
    const { data: d, error } = await ctx.sb.functions.invoke('cnj-captura', { body: corpo });
    if (error) {
      let msg = error.message;
      try { const j = await error.context.json(); msg = j.erro || msg; } catch (e) { /* sem corpo */ }
      throw new Error(msg);
    }
    return d;
  }

  async function abrir(raiz, ctx) {
    const f = { inicio: menosDias(hojeISO(), 7), fim: hojeISO(), busca: '', filtro: '' };
    raiz.append(h('h1', {}, 'Intimações CNJ'),
      h('p', { class: 'subtitulo' }, 'Diário de Justiça Eletrônico Nacional (DJEN)'),
      h('p', { class: 'sutil' }, 'Comunicações processuais capturadas direto na API pública do CNJ: todo dia pela OAB do escritório e, de madrugada, ',
        'processo por processo da carteira (processos do Atlas e os já conhecidos pelo sistema). Diários estaduais próprios ',
        '(ex.: DJ de Minas Gerais fora do DJEN) não estão nesta fonte; para eles vale a Webjur.'));
    const topo = h('div'), corpo = h('div'); raiz.append(topo, corpo);
    if (ehAdmin(ctx)) {
      const saida = h('div', { 'aria-live': 'polite' });
      const bt = (rot, fn) => { const b = h('button', { type: 'button', class: 'btn btn-sec', onclick: async () => {
        const txt = b.textContent; b.disabled = true; b.textContent = 'Consultando o CNJ…'; saida.textContent = '';
        try { saida.append(aviso('ok', await fn())); desenhar(); } catch (e) { saida.append(aviso('erro', msgErro(e))); }
        finally { b.disabled = false; b.textContent = txt; } } }, rot); return b; };
      topo.append(h('div', { class: 'acoes' },
        bt('Consultar agora pela OAB', async () => { const r = await chamar(ctx, { acao: 'oab' });
          return `Consulta por OAB: ${num(r.comunicacoes)} comunicação(ões), ${num(r.novas)} nova(s)` + (r.falhas ? `; ${r.falhas} falha(s): ${r.erros.join('; ')}` : '.'); }),
        bt('Consultar 20 processos da fila', async () => { const r = await chamar(ctx, { acao: 'lote', limite: 20 });
          return `${num(r.consultas)} processo(s) consultado(s), ${num(r.novas)} comunicação(ões) nova(s)` + (r.falhas ? `, ${r.falhas} falha(s) (voltam para a fila).` : '.'); }),
        bt('Atualizar a carteira de processos', async () => { const r = await chamar(ctx, { acao: 'carteira' });
          return `Carteira: ${num(r.carteira)} processo(s); ${num(r.atlas)} vindos do Atlas` + (r.erro_atlas ? ` (Atlas: ${r.erro_atlas})` : '') + '.'; })), saida);
    }
    const campo = (rot, el) => h('label', { class: 'filtro' }, h('span', {}, rot), el);
    const ini = h('input', { type: 'date', value: f.inicio }), fim = h('input', { type: 'date', value: f.fim });
    const busca = h('input', { type: 'search', placeholder: 'Processo, tribunal ou texto', 'aria-label': 'Buscar' });
    const filtro = h('select', {}, h('option', { value: '' }, 'Todas'), h('option', { value: 'sem_webjur' }, 'Sem captura da Webjur'),
      h('option', { value: 'com_webjur' }, 'Capturadas pela Webjur'));
    topo.append(h('form', { class: 'filtros-barra', onsubmit: e => { e.preventDefault(); f.inicio = ini.value; f.fim = fim.value; f.busca = busca.value; f.filtro = filtro.value; desenhar(); } },
      campo('Disponibilização de', ini), campo('até', fim), campo('Situação', filtro), campo('Busca', busca),
      h('button', { type: 'submit', class: 'btn btn-sec' }, 'Filtrar')));

    async function desenhar() {
      corpo.textContent = ''; corpo.append(h('p', { class: 'sutil' }, 'Carregando…'));
      let r;
      try {
        const { data: d, error } = await ctx.sb.rpc('cnj_painel', { p_inicio: f.inicio || null, p_fim: f.fim || null, p_busca: f.busca || null,
                                                                     p_filtro: f.filtro || null, p_limite: 1000 });
        if (error) throw error; r = d;
      } catch (e) { corpo.textContent = ''; corpo.append(aviso('erro', msgErro(e))); return; }
      corpo.textContent = '';
      const c = r.carteira, sem = r.itens.filter(i => !i.webjur).length;
      corpo.append(h('section', { class: 'kpis' },
        kpi('Comunicações no período', num(r.itens.length)),
        kpi('Sem captura da Webjur', num(sem), 'conferir', sem > 0),
        kpi('Processos na carteira', num(c.total), `${num(c.do_atlas)} do Atlas`),
        kpi('Consultados hoje', `${num(c.consultados_hoje)} de ${num(c.total)}`, c.com_falha ? `${num(c.com_falha)} com falha` : null, c.com_falha > 0)));
      if (r.execucoes.length) corpo.append(h('p', { class: 'sutil' }, 'Últimas execuções: ',
        r.execucoes.map(e => `${TIPO_EXEC[e.tipo] || e.tipo} em ${dataHora(e.inicio)} (${num(e.sucesso)} ok, ${num(e.falhas)} falha(s), ${num(e.novas)} nova(s))`).join(' · '), '.'));
      else corpo.append(aviso('alerta', 'A captura do CNJ ainda não rodou.'));
      corpo.append(tabela([
        { titulo: 'Disponibilização', valor: i => data(i.data_disponibilizacao) },
        { titulo: 'Processo', valor: i => h('span', { class: 'nowrap' }, i.cnj || '—') },
        { titulo: 'Tribunal / órgão', valor: i => [i.tribunal, i.orgao].filter(Boolean).join(' — ') },
        { titulo: 'Tipo', valor: i => [i.tipo, i.documento].filter(Boolean).join(' · ') },
        { titulo: 'Webjur', valor: i => i.webjur ? h('span', { class: 'tag tag-ok' }, i.webjur.exata ? 'Capturada' : 'Capturada (processo e data)')
                                                : h('span', { class: 'tag tag-erro' }, 'Não capturada') },
        { titulo: 'Comunicação', larga: true, valor: i => h('details', {}, h('summary', {}, (i.texto || '').slice(0, 140) + ((i.texto || '').length > 140 ? '…' : '')),
            h('p', { class: 'teor-cnj' }, i.texto || ''),
            i.link ? h('p', {}, h('a', { href: i.link, target: '_blank', rel: 'noopener noreferrer' }, 'Certidão no CNJ')) : null,
            h('p', { class: 'sutil' }, 'Captura: ' + (i.encontrada_por || []).map(x => x === 'processo' ? 'varredura por processo' : x.replace('oab:', 'OAB ')).join(', ')
              + (i.na_carteira ? '' : ' · processo fora da carteira'))) }
      ], r.itens, { compacta: true, vazio: 'Nenhuma comunicação no período.', classeLinha: i => i.webjur ? null : 'linha-alerta' }));
    }
    const kpi = (rotulo, valor, desc, atencao) => h('div', { class: 'kpi' + (atencao ? ' kpi-atencao' : '') },
      h('span', { class: 'kpi-rotulo' }, rotulo), h('span', { class: 'kpi-valor' }, valor), desc ? h('span', { class: 'kpi-desc' }, desc) : null);
    desenhar();
  }

  window.Cnj = { abrir, chamar };
})();
