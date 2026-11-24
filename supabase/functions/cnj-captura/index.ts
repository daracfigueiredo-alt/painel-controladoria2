// Edge Function cnj-captura — intimações do CNJ (API pública de comunicações do DJEN) para o double check (0044).
// O escritório não contratou o módulo de intimações do Atlas (12/11/2026); a captura é feita direto no CNJ.
// Ações (POST JSON {acao}):
//   carteira  -> atualiza a lista de processos varridos: processos do Atlas (list_lawsuits) + processos já conhecidos
//   oab       -> consulta as comunicações das OABs do escritório (parâmetro cnj_oabs), dos últimos 3 dias
//   lote      -> varredura por processo: consulta os próximos processos da fila do dia (janela cnj_janela_dias)
//   diagnostico -> nomes dos campos devolvidos pelo Atlas (list_tasks, list_lawsuits), sem conteúdo
// Autorização: agendamento (header x-cron-secret = CRON_SECRET, chave de serviço) ou controladoria logada no painel.
// A API do CNJ oscila ("sistema muito ocupado"): cada consulta é repetida com espera; o que falhar volta para a fila.

const SB_URL = Deno.env.get('SUPABASE_URL') ?? '';
const SB_KEY = Deno.env.get('SUPABASE_ANON_KEY') ?? '';
const SB_SERVICO = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
const CNJ_URL = Deno.env.get('CNJ_API_URL') ?? 'https://comunicaapi.pje.jus.br/api/v1/comunicacao';
const ATLAS_URL = Deno.env.get('ATLAS_API_URL') ?? 'https://tdhgpaurcjinhbandmvb.supabase.co/functions/v1/client-webhook';
const TEMPO_MAX_MS = 50_000;       // margem dentro dos limites da Edge Function (tempo e CPU): teste real de 12/11 parou em 24 consultas
const PAUSA_MS = Number(Deno.env.get('CNJ_PAUSA_MS') ?? '800');

const CORS = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
               'Access-Control-Allow-Methods': 'POST, OPTIONS' };
const resp = (status: number, corpo: unknown) =>
  new Response(JSON.stringify(corpo), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });
const dormir = (ms: number) => new Promise(r => setTimeout(r, ms));

export type Ambiente = {
  fetch: typeof fetch; rpc: (nome: string, args: Record<string, unknown>) => Promise<any>;
  agora: () => number; pausa: number; dormir: (ms: number) => Promise<unknown>;
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

export const soDigitos = (s: string) => String(s ?? '').replace(/\D/g, '');
export function cnjsDoTexto(t: string): string[] {
  const s = new Set<string>();
  for (const m of String(t ?? '').matchAll(/\b(\d{7})-?(\d{2})\.?(\d{4})\.?(\d)\.?(\d{2})\.?(\d{4})\b/g)) s.add(m.slice(1).join(''));
  return [...s];
}
const iso = (d: Date) => d.toISOString().slice(0, 10);
export function hojeBrasilia(agora: number) { return new Date(agora - 3 * 3600_000); }   // Brasília sem horário de verão

// consulta a API do CNJ com novas tentativas; devolve todos os itens (todas as páginas)
export async function consultarCnj(amb: Ambiente, filtros: Record<string, string>): Promise<any[]> {
  const itens: any[] = [];
  for (let pagina = 1; pagina <= 50; pagina++) {
    const q = new URLSearchParams({ ...filtros, itensPorPagina: '100', pagina: String(pagina) });
    let j: any = null, ultimo = '';
    for (let tentativa = 1; tentativa <= 4; tentativa++) {
      const r = await amb.fetch(`${CNJ_URL}?${q}`, { headers: { Accept: 'application/json' } });
      const txt = await r.text();
      try { j = JSON.parse(txt); } catch { j = null; }
      if (r.ok && j && j.status === 'success') break;
      ultimo = `HTTP ${r.status}: ${(j && (j.message || j.error)) || txt.slice(0, 120)}`;
      j = null;
      if (r.status === 400 || r.status === 404) break;          // filtro inválido: não adianta repetir
      await amb.dormir(Math.min(15_000, 2_000 * tentativa * tentativa));
    }
    if (!j) throw new Error(ultimo || 'CNJ sem resposta');
    const lote = Array.isArray(j.items) ? j.items : [];
    itens.push(...lote);
    if (lote.length < 100 || itens.length >= Number(j.count ?? 0)) break;
    await amb.dormir(amb.pausa);
  }
  return itens;
}

async function atlas(amb: Ambiente, action: string, data: Record<string, unknown>) {
  const chave = Deno.env.get('ATLAS_API_KEY');
  if (!chave) throw new Error('Chave do Atlas não configurada (ATLAS_API_KEY).');
  const r = await amb.fetch(ATLAS_URL, { method: 'POST', headers: { 'Content-Type': 'application/json', 'x-api-key': chave, 'X-Api-Version': 'v1' },
                                          body: JSON.stringify({ action, data }) });
  const j = await r.json().catch(() => null);
  if (!r.ok || !j || j.success === false) throw new Error((j && (j.error || j.code)) || `Atlas respondeu ${r.status}`);
  return j;
}

// processos do Atlas: cada item pode trazer o CNJ em campos diferentes; o número é procurado no item inteiro
export function processosDoAtlas(itens: any[]) {
  const out: { cnj: string; lawsuit_id: string | null; cliente: string | null }[] = [];
  for (const p of itens) {
    const preferido = cnjsDoTexto([p?.process_number, p?.number, p?.cnj, p?.lawsuit_number].filter(Boolean).join(' '));
    const cnjs = preferido.length ? preferido : cnjsDoTexto(JSON.stringify(p ?? {}));
    for (const c of cnjs) out.push({ cnj: c, lawsuit_id: p?.id ? String(p.id) : null,
                                     cliente: p?.client_name ?? p?.client?.name ?? null });
  }
  return out;
}

export async function carteira(amb: Ambiente) {
  const r: any = { atlas: 0, paginas: 0, erro_atlas: null };
  const itens: any[] = [];
  try {
    let cursor: string | null = null;
    do {
      const j = await atlas(amb, 'list_lawsuits', { limit: 100, ...(cursor ? { cursor } : {}) });
      const lote = j.lawsuits ?? j.items ?? j.data ?? [];
      itens.push(...lote); r.paginas++;
      cursor = j.hasMore ? j.nextCursor : null;
      if (r.paginas > 500) break;
    } while (cursor);
  } catch (e) { r.erro_atlas = (e as Error).message; }
  const procs = processosDoAtlas(itens);
  r.atlas = procs.length;
  const reg = await amb.rpc('cnj_carteira_registrar', { p_itens: procs.length ? procs : null, p_origem: procs.length ? 'atlas' : 'base' });
  Object.assign(r, reg);
  await amb.rpc('cnj_execucao_registrar', { p_tipo: 'carteira', p_detalhe: { ...r, sucesso: r.erro_atlas ? 0 : 1, falhas: r.erro_atlas ? 1 : 0 } });
  return r;
}

export async function porOab(amb: Ambiente, tipo = 'oab') {
  const oabs: string[] = (await amb.rpc('cnj_parametro', { p_chave: 'cnj_oabs' })) ?? [];
  const hoje = hojeBrasilia(amb.agora());
  const ini = new Date(hoje.getTime() - 3 * 86400_000);
  const r = { consultas: 0, sucesso: 0, falhas: 0, comunicacoes: 0, novas: 0, erros: [] as string[] };
  for (const oab of oabs) {
    const [numero, uf] = String(oab).split('/');
    r.consultas++;
    try {
      const itens = await consultarCnj(amb, { numeroOab: soDigitos(numero), ufOab: (uf ?? '').toUpperCase(),
                                              dataDisponibilizacaoInicio: iso(ini), dataDisponibilizacaoFim: iso(hoje) });
      const g = await amb.rpc('cnj_registrar', { p_itens: itens, p_encontrada_por: 'oab:' + oab });
      r.sucesso++; r.comunicacoes += g.recebidas; r.novas += g.novas;
    } catch (e) { r.falhas++; r.erros.push(`${oab}: ${(e as Error).message}`); }
    await amb.dormir(amb.pausa);
  }
  await amb.rpc('cnj_execucao_registrar', { p_tipo: tipo, p_detalhe: r });
  return r;
}

export async function lote(amb: Ambiente, janela: number, limite: number | null = null, tipo = 'lote') {
  const inicio = amb.agora();
  const fila: string[] = (await amb.rpc('cnj_proximos', { p_limite: limite })) ?? [];
  const hoje = hojeBrasilia(inicio);
  const ini = new Date(hoje.getTime() - janela * 86400_000);
  const r = { consultas: 0, sucesso: 0, falhas: 0, comunicacoes: 0, novas: 0, fila: fila.length, interrompido: false, erros: [] as string[] };
  for (const cnj of fila) {
    if (amb.agora() - inicio > TEMPO_MAX_MS) { r.interrompido = true; break; }
    r.consultas++;
    try {
      const itens = await consultarCnj(amb, { numeroProcesso: soDigitos(cnj), dataDisponibilizacaoInicio: iso(ini), dataDisponibilizacaoFim: iso(hoje) });
      const g = itens.length ? await amb.rpc('cnj_registrar', { p_itens: itens, p_encontrada_por: 'processo' }) : { recebidas: 0, novas: 0 };
      await amb.rpc('cnj_marcar', { p_cnj: cnj, p_ok: true, p_qtd: itens.length, p_erro: null });
      r.sucesso++; r.comunicacoes += g.recebidas; r.novas += g.novas;
    } catch (e) {
      r.falhas++; if (r.erros.length < 5) r.erros.push(`${cnj}: ${(e as Error).message}`);
      await amb.rpc('cnj_marcar', { p_cnj: cnj, p_ok: false, p_qtd: null, p_erro: (e as Error).message });
    }
    await amb.dormir(amb.pausa);
  }
  if (r.consultas || r.fila) await amb.rpc('cnj_execucao_registrar', { p_tipo: tipo, p_detalhe: r });
  return r;
}

async function diagnostico(amb: Ambiente) {
  const campos = async (action: string, chave: string) => {
    try { const j = await atlas(amb, action, { limit: 1 }); const it = (j[chave] ?? [])[0];
          return { ok: true, campos: it ? Object.keys(it).sort() : [], vazio: !it }; }
    catch (e) { return { ok: false, erro: (e as Error).message }; }
  };
  return { list_tasks: await campos('list_tasks', 'tasks'), list_lawsuits: await campos('list_lawsuits', 'lawsuits') };
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
  const amb: Ambiente = { fetch, rpc: rpcCom(token), agora: () => Date.now(), pausa: PAUSA_MS, dormir };
  try {
    await amb.rpc('cnj_conferir_acesso', {});
    const manual = !cron;
    if (corpo.acao === 'carteira') return resp(200, { ok: true, ...(await carteira(amb)) });
    if (corpo.acao === 'oab') return resp(200, { ok: true, ...(await porOab(amb, 'oab')) });   // manual ou agendada: vale como a consulta do dia
    if (corpo.acao === 'lote') {
      const janela = Number((await amb.rpc('cnj_parametro', { p_chave: 'cnj_janela_dias' })) ?? 7) || 7;
      return resp(200, { ok: true, ...(await lote(amb, janela, manual ? Math.min(Number(corpo.limite) || 20, 40) : null, manual ? 'manual' : 'lote')) });
    }
    if (corpo.acao === 'diagnostico') return resp(200, { ok: true, ...(await diagnostico(amb)) });
    return resp(400, { erro: 'Ação desconhecida' });
  } catch (e) {
    return resp(500, { erro: (e as Error).message });
  }
});
