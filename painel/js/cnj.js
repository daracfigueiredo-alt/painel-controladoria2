/* Intimações CNJ (12/11/2026): comunicações capturadas na API pública do CNJ (DJEN), por OAB e por processo
 * da carteira (processos do Atlas + processos já conhecidos). Substitui o módulo de intimações do Atlas, que o
 * escritório decidiu não contratar. Cada comunicação mostra se a Webjur também capturou (identificador exato,
 * ou processo e data). Toda permissão é decidida no banco.
 * 0064 (27/11/2026): a controladoria arquiva intimações já tratadas (lista "Arquivadas", motivo opcional, pode desarquivar);
 * cada intimação mostra se o processo está no Atlas e, se não estiver, a situação do cadastro automático (área
 * "Processos não cadastrados"). */
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
    const filtro = h('select', {}, h('option', { value: '' }, 'Pendentes (não arquivadas)'), h('option', { value: 'sem_webjur' }, 'Sem captura da Webjur'),
      h('option', { value: 'com_webjur' }, 'Capturadas pela Webjur'), h('option', { value: 'fora_atlas' }, 'Processo fora do Atlas'),
      h('option', { value: 'arquivadas' }, 'Arquivadas'));
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
      // tratamento (0065): fluxo de workflow aberto a partir de cada intimação
      const fluxos = await window.Workflows.fluxosPorOrigem(ctx, 'cnj', r.itens.map(i => i.id));
      corpo.textContent = '';
      const c = r.carteira, sem = r.itens.filter(i => !i.webjur).length, fora = r.itens.filter(i => !i.no_atlas).length;
      const arquivadas = f.filtro === 'arquivadas';
      const semTratamento = r.itens.filter(i => !fluxos[String(i.id)]).length;
      const irFiltro = v => () => { f.filtro = v; filtro.value = v; desenhar(); };
      corpo.append(h('section', { class: 'kpis' },
        kpi(arquivadas ? 'Arquivadas no período' : 'Comunicações pendentes', num(r.itens.length)),
        kpi('Sem tratamento', num(semTratamento), 'sem fluxo aberto', !arquivadas && semTratamento > 0),
        kpi('Sem captura da Webjur', num(sem), 'conferir', sem > 0, irFiltro('sem_webjur')),
        kpi('Processo fora do Atlas', num(fora), 'ver os processos não cadastrados', fora > 0, () => { location.hash = '#/nao-cadastrados'; }),
        kpi('Arquivadas no período', num(r.arquivadas_periodo || 0), arquivadas ? 'voltar às pendentes' : 'ver as arquivadas', false,
          irFiltro(arquivadas ? '' : 'arquivadas')),
        kpi('Processos na carteira', num(c.total), `${num(c.do_atlas)} do Atlas`),
        kpi('Consultados hoje', `${num(c.consultados_hoje)} de ${num(c.total)}`, c.com_falha ? `${num(c.com_falha)} com falha` : null, c.com_falha > 0)));
      if (r.execucoes.length) corpo.append(h('p', { class: 'sutil' }, 'Últimas execuções: ',
        r.execucoes.map(e => `${TIPO_EXEC[e.tipo] || e.tipo} em ${dataHora(e.inicio)} (${num(e.sucesso)} ok, ${num(e.falhas)} falha(s), ${num(e.novas)} nova(s))`).join(' · '), '.'));
      else corpo.append(aviso('alerta', 'A captura do CNJ ainda não rodou.'));
      if (fluxos._erro) corpo.append(aviso('alerta', 'Não foi possível ler o tratamento das intimações: ' + fluxos._erro));
      else if (ehAdmin(ctx) && !arquivadas) corpo.append(h('p', { class: 'sutil' }, 'Clique em "Tratar" para abrir o workflow da intimação: a triagem já vem com processo, cliente, equipe, data e link. ',
        'Depois de tratada, a intimação mostra o fluxo; ela pode ser arquivada quando o fluxo terminar.'));
      // seleção para arquivar / desarquivar (só a controladoria)
      const marcados = new Set();
      const admin = ehAdmin(ctx);
      if (admin && r.itens.length) {
        const mot = h('input', { type: 'text', placeholder: 'Motivo (opcional)', 'aria-label': 'Motivo do arquivamento', maxlength: 500 });
        const msg = h('span', { class: 'erro', 'aria-live': 'polite' });
        const conta = h('span', { class: 'sutil' }, 'Nenhuma selecionada.');
        const bt = h('button', { type: 'button', class: 'btn btn-sec', onclick: async () => {
          msg.textContent = '';
          if (!marcados.size) { msg.textContent = 'Selecione as intimações na tabela.'; return; }
          bt.disabled = true;
          try {
            const ids = [...marcados];
            const x = arquivadas ? await rpc('cnj_desarquivar', { p_ids: ids }) : await rpc('cnj_arquivar', { p_ids: ids, p_motivo: mot.value || null });
            desenhar(); void x;
          } catch (e) { msg.textContent = msgErro(e); bt.disabled = false; }
        } }, arquivadas ? 'Desarquivar selecionadas' : 'Arquivar selecionadas');
        corpo.append(h('div', { class: 'acoes barra-lote' }, conta, arquivadas ? null : mot, bt, msg));
        corpo._conta = n => { conta.textContent = n ? `${n} selecionada(s).` : 'Nenhuma selecionada.'; };
      }
      const caixa = i => h('input', { type: 'checkbox', 'aria-label': 'Selecionar a intimação de ' + data(i.data_disponibilizacao) + ' do processo ' + (i.cnj || ''),
        onchange: e => { if (e.target.checked) marcados.add(i.id); else marcados.delete(i.id); if (corpo._conta) corpo._conta(marcados.size); } });
      const tagAtlas = i => {
        if (i.no_atlas) return h('span', { class: 'tag tag-ok' }, 'No Atlas');
        const cad = i.cadastro;
        const st = cad && cad.situacao;
        const [t, cl] = st === 'cadastrado' ? ['Cadastrado agora', 'tag-ok'] : ['aprovado', 'enviando', 'previa'].includes(st) ? ['Cadastrando no Atlas', 'tag-neutra']
          : st === 'revisar' ? ['Fora do Atlas: conferir cliente', 'tag-alerta'] : st === 'erro' ? ['Erro no cadastro', 'tag-erro']
          : ['Fora do Atlas: escolher cliente', 'tag-erro'];
        return h('a', { href: '#/nao-cadastrados', class: 'tag ' + cl, title: cad && cad.cliente ? 'Cliente: ' + cad.cliente : 'Abrir os processos não cadastrados' }, t);
      };
      corpo.append(tabela([
        ...(admin ? [{ titulo: '', valor: caixa }] : []),
        { titulo: 'Disponibilização', valor: i => data(i.data_disponibilizacao) },
        { titulo: 'Processo', valor: i => h('span', { class: 'nowrap' }, i.cnj || '—') },
        { titulo: 'Tribunal / órgão', valor: i => [i.tribunal, i.orgao].filter(Boolean).join(' — ') },
        { titulo: 'Tipo', valor: i => [i.tipo, i.documento].filter(Boolean).join(' · ') },
        { titulo: 'Tratamento', valor: i => window.Workflows.celulaTratamento(ctx, fluxos[String(i.id)], {
            origem_tipo: 'cnj', origem_id: i.id, modalidade: 'DJEN',
            titulo: [i.cnj, data(i.data_disponibilizacao), [i.tipo, i.documento].filter(Boolean).join(' · ')].filter(Boolean).join(' — '), arquivada: !!i.arquivada }, admin, () => desenhar()) },
        { titulo: 'Atlas', valor: tagAtlas },
        { titulo: 'Webjur', valor: i => i.webjur ? h('span', { class: 'tag tag-ok' }, i.webjur.exata ? 'Capturada' : 'Capturada (processo e data)')
                                                : h('span', { class: 'tag tag-erro' }, 'Não capturada') },
        { titulo: 'Comunicação', larga: true, valor: i => { const t = UI.textoLegivel(i.texto); const linhas = t.split('\n');
          // resumo: o ato (ex.: ATO ORDINATÓRIO, DESPACHO) e o começo do corpo, sem o cabeçalho de partes
          const corpoIni = linhas.findIndex(l => !/^[A-ZÀ-Ú()\/ ]{3,40}:/.test(l) && !/^[A-ZÀ-Ú ]+ N[ºo°] /.test(l));
          const resumo = linhas.slice(corpoIni < 0 ? 0 : corpoIni).join(' · ');
          const soEventos = /refere-se aos seguintes eventos/i.test(t);
          return h('details', {}, h('summary', {}, resumo.slice(0, 160) + (resumo.length > 160 ? '…' : '')),
            h('div', { class: 'teor-cnj' }, linhas.map(l => h('p', { class: /^[A-ZÀ-Ú()\/ ]{3,40}:/.test(l) ? 'teor-cab' : null }, l))),
            soEventos ? h('p', { class: 'nota' }, 'Esta comunicação só cita os eventos do processo (padrão do eproc). O inteiro teor do ato está no documento do tribunal: abra a certidão abaixo.') : null,
            i.link ? h('p', {}, h('a', { href: i.link, target: '_blank', rel: 'noopener noreferrer' }, soEventos ? 'Abrir o documento no tribunal' : 'Certidão no CNJ')) : null,
            h('p', { class: 'sutil' }, 'Captura: ' + (i.encontrada_por || []).map(x => x === 'processo' ? 'varredura por processo' : x.replace('oab:', 'OAB ')).join(', ')
              + (i.na_carteira ? '' : ' · processo fora da carteira')),
            i.arquivada ? h('p', { class: 'nota' }, `Arquivada em ${dataHora(i.arquivada.em)}` + (i.arquivada.por ? ` por ${i.arquivada.por}` : '')
              + (i.arquivada.motivo ? `: ${i.arquivada.motivo}` : '.')) : null); } }
      ], r.itens, { compacta: true, vazio: arquivadas ? 'Nenhuma intimação arquivada no período.' : 'Nenhuma comunicação pendente no período.',
         classeLinha: i => i.webjur || i.arquivada ? null : 'linha-alerta' }));
    }
    const kpi = (rotulo, valor, desc, atencao, acao) => h(acao ? 'button' : 'div', { class: 'kpi' + (acao ? '' : ' kpi-estatico') + (atencao ? ' kpi-atencao' : ''),
      ...(acao ? { type: 'button', onclick: acao } : {}) },
      h('span', { class: 'kpi-rotulo' }, rotulo), h('span', { class: 'kpi-valor' }, valor), desc ? h('span', { class: 'kpi-desc' }, desc) : null);
    const rpc = async (fn, args) => { const { data: d, error } = await ctx.sb.rpc(fn, args); if (error) throw new Error(error.message); return d; };
    desenhar();
  }

  window.Cnj = { abrir, chamar };
})();
