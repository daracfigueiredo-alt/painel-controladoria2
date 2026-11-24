/* SOMENTE PARA TESTE LOCAL — emula o mínimo da API do Supabase para testar o painel
 * ponta a ponta contra o PostgreSQL local, com RLS e funções reais:
 *   /auth/v1/token   login por senha (usuários de teste fixos) -> JWT HS256
 *   /auth/v1/logout  encerra
 *   /rest/v1/<visão|tabela>  GET com select, filtros eq, order, limit (subconjunto do PostgREST)
 *   /rest/v1/rpc/<função>    POST com argumentos nomeados
 *   /painel/*        arquivos estáticos do painel (config.js gerado para este ambiente)
 * Cada requisição roda numa transação com SET LOCAL ROLE (anon/authenticated) e
 * request.jwt.claims, como o PostgREST faz. NÃO é o PostgREST: o teste no Supabase
 * real continua necessário (Etapa 10). */
'use strict';
const http = require('http');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { Pool, types } = require('pg');
// Como o PostgREST: bigint e numeric saem como número JSON (o driver pg os entrega como texto por padrão).
types.setTypeParser(20, v => Number(v)); types.setTypeParser(1700, v => Number(v));

const PORTA = Number(process.env.PORTA || 8787);
const SEGREDO = 'segredo-somente-teste-local-0123456789abcdef';
const PAINEL = path.resolve(__dirname, '..', '..', 'painel');
const pool = new Pool({ host: '/tmp', port: 5433, user: 'postgres', database: process.env.DB || 'ctrl_e2e', max: 4 });
const USUARIOS = {
  'admin.teste@exemplo.invalid': { id: '00000000-0000-0000-0000-00000000000a', senha: 'senha-admin-teste' },
  'colab.teste@exemplo.invalid': { id: '00000000-0000-0000-0000-00000000000c', senha: 'senha-colab-teste' },
  'lider.teste@exemplo.invalid': { id: '00000000-0000-0000-0000-0000000000d1', senha: 'senha-lider-teste' },
  'diretoria.teste@exemplo.invalid': { id: '00000000-0000-0000-0000-0000000000d9', senha: 'senha-diretoria-teste' }
};
const ARQUIVOS = path.join(require('os').tmpdir(), 'ctrl_storage_teste');

const b64 = o => Buffer.from(typeof o === 'string' ? o : JSON.stringify(o)).toString('base64url');
function assinar(payload) {
  const cab = b64({ alg: 'HS256', typ: 'JWT' }), corpo = b64(payload);
  return `${cab}.${corpo}.${crypto.createHmac('sha256', SEGREDO).update(`${cab}.${corpo}`).digest('base64url')}`;
}
function verificar(token) {
  const [c, p, s] = String(token || '').split('.');
  if (!s) return null;
  const esperado = crypto.createHmac('sha256', SEGREDO).update(`${c}.${p}`).digest('base64url');
  if (!crypto.timingSafeEqual(Buffer.from(s), Buffer.from(esperado))) return null;
  const claims = JSON.parse(Buffer.from(p, 'base64url'));
  if (claims.exp && claims.exp < Date.now() / 1000) return null;
  return claims;
}
const ANON = assinar({ role: 'anon', iss: 'teste-local' });

function sessao(email, u) {
  const agora = Math.floor(Date.now() / 1000);
  const user = { id: u.id, aud: 'authenticated', role: 'authenticated', email, app_metadata: {}, user_metadata: {}, created_at: new Date().toISOString() };
  return { access_token: assinar({ sub: u.id, role: 'authenticated', email, aud: 'authenticated', exp: agora + 3600 }),
           token_type: 'bearer', expires_in: 3600, expires_at: agora + 3600, refresh_token: 'rt-' + u.id, user };
}

const ID = /^[a-z_][a-z0-9_]*$/;
const json = (res, st, corpo, extra = {}) => { res.writeHead(st, { 'Content-Type': 'application/json', ...extra }); res.end(corpo === undefined ? '' : JSON.stringify(corpo)); };
const lerCorpo = req => new Promise((ok, falha) => { const ch = []; req.on('data', d => ch.push(d)); req.on('end', () => ok(Buffer.concat(ch).toString('utf8'))); req.on('error', falha); });

async function comPapel(claims, fn) {
  const c = await pool.connect();
  try {
    await c.query('begin');
    // chave de serviço (rotina agendada): como no Supabase, ignora a RLS
    if (claims.role !== 'service_role') await c.query(`set local role ${claims.role === 'authenticated' ? 'authenticated' : 'anon'}`);
    await c.query("select set_config('request.jwt.claims', $1, true)", [JSON.stringify(claims)]);
    const r = await fn(c);
    await c.query('commit');
    return r;
  } catch (e) { await c.query('rollback').catch(() => {}); throw e; } finally { c.release(); }
}
function erroPg(res, e) {
  const st = e.code === '42501' ? 403 : e.code === 'P0001' || e.code === '23514' || e.code === '22P02' ? 400 : 400;
  json(res, st, { code: e.code, message: e.message, details: e.detail || null, hint: e.hint || null });
}

async function rest(req, res, url, claims) {
  const partes = url.pathname.replace(/^\/rest\/v1\//, '').split('/');
  if (partes[0] === 'rpc') {
    const fn = partes[1];
    if (!ID.test(fn) || req.method !== 'POST') return json(res, 404, { message: 'rota inválida' });
    const args = JSON.parse((await lerCorpo(req)) || '{}');
    const nomes = Object.keys(args);
    if (!nomes.every(n => ID.test(n))) return json(res, 400, { message: 'argumento inválido' });
    const argsSql = nomes.map((n, i) => `${n} => $${i + 1}`).join(', ');
    try {
      // Como o PostgREST: lista JSON em parâmetro do tipo array (text[], bigint[]) vira array do Postgres; o resto vai como JSON
      const tipos = Object.fromEntries((await pool.query(
        "select a.nome, a.tipo from pg_proc p join pg_namespace n on n.oid = p.pronamespace, unnest(p.proargnames, p.proargtypes::regtype[]::text[]) a(nome, tipo) where n.nspname = 'public' and p.proname = $1", [fn])).rows.map(r => [r.nome, r.tipo]));
      const vals = nomes.map(n => (args[n] !== null && typeof args[n] === 'object')
        ? (Array.isArray(args[n]) && /\[\]$/.test(tipos[n] || '') ? args[n] : JSON.stringify(args[n])) : args[n]);
      // Como o PostgREST: função que devolve conjunto (SETOF/TABLE) -> lista de objetos; senão, o valor.
      const conj = (await pool.query("select bool_or(proretset) c from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = $1", [fn])).rows[0].c;
      const sql = conj ? `select * from public.${fn}(${argsSql})` : `select public.${fn}(${argsSql}) as r`;
      const r = await comPapel(claims, c => c.query(sql, vals));
      return json(res, 200, conj ? r.rows : r.rows[0].r);
    } catch (e) { return erroPg(res, e); }
  }
  const tabela = partes[0];
  if (!ID.test(tabela) || req.method !== 'GET') return json(res, 404, { message: 'rota inválida' });
  const p = url.searchParams;
  const cols = (p.get('select') || '*').split(',').map(s => s.trim());
  if (!(cols.length === 1 && cols[0] === '*') && !cols.every(c => ID.test(c))) return json(res, 400, { message: 'select inválido' });
  const where = [], vals = [];
  let ordem = '', limite = '';
  for (const [k, v] of p) {
    if (k === 'select') continue;
    if (k === 'order') {
      const [c, dir] = v.split('.');
      if (!ID.test(c)) return json(res, 400, { message: 'order inválido' });
      ordem = ` order by ${c} ${dir === 'desc' ? 'desc' : 'asc'}`;
    } else if (k === 'limit') limite = ` limit ${parseInt(v, 10) || 1000}`;
    else if (ID.test(k) && v.startsWith('eq.')) { vals.push(v.slice(3)); where.push(`${k}::text = $${vals.length}`); }
    else if (ID.test(k) && /^(gte|lte)\./.test(v)) { vals.push(v.slice(4)); where.push(`${k} ${v.startsWith('gte') ? '>=' : '<='} $${vals.length}`); }
    else return json(res, 400, { message: `filtro não suportado no servidor de teste: ${k}=${v}` });
  }
  const sql = `select ${cols.join(', ')} from public.${tabela}${where.length ? ' where ' + where.join(' and ') : ''}${ordem}${limite}`;
  try {
    const r = await comPapel(claims, c => c.query(sql, vals));
    if ((req.headers.accept || '').includes('vnd.pgrst.object')) {
      if (r.rows.length !== 1) return json(res, 406, { code: 'PGRST116', message: 'JSON object requested, multiple (or no) rows returned', details: `${r.rows.length} rows` });
      return json(res, 200, r.rows[0]);
    }
    return json(res, 200, r.rows);
  } catch (e) { return erroPg(res, e); }
}

const TIPOS = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8', '.txt': 'text/plain; charset=utf-8' };
function estatico(res, url) {
  if (url.pathname === '/painel/js/config.js') {
    res.writeHead(200, { 'Content-Type': TIPOS['.js'] });
    return res.end(`window.OC_CONFIG = { SUPABASE_URL: ${JSON.stringify(`http://127.0.0.1:${PORTA}`)}, SUPABASE_ANON_KEY: ${JSON.stringify(ANON)} };`);
  }
  const rel = decodeURIComponent(url.pathname.replace(/^\/painel\/?/, '')) || 'index.html';
  const arq = path.resolve(PAINEL, rel);
  if (!arq.startsWith(PAINEL + path.sep) || !fs.existsSync(arq) || fs.statSync(arq).isDirectory()) { res.writeHead(404); return res.end(); }
  res.writeHead(200, { 'Content-Type': TIPOS[path.extname(arq)] || 'application/octet-stream' });
  fs.createReadStream(arq).pipe(res);
}

http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://127.0.0.1:${PORTA}`);
  try {
    if (url.pathname.startsWith('/painel')) return estatico(res, url);
    if (url.pathname === '/auth/v1/token') {
      const corpo = JSON.parse((await lerCorpo(req)) || '{}');
      if (url.searchParams.get('grant_type') === 'password') {
        const u = USUARIOS[corpo.email];
        if (!u || u.senha !== corpo.password) return json(res, 400, { error: 'invalid_grant', error_description: 'Invalid login credentials', code: 'invalid_credentials' });
        return json(res, 200, sessao(corpo.email, u));
      }
      const email = Object.keys(USUARIOS).find(e => 'rt-' + USUARIOS[e].id === corpo.refresh_token);
      return email ? json(res, 200, sessao(email, USUARIOS[email])) : json(res, 400, { error: 'invalid_grant' });
    }
    if (url.pathname === '/auth/v1/logout') return json(res, 204);
    if (url.pathname === '/auth/v1/user') {
      const c = verificar((req.headers.authorization || '').replace(/^Bearer /, ''));
      return c && c.sub ? json(res, 200, { id: c.sub, email: c.email, aud: 'authenticated', role: 'authenticated' }) : json(res, 401, { message: 'invalid token' });
    }
    // Storage mínimo (0039): envio com corpo bruto e leitura, sob a RLS de storage.objects
    if (url.pathname.startsWith('/storage/v1/object/')) {
      const token = (req.headers.authorization || '').replace(/^Bearer /, '') || req.headers.apikey;
      const claims = verificar(token);
      if (!claims) return json(res, 401, { message: 'JWT inválido' });
      const rel = decodeURIComponent(url.pathname.replace(/^\/storage\/v1\/object\/(authenticated\/)?/, ''));
      const [bucket, ...resto] = rel.split('/'); const nome = resto.join('/');
      if (!bucket || !nome || nome.includes('..')) return json(res, 400, { message: 'caminho inválido' });
      const arq = path.join(ARQUIVOS, bucket, nome);
      if (req.method === 'POST' || req.method === 'PUT') {
        const ch = []; for await (const d of req) ch.push(d); const corpo = Buffer.concat(ch);
        try {
          await comPapel(claims, c => c.query('insert into storage.objects (bucket_id, name, metadata) values ($1, $2, $3)',
            [bucket, nome, JSON.stringify({ size: corpo.length, mimetype: req.headers['content-type'] || null })]));
        } catch (e) { return json(res, e.code === '23505' ? 409 : 403, { statusCode: e.code === '23505' ? '409' : '403', error: e.code === '23505' ? 'Duplicate' : 'Unauthorized', message: e.message }); }
        fs.mkdirSync(path.dirname(arq), { recursive: true }); fs.writeFileSync(arq, corpo);
        return json(res, 200, { Key: `${bucket}/${nome}` });
      }
      if (req.method === 'GET') {
        const r = await comPapel(claims, c => c.query('select 1 from storage.objects where bucket_id = $1 and name = $2', [bucket, nome]));
        if (!r.rows.length || !fs.existsSync(arq)) return json(res, 404, { message: 'Object not found' });
        res.writeHead(200, { 'Content-Type': 'application/octet-stream' }); return fs.createReadStream(arq).pipe(res);
      }
      return json(res, 405, { message: 'método' });
    }
    if (url.pathname.startsWith('/rest/v1/')) {
      const token = (req.headers.authorization || '').replace(/^Bearer /, '') || req.headers.apikey;
      const claims = verificar(token);
      if (!claims) return json(res, 401, { message: 'JWT inválido' });
      return rest(req, res, url, claims);
    }
    res.writeHead(404); res.end();
  } catch (e) { json(res, 500, { message: e.message }); }
}).listen(PORTA, '127.0.0.1', () => console.log(`servidor de teste em http://127.0.0.1:${PORTA}/painel/`));
