/* Leitor da exportação "Planilha" do portal Webjur (historico.webjur.com.br → Exportar → Planilha).
 *
 * Formato conferido em 06/11/2026 numa exportação real (39 publicações):
 *   - texto separado por ";", sem aspas, codificação Windows-1252, linhas terminadas em CRLF;
 *   - linha 2: "WEBJUR - RELATÓRIO DE PUBLICAÇÕES;"
 *   - linha 3 (cabeçalho, 11 nomes): CÓDIGO WEBJUR;ESTADO;DATA DISP;DATA PUBLIC;COMENTARIO;TRIBUNAL;
 *     PAGINA;NRO. PROCESSO;LOCAL;CIDADE;PUBLICAÇÃO;
 *   - cada publicação: os 11 campos + o TEOR (12º campo, sem nome no cabeçalho) + ";" e um TAB;
 *     o 11º campo ("PUBLICAÇÃO") é o tipo do ato ("Intimação", "Despacho"...);
 *   - última linha: "TOTAL DE PUBLICAÇÕES:;N;" — usada para conferir se nada faltou.
 * A exportação XML 1 (CPJ) do mesmo dia veio com os acentos destruídos (632 caracteres "�")
 * e sem o código Webjur: por isso não é usada.
 *
 * Saída no mesmo formato do leitor do e-mail (webjur_email.js), para o painel e o banco. */
(function (raiz) {
  'use strict';
  const CAB = ['CÓDIGO WEBJUR', 'ESTADO', 'DATA DISP', 'DATA PUBLIC', 'COMENTARIO', 'TRIBUNAL', 'PAGINA', 'NRO. PROCESSO', 'LOCAL', 'CIDADE', 'PUBLICAÇÃO'];
  const dataValida = s => /^\d{2}\/\d{2}\/\d{4}$/.test(s || '');
  const iso = s => s.split('/').reverse().join('-');

  function decodificar(bytes) {
    // UTF-8 válido (ex.: arquivo regravado) ou Windows-1252 (o que o portal gera)
    try { return new TextDecoder('utf-8', { fatal: true }).decode(bytes); }
    catch (e) { return new TextDecoder('windows-1252').decode(bytes); }
  }

  function lerExportacaoCsv(bytesOuTexto, nome) {
    const W = raiz.OCWebjur || (typeof require === 'function' ? require('./webjur_email.js') : null);
    const txt = typeof bytesOuTexto === 'string' ? bytesOuTexto : decodificar(bytesOuTexto);
    const linhas = txt.split(/\r?\n/);
    const r = { formato: 'webjur_portal_csv_v1', origem: 'webjur_portal', cliente: null, chave_cliente: null, recebido_em: null,
                resumo: [], secoes: [], publicacoes: [], avisos: [], assunto: null, remetente: null, indice: 1, de: 1, texto_bloco: null };
    const iCab = linhas.findIndex(l => /^C[ÓO]DIGO WEBJUR;/i.test(l.trim()));
    if (iCab < 0 || !/WEBJUR - RELAT/i.test(linhas.slice(0, iCab).join(' '))) {
      r.reconhecido = false; r.completo = false; r.total_declarado = 0; r.total_lido = 0;
      r.avisos.push('O arquivo não tem o formato da exportação "Planilha" do portal Webjur (cabeçalho "CÓDIGO WEBJUR;ESTADO;...").');
      return r;
    }
    const cab = linhas[iCab].split(';').map(x => x.trim()).filter(Boolean);
    const faltando = CAB.filter(c => !cab.includes(c));
    if (faltando.length) r.avisos.push('Cabeçalho diferente do conferido em 06/11/2026; colunas ausentes: ' + faltando.join(', ') + '.');
    let totalDeclarado = null;
    const vistos = new Set();
    for (let i = iCab + 1; i < linhas.length; i++) {
      const l = linhas[i];
      if (!l.trim()) continue;
      const tot = l.match(/^TOTAL DE PUBLICA[ÇC][ÕO]ES:\s*;\s*(\d+)/i);
      if (tot) { totalDeclarado = Number(tot[1]); continue; }
      const f = l.split(';');
      if (!/^\d+$/.test(f[0]) || f.length < 12) { r.avisos.push(`Linha ${i + 1} não reconhecida: "${l.slice(0, 60)}…"`); continue; }
      // sem aspas no arquivo: um ";" dentro do teor quebraria a linha; o teor é tudo do 12º campo em diante
      let teor = f.slice(11).join(';').replace(/;?\s*$/, '').trim();
      const idd = teor.match(/Identificador do documento:\s*(\d+)/i);
      const url = teor.match(/Acesso ao documento:\s*(https?:\/\/\S+)/i);
      teor = teor.replace(/\s*Acesso ao documento:\s*(https?:\/\/\S+)?/i, ' ').replace(/\s*Identificador do documento:\s*\d+/i, '').trim();
      const trib = (f[5] || '').trim();
      const partes = trib.split(/\s+-\s+/);
      const p = {
        seq: r.publicacoes.length + 1, id_origem: f[0], codigo_webjur: f[0], uf: f[1].trim(),
        data_disponibilizacao: f[2].trim(), data_publicacao: f[3].trim() || null, comentario: f[4].trim() || null,
        tribunal_texto: trib, tribunal: partes[0] === 'DJEN' && partes.length >= 3 ? partes.slice(2).join(' - ') : (trib || null),
        pagina: f[6].trim() || null, cnj_texto: f[7].trim(), orgao_julgador: f[8].trim() || null, cidade: f[9].trim() || null,
        tipo_comunicacao: f[10].trim() || null, teor, id_documento: idd ? idd[1] : null, url_origem: url ? url[1] : null,
        secao: 'Exportação do portal', secao_ordem: 1
      };
      p.secao_data = p.data_disponibilizacao;
      p.cnjs_mencionados = W.cnjsDoTexto(teor);
      p.cnj = W.cnjsDoTexto(p.cnj_texto)[0] || null;
      const a = p.alertas = [];
      if (!p.cnj) a.push(p.cnjs_mencionados.length ? 'cnj_ambiguo' : 'cnj_ausente');
      else if (!W.digitoCnjValido(p.cnj)) a.push('cnj_digito_invalido');
      if (p.cnjs_mencionados.length > 1) a.push('varios_cnj_no_teor');
      if (!dataValida(p.data_disponibilizacao)) a.push('data_disponibilizacao_invalida');
      if (p.data_publicacao && !dataValida(p.data_publicacao)) a.push('data_publicacao_invalida');
      if (!p.id_documento) a.push('sem_identificador_documento');
      if (!p.tribunal) a.push('tribunal_nao_identificado');
      if (!teor) a.push('teor_vazio');
      if (vistos.has(p.codigo_webjur)) r.avisos.push(`Código Webjur ${p.codigo_webjur} repetido no arquivo.`);
      vistos.add(p.codigo_webjur);
      r.publicacoes.push(p);
    }
    const datas = r.publicacoes.map(p => p.data_disponibilizacao).filter(dataValida).map(iso).sort();
    const periodo = datas.length ? (datas[0] === datas[datas.length - 1] ? datas[0] : `${datas[0]} a ${datas[datas.length - 1]}`) : '';
    if (totalDeclarado === null) r.avisos.push('O arquivo não tem a linha "TOTAL DE PUBLICAÇÕES": não dá para conferir se veio completo.');
    r.secoes = [{ ordem: 1, caderno: 'Exportação do portal', data: periodo.split('-').length === 3 ? periodo.split('-').reverse().join('/') : periodo,
                  declarado: totalDeclarado === null ? r.publicacoes.length : totalDeclarado, lidas: r.publicacoes.length, total_rodape: totalDeclarado }];
    r.publicacoes.forEach(p => { p.secao_data = r.secoes[0].data; });
    if (totalDeclarado !== null && totalDeclarado !== r.publicacoes.length)
      r.avisos.push(`O portal declara ${totalDeclarado} publicação(ões) no arquivo; o leitor encontrou ${r.publicacoes.length}.`);
    r.total_declarado = r.secoes[0].declarado; r.total_lido = r.publicacoes.length;
    r.reconhecido = true;
    r.completo = totalDeclarado !== null && totalDeclarado === r.publicacoes.length && !r.avisos.some(a => /repetido|não reconhecida/.test(a));
    r.porUf = r.publicacoes.reduce((m, p) => (m[p.uf] = (m[p.uf] || 0) + 1, m), {});
    return r;
  }

  /** Objeto aceito por pub_registrar_remessa (o banco guarda o objeto inteiro como conteúdo original). */
  function paraRegistro(p) {
    return {
      id_origem: p.id_origem, codigo_webjur: p.codigo_webjur, uf: p.uf, cnj: p.cnj, cnj_texto: p.cnj_texto,
      cnjs_mencionados: p.cnjs_mencionados, data_disponibilizacao: p.data_disponibilizacao, data_publicacao: p.data_publicacao,
      tribunal: p.tribunal, tribunal_texto: p.tribunal_texto, orgao_julgador: p.orgao_julgador, cidade: p.cidade,
      pagina: p.pagina, tipo_comunicacao: p.tipo_comunicacao, comentario: p.comentario, teor: p.teor, resumo: null,
      url_origem: p.url_origem, id_documento: p.id_documento, secao: p.secao, secao_data: p.secao_data,
      secao_ordem: p.secao_ordem, seq: p.seq, alertas: p.alertas, jornal: p.uf ? `DJ ${p.uf} (portal)` : null
    };
  }

  const api = { lerExportacaoCsv, paraRegistro };
  if (typeof module !== 'undefined' && module.exports) module.exports = api; else raiz.OCWebjurPortal = api;
})(typeof window !== 'undefined' ? window : globalThis);
