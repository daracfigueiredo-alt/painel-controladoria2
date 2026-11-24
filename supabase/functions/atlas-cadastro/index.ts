// Edge Function atlas-cadastro — robô de cadastro de processos no Atlas (0048, 14/11/2026).
// Os processos vêm da exportação de processos do ADVBOX (importada no painel) e só são enviados depois que a
// controladoria aprova a prévia. Cliente não encontrado no Atlas fica só na lista: o robô não cria cliente.
// Ações (POST JSON {acao}):
//   clientes  -> lê todos os clientes do Atlas (list_clients) e casa os processos da prévia com eles
//   cadastrar -> cadastra os próximos aprovados: confere no Atlas se o número já existe (list_lawsuits) e,
//                se não existir, cria (create_lawsuit, com Idempotency-Key)
// Autorização: agendamento (x-cron-secret = CRON_SECRET, chave de serviço) ou controladoria logada no painel.
// A chave do Atlas fica só no segredo ATLAS_API_KEY.

const SB_URL = Deno.env.get('SUPABASE_URL') ?? '';
const SB_KEY = Deno.env.get('SUPABASE_ANON_KEY') ?? '';
const SB_SERVICO = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
const ATLAS_URL = Deno.env.get('ATLAS_API_URL') ?? 'https://tdhgpaurcjinhbandmvb.supabase.co/functions/v1/client-webhook';
const TEMPO_MAX_MS = 45_000;
const PAUSA_MS = Number(Deno.env.get('ATLAS_PAUSA_MS') ?? '1100');   // ~50 chamadas por minuto, abaixo do limite de 60 do Atlas

const CORS = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
               'Access-Control-Allow-Methods': 'POST, OPTIONS' };
const resp = (status: number, corpo: unknown) =>
  new Response(JSON.stringify(corpo), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });
const dormir = (ms: number) => new Promise(r => setTimeout(r, ms));

export type Ambiente = {
  fetch: typeof fetch; rpc: (nome: string, args: Record<string, unknown>) => Promise<any>;
  agora: () => number; pausa: number; dormir: (ms: number) => Promise<unknown>; chave: string;
};

export function rpcCom(token: string, f: typeof fetch = fetch) {
  return async (nome: string, args: Record<string, unknown>) => {
    const servico = SB_SERVICO !== '' && token === `Bearer ${SB_SERVICO}`;
    const r = await f(`${SB_URL}/rest/v1/rpc/${nome}`, {
      method: 'POST', headers: { apikey: servico ? SB_SERVICO : SB_KEY, Authorization: token, 'Content-Type': 'application/json' },
      body: JSON.stringify(args),
    });
    const txt = await r.text();
    if (!r.ok) { let m = txt; try { m = JSON.parse(txt).message ?? txt; } catch { /* texto */ } throw new Error(m); }
    return txt ? JSON.parse(txt) : null;
  };
}

export class ErroAtlas extends Error {
  constructor(msg: string, public status: number, public code: string | null) { super(msg); }
}

export async function atlas(amb: Ambiente, action: string, data: Record<string, unknown>, idempotencia: string | null = null) {
  if (!amb.chave) throw new ErroAtlas('Chave do Atlas não configurada (ATLAS_API_KEY).', 0, 'sem_chave');
  const headers: Record<string, string> = { 'Content-Type': 'application/json', 'x-api-key': amb.chave, 'X-Api-Version': 'v1' };
  if (idempotencia) headers['Idempotency-Key'] = idempotencia;
  for (let tentativa = 1; ; tentativa++) {
    let r: Response;
    try { r = await amb.fetch(ATLAS_URL, { method: 'POST', headers, body: JSON.stringify({ action, data }) }); }
    catch (e) { throw new ErroAtlas('Falha de rede: ' + (e as Error).message, 0, 'rede'); }
    const j = await r.json().catch(() => null);
    if (r.status === 429 && tentativa < 3) {   // limite por minuto: espera o que o Atlas pedir e tenta de novo
      const espera = Math.min(30, Number(r.headers.get('Retry-After') ?? '10') || 10);
      await amb.dormir(espera * 1000); continue;
    }
    if (!r.ok || !j || j.success === false) {
      const campos = j?.fields ? ` (${[].concat(j.fields).join(', ')})` : '';
      throw new ErroAtlas(((j && (j.error || j.code)) || `Atlas respondeu ${r.status}`) + campos, r.status, j?.code ?? null);
    }
    return j;
  }
}

// ------------------------------------------------------------ clientes do Atlas
export async function clientes(amb: Ambiente) {
  const itens: any[] = []; let cursor: string | null = null, paginas = 0;
  do {
    const j = await atlas(amb, 'list_clients', { limit: 100, ...(cursor ? { cursor } : {}) });
    const lote = j.clients ?? [];
    for (const c of lote) itens.push({ id: c.id, name: c.name, doc_id: c.doc_id ?? c.docId ?? null, status: c.status ?? null });
    paginas++;
    cursor = j.hasMore ? j.nextCursor : null;
    if (paginas > 200) break;
    if (cursor) await amb.dormir(amb.pausa);
  } while (cursor);
  // a mesma ficha pode voltar em outra página (o Atlas avisa: at-least-once); fica a última
  const unicos = [...new Map(itens.filter(c => c.id).map(c => [c.id, c])).values()];
  const reg = await amb.rpc('atlas_clientes_registrar', { p_itens: unicos, p_completo: true });
  return { paginas, lidos: unicos.length, com_documento: unicos.filter(c => c.doc_id).length, ...reg };
}

// erros que não adianta repetir: dado recusado pelo Atlas (validação, cliente inexistente, permissão)
const DEFINITIVO = new Set(['validation_error', 'not_found', 'permission_denied', 'read_only_key', 'invalid_api_key', 'api_not_in_plan']);
const PARA_TUDO = new Set(['permission_denied', 'read_only_key', 'invalid_api_key', 'api_not_in_plan', 'tenant_inactive', 'sem_chave']);

export function corpoDoCadastro(p: any) {
  const d: Record<string, unknown> = { clientId: p.clientId, processNumber: String(p.cnj).replace(/\D/g, ''), type: p.type || 'Outros',
                                       causeValue: Number(p.causeValue) || 0 };
  if (p.protocolDate) d.protocolDate = String(p.protocolDate).slice(0, 10);
  if (p.authors) d.authors = String(p.authors).slice(0, 1000);
  if (p.defendants) d.defendants = String(p.defendants).slice(0, 1000);
  if (p.notes) d.notes = String(p.notes).slice(0, 2000);
  return d;
}

export async function cadastrar(amb: Ambiente, limite: number | null = null) {
  const inicio = amb.agora();
  const fila: any[] = (await amb.rpc('atlas_cadastro_proximos', { p_limite: limite })) ?? [];
  const r = { fila: fila.length, cadastrados: 0, ja_existiam: 0, erros: 0, adiados: 0, interrompido: false, mensagens: [] as string[] };
  let parar = '';
  for (const p of fila) {
    if (parar || amb.agora() - inicio > TEMPO_MAX_MS) {   // o resto volta para a fila
      r.interrompido = true; r.adiados++;
      // não chegou a chamar o Atlas: volta para a fila sem contar como tentativa
      await amb.rpc('atlas_cadastro_resultado', { p_cnj: p.cnj, p_resultado: 'adiado', p_lawsuit_id: null,
                                                  p_erro: parar || null, p_detalhe: {} });
      continue;
    }
    try {
      // 1) já existe no Atlas? (outra pessoa pode ter cadastrado depois da prévia)
      const ex = await atlas(amb, 'list_lawsuits', { processNumber: String(p.cnj).replace(/\D/g, ''), limit: 5 });
      await amb.dormir(amb.pausa);
      const achado = (ex.lawsuits ?? [])[0];
      if (achado) {
        r.ja_existiam++;
        await amb.rpc('atlas_cadastro_resultado', { p_cnj: p.cnj, p_resultado: 'ja_existia', p_lawsuit_id: String(achado.id),
                                                    p_erro: null, p_detalhe: { cliente_no_atlas: achado.client_name ?? null } });
        continue;
      }
      // 2) cadastra (a chave de idempotência muda a cada tentativa; a conferência acima evita duplicar)
      const j = await atlas(amb, 'create_lawsuit', corpoDoCadastro(p), `${p.idempotencyKey}-t${p.tentativa ?? 1}`);
      await amb.dormir(amb.pausa);
      r.cadastrados++;
      await amb.rpc('atlas_cadastro_resultado', { p_cnj: p.cnj, p_resultado: 'cadastrado', p_lawsuit_id: String(j.lawsuitId ?? j.lawsuit?.id ?? ''),
                                                  p_erro: null, p_detalhe: { app_url: j.appUrl ?? null, idempotente: !!j.idempotent } });
    } catch (e) {
      const err = e as ErroAtlas;
      const definitivo = DEFINITIVO.has(err.code ?? '');
      if (definitivo) r.erros++; else r.adiados++;
      if (r.mensagens.length < 5) r.mensagens.push(`${p.cnj}: ${err.message}`);
      await amb.rpc('atlas_cadastro_resultado', { p_cnj: p.cnj, p_resultado: definitivo ? 'erro' : 'tentar_de_novo', p_lawsuit_id: null,
                                                  p_erro: err.message, p_detalhe: { code: err.code, status: err.status } });
      if (PARA_TUDO.has(err.code ?? '')) parar = 'Atlas recusou a chave: ' + err.message;
    }
  }
  if (r.fila) await amb.rpc('atlas_cadastro_execucao', { p_detalhe: { ...r, parou: parar || null } });
  return { ...r, parou: parar || null };
}

function iguais(a: string, b: string) {
  if (a.length !== b.length || a.length === 0) return false;
  let d = 0; for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

if (import.meta.main) Deno.serve(async req => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return resp(405, { erro: 'Use POST' });
  let token = req.headers.get('Authorization') ?? '';
  let corpo: any = {}; try { corpo = await req.json(); } catch { return resp(400, { erro: 'JSON inválido' }); }
  const cron = (req.headers.get('x-cron-secret') ?? '').trim();
  if (cron) {
    const segredo = (Deno.env.get('CRON_SECRET') ?? '').trim();
    if (!segredo || !SB_SERVICO || !iguais(cron, segredo)) return resp(401, { erro: 'Agendamento não autorizado.' });
    token = `Bearer ${SB_SERVICO}`;
  } else if (!token.startsWith('Bearer ')) return resp(401, { erro: 'Faça login no painel.' });
  const amb: Ambiente = { fetch, rpc: rpcCom(token), agora: () => Date.now(), pausa: PAUSA_MS, dormir,
                          chave: (Deno.env.get('ATLAS_API_KEY') ?? '').trim() };
  try {
    await amb.rpc('cnj_conferir_acesso', {});   // só a controladoria (ou o agendamento)
    if (corpo.acao === 'clientes') return resp(200, { ok: true, ...(await clientes(amb)) });
    if (corpo.acao === 'diagnostico') {   // só os NOMES dos campos do 1º cliente, sem conteúdo
      const j = await atlas(amb, 'list_clients', { limit: 1 });
      const c = (j.clients ?? [])[0] ?? {};
      return resp(200, { ok: true, campos: Object.keys(c).sort(), tipos: Object.fromEntries(Object.entries(c).map(([k, v]) => [k, Array.isArray(v) ? 'lista' : v === null ? 'vazio' : typeof v])) });
    }
    if (corpo.acao === 'cadastrar') {
      const limite = cron ? null : Math.min(Math.max(Number(corpo.limite) || 5, 1), 20);
      return resp(200, { ok: true, ...(await cadastrar(amb, limite)) });
    }
    return resp(400, { erro: 'Ação desconhecida' });
  } catch (e) {
    return resp(500, { erro: (e as Error).message });
  }
});
