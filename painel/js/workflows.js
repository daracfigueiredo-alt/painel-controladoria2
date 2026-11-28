/* Workflows jurídicos — fase 1 (26/11/2026, migração 0061) e prazos recursais (27/11/2026, migração 0063).
 * Recursais: a triagem abre o fluxo da DECISÃO (comunicação ao cliente pela assistente, validada pelo advogado, e análise de
 * Embargos e do recurso cabível) ou um recurso direto (ex.: contrarrazões). Os recursos escolhidos pelo advogado abrem fluxos
 * filhos com o PF SUGERIDO; a controladoria confirma o PF aqui antes de a peça e o protocolo seguirem. Dispensa: o líder aprova.
 * A controladoria faz a triagem da intimação (campos obrigatórios da especificação) e abre o fluxo-mestre.
 * O sistema cria no Atlas UMA tarefa por etapa, só quando a etapa é liberada (dependências e decisões SE/ENTÃO),
 * com o responsável do papel: advogado, assistente da equipe ou controladoria. O ciclo roda a cada 10 minutos.
 * O advogado (ou o líder, ou a controladoria) registra aqui as decisões que abrem as etapas seguintes.
 * Toda permissão é decidida no banco; aqui só se escondem botões que o banco recusaria. */
(function () {
  'use strict';
  const { h, num, data, dataHora, aviso } = UI;
  const msgErro = e => (e && (e.message || e.erro)) || String(e);
  const hojeISO = () => new Date().toLocaleDateString('sv-SE', { timeZone: 'America/Sao_Paulo' });
  const STATUS = {
    aguardando: ['Aguardando etapa anterior', 'tag-neutra'], aguardando_decisao: ['Aguardando decisão', 'tag-alerta'],
    aguardando_pf: ['PF a confirmar', 'tag-alerta'], liberada: ['Liberada (a criar no Atlas)', 'tag-alerta'], criando: ['Criando no Atlas', 'tag-neutra'],
    criada: ['No Atlas', 'tag-ok'], verificar: ['Conferir no Atlas', 'tag-erro'], sem_responsavel: ['Sem responsável', 'tag-erro'],
    em_subfluxo: ['Em andamento (rotina)', 'tag-ok'], concluida: ['Concluída', 'tag-ok'], dispensada: ['Dispensada', 'tag-neutra'],
    cancelada: ['Cancelada', 'tag-neutra']
  };
  const FLUXO = { ativo: 'Ativo', concluido: 'Concluído', cancelado: 'Cancelado' };
  const PAPEL = { advogado: 'Advogado', assistente: 'Assistente', controladoria: 'Controladoria', lider: 'Líder da equipe' };
  const EVENTO = { fluxo_iniciado: 'Fluxo iniciado', triagem: 'Triagem registrada', etapa_liberada: 'Etapa liberada', criada_no_atlas: 'Criada no Atlas',
    falha_atlas: 'Falha ao criar no Atlas', etapa_concluida: 'Etapa concluída', etapa_dispensada: 'Etapa dispensada', decisao: 'Decisão registrada',
    sem_responsavel: 'Sem responsável', etapa_reenviada: 'Etapa reenviada', fluxo_concluido: 'Fluxo concluído', fluxo_cancelado: 'Fluxo cancelado',
    pf_confirmado: 'PF confirmado', aguardando_pf: 'Aguardando confirmação do PF' };
  const tag = st => { const [t, c] = STATUS[st] || [st, 'tag-neutra']; return h('span', { class: 'tag ' + c }, t); };
  async function rpc(ctx, fn, args) {
    const { data: d, error } = await ctx.sb.rpc(fn, args || {});
    if (error) throw new Error(error.message);
    return d;
  }
  const campo = (rot, el, largo) => h('label', { class: 'filtro' + (largo ? ' filtro-largo' : '') }, h('span', {}, rot), el);

  async function abrir(raiz, ctx) {
    const admin = ctx.perfil.papel === 'admin';
    const f = { status: 'ativo', busca: '' };
    raiz.append(h('h1', {}, 'Workflows jurídicos'),
      h('p', { class: 'subtitulo' }, 'Tratamento de intimações e prazos recursais'),
      h('p', { class: 'sutil' }, 'Cada etapa vira uma tarefa no Atlas só quando é liberada, já com o responsável do papel: advogado, assistente da equipe ou controladoria. ',
        'Depois da análise, o advogado registra aqui as decisões (precisa de peça? de documentos? de comunicação?), e as etapas seguintes são criadas. ',
        'Documentos e elaboração da peça correm em paralelo: pendência do cliente não suspende o PF. ',
        'Decisões judiciais: a assistente da equipe comunica o cliente (com orientação validada pelo advogado); recurso tem PF sugerido que a controladoria confirma; protocolo é da controladoria e o advogado autor fiscaliza; não recorrer exige aprovação do líder. O ciclo roda a cada 10 minutos.'));
    const topo = h('div'), triagem = h('div'), corpo = h('div'), config = h('div');
    raiz.append(topo, triagem, corpo, config);
    const saida = h('div', { 'aria-live': 'polite' });

    if (admin) {
      const btCiclo = h('button', { type: 'button', class: 'btn btn-sec', onclick: async () => {
        btCiclo.disabled = true; saida.textContent = '';
        try {
          const r = await window.Gestao.chamarAtlas(ctx, { acao: 'workflows' });
          saida.append(aviso(r.erros ? 'alerta' : 'ok', `Ciclo: ${num(r.concluidas)} etapa(s) concluída(s) lidas no Atlas; `,
            r.ligado ? `${num(r.criadas)} tarefa(s) criada(s)` : 'criação no Atlas desligada', r.erros ? `; ${num(r.erros)} erro(s): ${r.ultimo_erro}` : '', '.'));
        } catch (e) { saida.append(aviso('erro', msgErro(e))); }
        btCiclo.disabled = false; desenhar();
      } }, 'Rodar o ciclo agora');
      const btNova = h('button', { type: 'button', class: 'btn btn-sec', onclick: () => { triagem.hidden = !triagem.hidden; if (!triagem.hidden && !triagem.firstChild) formTriagem(triagem, ctx, id => { triagem.hidden = true; abrirDetalhe(id); }); } }, 'Lançamento manual');
      triagem.hidden = true;
      topo.append(aviso('info', 'Para tratar uma intimação, use o botão "Tratar" na lista de ', h('a', { href: '#/intimacoes-cnj' }, 'Intimações CNJ'), ' ou de ',
          h('a', { href: '#/publicacoes' }, 'Publicações Webjur'), ': a triagem já abre com os dados da intimação. ',
          'Aqui ficam o acompanhamento dos fluxos, as decisões dos advogados, a configuração das equipes e o lançamento manual (intimação que não está nas listas).'),
        h('div', { class: 'acoes' }, btNova, btCiclo), saida);
    } else topo.append(saida);

    const selSt = h('select', {}, h('option', { value: 'ativo' }, 'Ativos'), h('option', { value: 'concluido' }, 'Concluídos'),
      h('option', { value: 'cancelado' }, 'Cancelados'), h('option', { value: '' }, 'Todos'));
    const busca = h('input', { type: 'search', placeholder: 'Processo, cliente ou providência', 'aria-label': 'Buscar' });
    topo.append(h('form', { class: 'filtros-barra', onsubmit: e => { e.preventDefault(); f.status = selSt.value; f.busca = busca.value; desenhar(); } },
      campo('Situação', selSt), campo('Busca', busca), h('button', { type: 'submit', class: 'btn btn-sec' }, 'Filtrar')));

    async function desenhar() {
      corpo.textContent = ''; corpo.append(h('p', { class: 'sutil' }, 'Carregando…'));
      let r;
      try { r = await rpc(ctx, 'wf_listar', { p_status: f.status || null, p_busca: f.busca || null, p_limite: 200 }); }
      catch (e) { corpo.textContent = ''; corpo.append(aviso('erro', msgErro(e))); return; }
      corpo.textContent = '';
      const c = r.contagem || {};
      const k = (rot, v, at) => h('div', { class: 'kpi kpi-estatico' + (at ? ' kpi-atencao' : '') }, h('span', { class: 'kpi-rotulo' }, rot), h('span', { class: 'kpi-valor' }, num(v)));
      corpo.append(h('section', { class: 'kpis' }, k('Fluxos ativos', c.ativos), k('Aguardando decisão', c.aguardando_decisao, c.aguardando_decisao > 0),
        k('PF a confirmar', c.pf_a_confirmar, c.pf_a_confirmar > 0),
        k('Com problema', c.com_problema, c.com_problema > 0), k('Etapas a criar no Atlas', c.para_criar, r.ligado && c.para_criar > 0)));
      corpo.append(h('p', { class: 'sutil' }, r.ligado ? 'Criação no Atlas: ligada.' : 'Criação no Atlas: desligada — as etapas liberadas ficam só aqui até a controladoria ligar (Configurações › wf_criar_no_atlas).',
        r.ultimo_ciclo ? ` Último ciclo: ${dataHora(r.ultimo_ciclo.em)} (${r.ultimo_ciclo.origem === 'agendamento' ? 'automático' : 'pelo painel'}).` : ' Nenhum ciclo rodou ainda.'));
      if (!r.itens.length) { corpo.append(aviso('info', 'Nenhum fluxo nos filtros escolhidos.')); return; }
      corpo.append(h('div', {}, r.itens.map(it => h('article', { class: 'cartao pauta-item' },
        h('div', { class: 'detalhe-topo' },
          h('div', {}, h('strong', {}, `#${it.id} · ${it.cnj || 'sem processo'}`), ' ', h('span', { class: 'tag tag-neutra' }, FLUXO[it.status] || it.status),
            it.modelo_nome ? h('div', { class: 'sutil' }, it.modelo_nome) : null,
            h('div', { class: 'sutil' }, [it.cliente, it.providencia, it.equipe && 'Equipe ' + it.equipe, it.advogado].filter(Boolean).join(' · '),
              it.pf ? ` · PF ${data(it.pf)}` : ' · sem prazo judicial')),
          h('button', { type: 'button', class: 'btn btn-sec btn-peq', onclick: () => abrirDetalhe(it.id) }, 'Abrir')),
        it.etapas && it.etapas.length ? h('ul', { class: 'checklist' }, it.etapas.map(e => h('li', {}, tag(e.status), ' ', e.titulo,
          e.responsavel ? ` — ${e.responsavel}` : '', e.prazo ? ` (até ${data(e.prazo)})` : ''))) : null))));
    }

    async function abrirDetalhe(id) {
      corpo.textContent = ''; corpo.append(h('p', { class: 'sutil' }, 'Carregando…'));
      let d;
      try { d = await rpc(ctx, 'wf_detalhe', { p_id: id }); } catch (e) { corpo.textContent = ''; corpo.append(aviso('erro', msgErro(e))); return; }
      corpo.textContent = '';
      const voltar = h('button', { type: 'button', class: 'btn btn-sec btn-peq', onclick: desenhar }, '← Voltar à lista');
      const recarregar = () => abrirDetalhe(id);
      corpo.append(h('div', { class: 'acoes' }, voltar),
        h('section', { class: 'cartao' },
          h('h2', {}, `Fluxo #${d.id} — ${d.modelo_nome}`), h('p', {}, tagFluxo(d.status)),
          h('div', { class: 'wf-dados' },
            ...[['Processo', d.cnj], ['Cliente', d.cliente], ['Natureza', d.natureza], ['Providência', d.providencia], ['Equipe', d.equipe],
                ['Advogado', d.advogado], ['PF', d.pf ? data(d.pf) : 'sem prazo judicial'], ['D-4', d.d4 ? data(d.d4) : '—'],
                ['Recebida em', data(d.data_recebimento)], ['Ciência', data(d.data_ciencia)], ['Modalidade', d.modalidade_intimacao],
                ...(d.dados && d.dados.tipo_decisao ? [['Tipo de decisão', TIPO_DECISAO[d.dados.tipo_decisao] || d.dados.tipo_decisao],
                  ['Resultado', RESULTADO[d.dados.resultado] || d.dados.resultado]] : []),
                ...(d.prazo_em_dobro ? [['Prazo', 'em dobro']] : [])]
              .map(([k, v]) => h('div', {}, h('span', { class: 'sutil' }, k), h('strong', {}, v || '—')))),
          d.link_intimacao ? h('p', {}, h('a', { href: d.link_intimacao, target: '_blank', rel: 'noopener noreferrer' }, 'Abrir a intimação')) : null,
          d.cancelado_motivo ? aviso('info', 'Cancelado: ' + d.cancelado_motivo) : null));
      corpo.append(blocoFluxo(d, ctx, recarregar, 0));
      if (d.admin && d.status === 'ativo') {
        const mot = h('textarea', { rows: 2, placeholder: 'Motivo do cancelamento (mín. 15 caracteres)', 'aria-label': 'Motivo do cancelamento' });
        const m = h('p', { class: 'erro', 'aria-live': 'polite' });
        corpo.append(h('details', { class: 'cartao' }, h('summary', {}, 'Cancelar o fluxo'),
          h('p', { class: 'sutil' }, 'Cancela o fluxo e as rotinas abertas por ele. Tarefas já criadas no Atlas não são apagadas (a API do Atlas não exclui tarefas): conclua ou exclua lá.'),
          mot, h('div', { class: 'acoes' }, h('button', { type: 'button', class: 'btn btn-sec', onclick: async ev => {
            ev.target.disabled = true; m.textContent = '';
            try { await rpc(ctx, 'wf_cancelar', { p_instancia: d.id, p_motivo: mot.value }); recarregar(); }
            catch (e) { m.textContent = msgErro(e); ev.target.disabled = false; }
          } }, 'Cancelar o fluxo')), m));
      }
      if (d.eventos && d.eventos.length) {
        corpo.append(h('details', { class: 'cartao' }, h('summary', {}, `Histórico (${d.eventos.length})`),
          h('ul', { class: 'checklist' }, d.eventos.map(e => h('li', {}, `${dataHora(e.em)} — ${EVENTO[e.tipo] || e.tipo}`,
            e.fluxo !== d.id ? ` (rotina #${e.fluxo})` : '', e.usuario ? ` — ${e.usuario}` : '',
            e.detalhe && (e.detalhe.nota || e.detalhe.motivo || e.detalhe.erro || e.detalhe.problema) ? ': ' + (e.detalhe.nota || e.detalhe.motivo || e.detalhe.erro || e.detalhe.problema) : '')))));
      }
      corpo.scrollIntoView({ block: 'start' });
    }

    if (admin) desenharConfig(config, ctx);
    if (fluxoPedido) { const id = fluxoPedido; fluxoPedido = null; abrirDetalhe(id); } else desenhar();
  }
  const TIPO_DECISAO = { sentenca: 'Sentença', interlocutoria: 'Decisão interlocutória', acordao: 'Acórdão', monocratica: 'Decisão monocrática', outra: 'Outra' };
  const RESULTADO = { favoravel: 'Favorável', parcialmente_favoravel: 'Parcialmente favorável', desfavoravel: 'Desfavorável' };
  const rotuloResposta = (p, v) => Array.isArray(v) ? v.map(x => ((p.opcoes || []).find(o => o.valor === x) || { rotulo: x }).rotulo).join(', ') : (v ? 'Sim' : 'Não');
  const tagFluxo = st => h('span', { class: 'tag ' + (st === 'ativo' ? 'tag-ok' : 'tag-neutra') }, FLUXO[st] || st);

  // etapas de um fluxo (e das rotinas que ele abriu), decisões pendentes e ações da controladoria
  function blocoFluxo(d, ctx, recarregar, nivel) {
    const sec = h('section', { class: nivel ? 'secao' : 'cartao' });
    if (nivel) sec.append(h('h3', {}, `Rotina #${d.id} — ${d.modelo_nome} `, tagFluxo(d.status)));
    else sec.append(h('h2', {}, 'Etapas'));
    if (d.status === 'ativo' && d.pf_confirmado === false) sec.append(blocoPF(d, ctx, recarregar));
    const pend = (d.perguntas || []).filter(p => p.pendente || p.resposta !== null && p.resposta !== undefined);
    // quem pode responder cada pergunta (o banco confere de novo): decisão do líder só o líder da equipe ou a controladoria
    const podeResponder = p => p.quem === 'lider' ? (d.admin || d.lider_do_fluxo) : d.pode_decidir;
    if (pend.length) {
      const respostas = {};
      const m = h('p', { class: 'erro', 'aria-live': 'polite' });
      const linhas = pend.map(p => {
        if (!p.pendente) return h('p', { class: 'pergunta' }, `${p.pergunta} `, h('strong', {}, rotuloResposta(p, p.resposta)));
        if (!podeResponder(p)) return h('p', { class: 'pergunta' }, `${p.pergunta} `,
          h('span', { class: 'sutil' }, p.quem === 'lider' ? '— aguardando o líder da equipe' : '— aguardando o advogado do fluxo'));
        const nome = `wf-${d.id}-${p.chave}`;
        if (p.tipo === 'multipla') {
          const marcados = new Set();
          return h('fieldset', { class: 'pergunta' }, h('legend', {}, p.pergunta + ' (pode marcar mais de um)'),
            (p.opcoes || []).map(o => h('label', { class: 'opcao' }, h('input', { type: 'checkbox', name: nome, value: o.valor, onchange: ev => {
              if (ev.target.checked) marcados.add(o.valor); else marcados.delete(o.valor);
              if (marcados.size) respostas[p.chave] = [...marcados]; else delete respostas[p.chave];
            } }), ' ', o.rotulo)));
        }
        const op = (v, t) => h('label', { class: 'opcao' }, h('input', { type: 'radio', name: nome, value: String(v), onchange: () => { respostas[p.chave] = v; } }), ' ', t);
        return h('fieldset', { class: 'pergunta' }, h('legend', {}, p.pergunta + (p.quem === 'lider' ? ' (decisão do líder)' : '')), op(true, 'Sim'), op(false, 'Não'));
      });
      sec.append(h('div', { class: 'caixa' }, h('p', {}, h('strong', {}, 'Decisões')), ...linhas,
        pend.some(p => p.pendente && podeResponder(p)) ? h('div', { class: 'acoes' }, h('button', { type: 'button', class: 'btn', onclick: async ev => {
          m.textContent = '';
          if (!Object.keys(respostas).length) { m.textContent = 'Responda pelo menos uma pergunta.'; return; }
          ev.target.disabled = true;
          try { await rpc(ctx, 'wf_decidir', { p_instancia: d.id, p_respostas: respostas, p_nota: null }); recarregar(); }
          catch (e) { m.textContent = msgErro(e); ev.target.disabled = false; }
        } }, 'Registrar decisões')) : null, m));
    }
    // etapas que não se aplicam (dispensadas pelas decisões) ficam recolhidas numa linha
    const naoAplicam = (d.etapas || []).filter(e => e.status === 'dispensada' && !e.filho);
    for (const e of d.etapas || []) {
      if (e.status === 'dispensada' && !e.filho) continue;
      const it = h('div', { class: 'pauta-item' + (['sem_responsavel', 'verificar'].includes(e.status) ? ' pauta-pendente' : '') },
        h('div', {}, tag(e.status), ' ', h('strong', {}, e.titulo)),
        h('div', { class: 'sutil' }, [e.papel && PAPEL[e.papel], e.responsavel, e.prazo && 'prazo ' + data(e.prazo),
          e.status === 'aguardando_decisao' && 'depende de decisão', e.status === 'aguardando_pf' && 'aguarda a controladoria confirmar o PF',
          e.concluida_em && 'encerrada em ' + dataHora(e.concluida_em) + (e.concluida_por === 'painel' ? ' (pelo painel)' : e.concluida_por === 'atlas' ? ' (no Atlas)' : '')].filter(Boolean).join(' · ')),
        e.atlas_app_url ? h('a', { href: e.atlas_app_url, target: '_blank', rel: 'noopener noreferrer' }, 'Abrir no Atlas') : null,
        e.exige_evidencia ? h('p', { class: 'sutil' }, 'Evidência obrigatória: ' + e.exige_evidencia) : null,
        e.erro ? h('p', { class: 'nota nota-erro' }, e.erro) : null,
        e.nota && e.status !== 'concluida' ? h('p', { class: 'nota' }, e.nota) : null);
      if (d.admin && d.status === 'ativo' && !['concluida', 'dispensada', 'cancelada'].includes(e.status)) it.append(acoesEtapa(e, ctx, recarregar));
      sec.append(it);
      if (e.filho) sec.append(blocoFluxo(e.filho, ctx, recarregar, nivel + 1));
    }
    if (naoAplicam.length) sec.append(h('details', { class: 'wf-nao-aplica' }, h('summary', {}, `${naoAplicam.length} etapa(s) que não se aplicam`),
      h('ul', { class: 'checklist' }, naoAplicam.map(e => h('li', {}, e.titulo, e.nota ? h('span', { class: 'sutil' }, ' — ' + e.nota) : null)))));
    return sec;
  }

  // PF sugerido pelo sistema (data da intimação + prazo legal em dias úteis); a controladoria confirma ou corrige com motivo
  function blocoPF(d, ctx, recarregar) {
    const cx = h('div', { class: 'caixa caixa-alerta' }, h('p', {}, h('strong', {}, 'PF a confirmar: '),
      `sugerido ${d.pf_sugerido ? data(d.pf_sugerido) : '—'} (${d.prazo_legal_modelo || '?'} dias úteis${d.prazo_em_dobro ? ', em dobro' : ''}, contados da ciência em ${data(d.data_ciencia)}, calendário do tribunal). `,
      'A peça e o protocolo só seguem depois da confirmação.'));
    if (!d.admin) { cx.append(h('p', { class: 'sutil' }, 'Aguardando a controladoria confirmar o PF.')); return cx; }
    const pf = h('input', { type: 'date', value: d.pf_sugerido || '', min: hojeISO(), 'aria-label': 'PF confirmado' });
    const mot = h('input', { type: 'text', placeholder: 'Motivo, se for diferente do sugerido (mín. 15 caracteres)', 'aria-label': 'Motivo do PF diferente' });
    const m = h('p', { class: 'erro', 'aria-live': 'polite' });
    cx.append(h('p', { class: 'sutil' }, 'Confira rito, forma de intimação, prazo em dobro, suspensões e regras do tribunal.'),
      h('div', { class: 'filtros-barra' }, campo('PF', pf), campo('Motivo', mot, true),
        h('button', { type: 'button', class: 'btn', onclick: async ev => {
          ev.target.disabled = true; m.textContent = '';
          try { await rpc(ctx, 'wf_confirmar_pf', { p_instancia: d.id, p_pf: pf.value || null, p_motivo: mot.value || null }); recarregar(); }
          catch (e) { m.textContent = msgErro(e); ev.target.disabled = false; }
        } }, 'Confirmar PF')), m);
    return cx;
  }

  function acoesEtapa(e, ctx, recarregar) {
    const nota = h('textarea', { rows: 2, placeholder: 'Justificativa (mín. 15 caracteres)', 'aria-label': 'Justificativa' });
    const m = h('p', { class: 'erro', 'aria-live': 'polite' });
    const bt = (acao, txt) => h('button', { type: 'button', class: 'btn btn-sec btn-peq', onclick: async ev => {
      ev.target.disabled = true; m.textContent = '';
      try { await rpc(ctx, 'wf_etapa_manual', { p_tarefa: e.id, p_acao: acao, p_nota: nota.value }); recarregar(); }
      catch (err) { m.textContent = msgErro(err); ev.target.disabled = false; }
    } }, txt);
    const botoes = [];
    if (e.status !== 'em_subfluxo') botoes.push(bt('concluir', 'Concluir pelo painel'));
    botoes.push(bt('dispensar', 'Dispensar etapa'));
    if (['verificar', 'sem_responsavel'].includes(e.status)) botoes.push(bt('recriar', e.status === 'verificar' ? 'Conferi no Atlas: reenviar' : 'Tentar de novo'));
    return h('details', {}, h('summary', {}, 'Ações da controladoria'), nota, h('div', { class: 'acoes' }, ...botoes), m);
  }

  // ------------------------------------------------------------ triagem (seção 1.2 da especificação)
  // pre (0065, 27/11/2026): { origem_tipo, origem_id } quando a triagem nasce de uma intimação da lista (CNJ ou Webjur):
  // a origem já vem escolhida e os dados são buscados sozinhos.
  async function formTriagem(caixa, ctx, aoCriar, pre) {
    let cfg;
    try { cfg = await rpc(ctx, 'wf_configuracao'); } catch (e) { caixa.append(aviso('erro', msgErro(e))); return; }
    const sel = (lista, rot) => h('select', {}, h('option', { value: '' }, rot), lista.map(x => h('option', { value: x.id }, x.nome)));
    const el = {
      modelo: h('select', {}, (cfg.modelos_entrada || [{ codigo: 'MESTRE', nome: 'Intimação (fluxo-mestre)' }]).map(x =>
        h('option', { value: x.codigo }, x.nome + (x.prazo_legal_dias ? ` — ${x.prazo_legal_dias} dias úteis` : '')))),
      tipo_decisao: h('select', {}, h('option', { value: '' }, 'Escolha'), Object.entries(TIPO_DECISAO).map(([v, t]) => h('option', { value: v }, t))),
      resultado: h('select', {}, h('option', { value: '' }, 'Escolha'), Object.entries(RESULTADO).map(([v, t]) => h('option', { value: v }, t))),
      prazo_em_dobro: h('input', { type: 'checkbox' }),
      origem_tipo: h('select', {}, [['manual', 'Lançamento manual'], ['cnj', 'Intimação do CNJ (id)'], ['webjur', 'Publicação Webjur (id)'], ['atlas_intimacao', 'Intimação do Atlas (id)']]
        .map(([v, t]) => h('option', { value: v }, t))),
      origem_id: h('input', { type: 'text', placeholder: 'Identificador da intimação' }),
      cnj: h('input', { type: 'text', required: true }), cliente: h('input', { type: 'text', required: true }),
      equipe_id: sel(cfg.equipes_lista, 'Escolha'), advogado_colaborador_id: sel(cfg.advogados, 'Escolha'),
      natureza: h('input', { type: 'text', placeholder: 'Ex.: determinação de emenda' }),
      providencia: h('input', { type: 'text', placeholder: 'Ex.: EMENDA À INICIAL' }),
      modalidade_intimacao: h('select', {}, ['DJEN', 'Sistema do tribunal (PJe/eproc/Projudi)', 'E-mail', 'Oficial de justiça', 'Audiência', 'Outra'].map(t => h('option', { value: t }, t))),
      data_recebimento: h('input', { type: 'date', value: hojeISO() }), data_ciencia: h('input', { type: 'date' }),
      tem_prazo: h('input', { type: 'checkbox', checked: true }), prazo_legal_dias: h('input', { type: 'number', min: 0, max: 365, class: 'campo-curto' }),
      pf: h('input', { type: 'date', min: hojeISO() }), link_intimacao: h('input', { type: 'url', placeholder: 'https://…' }),
      motivo: h('input', { type: 'text', placeholder: 'Motivo da comunicação ao cliente' }),
      finalidade: h('input', { type: 'text', placeholder: 'Para que servem os documentos' })
    };
    let decisoes = {};
    const caixaPerg = h('div', { class: 'filtros-barra' }), caixaDecisao = h('div', { class: 'filtros-barra' });
    // Natureza e providência só no fluxo geral (MESTRE): tarefas sem workflow próprio, como especificação de provas,
    // alegações finais, memoriais, manifestação complexa e impugnação. Nos fluxos de decisão e de recurso a peça já vem do fluxo.
    const linhaNatureza = h('div', { class: 'filtros-barra wf-bloco' },
      h('p', { class: 'wf-dica' }, h('strong', {}, 'Tarefa sem workflow próprio? '),
        'Em especificação de provas, alegações finais, memoriais, manifestação complexa, impugnação e casos parecidos, descreva a natureza da intimação e a providência que ela pede.'),
      campo('Natureza da intimação', el.natureza, true), campo('Providência jurídica', el.providencia, true));
    const modeloAtual = () => (cfg.modelos_entrada || []).find(x => x.codigo === el.modelo.value) || { codigo: 'MESTRE', perguntas: cfg.perguntas_mestre };
    const trocarModelo = () => {
      const mo = modeloAtual(); decisoes = {}; caixaPerg.textContent = '';
      caixaPerg.append(...(mo.perguntas || []).map(p => {
        const s = h('select', { onchange: () => { if (s.value === '') delete decisoes[p.chave]; else decisoes[p.chave] = s.value === 'sim'; } },
          h('option', { value: '' }, 'O advogado decide depois da análise'), h('option', { value: 'sim' }, 'Sim'), h('option', { value: 'nao' }, 'Não'));
        return campo(p.pergunta, s, true);
      }));
      caixaPerg.hidden = !caixaPerg.childNodes.length;
      caixaDecisao.hidden = mo.codigo !== 'DECISAO';
      linhaNatureza.hidden = mo.codigo !== 'MESTRE';
      el.providencia.placeholder = mo.nome_peca ? `Padrão: ${mo.nome_peca}` : (mo.codigo === 'DECISAO' ? 'Padrão: ANALISAR DECISÃO' : 'Ex.: EMENDA À INICIAL');
      // 0067: "Sugerir PF" em todos os fluxos; o prazo padrão do modelo (recursos) só preenche o campo
      if (mo.prazo_legal_dias) el.prazo_legal_dias.value = mo.prazo_legal_dias;
    };
    el.modelo.addEventListener('change', trocarModelo);
    caixaDecisao.append(campo('Tipo de decisão', el.tipo_decisao), campo('Resultado', el.resultado));
    const dica = h('p', { class: 'sutil', 'aria-live': 'polite' }), m = h('p', { class: 'erro', 'aria-live': 'polite' });
    const teor = h('div');   // inteiro teor da intimação (texto legível), mostrado na triagem
    const btBuscar = h('button', { type: 'button', class: 'btn btn-sec btn-peq', onclick: async () => {
      m.textContent = ''; dica.textContent = '';
      if (el.origem_tipo.value === 'manual' || !el.origem_id.value.trim()) { m.textContent = 'Escolha a origem e informe o identificador da intimação.'; return; }
      try {
        const r = await rpc(ctx, 'wf_triagem_dados', { p_origem_tipo: el.origem_tipo.value, p_origem_id: el.origem_id.value.trim() });
        for (const k of ['cnj', 'cliente', 'natureza', 'pf', 'data_ciencia', 'link_intimacao']) if (r[k]) el[k].value = r[k];
        if (r.data_disponibilizacao) el.data_recebimento.value = r.data_disponibilizacao;
        if (r.equipe_id) el.equipe_id.value = String(r.equipe_id);
        caixa.dataset.lawsuit = r.atlas_lawsuit_id || ''; caixa.dataset.client = r.atlas_client_id || '';
        dica.textContent = (r.fluxo_ativo ? `Atenção: esta intimação já tem o fluxo #${r.fluxo_ativo} ativo. ` : '')
          + (r.atlas_lawsuit_id ? 'Processo encontrado no Atlas: as tarefas serão vinculadas a ele. ' : 'Processo não encontrado no Atlas: as tarefas sairão sem vínculo com o processo. ')
          + (r.data_disponibilizacao && r.data_ciencia && r.data_disponibilizacao !== r.data_ciencia
            ? `Disponibilizada em ${data(r.data_disponibilizacao)}; publicação considerada em ${data(r.data_ciencia)} (1º dia útil seguinte, regra do DJEN). ` : '')
          + (r.resumo ? '' : 'A intimação não trouxe texto.');
        teor.textContent = '';
        if (r.resumo) teor.append(h('details', { class: 'caixa', open: true }, h('summary', {}, h('strong', {}, 'Inteiro teor da intimação')),
          h('div', { class: 'teor-cnj' }, UI.textoLegivel(r.resumo).split('\n').map(l => h('p', { class: /^[A-ZÀ-Ú()\/ ]{3,40}:/.test(l) ? 'teor-cab' : null }, l))),
          /refere-se aos seguintes eventos/i.test(r.resumo) && r.link_intimacao ? h('p', { class: 'nota' }, 'A comunicação só cita os eventos (eproc). O inteiro teor do ato está no ',
            h('a', { href: r.link_intimacao, target: '_blank', rel: 'noopener noreferrer' }, 'documento do tribunal'), '.') : null));
      } catch (e) { m.textContent = msgErro(e); }
    } }, 'Buscar dados da intimação');
    const btSugerir = h('button', { type: 'button', class: 'btn btn-sec btn-peq', onclick: async () => {
      m.textContent = ''; dica.textContent = '';
      if (!el.data_ciencia.value) { m.textContent = 'Informe a data da publicação ou ciência para sugerir o PF.'; return; }
      try {
        const dias = el.prazo_legal_dias.value ? parseInt(el.prazo_legal_dias.value, 10) : null;
        const r = await rpc(ctx, 'wf_sugerir_pf', { p_modelo: el.modelo.value, p_data_intimacao: el.data_ciencia.value, p_dobro: el.prazo_em_dobro.checked,
          p_cnj: el.cnj.value.trim() || null, p_dias: dias });
        if (r.pf) { el.pf.value = r.pf; el.prazo_legal_dias.value = r.dias_base; }
        dica.textContent = r.pf ? `PF sugerido: ${data(r.pf)} (${r.dias} dias úteis contados de ${data(r.inicio_contagem)}${r.tribunal ? ', calendário do tribunal ' + r.tribunal : ''}; D-4 ${data(r.d4)}). ${r.aviso}` : (r.mensagem || '');
      } catch (e) { m.textContent = msgErro(e); }
    } }, 'Sugerir PF');
    el.tem_prazo.addEventListener('change', () => { el.pf.disabled = !el.tem_prazo.checked; el.prazo_legal_dias.disabled = !el.tem_prazo.checked; btSugerir.hidden = !el.tem_prazo.checked; });
    const btCriar = h('button', { type: 'submit', class: 'btn' }, 'Abrir o fluxo');
    caixa.append(h('form', { class: 'cartao wf-triagem', onsubmit: async ev => {
      ev.preventDefault(); m.textContent = '';
      const campos = {
        modelo: el.modelo.value, prazo_em_dobro: el.prazo_em_dobro.checked,
        origem_tipo: el.origem_tipo.value, origem_id: el.origem_id.value.trim() || null, cnj: el.cnj.value.trim(), cliente: el.cliente.value.trim(),
        equipe_id: el.equipe_id.value, advogado_colaborador_id: el.advogado_colaborador_id.value,
        natureza: linhaNatureza.hidden ? (modeloAtual().nome || el.modelo.value) : el.natureza.value.trim(),
        providencia: linhaNatureza.hidden ? '' : el.providencia.value.trim(), modalidade_intimacao: el.modalidade_intimacao.value, data_recebimento: el.data_recebimento.value,
        data_ciencia: el.data_ciencia.value, tem_prazo: el.tem_prazo.checked, prazo_legal_dias: el.tem_prazo.checked ? el.prazo_legal_dias.value : '',
        pf: el.tem_prazo.checked ? el.pf.value : '', link_intimacao: el.link_intimacao.value.trim(),
        atlas_lawsuit_id: caixa.dataset.lawsuit || '', atlas_client_id: caixa.dataset.client || '',
        dados: { motivo: el.motivo.value.trim(), finalidade: el.finalidade.value.trim(),
          ...(el.modelo.value === 'DECISAO' ? { tipo_decisao: el.tipo_decisao.value, resultado: el.resultado.value } : {}) }, decisoes
      };
      btCriar.disabled = true;
      try { const d = await rpc(ctx, 'wf_iniciar', { p_campos: campos }); caixa.textContent = ''; aoCriar(d.id); }
      catch (e) { m.textContent = msgErro(e); btCriar.disabled = false; }
    } },
      h('h2', {}, 'Triagem da intimação'),
      h('p', { class: 'sutil' }, 'Campos obrigatórios da especificação. Com prazo judicial, o fluxo só abre com o PF validado (Regra 04). A mesma intimação não abre dois fluxos ativos (Regra 05).'),
      // ordem pedida pela controladoria (27/11/2026): origem → processo e cliente → inteiro teor → fluxo
      h('div', { class: 'filtros-barra' }, campo('Origem', el.origem_tipo), campo('Identificador', el.origem_id), btBuscar), dica,
      h('div', { class: 'filtros-barra' }, campo('Processo (CNJ)', el.cnj), campo('Cliente no sistema', el.cliente, true)),
      teor,
      h('div', { class: 'filtros-barra' }, campo('Fluxo', el.modelo, true)), caixaDecisao, linhaNatureza,
      h('div', { class: 'filtros-barra' }, campo('Equipe', el.equipe_id), campo('Advogado responsável', el.advogado_colaborador_id)),
      h('div', { class: 'filtros-barra' }, campo('Modalidade', el.modalidade_intimacao), campo('Recebida em', el.data_recebimento), campo('Publicação ou ciência', el.data_ciencia)),
      h('div', { class: 'filtros-barra' }, h('label', { class: 'filtro-check' }, el.tem_prazo, ' Tem prazo judicial'), h('label', { class: 'filtro-check' }, el.prazo_em_dobro, ' Prazo em dobro'),
        campo('Prazo legal (dias)', el.prazo_legal_dias), campo('Prazo fatal (PF)', el.pf), btSugerir),
      h('div', { class: 'filtros-barra' }, campo('Link da intimação', el.link_intimacao, true)),
      h('div', { class: 'filtros-barra' }, campo('Motivo da comunicação', el.motivo, true), campo('Finalidade dos documentos', el.finalidade, true)),
      h('p', {}, h('strong', {}, 'Decisões já conhecidas na triagem (opcional)')), caixaPerg,
      h('div', { class: 'acoes' }, btCriar), m));
    trocarModelo();
    if (pre && pre.origem_tipo && pre.origem_id) {
      el.origem_tipo.value = pre.origem_tipo; el.origem_id.value = String(pre.origem_id);
      el.origem_tipo.disabled = true; el.origem_id.readOnly = true;
      if (pre.modalidade) el.modalidade_intimacao.value = pre.modalidade;
      btBuscar.click();
    }
  }

  // Tratar uma intimação a partir das listas (Intimações CNJ, Publicações Webjur): triagem numa janela, já com os dados.
  let dlgTratar = null;
  function tratar(ctx, pre, aoCriar) {
    if (!dlgTratar) { dlgTratar = h('dialog', { class: 'detalhe', 'aria-labelledby': 'wf-tratar-titulo' }); document.body.append(dlgTratar); }
    dlgTratar.textContent = '';
    const corpo = h('div', { class: 'detalhe-corpo' });
    dlgTratar.append(h('div', { class: 'detalhe-topo' },
      h('div', {}, h('h2', { id: 'wf-tratar-titulo' }, 'Tratar intimação'), h('p', { class: 'sutil' }, pre.titulo || '')),
      h('button', { type: 'button', class: 'btn btn-sec btn-peq', onclick: () => dlgTratar.close() }, 'Fechar')), corpo);
    dlgTratar.showModal();
    formTriagem(corpo, ctx, id => {
      corpo.textContent = '';
      corpo.append(aviso('ok', `Fluxo #${id} aberto. A primeira tarefa vai para o Atlas no próximo ciclo (até 10 minutos).`),
        h('div', { class: 'acoes' }, h('button', { type: 'button', class: 'btn', onclick: () => { dlgTratar.close(); abrirFluxo(id); } }, 'Ver o fluxo'),
          h('button', { type: 'button', class: 'btn btn-sec', onclick: () => dlgTratar.close() }, 'Continuar na lista')));
      if (aoCriar) aoCriar(id);
    }, pre);
  }

  // abre a área de Workflows já no detalhe de um fluxo
  let fluxoPedido = null;
  function abrirFluxo(id) { fluxoPedido = id; if (location.hash === '#/workflows') window.dispatchEvent(new HashChangeEvent('hashchange')); else location.hash = '#/workflows'; }

  // situação de tratamento de cada intimação de uma lista: { origem_id: { id, status, modelo } }
  async function fluxosPorOrigem(ctx, tipo, ids) {
    if (!ids.length) return {};
    try { return await rpc(ctx, 'wf_fluxos_por_origem', { p_origem_tipo: tipo, p_ids: ids.map(String) }) || {}; }
    catch (e) { return { _erro: msgErro(e) }; }
  }
  // célula "Tratamento" das listas de intimações
  function celulaTratamento(ctx, fluxo, pre, admin, aoCriar) {
    if (fluxo) return h('button', { type: 'button', class: 'tag tag-botao ' + (fluxo.status === 'ativo' ? 'tag-ok' : 'tag-neutra'), title: fluxo.modelo || '',
      onclick: () => abrirFluxo(fluxo.id) }, `Fluxo #${fluxo.id} · ${FLUXO[fluxo.status] || fluxo.status}`);
    if (!admin) return h('span', { class: 'tag tag-alerta' }, 'Sem tratamento');
    return h('button', { type: 'button', class: 'btn btn-peq', onclick: () => tratar(ctx, pre, aoCriar) }, 'Tratar');
  }

  // ------------------------------------------------------------ assistentes das equipes
  async function desenharConfig(caixa, ctx) {
    caixa.textContent = '';
    let cfg;
    try { cfg = await rpc(ctx, 'wf_configuracao'); } catch (e) { caixa.append(aviso('erro', msgErro(e))); return; }
    const linhas = cfg.equipes.map(e => {
      const selC = h('select', { 'aria-label': 'Assistente da equipe ' + e.equipe }, h('option', { value: '' }, 'Sem assistente'),
        cfg.colaboradores.map(c => h('option', { value: c.id, selected: c.id === e.colaborador_id }, c.nome)));
      const selU = h('select', { 'aria-label': 'Usuário do Atlas' }, h('option', { value: '' }, 'Manter o atual'),
        cfg.usuarios_atlas.map(u => h('option', { value: u.atlas_user_id }, `${u.nome} (${u.atlas_user_id.slice(0, 8)})${u.colaborador ? ' — ligado a ' + u.colaborador : ''}`)));
      const mot = h('input', { type: 'text', placeholder: 'Motivo (mín. 10 caracteres)', 'aria-label': 'Motivo' });
      const m = h('span', { class: 'erro', 'aria-live': 'polite' });
      const bt = h('button', { type: 'button', class: 'btn btn-sec btn-peq', onclick: async () => {
        bt.disabled = true; m.textContent = '';
        try {
          await rpc(ctx, 'admin_definir_assistente', { p_equipe: e.equipe_id, p_colaborador: selC.value ? Number(selC.value) : null,
            p_atlas_user: selU.value || null, p_motivo: mot.value });
          desenharConfig(caixa, ctx);
        } catch (err) { m.textContent = msgErro(err); bt.disabled = false; }
      } }, 'Salvar');
      return h('tr', {}, h('td', { 'data-rotulo': 'Equipe' }, e.equipe),
        h('td', { 'data-rotulo': 'Situação' }, !e.colaborador_id ? h('span', { class: 'tag tag-erro' }, 'Sem assistente')
          : !e.atlas_user_id ? h('span', { class: 'tag tag-erro' }, 'Sem usuário do Atlas') : h('span', { class: 'tag tag-ok' }, 'Pronta')),
        h('td', { 'data-rotulo': 'Líder' }, e.lider || h('span', { class: 'tag tag-erro' }, 'Sem líder')),
        h('td', { 'data-rotulo': 'Assistente' }, selC), h('td', { 'data-rotulo': 'Usuário do Atlas' }, selU),
        h('td', { 'data-rotulo': 'Motivo' }, mot), h('td', {}, bt, m));
    });
    caixa.append(h('details', { class: 'cartao', open: cfg.equipes.some(e => !e.atlas_user_id && e.colaborador_id || !e.colaborador_id) },
      h('summary', {}, 'Assistentes e líderes das equipes'),
      h('p', { class: 'sutil' }, 'A assistente recebe as etapas de comunicação e de documentos. Ela precisa ter usuário no Atlas: escolha a conta entre as que a API do Atlas informou (produtividade). ',
        `Etapas da controladoria vão para ${cfg.controladoria_email || '(e-mail não configurado)'}. `,
        'O líder aprova as dispensas de recurso; ele é definido em Usuários e permissões e também precisa de usuário no Atlas.'),
      h('div', { class: 'tab-rolagem' }, h('table', { class: 'tab tab-compacta' },
        h('thead', {}, h('tr', {}, ['Equipe', 'Situação', 'Líder', 'Assistente', 'Usuário do Atlas', 'Motivo', ''].map(t => h('th', { scope: 'col' }, t)))),
        h('tbody', {}, linhas)))));
  }

  window.Workflows = { abrir, tratar, abrirFluxo, fluxosPorOrigem, celulaTratamento };
})();
