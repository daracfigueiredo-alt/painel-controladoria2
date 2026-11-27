/* Áreas 3, 4 e 5 — Prazos em risco (§11), Reagendamentos (§22) e Tratativa (§8.3).
 * Listagens filtradas no banco (total exato; até 500 linhas exibidas por vez). */
(function () {
  'use strict';
  const { h, num, data, dataHora, aviso, tabela } = UI;
  const C = () => window.Comum;
  const sel = (rotulo, opcoes, valor, aoMudar) => h('label', { class: 'filtro' }, h('span', {}, rotulo),
    h('select', { onchange: e => aoMudar(e.target.value || null) }, h('option', { value: '' }, 'Todas'),
      Object.entries(opcoes).map(([k, t]) => h('option', { value: k, selected: valor === k }, t))));
  const busca = (rotulo, valor, aoMudar) => { let t; return h('label', { class: 'filtro' }, h('span', {}, rotulo),
    h('input', { type: 'search', value: valor || '', placeholder: 'número CNJ', oninput: e => { clearTimeout(t); t = setTimeout(() => aoMudar(e.target.value.trim() || null), 350); } })); };
  const chips = (contagem, rotulos, ativo, aoMudar, total) => h('div', { class: 'filtros', role: 'group', 'aria-label': 'Filtrar por tipo' },
    h('button', { type: 'button', class: 'chip' + (!ativo ? ' ativo' : ''), 'aria-pressed': String(!ativo), onclick: () => aoMudar(null) }, `Todos (${num(total)})`),
    Object.entries(contagem).sort((a, b) => b[1] - a[1]).map(([k, n]) => h('button', { type: 'button', class: 'chip' + (ativo === k ? ' ativo' : ''),
      'aria-pressed': String(ativo === k), onclick: () => aoMudar(k) }, `${C().rot(rotulos, k)} (${num(n)})`)));
  const contagemTexto = r => h('p', { class: 'sutil' }, r.total > r.linhas.length ? `Mostrando ${num(r.linhas.length)} de ${num(r.total)}. Use os filtros para reduzir a lista.` : `${num(r.total)} registro(s).`);
  const ICONE = { critica: '●', alta: '▲', media: '■' };
  const critTag = c => h('span', { class: 'tag crit crit-' + c }, ICONE[c] + ' ' + C().rot('criticidade', c));

  // ---------------------------------------------------------------- Prazos em risco
  async function prazos(raiz, ctx) {
    const admin = ctx.perfil.papel === 'admin';
    const autorizaD4 = admin || ctx.perfil.papel === 'lider';   // 0037: exceção de D-4 (líder ou controladoria)
    const D4 = ['d4_vencido_sem_entrega', 'd4_hoje', 'd4_proximo'];
    const f = { categoria: null, criticidade: null, situacao: 'pendente_conferencia', grupo: null, processo: null, usarPeriodo: false };
    raiz.append(h('h1', {}, 'Prazos em risco'),
      h('p', { class: 'sutil' }, 'Alertas calculados sobre a base importada. PF Judicial vencido é pendência de conferência: a providência pode ter sido feita em outra tarefa da mesma pasta.'));
    const filtros = h('div'), corpo = h('div'); raiz.append(filtros, corpo);
    const chkPeriodo = h('label', { class: 'filtro filtro-check' }, h('input', { type: 'checkbox', onchange: e => { f.usarPeriodo = e.target.checked; desenhar(); } }), h('span', {}, 'Aplicar o período à data de referência'));
    filtros.append(await C().barraFiltros(ctx, { rotuloPeriodo: 'Período (data de referência do prazo)', extras: [
      chkPeriodo,
      sel('Criticidade', C().ROTULOS.criticidade, f.criticidade, v => { f.criticidade = v; desenhar(); }),
      sel('Situação', C().ROTULOS.conferencia, f.situacao, v => { f.situacao = v; desenhar(); }),
      sel('Grupo', C().ROTULOS.grupo, f.grupo, v => { f.grupo = v; desenhar(); }),
      busca('Processo', f.processo, v => { f.processo = v; desenhar(); })] }, () => desenhar()));
    async function desenhar() {
      corpo.textContent = ''; corpo.append(h('p', { class: 'sutil' }, 'Carregando…'));
      const p = C().params();
      const [{ data: r, error }, res] = await Promise.all([ctx.sb.rpc('prazos_risco_listar', {
        p_categoria: f.categoria, p_criticidade: f.criticidade, p_situacao_conferencia: f.situacao, p_grupo: f.grupo, p_processo: f.processo,
        p_equipe: p.p_equipe, p_colaborador: p.p_colaborador, p_inicio: f.usarPeriodo ? p.p_inicio : null, p_fim: f.usarPeriodo ? p.p_fim : null, p_limite: 500 }),
        ctx.sb.rpc('indicadores_resumo', p)]);
      corpo.textContent = '';
      if (error) { corpo.append(aviso('erro', error.message)); return; }
      if (f.categoria && !r.por_categoria[f.categoria]) { f.categoria = null; return desenhar(); }   // categoria esvaziada (ex.: após conferência)
      if (res.data) corpo.append(...C().avisoBase(res.data));
      const totalBase = Object.values(r.por_categoria).reduce((a, b) => a + b, 0);
      corpo.append(chips(r.por_categoria, 'categoria', f.categoria, v => { f.categoria = v; desenhar(); }, totalBase), contagemTexto(r),
        tabela([
          { titulo: 'Criticidade', valor: l => critTag(l.criticidade) },
          { titulo: 'Alerta', valor: l => h('span', {}, h('b', {}, C().rot('categoria', l.categoria)), h('br'), h('span', { class: 'sutil' }, l.motivo)), larga: true },
          { titulo: 'Data ref.', valor: l => data(l.data_referencia) },
          { titulo: 'Processo', valor: l => l.processo_cnj || '—' },
          { titulo: 'Compromisso', valor: l => l.compromisso || '—' },
          { titulo: 'Responsável', valor: l => l.responsavel || '—' },
          { titulo: 'Conferência', valor: l => h('span', {}, C().rot('conferencia', l.situacao_conferencia),
              l.conferencia_resultado ? h('span', { class: 'sutil' }, ` — ${C().rot('resultado', l.conferencia_resultado)}: ${l.conferencia_nota}`) : null) },
          ...(admin || autorizaD4 ? [{ titulo: '', valor: l => h('span', { class: 'acoes' },
              admin ? h('button', { type: 'button', class: 'btn btn-sec btn-peq', onclick: ev => conferir(ev.target, l) }, 'Registrar conferência') : null,
              autorizaD4 && l.tarefa_id && D4.includes(l.categoria)
                ? h('button', { type: 'button', class: 'btn btn-sec btn-peq', title: 'Exceção: a tarefa pode ser entregue depois do D-4',
                    onclick: ev => excecaoD4(ev.target, l.tarefa_id, true) }, 'Autorizar após o D-4') : null) }] : [])
        ], r.linhas, { compacta: true, vazio: 'Nenhum alerta com esses filtros.' }));
      if (autorizaD4 || ctx.perfil.papel === 'diretoria') await listarExcecoes();   // 0064: a diretoria também vê (só leitura)
      let rolar = null; try { rolar = sessionStorage.getItem('ctrl-rolar'); sessionStorage.removeItem('ctrl-rolar'); } catch (e) { /* */ }
      if (rolar === 'excecoes-d4') { const alvo = document.getElementById('excecoes-d4'); if (alvo) alvo.scrollIntoView({ block: 'start' }); }
    }
    // 0037: exceções de D-4 (entregas autorizadas depois do D-4). Saem dos alertas de D-4; o PF Judicial continua valendo.
    async function listarExcecoes() {
      const { data: lista, error } = await ctx.sb.rpc('excecoes_d4_listar');
      if (!error && !(lista || []).length) return;     // seção aparece só quando há exceção ativa
      corpo.append(h('h2', { class: 'secao', id: 'excecoes-d4' }, 'Entregas autorizadas depois do D-4'),
        h('p', { class: 'sutil' }, 'Exceções marcadas por líder ou pela controladoria, com justificativa. Essas tarefas saem dos alertas de D-4; o PF Judicial continua valendo.'));
      if (error) { corpo.append(aviso('erro', error.message)); return; }
      corpo.append(tabela([
        { titulo: 'Compromisso', valor: l => l.compromisso || l.id_externo || '—', larga: true },
        { titulo: 'Responsável', valor: l => l.responsavel || '—' },
        { titulo: 'D-4', valor: l => l.d4 ? data(l.d4) : '—' },
        { titulo: 'PF Judicial', valor: l => l.pf_judicial ? data(l.pf_judicial) : '—' },
        { titulo: 'Situação', valor: l => l.situacao === 'concluida' ? 'Concluída' : l.situacao === 'pendente' ? 'Pendente' : 'Fora da base atual' },
        { titulo: 'Autorizada por', valor: l => h('span', {}, l.por || '—', h('br'), h('span', { class: 'sutil' }, dataHora(l.em))) },
        { titulo: 'Justificativa', valor: l => l.justificativa, larga: true },
        { titulo: '', valor: l => h('button', { type: 'button', class: 'btn btn-sec btn-peq', onclick: ev => excecaoD4(ev.target, l.tarefa_id, false) }, 'Retirar') }
      ], lista, { compacta: true }));
    }
    function excecaoD4(botao, tarefaId, ativa) {
      const td = botao.closest('td'); td.textContent = '';
      const just = h('textarea', { rows: 3, 'aria-label': 'Justificativa', placeholder: (ativa ? 'Por que a entrega pode passar do D-4' : 'Por que a exceção foi retirada') + ' (mín. 15 caracteres)' });
      const msg = h('p', { class: 'erro' });
      td.append(h('div', { class: 'form-conferencia' }, just, h('div', { class: 'acoes' },
        h('button', { type: 'button', class: 'btn btn-peq', onclick: async () => {
          const { error } = await ctx.sb.rpc('excecao_d4_definir', { p_tarefa_id: tarefaId, p_ativa: ativa, p_justificativa: just.value });
          if (error) { msg.textContent = /mínimo/.test(error.message) ? 'A justificativa precisa ter pelo menos 15 caracteres.' : error.message; return; }
          desenhar();
        } }, ativa ? 'Autorizar' : 'Retirar exceção'), h('button', { type: 'button', class: 'btn btn-sec btn-peq', onclick: () => desenhar() }, 'Cancelar')), msg));
      just.focus();
    }
    function conferir(botao, l) {
      const td = botao.closest('td'); td.textContent = '';
      const res = h('select', { 'aria-label': 'Resultado' }, Object.entries(C().ROTULOS.resultado).map(([k, t]) => h('option', { value: k }, t)));
      const nota = h('textarea', { rows: 3, 'aria-label': 'Nota', placeholder: 'O que foi conferido (mín. 10 caracteres)' });
      const msg = h('p', { class: 'erro' });
      td.append(h('div', { class: 'form-conferencia' }, res, nota, h('div', { class: 'acoes' },
        h('button', { type: 'button', class: 'btn btn-peq', onclick: async () => {
          const { error } = await ctx.sb.rpc('admin_conferir_alerta', { p_linha: l.linha_id, p_categoria: l.categoria, p_resultado: res.value, p_nota: nota.value });
          if (error) { msg.textContent = /length|nota/.test(error.message) ? 'A nota precisa ter pelo menos 10 caracteres.' : error.message; return; }
          desenhar();
        } }, 'Salvar'), h('button', { type: 'button', class: 'btn btn-sec btn-peq', onclick: () => desenhar() }, 'Cancelar')), msg));
      nota.focus();
    }
    desenhar();
  }

  // ---------------------------------------------------------------- Reagendamentos
  async function reagendamentos(raiz, ctx) {
    const f = { natureza: null, processo: null, semJust: false };
    raiz.append(h('h1', {}, 'Reagendamentos'),
      h('p', { class: 'sutil' }, 'Solicitação (texto na tarefa) não é prova de alteração. Efetivação = data, PF ou responsável alterados, observados entre duas importações.'),
      aviso('info', 'Aprovação e rejeição de pedidos não aparecem na exportação do ADVBOX; por isso não são classificadas aqui. Quando houver evento observável (extensão), passam a ser registradas.'));
    const filtros = h('div'), corpo = h('div'); raiz.append(filtros, corpo);
    filtros.append(await C().barraFiltros(ctx, { rotuloPeriodo: 'Período (data do evento)', extras: [
      busca('Processo', f.processo, v => { f.processo = v; desenhar(); }),
      h('label', { class: 'filtro filtro-check' }, h('input', { type: 'checkbox', onchange: e => { f.semJust = e.target.checked; desenhar(); } }), h('span', {}, 'Só efetivações sem justificativa'))] }, () => desenhar()));
    async function desenhar() {
      corpo.textContent = ''; corpo.append(h('p', { class: 'sutil' }, 'Carregando…'));
      const p = C().params();
      const { data: r, error } = await ctx.sb.rpc('reagendamentos_listar', { p_natureza: f.natureza, p_inicio: p.p_inicio, p_fim: p.p_fim,
        p_equipe: p.p_equipe, p_colaborador: p.p_colaborador, p_processo: f.processo, p_so_sem_justificativa: f.semJust, p_limite: 500 });
      corpo.textContent = '';
      if (error) { corpo.append(aviso('erro', error.message)); return; }
      const totalBase = Object.values(r.por_natureza).reduce((a, b) => a + b, 0);
      corpo.append(chips(r.por_natureza, 'natureza', f.natureza, v => { f.natureza = v; desenhar(); }, totalBase),
        h('p', { class: 'sutil' }, `${num(r.sem_justificativa)} efetivação(ões) sem justificativa anotada · ${num(r.com_impacto_no_prazo)} com impacto no prazo.`),
        contagemTexto(r),
        tabela([
          { titulo: 'Data', valor: l => h('span', {}, l.ocorrido_em ? data(l.ocorrido_em.slice(0, 10)) : dataHora(l.observado_em),
              l.precisao_ocorrido === 'entre_importacoes' ? h('span', { class: 'sutil' }, ' (observado na importação)') : null) },
          { titulo: 'Natureza', valor: l => h('span', { class: 'tag ' + (l.natureza === 'efetivacao' ? 'tag-alerta' : 'tag-neutra') }, C().rot('natureza', l.natureza)) },
          { titulo: 'Evento', valor: l => C().rot('tipoEvento', l.tipo) },
          { titulo: 'Texto original / alteração', valor: l => l.texto_original ? l.texto_original
              : `${fmtValor(l.valor_anterior)} → ${fmtValor(l.valor_novo)}`, larga: true },
          { titulo: 'Autor', valor: l => l.autor || '—' },
          { titulo: 'Processo', valor: l => l.processo_cnj || '—' },
          { titulo: 'Responsável', valor: l => l.responsavel || '—' },
          { titulo: 'Situação', valor: l => h('span', {}, [
              l.sem_justificativa ? h('span', { class: 'tag tag-erro' }, 'sem justificativa') : null,
              l.impacto_no_prazo ? h('span', { class: 'tag tag-alerta' }, 'impacta prazo') : null,
              l.natureza === 'solicitacao' ? h('span', { class: 'tag tag-neutra' }, l.efetivada_depois ? 'data alterada depois' : 'sem alteração observada') : null]) }
        ], r.linhas, { compacta: true, vazio: 'Nenhum evento com esses filtros.' }));
    }
    desenhar();
  }
  function fmtValor(v) {
    if (v === null || v === undefined) return '—';
    const s = typeof v === 'string' ? v : JSON.stringify(v);
    return /^\d{4}-\d{2}-\d{2}/.test(s) ? data(s) : s;
  }

  // ---------------------------------------------------------------- Tratativa
  async function tratativa(raiz, ctx) {
    const admin = ctx.perfil.papel === 'admin';
    const f = { status: 'pendente_sem_inicio', processo: null };
    raiz.append(h('h1', {}, 'Tratativa'),
      h('p', { class: 'sutil' }, 'Início registrado pelo botão "Iniciar tratativa" da extensão, com horário do servidor. A abertura da tarefa nunca conta como início.'));
    const filtros = h('div'), corpo = h('div'); raiz.append(filtros, corpo);
    filtros.append(await C().barraFiltros(ctx, { periodo: false, extras: [busca('Processo', f.processo, v => { f.processo = v; desenhar(); })] }, () => desenhar()));
    async function desenhar() {
      corpo.textContent = ''; corpo.append(h('p', { class: 'sutil' }, 'Carregando…'));
      const p = C().params();
      const { data: r, error } = await ctx.sb.rpc('tratativa_listar', { p_status: f.status, p_equipe: p.p_equipe, p_colaborador: p.p_colaborador, p_processo: f.processo, p_limite: 500 });
      corpo.textContent = '';
      if (error) { corpo.append(aviso('erro', error.message)); return; }
      if (!r.monitorada_desde)
        corpo.append(aviso('alerta', 'A data de início do uso real da extensão ainda não foi configurada (parâmetro "tratativa_monitorada_desde"). Até lá, conclusões sem início não são tratadas como inconsistência — não havia como registrar o início.'));
      const totalBase = Object.values(r.por_status).reduce((a, b) => a + b, 0);
      corpo.append(chips(r.por_status, 'status', f.status, v => { f.status = v; desenhar(); }, totalBase), contagemTexto(r),
        tabela([
          { titulo: 'Situação', valor: l => h('span', { class: 'tag ' + (l.status_tratativa === 'concluida_sem_inicio' ? 'tag-erro' : l.status_tratativa === 'pendente_sem_inicio' ? 'tag-alerta' : 'tag-neutra') }, C().rot('status', l.status_tratativa)) },
          { titulo: 'Compromisso', valor: l => l.compromisso || '—', larga: true },
          { titulo: 'Processo', valor: l => l.processo_cnj || '—' },
          { titulo: 'Responsável', valor: l => l.responsavel || '—' },
          { titulo: 'Data', valor: l => data(l.d7_data_agenda) },
          { titulo: 'Abertura (ADVBOX)', valor: l => l.abertura_em ? dataHora(l.abertura_em) : h('span', { class: 'sutil' }, 'não lida') },
          { titulo: 'Início', valor: l => l.inicio_tratativa_em ? h('span', {}, dataHora(l.inicio_tratativa_em), h('span', { class: 'sutil' }, ' por ' + (l.inicio_por || '—'))) : '—' },
          { titulo: 'Conclusão', valor: l => l.data_conclusao ? dataHora(l.data_conclusao) : '—' }
        ], r.linhas, { compacta: true, vazio: 'Nenhuma tarefa nesta situação.' }));
      corpo.append(h('h2', { class: 'secao' }, 'Eventos das travas (extensão)'),
        tabela([
          { titulo: 'Quando', valor: l => dataHora(l.ocorrido_em) },
          { titulo: 'Operação', valor: l => C().rot('tipoEvento', l.tipo) },
          { titulo: 'Resultado', valor: l => h('span', { class: 'tag ' + (l.estado_trava === 'violacao_detectada' ? 'tag-erro' : l.estado_trava === 'bloqueio_efetivo' ? 'tag-alerta' : 'tag-neutra') }, C().rot('estadoTrava', l.estado_trava)) },
          { titulo: 'Colaborador', valor: l => l.colaborador || '—' },
          { titulo: 'ID ADVBOX', valor: l => l.advbox_id || '—' },
          { titulo: 'Justificativa / motivo', valor: l => l.justificativa || l.motivo || '—', larga: true }
        ], r.travas, { compacta: true, vazio: 'Nenhum evento de trava registrado (a extensão ainda não está em uso real).' }));
      if (admin) corpo.append(h('h2', { class: 'secao' }, 'Vínculos a refazer'),
        h('p', { class: 'sutil' }, 'Tarefas vistas pela extensão que não aparecem na exportação atual. Abra a tarefa no ADVBOX com a extensão para refazer o vínculo.'),
        tabela([{ titulo: 'ID ADVBOX', valor: l => l.advbox_id }, { titulo: 'Título na tela', valor: l => l.titulo_tela || '—', larga: true },
          { titulo: 'Data na tela', valor: l => l.data_evento_tela || '—' }, { titulo: 'Início', valor: l => l.inicio_tratativa_em ? dataHora(l.inicio_tratativa_em) : '—' }],
          r.sem_linha_atual, { compacta: true, vazio: 'Nenhum vínculo pendente.' }));
    }
    desenhar();
  }

  window.Riscos = { prazos, reagendamentos, tratativa };
})();
