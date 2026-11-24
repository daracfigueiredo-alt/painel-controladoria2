// Edge Function webjur-email — recebe os e-mails diários da Webjur, enviados pelo script da conta
// controladoria.oecadv@gmail.com (Google Apps Script, docs/ETAPA13_WEBJUR_EMAIL.md), e registra as publicações.
// * Autorização: segredo próprio WEBJUR_EMAIL_SECRET (header x-webjur-secret). O mesmo valor fica nas
//   propriedades do script. Sem ele, nada acontece.
// * A leitura do e-mail é a MESMA do painel (webjur_email.js, cópia de painel/js/webjur_email.js; o teste
//   confere que as duas são idênticas). O hash da remessa é o mesmo do painel, então um e-mail importado
//   à mão no painel e depois enviado pelo script é reconhecido como já importado.
// * Remessa com contagem divergente da declarada pela Webjur NÃO é registrada automaticamente
//   (no painel ela exige confirmação): fica no log de integração para a controladoria conferir.
import './webjur_email.js';

const SB_URL = Deno.env.get('SUPABASE_URL')!;
const SB_SERVICO = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
const W = (globalThis as any).OCWebjur;

const resp = (status: number, corpo: unknown) =>
  new Response(JSON.stringify(corpo), { status, headers: { 'Content-Type': 'application/json' } });

async function rpc(nome: string, args: Record<string, unknown>) {
  const r = await fetch(`${SB_URL}/rest/v1/rpc/${nome}`, {
    method: 'POST',
    headers: { apikey: SB_SERVICO, Authorization: `Bearer ${SB_SERVICO}`, 'Content-Type': 'application/json' },
    body: JSON.stringify(args),
  });
  const txt = await r.text();
  if (!r.ok) { let m = txt; try { m = JSON.parse(txt).message ?? txt; } catch { /* texto */ } throw new Error(m); }
  return txt ? JSON.parse(txt) : null;
}
const log = (nivel: string, mensagem: string, detalhe: unknown) =>
  rpc('registrar_log_integracao', { p_origem: 'webjur_gmail', p_nivel: nivel, p_operacao: 'webjur_email', p_mensagem: mensagem, p_detalhe: detalhe })
    .catch(() => null);

async function sha256(bytes: Uint8Array) {
  const b = await crypto.subtle.digest('SHA-256', bytes);
  return [...new Uint8Array(b)].map(x => x.toString(16).padStart(2, '0')).join('');
}
function base64(s: string) {
  const bin = atob(s.replace(/[^A-Za-z0-9+/=]/g, ''));
  return Uint8Array.from(bin, c => c.charCodeAt(0));
}
function iguais(a: string, b: string) {
  if (a.length !== b.length || a.length === 0) return false;
  let d = 0; for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

// um e-mail do Gmail pode trazer mais de um e-mail da Webjur (encaminhamento com anexos): cada um é uma remessa
export async function processar(m: { gmail_id?: string; assunto?: string; raw_base64: string }, registrar = rpc) {
  const nome = `Gmail ${m.gmail_id ?? '?'} — ${m.assunto ?? ''}`.trim();
  let lidos: any[];
  try { lidos = W.lerEmails(base64(m.raw_base64), nome + '.eml'); }
  catch (e) { return { gmail_id: m.gmail_id, ok: false, erro: 'Não foi possível ler o e-mail: ' + (e as Error).message, remessas: [] }; }
  const remessas: any[] = [];
  for (const r of lidos) {
    const rotulo = lidos.length > 1 ? `${nome} — e-mail ${r.indice} de ${r.de}` : nome;
    if (!r.reconhecido) { remessas.push({ nome: rotulo, status: 'nao_reconhecido', avisos: r.avisos }); continue; }
    if (!r.completo) {
      remessas.push({ nome: rotulo, status: 'contagem_divergente', declarado: r.total_declarado, lido: r.total_lido, avisos: r.avisos });
      continue;
    }
    const hash = await sha256(new TextEncoder().encode(r.texto_bloco || ''));
    const d = await registrar('pub_registrar_remessa', {
      p_arquivo_nome: rotulo, p_arquivo_sha256: hash, p_origem: 'webjur_gmail',
      p_remessa: { formato: r.formato, recebido_em: r.recebido_em, chave_cliente: r.chave_cliente, cliente: r.cliente,
                   secoes: r.secoes.map((x: any) => ({ ordem: x.ordem, caderno: x.caderno, data: x.data, declarado: x.declarado })), avisos: r.avisos },
      p_publicacoes: r.publicacoes.map((p: any) => W.paraRegistro(p, r)),
    });
    remessas.push({ nome: rotulo, status: d.status, remessa_id: d.remessa_id, situacao: d.situacao ?? null,
                    novas: d.novas ?? 0, ja_registradas: d.ja_registradas ?? 0, rejeitadas: d.rejeitadas ?? 0 });
  }
  const ok = remessas.length > 0 && remessas.every(x => x.status === 'importada' || x.status === 'ja_importada');
  return { gmail_id: m.gmail_id, ok, remessas };
}

if (import.meta.main) Deno.serve(async req => {
  if (req.method !== 'POST') return resp(405, { erro: 'Use POST' });
  const segredo = (Deno.env.get('WEBJUR_EMAIL_SECRET') ?? '').trim();
  const recebido = (req.headers.get('x-webjur-secret') ?? '').trim();
  if (!segredo) return resp(401, { erro: 'Não autorizado.', motivo: 'segredo WEBJUR_EMAIL_SECRET não configurado na função' });
  if (!SB_SERVICO) return resp(401, { erro: 'Não autorizado.', motivo: 'chave de serviço indisponível na função' });
  if (!iguais(recebido, segredo)) {
    // diagnóstico sem expor o segredo: tamanho e 6 primeiros caracteres do SHA-256 de cada lado
    const resumo = async (t: string) => (await sha256(new TextEncoder().encode(t))).slice(0, 6);
    return resp(401, { erro: 'Não autorizado.', motivo: 'segredo diferente do guardado na função',
      diagnostico: { recebido: { tamanho: recebido.length, resumo: await resumo(recebido) },
                     guardado: { tamanho: segredo.length, resumo: await resumo(segredo) } } });
  }
  let corpo: any; try { corpo = await req.json(); } catch { return resp(400, { erro: 'JSON inválido' }); }
  const msgs = Array.isArray(corpo?.mensagens) ? corpo.mensagens : [];
  if (corpo?.acao === 'testar') return resp(200, { ok: true, mensagem: 'Conexão com o sistema da controladoria funcionando.' });
  if (!msgs.length || msgs.length > 20) return resp(400, { erro: 'Envie de 1 a 20 mensagens por chamada.' });
  const resultados: any[] = [];
  for (const m of msgs) {
    try { resultados.push(await processar(m)); }
    catch (e) { resultados.push({ gmail_id: m?.gmail_id, ok: false, erro: (e as Error).message, remessas: [] }); }
  }
  const pend = resultados.filter(r => !r.ok);
  await log(pend.length ? 'aviso' : 'info',
    pend.length ? `E-mails da Webjur: ${pend.length} de ${resultados.length} precisam de conferência manual (contagem divergente, não reconhecido ou erro).`
                : `E-mails da Webjur: ${resultados.length} recebido(s) e registrado(s).`,
    { resultados });
  return resp(200, { ok: pend.length === 0, resultados });
});
