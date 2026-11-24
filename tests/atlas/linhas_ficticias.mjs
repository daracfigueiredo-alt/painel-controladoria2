// Gera as linhas de importação a partir de tarefas FICTÍCIAS no formato do list_tasks do Atlas.
// uso: node linhas_ficticias.mjs <cenario> '<json nomes>'   (cenario: usuarios | s1 | s2)
import { tarefaParaLinha, usuariosDasTarefas, semRepetir } from '../../supabase/functions/atlas-sync/mapear.js';

const U = { ana: '11111111-1111-4111-8111-111111111111', bruno: '22222222-2222-4222-8222-222222222222',
            brenda: '33333333-3333-4333-8333-333333333333' };
const T = { a: 'aaaaaaaa-0000-4000-8000-00000000000a', b: 'bbbbbbbb-0000-4000-8000-00000000000b',
            c: 'cccccccc-0000-4000-8000-00000000000c', d: 'dddddddd-0000-4000-8000-00000000000d' };
const resp = (id, name, principal = true, completed_at = null) => ({ user_id: id, name, is_principal: principal, completed_at });
const base = (id, extra) => ({ id, title: 'Contestar', description: 'TF - 10/11 - elaborar contestação.', status: 'todo',
  priority: 'normal', due_date: '2026-11-20', fatal_date: '2026-11-25', client_name: 'CLIENTE TESTE', created_by: U.ana,
  lawsuit_number: '0000001-02.2026.8.13.0024', source_intimacao_number: null, assignees: [resp(U.ana, 'Ana Teste')],
  created_at: '2026-11-10T13:00:00Z', updated_at: '2026-11-10T13:00:00Z', deleted_at: null,
  app_url: 'https://gestor.atlasjus.com/#/tasks?task=' + id, ...extra });

const s1 = [
  base(T.a, {}),
  base(T.b, { title: 'Recurso', priority: 'urgent', assignees: [resp(U.bruno, 'Bruno Teste')], fatal_date: null }),
  base(T.c, { title: 'Manifestação', description: 'PF: 28/11/2026 conforme publicação', status: 'doing' }),
  base(T.d, { title: 'Sem responsável', assignees: [], due_date: null }),
];
const s2 = [
  base(T.a, { due_date: '2026-11-22', assignees: [resp(U.brenda, 'BRENDA MARTINS'), resp(U.ana, 'Ana Teste', false)] }),  // nova data + novo responsável
  base(T.b, { title: 'Recurso', priority: 'urgent', assignees: [resp(U.bruno, 'Bruno Teste')], fatal_date: '2026-11-30' }), // PF mudou
  base(T.c, { title: 'Manifestação', description: 'PF: 28/11/2026 conforme publicação', status: 'done',
              assignees: [resp(U.ana, 'Ana Teste', true, '2026-11-11T15:30:00Z')] }),                                    // concluída
  base(T.d, { title: 'Sem responsável', assignees: [], due_date: null }),
  base(T.a, { due_date: '2026-11-22', assignees: [resp(U.brenda, 'BRENDA MARTINS'), resp(U.ana, 'Ana Teste', false)] }), // repetida (abertas x concluídas)
];
// cenário d4 (0037): prazos fatais relativos a hoje, informados pelo teste: {"vencido":..,"hoje":..,"proximo":..}
const E = { vencido: 'e0000000-0000-4000-8000-0000000000e1', hoje: 'e0000000-0000-4000-8000-0000000000e2',
            proximo: 'e0000000-0000-4000-8000-0000000000e3' };
const [cenario, nomesTxt, pfsTxt] = process.argv.slice(2);
if (cenario === 'd4') {
  const pfs = JSON.parse(pfsTxt);
  const lista = Object.keys(E).map(k => base(E[k], { title: 'Prazo ' + k, description: 'Tarefa fictícia D-4 ' + k, fatal_date: pfs[k], due_date: pfs.agenda }));
  console.log(JSON.stringify(lista.map(t => tarefaParaLinha(t, JSON.parse(nomesTxt || '{}')))));
  process.exit(0);
}
// cenário json (0038-0041): tarefas fictícias descritas pelo teste, sobre a base padrão
if (cenario === 'json') {
  const lista = JSON.parse(pfsTxt).map(x => base(x.id, x));
  console.log(JSON.stringify(lista.map(t => tarefaParaLinha(t, JSON.parse(nomesTxt || '{}')))));
  process.exit(0);
}
if (cenario === 'usuarios') console.log(JSON.stringify(usuariosDasTarefas([...s1, ...s2])));
else console.log(JSON.stringify(semRepetir(cenario === 's1' ? s1 : s2).map(t => tarefaParaLinha(t, JSON.parse(nomesTxt || '{}')))));
