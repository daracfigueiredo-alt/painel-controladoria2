// Edge Function atlas-sync — ponte entre o painel da controladoria e a API do Atlas Gestor.
// * A chave da API do Atlas fica SÓ no segredo ATLAS_API_KEY desta função (nunca no painel nem na extensão).
// * Quem chama é a pessoa logada no painel: o token dela vai junto e o banco confere o papel
//   (as funções de importação exigem administradora). Sem login válido, nada acontece.
// Ações (POST JSON {acao}):
//   testar        -> whoami do Atlas (confere a chave e as permissões; não grava nada)
//   sincronizar   -> lê as tarefas do Atlas (abertas + concluídas recentes) e grava uma fotografia (lote)
//   criar_tarefa  -> cria uma tarefa no Atlas (tarefas de análise); dados validados pelo banco
//   executar_solicitacao  -> executa no Atlas a solicitação aprovada de um líder (0040): create_task,
//                    edit_task (nova data/responsável) e comentário com a justificativa
//   padronizar_descricoes -> grava no Atlas o bloco padrão da controladoria na descrição (0039),
//                    preservando o texto original (só tarefas de modalidade ATIVA)
//   sincronizar_intimacoes -> espelha as intimações e prazos do Atlas (list_deadlines) (0041)
//   workflows      -> ciclo dos workflows (0061): lê no Atlas as etapas concluídas, libera as seguintes e
//                    cria no Atlas as etapas liberadas (create_task com Idempotency-Key). Também pelo agendamento.
//   fim_expediente -> rotina do fim do expediente (0041/0042): tarefas + intimações + produtividade
//                    + double check Webjur × Atlas + relatório diário. Só LÊ o Atlas.
//                    Também pode ser chamada pelo agendamento (pg_cron), com o segredo CRON_SECRET:
//                    nesse caso roda com a chave de serviço (sem usuário).
import { tarefaParaLinha, usuariosDasTarefas, semRepetir, emBlocos, comBloco } from './mapear.js';

const ATLAS_URL = Deno.env.get('ATLAS_API_URL') ?? 'https://tdhgpaurcjinhbandmvb.supabase.co/functions/v1/client-webhook';
const SB_URL = Deno.env.get('SUPABASE_URL')!;
const SB_KEY = Deno.env.get('SUPABASE_ANON_KEY') ?? Deno.env.get('SUPABASE_PUBLISHABLE_KEY') ?? '';
const SB_SERVICO = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const resp = (status: number, corpo: unknown) =>
  new Response(JSON.stringify(corpo), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });

class ErroAtlas extends Error {
  constructor(public status: number, public code: string, msg: string, public extra: unknown = null) { super(msg); }
}

async function atlas(action: string, data: Record<string, unknown>, tentativa = 1, idempotencia: string | null = null): Promise<any> {
  const chave = Deno.env.get('ATLAS_API_KEY');
  if (!chave) throw new ErroAtlas(500, 'sem_chave', 'A chave da API do Atlas ainda não foi configurada (segredo ATLAS_API_KEY).');
  const r = await fetch(ATLAS_URL, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'x-api-key': chave, 'X-Api-Version': 'v1',
               ...(idempotencia ? { 'Idempotency-Key': idempotencia } : {}) },
    body: JSON.stringify({ action, data }),
  });
  const txt = await r.text();
  let j: any = null; try { j = JSON.parse(txt); } catch { /* resposta não JSON */ }
  if ((r.status === 429 || r.status === 503) && tentativa <= 4) {
    const espera = Math.min(Number(r.headers.get('Retry-After') ?? '5'), 30) * 1000;
    await new Promise(res => setTimeout(res, espera));
    return atlas(action, data, tentativa + 1, idempotencia);
  }
  if (!r.ok || !j || j.success === false) {
    throw new ErroAtlas(r.status, j?.code ?? 'erro_atlas', j?.error ?? `Atlas respondeu ${r.status}`, j);
  }
  return j;
}

async function todasAsPaginas(filtros: Record<string, unknown>) {
  const tarefas: any[] = [];
  let cursor: string | null = null; let paginas = 0;
  do {
    const j = await atlas('list_tasks', { ...filtros, limit: 100, includeIntimacaoNumber: true, ...(cursor ? { cursor } : {}) });
    tarefas.push(...(j.tasks ?? []));
    cursor = j.hasMore ? j.nextCursor : null;
    if (++paginas > 300) throw new ErroAtlas(500, 'paginas_demais', 'Mais de 30.000 tarefas: sincronização interrompida por segurança.');
  } while (cursor);
  return tarefas;
}

// token = "Bearer <jwt do usuário>" ou, na rotina agendada, "Bearer <chave de serviço>"
async function rpc(token: string, nome: string, args: Record<string, unknown>) {
  const servico = SB_SERVICO !== '' && token === `Bearer ${SB_SERVICO}`;
  const r = await fetch(`${SB_URL}/rest/v1/rpc/${nome}`, {
    method: 'POST',
    headers: { apikey: servico ? SB_SERVICO : SB_KEY, Authorization: token, 'Content-Type': 'application/json' },
    body: JSON.stringify(args),
  });
  const txt = await r.text();
  if (!r.ok) {
    let m = txt; try { m = JSON.parse(txt).message ?? txt; } catch { /* texto */ }
    throw new ErroAtlas(r.status, 'erro_banco', m);
  }
  return txt ? JSON.parse(txt) : null;
}

async function sha256(texto: string) {
  const b = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(texto));
  return [...new Uint8Array(b)].map(x => x.toString(16).padStart(2, '0')).join('');
}

async function sincronizar(token: string) {
  const inicio = new Date();
  const dias = Number((await rpc(token, 'atlas_parametro', { p_chave: 'atlas_concluidas_dias' })) ?? 90) || 90;
  const desde = new Date(inicio.getTime() - dias * 86400000).toISOString();
  const abertas = await todasAsPaginas({ status: ['todo', 'doing'] });
  const concluidas = await todasAsPaginas({ status: ['done'], updatedSince: desde });
  const tarefas = semRepetir([...abertas, ...concluidas]);
  if (tarefas.length === 0) throw new ErroAtlas(422, 'sem_tarefas', 'O Atlas não devolveu nenhuma tarefa: nada foi gravado.');

  const nomes = await rpc(token, 'atlas_mapear_usuarios', { p_usuarios: usuariosDasTarefas(tarefas) });
  const linhas = tarefas.map(t => tarefaParaLinha(t, nomes));
  const carimbo = inicio.toISOString();
  let lote: number | null = null; const resultados: any[] = [];
  for (const [i, bloco] of emBlocos(linhas, 1000).entries()) {
    const nome = `Atlas — sincronização ${carimbo} (parte ${i + 1})`;
    const r = await rpc(token, 'importar_arquivo', {
      p_nome_arquivo: nome, p_hash_arquivo: await sha256(carimbo + '|' + i + '|' + JSON.stringify(bloco)),
      p_linhas: bloco, p_lote_id: lote, p_data_exportacao: carimbo, p_confirmar_lote_novo_so_concluidas: false,
    });
    if (r?.status !== 'concluida') throw new ErroAtlas(500, 'importacao_falhou', `Parte ${i + 1}: ${r?.mensagem ?? r?.status}`, r);
    lote = r.lote_id; resultados.push(r);
  }
  // 0058: tarefa "em andamento" no Atlas conta como início da tratativa (controladoria, 17/11/2026)
  const andamento = await rpc(token, 'atlas_registrar_em_andamento', { p_lote: lote });
  // 0061: etapas de workflow concluídas no Atlas (rede de segurança do ciclo de 10 minutos)
  let wf: any = null;
  try { wf = await rpc(token, 'wf_registrar_atlas', { p_itens: concluidas.map(t => ({ id: t.id, status: t.status })) }); } catch { /* sem 0061 */ }
  return {
    workflows_concluidas: wf?.concluidas ?? 0,
    inicios_por_andamento: andamento?.registrados ?? 0,
    lote_id: lote, tarefas: tarefas.length, abertas: abertas.length, concluidas_recentes: concluidas.length,
    novas: resultados.reduce((s, r) => s + (r.tarefas_novas ?? 0), 0),
    ja_conhecidas: resultados.reduce((s, r) => s + (r.tarefas_ja_conhecidas ?? 0), 0),
    rejeitadas: resultados.reduce((s, r) => s + (r.rejeitadas ?? 0), 0),
    importacoes: resultados.map(r => r.importacao_id), segundos: Math.round((Date.now() - inicio.getTime()) / 1000),
  };
}

async function sincronizarIntimacoes(token: string) {
  const inicio = Date.now(); let cursor: string | null = null; let paginas = 0; let total = 0; let lote: any[] = [];
  const gravar = async () => { if (lote.length) { await rpc(token, 'atlas_registrar_intimacoes', { p_itens: lote }); total += lote.length; lote = []; } };
  do {
    const j = await atlas('list_deadlines', { limit: 100, ...(cursor ? { cursor } : {}) });
    lote.push(...(j.deadlines ?? []));
    if (lote.length >= 500) await gravar();
    cursor = j.hasMore ? j.nextCursor : null;
    if (++paginas > 500) throw new ErroAtlas(500, 'paginas_demais', 'Mais de 50.000 intimações: sincronização interrompida por segurança.');
  } while (cursor);
  await gravar();
  return { intimacoes: total, segundos: Math.round((Date.now() - inicio) / 1000) };
}

async function produtividade(token: string) {
  const hoje = new Date(new Date().toLocaleString('en-US', { timeZone: 'America/Sao_Paulo' }));
  const iso = (d: Date) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
  const de = iso(new Date(hoje.getFullYear(), hoje.getMonth(), 1)); const ate = iso(hoje);
  const j = await atlas('get_productivity', { from: de, to: ate });
  const n = await rpc(token, 'atlas_registrar_produtividade', { p_de: de, p_ate: ate, p_membros: j.productivity?.members ?? [] });
  return { de, ate, membros: n };
}

// executa as operações de uma solicitação aprovada (0040); comentário é opcional (a chave pode não ter autor)
async function executarSolicitacao(token: string, id: number) {
  const plano = await rpc(token, 'solicitacao_para_execucao', { p_id: id });
  const feitas: any[] = [];
  try {
    for (const op of plano.operacoes) {
      try {
        const j = await atlas(op.op, op.data, 1, op.idempotencia ?? null);
        feitas.push({ op: op.op, ok: true, taskId: j.taskId ?? op.data.taskId ?? null, appUrl: j.appUrl ?? null });
      } catch (e) {
        if (!op.opcional) throw e;
        feitas.push({ op: op.op, ok: false, opcional: true, erro: (e as Error).message, code: (e as ErroAtlas).code });
      }
    }
  } catch (e) {
    const err = e as ErroAtlas;
    await rpc(token, 'solicitacao_resultado', { p_id: id, p_ok: false, p_resultado: { erro: err.message, code: err.code, feitas } });
    throw err;
  }
  return rpc(token, 'solicitacao_resultado', { p_id: id, p_ok: true, p_resultado: { feitas } });
}

// grava o bloco padrão na descrição (preserva o texto original); limite por chamada por causa do limite da API
async function padronizarDescricoes(token: string, limite: number) {
  const lista = await rpc(token, 'descricoes_para_padronizar', { p_limite: limite });
  const r = { gravadas: 0, puladas: 0, erros: 0, pendentes_restantes: 0 };
  for (const t of lista) {
    if (t.truncada) {
      await rpc(token, 'descricao_padronizada_registrar', { p_tarefa: t.tarefa_id, p_hash: t.hash_bloco, p_resultado: 'pulada_descricao_longa',
        p_detalhe: 'Descrição com mais de 500 caracteres: o Atlas não devolve o texto inteiro e ele seria perdido. Completar à mão.' });
      r.puladas++; continue;
    }
    const nova = comBloco(t.descricao_original ?? '', t.bloco);
    if (nova.length > 10000) {
      await rpc(token, 'descricao_padronizada_registrar', { p_tarefa: t.tarefa_id, p_hash: t.hash_bloco, p_resultado: 'pulada_descricao_longa',
        p_detalhe: 'Descrição ficaria com mais de 10.000 caracteres (limite do Atlas).' });
      r.puladas++; continue;
    }
    try {
      await atlas('edit_task', { taskId: t.atlas_id, description: nova });
      await rpc(token, 'descricao_padronizada_registrar', { p_tarefa: t.tarefa_id, p_hash: t.hash_bloco, p_resultado: 'gravada' });
      r.gravadas++;
    } catch (e) {
      await rpc(token, 'descricao_padronizada_registrar', { p_tarefa: t.tarefa_id, p_hash: t.hash_bloco, p_resultado: 'erro', p_detalhe: (e as Error).message });
      r.erros++;
      if ((e as ErroAtlas).code === 'permission_denied' || (e as ErroAtlas).status === 403) break;
    }
  }
  return r;
}

// 0061: ciclo dos workflows
const CODIGOS_PARAR = new Set(['permission_denied', 'invalid_api_key', 'missing_api_key', 'read_only_key', 'api_not_in_plan', 'tenant_inactive', 'sem_chave']);
async function cicloWorkflows(token: string, origem: string) {
  const inicio = new Date();
  const r: Record<string, unknown> = { lidas: 0, concluidas: 0, criadas: 0, erros: 0, ligado: false };
  try {
    const acomp = await rpc(token, 'wf_acompanhar', {});
    if (acomp?.abertas > 0 && acomp?.desde) {
      const feitas = await todasAsPaginas({ status: ['done'], updatedSince: new Date(acomp.desde).toISOString() });
      r.lidas = feitas.length;
      const x = await rpc(token, 'wf_registrar_atlas', { p_itens: feitas.map(t => ({ id: t.id, status: t.status })) });
      r.concluidas = x?.concluidas ?? 0;
    }
    r.leitura_ok = true;
  } catch (e) { r.erro_leitura = (e as Error).message; }
  // até 3 rodadas de 20; depois de um erro não há nova rodada (a etapa que falhou volta no próximo ciclo,
  // em vez de gastar tentativas seguidas com o mesmo erro)
  let parar = false;
  for (let rodada = 0; rodada < 3 && !parar; rodada++) {
    const plano = await rpc(token, 'wf_para_criar', { p_limite: 20 });
    r.ligado = !!plano?.ligado;
    if (!plano?.ligado || !plano.tarefas?.length) break;
    if (plano.tarefas.length < 20) parar = true;
    for (const t of plano.tarefas) {
      try {
        const j = await atlas('create_task', t.payload, 1, t.idempotencia);
        await rpc(token, 'wf_confirmar_criacao', { p_tarefa: t.id, p_tentativa: t.tentativa, p_resposta: j });
        (r.criadas as number)++;
      } catch (e) {
        const err = e as ErroAtlas;
        (r.erros as number)++; r.ultimo_erro = err.message; parar = true;
        try { await rpc(token, 'wf_falha_criacao', { p_tarefa: t.id, p_erro: err.message, p_code: err.code ?? null }); } catch { /* fica em "criando" e o banco passa a "verificar" depois */ }
        if (CODIGOS_PARAR.has(err.code) || err.status === 401 || err.status === 403) { parar = true; break; }
      }
    }
  }
  await rpc(token, 'wf_registrar_ciclo', { p_inicio: inicio.toISOString(), p_origem: origem, p_resultado: r });
  return { ...r, segundos: Math.round((Date.now() - inicio.getTime()) / 1000) };
}

async function fimExpediente(token: string) {
  const etapas: Record<string, unknown> = {};
  const passo = async (nome: string, fn: () => Promise<unknown>) => {
    try { etapas[nome] = { ok: true, ...(await fn() as object) }; }
    catch (e) { etapas[nome] = { ok: false, erro: (e as Error).message, code: (e as ErroAtlas).code ?? null }; }
  };
  await passo('tarefas', () => sincronizar(token));
  await passo('intimacoes', () => sincronizarIntimacoes(token));
  await passo('produtividade', () => produtividade(token));
  await passo('double_check', async () => ({ resumo: await rpc(token, 'double_check_atlas_executar', { p_dia: null, p_origem: 'automatico' }) }));
  return etapas;
}

function iguais(a: string, b: string) {
  if (a.length !== b.length || a.length === 0) return false;
  let d = 0; for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

Deno.serve(async req => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return resp(405, { erro: 'Use POST' });
  let token = req.headers.get('Authorization') ?? '';
  if (!token.startsWith('Bearer ')) return resp(401, { erro: 'Faça login no painel.' });
  let corpo: any = {}; try { corpo = await req.json(); } catch { return resp(400, { erro: 'JSON inválido' }); }
  // rotina agendada: segredo próprio + chave de serviço (só as ações fim_expediente e workflows)
  // trim: espaço ou quebra de linha colados junto com o valor não devem impedir a rotina
  const segredo = (Deno.env.get('CRON_SECRET') ?? '').trim();
  const cron = (req.headers.get('x-cron-secret') ?? '').trim();
  if (cron !== '') {
    // o motivo ajuda a configurar sem nunca devolver o valor do segredo
    const motivo = !segredo ? 'segredo CRON_SECRET não configurado na função'
      : !SB_SERVICO ? 'chave de serviço indisponível na função'
      : !['fim_expediente', 'workflows'].includes(corpo.acao) ? 'ação não permitida para o agendamento'
      : !iguais(cron, segredo) ? 'segredo diferente do guardado no Vault' : '';
    if (motivo) return resp(401, { erro: 'Agendamento não autorizado.', motivo });
    token = `Bearer ${SB_SERVICO}`;
  }
  try {
    // o banco confere quem chama (controladoria; líder só executa as próprias solicitações) antes de qualquer chamada ao Atlas
    await rpc(token, 'atlas_conferir_acesso', { p_acao: String(corpo.acao ?? '') });
    if (corpo.acao === 'testar') {
      const w = await atlas('whoami', {});
      return resp(200, { ok: true, escritorio: w.tenant?.name, plano: w.plan, permissoes: w.permissions,
                         acesso: w.keyScope, chave: w.keyName, limite_por_minuto: w.rateLimitPerMinute });
    }
    if (corpo.acao === 'sincronizar') {
      const r = await sincronizar(token);
      await rpc(token, 'atlas_registrar', { p_operacao: 'sincronizar', p_nivel: 'info', p_detalhe: r });
      return resp(200, { ok: true, ...r });
    }
    if (corpo.acao === 'criar_tarefa') {
      const dados = await rpc(token, 'analise_dados_para_atlas', { p_id: Number(corpo.id) });
      const j = await atlas('create_task', dados.payload, 1, dados.idempotencia);
      const conf = await rpc(token, 'analise_confirmar_atlas', { p_id: Number(corpo.id), p_tentativa: dados.tentativa, p_resposta: j });
      return resp(200, { ok: true, ...conf });
    }
    if (corpo.acao === 'executar_solicitacao') {
      const r = await executarSolicitacao(token, Number(corpo.id));
      return resp(200, { ok: true, solicitacao: r });
    }
    if (corpo.acao === 'padronizar_descricoes') {
      const r = await padronizarDescricoes(token, Math.min(Math.max(Number(corpo.limite) || 40, 1), 100));
      await rpc(token, 'atlas_registrar', { p_operacao: 'padronizar_descricoes', p_nivel: 'info', p_detalhe: r });
      return resp(200, { ok: true, ...r });
    }
    if (corpo.acao === 'sincronizar_intimacoes') {
      const r = await sincronizarIntimacoes(token);
      await rpc(token, 'atlas_registrar', { p_operacao: 'sincronizar_intimacoes', p_nivel: 'info', p_detalhe: r });
      return resp(200, { ok: true, ...r });
    }
    if (corpo.acao === 'workflows') {
      const r = await cicloWorkflows(token, cron !== '' ? 'agendamento' : 'painel');
      if ((r.erros as number) > 0 || r.erro_leitura) await rpc(token, 'atlas_registrar', { p_operacao: 'workflows', p_nivel: 'aviso', p_detalhe: r });
      return resp(200, { ok: true, ...r });
    }
    if (corpo.acao === 'fim_expediente') {
      const r = await fimExpediente(token);
      const falhou = Object.values(r).some((x: any) => !x.ok);
      await rpc(token, 'atlas_registrar', { p_operacao: 'fim_expediente', p_nivel: falhou ? 'aviso' : 'info', p_detalhe: r });
      return resp(200, { ok: !falhou, etapas: r });
    }
    return resp(400, { erro: 'Ação desconhecida' });
  } catch (e) {
    const err = e as ErroAtlas;
    try { await rpc(token, 'atlas_registrar', { p_operacao: String(corpo.acao ?? ''), p_nivel: 'erro',
            p_detalhe: { code: err.code, mensagem: err.message, status: err.status, extra: err.extra } }); } catch { /* sem log */ }
    if (corpo.acao === 'criar_tarefa' && corpo.id) {
      try { await rpc(token, 'analise_falha_atlas', { p_id: Number(corpo.id), p_erro: err.message, p_code: err.code ?? null }); } catch { /* */ }
    }
    return resp(err.status && err.status >= 400 ? err.status : 500, { erro: err.message, code: err.code ?? 'erro' });
  }
});
