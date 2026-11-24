/*
 * Leitura da tela "Intimações recebidas" do ADVBOX (/publications) para o double check.
 * Funções puras (sem rede, sem chrome.*), testáveis.
 *
 * Estrutura conferida na tela REAL em 06/11/2026 (somente leitura; ver docs/ETAPA7_DOUBLE_CHECK.md):
 *   Lista      table.publications (DataTables com paginação NO SERVIDOR). Rodapé ".dataTables_info"
 *              "1-50 de 84": só as linhas exibidas existem na página. A varredura só é completa
 *              quando exibidas = total (escolher "Registros por página" maior que o total).
 *   Linha      células: Processo (partes) | Publicação (dd/mm/aaaa) | Tribunal | Número do processo |
 *              Responsável | Situação ("description Pendente") | ações.
 *              a[href="posts/<id>/edit"] = a intimação; a[href="lawsuits/<id>/edit"] = processo vinculado.
 *              Linha "N/A": sem processo vinculado, sem tribunal e sem número na lista.
 *   Filtro     select[name=interval] (Hoje | 3 | 7 | 30 dias) e input[name=date_from] / [name=date_until]
 *              com o texto "De: dd/mm/aaaa" / "Até: dd/mm/aaaa" (período de RECEBIMENTO no ADVBOX).
 *   Janela     GET posts/<id>/edit (o mesmo pedido que a tela faz ao abrir "Ver intimação"). Em texto:
 *              "<ÓRGÃO>" / "Processo: <CNJ>" / teor ... "Inteiro Teor: <url>" / "Responsável" / "Situação" /
 *              ... "Nome pesquisado" <nome> / "Data da publicação" "today dd/mm/aaaa" / "Prazo" ... /
 *              "Criado por" <órgão> "dd/mm/aaaa hh:mm (...)" / "Processo" <CNJ> | "Nenhum processo vinculado".
 * Se o ADVBOX mudar a tela, estas funções devolvem campos nulos e erros explícitos, nunca valores inventados.
 */
(function (root) {
  'use strict';
  const RE_CNJ = /\b(\d{7})-?(\d{2})\.?(\d{4})\.?(\d)\.?(\d{2})\.?(\d{4})\b/;
  const cnj = s => { const m = String(s || '').match(RE_CNJ); return m ? `${m[1]}-${m[2]}.${m[3]}.${m[4]}.${m[5]}.${m[6]}` : null; };
  const data = s => { const m = String(s || '').match(/(\d{2})\/(\d{2})\/(\d{4})/); return m ? `${m[1]}/${m[2]}/${m[3]}` : null; };
  const limpa = s => String(s || '').replace(/\s+/g, ' ').trim();

  /** linhas: [{celulas:[texto...], hrefs:[...]}] — extraídas do DOM pelo content script. */
  function lerLista(linhas, infoTexto, filtro) {
    const erros = [];
    const m = String(infoTexto || '').match(/(\d+)\s*-\s*(\d+)\s+de\s+(\d+)/);
    const total = m ? Number(m[3]) : null;
    if (!m) erros.push('Rodapé "1-N de M" não encontrado: não dá para saber se a lista está completa.');
    const itens = [];
    for (const l of linhas) {
      const c = l.celulas || [];
      const post = (l.hrefs || []).map(h => (h.match(/(?:^|\/)posts\/(\d+)\/edit/) || [])[1]).find(Boolean);
      const law = (l.hrefs || []).map(h => (h.match(/(?:^|\/)lawsuits\/(\d+)\/edit/) || [])[1]).find(Boolean);
      if (!post) { erros.push('Linha sem link da intimação: ' + limpa(c.join(' | ')).slice(0, 80)); continue; }
      itens.push({ post_id: post, partes: limpa(c[0]) || null, data_publicacao: data(c[1]), tribunal: limpa(c[2]) || null,
                   cnj: cnj(c[3]), lawsuit_id: law || null, responsavel: limpa(c[4]) || null,
                   situacao: limpa(String(c[5] || '').replace(/description/g, '')) || null, sem_processo: !law });
    }
    const de = data(filtro && filtro.de), ate = data(filtro && filtro.ate);
    if (!de || !ate) erros.push('Período do filtro (De/Até) não encontrado na tela.');
    return { itens, total_informado: total, exibidas: itens.length, completa_na_tela: total !== null && total === itens.length,
             recebido_de: de, recebido_ate: ate, erros };
  }

  /** texto: textContent da resposta de posts/<id>/edit (linhas preservadas). */
  function lerIntimacao(texto) {
    const L = String(texto || '').split(/\r?\n/).map(limpa).filter(Boolean);
    const r = { teor: null, orgao: null, cnj_teor: null, url_inteiro_teor: null, nome_pesquisado: null, data_publicacao: null,
                capturada_em: null, processo_vinculado: null, erros: [] };
    const iProc = L.findIndex(l => /^Processo:\s*\d/.test(l));
    const iResp = L.findIndex((l, i) => i > iProc && l === 'Responsável');
    if (iProc < 1 || iResp < 0) { r.erros.push('Teor da intimação não localizado na janela (estrutura diferente da conferida).'); }
    else {
      r.orgao = L[iProc - 1];
      r.cnj_teor = cnj(L[iProc]);
      const corpo = L.slice(iProc - 1, iResp);
      const it = corpo.findIndex(l => /^Inteiro Teor:/i.test(l));
      if (it >= 0) { r.url_inteiro_teor = (corpo[it].match(/https?:\/\/\S+/) || [])[0] || null; }
      r.teor = corpo.join('\n');
    }
    const apos = rot => { const i = L.findIndex((l, k) => k > iResp && l === rot); return i >= 0 ? L.slice(i + 1, i + 4) : []; };
    const np = apos('Nome pesquisado'); r.nome_pesquisado = np[0] || null;
    r.data_publicacao = data(apos('Data da publicação')[0]);
    const cp = apos('Criado por');
    const dh = (cp[1] || '').match(/(\d{2})\/(\d{2})\/(\d{4})\s+(\d{2}):(\d{2})/);
    if (dh) r.capturada_em = `${dh[3]}-${dh[2]}-${dh[1]}T${dh[4]}:${dh[5]}:00-03:00`;
    // o último rótulo "Processo" (sem dois-pontos) é o vínculo; antes dele há "Processo: <CNJ>" do teor
    const iv = L.map((l, i) => (l === 'Processo' ? i : -1)).filter(i => i > iResp).pop();
    if (iv !== undefined) {
      const v = L[iv + 1] || '';
      r.processo_vinculado = /^Nenhum processo vinculado/i.test(v) ? false : (cnj(v) ? true : null);
    }
    if (!r.data_publicacao) r.erros.push('"Data da publicação" não localizada na janela.');
    return r;
  }

  /** Junta a linha da lista e a janela no formato de ext_registrar_varredura. */
  function paraRegistro(item, janela) {
    return {
      post_id: item.post_id, cnj: item.cnj || (janela && janela.cnj_teor) || null,
      data_publicacao: item.data_publicacao || (janela && janela.data_publicacao) || null,
      tribunal: item.tribunal, orgao: janela ? janela.orgao : null, capturada_em: janela ? janela.capturada_em : null,
      lawsuit_id: item.lawsuit_id, partes: item.partes, nome_pesquisado: janela ? janela.nome_pesquisado : null,
      teor: janela ? janela.teor : null, url_inteiro_teor: janela ? janela.url_inteiro_teor : null, situacao: item.situacao,
      processo_vinculado: janela ? janela.processo_vinculado : !item.sem_processo
    };
  }

  const api = { lerLista, lerIntimacao, paraRegistro };
  if (typeof module !== 'undefined' && module.exports) module.exports = api; else root.OCIntimacoes = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
