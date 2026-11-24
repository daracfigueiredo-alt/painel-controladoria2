/* Regras da controladoria para o Atlas Gestor (11/11/2026) — módulo puro (sem DOM, sem rede):
 * roda na extensão (mundo isolado) e nos testes em Node.
 * O Atlas grava pela API REST do Supabase dele. A ponte (atlas_ponte.js, mundo da página) segura
 * cada gravação de tarefa ANTES de sair do navegador e pede a decisão à extensão. Aqui ficam:
 *   1) interpretarGravacao: transforma a requisição (método, endereço, corpo) em operações;
 *   2) avaliarOperacao: aplica as mesmas regras do ADVBOX (conclusão sem início, realocação e
 *      prazo fatal com justificativa; líderes livres nas alterações, com registro).
 * 0.7.0 (17/11/2026): conclusão com justificativa obrigatória; "em andamento" = início da tratativa. */
(function (root) {
  'use strict';
  const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  const dia = v => (v === null || v === undefined || v === '') ? null : String(v).slice(0, 10);

  // "/rest/v1/tasks?id=eq.<uuid>&..." -> { tabela: 'tasks', filtros: { id: 'eq.<uuid>' } }
  function rota(url) {
    let u; try { u = new URL(url, 'https://x.invalid'); } catch (e) { return null; }
    const m = /\/rest\/v1\/((?:rpc\/)?[a-z_0-9]+)$/.exec(u.pathname);
    if (!m) return null;
    const filtros = {}; for (const [k, v] of u.searchParams) filtros[k] = v;
    return { tabela: m[1], filtros };
  }
  const idDoFiltro = v => { const m = /^eq\.(.+)$/.exec(v || ''); return m && UUID.test(m[1]) ? m[1].toLowerCase() : null; };

  /**
   * metodo/url/corpo: a requisição do Atlas. conhecidas: Map id -> { status, due_date, fatal_date, user_id, assignees:[user_id] }
   * (valores ANTES da gravação, vistos nas leituras da própria página).
   * Devolve [{ atlas_id, conclusao, due, fatal, executante, responsaveis }] — só o que muda de verdade.
   * Tarefa desconhecida (ex.: criação) não gera operação: nada a conferir.
   */
  function interpretarGravacao(metodo, url, corpo, conhecidas) {
    const r = rota(url); metodo = String(metodo || 'GET').toUpperCase();
    if (!r || metodo === 'GET' || metodo === 'HEAD') return [];
    let dados = corpo; if (typeof dados === 'string') { try { dados = JSON.parse(dados); } catch (e) { dados = null; } }
    const linhas = Array.isArray(dados) ? dados : (dados && typeof dados === 'object' ? [dados] : []);
    const ops = [];
    if (r.tabela === 'tasks' && (metodo === 'PATCH' || metodo === 'POST' || metodo === 'PUT')) {
      const idUrl = idDoFiltro(r.filtros.id);
      for (const l of linhas) {
        const id = (l.id && UUID.test(String(l.id)) ? String(l.id).toLowerCase() : null) || idUrl;
        const ant = id && conhecidas.get(id);
        if (!ant) continue;
        const op = { atlas_id: id };
        if ('status' in l && l.status === 'done' && ant.status !== 'done') op.conclusao = true;
        // 0.7.0: "em andamento" no Atlas conta como início da tratativa (controladoria, 17/11/2026)
        if ('status' in l && l.status === 'doing' && ant.status !== 'doing' && ant.status !== 'done') op.em_andamento = true;
        if ('due_date' in l && dia(l.due_date) !== dia(ant.due_date)) op.due = { de: dia(ant.due_date), para: dia(l.due_date) };
        if ('fatal_date' in l && dia(l.fatal_date) !== dia(ant.fatal_date)) op.fatal = { de: dia(ant.fatal_date), para: dia(l.fatal_date) };
        if ('user_id' in l && (l.user_id || null) !== (ant.user_id || null)) op.executante = { de: ant.user_id || null, para: l.user_id || null };
        if (Object.keys(op).length > 1) ops.push(op);
      }
    }
    // "Dar baixa na minha parte" (botão da janela e do card): rotina complete_task_assignee_tx (visto em 11/11/2026)
    if (r.tabela === 'rpc/complete_task_assignee_tx' && metodo === 'POST') {
      for (const l of linhas) {
        const id = l.p_task_id && UUID.test(String(l.p_task_id)) ? String(l.p_task_id).toLowerCase() : null;
        if (id && conhecidas.get(id)) ops.push({ atlas_id: id, conclusao: true, baixa_parcial: true });
      }
    }
    if (r.tabela === 'task_assignees') {
      const idUrl = idDoFiltro(r.filtros.task_id);
      if (metodo === 'PATCH') {
        const ant = idUrl && conhecidas.get(idUrl);
        if (ant && linhas.some(l => l.completed_at)) ops.push({ atlas_id: idUrl, conclusao: true, baixa_parcial: true });
      } else if (metodo === 'DELETE') {
        if (idUrl && conhecidas.get(idUrl)) ops.push({ atlas_id: idUrl, responsaveis: { removidos: true } });
      } else if (metodo === 'POST') {
        const porTarefa = new Map();
        for (const l of linhas) {
          const id = l.task_id && UUID.test(String(l.task_id)) ? String(l.task_id).toLowerCase() : null;
          const ant = id && conhecidas.get(id);
          if (!ant || !l.user_id) continue;
          if ((ant.assignees || []).includes(l.user_id)) continue;     // já era responsável
          if (!porTarefa.has(id)) porTarefa.set(id, []);
          porTarefa.get(id).push(l.user_id);
        }
        for (const [id, add] of porTarefa) ops.push({ atlas_id: id, responsaveis: { adicionados: add } });
      }
    }
    return ops;
  }

  /** status: resposta de ext_status_tarefa (ou null sem conexão/login). Devolve [{tipo, decisao, estado, motivo, extra, precisa_justificativa}] */
  function avaliarOperacao(op, status, justificativa) {
    const out = [];
    const min = (status && status.justificativa_minima) || 15;
    const justOk = String(justificativa || '').replace(/\s+/g, ' ').trim().length >= min;
    const modos = (status && status.modos) || {};
    const pfJud = (status && status.pf_judicial_excel) || null;
    const papel = status && status.papel;
    const av = (tipo, motivo, modo, extra, podeJustificar) => {
      if (!status) return { tipo, decisao: 'permitir', estado: 'nao_monitorada', modo: null, extra,
        motivo: 'Sem conexão/login com a controladoria: operação não verificada.' };
      if (modo === 'lider_livre') return { tipo, decisao: 'permitir', estado: 'excecao_autorizada', modo, extra,
        motivo: 'Alteração feita por líder (autorizada pela coordenação em 11/11/2026).' };
      if (!motivo) return { tipo, decisao: 'permitir', estado: 'permitida_apos_validacao', modo, extra, motivo: 'Regras atendidas.' };
      if (modo === 'bloquear') return { tipo, decisao: 'bloquear', estado: 'bloqueio_efetivo', modo, extra, motivo, precisa_justificativa: !!podeJustificar };
      return { tipo, decisao: 'permitir', estado: 'violacao_detectada', modo: modo || 'observar', extra, motivo: motivo + ' (modo observação: não bloqueado)' };
    };
    if (op.conclusao) {
      const motivo = status && status.inicio_tratativa_em ? null
        : 'Conclusão sem início da tratativa registrado. Abra a tarefa e clique em "Iniciar tratativa" (painel da controladoria) antes de concluir.';
      // 0039: modalidade ativa exige checklist completo, a peça e o parecer de autoavaliação
      const ex = status && status.execucao;
      if (!motivo && ex && ex.exigido && !ex.completo) {
        const p = ex.pendencias || [];
        const mot = `Conclusão com pendências da modalidade ${ex.modalidade ? ex.modalidade.nome : ''}: ${p.slice(0, 3).join('; ')}${p.length > 3 ? ` (e mais ${p.length - 3})` : ''}. `
          + 'Complete o checklist e os anexos no painel da controladoria (janela da tarefa) antes de concluir.';
        out.push(av('tentativa_conclusao', mot, ex.modo === 'observar' ? 'observar' : 'bloquear',
          { origem: 'atlas', baixa_parcial: !!op.baixa_parcial, pendencias_execucao: p }, false));
      } else if (!motivo && status && status.conclusao_exige_justificativa && !justOk) {
        // 0.7.0: conclusão no Atlas exige justificativa (controladoria, 17/11/2026)
        out.push(av('tentativa_conclusao', `Conclusão exige justificativa (mínimo ${min} caracteres): registre o que foi feito.`,
          modos.conclusao, { origem: 'atlas', baixa_parcial: !!op.baixa_parcial, justificativa_conclusao: true }, true));
      } else {
        out.push(av('tentativa_conclusao', motivo, modos.conclusao, { origem: 'atlas', baixa_parcial: !!op.baixa_parcial,
          justificativa_conclusao: !!(status && status.conclusao_exige_justificativa) }, false));
      }
    }
    if (op.fatal) {
      let motivo = null, justificavel = false;
      if (modos.pf === 'lider_livre') motivo = null;
      else if (pfJud) motivo = `Prazo fatal de tarefa com PF Judicial (${pfJud.split('-').reverse().join('/')}) não pode ser alterado.`;
      else if (papel !== 'admin') motivo = 'Alteração de prazo fatal só pela controladoria.';
      else if (!justOk) { motivo = `Alteração de prazo fatal exige justificativa (mínimo ${min} caracteres).`; justificavel = true; }
      out.push(av('tentativa_alteracao_pf', motivo, modos.pf, { origem: 'atlas', pf_anterior: op.fatal.de, pf_novo: op.fatal.para, pf_judicial: pfJud }, justificavel));
    }
    if (op.due || op.executante || op.responsaveis) {
      const motivo = justOk ? null : `Realocação exige justificativa (mínimo ${min} caracteres).`;
      out.push(av('tentativa_realocacao', motivo, modos.realocacao, { origem: 'atlas',
        alteracoes: [op.due ? 'data' : null, op.executante || op.responsaveis ? 'responsavel' : null].filter(Boolean),
        data_anterior: op.due ? op.due.de : null, data_nova: op.due ? op.due.para : null,
        executante_anterior: op.executante ? op.executante.de : null, executante_novo: op.executante ? op.executante.para : null,
        responsaveis: op.responsaveis || null }, true));
    }
    return out;
  }

  // valores de uma tarefa como o Atlas devolve nas leituras (snake_case) ou nas props da tela (camelCase)
  function normalizarTarefa(t) {
    if (!t || !t.id || !UUID.test(String(t.id))) return null;
    const pega = (a, b) => (a in t ? t[a] : (b in t ? t[b] : undefined));
    const ass = pega('assignees', 'task_assignees');
    return { id: String(t.id).toLowerCase(), status: pega('status', 'status'), due_date: dia(pega('due_date', 'dueDate')),
      fatal_date: dia(pega('fatal_date', 'fatalDate')), user_id: pega('user_id', 'userId') || null,
      title: pega('title', 'title') || null,
      assignees: Array.isArray(ass) ? ass.map(a => a.user_id || a.userId || a.id).filter(Boolean) : undefined };
  }

  const api = { interpretarGravacao, avaliarOperacao, normalizarTarefa, rota, UUID };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  root.OCAtlas = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
