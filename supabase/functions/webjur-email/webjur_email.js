/* Leitor do e-mail diário da Webjur ("Leitura DJ ...").
 *
 * Estrutura conferida em 06/11/2026 em 4 e-mails reais (encaminhados à controladoria em
 * set/2026). Aceita o e-mail salvo (.eml), o corpo HTML (.html/.htm) ou o texto colado.
 * Não usa rede nem bibliotecas. Roda no navegador (window.OCWebjur) e no Node (testes).
 *
 * O leitor NÃO decide o que entra na base: ele monta as publicações e as contagens
 * declaradas pela própria Webjur; o banco (pub_registrar_remessa) confere de novo. */
(function (raiz) {
  'use strict';

  // ------------------------------------------------------------------ MIME (.eml)
  const latin1 = b => { let s = ''; for (let i = 0; i < b.length; i++) s += String.fromCharCode(b[i]); return s; };
  function decodificar(bytes, charset) {
    const cs = (charset || 'utf-8').toLowerCase().replace(/^"|"$/g, '');
    try { return new TextDecoder(cs === 'iso-8859-1' || cs === 'latin1' ? 'windows-1252' : cs).decode(bytes); }
    catch (e) { return new TextDecoder('utf-8').decode(bytes); }
  }
  function qp(s) {
    s = s.replace(/=\r?\n/g, '');
    const out = []; for (let i = 0; i < s.length; i++) {
      if (s[i] === '=' && /^[0-9A-Fa-f]{2}$/.test(s.substr(i + 1, 2))) { out.push(parseInt(s.substr(i + 1, 2), 16)); i += 2; }
      else out.push(s.charCodeAt(i) & 0xff);
    }
    return Uint8Array.from(out);
  }
  function b64(s) {
    const t = s.replace(/[^A-Za-z0-9+/=]/g, '');
    if (typeof atob === 'function') return Uint8Array.from(atob(t), c => c.charCodeAt(0));
    return Uint8Array.from(Buffer.from(t, 'base64'));
  }
  function cabecalhos(bloco) {
    const h = {}; bloco.replace(/\r?\n[ \t]+/g, ' ').split(/\r?\n/).forEach(l => {
      const m = l.match(/^([^:\s]+):\s*(.*)$/); if (m) h[m[1].toLowerCase()] = m[2];
    });
    return h;
  }
  function palavraCodificada(s) { // =?utf-8?Q?...?= / =?utf-8?B?...?=
    return (s || '').replace(/=\?([^?]+)\?([QqBb])\?([^?]*)\?=/g, (_, cs, enc, txt) =>
      decodificar(enc.toUpperCase() === 'B' ? b64(txt) : qp(txt.replace(/_/g, ' ')), cs));
  }
  /** Devolve as partes legíveis da mensagem: [{tipo:'html'|'texto', conteudo, cabecalhos}].
   *  multipart/alternative: fica a versão HTML; multipart/mixed: todas as partes;
   *  message/rfc822 (e-mail anexado, como nos encaminhamentos com vários e-mails): lido como mensagem própria. */
  function lerMime(bruto, cabMsg) {
    const sep = bruto.search(/\r?\n\r?\n/);
    const hd = cabecalhos(sep < 0 ? bruto : bruto.slice(0, sep));
    const msg = cabMsg || hd;
    const corpo = sep < 0 ? '' : bruto.slice(sep).replace(/^\r?\n\r?\n/, '');
    const ct = hd['content-type'] || 'text/plain';
    const cte = (hd['content-transfer-encoding'] || '').toLowerCase();
    const fronteira = (ct.match(/boundary="?([^";]+)"?/i) || [])[1];
    if (/^multipart\//i.test(ct) && fronteira) {
      let partes = [];
      for (const parte of corpo.split('--' + fronteira).slice(1)) {
        if (/^--/.test(parte)) break;
        partes = partes.concat(lerMime(parte.replace(/^\r?\n/, ''), msg));
      }
      if (/^multipart\/alternative/i.test(ct) && partes.some(x => x.tipo === 'html')) partes = partes.filter(x => x.tipo !== 'texto');
      return partes;
    }
    if (/^message\/rfc822/i.test(ct)) {
      const interno = cte === 'base64' ? latin1(b64(corpo)) : cte === 'quoted-printable' ? latin1(qp(corpo)) : corpo;
      return lerMime(interno, null);
    }
    if (!/^text\/(html|plain)/i.test(ct) || /attachment/i.test(hd['content-disposition'] || '') && !/^text\/html/i.test(ct)) return [];
    const cs = (ct.match(/charset="?([^";]+)"?/i) || [])[1];
    const bytes = cte === 'base64' ? b64(corpo) : cte === 'quoted-printable' ? qp(corpo) : Uint8Array.from(corpo, c => c.charCodeAt(0) & 0xff);
    return [{ tipo: /^text\/html/i.test(ct) ? 'html' : 'texto', conteudo: decodificar(bytes, cs), cabecalhos: msg }];
  }

  // ------------------------------------------------------------------ HTML -> linhas de texto
  const ENT = { nbsp: ' ', amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", ordm: 'º', ordf: 'ª', sect: '§', deg: '°',
    ndash: '–', mdash: '—', laquo: '«', raquo: '»', ldquo: '“', rdquo: '”', lsquo: '‘', rsquo: '’', hellip: '…', middot: '·',
    ccedil: 'ç', Ccedil: 'Ç', ntilde: 'ñ', Ntilde: 'Ñ', uuml: 'ü', Uuml: 'Ü' };
  'aeiouAEIOU'.split('').forEach(v => {
    const base = { a: 'aáàâãä', e: 'eéèêẽë', i: 'iíìîĩï', o: 'oóòôõö', u: 'uúùûũü' }[v.toLowerCase()];
    const up = v === v.toUpperCase();
    [['acute', 1], ['grave', 2], ['circ', 3], ['tilde', 4]].forEach(([n, k]) => { const c = base[k]; ENT[v + n] = up ? c.toUpperCase() : c; });
  });
  const entidades = s => s.replace(/&(#x[0-9a-f]+|#\d+|[a-z]+);/gi, (m, e) =>
    e[0] === '#' ? String.fromCodePoint(e[1] === 'x' || e[1] === 'X' ? parseInt(e.slice(2), 16) : parseInt(e.slice(1), 10)) : (ENT[e] !== undefined ? ENT[e] : m));
  function htmlParaTexto(html) {
    let t = html.replace(/<(script|style|head)[\s\S]*?<\/\1>/gi, '');
    t = t.replace(/<br\s*\/?>/gi, '\n').replace(/<\/(p|div|tr|li|h\d|table|blockquote)>/gi, '\n');
    t = t.replace(/<[^>]+>/g, '');
    t = entidades(t).replace(/\u00a0/g, ' ');
    return t.split(/\r?\n/).map(l => l.replace(/[ \t]+/g, ' ').trim()).filter(Boolean);
  }

  // ------------------------------------------------------------------ CNJ e datas
  const RE_CNJ = /\b(\d{7})-?(\d{2})\.?(\d{4})\.?(\d)\.?(\d{2})\.?(\d{4})\b/g;
  const cnjFormatado = m => `${m[1]}-${m[2]}.${m[3]}.${m[4]}.${m[5]}.${m[6]}`;
  function cnjsDoTexto(t) { const s = new Set(); for (const m of t.matchAll(RE_CNJ)) s.add(cnjFormatado(m)); return [...s]; }
  function digitoCnjValido(cnj) { // ISO 7064 mod 97-10 (Resolução CNJ 65/2008)
    const d = cnj.replace(/\D/g, ''); if (d.length !== 20) return false;
    const n = d.slice(0, 7), dv = d.slice(7, 9), resto = d.slice(9);
    let r = 0; for (const c of n + resto + '00') r = (r * 10 + Number(c)) % 97;
    return 98 - r === Number(dv);
  }
  const MESES = { jan: 1, fev: 2, mar: 3, abr: 4, mai: 5, jun: 6, jul: 7, ago: 8, set: 9, out: 10, nov: 11, dez: 12 };
  /** "seg, 28 de set de 2026 às 09:42" -> "2026-09-28T09:42:00-03:00" (horário de Brasília). */
  function dataEncaminhada(s) {
    const m = (s || '').match(/(\d{1,2}) de ([a-zç]{3})\.? de (\d{4})(?: às (\d{1,2}):(\d{2}))?/i);
    if (!m || !MESES[m[2].toLowerCase()]) return null;
    const p = n => String(n).padStart(2, '0');
    return `${m[3]}-${p(MESES[m[2].toLowerCase()])}-${p(m[1])}T${p(m[4] || 0)}:${p(m[5] || 0)}:00-03:00`;
  }
  const dataValida = s => /^\d{2}\/\d{2}\/\d{4}$/.test(s || '');

  // ------------------------------------------------------------------ leitura das publicações
  const RE_SECAO = /^Leitura (.+?) - (\d{2}\/\d{2}\/\d{4}) - Total de Publica[çc][õo]es: (\d+)\.?$/i;
  const RE_RESUMO = /^Leitura (.+?) \( ?(\d{2}\/\d{2}\/\d{4}) ?\) - Total publica[çc][õo]es: (\d+)/i;
  const RE_PUB = /^Publica[çc][ãa]o: (\d+)\s*\.?\s*$/i;
  const RE_RODAPE = /^Total de Publica[çc][õo]es \( ?Assinatura (.+?) ?\): (\d+)/i;
  const CAMPOS = [
    ['data_disponibilizacao', /^Data de Disponibiliza[çc][ãa]o:\s*(.*)$/i],
    ['data_publicacao', /^Data de Publica[çc][ãa]o:\s*(.*)$/i],
    ['jornal', /^Jornal:\s*(.*)$/i], ['caderno', /^Caderno:\s*(.*)$/i],
    ['local', /^Local:\s*(.*)$/i],
    // Layout "Tribunais Superiores" (STJ, TRFs): Tribunal / Vara / Seção no lugar de Caderno / Local
    ['tribunal_texto', /^Tribunal:\s*(.*)$/i], ['vara', /^Vara:\s*(.*)$/i], ['secao_diario', /^Se[çc][ãa]o:\s*(.*)$/i],
    ['pagina', /^P[áa]gina:\s*(.*)$/i]
  ];
  const FIM_TEOR = [RE_PUB, RE_RODAPE, RE_SECAO, /^N[ãa]o foi localizada qualquer publica/i, /^Observa[çc][õo]es importantes:/i];

  /** Tribunal e órgão julgador, só a partir do que o e-mail escreve (sem tabela de siglas presumida).
   *  "DJEN - Diário de Justiça Eletrônico Nacional - TJAL - 6ª Vara Cível" -> TJAL / 6ª Vara Cível
   *  Tribunal: "DJEN - Diário ... - STJ" + Vara: "..."                     -> STJ / Vara
   *  Tribunal: "Tribunal Regional Federal da 1ª Região - TRIBUNAL ..."      -> Tribunal Regional Federal da 1ª Região */
  function localParaTribunal(p) {
    const partes = s => (s || '').split(/\s+-\s+/).map(x => x.trim()).filter(Boolean);
    if (p.local) {
      const l = partes(p.local);
      if (l[0] === 'DJEN' && l.length >= 3) return { tribunal: l[2], orgao_julgador: l.slice(3).join(' - ') || p.vara || null };
      return { tribunal: null, orgao_julgador: p.vara || p.local };
    }
    if (p.tribunal_texto) {
      const t = partes(p.tribunal_texto);
      return { tribunal: t[0] === 'DJEN' && t.length >= 3 ? t.slice(2).join(' - ') : t[0], orgao_julgador: p.vara || null };
    }
    return { tribunal: null, orgao_julgador: p.vara || null };
  }
  /** Diários estaduais próprios (DJE, não DJEN) — vistos em 06/11/2026: "Caderno: TJMGFBH" + "Local: FBH BELO HORIZONTE";
   *  "Caderno: Tribunal de Justiça" + "Local: COMARCAS ... Campo Grande". A sigla vem do próprio código do caderno. */
  function tribunalDoCaderno(p) {
    const c = (p.caderno || '').trim();
    const sigla = c.match(/^(TJ[A-Z]{2}|TRF\d|TRT\d{1,2}|TRE[A-Z]{2}|STJ|STF|TST)/);
    if (sigla) return sigla[1];
    if (/Tribunal/i.test(c)) return p.secao ? `${c} (${p.secao})` : c;
    return null;
  }

  function lerLinhas(linhas) {
    const r = { formato: 'webjur_email_v1', cliente: null, chave_cliente: null, recebido_em: null,
                resumo: [], secoes: [], publicacoes: [], avisos: [] };
    let secao = null, pub = null;
    const fecharPub = () => {
      if (!pub) return;
      let teor = pub._teor.join('\n');
      const url = teor.match(/Acesso ao documento:\s*(\S+)/i), idd = teor.match(/Identificador do documento:\s*(\d+)/i);
      teor = teor.replace(/\s*Acesso ao documento:\s*\S+/i, '').replace(/\s*Identificador do documento:\s*\d+/i, '').trim();
      pub.url_origem = url ? url[1] : null; pub.id_documento = idd ? idd[1] : null;
      pub.tipo_comunicacao = pub._teor[0] || null;
      pub.teor = teor; delete pub._teor;
      const t = localParaTribunal(pub); pub.tribunal = t.tribunal || tribunalDoCaderno(pub); pub.orgao_julgador = t.orgao_julgador;
      const cab = teor.match(/PROCESSO:?\s*(?:n[º°o.]*\s*)?(\d{7}-?\d{2}\.?\d{4}\.?\d\.?\d{2}\.?\d{4})/i);
      pub.cnjs_mencionados = cnjsDoTexto(teor);
      pub.cnj = cab ? cnjsDoTexto(cab[1])[0] : (pub.cnjs_mencionados.length === 1 ? pub.cnjs_mencionados[0] : null);
      const a = pub.alertas = [];
      if (!pub.cnj) a.push(pub.cnjs_mencionados.length ? 'cnj_ambiguo' : 'cnj_ausente');
      else if (!digitoCnjValido(pub.cnj)) a.push('cnj_digito_invalido');
      if (pub.cnjs_mencionados.length > 1) a.push('varios_cnj_no_teor');
      if (!dataValida(pub.data_disponibilizacao)) a.push('data_disponibilizacao_invalida');
      if (pub.data_publicacao && !dataValida(pub.data_publicacao)) a.push('data_publicacao_invalida');
      if (!pub.id_documento) a.push('sem_identificador_documento');
      if (!pub.tribunal) a.push('tribunal_nao_identificado');
      if (!teor) a.push('teor_vazio');
      r.publicacoes.push(pub); pub = null;
    };
    for (let i = 0; i < linhas.length; i++) {
      const l = linhas[i];
      let m;
      if (pub && pub._noTeor && !FIM_TEOR.some(re => re.test(l))) { pub._teor.push(l); continue; }
      if (!r.secoes.length && (m = l.match(/^Chave secreta do cliente:\s*(.+)$/i))) { r.chave_cliente = m[1].trim(); continue; }
      if (!r.cliente && (m = l.match(/^Cliente\s*(.+)$/))) { r.cliente = m[1].trim(); continue; }
      if (!r.recebido_em && !r.secoes.length && /^Data:\s/.test(l)) { r.recebido_em = dataEncaminhada(l); continue; }
      if ((m = l.match(RE_RESUMO))) { r.resumo.push({ caderno: m[1].trim(), data: m[2], total: Number(m[3]) }); continue; }
      if ((m = l.match(RE_SECAO))) {
        fecharPub();
        secao = { ordem: r.secoes.length + 1, caderno: m[1].trim(), data: m[2], declarado: Number(m[3]), lidas: 0, total_rodape: null };
        r.secoes.push(secao); continue;
      }
      if ((m = l.match(RE_PUB))) {
        fecharPub();
        if (!secao) { r.avisos.push(`Publicação ${m[1]} fora de uma seção "Leitura DJ".`); }
        pub = { seq: Number(m[1]), secao: secao ? secao.caderno : null, secao_data: secao ? secao.data : null,
                secao_ordem: secao ? secao.ordem : null, _teor: [], _noTeor: false };
        if (secao) secao.lidas++;
        continue;
      }
      if ((m = l.match(RE_RODAPE))) {
        fecharPub();
        if (secao) secao.total_rodape = Number(m[2]);
        continue;
      }
      if (pub && !pub._noTeor) {
        const c = CAMPOS.find(([, re]) => re.test(l));
        if (c) { pub[c[0]] = l.match(c[1])[1].trim(); if (c[0] === 'pagina') pub._noTeor = true; continue; }
      }
      if (pub && pub._noTeor && FIM_TEOR.some(re => re.test(l))) { fecharPub(); i--; continue; }
    }
    fecharPub();
    r.publicacoes.forEach(p => delete p._noTeor);
    // ---- conferência de completude com os números que a própria Webjur declara
    for (const s of r.secoes) {
      if (s.lidas !== s.declarado) r.avisos.push(`${s.caderno} ${s.data}: a Webjur declara ${s.declarado} publicação(ões), o leitor encontrou ${s.lidas}.`);
      if (s.total_rodape !== null && s.total_rodape !== s.declarado) r.avisos.push(`${s.caderno} ${s.data}: total do rodapé (${s.total_rodape}) difere do cabeçalho (${s.declarado}).`);
    }
    // O mesmo diário e data podem vir em duas seções (visto em 06/11/2026: DJ Minas Gerais 04/11 com 25 e 4):
    // o resumo é comparado com as seções na mesma ordem em que aparecem.
    const usadas = new Set();
    for (const x of r.resumo) {
      const s = r.secoes.find(y => !usadas.has(y) && y.caderno === x.caderno && y.data === x.data);
      if (s) usadas.add(s);
      if (!s) r.avisos.push(`${x.caderno} ${x.data} consta no resumo, mas a seção não foi encontrada no e-mail.`);
      else if (s.declarado !== x.total) r.avisos.push(`${x.caderno} ${x.data}: resumo informa ${x.total}, seção informa ${s.declarado}.`);
    }
    r.total_declarado = r.secoes.reduce((a, s) => a + s.declarado, 0);
    // A "chave" do assunto ("Public 8. UFs 28.") trouxe, nos 4 e-mails conferidos, o total de
    // publicações e o número de diários lidos. Serve de terceira conferência; divergência vira aviso.
    const ch = (r.chave_cliente || '').match(/Public (\d+)\. UFs (\d+)\./i);
    if (ch) {
      r.chave_total = Number(ch[1]); r.chave_ufs = Number(ch[2]);
      if (r.chave_total !== r.total_declarado) r.avisos.push(`A chave do e-mail indica ${r.chave_total} publicação(ões); as seções somam ${r.total_declarado}.`);
      if (r.chave_ufs !== r.secoes.length) r.avisos.push(`A chave do e-mail indica ${r.chave_ufs} diários; o e-mail tem ${r.secoes.length} seções.`);
    }
    r.total_lido = r.publicacoes.length;
    r.reconhecido = r.secoes.length > 0;
    if (!r.reconhecido) r.avisos.push('O conteúdo não tem o formato do e-mail diário da Webjur ("Leitura DJ ... - Total de Publicações").');
    r.completo = r.reconhecido && r.total_lido === r.total_declarado && r.secoes.every(s => s.lidas === s.declarado);
    return r;
  }

  /** Um encaminhamento pode trazer vários e-mails da Webjur no mesmo corpo (visto em 06/11/2026:
   *  3 e-mails no corpo + 16 anexos .eml). Cada e-mail começa em "Cliente <nome>" seguido de "Resumo";
   *  o cabeçalho logo acima (site, endereço, linhas do encaminhamento) vai junto com ele. */
  const CAB_EMAIL = /^(www\.webjur\.com\.br|Avenida |Belo Horizonte\/MG|-+ ?Mensagem encaminhada ?-+|De:|Data:|Assunto:|Para:|Chave secreta do cliente:|Sent with|--)/i;
  function dividirEmails(linhas) {
    const inicios = [];
    for (let i = 0; i < linhas.length - 1; i++) {
      if (/^Cliente\s*\S/.test(linhas[i]) && /^Resumo$/i.test(linhas[i + 1])) {
        let k = i; while (k > 0 && i - k < 12 && CAB_EMAIL.test(linhas[k - 1])) k--;
        inicios.push(inicios.length ? k : 0);
      }
    }
    if (inicios.length <= 1) return [linhas];
    return inicios.map((ini, j) => linhas.slice(ini, j + 1 < inicios.length ? inicios[j + 1] : linhas.length));
  }

  /** Lê TODOS os e-mails da Webjur contidos no arquivo/texto. Devolve uma lista (um item por e-mail).
   *  bytesOuTexto: Uint8Array (arquivo) ou string (texto colado). nome: usado para detectar o tipo. */
  function lerEmails(bytesOuTexto, nome) {
    const ext = (nome || '').toLowerCase().split('.').pop();
    let partes;
    if (typeof bytesOuTexto === 'string') partes = [{ tipo: /<html|<table|<br/i.test(bytesOuTexto) ? 'html' : 'texto', conteudo: bytesOuTexto, cabecalhos: {} }];
    else if (ext === 'eml') partes = lerMime(latin1(bytesOuTexto));
    else {
      const s = decodificar(bytesOuTexto, 'utf-8');
      partes = [{ tipo: ext === 'html' || ext === 'htm' || /<html|<table/i.test(s) ? 'html' : 'texto', conteudo: s, cabecalhos: {} }];
    }
    const saida = [];
    for (const p of partes) {
      const linhas = p.tipo === 'html' ? htmlParaTexto(p.conteudo)
        : p.conteudo.split(/\r?\n/).map(l => l.replace(/[ \t ]+/g, ' ').trim()).filter(Boolean);
      for (const bloco of dividirEmails(linhas)) {
        const r = lerLinhas(bloco);
        if (!r.reconhecido && (partes.length > 1 || saida.length)) continue; // parte sem e-mail da Webjur (ex.: texto do encaminhamento)
        const cab = p.cabecalhos || {};
        if (cab.date) { const d = new Date(cab.date); if (!isNaN(d)) r.recebido_em = r.recebido_em || d.toISOString(); }
        r.assunto = cab.subject ? palavraCodificada(cab.subject) : null;
        r.remetente = cab.from ? palavraCodificada(cab.from) : null;
        if (!r.chave_cliente && r.assunto) { const m = r.assunto.match(/Public \d+\. UFs \d+\. \([^)]*\)/i); if (m) r.chave_cliente = m[0]; }
        // Base do hash da remessa: o conteúdo da Webjur a partir de "Cliente", sem as linhas do encaminhamento.
        // Assim o mesmo e-mail, vindo sozinho ou dentro de outro encaminhamento, é reconhecido como já importado.
        const ini = bloco.findIndex((l, i) => /^Cliente\s*\S/.test(l) && /^Resumo$/i.test(bloco[i + 1] || ''));
        r.texto_bloco = bloco.slice(Math.max(ini, 0)).join('\n');
        saida.push(r);
      }
    }
    if (!saida.length) saida.push(lerLinhas([]));
    saida.forEach((r, i) => { r.indice = i + 1; r.de = saida.length; });
    return saida;
  }
  /** Compatível com a versão anterior: o primeiro e-mail do arquivo. */
  const lerEmail = (b, n) => lerEmails(b, n)[0];

  /** Objeto aceito por pub_registrar (o banco guarda o objeto inteiro como conteúdo original). */
  function paraRegistro(p, remessa) {
    return {
      cnj: p.cnj, cnjs_mencionados: p.cnjs_mencionados, data_disponibilizacao: p.data_disponibilizacao || null,
      data_publicacao: p.data_publicacao || null, tribunal: p.tribunal, orgao_julgador: p.orgao_julgador,
      teor: p.teor, resumo: null, url_origem: p.url_origem, id_documento: p.id_documento,
      jornal: p.jornal || null, caderno: p.caderno || null, local: p.local || null, pagina: p.pagina || null,
      tribunal_texto: p.tribunal_texto || null, vara: p.vara || null, secao_diario: p.secao_diario || null,
      tipo_comunicacao: p.tipo_comunicacao, secao: p.secao, secao_data: p.secao_data, secao_ordem: p.secao_ordem, seq: p.seq,
      alertas: p.alertas, recebido_em: remessa.recebido_em || null
    };
  }

  const api = { lerEmail, lerEmails, dividirEmails, lerLinhas, htmlParaTexto, lerMime, paraRegistro, digitoCnjValido, cnjsDoTexto, dataEncaminhada };
  if (typeof module !== 'undefined' && module.exports) module.exports = api; else raiz.OCWebjur = api;
})(typeof window !== 'undefined' ? window : globalThis);
