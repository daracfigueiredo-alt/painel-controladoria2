/* Script de conteúdo — tela "Intimações recebidas" do ADVBOX (/publications). Etapa 7.
 * Só leitura: lê as linhas exibidas e, para cada intimação, faz o mesmo GET que a tela faz ao
 * abrir "Ver intimação" (posts/<id>/edit). Não clica em nada, não altera filtro nem situação.
 * O botão aparece só para quem está logado na extensão; o banco aceita só administrador.
 * A varredura só vale para concluir "não encontrada" quando a lista está COMPLETA na tela
 * (exibidas = total do rodapé) e todas as janelas foram lidas. */
(function () {
  'use strict';
  if (!/^\/publications\/?$/.test(location.pathname)) return;
  const I = globalThis.OCIntimacoes;
  const enviar = msg => new Promise(res => {
    try { chrome.runtime.sendMessage(msg, r => res(chrome.runtime.lastError ? { ok: false, erro: chrome.runtime.lastError.message } : r)); }
    catch (e) { res({ ok: false, erro: e.message }); }
  });
  const esperar = ms => new Promise(r => setTimeout(r, ms));
  const INTERVALO_PADRAO_MS = globalThis.__ocIntervaloTeste || 4000; // 4 s entre janelas (só o teste reduz)

  function linhasDaTela() {
    return [...document.querySelectorAll('table.publications tbody tr')].filter(tr => tr.cells.length >= 6).map(tr => ({
      celulas: [...tr.cells].map(td => td.innerText || td.textContent || ''),
      hrefs: [...tr.querySelectorAll('a[href]')].map(a => a.getAttribute('href'))
    }));
  }
  function filtroDaTela() {
    const sel = document.querySelector('select[name="interval"]');
    const val = n => { const e = document.querySelector(`[name="${n}"]`); return e ? e.value : null; };
    const usr = document.querySelector('select[name="user"]');
    return { intervalo: sel && sel.selectedOptions[0] ? sel.selectedOptions[0].textContent.trim() : null,
             de: val('date_from'), ate: val('date_until'),
             // opção vazia ("Selecione", "Responsável") = sem filtro (10/11/2026: o texto "Selecione" era lido como filtro)
             responsavel: usr && usr.value && usr.selectedOptions[0]
               && !/^(selecione|respons[aá]vel|todos)$/i.test(usr.selectedOptions[0].textContent.trim())
               ? usr.selectedOptions[0].textContent.trim() : null };
  }

  async function varrer(btn, saida) {
    btn.disabled = true; saida.textContent = 'Lendo a lista…';
    const filtro = filtroDaTela();
    const lista = I.lerLista(linhasDaTela(), (document.querySelector('.dataTables_info') || {}).textContent, filtro);
    if (filtro.responsavel) lista.erros.push(`Lista filtrada pelo responsável "${filtro.responsavel}": não serve para concluir ausência.`);
    if (!lista.completa_na_tela) lista.erros.push(`A tela mostra ${lista.exibidas} de ${lista.total_informado ?? '?'} intimações. Aumente "Registros por página" para ver todas.`);
    // Só abre as intimações cujo teor ainda não está no banco; as já lidas entram só com os dados da lista
    // (o banco preserva o teor da 1ª leitura). Em 07/11/2026 o ADVBOX recusou (HTTP 413) após ~20 janelas
    // em ~25 s: por isso a espera entre janelas e a parada na primeira recusa.
    const conh = await enviar({ tipo: 'intimacoes_conhecidas', posts: lista.itens.map(i => i.post_id) });
    const conhecidas = new Set(conh && conh.ok ? conh.dados : []);
    const intervalo = INTERVALO_PADRAO_MS;
    const registros = [];
    let parado = false;
    const abrir = lista.itens.filter(i => !conhecidas.has(i.post_id)).length;
    let lidas = 0;
    for (const it of lista.itens) {
      let janela = null;
      if (!conhecidas.has(it.post_id) && !parado) {
        lidas++;
        saida.textContent = `Abrindo intimação ${lidas} de ${abrir} (${Math.ceil((abrir - lidas) * intervalo / 60000)} min restantes)…`;
        try {
          const r = await fetch(`/posts/${it.post_id}/edit`, { credentials: 'include', headers: { 'X-Requested-With': 'XMLHttpRequest' } });
          if (!r.ok || /\/login/.test(r.url)) {
            parado = true;
            lista.erros.push(`O ADVBOX recusou a leitura (${/\/login/.test(r.url) ? 'sessão encerrada' : 'HTTP ' + r.status}) na intimação ${it.post_id}. Varredura interrompida; tente de novo em alguns minutos.`);
          } else {
            const doc = new DOMParser().parseFromString(await r.text(), 'text/html');
            doc.querySelectorAll('script,style,select').forEach(x => x.remove());
            janela = I.lerIntimacao(doc.body ? doc.body.textContent : '');
            janela.erros.forEach(e => lista.erros.push(`Intimação ${it.post_id}: ${e}`));
          }
        } catch (e) { lista.erros.push(`Intimação ${it.post_id}: janela não lida (${e.message}).`); }
        if (!parado) await esperar(intervalo);
      } else if (!conhecidas.has(it.post_id) && parado) {
        lista.erros.push(`Intimação ${it.post_id}: não aberta (varredura interrompida).`);
      }
      registros.push(I.paraRegistro(it, janela));
    }
    saida.textContent = 'Enviando à controladoria…';
    const r = await enviar({ tipo: 'varredura', varredura: {
      pagina: location.pathname, filtro, recebido_de: lista.recebido_de, recebido_ate: lista.recebido_ate,
      total_informado: lista.total_informado, erros: lista.erros }, intimacoes: registros });
    btn.disabled = false;
    if (!r || !r.ok) { saida.textContent = 'Não registrado: ' + ((r && r.erro) || 'sem resposta'); return; }
    const d = r.dados;
    // Datas de publicação vistas na tela: conferência visual de que a lista refletiu o período escolhido
    // (em 07/11/2026 uma lista "completa" lida logo após trocar o filtro não trazia 03–06/11).
    const porData = lista.itens.reduce((m, i) => (m[i.data_publicacao || '?'] = (m[i.data_publicacao || '?'] || 0) + 1, m), {});
    const datas = Object.entries(porData).sort().map(([k, n]) => `${(k || '?').slice(0, 5)}: ${n}`).join(' · ');
    saida.textContent = `Varredura #${d.varredura_id}: ${d.lidas} intimações (${d.novas} novas). Publicações por data — ${datas}. ` +
      (d.completa ? 'Completa: serve para o double check.' : 'INCOMPLETA: não serve para concluir ausência. ' + lista.erros.slice(0, 2).join(' '));
  }

  async function montar() {
    if (document.getElementById('oc-varredura') || !document.querySelector('table.publications')) return;
    const est = await enviar({ tipo: 'estado' });
    if (!est || !est.ok || !est.email) return;
    const caixa = document.createElement('div'); caixa.id = 'oc-varredura'; caixa.className = 'oc-painel oc-varredura';
    const t = document.createElement('strong'); t.textContent = 'Controladoria — double check';
    const btn = document.createElement('button'); btn.type = 'button'; btn.textContent = 'Registrar as intimações desta tela';
    const saida = document.createElement('span'); saida.className = 'oc-varredura-saida'; saida.setAttribute('role', 'status');
    btn.addEventListener('click', () => varrer(btn, saida));
    caixa.append(t, btn, saida);
    const tab = document.querySelector('table.publications');
    tab.parentElement.insertBefore(caixa, tab);
  }
  new MutationObserver(() => montar()).observe(document.documentElement, { childList: true, subtree: true });
  montar();
})();
