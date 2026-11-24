/* Áreas 1 e 2 — Visão geral (§12) e Indicadores por colaborador (§13).
 * Todos os números vêm de indicadores_resumo / indicadores_por_colaborador, que contam
 * exatamente os registros devolvidos pelo detalhamento (indicadores_registros). */
(function () {
  'use strict';
  const { h, num, data, aviso, tabela } = UI;
  const C = () => window.Comum;

  const POSICAO = [
    ['pendentes', 'Pendentes na exportação mais recente'],
    ['vencidas', 'Pendentes com o PF da Tarefa (ADVBOX) já passado'],
    ['pf_judicial_vencido_conferir', 'PF Judicial anotado já passou: conferir (não é perda de prazo presumida)'],
    ['vencem_hoje', 'PF da Tarefa ou PF Judicial vence hoje'],
    ['d4_criticas', 'D-4 atingido e PF Judicial ainda não vencido'],
    ['sem_inicio', 'Pendentes sem início da tratativa registrado'],
    ['sem_inicio_24h', 'Abertura lida pela extensão há mais de 24 h, sem início']
  ];
  const PERIODO = [
    ['concluidas', 'Conclusões registradas no período'],
    ['protocolos_realizados', 'Tarefas PROTOCOLO concluídas'],
    ['distribuicoes_realizadas', 'Tarefas DISTRIBUIÇÃO - NOVO PROCESSO concluídas'],
    ['pedidos_reagendamento', 'Pedidos identificados no texto — não são alterações'],
    ['reagendamentos_efetivados', 'Data da agenda efetivamente alterada entre importações']
  ];
  const CRITICOS = new Set(['pf_judicial_vencido_conferir', 'vencem_hoje', 'd4_criticas']);

  async function visaoGeral(raiz, ctx) {
    raiz.append(h('h1', {}, 'Visão geral'), h('p', { class: 'sutil' }, 'Clique em qualquer número para ver os registros que o compõem.'));
    const filtros = h('div'), corpo = h('div');
    raiz.append(filtros, corpo);
    filtros.append(await C().barraFiltros(ctx, { rotuloPeriodo: 'Período (conclusões, protocolos, reagendamentos)' }, () => desenhar()));
    async function desenhar() {
      corpo.textContent = ''; corpo.append(h('p', { class: 'sutil' }, 'Calculando…'));
      const p = C().params();
      const [r, d, pc] = await Promise.all([ctx.sb.rpc('indicadores_resumo', p), ctx.sb.rpc('indicadores_concluidas_por_dia', p), ctx.sb.rpc('indicadores_por_colaborador', p)]);
      corpo.textContent = '';
      const erro = r.error || d.error || pc.error;
      if (erro) { corpo.append(aviso('erro', 'Não foi possível calcular os indicadores: ' + erro.message)); return; }
      const res = r.data, cont = res.contagens || {};
      corpo.append(...C().avisoBase(res));
      if (!res.dados_atualizados_em) return;
      if (!res.pendentes_com_abertura_conhecida && !res.pendentes_com_inicio)
        corpo.append(aviso('info', 'Início da tratativa, abertura há +24 h e tempos médios dependem da extensão no ADVBOX, ainda sem registros. Até lá, "Abertas sem início" inclui todas as pendentes.'));
      const cartao = ([k, desc]) => h('button', { type: 'button', class: 'kpi' + (CRITICOS.has(k) && cont[k] ? ' kpi-atencao' : ''), onclick: () => C().detalharIndicador(ctx, k) },
        h('span', { class: 'kpi-rotulo' }, C().rot('indicador', k)), h('span', { class: 'kpi-valor' }, num(cont[k] || 0)), h('span', { class: 'kpi-desc' }, desc));
      corpo.append(
        h('h2', { class: 'secao' }, 'Posição atual'), h('div', { class: 'kpis' }, POSICAO.map(cartao)),
        h('h2', { class: 'secao' }, `No período — ${data(p.p_inicio)} a ${data(p.p_fim)}`), h('div', { class: 'kpis' }, PERIODO.map(cartao)));
      const serie = d.data || [];
      corpo.append(C().comTabela('Tarefas concluídas por dia', C().graficoPorDia(serie),
        [{ titulo: 'Dia', valor: x => data(x.dia) }, { titulo: 'Concluídas', valor: x => num(x.concluidas), num: true }], serie));
      const cols = (pc.data || []).map(x => ({ ...x, concluidas: Number(x.concluidas), pendentes: Number(x.pendentes) }))
        .filter(x => x.concluidas || x.pendentes).sort((a, b) => b.pendentes - a.pendentes || b.concluidas - a.concluidas);
      corpo.append(cols.length ? C().comTabela('Concluídas x pendentes por colaborador', C().graficoPorColaborador(cols),
        [{ titulo: 'Colaborador', valor: x => x.responsavel }, { titulo: 'Concluídas no período', valor: x => num(x.concluidas), num: true },
         { titulo: 'Pendentes', valor: x => num(x.pendentes), num: true }], cols) : aviso('info', 'Sem tarefas para os filtros escolhidos.'));
      corpo.append(h('p', { class: 'sutil nota-rodape' }, 'Quantidade de tarefas não mede qualidade do trabalho. Conclusões são atribuídas ao Destinatário da exportação, porque o Excel não informa quem concluiu.'));
    }
    desenhar();
  }

  const COLS_COLAB = [
    ['concluidas', 'Concluídas'], ['pendentes', 'Pendentes'], ['vencidas', 'Vencidas'], ['vencem_hoje', 'Vencem hoje'],
    ['d4_criticas', 'D-4'], ['pf_judicial_vencido_conferir', 'PF Jud. vencido'], ['protocolos_realizados', 'Protocolos'],
    ['distribuicoes_realizadas', 'Distribuições'], ['pedidos_reagendamento', 'Pedidos reag.'], ['reagendamentos_efetivados', 'Reag. efetivados'],
    ['sem_inicio', 'Sem início'], ['sem_inicio_24h', 'Sem início +24 h']
  ];
  async function porColaborador(raiz, ctx) {
    raiz.append(h('h1', {}, 'Indicadores por colaborador'),
      h('p', { class: 'sutil' }, 'Eventos atribuídos ao responsável da tarefa no momento em que foram observados. Clique em um número para ver os registros.'));
    const filtros = h('div'), corpo = h('div'); raiz.append(filtros, corpo);
    let ordem = { k: 'pendentes', desc: true };
    filtros.append(await C().barraFiltros(ctx, { rotuloPeriodo: 'Período (eventos)' }, () => desenhar()));
    let dados = [], resumo = null;
    async function desenhar() {
      corpo.textContent = ''; corpo.append(h('p', { class: 'sutil' }, 'Calculando…'));
      const p = C().params();
      const [pc, r] = await Promise.all([ctx.sb.rpc('indicadores_por_colaborador', p), ctx.sb.rpc('indicadores_resumo', p)]);
      corpo.textContent = '';
      if (pc.error || r.error) { corpo.append(aviso('erro', (pc.error || r.error).message)); return; }
      dados = pc.data || []; resumo = r.data;
      render();
    }
    function render() {
      corpo.textContent = '';
      corpo.append(...C().avisoBase(resumo));
      const ord = [...dados].sort((a, b) => {
        const va = a[ordem.k], vb = b[ordem.k];
        const numerico = ordem.k !== 'responsavel';
        const c = numerico ? (va === null || va === undefined ? -1 : Number(va)) - (vb === null || vb === undefined ? -1 : Number(vb))
                           : String(va || '').localeCompare(String(vb || ''), 'pt-BR');
        return ordem.desc ? -c : c;
      });
      const cabec = (k, t) => h('button', { type: 'button', class: 'ord' + (ordem.k === k ? ' ativo' : ''), onclick: () => { ordem = { k, desc: ordem.k === k ? !ordem.desc : true }; render(); } },
        t, ordem.k === k ? (ordem.desc ? ' ↓' : ' ↑') : '');
      const celula = (l, k) => l[k] ? h('button', { type: 'button', class: 'link-num', onclick: () => C().detalharIndicador(ctx, k, { p_colaborador: l.responsavel_id }) }, num(l[k])) : '0';
      const media = (v, n) => v === null || v === undefined ? h('span', { class: 'sutil' }, 'sem dados') : h('span', {}, `${String(v).replace('.', ',')} h`, h('span', { class: 'sutil' }, ` (n=${n})`));
      const colunas = [{ titulo: cabec('responsavel', 'Colaborador'), valor: l => h('span', {}, l.responsavel, l.equipe ? h('span', { class: 'tag tag-neutra' }, l.equipe) : null), larga: true },
        ...COLS_COLAB.map(([k, t]) => ({ titulo: cabec(k, t), valor: l => celula(l, k), num: true })),
        { titulo: cabec('media_horas_abertura_inicio', 'Abertura → início'), valor: l => media(l.media_horas_abertura_inicio, l.n_abertura_inicio), num: true },
        { titulo: cabec('media_horas_inicio_conclusao', 'Início → conclusão'), valor: l => media(l.media_horas_inicio_conclusao, l.n_inicio_conclusao), num: true }];
      corpo.append(h('section', { class: 'cartao' }, tabela(colunas, ord, { compacta: true, vazio: 'Nenhum colaborador com tarefas nos filtros escolhidos.' })),
        h('p', { class: 'sutil nota-rodape' }, 'Tempos médios usam só tarefas com abertura lida na tela do ADVBOX e início registrado pela extensão (n = quantidade de tarefas na média). Produtividade quantitativa não mede qualidade.'));
    }
    desenhar();
  }

  window.Indicadores = { visaoGeral, porColaborador };
})();
