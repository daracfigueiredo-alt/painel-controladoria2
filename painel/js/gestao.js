/* Pedidos da Dra. Mariana (11/11/2026):
 *  - Painel da diretoria (item 6): acompanhamento geral, produtividade e pendências;
 *  - Minha pauta (itens 5 e 6): pauta do peticionador com instruções, checklist, anexos e validações;
 *  - Solicitações (item 4): o líder pede tarefa nova ou reagendamento, o sistema analisa a pauta e sugere
 *    o remanejamento com justificativa; a controladoria aprova quando envolve prazo processual;
 *  - Relatório diário de inconsistências (item 3): double check Webjur × Atlas.
 * Toda permissão é decidida no banco; aqui só se escondem botões que o banco recusaria. */
(function () {
  'use strict';
  const { h, num, data, dataHora, aviso, tabela } = UI;
  const cfg = () => window.OC_CONFIG || {};
  const papel = ctx => ctx.perfil.papel;
  const ehAdmin = ctx => papel(ctx) === 'admin';
  const pausa = (bt, txt) => { const r = bt.textContent; bt.disabled = true; bt.textContent = txt; return () => { bt.disabled = false; bt.textContent = r; }; };
  const msgErro = e => (e && (e.message || e.erro)) || String(e);

  async function chamarAtlas(ctx, corpo) {
    const { data: d, error } = await ctx.sb.functions.invoke('atlas-sync', { body: corpo });
    if (error) {
      let msg = error.message;
      try { const j = await error.context.json(); msg = j.erro || msg; } catch (e) { /* sem corpo */ }
      throw new Error(msg);
    }
    return d;
  }
  // 0058 (17/11/2026): o peticionador pede reagendamento; até o D-4 decide o líder, depois do D-4 só a controladoria
  const hojeISO = () => new Date().toLocaleDateString('sv-SE', { timeZone: 'America/Sao_Paulo' });
  function quemDecide(t, novaData) {
    if (!t.d4 || t.excecao_d4) return 'lider';
    return (hojeISO() > t.d4 || (novaData && novaData > t.d4)) ? 'controladoria' : 'lider';
  }
  function formPedidoReagendamento(ctx, t, aoEnviar) {
    const caixa = h('div', { class: 'form-reagendamento' });
    const dataNova = h('input', { type: 'date', 'aria-label': 'Nova data', min: hojeISO(), max: t.pf_tarefa || null });
    const just = h('textarea', { rows: 2, 'aria-label': 'Justificativa do pedido', placeholder: 'Por que reagendar? (mín. 15 caracteres)' });
    const regra = h('p', { class: 'sutil', 'aria-live': 'polite' }); const msg = h('p', { class: 'erro', 'aria-live': 'polite' });
    const atualizar = () => {
      const quem = quemDecide(t, dataNova.value);
      regra.textContent = (t.d4 ? `D-4 (entrega): ${data(t.d4)}${t.excecao_d4 ? ' — entrega após o D-4 autorizada' : ''}. ` : 'Tarefa sem D-4. ')
        + (quem === 'lider' ? 'Quem decide: o líder da sua equipe.' : 'Depois do D-4: quem decide é a controladoria.');
    };
    dataNova.addEventListener('input', atualizar); atualizar();
    const bt = h('button', { type: 'button', class: 'btn btn-peq', onclick: async () => {
      msg.textContent = '';
      if (!dataNova.value) { msg.textContent = 'Informe a nova data.'; return; }
      const volta = pausa(bt, 'Enviando…');
      try {
        const sol = await rpc(ctx, 'solicitacao_reagendamento_pedir', { p_tarefa: t.tarefa_id, p_nova_data: dataNova.value, p_justificativa: just.value });
        caixa.textContent = '';
        caixa.append(aviso('ok', `Pedido #${sol.id} enviado: ${STATUS_SOL[sol.status]}.`, sol.motivos_controladoria.length ? ' ' + sol.motivos_controladoria.join('; ') + '.' : ''));
        if (aoEnviar) aoEnviar(sol);
      } catch (e) { msg.textContent = msgErro(e); volta(); }
    } }, 'Pedir reagendamento');
    caixa.append(h('div', { class: 'filtros-barra' }, h('label', { class: 'filtro' }, h('span', {}, `Nova data (hoje: ${data(t.data_agenda)})`), dataNova),
      h('label', { class: 'filtro filtro-largo' }, h('span', {}, 'Justificativa'), just)), regra, h('div', { class: 'acoes' }, bt), msg);
    return caixa;
  }

  async function rpc(ctx, fn, args) {
    const { data: d, error } = await ctx.sb.rpc(fn, args || {});
    if (error) throw new Error(error.message);
    return d;
  }
  const kpi = (rotulo, valor, desc, atencao) => h('div', { class: 'kpi' + (atencao ? ' kpi-atencao' : '') },
    h('span', { class: 'kpi-rotulo' }, rotulo), h('span', { class: 'kpi-valor' }, valor), desc ? h('span', { class: 'kpi-desc' }, desc) : null);
  const link = (url, texto) => url ? h('a', { href: url, target: '_blank', rel: 'noopener noreferrer' }, texto) : null;

  // ---------------------------------------------------------------- arquivos (Storage, bucket privado "pecas")
  async function token(ctx) { const { data: s } = await ctx.sb.auth.getSession(); return s.session ? s.session.access_token : ''; }
  async function sha256(buf) {
    const d = await crypto.subtle.digest('SHA-256', buf);
    return [...new Uint8Array(d)].map(x => x.toString(16).padStart(2, '0')).join('');
  }
  const nomeSeguro = n => String(n).normalize('NFD').replace(/[̀-ͯ]/g, '').replace(/[^A-Za-z0-9._-]+/g, '_').slice(-80);
  async function enviarAnexo(ctx, tarefaId, tipo, arquivo, maxMb) {
    if (!arquivo) throw new Error('Escolha o arquivo.');
    if (arquivo.size > (maxMb || 20) * 1048576) throw new Error(`Arquivo maior que ${maxMb || 20} MB.`);
    const buf = await arquivo.arrayBuffer();
    const caminho = `${tarefaId}/${Date.now()}-${tipo}-${nomeSeguro(arquivo.name)}`;
    const r = await fetch(`${cfg().SUPABASE_URL}/storage/v1/object/pecas/${caminho.split('/').map(encodeURIComponent).join('/')}`, {
      method: 'POST', body: buf,
      headers: { Authorization: 'Bearer ' + await token(ctx), apikey: cfg().SUPABASE_ANON_KEY, 'Content-Type': arquivo.type || 'application/octet-stream' } });
    if (!r.ok) { let m = r.status; try { m = (await r.json()).message || m; } catch (e) { /* */ } throw new Error('Envio do arquivo: ' + m); }
    return rpc(ctx, 'anexo_registrar', { p_tarefa: tarefaId, p_tipo: tipo, p_caminho: caminho, p_nome: arquivo.name, p_tamanho: arquivo.size,
      p_sha256: await sha256(buf), p_origem: 'painel' });
  }
  async function baixarAnexo(ctx, a) {
    const r = await fetch(`${cfg().SUPABASE_URL}/storage/v1/object/authenticated/pecas/${a.caminho.split('/').map(encodeURIComponent).join('/')}`,
      { headers: { Authorization: 'Bearer ' + await token(ctx), apikey: cfg().SUPABASE_ANON_KEY } });
    if (!r.ok) throw new Error('Arquivo indisponível (' + r.status + ')');
    const url = URL.createObjectURL(await r.blob());
    const el = h('a', { href: url, download: a.nome }); document.body.append(el); el.click(); el.remove();
    setTimeout(() => URL.revokeObjectURL(url), 30000);
  }
  const TIPO_ANEXO = { peca: 'Peça', parecer_autoavaliacao: 'Parecer de autoavaliação', outro: 'Outro' };

  // ---------------------------------------------------------------- Painel da diretoria
  async function diretoria(raiz, ctx) {
    raiz.append(h('h1', {}, 'Painel da diretoria'),
      h('p', { class: 'sutil' }, 'Acompanhamento geral: pendências da controladoria, solicitações dos líderes e produtividade da equipe no Atlas. Só leitura.'));
    const corpo = h('div'); raiz.append(corpo);
    corpo.append(h('p', { class: 'sutil' }, 'Carregando…'));
    let r;
    try { r = await rpc(ctx, 'diretoria_resumo'); } catch (e) { corpo.textContent = ''; corpo.append(aviso('erro', msgErro(e))); return; }
    corpo.textContent = '';
    const ult = r.ultimo_relatorio;
    corpo.append(h('section', { class: 'kpis', 'aria-label': 'Resumo' },
      kpi('Inconsistências abertas', num(r.inconsistencias_abertas), `${num(r.inconsistencias_criticas)} críticas`, r.inconsistencias_criticas > 0),
      kpi('Solicitações aguardando a controladoria', num(r.solicitacoes_aguardando), `${num(r.solicitacoes_mes)} no mês`, r.solicitacoes_aguardando > 0),
      kpi('Entregas autorizadas após o D-4', num(r.excecoes_d4_ativas), 'exceções ativas'),
      kpi('Modalidades padronizadas ativas', num(r.modalidades_ativas), 'com checklist e anexos obrigatórios'),
      kpi('Último relatório diário', ult ? dataHora(ult.executado_em) : '—', ult ? (ult.origem === 'automatico' ? 'rotina automática' : 'executado no painel') : 'ainda não executado')),
      h('p', {}, h('a', { href: '#/inconsistencias' }, 'Ver o relatório diário'), ' · ', h('a', { href: '#/visao-geral' }, 'Indicadores gerais'), ' · ',
        h('a', { href: '#/prazos' }, 'Prazos em risco'), ' · ', h('a', { href: '#/solicitacoes' }, 'Solicitações')));
    const p = r.produtividade || {};
    corpo.append(h('section', { class: 'cartao' }, h('h2', {}, 'Produtividade no Atlas'),
      h('p', { class: 'sutil' }, p.coleta ? `Coleta de ${dataHora(p.coleta)}, período ${data(p.periodo && p.periodo.de)} a ${data(p.periodo && p.periodo.ate)} (mesmo cálculo da tela Produtividade do Atlas).`
        : 'Ainda não coletada: a rotina do fim do expediente coleta a produtividade (permissão "Ler Produtividade" na chave do Atlas).'),
      tabela([
        { titulo: 'Pessoa', valor: m => m.nome || '—', larga: true },
        { titulo: 'Tarefas concluídas', num: true, valor: m => num(m.tarefas_concluidas) },
        { titulo: 'Dias ativos', num: true, valor: m => num(m.dias_ativos) },
        { titulo: 'Média por dia ativo', num: true, valor: m => m.media_por_dia_ativo === null || m.media_por_dia_ativo === undefined ? '—' : String(m.media_por_dia_ativo).replace('.', ',') },
        { titulo: 'Pendentes agora', num: true, valor: m => m.colaborador ? num(m.pendentes_agora) : '—' }
      ], p.membros || [], { compacta: true, vazio: 'Sem dados de produtividade.' })));
  }

  // ---------------------------------------------------------------- Minha pauta
  async function minhaPauta(raiz, ctx) {
    const f = { colaborador: null, dias: 30 };
    const vePauta = ['admin', 'diretoria', 'lider'].includes(papel(ctx));
    raiz.append(h('h1', {}, papel(ctx) === 'colaborador' ? 'Minha pauta' : 'Pautas'),
      h('p', { class: 'sutil' }, 'Tarefas pendentes, com prazos, instruções da modalidade, checklist obrigatório e anexos (peça e parecer de autoavaliação). ',
        'A conclusão no Atlas fica travada enquanto houver pendência em modalidade ativa.'));
    const filtros = h('form', { class: 'filtros-barra', onsubmit: e => e.preventDefault() }); const corpo = h('div');
    raiz.append(filtros, corpo);
    if (vePauta) {
      let lista = [];
      try { lista = papel(ctx) === 'diretoria' ? (await ctx.sb.from('colaboradores').select('id, nome_advbox').order('nome_advbox')).data.map(c => ({ id: c.id, nome: c.nome_advbox }))
                                              : await rpc(ctx, 'planejamento_colaboradores'); } catch (e) { /* lista vazia */ }
      filtros.append(h('label', { class: 'filtro' }, h('span', {}, 'Advogado'), h('select', { onchange: e => { f.colaborador = e.target.value ? Number(e.target.value) : null; desenhar(); } },
        h('option', { value: '' }, papel(ctx) === 'lider' ? 'Minha equipe' : 'Todos'), lista.map(c => h('option', { value: c.id }, c.nome)))));
    }
    filtros.append(h('label', { class: 'filtro' }, h('span', {}, 'Horizonte'), h('select', { onchange: e => { f.dias = Number(e.target.value); desenhar(); } },
      [[7, '7 dias'], [15, '15 dias'], [30, '30 dias'], [90, '90 dias']].map(([v, t]) => h('option', { value: v, selected: v === f.dias }, t)))));
    async function desenhar() {
      corpo.textContent = ''; corpo.append(h('p', { class: 'sutil' }, 'Carregando…'));
      let itens;
      try { itens = await rpc(ctx, 'minha_pauta', { p_colaborador: f.colaborador, p_dias: f.dias }); }
      catch (e) { corpo.textContent = ''; corpo.append(aviso('erro', msgErro(e))); return; }
      corpo.textContent = '';
      const comPend = itens.filter(t => t.exigido && t.pendencias.length).length;
      corpo.append(h('section', { class: 'kpis' }, kpi('Tarefas pendentes', num(itens.length)),
        kpi('Com pendência de execução', num(comPend), 'modalidade ativa com checklist ou anexo faltando', comPend > 0),
        kpi('Sem início da tratativa', num(itens.filter(t => !t.inicio_tratativa_em).length))));
      if (!itens.length) { corpo.append(aviso('info', 'Nenhuma tarefa pendente neste horizonte.')); return; }
      for (const t of itens) corpo.append(cartaoTarefa(t));
    }
    function cartaoTarefa(t) {
      const m = t.modalidade;
      const det = h('details', { class: 'cartao pauta-item' + (t.exigido && t.pendencias.length ? ' pauta-pendente' : '') });
      const prazos = [`Agenda ${data(t.data_agenda)}`, t.d4 ? `D-4 ${data(t.d4)}` : null, t.pf_judicial ? `PF Judicial ${data(t.pf_judicial)}` : null].filter(Boolean).join(' · ');
      det.append(h('summary', {}, h('b', {}, t.compromisso || '—'), ' ',
        m ? h('span', { class: 'tag ' + (m.ativa ? 'tag-ok' : 'tag-neutra') }, m.nome + (m.ativa ? '' : ' (modelo inativo)')) : h('span', { class: 'tag tag-neutra' }, 'sem modalidade'), ' ',
        t.exigido ? h('span', { class: 'tag ' + (t.pendencias.length ? 'tag-alerta' : 'tag-ok') }, t.pendencias.length ? `${t.pendencias.length} pendência(s)` : 'pronta para concluir') : null,
        t.excecao_d4 ? h('span', { class: 'tag tag-neutra' }, 'entrega após o D-4 autorizada') : null,
        h('br'), h('span', { class: 'sutil' }, [prazos, t.responsavel, t.processo_cnj].filter(Boolean).join(' · '))));
      const corpo = h('div', { class: 'pauta-corpo' }); det.append(corpo);
      det.addEventListener('toggle', () => { if (det.open && !corpo.childElementCount) preencher(corpo, t); });
      return det;
    }
    function preencher(corpo, t) {
      const m = t.modalidade; corpo.textContent = '';
      corpo.append(h('p', {}, link(t.atlas_url, 'Abrir no Atlas'), t.inicio_tratativa_em ? h('span', { class: 'sutil' }, ` · tratativa iniciada em ${dataHora(t.inicio_tratativa_em)}`)
        : h('span', { class: 'sutil' }, ' · tratativa ainda não iniciada (botão "Iniciar tratativa" na janela da tarefa no Atlas)')));
      if (papel(ctx) === 'colaborador' && t.atlas_url) {
        const det = h('details', { class: 'pedido-reagendamento' }, h('summary', {}, 'Pedir reagendamento'));
        det.addEventListener('toggle', () => { if (det.open && det.childElementCount === 1) det.append(formPedidoReagendamento(ctx, t)); });
        corpo.append(det);
      }
      if (!m) { corpo.append(aviso('info', 'Tarefa sem modalidade padronizada: não há checklist nem anexos obrigatórios.')); return; }
      if (m.orientacoes) corpo.append(h('p', {}, h('b', {}, 'Orientações: '), m.orientacoes));
      corpo.append(h('p', {}, link(m.link_treinamento, 'Material de treinamento'), m.link_treinamento && m.link_notebooklm ? ' · ' : '',
        link(m.link_notebooklm, 'Conferência técnica no NotebookLM')));
      const msg = h('p', { class: 'erro', 'aria-live': 'polite' });
      const lista = h('ul', { class: 'checklist' }, t.checklist.map(it => h('li', {}, h('label', {},
        h('input', { type: 'checkbox', checked: it.marcado, disabled: !t.pode_editar, onchange: async e => {
          e.target.disabled = true; msg.textContent = '';
          try { const ex = await rpc(ctx, 'execucao_marcar', { p_tarefa: t.tarefa_id, p_item: it.id, p_marcado: e.target.checked, p_origem: 'painel' }); Object.assign(t, ex); preencher(corpo, t); }
          catch (err) { msg.textContent = msgErro(err); e.target.checked = !e.target.checked; e.target.disabled = false; }
        } }), ' ', it.texto))));
      corpo.append(h('h3', {}, 'Checklist obrigatório'), lista);
      corpo.append(h('h3', {}, 'Anexos'), tabela([
        { titulo: 'Tipo', valor: a => TIPO_ANEXO[a.tipo] || a.tipo },
        { titulo: 'Arquivo', valor: a => h('button', { type: 'button', class: 'btn btn-sec btn-peq', onclick: () => baixarAnexo(ctx, a).catch(e => { msg.textContent = msgErro(e); }) }, a.nome), larga: true },
        { titulo: 'Enviado', valor: a => `${dataHora(a.em)} · ${a.por || '—'}` }
      ], t.anexos, { compacta: true, vazio: 'Nenhum anexo.' }));
      if (t.pode_editar) {
        const tipo = h('select', { 'aria-label': 'Tipo do anexo' }, ['peca', 'parecer_autoavaliacao', 'outro'].map(k => h('option', { value: k }, TIPO_ANEXO[k])));
        const arq = h('input', { type: 'file', 'aria-label': 'Arquivo', accept: '.pdf,.doc,.docx,.odt,.txt,.rtf' });
        const bt = h('button', { type: 'button', class: 'btn btn-peq', onclick: async () => {
          const volta = pausa(bt, 'Enviando…'); msg.textContent = '';
          try { const ex = await enviarAnexo(ctx, t.tarefa_id, tipo.value, arq.files[0], t.anexo_tamanho_maximo_mb); Object.assign(t, ex); preencher(corpo, t); }
          catch (e) { msg.textContent = msgErro(e); volta(); }
        } }, 'Anexar');
        corpo.append(h('div', { class: 'acoes' }, tipo, arq, bt));
      }
      if (t.exigido) corpo.append(t.pendencias.length ? aviso('alerta', h('b', {}, 'Pendências para concluir: '), h('ul', {}, t.pendencias.map(p => h('li', {}, p))))
        : aviso('ok', 'Checklist completo e anexos enviados: a conclusão no Atlas está liberada.'));
      else corpo.append(h('p', { class: 'sutil' }, 'Modalidade em modelo inativo: a controladoria ainda não ligou a exigência.'));
      corpo.append(msg);
    }
    desenhar();
  }

  // ---------------------------------------------------------------- Solicitações (líderes) e planejamento
  const STATUS_SOL = { aguardando_lider: 'Aguardando o líder', aguardando_controladoria: 'Aguardando a controladoria', aprovada: 'Aprovada', recusada: 'Recusada', em_execucao: 'Em execução',
    executada: 'Executada no Atlas', falhou: 'Falhou no Atlas', cancelada: 'Cancelada' };
  async function solicitacoes(raiz, ctx) {
    const podeSolicitar = ['admin', 'lider'].includes(papel(ctx));
    const peticionador = papel(ctx) === 'colaborador';
    raiz.append(h('h1', {}, 'Solicitações e reagendamentos'),
      h('p', { class: 'sutil' }, 'O líder pede uma tarefa nova ou um reagendamento. Antes de enviar, o sistema analisa a pauta do advogado (prazos internos e processuais, ',
        'prioridade, complexidade e capacidade diária) e sugere o que pode ser remanejado, com a justificativa. Reagendamento que envolve PF Judicial ',
        'ou passa do D-4 só é executado depois da aprovação da controladoria.'),
      h('p', { class: 'sutil' }, 'O peticionador também pede reagendamento das próprias tarefas: até o D-4, quem decide é o líder da equipe; ',
        'depois do D-4 (nova data depois do D-4 ou pedido feito quando o D-4 já passou), só a controladoria. Pedido que passa do D-4 sem decisão do líder sobe para a controladoria.'));
    const form = h('section', { class: 'cartao' }), lista = h('section', { class: 'cartao' });
    if (podeSolicitar || peticionador) raiz.append(form);
    raiz.append(lista);
    if (peticionador) desenharPedido();
    let colabs = [], modalidades = [];
    if (podeSolicitar) {
      try { [colabs, modalidades] = await Promise.all([rpc(ctx, 'planejamento_colaboradores'), ctx.sb.from('modalidades').select('id, nome, pontos').order('nome').then(r => r.data || [])]); }
      catch (e) { form.append(aviso('erro', msgErro(e))); }
      desenharForm();
    }
    desenharLista();

    async function desenharPedido() {
      form.textContent = ''; form.append(h('h2', {}, 'Pedir reagendamento'));
      let pauta = [];
      try { pauta = (await rpc(ctx, 'minha_pauta', { p_colaborador: null, p_dias: 90 })).filter(t => t.atlas_url); }
      catch (e) { form.append(aviso('erro', msgErro(e))); return; }
      if (!pauta.length) { form.append(aviso('info', 'Nenhuma tarefa pendente do Atlas nos próximos 90 dias.')); return; }
      const area = h('div');
      const sel = h('select', { 'aria-label': 'Tarefa', onchange: () => {
        area.textContent = ''; const t = pauta.find(x => String(x.tarefa_id) === sel.value);
        if (t) area.append(formPedidoReagendamento(ctx, t, () => desenharLista()));
      } }, h('option', { value: '' }, 'Escolha a tarefa…'), pauta.map(t => h('option', { value: t.tarefa_id },
        `${data(t.data_agenda)} — ${t.compromisso}${t.d4 ? ' (D-4 ' + data(t.d4) + ')' : ''}`)));
      form.append(h('label', { class: 'filtro filtro-largo' }, h('span', {}, 'Tarefa'), sel), area);
    }

    function desenharForm() {
      form.textContent = '';
      const tipo = h('select', { 'aria-label': 'Tipo', onchange: () => campos() }, h('option', { value: 'nova_tarefa' }, 'Tarefa nova'), h('option', { value: 'reagendamento' }, 'Reagendamento'));
      const adv = h('select', { 'aria-label': 'Advogado', onchange: () => campos() }, h('option', { value: '' }, 'Escolha…'),
        colabs.map(c => h('option', { value: c.id }, `${c.nome}${c.equipe ? ' — ' + c.equipe : ''} (capacidade ${c.capacidade} pts/dia)${c.atlas ? '' : ' — sem usuário no Atlas'}`)));
      const area = h('div'), analise = h('div', { 'aria-live': 'polite' }), msg = h('p', { class: 'erro', 'aria-live': 'polite' });
      const just = h('textarea', { rows: 3, 'aria-label': 'Justificativa', placeholder: 'Justificativa da solicitação (mín. 15 caracteres)' });
      let estado = {};
      form.append(h('h2', {}, 'Nova solicitação'), h('div', { class: 'filtros-barra' },
        h('label', { class: 'filtro' }, h('span', {}, 'Tipo'), tipo), h('label', { class: 'filtro' }, h('span', {}, 'Advogado'), adv)), area, analise,
        h('label', { class: 'filtro filtro-largo' }, h('span', {}, 'Justificativa'), just), msg);
      async function campos() {
        area.textContent = ''; analise.textContent = ''; msg.textContent = ''; estado = {};
        if (!adv.value) return;
        const btAnalisar = h('button', { type: 'button', class: 'btn btn-sec', onclick: () => analisar(btAnalisar) }, 'Analisar a pauta');
        if (tipo.value === 'nova_tarefa') {
          estado.campos = {
            titulo: h('input', { type: 'text', 'aria-label': 'Título', maxlength: 500 }),
            modalidade: h('select', { 'aria-label': 'Modalidade' }, h('option', { value: '' }, 'Sem modalidade (1 ponto)'), modalidades.map(m => h('option', { value: m.id }, `${m.nome} (${m.pontos} pts)`))),
            prioridade: h('select', { 'aria-label': 'Prioridade' }, h('option', { value: 'urgent' }, 'Urgente'), h('option', { value: 'normal' }, 'Normal')),
            data: h('input', { type: 'date', 'aria-label': 'Data na pauta' }), pf: h('input', { type: 'date', 'aria-label': 'Prazo fatal (opcional)' }),
            descricao: h('textarea', { rows: 2, 'aria-label': 'Descrição' }) };
          const c = estado.campos;
          area.append(h('div', { class: 'filtros-barra' }, h('label', { class: 'filtro filtro-largo' }, h('span', {}, 'Título'), c.titulo),
            h('label', { class: 'filtro' }, h('span', {}, 'Modalidade'), c.modalidade), h('label', { class: 'filtro' }, h('span', {}, 'Prioridade'), c.prioridade),
            h('label', { class: 'filtro' }, h('span', {}, 'Data na pauta'), c.data), h('label', { class: 'filtro' }, h('span', {}, 'Prazo fatal (opcional)'), c.pf)),
            h('label', { class: 'filtro filtro-largo' }, h('span', {}, 'Descrição (opcional)'), c.descricao), h('div', { class: 'acoes' }, btAnalisar));
        } else {
          let pauta = [];
          try { pauta = await rpc(ctx, 'minha_pauta', { p_colaborador: Number(adv.value), p_dias: 90 }); } catch (e) { msg.textContent = msgErro(e); }
          estado.pauta = pauta;
          estado.campos = {
            tarefa: h('select', { 'aria-label': 'Tarefa' }, h('option', { value: '' }, 'Escolha a tarefa…'), pauta.filter(t => t.atlas_url).map(t =>
              h('option', { value: t.tarefa_id }, `${data(t.data_agenda)} — ${t.compromisso}${t.pf_judicial ? ' (PF Judicial ' + data(t.pf_judicial) + ')' : ''}`))),
            data: h('input', { type: 'date', 'aria-label': 'Nova data' }),
            novo: h('select', { 'aria-label': 'Novo responsável' }, h('option', { value: '' }, 'Manter o responsável'), colabs.filter(c => String(c.id) !== adv.value).map(c => h('option', { value: c.id }, c.nome))) };
          const c = estado.campos;
          area.append(h('div', { class: 'filtros-barra' }, h('label', { class: 'filtro filtro-largo' }, h('span', {}, 'Tarefa'), c.tarefa),
            h('label', { class: 'filtro' }, h('span', {}, 'Nova data'), c.data), h('label', { class: 'filtro' }, h('span', {}, 'Novo responsável'), c.novo)),
            h('div', { class: 'acoes' }, btAnalisar));
        }
      }
      async function analisar(bt) {
        msg.textContent = ''; analise.textContent = ''; const c = estado.campos; const volta = pausa(bt, 'Analisando…');
        try {
          let a;
          if (tipo.value === 'nova_tarefa') {
            if (!c.data.value) throw new Error('Informe a data na pauta.');
            const mod = modalidades.find(m => String(m.id) === c.modalidade.value);
            a = await rpc(ctx, 'analisar_pauta', { p_colaborador: Number(adv.value), p_data: c.data.value, p_pontos: mod ? mod.pontos : null, p_urgente: c.prioridade.value === 'urgent', p_ignorar: null });
          } else {
            if (!c.tarefa.value) throw new Error('Escolha a tarefa.');
            const t = estado.pauta.find(x => String(x.tarefa_id) === c.tarefa.value);
            const dest = c.novo.value ? Number(c.novo.value) : Number(adv.value);
            a = await rpc(ctx, 'analisar_pauta', { p_colaborador: dest, p_data: c.data.value || t.data_agenda, p_pontos: t.modalidade ? t.modalidade.pontos : null, p_urgente: false, p_ignorar: t.tarefa_id });
          }
          estado.analise = a; desenharAnalise(a);
        } catch (e) { msg.textContent = msgErro(e); } finally { volta(); }
      }
      function desenharAnalise(a) {
        analise.textContent = '';
        analise.append(h('h3', {}, `Pauta de ${a.colaborador} em ${data(a.data)}`),
          h('p', {}, `Carga no dia: ${a.carga_no_dia} + ${a.pontos_novos} ponto(s) da nova tarefa, para capacidade de ${a.capacidade}. `,
            a.cabe_sem_remanejar ? h('b', {}, 'Cabe sem remanejar.') : h('b', {}, `Excesso de ${a.excesso} ponto(s).`)),
          tabela([{ titulo: 'Dia', valor: d => data(d.dia) }, { titulo: 'Carga', num: true, valor: d => `${d.carga}/${d.capacidade}` },
                  { titulo: 'Tarefas', valor: d => d.tarefas.map(t => `${t.compromisso} (${t.pontos})`).join('; ') || '—', larga: true }],
            a.dias, { compacta: true, classeLinha: d => d.carga > d.capacidade ? 'linha-alerta' : null }),
          aviso(a.cabe_sem_remanejar || a.sugestoes.length ? 'info' : 'alerta', h('b', {}, 'Recomendação: '), a.recomendacao));
        const escolha = h('fieldset', { class: 'sugestoes' }, h('legend', {}, 'Remanejamento'));
        const opcao = (valor, rotulo, marcado) => h('label', { class: 'opcao' }, h('input', { type: 'radio', name: 'remanejar', value: valor, checked: marcado }), ' ', rotulo);
        escolha.append(opcao('', 'Não remanejar nada', a.cabe_sem_remanejar || !a.sugestoes.length));
        a.sugestoes.forEach((s, i) => escolha.append(opcao(String(i), h('span', {}, h('b', {}, `${s.compromisso}: ${data(s.data_de)} → ${data(s.data_para)}`),
          s.exige_controladoria ? h('span', { class: 'tag tag-alerta' }, 'exige aprovação da controladoria') : h('span', { class: 'tag tag-ok' }, 'prazo interno'),
          h('br'), h('span', { class: 'sutil' }, s.justificativa)), !a.cabe_sem_remanejar && i === 0)));
        if (a.sugestoes.length || !a.cabe_sem_remanejar) analise.append(escolha);
        if (a.nao_remanejaveis.length) analise.append(h('p', { class: 'sutil' }, 'Não remanejáveis com segurança: ', a.nao_remanejaveis.map(x => `${x.compromisso} (${x.motivo})`).join('; '), '.'));
        const btEnviar = h('button', { type: 'button', class: 'btn', onclick: () => enviar(btEnviar, escolha) }, 'Enviar solicitação');
        analise.append(h('div', { class: 'acoes' }, btEnviar));
      }
      async function enviar(bt, escolha) {
        msg.textContent = ''; const c = estado.campos; const a = estado.analise;
        const sel = escolha.querySelector('input[name=remanejar]:checked'); const sug = sel && sel.value !== '' ? a.sugestoes[Number(sel.value)] : null;
        let dados;
        if (tipo.value === 'nova_tarefa') {
          dados = { titulo: c.titulo.value.trim(), prioridade: c.prioridade.value, data: c.data.value, pf: c.pf.value || null,
                    modalidade_id: c.modalidade.value ? Number(c.modalidade.value) : null, descricao: c.descricao.value.trim() || null };
        } else dados = { tarefa_id: Number(c.tarefa.value), nova_data: c.data.value || null, novo_colaborador_id: c.novo.value ? Number(c.novo.value) : null };
        const volta = pausa(bt, 'Enviando…');
        try {
          const s = await rpc(ctx, 'solicitacao_criar', { p_tipo: tipo.value, p_colaborador: Number(adv.value), p_dados: dados, p_remanejamento: sug, p_justificativa: just.value });
          desenharForm();
          form.append(aviso(s.status === 'aprovada' ? 'ok' : 'alerta', `Solicitação #${s.id}: ${STATUS_SOL[s.status]}.`,
            s.status === 'aprovada' ? ' Use "Executar no Atlas" na lista abaixo.' : ' ' + s.motivos_controladoria.join('; ') + '.'));
          desenharLista();
        } catch (e) { msg.textContent = msgErro(e); volta(); }
      }
    }

    async function desenharLista() {
      lista.textContent = ''; lista.append(h('h2', {}, 'Solicitações'), h('p', { class: 'sutil' }, 'Carregando…'));
      let itens;
      try { itens = await rpc(ctx, 'solicitacoes_listar', { p_status: null, p_limite: 200 }); }
      catch (e) { lista.textContent = ''; lista.append(aviso('erro', msgErro(e))); return; }
      lista.textContent = ''; lista.append(h('h2', {}, 'Solicitações'));
      const descr = s => s.tipo === 'nova_tarefa' ? `Tarefa nova: ${s.dados.titulo} (${data(s.dados.data)}${s.dados.prioridade === 'urgent' ? ', urgente' : ''})`
        : `Reagendar "${s.dados.compromisso}" de ${data(s.dados.data_atual)} para ${data(s.dados.nova_data || s.dados.data_atual)}${s.dados.novo_colaborador_id ? ' (troca de responsável)' : ''}`;
      lista.append(tabela([
        { titulo: '#', valor: s => String(s.id) },
        { titulo: 'Situação', valor: s => h('span', { class: 'tag ' + ({ executada: 'tag-ok', recusada: 'tag-erro', falhou: 'tag-erro', aguardando_controladoria: 'tag-alerta', aguardando_lider: 'tag-alerta' }[s.status] || 'tag-neutra') }, STATUS_SOL[s.status] || s.status) },
        { titulo: 'Pedido', valor: s => h('span', {}, h('b', {}, descr(s)), h('br'), h('span', { class: 'sutil' }, `Para ${s.colaborador} · por ${s.solicitante_nome || '—'} em ${dataHora(s.criada_em)}`),
            s.remanejamento ? h('span', {}, h('br'), `Remanejar: ${s.remanejamento.compromisso} ${data(s.remanejamento.data_de)} → ${data(s.remanejamento.data_para)}`) : null,
            h('br'), h('span', { class: 'sutil' }, 'Justificativa: ' + s.justificativa),
            s.motivos_controladoria.length ? h('span', {}, h('br'), h('span', { class: 'texto-alerta' }, 'Controladoria: ' + s.motivos_controladoria.join('; '))) : null,
            s.decisao_nota ? h('span', {}, h('br'), h('span', { class: 'sutil' }, `Decisão: ${s.decisao_nota}`)) : null), larga: true },
        { titulo: '', valor: s => acoes(s) }
      ], itens, { compacta: true, vazio: 'Nenhuma solicitação.' }));
    }
    function acoes(s) {
      const caixa = h('div', { class: 'acoes' }); const msg = h('p', { class: 'erro' });
      const souAutor = s.solicitante === ctx.usuario.id;
      const lider = papel(ctx) === 'lider';
      if ((ehAdmin(ctx) && ['aguardando_controladoria', 'aguardando_lider'].includes(s.status)) || (lider && s.status === 'aguardando_lider')) {
        if (s.solicitante_papel === 'colaborador' && s.tipo === 'reagendamento' && !s.analise) {   // 0058: análise da pauta para quem decide
          const btA = h('button', { type: 'button', class: 'btn btn-sec btn-peq', onclick: async () => {
            const volta = pausa(btA, 'Analisando…'); msg.textContent = '';
            try {
              const a = await rpc(ctx, 'analisar_pauta', { p_colaborador: s.colaborador_id, p_data: s.dados.nova_data, p_pontos: null, p_urgente: false, p_ignorar: s.dados.tarefa_id });
              btA.replaceWith(h('p', { class: 'sutil' }, `Pauta em ${data(a.data)}: carga ${a.carga_no_dia} + ${a.pontos_novos} para capacidade ${a.capacidade}. ${a.recomendacao}`));
            } catch (e) { msg.textContent = msgErro(e); volta(); }
          } }, 'Analisar a pauta');
          caixa.append(btA);
        }
        caixa.append(h('button', { type: 'button', class: 'btn btn-peq', onclick: () => decidir(true) }, 'Aprovar'),
          h('button', { type: 'button', class: 'btn btn-sec btn-peq', onclick: () => decidir(false) }, 'Recusar'));
      }
      const executar = async bt => {
        const volta = bt ? pausa(bt, 'Executando…') : () => {}; msg.textContent = '';
        try { await chamarAtlas(ctx, { acao: 'executar_solicitacao', id: s.id }); desenharLista(); } catch (e) { msg.textContent = msgErro(e); volta(); desenharLista(); }
      };
      if ((ehAdmin(ctx) || souAutor || lider) && papel(ctx) !== 'colaborador' && ['aprovada', 'falhou'].includes(s.status)) {
        const bt = h('button', { type: 'button', class: 'btn btn-peq', onclick: () => executar(bt) }, 'Executar no Atlas');
        caixa.append(bt);
      }
      if ((ehAdmin(ctx) || souAutor) && ['aguardando_lider', 'aguardando_controladoria', 'aprovada', 'falhou'].includes(s.status)) {
        caixa.append(h('button', { type: 'button', class: 'btn btn-sec btn-peq', onclick: async () => {
          try { await rpc(ctx, 'solicitacao_cancelar', { p_id: s.id, p_nota: 'Cancelada no painel' }); desenharLista(); } catch (e) { msg.textContent = msgErro(e); }
        } }, 'Cancelar'));
      }
      function decidir(aprovar) {
        caixa.textContent = '';
        const nota = h('textarea', { rows: 2, 'aria-label': 'Motivo da decisão', placeholder: 'Motivo da decisão (mín. 10 caracteres)' });
        caixa.append(h('div', { class: 'form-conferencia' }, nota, h('div', { class: 'acoes' },
          h('button', { type: 'button', class: 'btn btn-peq', onclick: async () => {
            try {
              const r = await rpc(ctx, 'solicitacao_decidir', { p_id: s.id, p_aprovar: aprovar, p_nota: nota.value });
              if (r.encaminhada_controladoria) { desenharLista(); return; }
              if (r.status === 'aprovada') { await executar(null); return; }   // aprovada: executa no Atlas na hora
              desenharLista();
            } catch (e) { msg.textContent = msgErro(e); }
          } }, aprovar ? 'Confirmar aprovação' : 'Confirmar recusa'),
          h('button', { type: 'button', class: 'btn btn-sec btn-peq', onclick: () => desenharLista() }, 'Voltar')), msg));
        nota.focus();
      }
      caixa.append(msg);
      return caixa;
    }
  }

  // ---------------------------------------------------------------- Relatório diário de inconsistências
  const TIPO_INC = { intimacao_nao_cadastrada: 'Intimação não cadastrada no Atlas', divergencia: 'Divergência Webjur × Atlas', prazo_nao_lancado: 'Prazo não lançado',
    prazo_incorreto: 'Prazo lançado incorretamente', publicacao_duplicada: 'Publicação duplicada', pendencia_controladoria: 'Pendência da controladoria',
    captura_divergente: 'Captura divergente CNJ × Webjur', audiencia_pendente: 'Audiência pendente', conclusao_sem_justificativa: 'Conclusão sem justificativa' };
  const SIT_INC = { aberta: 'Aberta', regularizada: 'Regularizada', justificada: 'Justificada' };
  async function inconsistencias(raiz, ctx) {
    const f = { situacao: 'aberta', tipo: null };
    raiz.append(h('h1', {}, 'Double check de intimações'),
      h('p', { class: 'subtitulo' }, 'Relatório diário de inconsistências'),
      h('p', { class: 'sutil' }, 'Dupla checagem entre as comunicações do CNJ (DJEN), as publicações da Webjur e o Atlas. Roda sozinha no fim do expediente ',
        '(dias úteis) e pode ser rodada aqui. O que for corrigido sai sozinho na execução seguinte.'));
    const topo = h('div'), corpo = h('div'); raiz.append(topo, corpo);
    if (ehAdmin(ctx)) {
      const saida = h('div', { 'aria-live': 'polite' });
      const bt = (rot, fn) => { const b = h('button', { type: 'button', class: 'btn btn-sec', onclick: async () => {
        const volta = pausa(b, 'Executando…'); saida.textContent = '';
        try { saida.append(aviso('ok', await fn())); desenhar(); } catch (e) { saida.append(aviso('erro', msgErro(e))); } finally { volta(); } } }, rot); return b; };
      topo.append(h('div', { class: 'acoes' },
        bt('Rodar a conferência agora', async () => { const r = await rpc(ctx, 'double_check_atlas_executar', { p_dia: null, p_origem: 'manual' }); return `Conferência concluída: ${r.novas} nova(s), ${r.regularizadas} regularizada(s), ${r.abertas} aberta(s).`; }),
        bt('Sincronizar intimações do Atlas', async () => { const r = await chamarAtlas(ctx, { acao: 'sincronizar_intimacoes' }); return `${num(r.intimacoes)} intimações do Atlas sincronizadas em ${r.segundos} s.`; }),
        bt('Consultar o CNJ pela OAB', async () => { const r = await window.Cnj.chamar(ctx, { acao: 'oab' }); return `CNJ: ${num(r.comunicacoes)} comunicação(ões), ${num(r.novas)} nova(s).`; }),
        bt('Rotina completa do fim do expediente', async () => { const r = await chamarAtlas(ctx, { acao: 'fim_expediente' });
          return 'Rotina: ' + Object.entries(r.etapas).map(([k, v]) => `${k} ${v.ok ? 'ok' : 'com erro (' + v.erro + ')'}`).join('; ') + '.'; })), saida);
    }
    const sel = (rot, op, val, fn) => h('label', { class: 'filtro' }, h('span', {}, rot), h('select', { onchange: e => { fn(e.target.value || null); desenhar(); } },
      h('option', { value: '' }, 'Todas'), Object.entries(op).map(([k, t]) => h('option', { value: k, selected: k === val }, t))));
    topo.append(h('form', { class: 'filtros-barra', onsubmit: e => e.preventDefault() }, sel('Situação', SIT_INC, f.situacao, v => { f.situacao = v; }), sel('Tipo', TIPO_INC, f.tipo, v => { f.tipo = v; })));
    let ultimo = [];
    async function desenhar() {
      corpo.textContent = ''; corpo.append(h('p', { class: 'sutil' }, 'Carregando…'));
      let r;
      try { r = await rpc(ctx, 'relatorio_inconsistencias', { p_situacao: f.situacao, p_tipo: f.tipo, p_limite: 1000 }); }
      catch (e) { corpo.textContent = ''; corpo.append(aviso('erro', msgErro(e))); return; }
      corpo.textContent = ''; ultimo = r.itens;
      const u = r.ultimo_relatorio;
      corpo.append(u ? h('p', { class: 'sutil' }, `Última execução: ${dataHora(u.executado_em)} (${u.origem === 'automatico' ? 'rotina automática' : 'painel'}), `,
        `${num(u.resumo.publicacoes_conferidas)} publicações da Webjur conferidas desde ${data(u.resumo.janela_de)}.`)
        : aviso('alerta', 'A conferência ainda não foi executada.'));
      corpo.append(h('section', { class: 'kpis' }, Object.entries(TIPO_INC).map(([k, t]) => kpi(t, num(r.por_tipo[k] || 0), null, (r.por_tipo[k] || 0) > 0 && f.situacao === 'aberta'))));
      corpo.append(h('div', { class: 'acoes' }, h('button', { type: 'button', class: 'btn btn-sec btn-peq', onclick: () => exportarCsv(ultimo) }, 'Exportar CSV')));
      corpo.append(tabela([
        { titulo: 'Gravidade', valor: i => h('span', { class: 'tag crit crit-' + ['critica', 'alta', 'media'][i.gravidade - 1] }, ['● Crítica', '▲ Alta', '■ Média'][i.gravidade - 1]) },
        { titulo: 'Tipo', valor: i => TIPO_INC[i.tipo] || i.tipo },
        { titulo: 'Dia', valor: i => data(i.dia) },
        { titulo: 'Processo', valor: i => i.cnj || '—' },
        { titulo: 'Inconsistência', valor: i => h('span', {}, i.descricao, i.acao_sugerida ? h('span', {}, h('br'), h('span', { class: 'sutil' }, 'O que fazer: ' + i.acao_sugerida)) : null,
            i.dados && i.dados.atlas ? h('span', {}, ' ', link(i.dados.atlas, 'abrir no Atlas')) : null,
            i.dados && i.dados.link ? h('span', {}, ' ', link(i.dados.link, 'certidão no CNJ')) : null), larga: true },
        { titulo: 'Situação', valor: i => h('span', {}, SIT_INC[i.situacao], i.nota ? h('span', { class: 'sutil' }, ' — ' + i.nota) : null) },
        ...(ehAdmin(ctx) ? [{ titulo: '', valor: i => tratar(i) }] : [])
      ], r.itens, { compacta: true, vazio: 'Nenhuma inconsistência com esses filtros.' }));
    }
    function tratar(i) {
      const alvo = i.situacao === 'aberta' ? 'justificada' : 'aberta';
      return h('button', { type: 'button', class: 'btn btn-sec btn-peq', onclick: ev => {
        const td = ev.target.closest('td'); td.textContent = '';
        const nota = h('textarea', { rows: 2, 'aria-label': 'Nota', placeholder: 'Nota (mín. 10 caracteres)' }); const msg = h('p', { class: 'erro' });
        td.append(h('div', { class: 'form-conferencia' }, nota, h('div', { class: 'acoes' },
          h('button', { type: 'button', class: 'btn btn-peq', onclick: async () => {
            try { await rpc(ctx, 'inconsistencia_tratar', { p_id: i.id, p_situacao: alvo, p_nota: nota.value }); desenhar(); } catch (e) { msg.textContent = msgErro(e); }
          } }, 'Salvar'), h('button', { type: 'button', class: 'btn btn-sec btn-peq', onclick: () => desenhar() }, 'Cancelar')), msg));
        nota.focus();
      } }, i.situacao === 'aberta' ? 'Justificar' : 'Reabrir');
    }
    function exportarCsv(itens) {
      const esc = v => `"${String(v === null || v === undefined ? '' : v).replace(/"/g, '""')}"`;
      const linhas = [['Gravidade', 'Tipo', 'Dia', 'Processo', 'Inconsistência', 'O que fazer', 'Situação', 'Nota', 'Primeira vez', 'Última vez'].map(esc).join(';')]
        .concat(itens.map(i => [i.gravidade, TIPO_INC[i.tipo] || i.tipo, data(i.dia), i.cnj, i.descricao, i.acao_sugerida, SIT_INC[i.situacao], i.nota,
          dataHora(i.primeira_vez_em), dataHora(i.ultima_vez_em)].map(esc).join(';')));
      const url = URL.createObjectURL(new Blob(['﻿' + linhas.join('\r\n')], { type: 'text/csv;charset=utf-8' }));
      const a = h('a', { href: url, download: `inconsistencias_${new Date().toISOString().slice(0, 10)}.csv` }); document.body.append(a); a.click(); a.remove();
      setTimeout(() => URL.revokeObjectURL(url), 30000);
    }
    desenhar();
  }

  window.Gestao = { diretoria, minhaPauta, solicitacoes, inconsistencias, chamarAtlas };
})();
