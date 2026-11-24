/* Painel de audiências (14/11/2026, migração 0051). As audiências vêm das intimações do CNJ e da Webjur:
 * o robô lê o texto e extrai data, hora, tipo, modalidade e link. O painel mostra a agenda por dia e equipe,
 * cobra as pendências (sem data, sem advogado, sem confirmação, sem tarefa no Atlas, sem ata) e registra a ata.
 * Toda permissão é decidida no banco: controladoria e líder da equipe designam e corrigem; o advogado designado
 * confirma e registra a ata; a diretoria lê. */
(function () {
  'use strict';
  const { h, num, data, dataHora, aviso } = UI;
  const msgErro = e => (e && (e.message || e.erro)) || String(e);
  const hojeISO = () => new Date().toLocaleDateString('sv-SE', { timeZone: 'America/Sao_Paulo' });
  const somaDias = (iso, n) => { const d = new Date(iso + 'T12:00:00'); d.setDate(d.getDate() + n); return d.toISOString().slice(0, 10); };
  const DIAS = ['domingo', 'segunda-feira', 'terça-feira', 'quarta-feira', 'quinta-feira', 'sexta-feira', 'sábado'];
  const PEND = {
    sem_data: 'Sem data na intimação', sem_advogado: 'Sem advogado', sem_confirmacao: 'Sem confirmação',
    sem_tarefa_atlas: 'Sem tarefa no Atlas', sem_ata: 'Sem ata/resultado'
  };
  const RESULTADOS = { acordo: 'Acordo', sem_acordo: 'Sem acordo', instrucao_concluida: 'Instrução concluída', redesignada: 'Redesignada', nao_realizada: 'Não realizada' };
  const SITUACAO = { agendada: 'Agendada', redesignada: 'Redesignada', cancelada: 'Cancelada', realizada: 'Realizada', nao_realizada: 'Não realizada' };

  async function abrir(raiz, ctx) {
    const admin = ctx.perfil.papel === 'admin';
    const f = { inicio: somaDias(hojeISO(), -7), fim: somaDias(hojeISO(), 60), equipe: '', pendencia: '', busca: '' };
    let advogados = null;
    raiz.append(h('h1', {}, 'Audiências'),
      h('p', { class: 'subtitulo' }, 'Intimações do CNJ e da Webjur'),
      h('p', { class: 'sutil' }, 'O robô lê as intimações (a cada hora e no double check das 18:30) e monta a agenda com data, hora, tipo, modalidade e link. ',
        'Quando a intimação não traz a data (ex.: "audiência designada" no Projudi ou no eproc), a audiência fica como "sem data" até alguém completar. ',
        'A equipe vem da letra do código do cliente (C = Celeste, P = Prime, G = Gold, E = Êxitos, D = Delta).'));
    const topo = h('div'), corpo = h('div'); raiz.append(topo, corpo);
    const saida = h('div', { 'aria-live': 'polite' });
    if (admin) {
      const b = h('button', { type: 'button', class: 'btn btn-sec', onclick: async () => {
        b.disabled = true; saida.textContent = '';
        const { data: r, error } = await ctx.sb.rpc('audiencias_ler');
        b.disabled = false;
        if (error) { saida.append(aviso('erro', msgErro(error))); return; }
        saida.append(aviso('ok', `${num(r.lidas)} intimação(ões) lidas; ${num(r.com_audiencia)} com audiência; ${num(r.novas)} audiência(s) nova(s).`)); desenhar();
      } }, 'Ler intimações agora');
      topo.append(h('div', { class: 'acoes' }, b), saida);
    } else topo.append(saida);

    const campo = (rot, el) => h('label', { class: 'filtro' }, h('span', {}, rot), el);
    const ini = h('input', { type: 'date', value: f.inicio }), fim = h('input', { type: 'date', value: f.fim });
    const selEq = h('select', {}, h('option', { value: '' }, 'Todas'));
    const selPend = h('select', {}, h('option', { value: '' }, 'Todas'), Object.entries(PEND).map(([v, t]) => h('option', { value: v }, t)));
    const busca = h('input', { type: 'search', placeholder: 'Processo ou texto', 'aria-label': 'Buscar' });
    topo.append(h('form', { class: 'filtros-barra', onsubmit: e => { e.preventDefault();
        Object.assign(f, { inicio: ini.value, fim: fim.value, equipe: selEq.value, pendencia: selPend.value, busca: busca.value }); desenhar(); } },
      campo('De', ini), campo('Até', fim), campo('Equipe', selEq), campo('Pendência', selPend), campo('Busca', busca),
      h('button', { type: 'submit', class: 'btn btn-sec' }, 'Filtrar')));

    async function desenhar() {
      corpo.textContent = ''; corpo.append(h('p', { class: 'sutil' }, 'Carregando…'));
      let r;
      try {
        const { data: d, error } = await ctx.sb.rpc('audiencias_painel', { p_inicio: f.inicio || null, p_fim: f.fim || null,
          p_equipe: f.equipe || null, p_pendencia: f.pendencia || null, p_busca: f.busca || null });
        if (error) throw error; r = d;
      } catch (e) { corpo.textContent = ''; corpo.append(aviso('erro', msgErro(e))); return; }
      if (r.pode_editar && !advogados) { const { data: a } = await ctx.sb.rpc('audiencias_advogados'); advogados = a || []; }
      corpo.textContent = '';
      const atual = selEq.value; selEq.textContent = ''; selEq.append(h('option', { value: '' }, 'Todas'), ...r.equipes.map(e => h('option', { value: e }, e))); selEq.value = atual;
      selPend.value = f.pendencia;
      const c = r.contagem;
      const k = (pend, rot, valor, atencao) => h('button', { type: 'button', class: 'kpi' + (atencao ? ' kpi-atencao' : '') + (f.pendencia === pend ? ' kpi-ativo' : ''),
        onclick: () => { f.pendencia = f.pendencia === pend ? '' : pend; desenhar(); } },
        h('span', { class: 'kpi-rotulo' }, rot), h('span', { class: 'kpi-valor' }, num(valor)));
      corpo.append(h('section', { class: 'kpis' },
        k('', 'Próximos 7 dias', c.proximos_7),
        k('sem_data', 'Sem data na intimação', c.sem_data, c.sem_data > 0),
        k('sem_advogado', 'Sem advogado', c.sem_advogado, c.sem_advogado > 0),
        k('sem_confirmacao', 'Sem confirmação', c.sem_confirmacao, c.sem_confirmacao > 0),
        k('sem_tarefa_atlas', 'Sem tarefa no Atlas', c.sem_tarefa_atlas, c.sem_tarefa_atlas > 0),
        k('sem_ata', 'Sem ata/resultado', c.sem_ata, c.sem_ata > 0)));
      corpo.append(h('p', { class: 'sutil' }, r.ultima_leitura ? `Última leitura das intimações: ${dataHora(r.ultima_leitura)}.` : 'As intimações ainda não foram lidas.'));
      if (!r.itens.length) { corpo.append(aviso('info', 'Nenhuma audiência no período e filtros escolhidos.')); return; }

      // agenda por dia (sem data primeiro: precisam ser completadas)
      const grupos = new Map();
      for (const a of r.itens) { const g = a.data || ''; if (!grupos.has(g)) grupos.set(g, []); grupos.get(g).push(a); }
      for (const [dia, itens] of grupos) {
        const titulo = dia ? `${data(dia)} — ${DIAS[new Date(dia + 'T12:00:00').getDay()]}` + (dia === hojeISO() ? ' (hoje)' : '') : 'Sem data na intimação (completar)';
        corpo.append(h('section', { class: 'cartao' + (dia ? '' : ' cartao-alerta') }, h('h2', {}, titulo), ...itens.map(a => linha(a))));
      }
    }

    function linha(a) {
      const tags = a.pendencias.map(p => h('span', { class: 'tag tag-erro' }, PEND[p] || p));
      if (a.situacao !== 'agendada') tags.unshift(h('span', { class: a.situacao === 'realizada' ? 'tag tag-ok' : 'tag' }, SITUACAO[a.situacao] || a.situacao));
      if (a.confirmada_em) tags.push(h('span', { class: 'tag tag-ok' }, 'Confirmada'));
      const el = h('article', { class: 'audiencia' },
        h('div', { class: 'audiencia-hora' }, a.hora || '—'),
        h('div', { class: 'audiencia-corpo' },
          h('p', { class: 'audiencia-titulo' }, h('b', {}, a.tipo || 'Audiência (tipo não informado)'), ' · ',
            a.modalidade ? a.modalidade : 'modalidade não informada',
            a.link ? [' · ', h('a', { href: a.link, target: '_blank', rel: 'noopener noreferrer' }, 'link da sala')] : null),
          h('p', {}, h('span', { class: 'nowrap' }, a.cnj), ' · ', a.cliente || 'cliente não identificado', ' · ', a.equipe || 'sem equipe',
            a.orgao ? ' · ' + a.orgao : ''),
          h('p', { class: 'sutil' }, 'Advogado: ', a.advogado || '—', a.preposto ? ' · Preposto: ' + a.preposto : '',
            a.confirmacao_obs ? ' · ' + a.confirmacao_obs : ''),
          h('p', {}, tags),
          a.resultado ? h('p', {}, h('b', {}, 'Resultado: '), RESULTADOS[a.resultado] || a.resultado, ' — ', a.ata) : null,
          acoes(a)));
      return el;
    }

    function acoes(a) {
      const caixa = h('div', { class: 'audiencia-acoes' });
      caixa.append(h('details', {}, h('summary', {}, 'Ver intimação'),
        h('p', { class: 'teor-cnj' }, a.trecho || ''),
        h('p', { class: 'sutil' }, 'Fontes: ', (a.fontes || []).map((s, i) => [i ? ' · ' : '',
          s.link ? h('a', { href: s.link, target: '_blank', rel: 'noopener noreferrer' }, `CNJ ${data(s.disp)}`) : `${s.origem === 'cnj' ? 'CNJ' : 'Webjur'} ${data(s.disp)}`]))));
      if (a.pode_editar && a.situacao === 'agendada') {
        const sel = h('select', { 'aria-label': 'Advogado' }, h('option', { value: '' }, '— advogado —'),
          (advogados || []).map(x => h('option', { value: x.id, selected: x.id === a.advogado_id }, x.nome)));
        const prep = h('input', { type: 'text', placeholder: 'Preposto (opcional)', value: a.preposto || '', 'aria-label': 'Preposto' });
        caixa.append(form('Designar advogado/preposto', [sel, prep], 'Salvar', () =>
          rpc('audiencia_designar', { p_id: a.id, p_advogado_id: sel.value ? Number(sel.value) : null, p_preposto: prep.value }, 'Designação salva.')));
        const dt = h('input', { type: 'date', value: a.data || '' }), hr = h('input', { type: 'time', value: a.hora || '' });
        const tp = h('input', { type: 'text', value: a.tipo || '', placeholder: 'Tipo', 'aria-label': 'Tipo' });
        const md = h('select', { 'aria-label': 'Modalidade' }, ['', 'presencial', 'virtual', 'híbrida'].map(v => h('option', { value: v, selected: v === (a.modalidade || '') }, v || '— modalidade —')));
        const lk = h('input', { type: 'url', value: a.link || '', placeholder: 'Link da sala', 'aria-label': 'Link' });
        const mo = h('input', { type: 'text', placeholder: 'Motivo (ex.: data conferida no processo)', 'aria-label': 'Motivo' });
        caixa.append(form(a.data ? 'Corrigir data, hora ou modalidade' : 'Completar a data', [dt, hr, tp, md, lk, mo], 'Salvar', () =>
          rpc('audiencia_corrigir', { p_id: a.id, p_data: dt.value || null, p_hora: hr.value || null, p_tipo: tp.value, p_modalidade: md.value || null,
                                      p_link: lk.value, p_motivo: mo.value }, 'Audiência corrigida.')));
      }
      if (a.pode_ata && a.situacao === 'agendada' && a.advogado_id && !a.confirmada_em) {
        const ob = h('input', { type: 'text', placeholder: 'Observação (ex.: cliente avisado)', 'aria-label': 'Observação da confirmação' });
        caixa.append(form('Confirmar presença', [ob], 'Confirmar', () => rpc('audiencia_confirmar', { p_id: a.id, p_obs: ob.value }, 'Audiência confirmada.')));
      }
      if (a.pode_ata && a.data && a.data <= hojeISO() && a.situacao === 'agendada') {
        const rs = h('select', { 'aria-label': 'Resultado' }, Object.entries(RESULTADOS).map(([v, t]) => h('option', { value: v }, t)));
        const at = h('textarea', { rows: 3, placeholder: 'O que aconteceu na audiência (mínimo 20 caracteres)', 'aria-label': 'Ata' });
        caixa.append(form('Registrar ata e resultado', [rs, at], 'Registrar', () =>
          rpc('audiencia_registrar_resultado', { p_id: a.id, p_resultado: rs.value, p_ata: at.value }, 'Ata registrada.')));
      }
      return caixa;
    }

    function form(titulo, campos, rotulo, fn) {
      return h('details', {}, h('summary', {}, titulo),
        h('form', { class: 'form-linha', onsubmit: async e => { e.preventDefault(); await fn(); } }, ...campos, h('button', { type: 'submit', class: 'btn btn-peq' }, rotulo)));
    }
    async function rpc(nome, args, msg) {
      saida.textContent = '';
      const { error } = await ctx.sb.rpc(nome, args);
      if (error) { saida.append(aviso('erro', msgErro(error))); saida.scrollIntoView({ block: 'nearest' }); return; }
      saida.append(aviso('ok', msg)); desenhar();
    }

    desenhar();
  }

  window.Audiencias = { abrir };
})();
