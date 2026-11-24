const $ = id => document.getElementById(id);
const msg = m => new Promise(r => chrome.runtime.sendMessage(m, r));

async function atualizar() {
  const e = await msg({ tipo: 'estado' });
  if (!e.configurado) { $('estado').textContent = 'Extensão sem configuração do Supabase (config.js).'; return; }
  $('login').hidden = !!e.email; $('sair').hidden = !e.email;
  $('estado').textContent = e.email
    ? `Conectada como ${e.email}. Eventos aguardando envio: ${e.pendentes}.`
    : 'Não conectada: as tarefas NÃO estão sendo monitoradas.';
  $('analise').hidden = true;
  if (!e.email) return;
  const f = await msg({ tipo: 'analise_fila' });
  if (!f || !f.ok || !f.dados || !f.dados.admin) return;
  const d = f.dados, { oc_criacao_pausada: pausada } = await chrome.storage.local.get('oc_criacao_pausada');
  $('analise').hidden = false; $('pausar').checked = !!pausada;
  $('analise-estado').textContent = `Tarefas de análise: ${d.aprovadas} aprovada(s) aguardando criação, ${d.bloqueadas} bloqueada(s), ${d.verificar} para verificar no ADVBOX.`
    + (pausada ? ' Criação automática PAUSADA.' : ' A criação roda sozinha na aba do ADVBOX aberta e sem uso.');
}
$('pausar').addEventListener('change', async ev => { await chrome.storage.local.set({ oc_criacao_pausada: ev.target.checked }); atualizar(); });
$('criar-agora').addEventListener('click', async () => {
  $('msg').textContent = '';
  const r = await msg({ tipo: 'analise_agora' });
  $('msg').textContent = r && r.ok ? '' : (r && r.erro) || 'Falhou.';
});

$('login').addEventListener('submit', async ev => {
  ev.preventDefault(); $('msg').textContent = '';
  const r = await msg({ tipo: 'login', email: $('email').value, senha: $('senha').value });
  $('senha').value = '';
  if (!r.ok) $('msg').textContent = r.erro;
  atualizar();
});
$('sair').addEventListener('click', async () => { await msg({ tipo: 'logout' }); atualizar(); });
atualizar();
