/* Processos não cadastrados (0064, 27/11/2026): processos que chegaram por intimação (CNJ ou Webjur) sem estar no Atlas.
 * O sistema procura o cliente nas partes da intimação: CPF/CNPJ citado ou nome idêntico a um nome da ficha do cliente
 * no Atlas, apontando para um só cliente = cadastro automático (robô do Atlas, em até 1 minuto). Nome só parecido,
 * mais de um cliente ou cliente com contrato rescindido = a controladoria confere; nenhum = a controladoria escolhe
 * (o robô não cria cliente). Toda permissão é decidida no banco. */
(function () {
  'use strict';
  const { h, num, data, dataHora, aviso, tabela } = UI;
  const msgErro = e => (e && (e.message || e.erro)) || String(e);
  const SIT = {
    sem_cliente: ['Aguardando cliente', 'tag-erro'], revisar: ['Conferir cliente', 'tag-alerta'], previa: ['Pronto para cadastrar', 'tag-alerta'],
    aprovado: ['Na fila do Atlas', 'tag-neutra'], enviando: ['Enviando ao Atlas', 'tag-neutra'], cadastrado: ['Cadastrado no Atlas', 'tag-ok'],
    no_atlas: ['Já estava no Atlas', 'tag-ok'], erro: ['Erro no cadastro', 'tag-erro']
  };
  const GRUPOS = [['', 'Todos'], ['aguardando_cliente', 'Aguardando cliente'], ['revisar', 'Conferir cliente'], ['prontos', 'Prontos para cadastrar'], ['na_fila', 'Na fila do Atlas'],
    ['cadastrados', 'Cadastrados'], ['ja_estavam', 'Já estavam no Atlas'], ['erro', 'Com erro']];
  const POLO = { A: 'ativo', P: 'passivo' };
  const tag = st => { const [t, c] = SIT[st] || [st, 'tag-neutra']; return h('span', { class: 'tag ' + c }, t); };

  async function abrir(raiz, ctx) {
    const admin = ctx.perfil.papel === 'admin';
    const f = { grupo: '', busca: '' };
    const rpc = async (fn, args) => { const { data: d, error } = await ctx.sb.rpc(fn, args || {}); if (error) throw new Error(error.message); return d; };
    raiz.append(h('h1', {}, 'Processos não cadastrados'),
      h('p', { class: 'subtitulo' }, 'Intimações de processos que não estavam no Atlas'),
      h('p', { class: 'sutil' }, 'Quando chega intimação (CNJ ou Webjur) de processo que não está no Atlas, o sistema procura o cliente nas partes da intimação. ',
        'CPF/CNPJ citado, ou nome idêntico a um nome da ficha do cliente no Atlas (um só cliente), vai direto para o cadastro pela API. ',
        'Nome só parecido, mais de um cliente possível ou contrato rescindido: a controladoria confere. Cliente que não existe no Atlas: cadastre o cliente lá e escolha aqui. ',
        'A procura roda a cada 15 minutos; o robô cadastra em até 1 minuto.'));
    const topo = h('div'), corpo = h('div'); raiz.append(topo, corpo);
    if (admin) {
      const saida = h('div', { 'aria-live': 'polite' });
      const bt = h('button', { type: 'button', class: 'btn btn-sec', onclick: async () => {
        bt.disabled = true; saida.textContent = '';
        try {
          const r = await rpc('cnj_cadastro_detectar');
          saida.append(aviso('ok', `${num(r.novos)} processo(s) novo(s); ${num(r.aprovados_automaticamente)} enviado(s) para o cadastro automático; `,
            `${num(r.revisar)} para conferir e ${num(r.sem_cliente)} aguardando cliente.`, r.automatico_ligado ? '' : ' Cadastro automático desligado (parâmetro cnj_cadastro_automatico).'));
          desenhar();
        } catch (e) { saida.append(aviso('erro', msgErro(e))); }
        bt.disabled = false;
      } }, 'Procurar agora');
      topo.append(h('div', { class: 'acoes' }, bt), saida);
    }
    const selG = h('select', {}, GRUPOS.map(([v, t]) => h('option', { value: v }, t)));
    const busca = h('input', { type: 'search', placeholder: 'Processo, cliente ou parte', 'aria-label': 'Buscar' });
    topo.append(h('form', { class: 'filtros-barra', onsubmit: e => { e.preventDefault(); f.grupo = selG.value; f.busca = busca.value; desenhar(); } },
      h('label', { class: 'filtro' }, h('span', {}, 'Situação'), selG), h('label', { class: 'filtro' }, h('span', {}, 'Busca'), busca),
      h('button', { type: 'submit', class: 'btn btn-sec' }, 'Filtrar')));

    async function desenhar() {
      corpo.textContent = ''; corpo.append(h('p', { class: 'sutil' }, 'Carregando…'));
      let r;
      try { r = await rpc('cnj_nao_cadastrados', { p_grupo: f.grupo || null, p_busca: f.busca || null, p_limite: 1000 }); }
      catch (e) { corpo.textContent = ''; corpo.append(aviso('erro', msgErro(e))); return; }
      corpo.textContent = '';
      const c = r.contagem || {};
      const k = (rot, v, grupo, desc, at) => h('button', { type: 'button', class: 'kpi' + (f.grupo === grupo ? ' kpi-ativo' : '') + (at ? ' kpi-atencao' : ''),
        onclick: () => { f.grupo = grupo; selG.value = grupo; desenhar(); } },
        h('span', { class: 'kpi-rotulo' }, rot), h('span', { class: 'kpi-valor' }, num(v)), desc ? h('span', { class: 'kpi-desc' }, desc) : null);
      corpo.append(h('section', { class: 'kpis' },
        k('Processos que não estavam no Atlas', c.total, '', 'desde a primeira intimação registrada'),
        k('Aguardando cliente', c.aguardando_cliente, 'aguardando_cliente', 'cliente não encontrado no Atlas', c.aguardando_cliente > 0),
        k('Prontos para cadastrar', c.prontos, 'prontos', 'cliente encontrado: confira e cadastre', c.prontos > 0),
        k('Conferir cliente', c.revisar, 'revisar', 'sugestão para confirmar', c.revisar > 0),
        k('Na fila do Atlas', c.na_fila, 'na_fila'),
        k('Cadastrados', c.cadastrados, 'cadastrados', `${num(c.automaticos)} automaticamente`),
        k('Com erro', c.erro, 'erro', '', c.erro > 0)));
      corpo.append(h('p', { class: 'sutil' }, r.automatico ? 'Cadastro automático: ligado.' : 'Cadastro automático: desligado — os processos com cliente encontrado ficam em "Prontos para cadastrar" até a controladoria confirmar.',
        r.ultima_execucao ? ` Última procura com novidade: ${dataHora(r.ultima_execucao)}.` : ''));
      // cadastrar de uma vez os prontos da lista (com confirmação: o Atlas não deixa excluir processo pela API)
      const prontos = r.itens.filter(i => i.situacao === 'previa').map(i => i.cnj);
      if (admin && prontos.length) {
        const conf = h('input', { type: 'checkbox', id: 'nc-conf' });
        const msg = h('span', { class: 'erro', 'aria-live': 'polite' });
        const bt = h('button', { type: 'button', class: 'btn', onclick: async () => {
          msg.textContent = '';
          if (!conf.checked) { msg.textContent = 'Marque a confirmação: o Atlas não deixa excluir processo pela API.'; return; }
          bt.disabled = true;
          try { const x = await rpc('atlas_cadastro_aprovar', { p_cnjs: prontos, p_todos: false }); msg.textContent = ''; corpo.prepend(aviso('ok', `${num(x.aprovados)} processo(s) enviado(s) para o cadastro no Atlas.`)); desenhar(); }
          catch (e) { msg.textContent = msgErro(e); bt.disabled = false; }
        } }, `Cadastrar no Atlas os ${prontos.length} prontos desta lista`);
        corpo.append(h('div', { class: 'acoes barra-lote' }, h('label', { class: 'filtro-check', for: 'nc-conf' }, conf,
          ' Conferi os clientes; o Atlas não permite excluir processo pela API'), bt, msg));
      }
      if ((r.por_mes || []).length || (r.por_tribunal || []).length) {
        corpo.append(h('details', { class: 'cartao' }, h('summary', {}, 'Volume por mês e por tribunal'),
          h('div', { class: 'grade-2' },
            tabela([{ titulo: 'Mês da 1ª intimação', valor: x => x.mes.split('-').reverse().join('/') },
                    { titulo: 'Processos', num: true, valor: x => num(x.total) },
                    { titulo: 'Já no Atlas', num: true, valor: x => num(x.cadastrados) }], r.por_mes, { compacta: true }),
            tabela([{ titulo: 'Tribunal', valor: x => x.tribunal }, { titulo: 'Processos', num: true, valor: x => num(x.total) }], r.por_tribunal, { compacta: true }))));
      }
      corpo.append(tabela([
        { titulo: 'Processo', valor: i => h('span', {}, h('span', { class: 'nowrap' }, i.cnj), h('br'),
            h('span', { class: 'sutil' }, [i.tribunal, (i.fontes || []).map(x => x === 'cnj' ? 'CNJ' : 'Webjur').join(' e ')].filter(Boolean).join(' · '))) },
        { titulo: '1ª intimação', valor: i => h('span', {}, data(i.primeira_intimacao), h('br'), h('span', { class: 'sutil' }, `${num(i.intimacoes)} intimação(ões)`)) },
        { titulo: 'Classe / órgão', valor: i => [i.classe, i.orgao].filter(Boolean).join(' — ') || '—' },
        { titulo: 'Partes', larga: true, valor: i => (i.partes || []).length
            ? h('ul', { class: 'lista-simples' }, i.partes.map(p => h('li', {}, p.nome, p.polo ? h('span', { class: 'sutil' }, ` (polo ${POLO[p.polo] || p.polo})`) : null)))
            : h('span', { class: 'sutil' }, i.cliente_advbox ? 'ADVBOX: ' + i.cliente_advbox : 'sem partes na intimação') },
        { titulo: 'Situação', valor: i => h('span', {}, tag(i.situacao), i.automatico && ['aprovado', 'enviando', 'cadastrado'].includes(i.situacao) ? h('span', { class: 'sutil' }, ' automático') : null,
            i.motivo ? h('p', { class: 'nota' }, i.motivo) : null, i.erro ? h('p', { class: 'nota nota-erro' }, i.erro) : null,
            i.cadastrado_em ? h('p', { class: 'sutil' }, 'em ' + dataHora(i.cadastrado_em)) : null) },
        { titulo: 'Cliente no Atlas', larga: true, valor: i => colunaCliente(i) }
      ], r.itens, { compacta: true, vazio: 'Nenhum processo nesta situação.' }));
    }

    function colunaCliente(i) {
      const caixa = h('div');
      if (i.cliente) caixa.append(h('div', {}, h('strong', {}, i.cliente)), h('div', { class: 'sutil' }, i.casado_por || ''));
      const pode = admin && ['sem_cliente', 'revisar', 'previa', 'erro'].includes(i.situacao);
      if (!pode) { if (!i.cliente) caixa.append(h('span', { class: 'sutil' }, '—')); return caixa; }
      const msg = h('p', { class: 'erro', 'aria-live': 'polite' });
      if (i.situacao === 'previa' && i.client_id) {
        const b = h('button', { type: 'button', class: 'btn btn-peq', onclick: async () => {
          b.disabled = true; msg.textContent = '';
          try { await rpc('atlas_cadastro_aprovar', { p_cnjs: [i.cnj], p_todos: false }); desenhar(); }
          catch (e) { msg.textContent = msgErro(e); b.disabled = false; }
        } }, 'Confirmar e cadastrar');
        caixa.append(h('div', { class: 'acoes' }, b));
      }
      const usar = async (cli, bt) => {
        bt.disabled = true; msg.textContent = '';
        try { await rpc('cnj_cadastro_escolher', { p_cnj: i.cnj, p_client_id: cli.id }); desenhar(); }
        catch (e) { msg.textContent = msgErro(e); bt.disabled = false; }
      };
      if ((i.sugestoes || []).length) {
        caixa.append(h('p', { class: 'sutil' }, 'Sugestões pelas partes:'), h('ul', { class: 'lista-simples' }, i.sugestoes.map(sg => {
          const b = h('button', { type: 'button', class: 'btn btn-sec btn-peq', onclick: ev => usar(sg, ev.currentTarget) }, 'Usar e cadastrar');
          return h('li', {}, sg.nome, h('span', { class: 'sutil' }, ` — ${sg.por}${sg.parte ? ' (' + sg.parte + ')' : ''}${sg.rescindido ? ', contrato rescindido' : ''} `), b);
        })));
      }
      const termo = h('input', { type: 'search', placeholder: 'Nome, código (C362) ou CPF/CNPJ', 'aria-label': 'Buscar cliente do Atlas para ' + i.cnj });
      const res = h('div');
      const buscar = async () => {
        res.textContent = ''; msg.textContent = '';
        try {
          const cs = await rpc('atlas_clientes_buscar', { p_busca: termo.value });
          if (!cs.length) { res.append(h('p', { class: 'sutil' }, 'Nenhum cliente do Atlas com esse termo (mínimo de 3 letras). Se ele não existir, cadastre no Atlas: a lista de clientes é relida toda noite.')); return; }
          res.append(h('ul', { class: 'lista-simples' }, cs.map(cl => h('li', {}, cl.nome, ' ',
            h('button', { type: 'button', class: 'btn btn-sec btn-peq', onclick: ev => usar(cl, ev.currentTarget) }, 'Usar e cadastrar')))));
        } catch (e) { msg.textContent = msgErro(e); }
      };
      caixa.append(h('details', {}, h('summary', {}, 'Escolher outro cliente'),
        h('form', { class: 'filtros-barra', onsubmit: e => { e.preventDefault(); buscar(); } }, termo, h('button', { type: 'submit', class: 'btn btn-sec btn-peq' }, 'Buscar')), res), msg);
      return caixa;
    }
    desenhar();
  }

  window.NaoCadastrados = { abrir };
})();
