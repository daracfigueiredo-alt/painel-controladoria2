/* Regras puras da criação automática da tarefa de análise (Etapa 8). Sem acesso à página:
 * recebem o que foi lido do formulário "Nova tarefa" e decidem. Testadas em Node.
 * Estrutura conferida no ADVBOX real em 10/11/2026 (tarefa de teste 297747789):
 *  - processo: select2 com busca; o CNJ com máscara encontra o processo; o mesmo CNJ pode ter
 *    uma linha por parte vinculada, todas com o mesmo ID de processo (um só processo); só com IDs
 *    diferentes há ambiguidade, e aí NÃO se escolhe sozinho;
 *  - tipo: "ANÁLISE DO CASO (50 pts)" (id 8849391);
 *  - responsável: campo oculto guests[] (296462 = Mayra) preenchido por posts/create?responsible=;
 *  - datas dd/mm/aaaa nos campos "date" e "date_deadline"; descrição no textarea "comments". */
(function (root) {
  'use strict';
  const digitos = s => String(s || '').replace(/\D/g, '');
  const norm = s => String(s || '').replace(/<[^>]*>/g, '').replace(/\s+/g, ' ').trim().toUpperCase();
  const dataBR = iso => { const m = String(iso || '').match(/^(\d{4})-(\d{2})-(\d{2})/); return m ? `${m[3]}/${m[2]}/${m[1]}` : null; };
  const SEM_RESULTADO = /nenhum processo encontrado|nenhum resultado|no results|searching|buscando|carregando/i;

  /** Opções do select de processo que correspondem à busca: CNJ completo (dígitos) ou, no teste, o nome do caso. */
  function filtrarProcessos(textos, alvo) {
    const lista = (textos || []).map(t => String(t || '')).filter(t => t.trim() && !SEM_RESULTADO.test(t));
    if (alvo.teste) {
      const b = norm(alvo.busca);
      return lista.filter(t => norm(t).startsWith(b + ' ') || norm(t) === b || norm(t).startsWith(b + ' -'));
    }
    const d = digitos(alvo.cnj);
    if (d.length !== 20) return [];
    return lista.filter(t => digitos(t).includes(d));
  }

  /** Decide qual processo recebe a tarefa. coletadas = [{ lawsuit_id, texto }] (lidas uma a uma no select). */
  function decidirProcesso(coletadas, conhecido, busca) {
    // O ADVBOX lista o mesmo processo uma vez por parte vinculada (ex.: "BANCO X - CNJ", "CG51 - CLIENTE - CNJ"),
    // todas com o MESMO ID de processo (conferido em 10/11/2026). Linhas com o mesmo ID são um único processo:
    // fica a primeira que apareceu. Só há ambiguidade se houver IDs de processo diferentes.
    const vistos = new Set();
    const ops = (coletadas || []).filter(o => /^\d{1,15}$/.test(o.lawsuit_id || '') && !vistos.has(o.lawsuit_id) && vistos.add(o.lawsuit_id));
    const detalhe = { busca, opcoes: ops.map(o => ({ lawsuit_id: o.lawsuit_id, texto: norm(o.texto).slice(0, 200) })) };
    if (!ops.length) return { acao: 'bloquear', motivo: 'processo_nao_encontrado', detalhe };
    if (conhecido) {
      const o = ops.find(x => x.lawsuit_id === String(conhecido));
      return o ? { acao: 'usar', lawsuit_id: o.lawsuit_id, texto: norm(o.texto) }
               : { acao: 'bloquear', motivo: 'processo_divergente', detalhe: { ...detalhe, esperado: String(conhecido) } };
    }
    if (ops.length > 1) return { acao: 'bloquear', motivo: 'processo_ambiguo', detalhe };
    return { acao: 'usar', lawsuit_id: ops[0].lawsuit_id, texto: norm(ops[0].texto) };
  }

  /** Tipo exato (sem diferença de maiúsculas/espaços). */
  const tipoConfere = (texto, tipo) => !!tipo && norm(texto) === norm(tipo);

  const linhasIguais = (a, b) => String(a || '').replace(/\r\n/g, '\n').trim() === String(b || '').replace(/\r\n/g, '\n').trim();

  /** Confere o formulário pronto (FormData lido como { campo: [valores] }) contra o que deve ser lançado. */
  function conferirFormulario(campos, esp) {
    const um = k => (campos[k] || [])[0] || '';
    const div = [];
    if (um('lawsuits_id') !== esp.lawsuit_id) div.push({ campo: 'processo', esperado: esp.lawsuit_id, obtido: um('lawsuits_id') });
    if (um('tasks_id') !== esp.tipo_id) div.push({ campo: 'tipo', esperado: esp.tipo_id, obtido: um('tasks_id') });
    const g = (campos['guests[]'] || []).filter(Boolean);
    if (g.length !== 1 || g[0] !== esp.responsavel_id) div.push({ campo: 'responsavel', esperado: [esp.responsavel_id], obtido: g });
    if (um('date') !== esp.data) div.push({ campo: 'data', esperado: esp.data, obtido: um('date') });
    if (um('date_deadline') !== esp.prazo_fatal) div.push({ campo: 'prazo_fatal', esperado: esp.prazo_fatal, obtido: um('date_deadline') });
    if (!linhasIguais(um('comments'), esp.descricao)) div.push({ campo: 'descricao', esperado_tamanho: String(esp.descricao || '').length, obtido_tamanho: um('comments').length });
    if (um('editing')) div.push({ campo: 'editing', esperado: '', obtido: um('editing') });   // nunca editar tarefa existente
    if (um('workflow') || um('workflow_id') !== '0') div.push({ campo: 'workflow', esperado: 'nenhum', obtido: um('workflow') || um('workflow_id') });
    return div;
  }

  /** Depois do envio: a janela aberta é a tarefa nova? */
  function conferirCriada(tela, idAntes, idNovo, tipo, agora) {
    const prob = [];
    if (!/^\d{1,15}$/.test(idNovo || '')) prob.push('sem ID novo');
    else if (idNovo === idAntes) prob.push('mesmo ID de antes do envio');
    if (!tela || !tela.titulo || norm(tela.titulo) !== norm(String(tipo || '').replace(/\s*\(\d+\s*pts\)\s*$/i, ''))) prob.push('título diferente do tipo');
    const m = String((tela && tela.criado_em) || '').match(/^(\d{2})\/(\d{2})\/(\d{4}) (\d{2}):(\d{2})$/);
    if (!m) prob.push('sem data de criação');
    else {
      const criado = Date.UTC(+m[3], +m[2] - 1, +m[1], +m[4] + 3, +m[5]);   // horário de Brasília (UTC-3)
      if (Math.abs((agora || Date.now()) - criado) > 10 * 60000) prob.push('criada fora da janela de 10 minutos');
    }
    return prob;
  }

  const api = { digitos, norm, dataBR, filtrarProcessos, decidirProcesso, tipoConfere, conferirFormulario, conferirCriada };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  else root.OCCriacao = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
