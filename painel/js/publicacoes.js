/* Área 7 — Publicações Webjur (Etapa 6). Exclusiva do administrador.
 * Entrada: e-mail diário da Webjur salvo (.eml/.html) ou texto colado. O arquivo é lido no
 * navegador (OCWebjur) e o banco confere de novo (pub_registrar_remessa): o mesmo arquivo nunca
 * entra duas vezes, e a contagem é comparada com o total que a Webjur declara. */
(function () {
  'use strict';
  const { h, data, dataHora, num, tabela, aviso } = UI;
  const SITUACAO = {
    sem_conferencia: 'Sem conferência', encontrada_advbox: 'Encontrada no ADVBOX', nao_encontrada_advbox: 'Não encontrada no ADVBOX',
    processo_nao_cadastrado: 'Processo não cadastrado', duplicidade_webjur: 'Duplicidade na Webjur', inconclusiva: 'Inconclusiva', conferencia_manual: 'Conferência manual',
    erro_coleta: 'Erro de coleta', erro_acesso_advbox: 'Erro de acesso ao ADVBOX'
  };
  const ALERTA = {
    cnj_ausente: 'Sem número de processo', cnj_ambiguo: 'Processo ambíguo (vários CNJ, nenhum no cabeçalho)', cnj_digito_invalido: 'CNJ com dígito inválido',
    varios_cnj_no_teor: 'Teor cita mais de um CNJ', data_disponibilizacao_invalida: 'Data de disponibilização inválida',
    data_publicacao_invalida: 'Data de publicação inválida', sem_identificador_documento: 'Sem identificador do documento',
    tribunal_nao_identificado: 'Tribunal não identificado', teor_vazio: 'Teor vazio'
  };
  const ORIGEM = { webjur_email: 'E-mail (arquivo)', webjur_gmail: 'Gmail', webjur_portal: 'Portal', manual: 'Manual' };
  const rotAlerta = a => ALERTA[a] || a;
  const hojeISO = () => new Date().toLocaleDateString('sv-SE', { timeZone: 'America/Sao_Paulo' });
  const somaDias = (iso, n) => { const d = new Date(iso + 'T12:00:00Z'); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); };
  const filtros = { inicio: somaDias(hojeISO(), -29), fim: hojeISO(), busca: '', situacao: '', origem: '' };
  let ctx, raiz, lidos = [];

  async function abrir(container, contexto) {
    ctx = contexto; raiz = container; lidos = [];
    raiz.append(
      h('h1', {}, 'Publicações Webjur'),
      h('p', { class: 'sutil' }, 'Fonte principal: exportação diária do portal Webjur (Exportar todas → Planilha). ',
        'Contingência e segunda contagem: o e-mail diário, salvo (.eml ou .html) ou colado. A mesma publicação vinda das duas fontes é registrada uma vez só.'),
      h('section', { class: 'cartao', id: 'pub-entrada' }),
      h('section', { id: 'pub-previa' }),
      h('section', { class: 'cartao', id: 'pub-remessas' }, h('h2', {}, 'E-mails importados'), h('p', { class: 'sutil' }, 'Carregando…')),
      h('section', { class: 'cartao', id: 'pub-lista' })
    );
    desenharEntrada(); desenharFiltros();
    await Promise.all([desenharRemessas(), listar()]);
  }

  // ---------------------------------------------------------------- entrada
  function desenharEntrada() {
    const el = raiz.querySelector('#pub-entrada');
    const area = h('textarea', { id: 'pub-texto', rows: 4, class: 'pub-texto', placeholder: 'Ou cole aqui o texto completo do e-mail da Webjur…', 'aria-label': 'Texto do e-mail' });
    el.append(
      h('h2', {}, 'Importar publicações da Webjur'),
      h('label', { class: 'arquivo' }, h('span', {}, 'Exportação do portal (.csv) ou e-mail (.eml, .html)'),
        h('input', { type: 'file', id: 'pub-arquivos', accept: '.csv,.eml,.html,.htm,.txt,message/rfc822,text/html,text/csv', multiple: true, onchange: aoSelecionar })),
      area,
      h('div', { class: 'acoes' }, h('button', { type: 'button', class: 'btn btn-sec', id: 'pub-ler-texto', onclick: () => lerTexto(area.value) }, 'Ler texto colado'))
    );
  }

  async function aoSelecionar(ev) {
    lidos = [];
    for (const f of ev.target.files) {
      const bytes = new Uint8Array(await f.arrayBuffer());
      if (/\.csv$/i.test(f.name)) {
        // Exportação "Planilha" do portal: uma remessa por arquivo; o hash é o do arquivo
        try { lidos.push({ nome: f.name, r: OCWebjurPortal.lerExportacaoCsv(bytes, f.name), hash: await OCPlanilha.sha256Hex(bytes) }); }
        catch (e) { lidos.push({ nome: f.name, erro: 'Não foi possível ler o arquivo: ' + e.message }); }
      } else lidos.push(...await preparar(f.name, () => OCWebjur.lerEmails(bytes, f.name)));
    }
    desenharPrevia();
  }
  async function lerTexto(texto) {
    if (!texto.trim()) return;
    lidos = await preparar(`texto colado em ${new Date().toLocaleString('pt-BR')}`, () => OCWebjur.lerEmails(texto, 'colado.txt'));
    desenharPrevia();
  }
  /** Um arquivo pode conter vários e-mails da Webjur (encaminhamento com e-mails anexados).
   *  Cada e-mail vira uma remessa; o hash é o do texto do próprio e-mail, então o mesmo e-mail
   *  importado por outro arquivo é reconhecido como já importado. */
  async function preparar(nome, ler) {
    let rs;
    try { rs = ler(); } catch (e) { return [{ nome, erro: 'Não foi possível ler o arquivo: ' + e.message }]; }
    const out = [];
    for (const r of rs) {
      const rotulo = rs.length > 1 ? `${nome} — e-mail ${r.indice} de ${r.de}` : nome;
      out.push({ nome: rotulo, r, hash: await OCPlanilha.sha256Hex(new TextEncoder().encode(r.texto_bloco || '')) });
    }
    return out;
  }

  function desenharPrevia() {
    const el = raiz.querySelector('#pub-previa'); el.textContent = '';
    for (const s of lidos) el.append(cartaoPrevia(s));
  }

  function cartaoPrevia(s) {
    const c = h('section', { class: 'cartao pub-previa', dataset: { hash: s.hash } });
    c.append(h('h2', {}, s.nome));
    if (s.erro) { c.append(aviso('erro', s.erro)); return c; }
    const r = s.r;
    if (!r.reconhecido) { c.append(aviso('erro', ...r.avisos)); return c; }
    const portal = r.origem === 'webjur_portal';
    const comPub = portal ? [] : r.secoes.filter(x => x.declarado > 0 || x.lidas > 0);
    c.append(h('p', { class: 'sutil pub-fonte' }, portal ? 'Exportação do portal Webjur (Planilha)' : 'E-mail diário da Webjur'));
    c.append(h('dl', { class: 'resumo' },
      portal ? item('Disponibilização', r.secoes[0].data || '—') : item('Envio pela Webjur', r.recebido_em ? dataHora(r.recebido_em) : 'não informado'),
      portal ? item('Por estado', Object.entries(r.porUf).map(([u, n]) => `${u} ${n}`).join(' · ') || '—') : item('Cliente', r.cliente || '—'),
      portal ? null : item('Diários lidos', num(r.secoes.length)),
      item('Publicações declaradas', num(r.total_declarado)), item('Publicações lidas', num(r.total_lido))));
    if (r.completo) c.append(aviso('info', portal ? `Conferido: as ${num(r.total_lido)} publicações lidas batem com o total informado no fim do arquivo.`
                                                  : `Conferido: as ${num(r.total_lido)} publicações lidas batem com o total declarado pela Webjur em cada diário.`));
    else c.append(aviso('alerta', h('b', {}, 'Contagem divergente. '), portal ? 'Exporte de novo no portal. ' : 'Confira este dia no portal da Webjur. ', h('ul', {}, r.avisos.map(a => h('li', {}, a)))));
    if (comPub.length) c.append(h('h3', {}, 'Diários com publicação'), tabela([
      { titulo: 'Diário', valor: x => x.caderno }, { titulo: 'Data', valor: x => x.data },
      { titulo: 'Declaradas', num: true, valor: x => num(x.declarado) }, { titulo: 'Lidas', num: true, valor: x => num(x.lidas) }
    ], comPub, { compacta: true }));
    c.append(h('h3', {}, 'Publicações'), tabela([
      { titulo: portal ? 'Código Webjur' : 'Diário', valor: p => portal ? `${p.uf} · ${p.codigo_webjur}` : `${p.secao} ${p.secao_data ? p.secao_data.slice(0, 5) : ''} #${p.seq}` },
      { titulo: 'Disponibilização', valor: p => p.data_disponibilizacao || '—' },
      { titulo: 'Publicação', valor: p => p.data_publicacao || '—' },
      { titulo: 'Processo', valor: p => h('span', { class: 'nowrap' }, p.cnj || '—') },
      { titulo: 'Tribunal / órgão', valor: p => [p.tribunal, p.orgao_julgador].filter(Boolean).join(' — ') || '—' },
      { titulo: 'Identificador', valor: p => p.id_documento || '—' },
      { titulo: 'Alertas', larga: true, valor: p => p.alertas.length ? p.alertas.map(rotAlerta).join('; ') : '—' }
    ], r.publicacoes, { compacta: true, vazio: 'Nenhuma publicação neste e-mail.', classeLinha: p => p.alertas.length ? 'linha-alerta' : null }));

    const confirma = h('input', { type: 'checkbox', class: 'pub-confirma-divergente' });
    const btn = h('button', { type: 'button', class: 'btn pub-registrar', disabled: !r.completo, onclick: () => registrar(s, c, btn) },
      r.publicacoes.length ? `Registrar ${num(r.publicacoes.length)} publicação(ões)` : 'Registrar o e-mail (sem publicações)');
    confirma.addEventListener('change', () => { btn.disabled = !confirma.checked; });
    c.append(h('div', { class: 'acoes' },
      r.completo ? null : h('label', { class: 'opcao' }, confirma, h('span', {}, 'Registrar mesmo assim. A divergência fica gravada na remessa e no log de integração.')),
      btn), h('div', { class: 'pub-resultado' }));
    return c;
  }
  const item = (k, v) => h('div', {}, h('dt', {}, k), h('dd', {}, v));

  async function registrar(s, cartao, btn) {
    btn.disabled = true; btn.textContent = 'Registrando…';
    const r = s.r;
    const { data: d, error } = await ctx.sb.rpc('pub_registrar_remessa', {
      p_arquivo_nome: s.nome, p_arquivo_sha256: s.hash,
      p_origem: r.origem === 'webjur_portal' ? 'webjur_portal' : 'webjur_email',
      p_remessa: { formato: r.formato, recebido_em: r.recebido_em, chave_cliente: r.chave_cliente, cliente: r.cliente,
                   secoes: r.secoes.map(x => ({ ordem: x.ordem, caderno: x.caderno, data: x.data, declarado: x.declarado })), avisos: r.avisos },
      p_publicacoes: r.publicacoes.map(p => r.origem === 'webjur_portal' ? OCWebjurPortal.paraRegistro(p) : OCWebjur.paraRegistro(p, r))
    });
    const out = cartao.querySelector('.pub-resultado'); out.textContent = '';
    if (error) { out.append(aviso('erro', 'O banco recusou a remessa: ' + error.message)); btn.disabled = false; btn.textContent = 'Tentar de novo'; return; }
    btn.textContent = 'Registrado';
    if (d.status === 'ja_importada') out.append(aviso('info', `Este ${s.r.origem === 'webjur_portal' ? 'arquivo' : 'e-mail'} já foi importado (remessa #${d.remessa_id}). Nada foi gravado de novo.`));
    else out.append(aviso(d.situacao === 'completa' && !d.rejeitadas ? 'info' : 'alerta',
      `Remessa #${d.remessa_id}: ${num(d.novas)} nova(s), ${num(d.ja_registradas)} já registrada(s), ${num(d.rejeitadas)} rejeitada(s). `,
      d.situacao === 'completa' ? 'Contagem conferida pelo banco.' : 'Contagem divergente registrada.'));
    await Promise.all([desenharRemessas(), listar()]);
  }

  // ---------------------------------------------------------------- remessas
  async function desenharRemessas() {
    const el = raiz.querySelector('#pub-remessas');
    const { data: rs, error } = await ctx.sb.from('v_webjur_remessas')
      .select('id,arquivo_nome,recebido_em,importada_em,total_declarado,total_enviado,novas,rejeitadas,situacao,origem')
      .order('id', { ascending: false }).limit(30);
    el.textContent = ''; el.append(h('h2', {}, 'E-mails importados'));
    if (error) { el.append(aviso('erro', error.message)); return; }
    el.append(h('p', { class: 'sutil' }, 'Últimas 30 remessas. Uma remessa não pode ser alterada nem excluída.'), tabela([
      { titulo: '#', num: true, valor: x => x.id }, { titulo: 'Importada em', valor: x => dataHora(x.importada_em) },
      { titulo: 'Arquivo', valor: x => x.arquivo_nome || '—' }, { titulo: 'Envio Webjur', valor: x => x.recebido_em ? dataHora(x.recebido_em) : '—' },
      { titulo: 'Declaradas', num: true, valor: x => num(x.total_declarado) }, { titulo: 'Recebidas', num: true, valor: x => num(x.total_enviado) },
      { titulo: 'Novas', num: true, valor: x => num(x.novas) }, { titulo: 'Rejeitadas', num: true, valor: x => num(x.rejeitadas) },
      { titulo: 'Contagem', valor: x => x.situacao === 'completa' ? 'Conferida' : 'Divergente' }
    ], rs || [], { compacta: true, vazio: 'Nenhum e-mail importado ainda.', classeLinha: x => x.situacao !== 'completa' || x.rejeitadas > 0 ? 'linha-alerta' : null }));
  }

  // ---------------------------------------------------------------- lista
  function desenharFiltros() {
    const el = raiz.querySelector('#pub-lista');
    const sel = (id, rot, opcoes, chave) => h('label', { class: 'filtro' }, h('span', {}, rot), h('select', { id, onchange: e => { filtros[chave] = e.target.value; listar(); } },
      opcoes.map(([v, t]) => h('option', { value: v, selected: filtros[chave] === v }, t))));
    let espera;
    el.append(h('h2', {}, 'Publicações registradas'),
      h('form', { class: 'filtros-barra', onsubmit: e => e.preventDefault(), 'aria-label': 'Filtros das publicações' },
        h('label', { class: 'filtro' }, h('span', {}, 'Disponibilização entre'), h('span', { class: 'filtro-linha' },
          h('input', { type: 'date', id: 'pub-ini', value: filtros.inicio, onchange: e => { filtros.inicio = e.target.value; listar(); } }),
          h('input', { type: 'date', id: 'pub-fim', value: filtros.fim, onchange: e => { filtros.fim = e.target.value; listar(); } }))),
        h('label', { class: 'filtro' }, h('span', {}, 'Processo, tribunal ou identificador'),
          h('input', { type: 'search', id: 'pub-busca', value: filtros.busca, oninput: e => { clearTimeout(espera); espera = setTimeout(() => { filtros.busca = e.target.value; listar(); }, 350); } })),
        sel('pub-situacao', 'Conferência', [['', 'Todas'], ['sem_conferencia', 'Sem conferência'], ['com_alerta', 'Com alerta da leitura'],
          ...Object.entries(SITUACAO).filter(([k]) => k !== 'sem_conferencia')], 'situacao'),
        sel('pub-origem', 'Origem', [['', 'Todas'], ...Object.entries(ORIGEM)], 'origem')),
      h('div', { id: 'pub-lista-corpo' }));
  }

  let seq = 0;
  async function listar() {
    const corpo = raiz.querySelector('#pub-lista-corpo'); const meu = ++seq;
    corpo.textContent = ''; corpo.append(h('p', { class: 'sutil' }, 'Carregando…'));
    const { data: d, error } = await ctx.sb.rpc('pub_listar', { p_inicio: filtros.inicio, p_fim: filtros.fim, p_busca: filtros.busca || null,
      p_situacao: filtros.situacao || null, p_origem: filtros.origem || null, p_limite: 500 });
    if (meu !== seq) return;
    corpo.textContent = '';
    if (error) { corpo.append(aviso('erro', error.message)); return; }
    const ps = Object.entries(d.por_situacao || {});
    corpo.append(h('p', { class: 'sutil', id: 'pub-total' }, d.total > d.linhas.length ? `Mostrando ${num(d.linhas.length)} de ${num(d.total)} publicações.` : `${num(d.total)} publicação(ões).`,
      ps.length ? ' ' + ps.map(([k, n]) => `${SITUACAO[k] || k}: ${num(n)}`).join(' · ') + '.' : ''));
    corpo.append(tabela([
      { titulo: 'Disponibilização', valor: p => data(p.data_disponibilizacao) },
      { titulo: 'Publicação', valor: p => data(p.data_publicacao) },
      { titulo: 'Processo', valor: p => h('button', { type: 'button', class: 'link pub-abrir nowrap', onclick: () => detalhar(p.id) },
          p.cnj || p.cnj_original || 'sem número') },
      { titulo: 'Tribunal / órgão', valor: p => [p.tribunal, p.orgao_julgador].filter(Boolean).join(' — ') || '—' },
      { titulo: 'Início do teor', larga: true, valor: p => p.teor_inicio + (p.teor_inicio.length >= 280 ? '…' : '') },
      { titulo: 'Fontes', valor: p => (p.origens || '').split(',').filter(Boolean).map(o => ORIGEM[o] || o).join(', ') + (p.n_coletas > 1 ? ` (${p.n_coletas}×)` : '') },
      { titulo: 'Conferência', valor: p => SITUACAO[p.situacao_conferencia || 'sem_conferencia'] },
      { titulo: 'Alertas', valor: p => (p.alertas_leitura || []).map(rotAlerta).join('; ') || '—' }
    ], d.linhas, { vazio: 'Nenhuma publicação no período.', classeLinha: p => (p.alertas_leitura || []).length ? 'linha-alerta' : null }));
  }

  // ---------------------------------------------------------------- detalhe
  let dlg = null;
  async function detalhar(id) {
    if (!dlg) { dlg = h('dialog', { class: 'detalhe', 'aria-labelledby': 'pub-det-titulo' }); document.body.append(dlg); }
    dlg.textContent = '';
    const corpo = h('div', { class: 'detalhe-corpo' }, h('p', { class: 'sutil' }, 'Carregando…'));
    dlg.append(h('div', { class: 'detalhe-topo' }, h('h2', { id: 'pub-det-titulo' }, 'Publicação #' + id),
      h('button', { type: 'button', class: 'btn btn-sec btn-peq', onclick: () => dlg.close() }, 'Fechar')), corpo);
    dlg.showModal();
    const { data: d, error } = await ctx.sb.rpc('pub_detalhe', { p_id: id });
    corpo.textContent = '';
    if (error || !d || !d.publicacao) { corpo.append(aviso('erro', error ? error.message : 'Publicação não encontrada.')); return; }
    const p = d.publicacao, o = d.conteudo_original || {};
    const url = /^https?:\/\//i.test(p.url_origem || '') ? h('a', { href: p.url_origem, target: '_blank', rel: 'noopener noreferrer' }, 'abrir no tribunal') : '—';
    corpo.append(h('dl', { class: 'resumo' },
      item('Processo (CNJ)', h('span', { class: 'nowrap' }, p.cnj || '—')), item('Como veio na fonte', h('span', { class: 'nowrap' }, p.cnj_original || '—')),
      item('Dígito do CNJ', p.cnj ? (p.cnj_digito_valido ? 'válido' : 'INVÁLIDO') : '—'),
      item('Disponibilização', data(p.data_disponibilizacao)), item('Publicação', data(p.data_publicacao)),
      item('Tribunal', p.tribunal || '—'), item('Órgão julgador', p.orgao_julgador || '—'),
      item('Diário', [o.jornal, o.caderno, o.pagina ? 'p. ' + o.pagina : null].filter(Boolean).join(' · ') || '—'),
      item('Identificador do documento', p.id_documento || '—'), item('Documento', url),
      item('Registrada em', dataHora(p.registrada_em)), item('Conferência ADVBOX', SITUACAO[p.situacao_conferencia || 'sem_conferencia'])));
    if ((p.alertas_leitura || []).length) corpo.append(aviso('alerta', 'Alertas da leitura: ' + p.alertas_leitura.map(rotAlerta).join('; ') + '.'));
    corpo.append(h('h3', {}, 'Teor'), h('div', { class: 'pub-teor', tabindex: '0' }, p.teor));
    corpo.append(h('h3', {}, 'Coletas (cada vez que a publicação foi recebida)'), tabela([
      { titulo: 'Origem', valor: k => ORIGEM[k.origem] || k.origem }, { titulo: 'Arquivo', valor: k => k.arquivo || '—' },
      { titulo: 'Envio pela fonte', valor: k => k.recebido_em ? dataHora(k.recebido_em) : '—' }, { titulo: 'Coletada em', valor: k => dataHora(k.coletado_em) },
      { titulo: 'Teor', valor: k => k.teor_igual === false ? 'DIFERENTE do registrado' : 'igual' }
    ], d.coletas, { compacta: true }));
    corpo.append(h('h3', {}, 'Conferências no ADVBOX'), d.conferencias.length ? tabela([
      { titulo: 'Quando', valor: c => dataHora(c.realizada_em) }, { titulo: 'Resultado', valor: c => SITUACAO[c.situacao] || c.situacao },
      { titulo: 'Área', valor: c => c.area_conferida }
    ], d.conferencias, { compacta: true }) : h('p', { class: 'sutil' }, 'Ainda não conferida (Etapa 7 — Double check).'));
  }

  window.Publicacoes = { abrir };
})();
