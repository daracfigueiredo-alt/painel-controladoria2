/*
 * Leitura da tela do ADVBOX e regras das travas.
 * Funções puras (sem rede, sem chrome.*) para poderem ser testadas.
 *
 * Estrutura conferida na tela REAL em 06/11/2026 (somente leitura, 1 tarefa da
 * própria usuária; ver docs/ETAPA5_EXTENSAO.md):
 *   Janela da tarefa  div.modal-container.task-container
 *     ID              a.button.toggle[data-id] ("Concluir") = número do post; a URL
 *                     também passa a ter ?t=<mesmo número>
 *     Título          linha logo após "Excluir" (texto do tipo da tarefa, ex. "Análise do Caso";
 *                     o Excel traz o mesmo texto em maiúsculas — o banco compara com upper())
 *     Responsáveis    ul.task-item-users > li.user-<id>[title="Nome: Situação"] (só foto na tela)
 *     Datas           "Data do evento" / "Prazo fatal" -> "terça, 27/10/2026 ..."
 *     Criado por      nome + "23/10/2026 16:44 (...)"
 *     Processo        CNJ seguido do ícone "content_copy" na mesma linha
 *   Formulários dentro da janela
 *     "Editar tarefa" form.modal-inner-create com input[name=editing] = ID da tarefa:
 *                     date, hour, date_deadline (preenchidos), guests[] (responsáveis) — ALTERA a tarefa
 *     "Atribuir tarefa" form.modal-body-comment (POST /posts), campos vazios: CRIA uma tarefa
 *                     nova; não é realocação da tarefa aberta (a fase 2 tratava como realocação: errado)
 *     "Encaminhar"    form.form-event (POST /post-events): user, post_id (sem campo de comentário)
 *   Lista de compromissos (painel e listas)
 *     Concluir direto a.change-status[data-field=completed][data-value=1][data-post=<ID>]
 *     Grupos da lista table[data-group]: deadline, others, unread, publication (= intimações
 *                     capturadas pelo ADVBOX, "INTIMAÇÃO JUDICIAL" — fora da trava da tratativa)
 * Se o ADVBOX mudar a tela, estas funções devem falhar de forma explícita
 * (campos nulos), nunca inventar valores.
 */
(function (root) {
  'use strict';

  const ICONES = new Set(['clear', 'close', 'today', 'event', 'done', 'share', 'edit', 'delete', 'update',
    'history', 'lock', 'attach_file', 'star', 'priority_high', 'lens', 'check_box_outline_blank', 'content_copy', 'help', 'error']);
  const RE_DATA = /(\d{2}\/\d{2}\/\d{4})/;
  const RE_CNJ = /(\d{7}-\d{2}\.\d{4}\.\d\.\d{2}\.\d{4})/;
  // Anotação de PF Judicial no texto (mesma regra do banco). Não atravessa quebra de linha,
  // para não confundir o rótulo "Prazo fatal" da tela com uma anotação.
  const RE_PF_ANOTADO = /(?:^|[^a-z])(?:PF|Prazo[ \t]+Fatal)[ \t]*:?[ \t]*(\d{1,2}\/\d{1,2}(?:\/\d{2,4})?)/gi;

  function linhas(texto) {
    return String(texto || '').split('\n').map(s => s.trim()).filter(s => s && !ICONES.has(s));
  }

  function valorApos(ls, rotulo, max = 2, re = null) {
    const i = ls.findIndex(l => l.toLowerCase() === rotulo.toLowerCase());
    if (i < 0) return null;
    for (let k = i + 1; k <= Math.min(i + max, ls.length - 1); k++) {
      if (!re) return ls[k];
      const m = ls[k].match(re);
      if (m) return m[1];
    }
    return null;
  }

  function dataBR(s) { // "dd/mm/aaaa" -> "aaaa-mm-dd"
    const m = String(s || '').match(/^(\d{2})\/(\d{2})\/(\d{4})$/);
    return m ? `${m[3]}-${m[2]}-${m[1]}` : null;
  }

  // dd/mm[/aa(aa)] com ano inferido pela data de referência (ISO), igual ao banco
  function dataAnotada(txt, refIso) {
    const p = String(txt).split('/').map(Number);
    if (p.length === 3) return iso(new Date(Date.UTC(p[2] < 100 ? 2000 + p[2] : p[2], p[1] - 1, p[0])));
    if (!refIso) return null;
    const ref = new Date(refIso + 'T00:00:00Z');
    let melhor = null;
    for (const y of [ref.getUTCFullYear() - 1, ref.getUTCFullYear(), ref.getUTCFullYear() + 1]) {
      const c = new Date(Date.UTC(y, p[1] - 1, p[0]));
      if (c.getUTCMonth() !== p[1] - 1) continue;
      if (!melhor || Math.abs(c - ref) < Math.abs(melhor - ref)) melhor = c;
    }
    return melhor ? iso(melhor) : null;
  }
  function iso(d) { return d.toISOString().slice(0, 10); }

  function pfJudicialNoTexto(texto, refIso) {
    let ultimo = null;
    for (const m of String(texto || '').matchAll(RE_PF_ANOTADO)) ultimo = m[1];
    return ultimo ? { texto: ultimo, data: dataAnotada(ultimo, refIso) } : null;
  }

  /** Lê a janela da tarefa a partir do texto visível (innerText) e do ID. */
  function lerTela(texto, advboxId) {
    const ls = linhas(texto);
    const iExcluir = ls.findIndex(l => l === 'Excluir' || /^delete\s+Excluir$/.test(l));   // ícone e texto podem vir na mesma linha
    const iResp = ls.findIndex(l => l === 'Responsável');
    const titulo = iExcluir >= 0 ? ls[iExcluir + 1] || null : null;
    let iDesc = iExcluir + 2;
    if (iExcluir >= 0 && /^\d+\s*pts$/i.test(ls[iDesc] || '')) iDesc++;   // pontuação exibida ao lado do título
    const descricao = (iExcluir >= 0 && iResp > iDesc) ? ls.slice(iDesc, iResp).join('\n') : null;
    const iCriado = ls.findIndex(l => l === 'Criado por');
    let criadoPor = null, criadoEm = null;
    if (iCriado >= 0) {
      criadoPor = ls[iCriado + 1] || null;
      const m = (ls[iCriado + 2] || '').match(/(\d{2}\/\d{2}\/\d{4} \d{2}:\d{2})/);
      criadoEm = m ? m[1] : null;
    }
    const iPartes = ls.findIndex(l => l === 'Partes envolvidas');
    const fimPartes = ls.findIndex((l, k) => k > iPartes && ['Grupo de ação', 'Tipo de ação', 'Responsável pelo processo'].includes(l));
    const partes = iPartes >= 0 ? ls.slice(iPartes + 1, fimPartes > iPartes ? fimPartes : iPartes + 1) : [];
    const dataEvento = valorApos(ls, 'Data do evento', 2, RE_DATA);
    const prazoFatal = valorApos(ls, 'Prazo fatal', 2, RE_DATA);
    const ref = dataBR(prazoFatal) || dataBR(dataEvento);
    return {
      advbox_id: advboxId ? String(advboxId) : null,
      titulo, descricao,
      situacao: valorApos(ls, 'Situação', 1),
      data_evento: dataEvento,              // data da agenda
      prazo_fatal: prazoFatal,              // PF da Tarefa (NÃO é o PF Judicial)
      criado_por: criadoPor, criado_em: criadoEm,
      processo: valorApos(ls, 'Processo', 2, RE_CNJ),
      partes: partes.map(p => p.replace(/\.{3}$|…$/, '').trim()).filter(Boolean),
      pf_judicial_tela: pfJudicialNoTexto(texto, ref)   // anotação "PF: dd/mm" (fonte oficial)
    };
  }

  /** Responsáveis da janela: [{ title: "Nome: Situação", classe: "user-123" }] -> [{ nome, situacao, usuario_id }]. */
  function lerResponsaveis(itens) {
    return (itens || []).map(({ title, classe }) => {
      const t = String(title || ''); const i = t.lastIndexOf(':');
      const m = String(classe || '').match(/(?:^|\s)user-(\d+)(?:\s|$)/);
      return { nome: (i > 0 ? t.slice(0, i) : t).trim() || null, situacao: i > 0 ? t.slice(i + 1).trim() : null, usuario_id: m ? m[1] : null };
    }).filter(r => r.nome || r.usuario_id);
  }

  /** ID da tarefa: botão Concluir e parâmetro ?t= da URL. Divergência = não monitorar (nunca adivinhar). */
  function idDaTarefa(idBotao, url) {
    let idUrl = null;
    try { idUrl = new URL(url).searchParams.get('t'); } catch (e) { /* URL inválida */ }
    const ok = v => (v && /^\d{1,15}$/.test(v)) ? v : null;
    const b = ok(idBotao), u = ok(idUrl);
    if (b && u && b !== u) return { id: null, conflito: true, id_botao: b, id_url: u };
    return { id: b || null, conflito: false, id_botao: b, id_url: u };
  }

  /** Formulário "Editar tarefa": valores atuais e originais (defaultValue = valor ao abrir). */
  function lerEdicao(form, guestsAoAbrir) {
    const el = n => form.querySelector(`[name="${n}"]`);
    const par = n => { const e = el(n); return e ? { atual: String(e.value || '').trim(), original: String(e.defaultValue || '').trim() } : { atual: null, original: null }; };
    const guests = [...form.querySelectorAll('[name="guests[]"]')].map(e => String(e.value)).filter(Boolean).sort();
    const ed = el('editing');
    return { editing: ed ? String(ed.value || '') : null, date: par('date'), hour: par('hour'), date_deadline: par('date_deadline'),
             guests, guests_ao_abrir: guestsAoAbrir ? [...guestsAoAbrir].sort() : null };
  }

  /**
   * Trava 1 — conclusão sem início da tratativa (janela ou lista).
   * status: { inicio_tratativa_em, modos } ou null se indisponível.
   */
  function avaliarConclusao(status) {
    if (!status) return { decisao: 'permitir', estado: 'nao_monitorada',
      motivo: 'Sem conexão/login com a controladoria: não foi possível verificar o início da tratativa.' };
    if (status.inicio_tratativa_em) return { decisao: 'permitir', estado: 'permitida_apos_validacao',
      motivo: 'Início da tratativa registrado.' };
    const modo = (status.modos || {}).conclusao || 'observar';
    return modo === 'bloquear'
      ? { decisao: 'bloquear', estado: 'bloqueio_efetivo', modo,
          motivo: 'Conclusão sem início da tratativa registrado. Abra a tarefa e clique em "Iniciar tratativa" antes de concluir.' }
      : { decisao: 'permitir', estado: 'violacao_detectada', modo,
          motivo: 'Conclusão sem início da tratativa registrado (modo observação: não bloqueado).' };
  }

  /**
   * Travas 2 e 3 — envio do formulário "Editar tarefa".
   * Compara o que foi alterado em relação ao valor que o formulário trouxe ao abrir.
   * justificativa: texto do campo da controladoria inserido no formulário.
   */
  function avaliarEdicao(ed, tela, status, justificativa) {
    const out = [];
    const min = (status && status.justificativa_minima) || 15;
    const justOk = String(justificativa || '').replace(/\s+/g, ' ').trim().length >= min;
    const modos = (status && status.modos) || {};
    const pfJud = (tela && tela.pf_judicial_tela && tela.pf_judicial_tela.data) || (status && status.pf_judicial_excel) || null;
    const mudou = p => p && p.atual !== null && p.atual !== p.original;

    if (mudou(ed.date_deadline)) {
      let motivo = null;
      if (pfJud) motivo = `Prazo fatal de tarefa com PF Judicial (${pfJud}) não pode ser alterado.`;
      else if (!status) motivo = null;
      else if (status.papel !== 'admin') motivo = 'Alteração de prazo fatal (prazo não judicial) só pela controladoria.';
      else if (!justOk) motivo = `Alteração de prazo fatal exige justificativa (mínimo ${min} caracteres).`;
      out.push(avaliacao('tentativa_alteracao_pf', motivo, status, modos.pf,
        { pf_anterior: ed.date_deadline.original, pf_novo: ed.date_deadline.atual, pf_judicial: pfJud, formulario: 'editar_tarefa' }));
    }
    const dataMudou = mudou(ed.date);
    const respMudou = !!(ed.guests_ao_abrir && ed.guests.join(',') !== ed.guests_ao_abrir.join(','));
    if (dataMudou || respMudou) {
      const motivo = justOk ? null : `Realocação exige justificativa (mínimo ${min} caracteres) no campo da controladoria.`;
      out.push(avaliacao('tentativa_realocacao', motivo, status, modos.realocacao, {
        formulario: 'editar_tarefa',
        alteracoes: [dataMudou ? 'data' : null, respMudou ? 'responsavel' : null].filter(Boolean),
        data_anterior: ed.date.original, data_nova: ed.date.atual,
        responsaveis_anteriores: ed.guests_ao_abrir, responsaveis_novos: ed.guests }));
    }
    return out;
  }

  /**
   * "Encaminhar" (form.form-event). O efeito exato no ADVBOX (troca de responsável ou só
   * notificação) ainda não foi confirmado: registra, nunca bloqueia.
   */
  function avaliarEncaminhamento(campos, status, justificativa) {
    const min = (status && status.justificativa_minima) || 15;
    const justOk = String(justificativa || '').replace(/\s+/g, ' ').trim().length >= min;
    const extra = { formulario: 'encaminhar', usuario_destino: campos.user || null, semantica: 'a_confirmar' };
    if (!status) return { tipo: 'tentativa_realocacao', decisao: 'permitir', estado: 'nao_monitorada', modo: null, extra, motivo: 'Sem conexão/login: não verificado.' };
    return justOk
      ? { tipo: 'tentativa_realocacao', decisao: 'permitir', estado: 'permitida_apos_validacao', modo: 'observar', extra, motivo: 'Encaminhamento com justificativa.' }
      : { tipo: 'tentativa_realocacao', decisao: 'permitir', estado: 'violacao_detectada', modo: 'observar', extra,
          motivo: `Encaminhamento sem justificativa (mínimo ${min} caracteres). Registrado; não bloqueado até a confirmação do efeito no ADVBOX.` };
  }

  function avaliacao(tipo, motivo, status, modo, extra) {
    if (!status) return { tipo, decisao: 'permitir', estado: 'nao_monitorada', modo: null, extra,
      motivo: 'Sem conexão/login com a controladoria: operação não verificada.' };
    if (!motivo) return { tipo, decisao: 'permitir', estado: 'permitida_apos_validacao', modo, extra, motivo: 'Regras atendidas.' };
    return modo === 'bloquear'
      ? { tipo, decisao: 'bloquear', estado: 'bloqueio_efetivo', modo, extra, motivo }
      : { tipo, decisao: 'permitir', estado: 'violacao_detectada', modo: modo || 'observar', extra,
          motivo: motivo + ' (modo observação: não bloqueado)' };
  }

  /** Título da tarefa a partir do texto da linha da lista ("COMPROMISSO: descrição"). */
  function tituloDaLista(texto) {
    const t = String(texto || '').trim(); const i = t.indexOf(':');
    return i > 0 ? t.slice(0, i).trim() : (t || null);
  }

  const api = { lerTela, lerResponsaveis, idDaTarefa, lerEdicao, avaliarConclusao, avaliarEdicao, avaliarEncaminhamento,
                tituloDaLista, pfJudicialNoTexto, dataAnotada, dataBR };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  root.OCParse = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
