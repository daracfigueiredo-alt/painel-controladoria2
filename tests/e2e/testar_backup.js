/* Teste do backup e da restauração dos dados (0060, 18/11/2026). Dados FICTÍCIOS, banco LOCAL.
 * 1) baixa o backup pela tela (Configurações › Backup dos dados), como a controladoria faria;
 * 2) cria um banco NOVO só com as migrações, restaura com integracoes/backup/restaurar_dados.py;
 * 3) compara tabela por tabela (quantidade e impressão digital md5 do conteúdo) com o banco de origem;
 * 4) recria as contas com outros IDs e confere o remapeamento. Origem: banco do test_etapa18.py (MANTER=1). */
'use strict';
const { chromium } = require('playwright');
const { execFileSync, spawn } = require('child_process');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const ORIGEM = process.env.DB || 'ctrl_etapa18', DESTINO = 'ctrl_restaurado', PORTA = 8795, BASE = `http://127.0.0.1:${PORTA}/painel/`;
const RAIZ = path.join(__dirname, '..', '..'), SAIDA = path.join(__dirname, 'out', 'backup'); fs.rmSync(SAIDA, { recursive: true, force: true }); fs.mkdirSync(SAIDA, { recursive: true });
const res = [];
const check = (n, e, o) => res.push([n, String(e), String(o), String(e) === String(o) ? 'OK' : 'FALHA']);
const PSQL = ['-h', '/tmp', '-p', '5433', '-U', 'postgres', '-At', '-q', '-v', 'ON_ERROR_STOP=1'];
const psql = (db, sql) => execFileSync('psql', [...PSQL, '-d', db, '-c', sql], { encoding: 'utf8', maxBuffer: 1 << 28 }).trim();
const psqlArq = (db, arq) => execFileSync('psql', [...PSQL, '-d', db, '-f', arq], { encoding: 'utf8', maxBuffer: 1 << 28 }).trim();
const tenta = (fn) => { try { return { ok: true, saida: fn() }; } catch (e) { return { ok: false, erro: String(e.stderr || e.message) }; } };
let srv = null;
process.on('exit', () => { if (srv) srv.kill(); });

// impressão digital de cada tabela: quantidade + md5 das linhas em ordem (chave primária, ou a linha inteira)
const DIGITAL = `select string_agg(t || '=' || n || ':' || h, ',' order by t) from (
  select c.relname t, (xpath('/row/n/text()', query_to_xml(format('select count(*) n from public.%I', c.relname), false, true, '')))[1]::text n,
         (xpath('/row/h/text()', query_to_xml(format('select md5(coalesce(string_agg(to_jsonb(x)::text, %L order by x::text), %L)) h from public.%I x', '|', '', c.relname), false, true, '')))[1]::text h
    from pg_class c join pg_namespace s on s.oid = c.relnamespace where s.nspname = 'public' and c.relkind = 'r') z`;

(async () => {
  // ------------------------------------------------ permissões (banco de origem)
  const comoUsuario = (uid, sql) => tenta(() => psql(ORIGEM, `set role authenticated; set request.jwt.claim.sub = '${uid}'; ${sql}`));
  for (const [quem, uid] of [['Peticionador', '00000000-0000-0000-0000-00000000000c'], ['Líder', '00000000-0000-0000-0000-0000000000d1']]) {
    const r = comoUsuario(uid, 'select backup_tabelas()');
    check(`${quem} não baixa o backup`, 'recusado', !r.ok && /Somente a controladoria/.test(r.erro) ? 'recusado' : 'aceito');
  }
  const rs = tenta(() => psql(ORIGEM, `set role authenticated; set request.jwt.claims = '{"role":"service_role"}'; select backup_tabela('perfis', 0, 10)`));
  check('Chave de serviço (rotina) não baixa o backup', 'recusado', !rs.ok && /Somente a controladoria/.test(rs.erro) ? 'recusado' : 'aceito');
  const ra = tenta(() => psql(ORIGEM, `set role anon; select backup_usuarios()`));
  check('Anônimo não executa', 'recusado', !ra.ok && /permission denied/.test(ra.erro) ? 'recusado' : 'aceito');
  const rt = comoUsuario('00000000-0000-0000-0000-00000000000a', `select backup_tabela('pg_authid', 0, 10)`);
  check('Só tabelas do sistema (nada fora de public)', 'recusado', !rt.ok && /Tabela desconhecida/.test(rt.erro) ? 'recusado' : 'aceito');

  // ------------------------------------------------ 1) baixar pela tela
  srv = spawn(process.execPath, [path.join(__dirname, 'servidor_local.js')], { env: { ...process.env, PORTA: String(PORTA), DB: ORIGEM }, stdio: ['ignore', 'pipe', 'inherit'] });
  await new Promise(ok => srv.stdout.once('data', ok));
  const browser = await chromium.launch();
  const ctxNav = await browser.newContext({ viewport: { width: 1360, height: 900 }, acceptDownloads: true });
  const page = await ctxNav.newPage();
  const erros = []; page.on('pageerror', e => erros.push(e.message));
  page.on('console', m => { if (m.type() === 'error' && !/Failed to load resource/.test(m.text())) erros.push(m.text()); });
  await page.goto(BASE); await page.fill('#login-email', 'admin.teste@exemplo.invalid'); await page.fill('#login-senha', 'senha-admin-teste');
  await page.click('#btn-entrar'); await page.waitForSelector('#tela-app:not([hidden])');
  await page.goto(BASE + '#/configuracoes'); await page.waitForSelector('#cf-backup button');
  const [download] = await Promise.all([page.waitForEvent('download'), page.click('#cf-backup button:text-is("Baixar backup dos dados")')]);
  const arq = path.join(SAIDA, download.suggestedFilename()); await download.saveAs(arq);
  await page.waitForFunction(() => /Backup baixado/.test(document.querySelector('#cf-backup p[aria-live]').textContent));
  const hashTela = await page.getAttribute('#cf-backup p[aria-live]', 'data-hash');
  await page.locator('#cf-backup').screenshot({ path: path.join(__dirname, 'out', '80_backup_dados.png') });
  await browser.close(); srv.kill(); srv = null;
  const bruto = fs.readFileSync(arq);
  check('Arquivo com o nome do dia', 'true', /^backup_dados_controladoria_\d{4}-\d{2}-\d{2}_\d{2}h\d{2}\.json$/.test(path.basename(arq)));
  check('Conferência SHA-256 da tela = arquivo baixado', hashTela, crypto.createHash('sha256').update(bruto).digest('hex'));
  const b = JSON.parse(bruto.toString('utf8'));
  const nTab = Number(psql(ORIGEM, "select count(*) from pg_tables where schemaname = 'public'"));
  check('Todas as tabelas no arquivo', nTab, Object.keys(b.tabelas).length);
  check('Linhas no arquivo = banco (eventos, tarefas, parâmetros)',
    psql(ORIGEM, 'select (select count(*) from eventos) || \'|\' || (select count(*) from tarefas) || \'|\' || (select count(*) from parametros)'),
    `${b.tabelas.eventos.linhas.length}|${b.tabelas.tarefas.linhas.length}|${b.tabelas.parametros.linhas.length}`);
  check('Contas: só id e e-mail (sem senha)', 'id,email', Object.keys(b.usuarios[0]).sort().reverse().join(','));
  check('Nenhum segredo no arquivo', 'false', /encrypted_password|sb_secret_|service_role/i.test(bruto.toString('utf8')));

  // ------------------------------------------------ 2) banco novo + restauração
  execFileSync('python3', [path.join(RAIZ, 'integracoes', 'backup', 'restaurar_dados.py'), arq, SAIDA], { encoding: 'utf8' });
  psql('postgres', `drop database if exists ${DESTINO}`); psql('postgres', `create database ${DESTINO}`);
  psqlArq(DESTINO, path.join(RAIZ, 'tests', '00_stub_supabase_local.sql'));
  for (const m of fs.readdirSync(path.join(RAIZ, 'supabase', 'migrations')).sort()) psqlArq(DESTINO, path.join(RAIZ, 'supabase', 'migrations', m));
  check('Banco novo começa diferente (só dados das migrações)', 'true', psql(DESTINO, DIGITAL) !== psql(ORIGEM, DIGITAL));
  // contas recriadas antes (como no Supabase novo): mesmos e-mails, IDs NOVOS
  for (const u of b.usuarios) psql(DESTINO, `insert into auth.users (id, email) values (gen_random_uuid(), '${u.email}')`);
  const r1 = tenta(() => psqlArq(DESTINO, path.join(SAIDA, '1_restaurar_dados.sql')));
  check('Restauração roda inteira e confere as tabelas', 'true', r1.ok && /Restauração concluída/.test(r1.saida) ? 'true' : r1.erro);
  // impressão digital idêntica à origem, tabela por tabela
  const dOrig = psql(ORIGEM, DIGITAL).split(','), dDest = psql(DESTINO, DIGITAL).split(',');
  const dif = dOrig.filter((x, i) => x !== dDest[i]).map(x => x.split('=')[0]);
  check('Conteúdo idêntico à origem em todas as tabelas', `${dOrig.length} iguais`, dif.length ? 'diferentes: ' + dif.join(' ') : `${dDest.length} iguais`);
  // contadores de id acertados: novo evento não colide
  const seq = psql(DESTINO, "select nextval(pg_get_serial_sequence('public.tarefas','id')) > (select max(id) from tarefas)");
  check('Contadores de id acertados (novo registro não colide)', 't', seq);
  // tabelas de histórico continuam imutáveis depois da carga
  const imut = tenta(() => psql(DESTINO, 'delete from eventos where id = (select id from eventos limit 1)'));
  check('Histórico continua imutável depois da restauração', 'recusado pela trava', imut.ok ? 'aceito' : (/imutável/.test(imut.erro) ? 'recusado pela trava' : imut.erro));
  // rodar de novo: tudo ou nada, mesmo resultado
  const r1b = tenta(() => psqlArq(DESTINO, path.join(SAIDA, '1_restaurar_dados.sql')));
  check('Rodar a restauração de novo dá o mesmo resultado', 'true', r1b.ok && psql(DESTINO, DIGITAL) === psql(ORIGEM, DIGITAL) ? 'true' : (r1b.erro || 'diferente'));

  // ------------------------------------------------ 4) contas: troca dos IDs antigos pelos novos
  const antes = psql(DESTINO, "select count(*) from perfis p where not exists (select 1 from auth.users u where u.id = p.user_id)");
  check('Antes do remapeamento: perfis apontam para os IDs antigos', String(b.usuarios.length), antes);
  const r2 = tenta(() => execFileSync('psql', [...PSQL, '-d', DESTINO, '-f', path.join(SAIDA, '2_remapear_usuarios.sql')], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }));
  check('Remapeamento roda', 'true', r2.ok ? 'true' : r2.erro);
  check('Depois: todo perfil aponta para uma conta existente', '0',
    psql(DESTINO, "select count(*) from perfis p where not exists (select 1 from auth.users u where u.id = p.user_id)"));
  const antigo = b.usuarios.find(u => u.email === 'c@x.invalid').id;
  check('Nenhum ID antigo sobra em coluna nenhuma', '0', psql(DESTINO, `do $x$ declare c record; n bigint; t bigint := 0; begin
     for c in select table_name, column_name from information_schema.columns where table_schema='public' and data_type='uuid'
       and table_name in (select tablename from pg_tables where schemaname='public') loop
       execute format('select count(*) from public.%I where %I = %L', c.table_name, c.column_name, '${antigo}') into n; t := t + n; end loop;
     perform set_config('x.sobra', t::text, false); end $x$; select current_setting('x.sobra')`).split('\n').pop());
  check('O peticionador continua ligado às próprias solicitações', psql(ORIGEM, "select count(*) from solicitacoes where solicitante = '00000000-0000-0000-0000-00000000000c'"),
    psql(DESTINO, "select count(*) from solicitacoes s join auth.users u on u.id = s.solicitante where u.email = 'c@x.invalid'"));
  psql('postgres', `drop database if exists ${DESTINO}`);

  check('Sem erros no console', '[]', JSON.stringify(erros));
  for (const [n, e, o, s] of res) if (s !== 'OK') console.log(`FALHA: ${n}\n  esperado: ${e}\n  obtido:   ${o}`);
  console.log(`${res.filter(r => r[3] === 'OK').length}/${res.length} OK`);
  process.exit(0);
})().catch(e => { console.error(e); process.exit(1); });
