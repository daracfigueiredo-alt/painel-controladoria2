// Teste da Edge Function atlas-cadastro (Deno), sem rede: a API do Atlas e o banco são simulados.
// Rodar: deno run --allow-env tests/atlas/testar_cadastro.ts
import { cadastrar, clientes, corpoDoCadastro, type Ambiente } from '../../supabase/functions/atlas-cadastro/index.ts';

let ok = 0, falhas = 0;
const check = (nome: string, esperado: unknown, obtido: unknown) => {
  const e = JSON.stringify(esperado), o = JSON.stringify(obtido);
  if (e === o) { ok++; console.log('OK  ', nome); } else { falhas++; console.log('FALHA', nome, '— esperado', e, 'obtido', o); }
};
const resposta = (status: number, corpo: unknown, headers: Record<string, string> = {}) =>
  new Response(JSON.stringify(corpo), { status, headers });

type Chamada = { action: string; data: any; idem: string | null };
function ambiente(roteiro: (c: Chamada, n: number) => Response, rpcs: Record<string, (a: any) => any> = {}) {
  const chamadas: Chamada[] = []; const rpcLog: [string, any][] = []; let relogio = 0; let n = 0;
  const amb: Ambiente = {
    fetch: (async (_u: string, init: RequestInit) => {
      const b = JSON.parse(String(init.body)); const h = init.headers as Record<string, string>;
      const c = { action: b.action, data: b.data, idem: h['Idempotency-Key'] ?? null };
      chamadas.push(c); return roteiro(c, n++);
    }) as unknown as typeof fetch,
    rpc: async (nome, args) => { rpcLog.push([nome, args]); return rpcs[nome] ? rpcs[nome](args) : null; },
    agora: () => relogio, pausa: 0, dormir: async (ms: number) => { relogio += ms; }, chave: 'chave-de-teste',
  };
  return { amb, chamadas, rpcLog, avancar: (ms: number) => { relogio += ms; } };
}
const item = (cnj: string, extra: Record<string, unknown> = {}) => ({ cnj, clientId: 'C1', type: 'Revisional de Contrato', causeValue: 100.5,
  protocolDate: '2026-03-10', authors: 'Cliente', defendants: 'Banco', notes: 'Cadastrado pela controladoria', tentativa: 1,
  idempotencyKey: 'ctrl-cadastro-' + cnj.replace(/\D/g, '') + '-abcd1234', ...extra });
const resultados = (log: [string, any][]) => log.filter(x => x[0] === 'atlas_cadastro_resultado').map(x => [x[1].p_cnj, x[1].p_resultado, x[1].p_lawsuit_id]);

// 1. corpo do create_lawsuit: só dígitos, campos opcionais fora quando vazios
check('Corpo do cadastro: número só com dígitos e campos da API', { clientId: 'C1', processNumber: '00010012020268130024', type: 'Outros', causeValue: 0 },
      corpoDoCadastro({ cnj: '0001001-20.2026.8.13.0024', clientId: 'C1', type: '', causeValue: null, protocolDate: null, authors: null }));

// 2. fluxo normal: confere, cadastra com Idempotency-Key, registra
{
  const { amb, chamadas, rpcLog } = ambiente(c => c.action === 'list_lawsuits' ? resposta(200, { success: true, lawsuits: [] })
                                                  : resposta(200, { success: true, lawsuitId: 'L1', appUrl: 'https://x' }),
    { atlas_cadastro_proximos: () => [item('0001001-20.2026.8.13.0024')] });
  const r = await cadastrar(amb, 5);
  check('Confere o número no Atlas antes de cadastrar', ['list_lawsuits', '00010012020268130024'], [chamadas[0].action, chamadas[0].data.processNumber]);
  check('create_lawsuit com Idempotency-Key e os dados da prévia', ['create_lawsuit', 'ctrl-cadastro-00010012020268130024-abcd1234-t1', 'C1', 100.5, '2026-03-10'],
        [chamadas[1].action, chamadas[1].idem, chamadas[1].data.clientId, chamadas[1].data.causeValue, chamadas[1].data.protocolDate]);
  check('Resultado gravado como cadastrado', [['0001001-20.2026.8.13.0024', 'cadastrado', 'L1']], resultados(rpcLog));
  check('Resumo e execução registrada', [1, 0, true], [r.cadastrados, r.erros, rpcLog.some(x => x[0] === 'atlas_cadastro_execucao')]);
}
// 3. já existe no Atlas: não cria
{
  const { amb, chamadas, rpcLog } = ambiente(() => resposta(200, { success: true, lawsuits: [{ id: 'L9', client_name: 'X' }] }),
    { atlas_cadastro_proximos: () => [item('0001001-20.2026.8.13.0024')] });
  const r = await cadastrar(amb, 5);
  check('Processo que já existe no Atlas não é criado de novo', [1, ['list_lawsuits'], [['0001001-20.2026.8.13.0024', 'ja_existia', 'L9']]],
        [r.ja_existiam, chamadas.map(c => c.action), resultados(rpcLog)]);
}
// 4. erro de validação: definitivo; falha de rede: tenta de novo
{
  let n = 0;
  const { amb, rpcLog } = ambiente(c => {
    if (c.action === 'list_lawsuits') return resposta(200, { success: true, lawsuits: [] });
    n++;
    return n === 1 ? resposta(400, { error: 'Campo inválido', code: 'validation_error', fields: ['type'] })
                   : resposta(500, { error: 'Erro inesperado', code: 'internal_error' });
  }, { atlas_cadastro_proximos: () => [item('A-1'), item('A-2')] });
  const r = await cadastrar(amb, 5);
  check('Validação do Atlas = erro (com o campo); erro inesperado = tentar de novo', [['A-1', 'erro', null], ['A-2', 'tentar_de_novo', null]], resultados(rpcLog));
  check('Mensagem do Atlas guardada com o campo recusado', true, String(rpcLog.find(x => x[0] === 'atlas_cadastro_resultado')?.[1].p_erro).includes('(type)'));
  check('Resumo: 1 erro e 1 adiado', [1, 1], [r.erros, r.adiados]);
}
// 5. chave sem permissão: para o lote e devolve o resto para a fila
{
  const { amb, chamadas, rpcLog } = ambiente(() => resposta(403, { error: 'Permission denied: write_lawsuits', code: 'permission_denied' }),
    { atlas_cadastro_proximos: () => [item('B-1'), item('B-2'), item('B-3')] });
  const r = await cadastrar(amb, 5);
  check('Sem permissão no Atlas: para na 1ª chamada; os outros voltam para a fila', [1, 'erro', 'adiado', 'adiado'],
        [chamadas.length, ...resultados(rpcLog).map(x => x[1])]);
  check('Motivo da parada informado', true, String(r.parou).includes('Permission denied'));
}
// 6. limite por minuto (429): espera e repete
{
  const { amb, chamadas } = ambiente((c, i) => i === 0 ? resposta(429, { error: 'rate', code: 'rate_limited' }, { 'Retry-After': '5' })
                                        : c.action === 'list_lawsuits' ? resposta(200, { success: true, lawsuits: [] })
                                        : resposta(200, { success: true, lawsuitId: 'L2' }),
    { atlas_cadastro_proximos: () => [item('C-1')] });
  const r = await cadastrar(amb, 5);
  check('Limite por minuto: espera o Retry-After e repete', [1, 3], [r.cadastrados, chamadas.length]);
}
// 7. tempo da execução: o resto volta para a fila
{
  const { amb, rpcLog } = ambiente(c => c.action === 'list_lawsuits' ? resposta(200, { success: true, lawsuits: [] })
                                           : resposta(200, { success: true, lawsuitId: 'L' }),
    { atlas_cadastro_proximos: () => Array.from({ length: 6 }, (_, i) => item('D-' + i)) });
  amb.pausa = 10_000;
  const r = await cadastrar(amb, 6);
  check('Execução respeita o tempo máximo (o resto volta sem contar tentativa)', [true, 'adiado'],
        [r.interrompido, resultados(rpcLog).at(-1)?.[1]]);
}
// 8. segunda tentativa usa outra chave de idempotência (a conferência anterior evita duplicar)
{
  const { amb, chamadas } = ambiente(c => c.action === 'list_lawsuits' ? resposta(200, { success: true, lawsuits: [] }) : resposta(200, { success: true, lawsuitId: 'L' }),
    { atlas_cadastro_proximos: () => [item('E-1', { tentativa: 2 })] });
  await cadastrar(amb, 1);
  check('Nova tentativa: chave com o número da tentativa', true, String(chamadas[1].idem).endsWith('-t2'));
}
// 9. clientes: todas as páginas, sem repetir, com documento
{
  const { amb, chamadas, rpcLog } = ambiente(c => c.data.cursor
      ? resposta(200, { success: true, clients: [{ id: 'B', name: 'B', doc_id: null }, { id: 'A', name: 'A2', doc_id: '1' }], hasMore: false })
      : resposta(200, { success: true, clients: [{ id: 'A', name: 'A', doc_id: '11222333000181', status: 'ativo' }], hasMore: true, nextCursor: 'k' }),
    { atlas_clientes_registrar: (a: any) => ({ recebidos: a.p_itens.length, removidos: 0, total: a.p_itens.length }) });
  const r = await clientes(amb);
  const enviados = rpcLog.find(x => x[0] === 'atlas_clientes_registrar')?.[1];
  check('Clientes: 2 páginas, sem repetir a ficha e leitura completa', [2, 2, 2, true], [chamadas.length, r.lidos, enviados.p_itens.length, enviados.p_completo]);
}
// 10. fila vazia: nenhuma chamada ao Atlas
{
  const { amb, chamadas, rpcLog } = ambiente(() => resposta(500, {}), { atlas_cadastro_proximos: () => [] });
  await cadastrar(amb, 5);
  check('Fila vazia: nada chamado no Atlas e nada registrado', [0, false], [chamadas.length, rpcLog.some(x => x[0] === 'atlas_cadastro_execucao')]);
}

console.log(`\n${ok}/${ok + falhas} OK`);
if (falhas) Deno.exit(1);
