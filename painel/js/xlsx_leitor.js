/* Leitor da exportação .xlsx do ADVBOX, executado no navegador do administrador.
 * Reproduz o mesmo formato de tests/xlsx_para_json.py (openpyxl), que é o formato
 * aceito por importar_arquivo(): lista de objetos {cabeçalho: texto}, célula vazia = ''.
 *  - primeira aba; primeira linha = cabeçalho;
 *  - texto exatamente como está na planilha (inclui quebras de linha);
 *  - número inteiro vira "5"; booleano vira "True"/"False" (como str() do Python);
 *  - linhas vazias no FINAL são descartadas; vazias no meio são mantidas
 *    (o número da linha precisa bater com a planilha para o relatório de erros).
 * Datas gravadas como número (não é o caso da exportação do ADVBOX, que grava texto)
 * chegam como o número serial e são rejeitadas pelo banco com mensagem por linha:
 * nada é convertido silenciosamente.
 * Depende de fflate (descompactação). Sem rede, sem armazenamento. */
(function (root) {
  'use strict';
  const NS = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main';
  const NS_R = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships';
  const LIMITE_BYTES = 20 * 1024 * 1024;           // arquivo compactado
  const LIMITE_DESCOMPACTADO = 200 * 1024 * 1024;  // proteção contra arquivo malformado

  class ErroPlanilha extends Error {}

  function xml(texto) {
    const doc = new DOMParser().parseFromString(texto, 'application/xml');
    if (doc.getElementsByTagName('parsererror').length) throw new ErroPlanilha('Arquivo .xlsx com XML inválido.');
    return doc;
  }
  const filhos = (el, nome) => Array.from(el.childNodes).filter(n => n.nodeType === 1 && n.localName === nome);
  // openpyxl desfaz o escape _xHHHH_ do formato OOXML
  const desescapar = s => s.replace(/_x([0-9A-Fa-f]{4})_/g, (_, h) => String.fromCharCode(parseInt(h, 16)));
  // texto de <si> ou <is>: <t> direto ou <r><t>; ignora <rPh> (fonética)
  function textoRico(el) {
    let s = '';
    for (const n of el.childNodes) {
      if (n.nodeType !== 1) continue;
      if (n.localName === 't') s += n.textContent;
      else if (n.localName === 'r') for (const t of filhos(n, 't')) s += t.textContent;
    }
    return desescapar(s);
  }
  function colunaIdx(ref) {
    const m = /^([A-Z]+)\d+$/.exec(ref || '');
    if (!m) return null;
    let n = 0; for (const ch of m[1]) n = n * 26 + (ch.charCodeAt(0) - 64);
    return n - 1;
  }
  function numeroComoPython(v) {
    const n = Number(v);
    if (!Number.isFinite(n)) return v;
    if (Number.isInteger(n) && !/[.eE]/.test(v)) return String(n);   // openpyxl devolve int
    return Number.isInteger(n) ? n.toFixed(1) : String(n);            // float: 5.0 -> "5.0"
  }

  function caminhoAlvo(base, alvo) {
    if (alvo.startsWith('/')) return alvo.slice(1);
    const partes = base.split('/'); partes.pop();
    for (const p of alvo.split('/')) { if (p === '..') partes.pop(); else if (p !== '.') partes.push(p); }
    return partes.join('/');
  }

  /** bytes: Uint8Array do arquivo. Devolve {aba, cabecalho, linhas, avisos}. */
  function lerPlanilha(bytes, fflate) {
    fflate = fflate || root.fflate;
    if (!(bytes instanceof Uint8Array)) bytes = new Uint8Array(bytes);
    if (bytes.length > LIMITE_BYTES) throw new ErroPlanilha('Arquivo maior que 20 MB.');
    if (bytes[0] !== 0x50 || bytes[1] !== 0x4b) throw new ErroPlanilha('O arquivo não é uma planilha .xlsx (formato ZIP).');
    let total = 0;
    let zip;
    try {
      zip = fflate.unzipSync(bytes, { filter: f => {
        total += f.originalSize || 0;
        if (total > LIMITE_DESCOMPACTADO) throw new ErroPlanilha('Conteúdo descompactado grande demais.');
        return /^(xl\/workbook\.xml|xl\/_rels\/workbook\.xml\.rels|xl\/sharedStrings\.xml|xl\/worksheets\/[^/]+\.xml)$/.test(f.name);
      } });
    } catch (e) {
      if (e instanceof ErroPlanilha) throw e;
      throw new ErroPlanilha('Não foi possível abrir o arquivo .xlsx: ' + e.message);
    }
    const dec = new TextDecoder('utf-8');
    const ler = nome => { if (!zip[nome]) throw new ErroPlanilha('Arquivo .xlsx incompleto: falta ' + nome + '.'); return xml(dec.decode(zip[nome])); };

    const wb = ler('xl/workbook.xml');
    const sheets = wb.getElementsByTagNameNS(NS, 'sheet');
    if (!sheets.length) throw new ErroPlanilha('A planilha não tem abas.');
    const aba = sheets[0].getAttribute('name');
    const rid = sheets[0].getAttributeNS(NS_R, 'id');
    const rels = ler('xl/_rels/workbook.xml.rels');
    let alvo = null;
    for (const r of rels.getElementsByTagName('Relationship')) if (r.getAttribute('Id') === rid) alvo = r.getAttribute('Target');
    if (!alvo) throw new ErroPlanilha('Não foi possível localizar a primeira aba.');
    const caminhoAba = caminhoAlvo('xl/workbook.xml', alvo);

    const sst = [];
    if (zip['xl/sharedStrings.xml']) for (const si of ler('xl/sharedStrings.xml').getElementsByTagNameNS(NS, 'si')) sst.push(textoRico(si));

    const sheet = ler(caminhoAba);
    const grade = [];   // [numeroLinha] -> array de valores
    let maxCol = 0, maxLinha = 0;
    for (const row of sheet.getElementsByTagNameNS(NS, 'row')) {
      const rn = parseInt(row.getAttribute('r'), 10);
      const valores = [];
      let k = 0;
      for (const c of filhos(row, 'c')) {
        const idx = c.hasAttribute('r') ? colunaIdx(c.getAttribute('r')) : k;
        k = idx + 1;
        const t = c.getAttribute('t') || 'n';
        const vEl = filhos(c, 'v')[0];
        const v = vEl ? vEl.textContent : null;
        let val = null;
        if (t === 's') val = v === null ? null : sst[parseInt(v, 10)];
        else if (t === 'inlineStr') { const is = filhos(c, 'is')[0]; val = is ? textoRico(is) : null; }
        else if (t === 'str' || t === 'e') val = v === null ? null : desescapar(v);
        else if (t === 'b') val = v === null ? null : (v === '1' ? 'True' : 'False');
        else val = v === null || v === '' ? null : numeroComoPython(v);
        if (val !== null && val !== undefined) { valores[idx] = val; maxCol = Math.max(maxCol, idx + 1); }
      }
      grade[rn] = valores;
      if (valores.some(x => x !== undefined && x !== null)) maxLinha = Math.max(maxLinha, rn);
    }
    if (!grade[1]) throw new ErroPlanilha('A primeira linha (cabeçalho) está vazia.');
    const cabecalho = Array.from({ length: maxCol }, (_, i) => (grade[1][i] === undefined ? 'None' : String(grade[1][i])));
    const linhas = [];
    for (let rn = 2; rn <= maxLinha; rn++) {
      const vals = grade[rn] || [];
      const o = {};
      cabecalho.forEach((h, i) => { o[h] = vals[i] === undefined || vals[i] === null ? '' : String(vals[i]); });
      linhas.push(o);
    }
    const avisos = [];
    if (sheets.length > 1) avisos.push(`A planilha tem ${sheets.length} abas; só a primeira ("${aba}") foi lida.`);
    return { aba, cabecalho, linhas, avisos };
  }

  async function sha256Hex(bytes) {
    const h = await crypto.subtle.digest('SHA-256', bytes);
    return Array.from(new Uint8Array(h)).map(b => b.toString(16).padStart(2, '0')).join('');
  }

  // "Advbox-2026-10-24_0717524.xlsx" -> "2026-10-24T12:00:00-03:00" (só a data é conhecida)
  function dataExportacaoDoNome(nome) {
    const m = /Advbox-(\d{4})-(\d{2})-(\d{2})_/i.exec(nome || '');
    return m ? `${m[1]}-${m[2]}-${m[3]}T12:00:00-03:00` : null;
  }

  root.OCPlanilha = { lerPlanilha, sha256Hex, dataExportacaoDoNome, ErroPlanilha };
})(typeof globalThis !== 'undefined' ? globalThis : this);
