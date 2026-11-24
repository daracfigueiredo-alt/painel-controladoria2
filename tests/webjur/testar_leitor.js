// Testes do leitor do e-mail Webjur (painel/js/webjur_email.js).
// 1) e-mails FICTÍCIOS (tests/webjur/fixtures, gerados por gerar_fixtures.py);
// 2) se existirem, os e-mails REAIS guardados fora do git (tests/out/webjur_real_*): só contagens.
const fs = require('fs'), path = require('path');
const W = require('../../painel/js/webjur_email.js');
const FX = path.join(__dirname, 'fixtures'), REAL = path.join(__dirname, '..', 'out');
const res = [];
const check = (n, e, o) => res.push([n, String(e), String(o), String(e) === String(o) ? 'OK' : 'FALHA']);
const ler = (dir, f) => W.lerEmail(new Uint8Array(fs.readFileSync(path.join(dir, f))), f);

const e1 = ler(FX, 'email_ficticio_1.html');
check('E1: formato reconhecido', true, e1.reconhecido);
check('E1: chave, cliente e data de envio', 'Public 4. UFs 3. (00.00000000)|ADVOGADA FICTICIA DE TESTE|2026-10-05T09:40:00-03:00',
      `${e1.chave_cliente}|${e1.cliente}|${e1.recebido_em}`);
check('E1: 3 seções, 4 declaradas, 4 lidas, completo', '3|4|4|true', `${e1.secoes.length}|${e1.total_declarado}|${e1.total_lido}|${e1.completo}`);
check('E1: seção sem publicação conta 0 e não gera publicação', '0|0', `${e1.secoes[2].declarado}|${e1.secoes[2].lidas}`);
const [p1, p2, p3, p4] = e1.publicacoes;
check('E1 p1: datas de disponibilização e publicação', '05/10/2026|06/10/2026', `${p1.data_disponibilizacao}|${p1.data_publicacao}`);
check('E1 p1: tribunal e órgão julgador (Local DJEN)', 'TJAL|1ª Vara Cível Fictícia', `${p1.tribunal}|${p1.orgao_julgador}`);
check('E1 p1: CNJ do cabeçalho "PROCESSO:"', '0000101-95.2026.8.02.0001', p1.cnj);
check('E1 p1: identificador e URL do documento', '900000001|https://exemplo.invalid/doc?x=900000001', `${p1.id_documento}|${p1.url_origem}`);
check('E1 p1: identificador e URL saem do teor', false, /Identificador do documento|Acesso ao documento/.test(p1.teor));
check('E1 p1: teor começa pelo tipo e preserva o despacho', 'true|true', `${p1.teor.startsWith('Intimação')}|${p1.teor.includes('Primeiro despacho ficticio: cite-se.')}`);
check('E1 p1: sem alertas', '', p1.alertas.join(','));
check('E1 p1 x p2: mesmo CNJ e data, teores e identificadores diferentes', 'true|true|true',
      `${p1.cnj === p2.cnj && p1.data_disponibilizacao === p2.data_disponibilizacao}|${p1.teor !== p2.teor}|${p1.id_documento !== p2.id_documento}`);
check('E1 p4 (Tribunais Superiores): tribunal pela linha "Tribunal:"', 'Tribunal Regional Federal da 1ª Região', p4.tribunal);
check('E1 p4: sem identificador → alerta', 'sem_identificador_documento', p4.alertas.join(','));
check('E1 p4: CNJ lido', '0000201-72.2026.8.13.0024', p4.cnj);
check('E1: texto de encaminhamento e avisos da Webjur não entram em nenhum teor', false,
      e1.publicacoes.some(p => /encaminhamento|Observações importantes|Vencimento da assinatura/.test(p.teor)));

const eml = ler(FX, 'email_ficticio_1.eml');
check('.eml (multipart, quoted-printable): mesmo resultado do HTML', JSON.stringify(e1.publicacoes), JSON.stringify(eml.publicacoes));
check('.eml: assunto decodificado', 'Fwd: Public 4. UFs 3. (00.00000000)', eml.assunto);
const txt = W.lerEmail(W.htmlParaTexto(fs.readFileSync(path.join(FX, 'email_ficticio_1.html'), 'utf8')).join('\n'), 'colado.txt');
check('Texto colado: mesmas 4 publicações', '4|true', `${txt.total_lido}|${txt.completo}`);

const div = ler(FX, 'email_ficticio_divergente.html');
check('Divergente: não completo', false, div.completo);
check('Divergente: aviso de contagem e de seção do resumo ausente', '2', div.avisos.filter(a => /declara 2|não foi encontrada/.test(a)).length);

check('Não-Webjur: texto qualquer não é reconhecido', 'false|0', (r => `${r.reconhecido}|${r.publicacoes.length}`)(W.lerEmail('Olá, segue o relatório.', 'x.txt')));
check('CNJ: dígito verificador (válido / inválido)', 'true|false', `${W.digitoCnjValido('0000101-95.2026.8.02.0001')}|${W.digitoCnjValido('0000101-96.2026.8.02.0001')}`);
const ambig = W.lerLinhas(['Leitura DJ Teste - 01/10/2026 - Total de Publicações: 1.', 'Publicação: 1.', 'Data de Disponibilização: 01/10/2026',
  'Página: 1', 'Intimação', 'Processos 0000101-95.2026.8.02.0001 e 0000102-80.2026.8.02.0001 apensados.']);
check('Teor com 2 CNJ e sem "PROCESSO:" → CNJ não escolhido (ambíguo)', 'null|cnj_ambiguo,varios_cnj_no_teor,sem_identificador_documento,tribunal_nao_identificado',
      `${ambig.publicacoes[0].cnj}|${ambig.publicacoes[0].alertas.join(',')}`);
check('Data do encaminhamento ("seg, 28 de set de 2026 às 09:42")', '2026-09-28T09:42:00-03:00', W.dataEncaminhada('Data: seg, 28 de set de 2026 às 09:42'));

// ---- seções repetidas e encaminhamentos com vários e-mails
const rep = ler(FX, 'email_ficticio_secoes_repetidas.html');
check('Mesmo diário e data em 2 seções: completo, sem aviso falso do resumo', 'true|0|1,2',
      `${rep.completo}|${rep.avisos.length}|${[...new Set(rep.publicacoes.map(p => p.secao_ordem))].join(',')}`);
const dois = W.lerEmails(new Uint8Array(fs.readFileSync(path.join(FX, 'encaminhamento_dois_emails.html'))), 'encaminhamento_dois_emails.html');
check('Encaminhamento com 2 e-mails no corpo: 2 remessas, cada uma com sua chave', '2|Public 3. UFs 2. (00.00000000)|Public 2. UFs 1. (00.00000000)',
      `${dois.length}|${dois[0].chave_cliente}|${dois[1].chave_cliente}`);
check('Encaminhamento: contagem de cada e-mail conferida separadamente', 'true|false', `${dois[0].completo}|${dois[1].completo}`);
check('Encaminhamento: texto do encaminhamento não vira e-mail nem teor', 'false',
      dois.some(r => r.publicacoes.some(p => /texto fictício do encaminhamento/.test(p.teor))));
const anexo = W.lerEmails(new Uint8Array(fs.readFileSync(path.join(FX, 'encaminhamento_com_anexo.eml'))), 'encaminhamento_com_anexo.eml');
check('.eml com e-mail da Webjur anexado (message/rfc822): lido, com data e assunto do anexo', '1|2|true|2026-10-05T15:10:00-03:00|Public 2. UFs 2. (00.00000000)',
      `${anexo.length}|${anexo[0].total_lido}|${anexo[0].completo}|${anexo[0].recebido_em}|${anexo[0].assunto}`);
check('DJE estadual: tribunal pela sigla do caderno ("TJMGFBH" → TJMG)', 'TJMG',
      W.lerLinhas(['Leitura DJ Minas Gerais - 04/11/2026 - Total de Publicações: 1.', 'Publicação: 1.', 'Data de Disponibilização: 04/11/2026',
        'Jornal:', 'Caderno: TJMGFBH', 'Local: FBH BELO HORIZONTE', 'Página: 1', 'Expediente de 04/11/2026', '00991 - 0000201-72.2026.8.13.0024']).publicacoes[0].tribunal);

// ---- exportação "Planilha" do portal
const P = require('../../painel/js/webjur_portal.js');
const lerP = (dir, f) => P.lerExportacaoCsv(new Uint8Array(fs.readFileSync(path.join(dir, f))), f);
const pp1 = lerP(FX, 'portal_exportacao_1.csv');
check('Portal CSV: reconhecido, completo (5 = TOTAL DE PUBLICAÇÕES)', 'true|true|5|5', `${pp1.reconhecido}|${pp1.completo}|${pp1.total_declarado}|${pp1.total_lido}`);
check('Portal CSV: código Webjur, UF, datas, tribunal (DJEN), órgão, tipo', '8000000001|AL|05/10/2026|06/10/2026|TJAL|1ª Vara Cível Fictícia|Intimação',
      (p => [p.codigo_webjur, p.uf, p.data_disponibilizacao, p.data_publicacao, p.tribunal, p.orgao_julgador, p.tipo_comunicacao].join('|'))(pp1.publicacoes[0]));
check('Portal CSV: identificador do documento extraído e retirado do teor', '900000001|false',
      `${pp1.publicacoes[0].id_documento}|${/Identificador do documento|Acesso ao documento/.test(pp1.publicacoes[0].teor)}`);
check('Portal CSV: acentos do Windows-1252 preservados', 'true', /Cível/.test(pp1.publicacoes[0].orgao_julgador));
const pi = lerP(FX, 'portal_exportacao_incompleta.csv');
check('Portal CSV: total do arquivo ≠ linhas lidas → não completo, com aviso', 'false|1', `${pi.completo}|${pi.avisos.length}`);
check('Portal CSV: arquivo que não é a exportação → não reconhecido', 'false', P.lerExportacaoCsv('a;b;c\r\n1;2;3', 'x.csv').reconhecido);

// ---- e-mails reais (fora do git), se presentes: contagens e alertas (informativo)
const reais = fs.existsSync(REAL) ? fs.readdirSync(REAL).filter(f => f.startsWith('webjur_real_')).sort() : [];
const reaisEmail = reais.filter(f => /\.(html|eml)$/.test(f));
let nEmails = 0, ok = 0, tot = 0; const alertas = {};
for (const f of reaisEmail) for (const r of W.lerEmails(new Uint8Array(fs.readFileSync(path.join(REAL, f))), f)) {
  nEmails++; tot += r.total_lido;
  if (r.completo && r.avisos.length === 0) ok++;
  r.publicacoes.forEach(p => p.alertas.forEach(a => { alertas[a] = (alertas[a] || 0) + 1; }));
}
const csvReal = reais.find(f => /portal.*\.csv$/.test(f));
if (csvReal) {
  const pr = lerP(REAL, csvReal);
  check('Real (portal 05/11): 39 publicações, completo, sem avisos, todas com CNJ válido', 'true|39|0|0',
        `${pr.completo}|${pr.total_lido}|${pr.avisos.length}|${pr.publicacoes.filter(p => !p.cnj || p.alertas.includes('cnj_digito_invalido')).length}`);
}
if (reais.length) {
  check(`Reais: ${nEmails} e-mails em ${reaisEmail.length} arquivos, todos completos e sem avisos`, nEmails, ok);
  check('Reais: nenhuma publicação sem CNJ (só ambíguos legítimos) nem com dígito inválido', '0|0', `${alertas.cnj_ausente || 0}|${alertas.cnj_digito_invalido || 0}`);
  console.log(`(reais: ${tot} publicações; alertas: ${JSON.stringify(alertas)})`);
}

const w = Math.max(...res.map(x => x[0].length));
res.forEach(([n, e, o, s]) => console.log(`${s.padEnd(5)} | ${n.padEnd(w)} | esperado: ${e.slice(0, 60)} | obtido: ${o.slice(0, 60)}`));
console.log(`\n${res.filter(x => x[3] === 'OK').length}/${res.length} OK — ${new Date().toLocaleString('pt-BR')}`);
process.exit(res.every(x => x[3] === 'OK') ? 0 : 1);
