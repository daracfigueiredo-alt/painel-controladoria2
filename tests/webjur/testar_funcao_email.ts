// Teste da Edge Function webjur-email (Deno): leitura dos e-mails enviados pelo script da conta da
// controladoria, sem rede e sem banco (o registro no banco é simulado). Dados fictícios.
// Rodar: deno run --allow-read tests/webjur/testar_funcao_email.ts
import { processar } from '../../supabase/functions/webjur-email/index.ts';

const raiz = new URL('../../', import.meta.url);
const ler = (p: string) => Deno.readFileSync(new URL(p, raiz));
const b64 = (u: Uint8Array) => { let s = ''; for (const x of u) s += String.fromCharCode(x); return btoa(s); };
let ok = 0, falhas = 0;
const check = (nome: string, esperado: unknown, obtido: unknown) => {
  const e = JSON.stringify(esperado), o = JSON.stringify(obtido);
  if (e === o) { ok++; console.log('OK  ', nome); } else { falhas++; console.log('FALHA', nome, '— esperado', e, 'obtido', o); }
};
const sha = async (t: string) => [...new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(t)))].map(x => x.toString(16).padStart(2, '0')).join('');
const comoEml = (html: Uint8Array) => {
  const cab = 'From: webjur@webjur.com.br\r\nTo: controladoria@exemplo.invalid\r\nSubject: Public 3. UFs 1. (teste)\r\nDate: 5 Nov 2026 12:39:08 -0300\r\n' +
              'MIME-Version: 1.0\r\nContent-Type: text/html; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n';
  const corpo = b64(html).replace(/.{76}/g, '$&\r\n');
  return new TextEncoder().encode(cab + corpo + '\r\n');
};

// 1. a cópia do leitor na função é idêntica à do painel (uma só regra de leitura)
check('webjur_email.js da função é idêntico ao do painel', true,
  new TextDecoder().decode(ler('painel/js/webjur_email.js')) === new TextDecoder().decode(ler('supabase/functions/webjur-email/webjur_email.js')));

// 2. e-mail completo: registra uma remessa, com o mesmo hash que o painel usaria
const chamadas: any[] = [];
const registrar = async (nome: string, args: any) => { chamadas.push({ nome, args }); return { status: 'importada', remessa_id: 7, situacao: 'completa', novas: args.p_publicacoes.length, ja_registradas: 0, rejeitadas: 0 }; };
const raw1 = ler('tests/webjur/fixtures/email_ficticio_1.eml');
const r1 = await processar({ gmail_id: 'g1', assunto: 'Public', raw_base64: b64(raw1) }, registrar);
check('e-mail completo: ok', true, r1.ok);
check('e-mail completo: uma chamada a pub_registrar_remessa', ['pub_registrar_remessa'], chamadas.map(c => c.nome));
check('origem webjur_gmail', 'webjur_gmail', chamadas[0]?.args.p_origem);
const W = (globalThis as any).OCWebjur;
const esperado = W.lerEmails(raw1, 'x.eml')[0];
check('mesmo hash do painel (sha256 do bloco a partir de "Cliente")', await sha(esperado.texto_bloco), chamadas[0]?.args.p_arquivo_sha256);
check('publicações enviadas = lidas', esperado.total_lido, chamadas[0]?.args.p_publicacoes.length);
check('seções enviadas', esperado.secoes.length, chamadas[0]?.args.p_remessa.secoes.length);

// 3. já importado (ex.: importado à mão no painel antes) conta como ok
const r2 = await processar({ gmail_id: 'g1', raw_base64: b64(raw1) }, async () => ({ status: 'ja_importada', remessa_id: 7 }));
check('já importado: ok, sem duplicar', [true, 'ja_importada'], [r2.ok, r2.remessas[0].status]);

// 4. contagem divergente: NÃO registra (no painel exige confirmação) e pede conferência
chamadas.length = 0;
const r3 = await processar({ gmail_id: 'g3', raw_base64: b64(comoEml(ler('tests/webjur/fixtures/email_ficticio_divergente.html'))) }, registrar);
check('divergente: não registra', 0, chamadas.length);
check('divergente: pede conferência', [false, 'contagem_divergente'], [r3.ok, r3.remessas[0]?.status]);

// 5. e-mail que não é da Webjur: não registra
const r4 = await processar({ gmail_id: 'g4', raw_base64: b64(new TextEncoder().encode('From: x@exemplo.invalid\r\nSubject: oi\r\n\r\nolá')) }, registrar);
check('e-mail estranho: não reconhecido, nada registrado', [false, 'nao_reconhecido', 0], [r4.ok, r4.remessas[0]?.status, chamadas.length]);

// 6. encaminhamento com vários e-mails anexados: uma remessa por e-mail da Webjur
const enc = ler('tests/webjur/fixtures/encaminhamento_com_anexo.eml');
const n = W.lerEmails(enc, 'x.eml').filter((r: any) => r.reconhecido && r.completo).length;
const r5 = await processar({ gmail_id: 'g5', raw_base64: b64(enc) }, registrar);
check('encaminhamento: uma remessa por e-mail da Webjur', n, chamadas.length);
check('encaminhamento: ok', true, r5.ok && n > 0);

console.log(`\n${ok}/${ok + falhas} OK`);
if (falhas) Deno.exit(1);
