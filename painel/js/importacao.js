/* Área 6 — Importação Excel (Prompt Mestre §6). Exclusiva do administrador.
 * O arquivo é lido no navegador; o banco valida tudo de novo (importar_arquivo) e
 * decide o que entra. Sem exclusão de importações, sem exportação CSV, sem edição manual. */
(function () {
  'use strict';
  const { h, dataHora, data, num, tabela, aviso } = UI;
  const CABECALHO = ['Prioridade','Data','Hora','Término','Hora Término','Prazo fatal','Data Conclusão','Pontuação',
    'Compromisso','Local','Remetente','Destinatário','Partes','Processo (CNJ)','Protocolo','Tipo de ação','Observações'];
  const CORTES = [25, 50, 100, 200, 500, 1000];
  const CATEGORIAS = {
    nova: 'Importada (nova)', atualizada: 'Atualizada (já conhecida)', ignorada_repetida: 'Ignorada (repetida no lote)',
    rejeitada: 'Rejeitada', sem_vinculo_seguro: 'Sem vínculo seguro'
  };
  let ctx, raiz, selecionados = [];

  // ADVBOX (histórico): importação do Excel exportado do ADVBOX
  async function abrir(container, contexto) {
    ctx = contexto; raiz = container; selecionados = [];
    raiz.append(
      h('h1', {}, 'Importação do Excel'),
      h('p', { class: 'subtitulo' }, 'ADVBOX (histórico)'),
      h('p', { class: 'sutil' }, 'Desde 11/11/2026 as tarefas vêm do Atlas Gestor (menu Atlas Gestor › Sincronização com o Atlas). ',
        'A importação do Excel do ADVBOX continua disponível para o histórico.'),
      h('section', { class: 'cartao', id: 'imp-base' }, h('p', { class: 'sutil' }, 'Carregando a base atual…')),
      h('section', { class: 'cartao', id: 'imp-nova' }),
      h('section', { id: 'imp-resultados' }),
      h('section', { class: 'cartao', id: 'imp-historico' }, h('h2', {}, 'Histórico de importações'), h('p', { class: 'sutil' }, 'Carregando…')),
      h('section', { class: 'cartao', id: 'imp-detalhe', hidden: true })
    );
    await Promise.all([desenharBase(), desenharHistorico()]);
    desenharFormulario();
  }

  // Atlas Gestor: sincronização pela API (Edge Function atlas-sync) e descrição padrão
  async function atlas(container, contexto) {
    ctx = contexto; raiz = container; selecionados = [];
    raiz.append(
      h('h1', {}, 'Sincronização com o Atlas'),
      h('p', { class: 'subtitulo' }, 'Atlas Gestor'),
      h('section', { class: 'cartao', id: 'imp-atlas' }),
      h('section', { class: 'cartao', id: 'imp-base' }, h('p', { class: 'sutil' }, 'Carregando a base atual…')),
      h('section', { class: 'cartao', id: 'imp-historico' }, h('h2', {}, 'Histórico de importações'), h('p', { class: 'sutil' }, 'Carregando…')),
      h('section', { class: 'cartao', id: 'imp-detalhe', hidden: true })
    );
    desenharAtlas();
    await Promise.all([desenharBase(), desenharHistorico()]);
  }

  // ------------------------------------------------------------ Atlas (Edge Function atlas-sync; a chave da API fica só no servidor)
  async function chamarAtlas(corpo) {
    const { data: d, error } = await ctx.sb.functions.invoke('atlas-sync', { body: corpo });
    if (error) {
      let msg = error.message;
      try { const j = await error.context.json(); msg = j.erro || msg; } catch (e) { /* sem corpo */ }
      throw new Error(msg);
    }
    return d;
  }
  function desenharAtlas() {
    const el = raiz.querySelector('#imp-atlas'); el.textContent = '';
    const saida = h('div', { id: 'atlas-saida', 'aria-live': 'polite' });
    const btTestar = h('button', { type: 'button', class: 'btn btn-sec', onclick: () => executar(btTestar, 'testar') }, 'Testar conexão');
    const btSinc = h('button', { type: 'button', class: 'btn', onclick: () => executar(btSinc, 'sincronizar') }, 'Sincronizar com o Atlas');
    const btPad = h('button', { type: 'button', class: 'btn btn-sec', onclick: () => executar(btPad, 'padronizar_descricoes') }, 'Padronizar descrições no Atlas');
    el.append(h('h2', {}, 'Sincronizar tarefas'),
      h('p', { class: 'sutil' }, 'Lê todas as tarefas abertas e as concluídas recentemente no Atlas e grava uma nova fotografia da base. ',
        'Cada tarefa é identificada pelo ID do Atlas. Mudanças de data, responsável e prazo fatal entre uma sincronização e outra viram eventos.'),
      h('div', { class: 'acoes' }, btTestar, btSinc), saida,
      h('h3', {}, 'Descrição padrão das tarefas (modalidades ativas)'),
      h('p', { class: 'sutil' }, 'Grava no Atlas, na descrição de cada tarefa pendente de modalidade ativa, o bloco da controladoria (prazos, orientações, ',
        'checklist e links). O texto original do Atlas é preservado. Até 40 tarefas por vez (limite da API). Exige a permissão "Editar Tarefas" na chave.'),
      h('div', { class: 'acoes' }, btPad));
    async function executar(bt, acao) {
      saida.textContent = ''; bt.disabled = true; const rot = bt.textContent; bt.textContent = acao === 'testar' ? 'Testando…' : acao === 'padronizar_descricoes' ? 'Gravando…' : 'Sincronizando…';
      try {
        const r = await chamarAtlas({ acao });
        if (acao === 'testar') {
          const perms = Object.entries(r.permissoes || {}).filter(([, v]) => v).map(([k]) => k);
          saida.append(aviso('ok', `Conectado ao Atlas: ${r.escritorio} (plano ${r.plano}). Chave "${r.chave}", acesso ${r.acesso === 'full' ? 'completo' : 'somente leitura'}.`),
            h('p', { class: 'sutil' }, 'Permissões ligadas: ' + (perms.join(', ') || 'nenhuma')));
        } else if (acao === 'padronizar_descricoes') {
          saida.append(aviso('ok', `Descrições: ${num(r.gravadas)} gravada(s), ${num(r.puladas)} pulada(s) (descrição longa demais para a API), ${num(r.erros)} erro(s).`));
        } else {
          saida.append(aviso('ok', `Sincronização concluída em ${r.segundos} s: ${num(r.tarefas)} tarefas (${num(r.abertas)} abertas, ${num(r.concluidas_recentes)} concluídas recentes). ` +
            `${num(r.novas)} novas, ${num(r.ja_conhecidas)} já conhecidas, ${num(r.rejeitadas)} rejeitadas. Lote #${r.lote_id}.`));
          await Promise.all([desenharBase(), desenharHistorico()]);
        }
      } catch (e) {
        saida.append(aviso('erro', 'Atlas: ' + e.message));
      } finally { bt.disabled = false; bt.textContent = rot; }
    }
  }

  let loteAtual = null;
  async function desenharBase() {
    const el = raiz.querySelector('#imp-base');
    const [{ data: lote, error }, { data: par }] = await Promise.all([
      ctx.sb.from('v_lote_atual').select('*').maybeSingle(),
      ctx.sb.from('parametros').select('valor').eq('chave', 'periodicidade_importacao_horas').maybeSingle()
    ]);
    loteAtual = lote || null;
    el.textContent = '';
    el.append(h('h2', {}, 'Base atual'));
    if (error) { el.append(aviso('erro', 'Não foi possível consultar a base: ' + error.message)); return; }
    if (!lote) { el.append(aviso('info', 'Nenhuma importação concluída ainda. A primeira importação cria a base.')); return; }
    const horas = (Date.now() - new Date(lote.ultima_importacao_em)) / 36e5;
    const limite = par ? Number(par.valor) : 24;
    el.append(h('dl', { class: 'resumo' },
      item('Lote', '#' + lote.lote_id), item('Data da exportação', lote.data_exportacao ? data(lote.data_exportacao) : 'não informada'),
      item('Última importação', dataHora(lote.ultima_importacao_em)), item('Arquivos no lote', num(lote.arquivos)),
      item('Linhas válidas', num(lote.linhas_validas))));
    if (horas > limite) el.append(aviso('alerta', `A base está desatualizada: última importação há ${Math.floor(horas)} horas (periodicidade definida: ${limite} h).`));
  }
  const item = (k, v) => h('div', {}, h('dt', {}, k), h('dd', {}, v));

  function desenharFormulario() {
    const el = raiz.querySelector('#imp-nova'); el.textContent = '';
    const temLote = !!loteAtual;
    el.append(
      h('h2', {}, 'Nova importação'),
      h('fieldset', { class: 'modo' }, h('legend', {}, 'Como os arquivos entram na base'),
        h('label', { class: 'opcao' }, h('input', { type: 'radio', name: 'modo', value: 'novo', checked: true, onchange: desenharPrevia }),
          h('span', {}, h('b', {}, 'Nova fotografia da base'), ' — exportação diária de pendentes. O 1º arquivo cria um lote novo; os demais selecionados juntos entram no mesmo lote.')),
        h('label', { class: 'opcao' + (temLote ? '' : ' desabilitada') }, h('input', { type: 'radio', name: 'modo', value: 'complementar', disabled: !temLote, onchange: desenharPrevia }),
          h('span', {}, h('b', {}, 'Complementar a base atual' + (temLote ? ` (lote #${loteAtual.lote_id})` : '')), ' — por exemplo, a exportação de concluídas do mesmo dia.'))),
      h('label', { class: 'arquivo' }, h('span', {}, 'Arquivos .xlsx'),
        h('input', { type: 'file', id: 'imp-arquivos', accept: '.xlsx,application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', multiple: true, onchange: aoSelecionar })),
      h('div', { id: 'imp-previa' })
    );
  }
  const modo = () => (raiz.querySelector('input[name=modo]:checked') || {}).value || 'novo';

  async function aoSelecionar(ev) {
    selecionados = [];
    const prev = raiz.querySelector('#imp-previa'); prev.textContent = ''; prev.append(h('p', { class: 'sutil' }, 'Lendo arquivos…'));
    for (const f of ev.target.files) {
      const s = { nome: f.name, tamanho: f.size };
      try {
        const bytes = new Uint8Array(await f.arrayBuffer());
        const p = OCPlanilha.lerPlanilha(bytes);
        s.hash = await OCPlanilha.sha256Hex(bytes);
        s.linhas = p.linhas; s.avisos = [...p.avisos]; s.aba = p.aba;
        s.faltando = CABECALHO.filter(c => !p.cabecalho.includes(c));
        s.extras = p.cabecalho.filter(c => !CABECALHO.includes(c));
        s.concluidas = p.linhas.filter(l => (l['Data Conclusão'] || '').trim()).length;
        const vistos = new Set(); s.repetidas = 0;
        for (const l of p.linhas) { const k = JSON.stringify(l); if (vistos.has(k)) s.repetidas++; vistos.add(k); }
        s.dataExportacao = OCPlanilha.dataExportacaoDoNome(f.name);
        if (CORTES.includes(p.linhas.length)) s.avisos.push(`Exatamente ${p.linhas.length} linhas: confira se a lista do ADVBOX não estava limitada (itens por página) na exportação.`);
        if (s.extras.length) s.avisos.push('Colunas não usadas pelo sistema: ' + s.extras.join(', ') + '.');
        s.bloqueio = s.faltando.length ? 'Colunas obrigatórias ausentes: ' + s.faltando.join(', ') + '.'
                   : p.linhas.length === 0 ? 'Arquivo sem linhas de dados.'
                   : p.linhas.length > 1000 ? `Arquivo com ${num(p.linhas.length)} linhas; o limite é 1.000 por arquivo.` : null;
      } catch (e) {
        s.bloqueio = e instanceof OCPlanilha.ErroPlanilha ? e.message : 'Não foi possível ler o arquivo: ' + e.message;
      }
      selecionados.push(s);
    }
    desenharPrevia();
  }

  function desenharPrevia() {
    const prev = raiz.querySelector('#imp-previa'); if (!prev) return;
    prev.textContent = '';
    if (!selecionados.length) return;
    const validos = selecionados.filter(s => !s.bloqueio);
    prev.append(h('h3', {}, 'Conferência antes de importar'),
      tabela([
        { titulo: 'Ordem', valor: s => String(selecionados.indexOf(s) + 1), num: true },
        { titulo: 'Arquivo', valor: s => s.nome, larga: true },
        { titulo: 'Linhas', valor: s => s.linhas ? num(s.linhas.length) : '—', num: true },
        { titulo: 'Concluídas', valor: s => s.linhas ? num(s.concluidas) : '—', num: true },
        { titulo: 'Repetidas no arquivo', valor: s => s.linhas ? num(s.repetidas) : '—', num: true },
        { titulo: 'Exportado em', valor: s => s.dataExportacao ? data(s.dataExportacao) : 'não identificado' },
        { titulo: 'Destino', valor: s => s.bloqueio ? 'não será importado' : destino(validos.indexOf(s)) },
        { titulo: 'Situação', valor: s => s.bloqueio ? h('span', { class: 'nota nota-erro' }, s.bloqueio)
            : s.avisos.length ? h('span', { class: 'nota nota-alerta' }, s.avisos.join(' ')) : h('span', { class: 'tag tag-ok' }, 'Pronto') }
      ], selecionados));
    if (modo() === 'novo' && validos.length && validos.every(s => s.concluidas === s.linhas.length) && loteAtual)
      prev.append(aviso('alerta', 'Todos os arquivos válidos contêm só tarefas concluídas. Como nova fotografia, eles substituiriam a base atual. Normalmente o correto é "Complementar a base atual".'));
    prev.append(h('div', { class: 'acoes' },
      h('button', { type: 'button', class: 'btn', id: 'imp-confirmar', disabled: !validos.length, onclick: importar },
        `Importar ${validos.length} arquivo(s)`)));
  }
  function destino(i) {
    if (modo() === 'complementar') return `lote atual #${loteAtual.lote_id}`;
    return i === 0 ? 'cria lote novo' : 'mesmo lote do 1º arquivo';
  }

  async function importar() {
    raiz.dataset.ocupado = '1';
    try { await importarArquivos(); }
    catch (e) { raiz.querySelector('#imp-resultados').append(aviso('erro', 'Falha inesperada na importação: ' + e.message)); }
    finally {
      await Promise.all([desenharBase(), desenharHistorico()]).catch(() => {});
      desenharFormulario();
      delete raiz.dataset.ocupado;
    }
  }

  async function importarArquivos() {
    const btn = raiz.querySelector('#imp-confirmar'); btn.disabled = true; btn.textContent = 'Importando…';
    raiz.querySelector('#imp-arquivos').disabled = true;
    const res = raiz.querySelector('#imp-resultados'); res.textContent = '';
    let lote = modo() === 'complementar' ? loteAtual.lote_id : null;
    for (const s of selecionados.filter(x => !x.bloqueio)) {
      const card = h('div', { class: 'cartao resultado' }, h('h3', {}, s.nome), h('p', { class: 'sutil' }, 'Enviando…'));
      res.append(card);
      let r = await chamar(s, lote, false);
      if (r.ok && r.dados.status === 'requer_confirmacao') {
        card.querySelector('.sutil').textContent = 'Aguardando a sua decisão:';
        const escolha = await perguntar(card, r.dados.mensagem, loteAtual);
        if (escolha === 'cancelar') { preencher(card, s, { ok: true, dados: { status: 'cancelado' } }); continue; }
        r = escolha === 'complementar' ? await chamar(s, loteAtual.lote_id, false) : await chamar(s, null, true);
      }
      preencher(card, s, r);
      if (r.ok && r.dados.status === 'concluida' && lote === null) lote = r.dados.lote_id;
    }
  }

  async function chamar(s, lote, confirmar) {
    const { data: d, error } = await ctx.sb.rpc('importar_arquivo', {
      p_nome_arquivo: s.nome, p_hash_arquivo: s.hash, p_linhas: s.linhas, p_lote_id: lote,
      p_data_exportacao: s.dataExportacao, p_confirmar_lote_novo_so_concluidas: confirmar });
    return error ? { ok: false, erro: error.message } : { ok: true, dados: d };
  }

  function perguntar(card, mensagem, lote) {
    return new Promise(resolve => {
      const caixa = h('div', { class: 'pergunta', role: 'group', 'aria-label': 'Confirmação necessária' },
        aviso('alerta', mensagem),
        h('div', { class: 'acoes' },
          lote ? h('button', { type: 'button', class: 'btn', onclick: () => fim('complementar') }, `Importar no lote atual #${lote.lote_id}`) : null,
          h('button', { type: 'button', class: 'btn btn-sec', onclick: () => fim('novo') }, 'Criar lote novo mesmo assim'),
          h('button', { type: 'button', class: 'btn btn-sec', onclick: () => fim('cancelar') }, 'Não importar este arquivo')));
      card.append(caixa);
      function fim(v) { caixa.remove(); resolve(v); }
    });
  }

  function preencher(card, s, r) {
    const nome = card.querySelector('h3').textContent; card.textContent = ''; card.append(h('h3', {}, nome));
    if (!r.ok) { card.append(aviso('erro', 'O banco recusou a importação: ' + r.erro)); return; }
    const d = r.dados;
    if (d.status === 'cancelado') { card.append(aviso('info', 'Arquivo não importado (decisão do administrador).')); return; }
    if (d.status === 'ja_importado') { card.append(aviso('info', `Este arquivo já foi importado (importação #${d.importacao_id}). Nada foi alterado.`)); return; }
    if (d.status === 'rejeitada') { card.append(aviso('erro', 'Arquivo rejeitado. Colunas ausentes: ' + (d.colunas_ausentes || []).join(', ') + '.')); return; }
    card.append(h('p', {}, `Importação #${d.importacao_id} concluída no lote #${d.lote_id}.`),
      h('dl', { class: 'resumo resumo-num' },
        item('Linhas no arquivo', num(d.total_linhas)), item('Importadas (novas)', num(d.tarefas_novas)),
        item('Atualizadas (já conhecidas)', num(d.tarefas_ja_conhecidas)), item('Ignoradas (repetidas no lote)', num(d.duplicadas_no_lote)),
        item('Rejeitadas', num(d.rejeitadas)), item('Sem vínculo seguro', num(d.ambiguas_nao_vinculadas)),
        item('Unificadas pelo ID do ADVBOX', num(d.tarefas_unificadas_pelo_id_advbox)), item('Processos novos', num(d.processos_novos))));
    if (d.alerta_possivel_corte) card.append(aviso('alerta', `O arquivo tem exatamente ${d.total_linhas} linhas. Confira se a exportação não estava limitada.`));
    if (d.ambiguas_nao_vinculadas > 0) card.append(aviso('info', `${d.ambiguas_nao_vinculadas} linha(s) com texto idêntico a outras ficaram sem vínculo: o sistema prefere não associar a associar errado. A extensão resolve pelo ID real da tarefa.`));
    card.append(h('div', { class: 'acoes' }, h('button', { type: 'button', class: 'btn btn-sec', onclick: () => detalhar(d.importacao_id, nome) }, 'Ver linhas e erros')));
  }

  async function desenharHistorico() {
    const el = raiz.querySelector('#imp-historico');
    const { data: lista, error } = await ctx.sb.from('v_importacoes').select('*').order('id', { ascending: false }).limit(100);
    el.textContent = ''; el.append(h('h2', {}, 'Histórico de importações'));
    if (error) { el.append(aviso('erro', 'Não foi possível carregar o histórico: ' + error.message)); return; }
    el.append(tabela([
      { titulo: '#', valor: i => String(i.id), num: true },
      { titulo: 'Lote', valor: i => h('span', {}, '#' + i.lote_id, i.lote_atual ? h('span', { class: 'tag tag-ok' }, 'atual') : null) },
      { titulo: 'Arquivo', valor: i => i.nome_arquivo, larga: true },
      { titulo: 'Importado em', valor: i => dataHora(i.importado_em) },
      { titulo: 'Situação', valor: i => h('span', { class: 'tag ' + (i.status === 'concluida' ? 'tag-ok' : 'tag-erro') }, i.status === 'concluida' ? 'concluída' : i.status) },
      { titulo: 'Linhas', valor: i => num(i.total_linhas), num: true },
      { titulo: 'Novas', valor: i => num(i.tarefas_novas), num: true },
      { titulo: 'Atualizadas', valor: i => num(i.tarefas_vinculadas), num: true },
      { titulo: 'Ignoradas', valor: i => num(i.linhas_duplicadas), num: true },
      { titulo: 'Rejeitadas', valor: i => num(i.linhas_rejeitadas), num: true },
      { titulo: 'Com avisos', valor: i => num(i.linhas_com_avisos), num: true },
      { titulo: 'Alterações', valor: i => num(i.alteracoes_detectadas), num: true },
      { titulo: '', valor: i => h('button', { type: 'button', class: 'btn btn-sec btn-peq', onclick: () => detalhar(i.id, i.nome_arquivo) }, 'Detalhar') }
    ], lista || [], { vazio: 'Nenhuma importação ainda.' }));
  }

  async function detalhar(id, nome) {
    const el = raiz.querySelector('#imp-detalhe'); el.hidden = false; el.textContent = '';
    el.append(h('h2', {}, `Importação #${id} — ${nome}`), h('p', { class: 'sutil' }, 'Carregando linhas…'));
    el.scrollIntoView({ behavior: 'smooth', block: 'start' });
    const { data: linhas, error } = await ctx.sb.from('v_importacao_linhas')
      .select('numero_linha, categoria, compromisso, processo_cnj, responsavel, data_agenda, pf_tarefa, data_conclusao, erros, alteracoes_detectadas')
      .eq('importacao_id', id).order('numero_linha').limit(1000);
    el.lastChild.remove();
    if (error) { el.append(aviso('erro', error.message)); return; }
    const cont = {}; for (const l of linhas) cont[l.categoria] = (cont[l.categoria] || 0) + 1;
    const comApont = linhas.filter(l => l.erros && l.erros.length).length;
    let filtro = comApont ? 'apontamentos' : 'todas';
    const filtros = h('div', { class: 'filtros', role: 'group', 'aria-label': 'Filtrar linhas' });
    const corpo = h('div');
    const opcoes = [['todas', 'Todas', linhas.length], ['apontamentos', 'Com erros ou avisos', comApont],
      ...Object.keys(CATEGORIAS).map(k => [k, CATEGORIAS[k], cont[k] || 0])];
    function render() {
      filtros.textContent = '';
      for (const [k, rot, n] of opcoes) filtros.append(h('button', { type: 'button', class: 'chip' + (filtro === k ? ' ativo' : ''), 'aria-pressed': String(filtro === k), onclick: () => { filtro = k; render(); } }, `${rot} (${num(n)})`));
      const vis = linhas.filter(l => filtro === 'todas' || (filtro === 'apontamentos' ? l.erros && l.erros.length : l.categoria === filtro));
      corpo.textContent = '';
      corpo.append(tabela([
        { titulo: 'Linha', valor: l => String(l.numero_linha), num: true },
        { titulo: 'Categoria', valor: l => h('span', { class: 'tag ' + ({ rejeitada: 'tag-erro', sem_vinculo_seguro: 'tag-alerta' }[l.categoria] || 'tag-neutra') }, CATEGORIAS[l.categoria]) },
        { titulo: 'Compromisso', valor: l => l.compromisso || '—' },
        { titulo: 'Processo', valor: l => l.processo_cnj || '—' },
        { titulo: 'Responsável', valor: l => l.responsavel || '—' },
        { titulo: 'Data', valor: l => data(l.data_agenda) },
        { titulo: 'Prazo fatal', valor: l => data(l.pf_tarefa) },
        { titulo: 'Erros e avisos', valor: l => (l.erros || []).length ? h('ul', { class: 'apont' }, l.erros.map(e => h('li', { class: e.nivel === 'erro' ? 'apont-erro' : 'apont-aviso' }, `${e.nivel === 'erro' ? 'Erro' : 'Aviso'} — ${e.campo}: ${e.mensagem}`))) : '—' },
        { titulo: 'Alterações', valor: l => num(l.alteracoes_detectadas), num: true }
      ], vis, { compacta: true, vazio: 'Nenhuma linha neste filtro.' }));
    }
    el.append(filtros, corpo); render();
  }

  window.Importacao = { abrir, atlas };
})();
