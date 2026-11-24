/* Componentes comuns das áreas de indicadores: rótulos, filtros, aviso de atualização,
 * detalhamento (registros que formam cada número) e gráficos SVG. */
(function () {
  'use strict';
  const { h, data, dataHora, num, tabela, aviso } = UI;

  const ROTULOS = {
    indicador: {
      pendentes: 'Tarefas pendentes', vencidas: 'Vencidas (PF da Tarefa)', pf_judicial_vencido_conferir: 'PF Judicial vencido — conferir',
      vencem_hoje: 'Vencem hoje', d4_criticas: 'Críticas em D-4', sem_inicio: 'Abertas sem início',
      sem_inicio_24h: 'Sem início há +24 h', concluidas: 'Concluídas', protocolos_realizados: 'Protocolos realizados',
      distribuicoes_realizadas: 'Distribuições realizadas', pedidos_reagendamento: 'Solicitações de reagendamento',
      reagendamentos_efetivados: 'Reagendamentos efetivados'
    },
    categoria: {
      pf_judicial_vencido: 'PF Judicial vencido', pf_judicial_hoje: 'PF Judicial hoje', pf_judicial_proximo: 'PF Judicial próximo',
      pf_judicial_nao_confirmado: 'PF Judicial não confirmado', d4_vencido_sem_entrega: 'D-4 vencido sem entrega', d4_hoje: 'D-4 hoje',
      d4_proximo: 'D-4 próximo', pf_tarefa_vencido: 'PF da Tarefa vencido', pf_tarefa_hoje: 'PF da Tarefa hoje',
      pf_tarefa_proximo: 'PF da Tarefa próximo', divergencia_pf_tarefa_x_judicial: 'PF da Tarefa ≠ PF Judicial',
      d4_anotado_diverge_regra: 'D-4 anotado ≠ regra', d4_posterior_pf_judicial: 'D-4 após PF Judicial',
      agenda_posterior_pf_tarefa: 'Agenda após PF da Tarefa', pf_alterado_violacao: 'PF alterado (violação)',
      aberta_24h_sem_inicio: 'Aberta há +24 h sem início', d7_atingido_sem_inicio: 'Data atingida sem início',
      reagendamentos_sucessivos: 'Reagendamentos sucessivos', protocolo_sem_evidencia: 'Protocolo/distribuição sem evidência'
    },
    criticidade: { critica: 'Crítica', alta: 'Alta', media: 'Média' },
    grupo: { processual: 'Risco processual', operacional_interno: 'Operacional interno', inconsistencia_cadastral: 'Inconsistência cadastral', ausencia_evidencia: 'Ausência de evidência' },
    conferencia: { pendente_conferencia: 'Pendente de conferência', em_analise: 'Em análise', conferido: 'Conferido' },
    resultado: { em_analise: 'Em análise', procedente: 'Procedente', providencia_em_outra_tarefa: 'Providência em outra tarefa', dado_incorreto_no_advbox: 'Dado incorreto no ADVBOX', outro: 'Outro' },
    natureza: { solicitacao: 'Solicitação', efetivacao: 'Efetivação', anotacao_de_realocacao: 'Anotação de realocação', tentativa_pela_extensao: 'Tentativa (extensão)' },
    tipoEvento: { pedido_reagendamento: 'Pedido de reagendamento', anotacao_realocacao: 'Anotação de realocação', alteracao_data_agenda: 'Data da agenda alterada',
      alteracao_pf_tarefa: 'PF da Tarefa alterado', alteracao_responsavel: 'Responsável alterado', tentativa_realocacao: 'Realocação (extensão)', tentativa_alteracao_pf: 'Alteração de PF (extensão)', tentativa_conclusao: 'Conclusão (extensão)', excecao_d4: 'Exceção de D-4' },
    status: { pendente_sem_inicio: 'Pendente sem início', iniciada_nao_concluida: 'Iniciada, não concluída', concluida_com_inicio: 'Concluída com início',
      concluida_sem_inicio: 'Concluída sem início (inconsistência)', concluida_antes_do_monitoramento: 'Concluída antes do monitoramento' },
    estadoTrava: { bloqueio_efetivo: 'Bloqueio efetivo', permitida_apos_validacao: 'Permitida após validação', excecao_autorizada: 'Exceção autorizada', violacao_detectada: 'Violação detectada', nao_monitorada: 'Não monitorada' }
  };
  const rot = (grupo, k) => (ROTULOS[grupo] && ROTULOS[grupo][k]) || k || '—';

  // ---------------------------------------------------------------- filtros (estado compartilhado entre áreas)
  const hojeISO = () => new Date().toLocaleDateString('sv-SE', { timeZone: 'America/Sao_Paulo' });
  const somaDias = (iso, n) => { const d = new Date(iso + 'T12:00:00Z'); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); };
  const estado = { preset: '30', inicio: somaDias(hojeISO(), -29), fim: hojeISO(), equipe: '', colaborador: '' };
  let listas = null;
  async function carregarListas(sb) {
    if (listas) return listas;
    const [c, e] = await Promise.all([sb.from('colaboradores').select('id,nome_advbox,equipe_id').order('nome_advbox'),
                                      sb.from('equipes').select('id,nome').order('nome')]);
    listas = { colaboradores: c.data || [], equipes: e.data || [] };
    return listas;
  }
  function aplicarPreset(p) {
    const hoje = hojeISO(); estado.preset = p;
    if (p === 'hoje') { estado.inicio = hoje; estado.fim = hoje; }
    else if (p === 'mes') { estado.inicio = hoje.slice(0, 8) + '01'; estado.fim = hoje; }
    else if (p !== 'livre') { estado.inicio = somaDias(hoje, -(Number(p) - 1)); estado.fim = hoje; }
  }
  /** opcoes: {periodo, rotuloPeriodo, equipe, colaborador, extras:[elementos]} */
  async function barraFiltros(ctx, opcoes, aoMudar) {
    const admin = ['admin', 'diretoria', 'lider'].includes(ctx.perfil.papel);   // 0038: diretoria e líder também filtram
    const l = await carregarListas(ctx.sb);
    const barra = h('form', { class: 'filtros-barra', onsubmit: e => e.preventDefault(), 'aria-label': 'Filtros' });
    const mudar = () => aoMudar();
    if (opcoes.periodo !== false) {
      const sel = h('select', { 'aria-label': 'Período', onchange: e => { aplicarPreset(e.target.value); ini.value = estado.inicio; fim.value = estado.fim; mudar(); } },
        [['hoje', 'Hoje'], ['7', 'Últimos 7 dias'], ['30', 'Últimos 30 dias'], ['mes', 'Mês atual'], ['90', 'Últimos 90 dias'], ['livre', 'Personalizado']]
          .map(([v, t]) => h('option', { value: v, selected: estado.preset === v }, t)));
      const ini = h('input', { type: 'date', value: estado.inicio, 'aria-label': 'Início', onchange: e => { estado.inicio = e.target.value; estado.preset = 'livre'; sel.value = 'livre'; mudar(); } });
      const fim = h('input', { type: 'date', value: estado.fim, 'aria-label': 'Fim', onchange: e => { estado.fim = e.target.value; estado.preset = 'livre'; sel.value = 'livre'; mudar(); } });
      barra.append(h('label', { class: 'filtro' }, h('span', {}, opcoes.rotuloPeriodo || 'Período'), h('span', { class: 'filtro-linha' }, sel, ini, fim)));
    }
    if (admin && opcoes.equipe !== false && l.equipes.length) {
      barra.append(h('label', { class: 'filtro' }, h('span', {}, 'Equipe'), h('select', { onchange: e => { estado.equipe = e.target.value; mudar(); } },
        h('option', { value: '' }, 'Todas'), l.equipes.map(q => h('option', { value: q.id, selected: String(q.id) === estado.equipe }, q.nome)))));
    }
    if (admin && opcoes.colaborador !== false) {
      barra.append(h('label', { class: 'filtro' }, h('span', {}, 'Colaborador'), h('select', { onchange: e => { estado.colaborador = e.target.value; mudar(); } },
        h('option', { value: '' }, 'Todos'), l.colaboradores.map(c => h('option', { value: c.id, selected: String(c.id) === estado.colaborador }, c.nome_advbox)))));
    }
    for (const x of opcoes.extras || []) barra.append(x);
    return barra;
  }
  const filtroId = v => (v === '' || v === null || v === undefined) ? null : Number(v);
  const params = () => ({ p_inicio: estado.inicio, p_fim: estado.fim, p_equipe: filtroId(estado.equipe), p_colaborador: filtroId(estado.colaborador) });

  // ---------------------------------------------------------------- aviso de atualização da base
  function avisoBase(resumo) {
    const out = [];
    const hoje = resumo.hoje;
    if (!resumo.dados_atualizados_em) {
      out.push(aviso('alerta', 'Nenhuma importação concluída ainda: não há dados para os indicadores.'));
      return out;
    }
    const exp = resumo.data_exportacao ? String(resumo.data_exportacao).slice(0, 10) : null;
    const dias = exp ? Math.round((new Date(hoje + 'T12:00:00Z') - new Date(exp + 'T12:00:00Z')) / 864e5) : null;
    const texto = exp ? `Posição atual = exportação do ADVBOX de ${data(exp)}` : 'Posição atual = última importação (data da exportação não informada)';
    if (dias === null || dias >= 1)
      out.push(aviso('alerta', `${texto}${dias !== null ? `, de ${dias} ${dias === 1 ? 'dia' : 'dias'} atrás` : ''}, importada em ${dataHora(resumo.dados_atualizados_em)}. `
        + 'Pendentes, vencidas e D-4 são calculados contra a data de hoje com essa base: importe a exportação do dia antes de decidir.'));
    else out.push(h('p', { class: 'sutil base-ok' }, `${texto}, importada em ${dataHora(resumo.dados_atualizados_em)}.`));
    if (resumo.exportacoes_concluidas_possivelmente_cortadas > 0)
      out.push(aviso('alerta', 'A base atual tem exportação com número "redondo" de linhas (ex.: 50). As conclusões podem estar incompletas: confira a exportação de concluídas no ADVBOX.'));
    return out;
  }

  // ---------------------------------------------------------------- detalhamento
  let dialogo = null;
  function abrirDetalhe(titulo, subtitulo, carregar, colunas) {
    if (!dialogo) { dialogo = h('dialog', { class: 'detalhe', 'aria-labelledby': 'detalhe-titulo' }); document.body.append(dialogo); }
    dialogo.textContent = '';
    const corpo = h('div', { class: 'detalhe-corpo' }, h('p', { class: 'sutil' }, 'Carregando…'));
    dialogo.append(h('div', { class: 'detalhe-topo' }, h('div', {}, h('h2', { id: 'detalhe-titulo' }, titulo), subtitulo ? h('p', { class: 'sutil' }, subtitulo) : null),
      h('button', { type: 'button', class: 'btn btn-sec btn-peq', onclick: () => dialogo.close() }, 'Fechar')), corpo);
    dialogo.showModal();
    carregar().then(r => {
      corpo.textContent = '';
      if (r.erro) { corpo.append(aviso('erro', r.erro)); return; }
      corpo.append(h('p', { class: 'sutil' }, r.total > r.linhas.length ? `Mostrando ${num(r.linhas.length)} de ${num(r.total)} registros.` : `${num(r.total)} registro(s).`),
        tabela(colunas || COLUNAS_REGISTRO, r.linhas, { compacta: true }));
    });
  }
  const COLUNAS_REGISTRO = [
    { titulo: 'Data de referência', valor: r => data(r.data_referencia) },
    { titulo: 'Compromisso', valor: r => r.compromisso || '—' },
    { titulo: 'Processo', valor: r => r.processo_cnj || '—' },
    { titulo: 'Responsável', valor: r => r.responsavel || '—' },
    { titulo: 'Por que está aqui', valor: r => r.detalhe || '—', larga: true }
  ];
  function detalharIndicador(ctx, indicador, extra = {}) {
    const p = { ...params(), ...extra };
    const per = ['concluidas', 'protocolos_realizados', 'distribuicoes_realizadas', 'pedidos_reagendamento', 'reagendamentos_efetivados'].includes(indicador)
      ? `Período: ${data(p.p_inicio)} a ${data(p.p_fim)}` : 'Posição atual da base importada';
    abrirDetalhe(rot('indicador', indicador), per, async () => {
      const { data: d, error } = await ctx.sb.rpc('indicadores_detalhe', { ...p, p_indicador: indicador, p_limite: 500 });
      return error ? { erro: error.message } : d;
    });
  }

  // ---------------------------------------------------------------- gráficos SVG (sem biblioteca)
  const NS = 'http://www.w3.org/2000/svg';
  const s = (tag, attrs, ...f) => { const el = document.createElementNS(NS, tag); for (const [k, v] of Object.entries(attrs || {})) el.setAttribute(k, v); el.append(...f); return el; };
  const passo = max => { const brutos = max / 4, p10 = Math.pow(10, Math.floor(Math.log10(Math.max(brutos, 1)))); return [1, 2, 5, 10].map(m => m * p10).find(x => x >= brutos) || p10 * 10; };
  function dica(wrap) {
    const t = h('div', { class: 'grafico-dica', role: 'status', hidden: true }); wrap.append(t);
    return { mostrar(ev, texto) { t.textContent = texto; t.hidden = false; const r = wrap.getBoundingClientRect();
               t.style.left = Math.min(ev.clientX - r.left + 12, r.width - 180) + 'px'; t.style.top = (ev.clientY - r.top - 36) + 'px'; },
             esconder() { t.hidden = true; } };
  }
  function comTabela(titulo, grafico, colunas, linhas) {
    let modoTabela = false;
    const area = h('div', {}, grafico);
    const btn = h('button', { type: 'button', class: 'btn btn-sec btn-peq', 'aria-pressed': 'false', onclick: () => {
      modoTabela = !modoTabela; btn.setAttribute('aria-pressed', String(modoTabela)); btn.textContent = modoTabela ? 'Ver gráfico' : 'Ver como tabela';
      area.textContent = ''; area.append(modoTabela ? tabela(colunas, linhas, { compacta: true }) : grafico);
    } }, 'Ver como tabela');
    return h('section', { class: 'cartao grafico' }, h('div', { class: 'grafico-topo' }, h('h2', {}, titulo), btn), area);
  }

  /** Gráfico 1 — uma série: concluídas por dia. */
  function graficoPorDia(serie, aoClicar) {
    const W = 720, H = 220, m = { t: 12, r: 8, b: 28, l: 34 };
    const max = Math.max(1, ...serie.map(x => x.concluidas)); const st = passo(max); const topo = Math.ceil(max / st) * st;
    const iw = W - m.l - m.r, ih = H - m.t - m.b, bw = iw / serie.length, gap = Math.min(2, bw * 0.2), larg = Math.max(1, bw - gap);
    const svg = s('svg', { viewBox: `0 0 ${W} ${H}`, class: 'grafico-svg', role: 'img', 'aria-label': `Tarefas concluídas por dia, ${serie.length} dias, máximo ${max}` });
    for (let v = 0; v <= topo; v += st) {
      const y = m.t + ih - (v / topo) * ih;
      svg.append(s('line', { x1: m.l, x2: W - m.r, y1: y, y2: y, class: v === 0 ? 'eixo' : 'grade' }), s('text', { x: m.l - 6, y: y + 4, class: 'rotulo-eixo', 'text-anchor': 'end' }, String(v)));
    }
    const cada = Math.ceil(serie.length / 8);
    const wrap = h('div', { class: 'grafico-wrap' }); const tip = dica(wrap);
    serie.forEach((p, i) => {
      const x = m.l + i * bw + gap / 2, alt = (p.concluidas / topo) * ih, y = m.t + ih - alt, r = Math.min(4, larg / 2, alt);
      if (p.concluidas > 0) svg.append(s('path', { class: 'serie-1', d: `M${x},${m.t + ih} V${y + r} Q${x},${y} ${x + r},${y} H${x + larg - r} Q${x + larg},${y} ${x + larg},${y + r} V${m.t + ih} Z` }));
      const alvo = s('rect', { x: m.l + i * bw, y: m.t, width: bw, height: ih, class: 'alvo', tabindex: '0', 'aria-label': `${data(p.dia)}: ${p.concluidas} concluída(s)` });
      const txt = `${data(p.dia)}: ${p.concluidas} concluída(s)`;
      alvo.addEventListener('mousemove', ev => tip.mostrar(ev, txt)); alvo.addEventListener('mouseleave', () => tip.esconder());
      if (aoClicar && p.concluidas) alvo.addEventListener('click', () => aoClicar(p));
      svg.append(alvo);
      if (i % cada === 0) svg.append(s('text', { x: m.l + i * bw + bw / 2, y: H - 8, class: 'rotulo-eixo', 'text-anchor': 'middle' }, data(p.dia).slice(0, 5)));
    });
    wrap.prepend(svg);
    return wrap;
  }

  /** Gráfico 2 — duas séries por colaborador (barras horizontais agrupadas, mesmo eixo: nº de tarefas). */
  function graficoPorColaborador(linhas) {
    const W = 760, rot = 236, m = { t: 30, r: 44, b: 8 }, alturaGrupo = 30, barra = 10;
    const H = m.t + linhas.length * alturaGrupo + m.b;
    const max = Math.max(1, ...linhas.flatMap(x => [x.concluidas, x.pendentes])); const st = passo(max); const topo = Math.ceil(max / st) * st;
    const iw = W - rot - m.r; const xs = v => rot + (v / topo) * iw;
    const svg = s('svg', { viewBox: `0 0 ${W} ${H}`, class: 'grafico-svg', role: 'img', 'aria-label': 'Concluídas no período e pendentes por colaborador' });
    for (let v = 0; v <= topo; v += st) svg.append(s('line', { x1: xs(v), x2: xs(v), y1: m.t - 6, y2: H - m.b, class: v === 0 ? 'eixo' : 'grade' }),
      s('text', { x: xs(v), y: m.t - 12, class: 'rotulo-eixo', 'text-anchor': 'middle' }, String(v)));
    const wrap = h('div', { class: 'grafico-wrap' }); const tip = dica(wrap);
    linhas.forEach((l, i) => {
      const y0 = m.t + i * alturaGrupo + 4;
      svg.append(s('text', { x: rot - 8, y: y0 + barra + 2, class: 'rotulo-cat', 'text-anchor': 'end' }, l.responsavel.length > 28 ? l.responsavel.slice(0, 27) + '…' : l.responsavel));
      [['concluidas', 'serie-1', 0], ['pendentes', 'serie-2', barra + 2]].forEach(([k, cls, dy]) => {
        const v = l[k], y = y0 + dy, x1 = xs(v), r = Math.min(4, (x1 - rot) / 2, barra / 2);
        if (v > 0) svg.append(s('path', { class: cls, d: `M${rot},${y} H${x1 - r} Q${x1},${y} ${x1},${y + r} V${y + barra - r} Q${x1},${y + barra} ${x1 - r},${y + barra} H${rot} Z` }));
        svg.append(s('text', { x: x1 + 4, y: y + barra - 1, class: 'rotulo-valor' }, String(v)));
      });
      const alvo = s('rect', { x: 0, y: m.t + i * alturaGrupo, width: W, height: alturaGrupo, class: 'alvo', tabindex: '0',
        'aria-label': `${l.responsavel}: ${l.concluidas} concluídas, ${l.pendentes} pendentes` });
      alvo.append(s('title', {}, l.responsavel));
      alvo.addEventListener('mousemove', ev => tip.mostrar(ev, `${l.responsavel} — concluídas: ${l.concluidas} · pendentes: ${l.pendentes}`));
      alvo.addEventListener('mouseleave', () => tip.esconder());
      svg.append(alvo);
    });
    wrap.prepend(h('div', { class: 'legenda' }, h('span', { class: 'leg leg-1' }, 'Concluídas no período'), h('span', { class: 'leg leg-2' }, 'Pendentes (posição atual)')), svg);
    return wrap;
  }

  window.Comum = { ROTULOS, rot, barraFiltros, params, estado, avisoBase, abrirDetalhe, detalharIndicador, comTabela, graficoPorDia, graficoPorColaborador, filtroId };
})();
