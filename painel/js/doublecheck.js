/* Área 8 — Double check ADVBOX (Etapa 7). Exclusiva do administrador.
 * Compara as publicações da Webjur (área 7) com as intimações lidas do ADVBOX pela extensão
 * (tela "Intimações recebidas" → "Registrar as intimações desta tela"). A comparação roda no
 * banco (double_check_executar); aqui só se executa, consulta e registra a conferência manual. */
(function () {
  'use strict';
  const { h, data, dataHora, num, tabela, aviso } = UI;
  const SIT = {
    encontrada_advbox: 'Encontrada no ADVBOX', nao_encontrada_advbox: 'Não encontrada no ADVBOX', processo_nao_cadastrado: 'Processo não cadastrado', duplicidade_webjur: 'Duplicidade na Webjur',
    inconclusiva: 'Inconclusiva', conferencia_manual: 'Conferência manual', erro_coleta: 'Erro de coleta', erro_acesso_advbox: 'Erro de acesso ao ADVBOX',
    aguardando: 'Aguardando varredura do ADVBOX'
  };
  const TAREFA = { preparada: 'Preparada (aguarda aprovação)', aprovada: 'Aprovada', rejeitada: 'Rejeitada', criada: 'Criada no ADVBOX',
    conferencia_manual: 'Conferência manual', ja_tratada: 'Já tratada', criacao_em_andamento: 'Criação em andamento', verificar_no_advbox: 'Verificar no ADVBOX' };
  const hojeISO = () => new Date().toLocaleDateString('sv-SE', { timeZone: 'America/Sao_Paulo' });
  const somaDias = (iso, n) => { const d = new Date(iso + 'T12:00:00Z'); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); };
  const filtros = { inicio: somaDias(hojeISO(), -6), fim: hojeISO(), situacao: '' };
  const linkAdvbox = id => /^\d{1,15}$/.test(id || '') ? h('a', { href: `https://app.advbox.com.br/posts/${id}/edit`, target: '_blank', rel: 'noopener noreferrer', class: 'nowrap' }, id) : '—';
  const pct = v => v === null || v === undefined ? '—' : Number(v).toLocaleString('pt-BR', { maximumFractionDigits: 1 }) + '%';
  let ctx, raiz;

  async function abrir(container, contexto) {
    ctx = contexto; raiz = container;
    raiz.append(
      h('h1', {}, 'Double check ADVBOX'),
      h('ol', { class: 'sutil dc-passos' },
        h('li', {}, 'Importe as publicações da Webjur do dia (área "Publicações Webjur").'),
        h('li', {}, 'No ADVBOX, abra "Intimações recebidas", escolha um período que cubra a disponibilização e o dia seguinte, mostre todos os registros numa página e clique em "Registrar as intimações desta tela" (extensão).'),
        h('li', {}, 'Aqui, execute o double check. Só uma varredura completa permite concluir que uma publicação não foi capturada.')),
      h('section', { class: 'cartao', id: 'dc-controle' }),
      h('section', { class: 'cartao', id: 'dc-relatorio' }),
      h('section', { class: 'cartao', id: 'dc-lista' }));
    desenharControle();
    await atualizar();
  }

  function desenharControle() {
    const el = raiz.querySelector('#dc-controle');
    const saida = h('div', { id: 'dc-saida' });
    el.append(h('h2', {}, 'Período de disponibilização'),
      h('form', { class: 'filtros-barra', onsubmit: e => e.preventDefault() },
        h('label', { class: 'filtro' }, h('span', {}, 'De'), h('input', { type: 'date', id: 'dc-ini', value: filtros.inicio, onchange: e => { filtros.inicio = e.target.value; atualizar(); } })),
        h('label', { class: 'filtro' }, h('span', {}, 'Até'), h('input', { type: 'date', id: 'dc-fim', value: filtros.fim, onchange: e => { filtros.fim = e.target.value; atualizar(); } })),
        h('div', { class: 'acoes' }, h('button', { type: 'button', class: 'btn', id: 'dc-executar', onclick: executar }, 'Executar double check'))),
      saida);
  }

  async function executar(ev) {
    const btn = ev.currentTarget, saida = raiz.querySelector('#dc-saida');
    btn.disabled = true; btn.textContent = 'Comparando…'; saida.textContent = '';
    const { data: d, error } = await ctx.sb.rpc('double_check_executar', { p_inicio: filtros.inicio, p_fim: filtros.fim });
    btn.disabled = false; btn.textContent = 'Executar double check';
    if (error) { saida.append(aviso('erro', error.message)); return; }
    const cont = {}; d.itens.forEach(i => { const k = i.resultado === 'conferida' ? i.situacao : i.resultado; cont[k] = (cont[k] || 0) + 1; });
    const rot = { ja_conferida: 'já conferidas antes', sem_mudanca: 'sem mudança', aguardando_varredura: 'aguardando varredura do ADVBOX' };
    saida.append(aviso(cont.aguardando_varredura ? 'alerta' : 'info', `${num(d.total)} publicação(ões) no período. `,
      Object.entries(cont).map(([k, n]) => `${SIT[k] || rot[k] || k}: ${num(n)}`).join(' · ') + '.',
      cont.aguardando_varredura ? ' Registre no ADVBOX uma varredura completa que cubra esses dias e execute de novo.' : ''));
    await atualizar();
  }

  async function atualizar() { await Promise.all([relatorio(), listar()]); }

  async function relatorio() {
    const el = raiz.querySelector('#dc-relatorio');
    const { data: d, error } = await ctx.sb.rpc('double_check_diario', { p_inicio: filtros.inicio, p_fim: filtros.fim });
    el.textContent = ''; el.append(h('h2', {}, 'Relatório diário'));
    if (error) { el.append(aviso('erro', error.message)); return; }
    el.append(h('p', { class: 'sutil' }, 'Por data de disponibilização. O percentual de ausentes considera só as conferidas efetivamente (encontradas, ausentes e processo não cadastrado), sem erros, inconclusivas ou aguardando.'),
      tabela([
        { titulo: 'Disponibilização', valor: x => data(x.dia) }, { titulo: 'Recebidas', num: true, valor: x => num(x.recebidas) },
        { titulo: 'Encontradas', num: true, valor: x => num(x.encontradas) }, { titulo: 'Ausentes', num: true, valor: x => num(x.ausentes) },
        { titulo: 'Processo não cadastrado', num: true, valor: x => num(x.processo_nao_cadastrado) },
        { titulo: 'Inconclusivas', num: true, valor: x => num(x.inconclusivas) }, { titulo: 'Duplicidade Webjur', num: true, valor: x => num(x.duplicidades) }, { titulo: 'Aguardando', num: true, valor: x => num(x.aguardando) },
        { titulo: 'Erros', num: true, valor: x => num(x.erros_integracao) }, { titulo: '% ausentes', num: true, valor: x => pct(x.pct_ausentes) },
        { titulo: 'Tarefas aprovadas', num: true, valor: x => num(x.tarefas_aprovadas) }, { titulo: 'Tarefas criadas', num: true, valor: x => num(x.tarefas_criadas) }
      ], d || [], { compacta: true, vazio: 'Nenhuma publicação no período.', classeLinha: x => x.ausentes || x.processo_nao_cadastrado || x.inconclusivas ? 'linha-alerta' : null }));
  }

  async function listar() {
    const el = raiz.querySelector('#dc-lista');
    const { data: d, error } = await ctx.sb.rpc('double_check_listar', { p_inicio: filtros.inicio, p_fim: filtros.fim, p_situacao: filtros.situacao || null, p_limite: 500 });
    el.textContent = '';
    el.append(h('h2', {}, 'Publicações'),
      h('label', { class: 'filtro' }, h('span', {}, 'Situação'), h('select', { id: 'dc-situacao', onchange: e => { filtros.situacao = e.target.value; listar(); } },
        [['', 'Todas'], ...Object.entries(SIT)].map(([v, t]) => h('option', { value: v, selected: filtros.situacao === v }, t)))));
    if (error) { el.append(aviso('erro', error.message)); return; }
    el.append(h('p', { class: 'sutil', id: 'dc-total' }, d.total > d.linhas.length ? `Mostrando ${num(d.linhas.length)} de ${num(d.total)}.` : `${num(d.total)} publicação(ões).`),
      tabela([
        { titulo: 'Disponibilização', valor: x => data(x.data_disponibilizacao) }, { titulo: 'Publicação', valor: x => data(x.data_publicacao) },
        { titulo: 'Processo', valor: x => h('span', { class: 'nowrap' }, x.cnj || 'sem CNJ') },
        { titulo: 'Tribunal / órgão', valor: x => [x.tribunal, x.orgao_julgador].filter(Boolean).join(' — ') || '—' },
        { titulo: 'Situação', valor: x => SIT[x.situacao_conferencia || 'aguardando'] },
        { titulo: 'Intimação no ADVBOX', valor: x => linkAdvbox(x.advbox_post_id) },
        { titulo: 'Semelhança', num: true, valor: x => x.semelhanca === null || x.semelhanca === undefined ? '—' : Number(x.semelhanca).toLocaleString('pt-BR', { maximumFractionDigits: 2 }) },
        { titulo: 'Tarefa de análise', valor: x => TAREFA[x.tarefa_analise_status] || '—' },
        { titulo: '', valor: x => ['inconclusiva', null, 'nao_encontrada_advbox', 'processo_nao_cadastrado'].includes(x.situacao_conferencia || null) && !['criada', 'aprovada'].includes(x.tarefa_analise_status)
            ? h('button', { type: 'button', class: 'btn btn-sec btn-peq dc-conferir', onclick: () => conferir(x) }, 'Conferir') : '' }
      ], d.linhas, { vazio: 'Nenhuma publicação no período.', classeLinha: x => ['nao_encontrada_advbox', 'processo_nao_cadastrado', 'inconclusiva'].includes(x.situacao_conferencia) ? 'linha-alerta' : null }));
    el.append(h('h3', {}, 'Últimas varreduras do ADVBOX'), tabela([
      { titulo: '#', num: true, valor: v => v.id }, { titulo: 'Realizada em', valor: v => dataHora(v.realizada_em) },
      { titulo: 'Recebidas no ADVBOX de', valor: v => data(v.recebido_de) }, { titulo: 'até', valor: v => data(v.recebido_ate) },
      { titulo: 'Lidas', num: true, valor: v => num(v.total_lido) }, { titulo: 'Na tela', num: true, valor: v => num(v.total_informado) },
      { titulo: 'Situação', valor: v => v.completa ? 'Completa' : `Incompleta${v.erros ? ` (${v.erros} erro(s))` : ''}` }
    ], d.varreduras, { compacta: true, vazio: 'Nenhuma varredura registrada. Use a extensão na tela "Intimações recebidas" do ADVBOX.', classeLinha: v => v.completa ? null : 'linha-alerta' }));
  }

  // ---------------------------------------------------------------- conferência manual
  let dlg = null;
  async function conferir(linha) {
    if (!dlg) { dlg = h('dialog', { class: 'detalhe', 'aria-labelledby': 'dc-det-titulo' }); document.body.append(dlg); }
    dlg.textContent = '';
    const corpo = h('div', { class: 'detalhe-corpo' }, h('p', { class: 'sutil' }, 'Carregando…'));
    dlg.append(h('div', { class: 'detalhe-topo' }, h('h2', { id: 'dc-det-titulo' }, 'Conferir publicação ' + (linha.cnj || '#' + linha.publicacao_id)),
      h('button', { type: 'button', class: 'btn btn-sec btn-peq', onclick: () => dlg.close() }, 'Fechar')), corpo);
    dlg.showModal();
    const [{ data: det }, { data: cands, error }] = await Promise.all([
      ctx.sb.rpc('pub_detalhe', { p_id: linha.publicacao_id }), ctx.sb.rpc('double_check_candidatas', { p_publicacao: linha.publicacao_id })]);
    corpo.textContent = '';
    if (error) { corpo.append(aviso('erro', error.message)); return; }
    const nota = h('textarea', { id: 'dc-nota', rows: 3, class: 'pub-texto', placeholder: 'O que foi conferido e onde (obrigatório, mínimo 10 caracteres).', 'aria-label': 'Nota da conferência' });
    const saida = h('div', { class: 'pub-resultado' });
    const registrar = async (situacao, post) => {
      saida.textContent = '';
      const { error: e } = await ctx.sb.rpc('double_check_manual', { p_publicacao: linha.publicacao_id, p_situacao: situacao, p_post_id: post || null, p_nota: nota.value });
      if (e) { saida.append(aviso('erro', e.message)); return; }
      dlg.close(); await atualizar();
    };
    const ev = linha.evidencia_conferencia || {};
    corpo.append(
      h('dl', { class: 'resumo' },
        h('div', {}, h('dt', {}, 'Situação atual'), h('dd', {}, SIT[linha.situacao_conferencia || 'aguardando'])),
        h('div', {}, h('dt', {}, 'Disponibilização / publicação'), h('dd', {}, `${data(linha.data_disponibilizacao)} / ${data(linha.data_publicacao)}`)),
        h('div', {}, h('dt', {}, 'Motivo'), h('dd', {}, ev.motivo || ev.regra || '—'))),
      h('h3', {}, 'Teor recebido da Webjur'), h('div', { class: 'pub-teor', tabindex: '0' }, det && det.publicacao ? det.publicacao.teor : '—'),
      h('h3', {}, `Intimações do ADVBOX com o mesmo CNJ (${num(cands.length)})`),
      cands.length ? h('div', { class: 'dc-candidatas' }, cands.map(c => h('div', { class: 'dc-candidata' },
        h('p', {}, h('b', {}, `Intimação ${c.post_id}`), ` · publicação ${data(c.data_publicacao)} · ${c.lawsuit_id ? 'processo vinculado' : 'SEM processo vinculado'} · semelhança ${Number(c.semelhanca).toLocaleString('pt-BR', { maximumFractionDigits: 2 })} · `, linkAdvbox(c.post_id)),
        h('div', { class: 'pub-teor', tabindex: '0' }, c.teor || '(teor não lido)'),
        h('button', { type: 'button', class: 'btn btn-sec btn-peq', onclick: () => registrar(c.lawsuit_id ? 'encontrada_advbox' : 'processo_nao_cadastrado', c.post_id) },
          c.lawsuit_id ? 'É esta publicação' : 'É esta (processo não cadastrado)')))) :
        h('p', { class: 'sutil' }, 'Nenhuma intimação deste processo nas varreduras registradas.'),
      h('h3', {}, 'Registrar a conferência'), nota,
      h('div', { class: 'acoes' },
        h('button', { type: 'button', class: 'btn', onclick: () => registrar('nao_encontrada_advbox') }, 'Confirmar: não está no ADVBOX'),
        h('button', { type: 'button', class: 'btn btn-sec', onclick: () => registrar('processo_nao_cadastrado') }, 'Processo não cadastrado no ADVBOX'),
        h('button', { type: 'button', class: 'btn btn-sec', onclick: () => registrar('conferencia_manual') }, 'Registrar só a nota (conferência manual)')),
      saida);
  }

  window.DoubleCheck = { abrir };
})();
