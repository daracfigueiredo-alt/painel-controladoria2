// Teste da Edge Function admin-senha (0062). Sem rede: o Supabase é simulado. Roda no Deno ou no Node 22+:
//   node --experimental-strip-types tests/admin/testar_senha.mjs
globalThis.Deno ??= { env: { get: () => '' } };
const { tratar, validar } = await import('../../supabase/functions/admin-senha/index.ts');
const res = []; const check = (n, e, o) => res.push([n, String(e), String(o), String(e) === String(o) ? 'OK' : 'FALHA']);
const USER = '00000000-0000-4000-8000-0000000000b1';
function falso({ rpcOk = true, rpcMsg = 'Somente a controladoria', authOk = true } = {}) {
  const chamadas = [];
  const f = async (url, op) => {
    chamadas.push({ url, metodo: op.method, headers: op.headers, corpo: JSON.parse(op.body) });
    if (url.includes('/rest/v1/rpc/admin_registrar_alteracao_senha'))
      return rpcOk ? new Response(JSON.stringify({ user_id: USER, email: 'brendamartinsoecadv@gmail.com' }), { status: 200 })
                   : new Response(JSON.stringify({ message: rpcMsg }), { status: 400 });
    if (url.includes('/auth/v1/admin/users/'))
      return authOk ? new Response('{}', { status: 200 }) : new Response(JSON.stringify({ msg: 'Password should be at least 6 characters' }), { status: 422 });
    return new Response('', { status: 404 });
  };
  return { cfg: { url: 'https://teste.supabase.co', anon: 'anon-x', servico: 'servico-x', fetch: f }, chamadas };
}
const pedido = (corpo, token = 'Bearer token-da-controladoria') =>
  new Request('https://f/admin-senha', { method: 'POST', headers: { Authorization: token, 'Content-Type': 'application/json' }, body: JSON.stringify(corpo) });
const ok = { user_id: USER, senha: 'Senha-Forte-2026', motivo: 'Primeiro acesso da líder da Prime' };

// caminho feliz
{ const { cfg, chamadas } = falso(); const r = await tratar(pedido(ok), cfg); const j = await r.json();
  check('Controladoria: senha trocada', '200|brendamartinsoecadv@gmail.com', `${r.status}|${j.email}`);
  check('Primeiro confere no banco, depois troca', 'rpc|auth', chamadas.map(c => c.url.includes('/rpc/') ? 'rpc' : 'auth').join('|'));
  check('Conferência usa o token de quem pediu (não a chave de serviço)', 'Bearer token-da-controladoria|anon-x', `${chamadas[0].headers.Authorization}|${chamadas[0].headers.apikey}`);
  check('Conferência não recebe a senha', 'false', String(JSON.stringify(chamadas[0].corpo).includes('Senha-Forte')));
  check('Troca usa a chave de serviço e PUT na conta', `PUT|Bearer servico-x|/auth/v1/admin/users/${USER}`, `${chamadas[1].metodo}|${chamadas[1].headers.Authorization}|${new URL(chamadas[1].url).pathname}`);
  check('Troca envia só a senha', '["password"]', JSON.stringify(Object.keys(chamadas[1].corpo))); }
// banco recusa (não é controladoria): nada é trocado
{ const { cfg, chamadas } = falso({ rpcOk: false }); const r = await tratar(pedido(ok), cfg); const j = await r.json();
  check('Quem não é controladoria: 403 e nada trocado', '403|Somente a controladoria|1', `${r.status}|${j.erro}|${chamadas.length}`); }
{ const { cfg, chamadas } = falso({ rpcOk: false, rpcMsg: 'Informe o motivo da alteração (mínimo 10 caracteres)' }); const r = await tratar(pedido(ok), cfg);
  check('Banco recusa o motivo: 400 e nada trocado', '400|1', `${r.status}|${chamadas.length}`); }
// Supabase recusa a senha
{ const { cfg } = falso({ authOk: false }); const r = await tratar(pedido(ok), cfg); const j = await r.json();
  check('Supabase recusa: a mensagem chega à tela', '400|true', `${r.status}|${/recusou a senha: Password should/.test(j.erro)}`); }
// tokens que não são de pessoa
for (const [n, t] of [['sem login', ''], ['chave de serviço', 'Bearer servico-x'], ['chave pública', 'Bearer anon-x']]) {
  const { cfg, chamadas } = falso(); const r = await tratar(pedido(ok, t), cfg);
  check(`Token ${n}: 401 sem chamar nada`, '401|0', `${r.status}|${chamadas.length}`); }
// validação
check('Senha curta', 'A senha precisa ter pelo menos 8 caracteres.', validar({ ...ok, senha: '1234567' }));
check('Senha com espaço nas pontas', 'A senha não pode começar nem terminar com espaço.', validar({ ...ok, senha: ' Senha-Forte ' }));
check('Senha longa demais', 'A senha pode ter no máximo 72 caracteres.', validar({ ...ok, senha: 'x'.repeat(73) }));
check('Conta inválida', 'Conta inválida.', validar({ ...ok, user_id: "1' or 1=1" }));
check('Motivo curto', 'Informe o motivo da alteração (mínimo 10 caracteres).', validar({ ...ok, motivo: 'curto' }));
check('Pedido válido', 'null', String(validar(ok)));
{ const { cfg, chamadas } = falso(); const r = await tratar(pedido({ ...ok, senha: '123' }), cfg);
  check('Pedido inválido: 400 sem chamar nada', '400|0', `${r.status}|${chamadas.length}`); }
{ const { cfg } = falso(); const r = await tratar(new Request('https://f/admin-senha', { method: 'GET' }), cfg); check('GET recusado', '405', r.status); }
{ const { cfg } = falso(); cfg.servico = ''; const r = await tratar(pedido(ok), cfg); check('Sem chave de serviço configurada: 500', '500', r.status); }

for (const [n, e, o, s] of res) console.log(`[${s}] ${n}` + (s === 'OK' ? '' : `\n    esperado: ${e}\n    obtido:   ${o}`));
const falhas = res.filter(r => r[3] !== 'OK').length; console.log(`\n${res.length - falhas}/${res.length} verificações OK`);
process?.exit?.(falhas ? 1 : 0);
