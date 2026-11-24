/* Teste ponta a ponta da Edge Function atlas-sync (11/11/2026), SÓ LOCAL e com dados FICTÍCIOS:
 *   Deno roda supabase/functions/atlas-sync/index.ts;
 *   o "Supabase" é o servidor de teste (tests/e2e/servidor_local.js) sobre o PostgreSQL local;
 *   o "Atlas" é um simulador que segue a documentação da API (x-api-key, list_tasks paginado,
 *   429 com Retry-After, create_task com Idempotency-Key). Nenhuma chamada ao Atlas real. */
'use strict';
const http = require('http');
const { execFileSync, spawn } = require('child_process');
const path = require('path');
const RAIZ = path.resolve(__dirname, '..', '..');
const DB = 'ctrl_atlas_edge', PSB = 8791, PATLAS = 8792, PFN = 8000;
const CRON = 'segredo-cron-de-teste-0123456789';
// chave de serviço do servidor de teste (mesmo segredo HS256 do servidor_local.js)
const SERVICO = (() => { const c = require('crypto'); const b = o => Buffer.from(JSON.stringify(o)).toString('base64url');
  const h = b({ alg: 'HS256', typ: 'JWT' }), p = b({ role: 'service_role', iss: 'teste-local' });
  return `${h}.${p}.${c.createHmac('sha256', 'segredo-somente-teste-local-0123456789abcdef').update(`${h}.${p}`).digest('base64url')}`; })();
const DENO = process.env.DENO || 'deno';
const psql = (sql, db = DB) => execFileSync('psql', ['-h', '/tmp', '-p', '5433', '-U', 'postgres', '-At', '-q', '-v', 'ON_ERROR_STOP=1', '-d', db], { input: sql, encoding: 'utf8' }).trim();
const res = []; const check = (n, e, o) => res.push([n, String(e), String(o), String(e) === String(o) ? 'OK' : 'FALHA']);
const espera = ms => new Promise(r => setTimeout(r, ms));

// ------------------------------------------------------------------ simulador do Atlas
const CHAVE = 'chave-ficticia-de-teste';
const U1 = '11111111-1111-4111-8111-111111111111';
const tarefas = [];
for (let i = 0; i < 230; i++) {   // 3 páginas de 100 nas abertas
  const id = `00000000-0000-4000-8000-${String(i).padStart(12, '0')}`;
  tarefas.push({ id, title: `Tarefa ${i}`, description: 'TF - teste', status: i % 3 === 0 ? 'doing' : 'todo', priority: 'normal',
    due_date: '2026-11-20', fatal_date: i % 2 ? '2026-11-25' : null, client_name: 'CLIENTE TESTE', created_by: U1,
    lawsuit_number: null, source_intimacao_number: null, assignees: [{ user_id: U1, name: 'Ana Teste', is_principal: true, completed_at: null }],
    created_at: '2026-11-10T13:00:00Z', updated_at: '2026-11-10T13:00:00Z', deleted_at: null, app_url: 'https://gestor.atlasjus.com/#/tasks?task=' + id });
}
tarefas.push({ ...tarefas[1], id: '00000000-0000-4000-8000-888888888888', title: 'Contestar ação revisional', description: 'Texto original do Atlas.',
  description_truncated: false, status: 'todo', fatal_date: '2026-12-10' });
tarefas.push({ ...tarefas[0], id: '00000000-0000-4000-8000-999999999999', title: 'Concluída', status: 'done',
  assignees: [{ user_id: U1, name: 'Ana Teste', is_principal: true, completed_at: '2026-11-11T14:00:00Z' }] });
const chamadas = []; let deu429 = false;
http.createServer((req, res) => {
  let b = ''; req.on('data', d => b += d); req.on('end', () => {
    const r = (st, o, h = {}) => { res.writeHead(st, { 'Content-Type': 'application/json', ...h }); res.end(JSON.stringify(o)); };
    if (!req.headers['x-api-key']) return r(401, { error: 'sem chave', code: 'missing_api_key' });
    if (req.headers['x-api-key'] !== CHAVE) return r(403, { error: 'chave inválida', code: 'invalid_api_key' });
    const { action, data } = JSON.parse(b);
    chamadas.push({ action, data, idem: req.headers['idempotency-key'] || null });
    if (action === 'whoami') return r(200, { success: true, tenant: { id: 'x', name: 'Escritório Teste' }, plan: 'elite', permissions: { list_tasks: true }, keyScope: 'full', keyName: 'Integração', rateLimitPerMinute: 60 });
    if (action === 'list_tasks') {
      if (!deu429) { deu429 = true; return r(429, { error: 'limite', code: 'rate_limited' }, { 'Retry-After': '1' }); }
      if (!(data.limit >= 1 && data.limit <= 100)) return r(400, { error: 'limit', code: 'validation_error' });
      const st = [].concat(data.status || []);
      const lista = tarefas.filter(t => st.includes(t.status));
      const ini = Number(data.cursor || 0); const pag = lista.slice(ini, ini + data.limit);
      const mais = ini + data.limit < lista.length;
      return r(200, { success: true, tasks: pag, hasMore: mais, nextCursor: mais ? String(ini + data.limit) : null });
    }
    if (action === 'list_deadlines') {   // 0041: 150 intimações em 2 páginas
      const todas = Array.from({ length: 150 }, (_, i) => ({ id: `b0000000-0000-4000-8000-${String(i).padStart(12, '0')}`,
        process_number: `${String(i).padStart(7, '0')}-11.2026.8.13.0024`, available_date: '2026-11-10', publication_date: '2026-11-11',
        status: 'lida', inferred_type: 'prazo', client_id: 'c0000000-0000-4000-8000-000000000001', client_match_status: 'confirmado',
        deadline: { fatal_date: '2026-12-01' }, tasks: [], summary: 'resumo', updated_at: '2026-11-11T12:00:00Z' }));
      const ini = Number(data.cursor || 0); const pag = todas.slice(ini, ini + data.limit); const mais = ini + data.limit < todas.length;
      return r(200, { success: true, deadlines: pag, hasMore: mais, nextCursor: mais ? String(ini + data.limit) : null });
    }
    if (action === 'get_productivity') return r(200, { success: true, productivity: { from: data.from, to: data.to,
      members: [{ user_id: U1, name: 'Ana Teste', active: true, tasks_completed: 12, active_days: 6 }] } });
    if (action === 'edit_task') {
      if (!data.taskId || Object.keys(data).length < 2) return r(400, { error: 'campos', code: 'validation_error' });
      return r(200, { success: true, taskId: data.taskId, updatedFields: Object.keys(data).filter(k => k !== 'taskId'), appUrl: 'x' });
    }
    if (action === 'add_task_comment') return r(403, { error: 'chave sem autor', code: 'key_author_required' });
    if (action === 'create_task') {
      if (!data.title || !(data.assigneeEmail || data.assigneeUserId)) return r(400, { error: 'campos', code: 'validation_error', fields: ['title'] });
      return r(200, { success: true, taskId: 'eeeeeeee-0000-4000-8000-00000000000e', clientLinked: false, assigneeUserId: U1, warnings: [], appUrl: 'https://gestor.atlasjus.com/#/tasks?task=e' });
    }
    return r(400, { error: 'ação', code: 'unknown_action' });
  });
}).listen(PATLAS, '127.0.0.1');

(async () => {
  psql(`drop database if exists ${DB}`, 'postgres'); psql(`create database ${DB}`, 'postgres');
  const fs = require('fs');
  for (const f of [path.join(RAIZ, 'tests', '00_stub_supabase_local.sql'), ...fs.readdirSync(path.join(RAIZ, 'supabase', 'migrations')).sort().map(f => path.join(RAIZ, 'supabase', 'migrations', f))])
    execFileSync('psql', ['-h', '/tmp', '-p', '5433', '-U', 'postgres', '-q', '-v', 'ON_ERROR_STOP=1', '-d', DB, '-f', f], { stdio: 'pipe' });
  psql(`insert into colaboradores(nome_advbox, origem) values ('COLAB TESTE','administrativo');
        insert into perfis values ('00000000-0000-0000-0000-00000000000a','admin',null), ('00000000-0000-0000-0000-00000000000c','colaborador',(select id from colaboradores limit 1));
        insert into equipes(nome) values ('Equipe A'); insert into colaboradores(nome_advbox, origem, equipe_id) values ('LIDER TESTE','administrativo',(select id from equipes where nome = 'Equipe A'));
        insert into perfis values ('00000000-0000-0000-0000-0000000000d1','lider',(select id from colaboradores where nome_advbox='LIDER TESTE'));
        insert into lideres_equipes(user_id, equipe_id) values ('00000000-0000-0000-0000-0000000000d1',(select id from equipes where nome = 'Equipe A'));`);
  const sb = spawn('node', [path.join(RAIZ, 'tests', 'e2e', 'servidor_local.js')], { env: { ...process.env, DB, PORTA: String(PSB) }, stdio: 'ignore' });
  await espera(800);
  const anon = /SUPABASE_ANON_KEY: "([^"]+)"/.exec(await (await fetch(`http://127.0.0.1:${PSB}/painel/js/config.js`)).text())[1];
  const fn = spawn(DENO, ['run', '--allow-net', '--allow-env', path.join(RAIZ, 'supabase', 'functions', 'atlas-sync', 'index.ts')],
    { env: { ...process.env, SUPABASE_URL: `http://127.0.0.1:${PSB}`, SUPABASE_ANON_KEY: anon, ATLAS_API_URL: `http://127.0.0.1:${PATLAS}`, ATLAS_API_KEY: CHAVE,
             SUPABASE_SERVICE_ROLE_KEY: SERVICO, CRON_SECRET: CRON }, stdio: 'ignore', detached: true });
  for (let i = 0; i < 60; i++) { try { await fetch(`http://127.0.0.1:${PFN}`, { method: 'OPTIONS' }); break; } catch { await espera(500); } }
  const login = async (email, senha) => (await (await fetch(`http://127.0.0.1:${PSB}/auth/v1/token?grant_type=password`, { method: 'POST', headers: { 'Content-Type': 'application/json', apikey: anon }, body: JSON.stringify({ email, password: senha }) })).json()).access_token;
  const tAdmin = await login('admin.teste@exemplo.invalid', 'senha-admin-teste');
  const tColab = await login('colab.teste@exemplo.invalid', 'senha-colab-teste');
  const chama = async (token, corpo, extra = {}) => { const r = await fetch(`http://127.0.0.1:${PFN}`, { method: 'POST', headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: 'Bearer ' + token } : {}), ...extra }, body: JSON.stringify(corpo) }); return { st: r.status, j: await r.json() }; };
  const tLider = await login('lider.teste@exemplo.invalid', 'senha-lider-teste');
  const comoAdmin = sql => psql(`set role authenticated; set request.jwt.claim.sub='00000000-0000-0000-0000-00000000000a'; ${sql}`).split('\n').pop();
  const comoLider = sql => psql(`set role authenticated; set request.jwt.claim.sub='00000000-0000-0000-0000-0000000000d1'; ${sql}`).split('\n').pop();
  try {
    let r = await chama(null, { acao: 'testar' });
    check('Sem login: recusado antes de chamar o Atlas', '401|0', `${r.st}|${chamadas.length}`);
    r = await chama(tColab, { acao: 'sincronizar' });
    check('Colaborador: recusado pelo banco, nenhuma chamada ao Atlas', `403|0`, `${r.st}|${chamadas.length}`);
    r = await chama(tAdmin, { acao: 'testar' });
    check('Testar a chave (whoami)', 'true|Escritório Teste|full', `${r.j.ok}|${r.j.escritorio}|${r.j.acesso}`);
    r = await chama(tAdmin, { acao: 'sincronizar' });
    check('Sincronizar: 232 tarefas (231 abertas em 3 páginas + 1 concluída), 429 respeitado', 'true|232|231|1', `${r.j.ok}|${r.j.tarefas}|${r.j.abertas}|${r.j.concluidas_recentes}`);
    check('Páginas de no máximo 100 e cursor seguido', 'true', chamadas.filter(c => c.action === 'list_tasks' && c.data.cursor).length >= 2 && chamadas.every(c => c.action !== 'list_tasks' || c.data.limit === 100));
    check('Lote do Atlas gravado com 232 linhas ligadas pelo ID', 'atlas|232|232',
      psql(`select l.origem, count(li.*), count(li.*) filter (where li.metodo_vinculo='atlas_id') from lotes_importacao l join linhas_importadas li on li.lote_id=l.id where l.id=${r.j.lote_id} group by 1`));
    check('Concluídas pedidas com updatedSince', 'true', chamadas.some(c => c.action === 'list_tasks' && [].concat(c.data.status).includes('done') && c.data.updatedSince));
    check('Log da integração registrado', '1', psql(`select count(*) from log_integracao where origem='atlas_api' and operacao='sincronizar' and nivel='info'`));
    // 0058: "em andamento" no Atlas = início da tratativa (77 tarefas em andamento no simulador)
    check('0058 Em andamento: início registrado na sincronização', '77|77|77',
      `${r.j.inicios_por_andamento}|${psql(`select count(*) from eventos where tipo='inicio_tratativa' and evidencia->>'fonte'='atlas_em_andamento'`)}|${psql(`select count(*) from eventos where tipo='inicio_tratativa' and origem='sistema' and colaborador_id is not null`)}`);
    // tarefa de análise criada pela API
    const id = psql(`set role authenticated; set request.jwt.claim.sub='00000000-0000-0000-0000-00000000000a'; select (analise_preparar_teste('TESTE 1.0','teste')->>'id')`).split('\n').pop();
    psql(`set role authenticated; set request.jwt.claim.sub='00000000-0000-0000-0000-00000000000a'; select analise_decidir(${id}, 'aprovar', 'ok')`);
    r = await chama(tAdmin, { acao: 'criar_tarefa', id: Number(id) });
    const c = chamadas.filter(x => x.action === 'create_task').pop();
    check('Tarefa de análise criada no Atlas com chave de idempotência', `true|criada|controladoria-analise-${id}-1`, `${r.j.ok}|${r.j.status}|${c && c.idem}`);
    r = await chama(tAdmin, { acao: 'criar_tarefa', id: Number(id) });
    check('Repetir não cria de novo (recusado pelo banco)', 'true|1', `${r.st >= 400}|${chamadas.filter(x => x.action === 'create_task').length}`);
    // ---------------------------------------------------------------- 0039: descrição padrão
    comoAdmin(`select admin_salvar_modalidade((select to_jsonb(m) || '{"ativa":true}' from modalidades m where nome='Contestação'), 'ativação para o teste')`);
    r = await chama(tAdmin, { acao: 'padronizar_descricoes', limite: 10 });
    const ed = chamadas.filter(x => x.action === 'edit_task').pop();
    check('Padronizar: grava o bloco preservando o texto original do Atlas', 'true|1|true|true',
      `${r.j.ok}|${r.j.gravadas}|${!!ed && ed.data.description.startsWith('Texto original do Atlas.')}|${!!ed && ed.data.description.includes('=== Controladoria Oliveira e Camilo (padrão) ===')}`);
    r = await chama(tAdmin, { acao: 'padronizar_descricoes', limite: 10 });
    check('Padronizar de novo: nada a gravar (bloco igual)', '0', r.j.gravadas);
    // ---------------------------------------------------------------- 0041: intimações e fim do expediente
    r = await chama(tAdmin, { acao: 'sincronizar_intimacoes' });
    check('Intimações do Atlas: 150 em 2 páginas', 'true|150|150', `${r.j.ok}|${r.j.intimacoes}|${psql('select count(*) from atlas_intimacoes')}`);
    r = await chama(tColab, { acao: 'fim_expediente' });
    check('Fim do expediente: colaborador recusado', '403', r.st);
    r = await chama(anon, { acao: 'fim_expediente' }, { 'x-cron-secret': 'errado' });
    check('Agendamento com segredo errado: recusado', '401', r.st);
    r = await chama(anon, { acao: 'sincronizar' }, { 'x-cron-secret': CRON });
    check('Segredo do agendamento só vale para fim_expediente', '401', r.st);
    const antes = chamadas.length;
    r = await chama(anon, { acao: 'fim_expediente' }, { 'x-cron-secret': CRON });
    check('Agendamento: tarefas + intimações + produtividade + double check', 'true|true|true|true',
      ['tarefas', 'intimacoes', 'produtividade', 'double_check'].map(k => r.j.etapas && r.j.etapas[k] && r.j.etapas[k].ok).join('|'));
    check('Agendamento não grava nada no Atlas (só leitura)', 'false',
      chamadas.slice(antes).some(c => ['edit_task', 'create_task', 'add_task_comment', 'complete_task'].includes(c.action)));
    check('Relatório diário automático e produtividade gravados', 'automatico|1',
      `${psql('select origem from relatorios_diarios order by id desc limit 1')}|${psql('select count(*) from atlas_produtividade')}`);
    // ---------------------------------------------------------------- 0040: solicitação do líder executada no Atlas
    const ana = psql("select id from colaboradores where atlas_user_id = '11111111-1111-4111-8111-111111111111'");
    psql(`update colaboradores set equipe_id = (select id from equipes where nome = 'Equipe A') where id = ${ana}`);
    const dia = psql('select somar_dias_uteis(hoje_brasilia(), 2)');
    const sol = JSON.parse(comoLider(`select solicitacao_criar('nova_tarefa', ${ana}, '{"titulo":"Petição avulsa do cliente","prioridade":"normal","data":"${dia}"}'::jsonb, null, 'Cliente pediu petição avulsa hoje')`));
    r = await chama(tColab, { acao: 'executar_solicitacao', id: sol.id });
    check('Colaborador não executa solicitação', '403', r.st);
    r = await chama(tLider, { acao: 'executar_solicitacao', id: sol.id });
    const ct = chamadas.filter(x => x.action === 'create_task').pop();
    check('Líder executa a solicitação aprovada: tarefa criada para o advogado no Atlas', `true|executada|11111111-1111-4111-8111-111111111111|controladoria-solic-${sol.id}-nova`,
      `${r.j.ok}|${r.j.solicitacao && r.j.solicitacao.status}|${ct.data.assigneeUserId}|${ct.idem}`);
    r = await chama(tLider, { acao: 'executar_solicitacao', id: sol.id });
    check('Executar de novo: recusado (já executada)', 'true', r.st >= 400);
    // ---------------------------------------------------------------- 0058: peticionador pede, líder aprova e executa
    check('0058 Segunda sincronização não repete o início por andamento', '77',
      psql(`select count(*) from eventos where tipo='inicio_tratativa' and evidencia->>'fonte'='atlas_em_andamento'`));
    psql(`select set_config('controladoria.motivo', 'teste 0058: peticionador ligado à Ana', false);
          update perfis set colaborador_id = ${ana} where user_id = '00000000-0000-0000-0000-00000000000c'`);
    const comoColab = sql => psql(`set role authenticated; set request.jwt.claim.sub='00000000-0000-0000-0000-00000000000c'; ${sql}`).split('\n').pop();
    const tarefa2 = psql("select id from tarefas where atlas_id = '00000000-0000-4000-8000-000000000002'");
    const nova = psql('select somar_dias_uteis(hoje_brasilia(), 3)');
    const ped = JSON.parse(comoColab(`select solicitacao_reagendamento_pedir(${tarefa2}, '${nova}', 'Aguardando documentos do cliente para a peça')`));
    check('0058 Pedido do peticionador (sem D-4): aguarda o líder', 'aguardando_lider|peticionador', `${ped.status}|${ped.dados.origem}`);
    comoLider(`select solicitacao_decidir(${ped.id}, true, 'Pauta comporta a nova data')`);
    r = await chama(tLider, { acao: 'executar_solicitacao', id: ped.id });
    const ed2 = chamadas.filter(x => x.action === 'edit_task').pop();
    check('0058 Líder aprova e executa: nova data gravada no Atlas', `true|executada|00000000-0000-4000-8000-000000000002|${nova}`,
      `${r.j.ok}|${r.j.solicitacao && r.j.solicitacao.status}|${ed2 && ed2.data.taskId}|${ed2 && ed2.data.dueDate}`);
  } finally { try { process.kill(-fn.pid, 'SIGKILL'); } catch { /* já saiu */ } sb.kill(); }
  for (const [n, e, o, s] of res) console.log(`${s.padEnd(5)} ${n}` + (s === 'OK' ? '' : `\n      esperado=${e}\n      obtido  =${o}`));
  const ok = res.filter(r => r[3] === 'OK').length; console.log(`\n${ok}/${res.length} OK`); process.exit(ok === res.length ? 0 : 1);
})().catch(e => { console.error(e); process.exit(1); });
