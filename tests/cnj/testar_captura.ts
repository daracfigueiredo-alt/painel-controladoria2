// Teste da Edge Function cnj-captura (Deno), sem rede: a API do CNJ e o banco são simulados.
// Rodar: deno run --allow-env tests/cnj/testar_captura.ts
import { consultarCnj, lote, porOab, carteira, processosDoAtlas, cnjsDoTexto, type Ambiente } from '../../supabase/functions/cnj-captura/index.ts';

let ok = 0, falhas = 0;
const check = (nome: string, esperado: unknown, obtido: unknown) => {
  const e = JSON.stringify(esperado), o = JSON.stringify(obtido);
  if (e === o) { ok++; console.log('OK  ', nome); } else { falhas++; console.log('FALHA', nome, '— esperado', e, 'obtido', o); }
};
const resposta = (status: number, corpo: unknown) => new Response(JSON.stringify(corpo), { status });

function ambiente(roteiro: (url: string, n: number) => Response, rpcs: Record<string, (a: any) => any> = {}) {
  const chamadas: string[] = []; const rpcLog: [string, any][] = []; let relogio = 0; let n = 0;
  const amb: Ambiente = {
    fetch: (async (u: string | URL | Request) => { const url = String(u); chamadas.push(url); return roteiro(url, n++); }) as typeof fetch,
    rpc: async (nome, args) => { rpcLog.push([nome, args]); return rpcs[nome] ? rpcs[nome](args) : null; },
    agora: () => relogio, pausa: 0, dormir: async (ms: number) => { relogio += ms; },
  };
  return { amb, chamadas, rpcLog, avancar: (ms: number) => { relogio += ms; } };
}
const item = (id: number) => ({ id, numero_processo: '00010012020268130024', data_disponibilizacao: '2026-11-11' });

// 1. API ocupada: repete com espera e segue
{
  const { amb, chamadas } = ambiente((_u, n) => n < 2 ? resposta(500, { status: 'error', message: 'O sistema está muito ocupado.' })
                                                   : resposta(200, { status: 'success', count: 1, items: [item(1)] }));
  const r = await consultarCnj(amb, { numeroProcesso: '1' });
  check('API ocupada: tenta de novo e recebe', [3, 1], [chamadas.length, r.length]);
}
// 2. paginação (100 por página)
{
  const pag1 = Array.from({ length: 100 }, (_, i) => item(i + 1));
  const { amb, chamadas } = ambiente(u => resposta(200, { status: 'success', count: 130,
    items: u.includes('pagina=1') ? pag1 : Array.from({ length: 30 }, (_, i) => item(200 + i)) }));
  const r = await consultarCnj(amb, { numeroOab: '1' });
  check('Paginação: 130 comunicações em 2 páginas', [2, 130], [chamadas.length, r.length]);
}
// 3. falha persistente vira erro (não é engolida)
{
  const { amb } = ambiente(() => resposta(500, { status: 'error', message: 'O sistema está muito ocupado.' }));
  let erro = ''; try { await consultarCnj(amb, { numeroProcesso: '1' }); } catch (e) { erro = (e as Error).message; }
  check('Falha persistente: erro com o motivo', true, erro.includes('muito ocupado'));
}
// 4. lote: marca sucesso e falha, registra a execução
{
  const fila = ['0001001-20.2026.8.13.0024', '0001002-00.2026.8.13.0024'];
  const { amb, chamadas, rpcLog } = ambiente(u => u.includes('00010012') ? resposta(200, { status: 'success', count: 1, items: [item(7)] })
                                                                         : resposta(400, { status: 'error', message: 'inválido' }),
    { cnj_proximos: () => fila, cnj_registrar: (a: any) => ({ recebidas: a.p_itens.length, novas: a.p_itens.length }) });
  const r = await lote(amb, 7, null);
  const marcas = rpcLog.filter(x => x[0] === 'cnj_marcar').map(x => [x[1].p_cnj, x[1].p_ok]);
  check('Lote: um sucesso e uma falha marcados', [[fila[0], true], [fila[1], false]], marcas);
  check('Lote: consulta por número do processo (só dígitos) e janela de datas', true,
        chamadas[0].includes('numeroProcesso=00010012020268130024') && chamadas[0].includes('dataDisponibilizacaoInicio='));
  check('Lote: resumo', [2, 1, 1, 1], [r.consultas, r.sucesso, r.falhas, r.novas]);
  check('Lote: execução registrada', 'lote', rpcLog.find(x => x[0] === 'cnj_execucao_registrar')?.[1].p_tipo);
}
// 5. lote respeita o tempo máximo da função
{
  const fila = Array.from({ length: 10 }, (_, i) => `000${1000 + i}-00.2026.8.13.0024`);
  const { amb } = ambiente(() => resposta(200, { status: 'success', count: 0, items: [] }), { cnj_proximos: () => fila });
  amb.pausa = 30_000;    // 30 s entre consultas
  const r = await lote(amb, 7, null);
  check('Lote interrompido antes do limite de tempo (o resto fica para a próxima execução)', [2, true], [r.consultas, r.interrompido]);
}
// 6. OAB: "176787/MG" vira numeroOab + ufOab
{
  const { amb, chamadas, rpcLog } = ambiente(() => resposta(200, { status: 'success', count: 2, items: [item(1), item(2)] }),
    { cnj_parametro: () => ['176787/MG'], cnj_registrar: () => ({ recebidas: 2, novas: 1 }) });
  const r = await porOab(amb);
  check('OAB: consulta com número e UF', true, chamadas[0].includes('numeroOab=176787') && chamadas[0].includes('ufOab=MG'));
  check('OAB: comunicações registradas com a origem da captura', 'oab:176787/MG', rpcLog.find(x => x[0] === 'cnj_registrar')?.[1].p_encontrada_por);
  check('OAB: resumo', [1, 2, 1], [r.sucesso, r.comunicacoes, r.novas]);
}
// 7. carteira: processos do Atlas (CNJ em qualquer campo) e queda para a base quando o Atlas recusa
{
  check('CNJ achado no texto, com ou sem máscara', ['00010012020268130024', '50000012020264013800'],
        cnjsDoTexto('proc 0001001-20.2026.8.13.0024 e 50000012020264013800'));
  check('Processos do Atlas: campo preferido, id e cliente', [{ cnj: '00010012020268130024', lawsuit_id: 'L9', cliente: 'Banco X' }],
        processosDoAtlas([{ id: 'L9', process_number: '0001001-20.2026.8.13.0024', client_name: 'Banco X', notes: 'ver 0009999-99.2026.8.13.0024' }]));
  const { amb, rpcLog } = ambiente(() => resposta(403, { success: false, code: 'permission_denied', error: 'Permission denied: read_lawsuits is disabled' }),
    { cnj_carteira_registrar: () => ({ novos: 5, carteira: 5 }) });
  Deno.env.set('ATLAS_API_KEY', 'chave-de-teste');
  const r = await carteira(amb);
  check('Sem permissão no Atlas: carteira usa a base e registra o erro', ['base', true],
        [rpcLog.find(x => x[0] === 'cnj_carteira_registrar')?.[1].p_origem, String(r.erro_atlas).includes('read_lawsuits')]);
}

console.log(`\n${ok}/${ok + falhas} OK`);
if (falhas) Deno.exit(1);
