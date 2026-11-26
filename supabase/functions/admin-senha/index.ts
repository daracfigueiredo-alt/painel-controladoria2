// Edge Function admin-senha — a controladoria define a senha de uma conta (0062, 26/11/2026).
// POST JSON {user_id, senha, motivo}, com o login da controladoria (Authorization: Bearer <token do painel>).
// 1) admin_registrar_alteracao_senha, com o token de quem pediu: confere o perfil (só controladoria),
//    exige o motivo e registra no histórico. Sem isso, nada é trocado.
// 2) troca a senha pela API de administração do Supabase Auth, com a chave de serviço, que fica só aqui.
// A senha não é gravada no banco nem nos registros da função.

const SB_URL = Deno.env.get('SUPABASE_URL') ?? '';
const SB_KEY = Deno.env.get('SUPABASE_ANON_KEY') ?? '';
const SB_SERVICO = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
export const SENHA_MINIMA = 8;

const CORS = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
               'Access-Control-Allow-Methods': 'POST, OPTIONS' };
const resp = (status: number, corpo: unknown) =>
  new Response(JSON.stringify(corpo), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export type Config = { url: string; anon: string; servico: string; fetch: typeof fetch };

export function validar(corpo: any): string | null {
  if (!corpo || typeof corpo !== 'object') return 'Pedido inválido.';
  if (typeof corpo.user_id !== 'string' || !UUID.test(corpo.user_id)) return 'Conta inválida.';
  if (typeof corpo.senha !== 'string' || corpo.senha.length < SENHA_MINIMA) return `A senha precisa ter pelo menos ${SENHA_MINIMA} caracteres.`;
  if (corpo.senha.length > 72) return 'A senha pode ter no máximo 72 caracteres.';
  if (corpo.senha.trim() !== corpo.senha) return 'A senha não pode começar nem terminar com espaço.';
  if (typeof corpo.motivo !== 'string' || corpo.motivo.trim().length < 10) return 'Informe o motivo da alteração (mínimo 10 caracteres).';
  return null;
}

export async function tratar(req: Request, cfg: Config): Promise<Response> {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return resp(405, { erro: 'Use POST.' });
  if (!cfg.servico) return resp(500, { erro: 'Chave de serviço indisponível na função.' });
  const token = req.headers.get('Authorization') ?? '';
  if (!token.startsWith('Bearer ') || token === `Bearer ${cfg.servico}` || token === `Bearer ${cfg.anon}`) {
    return resp(401, { erro: 'Entre no painel com o login da controladoria.' });
  }
  const corpo = await req.json().catch(() => null);
  const invalido = validar(corpo);
  if (invalido) return resp(400, { erro: invalido });

  // 1) quem pediu é a controladoria? (o banco confere pelo token e registra no histórico)
  const r1 = await cfg.fetch(`${cfg.url}/rest/v1/rpc/admin_registrar_alteracao_senha`, {
    method: 'POST', headers: { apikey: cfg.anon, Authorization: token, 'Content-Type': 'application/json' },
    body: JSON.stringify({ p_user_id: corpo.user_id, p_motivo: corpo.motivo }),
  });
  const t1 = await r1.text();
  if (!r1.ok) {
    let m = t1; try { m = JSON.parse(t1).message ?? t1; } catch { /* texto */ }
    return resp(r1.status === 401 || /Somente a controladoria/.test(m) ? 403 : 400, { erro: m });
  }
  const conta = JSON.parse(t1);

  // 2) troca a senha
  const r2 = await cfg.fetch(`${cfg.url}/auth/v1/admin/users/${corpo.user_id}`, {
    method: 'PUT', headers: { apikey: cfg.servico, Authorization: `Bearer ${cfg.servico}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ password: corpo.senha }),
  });
  if (!r2.ok) {
    const j = await r2.json().catch(() => null);
    return resp(400, { erro: 'O Supabase recusou a senha: ' + (j?.msg ?? j?.message ?? j?.error_description ?? `erro ${r2.status}`) });
  }
  return resp(200, { ok: true, email: conta.email });
}

if (import.meta.main) {
  Deno.serve(req => tratar(req, { url: SB_URL, anon: SB_KEY, servico: SB_SERVICO, fetch }));
}
