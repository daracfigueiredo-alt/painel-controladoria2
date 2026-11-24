/* Service worker: sessão no Supabase da controladoria, chamadas RPC e fila
 * de eventos pendentes (quando a rede falha, nada se perde: reenvia depois
 * com o mesmo id_cliente, e o banco ignora repetições). */
importScripts('config.js');
const C = self.OC_CONFIG;

async function getSessao() { return (await chrome.storage.local.get('sessao')).sessao || null; }
async function setSessao(s) { await chrome.storage.local.set({ sessao: s }); }

async function auth(grant, body) {
  const r = await fetch(`${C.SUPABASE_URL}/auth/v1/token?grant_type=${grant}`, {
    method: 'POST', headers: { apikey: C.SUPABASE_ANON_KEY, 'Content-Type': 'application/json' },
    body: JSON.stringify(body)
  });
  const j = await r.json();
  if (!r.ok) throw new Error(j.error_description || j.msg || 'Falha de autenticação');
  // guarda só tokens e e-mail; a senha nunca é armazenada
  const s = { access_token: j.access_token, refresh_token: j.refresh_token,
              expira_em: Date.now() + (j.expires_in - 60) * 1000, email: j.user && j.user.email };
  await setSessao(s);
  return s;
}

async function token() {
  let s = await getSessao();
  if (!s) return null;
  if (Date.now() > s.expira_em) {
    try { s = await auth('refresh_token', { refresh_token: s.refresh_token }); }
    catch (e) { await setSessao(null); return null; }
  }
  return s.access_token;
}

async function rpc(fn, args) {
  const t = await token();
  if (!t) throw new Error('sem_sessao');
  const r = await fetch(`${C.SUPABASE_URL}/rest/v1/rpc/${fn}`, {
    method: 'POST',
    headers: { apikey: C.SUPABASE_ANON_KEY, Authorization: `Bearer ${t}`, 'Content-Type': 'application/json' },
    body: JSON.stringify(args)
  });
  const j = await r.json().catch(() => null);
  if (!r.ok) throw new Error((j && (j.message || j.hint)) || `HTTP ${r.status}`);
  return j;
}

// envia o arquivo ao Storage (bucket privado "pecas", pasta = id da tarefa) e registra com hash (0039)
async function enviarAnexo(m) {
  const t = await token();
  if (!t) throw new Error('sem_sessao');
  const bytes = Uint8Array.from(atob(m.base64), c => c.charCodeAt(0));
  if (bytes.length !== m.tamanho) throw new Error('Arquivo corrompido no envio');
  const hash = [...new Uint8Array(await crypto.subtle.digest('SHA-256', bytes))].map(x => x.toString(16).padStart(2, '0')).join('');
  const nome = String(m.nome).normalize('NFD').replace(/[\u0300-\u036f]/g, '').replace(/[^A-Za-z0-9._-]+/g, '_').slice(-80);
  const caminho = `${m.tarefa_id}/${Date.now()}-${m.tipo_anexo}-${nome}`;
  const r = await fetch(`${C.SUPABASE_URL}/storage/v1/object/pecas/${caminho.split('/').map(encodeURIComponent).join('/')}`, {
    method: 'POST', body: bytes,
    headers: { apikey: C.SUPABASE_ANON_KEY, Authorization: `Bearer ${t}`, 'Content-Type': m.mime || 'application/octet-stream' } });
  if (!r.ok) { const j = await r.json().catch(() => null); throw new Error('Envio do arquivo: ' + ((j && j.message) || r.status)); }
  return rpc('ext_anexo_registrar', { p_advbox_id: m.advbox_id, p_tipo: m.tipo_anexo, p_caminho: caminho, p_nome: m.nome, p_tamanho: m.tamanho, p_sha256: hash });
}

async function enfileirar(ev) {
  const { fila = [] } = await chrome.storage.local.get('fila');
  fila.push(ev); await chrome.storage.local.set({ fila });
}
async function esvaziarFila() {
  const { fila = [] } = await chrome.storage.local.get('fila');
  const resto = [];
  for (const ev of fila) {
    try { await rpc('ext_registrar_evento', ev); } catch (e) { resto.push(ev); }
  }
  await chrome.storage.local.set({ fila: resto });
  return resto.length;
}

chrome.alarms.create('fila', { periodInMinutes: 1 });
chrome.alarms.onAlarm.addListener(a => { if (a.name === 'fila') esvaziarFila(); });

chrome.runtime.onMessage.addListener((msg, _sender, responder) => {
  (async () => {
    try {
      if (msg.tipo === 'login') return responder({ ok: true, sessao: { email: (await auth('password', { email: msg.email, password: msg.senha })).email } });
      if (msg.tipo === 'logout') { await setSessao(null); return responder({ ok: true }); }
      if (msg.tipo === 'estado') {
        const s = await getSessao(); const { fila = [] } = await chrome.storage.local.get('fila');
        return responder({ ok: true, email: s && s.email, pendentes: fila.length, configurado: !/SEU-PROJETO/.test(C.SUPABASE_URL) });
      }
      if (msg.tipo === 'status') return responder({ ok: true, dados: await rpc('ext_status_tarefa', { p_advbox_id: msg.advbox_id, p_snapshot: msg.snapshot }) });
      // 0039: execução da modalidade (checklist e anexos) na janela da tarefa do Atlas
      if (msg.tipo === 'execucao') return responder({ ok: true, dados: await rpc('ext_execucao', { p_advbox_id: msg.advbox_id }) });
      if (msg.tipo === 'execucao_marcar') return responder({ ok: true, dados: await rpc('ext_execucao_marcar', { p_advbox_id: msg.advbox_id, p_item: msg.item, p_marcado: !!msg.marcado }) });
      if (msg.tipo === 'anexo') return responder({ ok: true, dados: await enviarAnexo(msg) });
      // 0037: exceção de D-4 (consulta; marcar/retirar só líder e controladoria — o banco confere)
      if (msg.tipo === 'excecao_d4') return responder({ ok: true, dados: await rpc('ext_excecao_d4', { p_advbox_id: msg.advbox_id,
        p_ativa: typeof msg.ativa === 'boolean' ? msg.ativa : null, p_justificativa: msg.justificativa || null }) });
      if (msg.tipo === 'reedicao') return responder({ ok: true, dados: await rpc('ext_registrar_reedicao', { p_antigo: msg.antigo, p_novo: msg.novo, p_snap_novo: msg.snap_novo || {}, p_snap_antigo: msg.snap_antigo || {} }) });
      if (msg.tipo === 'inicios') return responder({ ok: true, dados: await rpc('ext_inicios_por_ids', { p_ids: (msg.ids || []).slice(0, 200) }) });
      if (msg.tipo === 'intimacoes_conhecidas') return responder({ ok: true, dados: await rpc('ext_intimacoes_conhecidas', { p_posts: msg.posts || [] }) });
      if (msg.tipo === 'varredura') return responder({ ok: true, dados: await rpc('ext_registrar_varredura', { p_varredura: msg.varredura, p_intimacoes: msg.intimacoes || [] }) });
      if (msg.tipo === 'analise_fila') return responder({ ok: true, dados: await rpc('ext_analise_fila', {}) });
      if (msg.tipo === 'analise_iniciar') return responder({ ok: true, dados: await rpc('analise_iniciar_criacao', { p_id: msg.id }) });
      if (msg.tipo === 'analise_bloquear') return responder({ ok: true, dados: await rpc('analise_bloquear_criacao', { p_id: msg.id, p_motivo: msg.motivo, p_detalhe: msg.detalhe || {} }) });
      if (msg.tipo === 'analise_falha') return responder({ ok: true, dados: await rpc('analise_falha_criacao', { p_id: msg.id, p_erro: msg.erro, p_certeza_nao_criada: !!msg.certeza }) });
      if (msg.tipo === 'analise_confirmar') return responder({ ok: true, dados: await rpc('analise_confirmar_criacao', { p_id: msg.id, p_advbox_tarefa_id: msg.advbox_id, p_evidencia: msg.evidencia || {} }) });
      if (msg.tipo === 'analise_agora') {
        const abas = await chrome.tabs.query({ url: 'https://app.advbox.com.br/*', active: true });
        if (!abas.length) return responder({ ok: false, erro: 'Abra o ADVBOX nesta janela (aba ativa) para criar as tarefas.' });
        chrome.tabs.sendMessage(abas[0].id, { tipo: 'analise_agora' });
        return responder({ ok: true });
      }
      if (msg.tipo === 'evento') {
        esvaziarFila();
        try { return responder({ ok: true, dados: await rpc('ext_registrar_evento', msg.evento) }); }
        catch (e) {
          // erro de regra (ex.: perfil) não volta para a fila; falha de rede/sessão volta
          if (/sem_sessao|Failed to fetch|NetworkError|HTTP 5/.test(e.message)) { await enfileirar(msg.evento); return responder({ ok: false, enfileirado: true, erro: e.message }); }
          return responder({ ok: false, erro: e.message });
        }
      }
      responder({ ok: false, erro: 'mensagem desconhecida' });
    } catch (e) { responder({ ok: false, erro: e.message }); }
  })();
  return true; // resposta assíncrona
});
