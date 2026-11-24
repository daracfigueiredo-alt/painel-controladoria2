/* Criação automática da tarefa de análise (Etapa 8) — roda no ADVBOX, só para a controladoria.
 * Decisão de 10/11/2026: depois da aprovação no painel, a extensão cria a tarefa sozinha.
 * Como: preenche e envia o formulário normal "Nova tarefa" do ADVBOX (o mesmo da tela), uma
 * tarefa por vez, e lê o ID da tarefa criada no endereço (?t=ID). Nenhuma chamada oculta.
 * Segurança:
 *  - só começa com a aba visível, sem janela/formulário aberto e sem uso da página há 20 s;
 *  - o banco trava a tarefa (criacao_em_andamento) antes de abrir o formulário: duas abas
 *    não criam a mesma tarefa;
 *  - antes de enviar, confere campo a campo (processo, tipo, responsável, datas, descrição);
 *    qualquer diferença cancela o formulário SEM enviar e bloqueia a tarefa para a controladoria;
 *  - processo não encontrado ou com mais de um cadastro para o CNJ: não envia, bloqueia;
 *  - enviado sem confirmação (sem ID novo, página recarregada): "verificar no ADVBOX",
 *    nunca recria sozinha. */
(function () {
  'use strict';
  if (window.top !== window) return;
  const C = globalThis.OCCriacao, P = globalThis.OCParse;
  const PAUSA = 'oc_criacao_pausada', ENVIO = 'oc_analise_envio';
  const OCIOSO_MS = 20000, INTERVALO_MS = 90000;
  let rodando = false, ultimoUso = Date.now(), banner = null;

  const enviar = msg => new Promise(res => {
    try { chrome.runtime.sendMessage(msg, r => res(chrome.runtime.lastError ? { ok: false, erro: chrome.runtime.lastError.message } : r)); }
    catch (e) { res({ ok: false, erro: e.message }); }
  });
  const espera = ms => new Promise(r => setTimeout(r, ms));
  const visivel = el => !!(el && el.getClientRects().length > 0 && getComputedStyle(el).visibility !== 'hidden');
  const local = {
    get: async k => { try { return (await chrome.storage.local.get(k))[k]; } catch (e) { return undefined; } },
    set: async (k, v) => { try { await chrome.storage.local.set({ [k]: v }); } catch (e) { /* sem armazenamento */ } },
    del: async k => { try { await chrome.storage.local.remove(k); } catch (e) { /* idem */ } }
  };
  ['mousedown', 'keydown', 'wheel', 'touchstart'].forEach(ev => window.addEventListener(ev, e => { if (e.isTrusted) ultimoUso = Date.now(); }, true));

  const formulario = () => [...document.querySelectorAll('form.modal-inner-create')].find(visivel);
  const tarefaAberta = () => [...document.querySelectorAll('.task-container')].find(c => visivel(c) && c.querySelector('a.toggle[data-id]'));
  const idNaUrl = () => { try { return new URL(location.href).searchParams.get('t'); } catch (e) { return null; } };
  async function aguardar(fn, ms, passo = 250) {
    const fim = Date.now() + ms;
    for (;;) { const v = fn(); if (v) return v; if (Date.now() > fim) return null; await espera(passo); }
  }

  function mostrar(texto, tipo) {
    if (!banner) {
      banner = document.createElement('div'); banner.className = 'oc-criacao-banner'; banner.setAttribute('role', 'status');
      document.body.appendChild(banner);
    }
    banner.className = 'oc-criacao-banner' + (tipo ? ' oc-criacao-' + tipo : ''); banner.textContent = texto; banner.hidden = false;
  }
  const esconder = (ms = 0) => setTimeout(() => { if (banner) banner.hidden = true; }, ms);

  // Texto da janela da tarefa SEM o painel da controladoria (que fica dentro dela e confundiria o título).
  function textoSemPainel(container) {
    const ps = [...container.querySelectorAll('.oc-painel')], antes = ps.map(p => p.style.display);
    ps.forEach(p => { p.style.display = 'none'; });
    try { return container.innerText; } finally { ps.forEach((p, i) => { p.style.display = antes[i]; }); }
  }
  // ---------------------------------------------------------------- select2 (ADVBOX)
  const mouse = (el, tipo) => el.dispatchEvent(new MouseEvent(tipo, { bubbles: true, cancelable: true, view: window }));
  function abrirSelect(sel) {
    const s = sel.nextElementSibling && sel.nextElementSibling.querySelector('.select2-selection');
    if (!s) return false;
    ['mousedown', 'mouseup', 'click'].forEach(t => mouse(s, t));
    return true;
  }
  const campoBusca = () => [...document.querySelectorAll('.select2-container--open .select2-search__field')].find(visivel);
  const opcoesAbertas = () => [...document.querySelectorAll('.select2-container--open .select2-results__option[role=option]')];
  async function buscar(sel, termo) {
    if (!abrirSelect(sel)) return null;
    const inp = await aguardar(campoBusca, 3000);
    if (!inp) return null;
    inp.value = termo; inp.dispatchEvent(new Event('input', { bubbles: true })); inp.dispatchEvent(new KeyboardEvent('keyup', { bubbles: true }));
    // espera o resultado da busca estabilizar (ajax)
    let antes = '', iguais = 0;
    await aguardar(() => {
      const t = opcoesAbertas().map(o => o.textContent).join('|');
      iguais = (t && t === antes && !/searching|buscando|carregando/i.test(t)) ? iguais + 1 : 0; antes = t;
      return iguais >= 3;
    }, 12000, 400);
    return opcoesAbertas();
  }
  const fechar = () => { const i = campoBusca(); if (i) i.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', keyCode: 27, bubbles: true })); };
  async function escolher(sel, op) { mouse(op, 'mouseenter'); mouse(op, 'mouseup'); await espera(700); return sel.value; }

  async function escolherProcesso(form, t) {
    const sel = form.querySelector('select[name=lawsuits_id]');
    if (!sel) return { acao: 'bloquear', motivo: 'formulario_indisponivel', detalhe: { campo: 'processo' } };
    const alvo = { teste: t.teste, busca: t.busca, cnj: t.cnj };
    let ops = await buscar(sel, t.busca);
    if (!ops) return { acao: 'bloquear', motivo: 'formulario_indisponivel', detalhe: { campo: 'processo (busca)' } };
    const textos = C.filtrarProcessos(ops.map(o => o.innerHTML), alvo);
    const coletadas = [];
    for (let i = 0; i < textos.length && i < 10; i++) {          // lê o ID de cada cadastro encontrado
      if (i > 0) ops = await buscar(sel, t.busca);
      const op = (ops || []).find(o => o.innerHTML === textos[i]);
      if (!op) continue;
      coletadas.push({ lawsuit_id: await escolher(sel, op), texto: textos[i] });
    }
    fechar();
    const d = C.decidirProcesso(coletadas, t.advbox_processo_id, t.busca);
    if (d.acao !== 'usar') return d;
    if (sel.value !== d.lawsuit_id) {                             // deixa selecionado o escolhido
      ops = await buscar(sel, t.busca);
      const op = (ops || []).find(o => C.norm(o.innerHTML) === d.texto);
      if (!op || await escolher(sel, op) !== d.lawsuit_id) { fechar(); return { acao: 'bloquear', motivo: 'formulario_divergente', detalhe: { campo: 'processo', esperado: d.lawsuit_id, obtido: sel.value } }; }
    }
    return d;
  }

  async function escolherTipo(form, t) {
    const sel = form.querySelector('select[name=tasks_id]');
    const ops = sel && await buscar(sel, String(t.tipo).replace(/\s*\(\d+\s*pts\)\s*$/i, ''));
    const op = (ops || []).find(o => C.tipoConfere(o.textContent, t.tipo));
    if (!op) { fechar(); return { ok: false, detalhe: { tipo: t.tipo, opcoes: (ops || []).map(o => o.textContent.trim()).slice(0, 20) } }; }
    const v = await escolher(sel, op);
    await aguardar(() => form.querySelector('[name=stages_id]') && form.querySelector('[name=stages_id]').value, 4000);
    return v === t.tipo_advbox_id ? { ok: true } : { ok: false, detalhe: { tipo: t.tipo, esperado: t.tipo_advbox_id, obtido: v } };
  }

  function preencher(form, nome, valor) {
    const el = form.querySelector(`[name="${nome}"]`);
    if (!el) return false;
    el.value = valor;
    el.dispatchEvent(new Event('input', { bubbles: true })); el.dispatchEvent(new Event('change', { bubbles: true }));
    return true;
  }
  function lerCampos(form) {
    const o = {};
    for (const [k, v] of new FormData(form).entries()) if (!(v instanceof File)) (o[k] = o[k] || []).push(String(v));
    return o;
  }
  function cancelar() {
    const f = formulario(); if (!f) return;
    const b = [...f.querySelectorAll('button')].find(x => x.getAttribute('type') !== 'submit' && /cancelar/i.test(x.textContent));
    if (b) b.click();
  }

  // ---------------------------------------------------------------- uma tarefa
  async function criar(id) {
    const ini = await enviar({ tipo: 'analise_iniciar', id });
    if (!ini || !ini.ok) return { fim: 'nao_iniciada', erro: ini && ini.erro };
    const t = ini.dados;
    const rotulo = `tarefa de análise #${t.id}${t.teste ? ' (TESTE)' : ''} — ${t.busca}`;
    mostrar(`Controladoria: criando ${rotulo}. Não use esta aba por alguns segundos.`);
    const bloquear = async (motivo, detalhe) => {
      cancelar();
      const r = await enviar({ tipo: 'analise_bloquear', id: t.id, motivo, detalhe: detalhe || {} });
      mostrar(`Controladoria: ${rotulo} NÃO foi enviada (${motivo.replace(/_/g, ' ')}). Resolva no painel, área "Tarefas de análise".`, 'alerta');
      esconder(15000);
      return { fim: 'bloqueada', motivo, registrado: !!(r && r.ok) };
    };

    // 1. formulário com o responsável já indicado
    const a = document.createElement('a');
    a.href = 'posts/create?responsible=' + encodeURIComponent(t.responsavel_advbox_id);
    a.className = 'add-new-message'; a.style.display = 'none';
    document.body.appendChild(a); a.click(); a.remove();
    const form = await aguardar(formulario, 12000);
    if (!form) {
      if ((t.tentativa || 1) < 3) {
        await enviar({ tipo: 'analise_falha', id: t.id, erro: 'Formulário "Nova tarefa" não abriu; nada foi enviado.', certeza: true });
        esconder(); return { fim: 'tentar_depois' };
      }
      return bloquear('formulario_indisponivel', { tentativas: t.tentativa });
    }
    await espera(800);
    const guests = [...form.querySelectorAll('[name="guests[]"]')].map(e => e.value).filter(Boolean);
    if (guests.length !== 1 || guests[0] !== t.responsavel_advbox_id) return bloquear('responsavel_divergente', { esperado: t.responsavel_advbox_id, obtido: guests });

    // 2. processo, 3. tipo
    const proc = await escolherProcesso(form, t);
    if (proc.acao !== 'usar') return bloquear(proc.motivo, proc.detalhe);
    const tipo = await escolherTipo(form, t);
    if (!tipo.ok) return bloquear('tipo_nao_encontrado', tipo.detalhe);

    // 4. datas e descrição
    const data = C.dataBR(t.data_prevista), pf = C.dataBR(t.pf_previsto);
    if (!data || !pf) return bloquear('formulario_divergente', { campo: 'datas', data_prevista: t.data_prevista, pf_previsto: t.pf_previsto });
    preencher(form, 'date', data); preencher(form, 'date_deadline', pf); preencher(form, 'comments', t.observacoes);
    await espera(600);

    // 5. conferência final, campo a campo
    const div = C.conferirFormulario(lerCampos(form), { lawsuit_id: proc.lawsuit_id, tipo_id: t.tipo_advbox_id, responsavel_id: t.responsavel_advbox_id,
      data, prazo_fatal: pf, descricao: t.observacoes });
    if (div.length) return bloquear('formulario_divergente', { divergencias: div });
    const botao = [...form.querySelectorAll('button[type=submit]')].find(b => /criar nova tarefa/i.test(b.textContent));
    if (!botao || formulario() !== form) return bloquear('formulario_indisponivel', { campo: 'botão Criar nova tarefa' });

    // 6. envio — a partir daqui, sem confirmação = verificar no ADVBOX
    const idAntes = idNaUrl();
    await local.set(ENVIO, { id: t.id, id_antes: idAntes, quando: Date.now() });
    botao.click();
    const novo = await aguardar(() => {
      const c = tarefaAberta(), u = idNaUrl();
      if (!c || !u || u === idAntes) return null;
      const b = c.querySelector('a.toggle[data-id]');
      return b && b.getAttribute('data-id') === u ? { id: u, c } : null;
    }, 30000, 400);
    await local.del(ENVIO);
    if (!novo) {
      const r = await enviar({ tipo: 'analise_falha', id: t.id, erro: 'Enviada ao ADVBOX sem confirmação (a tarefa criada não abriu em 30 s). Confira no ADVBOX antes de recriar.', certeza: false });
      mostrar(`Controladoria: ${rotulo} foi enviada, mas a confirmação não chegou. Confira no ADVBOX (painel: "Verificar no ADVBOX").`, 'alerta');
      esconder(20000);
      return { fim: 'verificar', registrado: !!(r && r.ok) };
    }
    await espera(800);
    const tela = P.lerTela(textoSemPainel(novo.c), novo.id);
    const prob = C.conferirCriada(tela, idAntes, novo.id, t.tipo, Date.now());
    const toast = [...document.querySelectorAll('body *')].some(e => e.children.length === 0 && /Tarefa cadastrada com sucesso/i.test(e.textContent || ''));
    const evid = { url: location.href, lawsuit_id: proc.lawsuit_id, processo_texto: proc.texto, id_antes: idAntes, aviso_sucesso: toast,
                   tela: { titulo: tela.titulo, criado_por: tela.criado_por, criado_em: tela.criado_em, data_evento: tela.data_evento, prazo_fatal: tela.prazo_fatal, processo: tela.processo } };
    if (prob.length) {
      await enviar({ tipo: 'analise_falha', id: t.id, erro: 'Tarefa aberta após o envio não confere: ' + prob.join('; ') + ` (ID ${novo.id}). Confira no ADVBOX.`, certeza: false });
      mostrar(`Controladoria: ${rotulo} — a tarefa aberta (${novo.id}) não confere (${prob.join('; ')}). Confira no ADVBOX.`, 'alerta');
      esconder(20000);
      return { fim: 'verificar' };
    }
    const r = await enviar({ tipo: 'analise_confirmar', id: t.id, advbox_id: novo.id, evidencia: evid });
    mostrar(r && r.ok ? `Controladoria: ${rotulo} criada no ADVBOX (tarefa ${novo.id}).` : `Controladoria: tarefa ${novo.id} criada, mas o registro falhou (${r && r.erro}). Avise a controladoria.`, r && r.ok ? 'ok' : 'alerta');
    esconder(10000);
    return { fim: 'criada', advbox_id: novo.id };
  }

  // ---------------------------------------------------------------- ciclo
  async function ciclo() {
    if (rodando) return;
    rodando = true;
    try {
      const pend = await local.get(ENVIO);                       // envio interrompido (página recarregada)
      if (pend && pend.id) {
        await local.del(ENVIO);
        await enviar({ tipo: 'analise_falha', id: pend.id, erro: 'Página recarregada durante o envio ao ADVBOX; confira no ADVBOX antes de recriar.', certeza: false });
      }
      for (let n = 0; n < 10; n++) {                             // no máximo 10 por ciclo
        if (document.visibilityState !== 'visible' || await local.get(PAUSA)) return;
        if (Date.now() - ultimoUso < OCIOSO_MS || formulario() || tarefaAberta() || campoBusca()) return;
        const f = await enviar({ tipo: 'analise_fila' });
        if (!f || !f.ok || !f.dados || !f.dados.admin || !f.dados.proxima) return;
        const r = await criar(f.dados.proxima);
        if (r.fim !== 'criada') return;
        // fecha a janela da tarefa criada para a próxima
        await espera(2500);
        const c = tarefaAberta();
        if (c) {   // botão "X" (a.close.material-icons, texto "clear") da janela da tarefa, conferido no ADVBOX real em 10/11/2026
          const x = c.querySelector('a.close.material-icons');
          if (x) x.click(); else c.click();
        }
        await espera(1500);
        if (tarefaAberta()) return;
      }
    } finally { rodando = false; }
  }

  chrome.runtime.onMessage.addListener((msg, _s, responder) => {
    if (msg && msg.tipo === 'analise_agora') { ultimoUso = 0; ciclo().then(() => responder({ ok: true })); return true; }
    return false;
  });
  setTimeout(ciclo, 8000);
  setInterval(ciclo, INTERVALO_MS);
})();
