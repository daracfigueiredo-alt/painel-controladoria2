/* Área 9 — Tarefas de análise pendentes (Etapa 8). Exclusiva do administrador.
 * O double check prepara uma tarefa por publicação ausente no ADVBOX. Aqui a controladoria
 * aprova (ou rejeita); a extensão, aberta no ADVBOX, cria as aprovadas sozinha, uma a uma.
 * Toda mudança de situação passa pelas funções do banco (analise_*), que guardam o histórico. */
(function () {
  'use strict';
  const { h, data, dataHora, num, tabela, aviso } = UI;
  const ST = { preparada: 'Preparada — aguarda aprovação', aprovada: 'Aprovada — aguarda a criação', rejeitada: 'Rejeitada',
    conferencia_manual: 'Conferência manual', ja_tratada: 'Já tratada', criacao_em_andamento: 'Criação em andamento',
    verificar_no_advbox: 'Verificar se foi criada', criada: 'Criada' };
  const BLOQ = {
    processo_nao_encontrado: 'Processo não encontrado no ADVBOX. Cadastre o processo e libere a nova tentativa.',
    processo_ambiguo: 'Há mais de um cadastro no ADVBOX para este CNJ. Escolha qual recebe a tarefa.',
    processo_divergente: 'O processo indicado não apareceu na busca do ADVBOX. Escolha entre os encontrados.',
    tipo_nao_encontrado: 'O tipo "ANÁLISE DO CASO (50 pts)" não apareceu na lista de tarefas do ADVBOX.',
    responsavel_divergente: 'O responsável do formulário não era o esperado.',
    formulario_divergente: 'O formulário preenchido não conferiu antes do envio; nada foi enviado.',
    formulario_indisponivel: 'O formulário "Nova tarefa" do ADVBOX não abriu.'
  };
  const linkTarefa = id => /^\d{1,15}$/.test(id || '') ? h('a', { href: `https://app.advbox.com.br/0?t=${id}`, target: '_blank', rel: 'noopener noreferrer', class: 'nowrap' }, id) : '—';
  // 0035: tarefas de análise criadas no Atlas pela API (link para a tarefa no Atlas)
  const linkCriada = x => x.atlas_tarefa_id
    ? h('a', { href: /^https:\/\/gestor\.atlasjus\.com\//.test(x.atlas_app_url || '') ? x.atlas_app_url : 'https://gestor.atlasjus.com/#/tasks?task=' + x.atlas_tarefa_id, target: '_blank', rel: 'noopener noreferrer', class: 'nowrap' }, 'Atlas')
    : linkTarefa(x.advbox_tarefa_id);
  let destino = 'advbox';
  let ctx, raiz;
  const marcadas = new Set();

  async function abrir(container, contexto) {
    ctx = contexto; raiz = container;
    raiz.append(
      h('h1', {}, 'Tarefas de análise pendentes'),
      h('p', { class: 'sutil' }, 'Uma tarefa por publicação que o double check não encontrou. Responsável Mayra, ',
        'data = data da conferência, prazo fatal = 1 dia útil depois. Desde 11/11/2026 as aprovadas são criadas no Atlas Gestor pela API ',
        '(botão "Criar no Atlas"). Com o destino ADVBOX, a extensão cria na aba do ADVBOX aberta.'),
      aviso('alerta', 'Ao criar "ANÁLISE DO CASO", o ADVBOX move o processo para a etapa NEGOCIAÇÃO / ANÁLISE DO CASO (decisão de 10/11/2026). ',
        'Processo não cadastrado: cadastre-o no ADVBOX antes; sem cadastro a extensão não envia nada e a tarefa fica bloqueada aqui.'),
      h('section', { class: 'cartao', id: 'an-lista' }),
      h('section', { class: 'cartao', id: 'an-teste' }));
    desenharTeste();
    await listar();
  }

  function desenharTeste() {
    const el = raiz.querySelector('#an-teste'), saida = h('div');
    const busca = h('input', { type: 'text', id: 'an-teste-busca', value: 'TESTE 1.0', 'aria-label': 'Caso de teste do ADVBOX' });
    el.append(h('h2', {}, 'Homologação: tarefa de teste'),
      h('p', { class: 'sutil' }, 'Prepara uma tarefa de análise sem publicação, no caso de teste indicado (o nome precisa conter "TESTE"). Aprove-a na lista acima para a extensão criá-la.'),
      h('div', { class: 'filtros-barra' }, h('label', { class: 'filtro' }, h('span', {}, 'Caso do ADVBOX'), busca),
        h('div', { class: 'acoes' }, h('button', { type: 'button', class: 'btn btn-sec', id: 'an-teste-preparar', onclick: async () => {
          saida.textContent = '';
          const { error } = await ctx.sb.rpc('analise_preparar_teste', { p_busca: busca.value, p_observacoes: null });
          if (error) { saida.append(aviso('erro', error.message)); return; }
          await listar();
        } }, 'Preparar tarefa de teste'))), saida);
  }

  const processo = x => x.teste ? h('span', {}, h('b', {}, 'TESTE'), ' — ', x.busca_advbox) : h('span', { class: 'nowrap' }, x.cnj || 'sem CNJ');
  function situacao(x) {
    const partes = [h('div', {}, ST[x.status] || x.status)];
    if (x.bloqueio_criacao) partes.push(h('div', { class: 'texto-alerta' }, 'Bloqueada: ' + (BLOQ[x.bloqueio_criacao] || x.bloqueio_criacao)));
    if (x.requer_cadastro) partes.push(h('div', { class: 'sutil' }, x.cadastro_confirmado_em
      ? `Cadastro no ADVBOX confirmado pela extensão em ${dataHora(x.cadastro_confirmado_em)}`
      : ['criada', 'rejeitada', 'ja_tratada'].includes(x.status) ? 'Processo não estava no ADVBOX na conferência'
      : 'Processo não estava no ADVBOX na conferência. Se já foi cadastrado, a extensão confirma ao criar a tarefa.'));
    return h('div', {}, partes);
  }

  async function listar() {
    const el = raiz.querySelector('#an-lista');
    const { data: d, error } = await ctx.sb.rpc('analise_listar', { p_status: null });
    el.textContent = '';
    el.append(h('div', { class: 'acoes' }, h('h2', {}, 'Tarefas'),
      h('button', { type: 'button', class: 'btn btn-sec btn-peq', id: 'an-atualizar', onclick: listar }, 'Atualizar')));
    if (error) { el.append(aviso('erro', error.message)); return; }
    const cont = {}; d.forEach(x => { cont[x.status] = (cont[x.status] || 0) + 1; });
    if (d.length) destino = d[0].destino || destino;
    const aprovadas = d.filter(x => x.status === 'aprovada' && !x.bloqueio_criacao);
    const saida = h('div', { id: 'an-saida' });
    const prep = d.filter(x => ['preparada', 'conferencia_manual'].includes(x.status));
    [...marcadas].forEach(id => { if (!prep.some(x => x.id === id)) marcadas.delete(id); });
    el.append(h('p', { class: 'sutil', id: 'an-contagem' }, Object.entries(cont).map(([k, n]) => `${ST[k] || k}: ${num(n)}`).join(' · ') || 'Nenhuma tarefa de análise.',
        ' Criadas, rejeitadas e já tratadas aparecem por 7 dias.'),
      prep.length ? h('div', { class: 'acoes' },
        h('button', { type: 'button', class: 'btn', id: 'an-aprovar-marcadas', onclick: () => aprovarMarcadas(saida) }, 'Aprovar as marcadas'),
        h('button', { type: 'button', class: 'btn btn-sec', onclick: () => { prep.forEach(x => marcadas.add(x.id)); listar(); } }, 'Marcar todas as preparadas')) : '',
      destino === 'atlas' && aprovadas.length ? h('div', { class: 'acoes' },
        h('button', { type: 'button', class: 'btn', id: 'an-criar-atlas', onclick: () => criarNoAtlas(aprovadas.map(x => x.id)) }, `Criar no Atlas as ${num(aprovadas.length)} aprovada(s)`)) : '',
      saida,
      tabela([
        { titulo: '', valor: x => ['preparada', 'conferencia_manual'].includes(x.status)
            ? h('input', { type: 'checkbox', 'aria-label': 'Marcar tarefa ' + x.id, checked: marcadas.has(x.id), onchange: e => e.target.checked ? marcadas.add(x.id) : marcadas.delete(x.id) }) : '' },
        { titulo: '#', num: true, valor: x => x.id },
        { titulo: 'Situação', valor: situacao },
        { titulo: 'Processo', valor: processo },
        { titulo: 'Tribunal / órgão', valor: x => [x.tribunal, x.orgao_julgador].filter(Boolean).join(' — ') || '—' },
        { titulo: 'Disponibilização', valor: x => data(x.data_disponibilizacao) },
        { titulo: 'Data / prazo fatal', valor: x => `${data(x.data_prevista)} / ${data(x.pf_previsto)}` },
        { titulo: 'Tarefa criada', valor: linkCriada },
        { titulo: '', valor: x => h('button', { type: 'button', class: 'btn btn-sec btn-peq an-abrir', onclick: () => detalhe(x) }, acaoPrincipal(x)) }
      ], d, { vazio: 'Nenhuma tarefa de análise.', classeLinha: x => x.bloqueio_criacao || x.status === 'verificar_no_advbox' ? 'linha-alerta' : null }));
  }
  const acaoPrincipal = x => ({ preparada: 'Revisar', conferencia_manual: 'Revisar', verificar_no_advbox: 'Conferir', criacao_em_andamento: 'Ver' })[x.status]
    || (x.bloqueio_criacao ? 'Resolver' : 'Ver');

  async function criarNoAtlas(ids) {
    const bt = raiz.querySelector('#an-criar-atlas'); if (bt) { bt.disabled = true; bt.textContent = 'Criando no Atlas…'; }
    let ok = 0; const erros = [];
    for (const id of ids) {     // uma de cada vez: o banco trava cada uma (criacao_em_andamento) e o Atlas recebe a chave de idempotência
      const { data: r, error } = await ctx.sb.functions.invoke('atlas-sync', { body: { acao: 'criar_tarefa', id } });
      if (error) {
        let msg = error.message; try { msg = (await error.context.json()).erro || msg; } catch (e) { /* sem corpo */ }
        erros.push(`#${id}: ${msg}`);
      } else if (r && r.status === 'criada') ok++;
    }
    await listar();
    raiz.querySelector('#an-saida').append(aviso(erros.length ? 'alerta' : 'ok', `${num(ok)} tarefa(s) criada(s) no Atlas.`, erros.length ? ' ' + erros.join(' · ') : ''));
  }

  async function aprovarMarcadas(saida) {
    saida.textContent = '';
    const ids = [...marcadas]; let ok = 0; const erros = [];
    for (const id of ids) {
      const { error } = await ctx.sb.rpc('analise_decidir', { p_id: id, p_acao: 'aprovar', p_nota: 'Aprovada no painel' });
      if (error) erros.push(`#${id}: ${error.message}`); else { ok++; marcadas.delete(id); }
    }
    await listar();
    raiz.querySelector('#an-saida').append(aviso(erros.length ? 'alerta' : 'info', `${num(ok)} aprovada(s).`, erros.length ? ' ' + erros.join(' · ') : ''));
  }

  // ---------------------------------------------------------------- detalhe e ações
  let dlg = null;
  async function detalhe(x) {
    if (!dlg) { dlg = h('dialog', { class: 'detalhe', 'aria-labelledby': 'an-det-titulo' }); document.body.append(dlg); }
    dlg.textContent = '';
    const corpo = h('div', { class: 'detalhe-corpo' }, h('p', { class: 'sutil' }, 'Carregando…'));
    dlg.append(h('div', { class: 'detalhe-topo' }, h('div', {}, h('h2', { id: 'an-det-titulo' }, `Tarefa de análise #${x.id}`), h('p', { class: 'sutil' }, ST[x.status] || x.status)),
      h('button', { type: 'button', class: 'btn btn-sec btn-peq', onclick: () => dlg.close() }, 'Fechar')), corpo);
    dlg.showModal();
    const { data: d, error } = await ctx.sb.rpc('analise_detalhe', { p_id: x.id });
    corpo.textContent = '';
    if (error) { corpo.append(aviso('erro', error.message)); return; }
    const t = d.tarefa, saida = h('div', { class: 'pub-resultado' });
    const nota = h('textarea', { id: 'an-nota', rows: 2, class: 'pub-texto', placeholder: 'Nota (obrigatória para rejeitar, já tratada e para resolver bloqueios).', 'aria-label': 'Nota' });
    const chamar = async (fn, args) => {
      saida.textContent = '';
      const { error: e } = await ctx.sb.rpc(fn, args);
      if (e) { saida.append(aviso('erro', e.message)); return; }
      dlg.close(); await listar();
    };
    const decidir = acao => chamar('analise_decidir', { p_id: t.id, p_acao: acao, p_nota: nota.value || null });
    const acoes = h('div', { class: 'acoes' });
    if (['preparada', 'conferencia_manual'].includes(t.status)) acoes.append(
      h('button', { type: 'button', class: 'btn', id: 'an-aprovar', onclick: () => decidir('aprovar') }, 'Aprovar'),
      h('button', { type: 'button', class: 'btn btn-sec', onclick: () => decidir('rejeitar') }, 'Rejeitar'),
      h('button', { type: 'button', class: 'btn btn-sec', onclick: () => decidir('ja_tratada') }, 'Já tratada'),
      t.status === 'preparada' ? h('button', { type: 'button', class: 'btn btn-sec', onclick: () => decidir('conferencia_manual') }, 'Conferência manual') : '');
    if (t.status === 'aprovada' && !t.bloqueio_criacao && destino === 'atlas') acoes.append(
      h('button', { type: 'button', class: 'btn', id: 'an-criar-uma', onclick: async () => { dlg.close(); await criarNoAtlas([t.id]); } }, 'Criar no Atlas'));
    if (t.status === 'aprovada') {
      if (t.bloqueio_criacao) {
        const ops = (t.bloqueio_detalhe && t.bloqueio_detalhe.opcoes) || [];
        const esc = ops.length ? h('select', { id: 'an-processo', 'aria-label': 'Processo do ADVBOX' }, h('option', { value: '' }, '— escolha o processo do ADVBOX —'),
          ops.map(o => h('option', { value: o.lawsuit_id }, `${o.texto} (processo ${o.lawsuit_id})`))) : null;
        acoes.append(esc || '', h('button', { type: 'button', class: 'btn', id: 'an-liberar', onclick: () => chamar('analise_desbloquear', { p_id: t.id, p_advbox_lawsuit_id: esc ? esc.value || null : null, p_nota: nota.value }) },
          t.bloqueio_criacao === 'processo_nao_encontrado' ? 'Processo cadastrado: tentar de novo' : 'Resolvido: tentar de novo'));
      }
      acoes.append(h('button', { type: 'button', class: 'btn btn-sec', onclick: () => decidir('rejeitar') }, 'Rejeitar'));
    }
    if (t.status === 'verificar_no_advbox') {
      const idAdv = h('input', { type: 'text', inputmode: 'numeric', id: 'an-id-advbox', placeholder: 'ID da tarefa no ADVBOX', 'aria-label': 'ID da tarefa no ADVBOX' });
      acoes.append(idAdv,
        h('button', { type: 'button', class: 'btn', onclick: () => chamar('analise_confirmar_criacao', { p_id: t.id, p_advbox_tarefa_id: idAdv.value.trim(), p_evidencia: { origem: 'painel', nota: nota.value } }) }, 'Foi criada: registrar o ID'),
        h('button', { type: 'button', class: 'btn btn-sec', onclick: () => chamar('analise_confirmar_nao_criada', { p_id: t.id, p_nota: nota.value }) }, 'Não foi criada: liberar nova tentativa'));
    }
    corpo.append(
      h('dl', { class: 'resumo' },
        h('div', {}, h('dt', {}, 'Processo'), h('dd', {}, t.teste ? 'TESTE — ' + t.busca_advbox : (t.cnj || '—'))),
        h('div', {}, h('dt', {}, 'Tipo'), h('dd', {}, t.tipo)), h('div', {}, h('dt', {}, 'Responsável'), h('dd', {}, t.responsavel)),
        h('div', {}, h('dt', {}, 'Data / prazo fatal'), h('dd', {}, `${data(t.data_prevista)} / ${data(t.pf_previsto)}`)),
        h('div', {}, h('dt', {}, 'Tarefa criada'), h('dd', {}, linkCriada(t))),
        h('div', {}, h('dt', {}, 'Tentativas de criação'), h('dd', {}, num(t.tentativas)))),
      t.bloqueio_criacao ? aviso('alerta', 'Bloqueada: ' + (BLOQ[t.bloqueio_criacao] || t.bloqueio_criacao)) : '',
      t.status === 'verificar_no_advbox' ? aviso('alerta', 'A extensão enviou o formulário mas não confirmou a criação. Procure a tarefa no ADVBOX (processo, tipo "ANÁLISE DO CASO", hoje) antes de decidir.') : '',
      acoes.childNodes.length ? h('div', {}, h('h3', {}, 'Decisão'), nota, acoes, saida) : '',
      h('h3', {}, 'Descrição que vai para o ADVBOX'), h('div', { class: 'pub-teor', tabindex: '0' }, t.observacoes),
      h('h3', {}, 'Histórico'), tabela([
        { titulo: 'Quando', valor: r => dataHora(r.em) }, { titulo: 'De', valor: r => ST[r.de] || r.de || '—' }, { titulo: 'Para', valor: r => ST[r.para] || r.para },
        { titulo: 'Nota', larga: true, valor: r => r.nota || '—' }
      ], d.historico || [], { compacta: true }));
  }

  window.Analise = { abrir };
})();
