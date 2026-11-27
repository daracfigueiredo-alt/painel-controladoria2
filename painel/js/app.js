/* Estrutura do painel: autenticação (Supabase Auth), perfil e navegação.
 * Usa somente a chave publicável; toda permissão é decidida no banco (RLS e funções). */
(function () {
  'use strict';
  const { h } = UI;
  const cfg = window.OC_CONFIG || {};
  const $ = id => document.getElementById(id);

  // Áreas do Prompt Mestre §25. "etapa" = onde a área é entregue; só as já entregues abrem.
  // papeis: quem abre a área (sem a lista, todos os perfis). Pedidos da Dra. Mariana (11/11/2026, item 6).
  // grupo: o menu junta as áreas por sistema (pedido da controladoria, 11/11/2026): o que é do Atlas
  // fica junto, o que é do ADVBOX (histórico) fica junto, e o que vale para os dois fica em Acompanhamento.
  const GRUPOS = [
    { id: 'geral',  nome: 'Acompanhamento' },
    { id: 'atlas',  nome: 'Atlas Gestor' },
    { id: 'webjur', nome: 'Publicações e intimações' },
    { id: 'advbox', nome: 'ADVBOX (histórico)' },
    { id: 'admin',  nome: 'Administração' }
  ];
  const AREAS = [
    { id: 'diretoria',     grupo: 'geral',  nome: 'Painel da diretoria',           etapa: 12, papeis: ['admin', 'diretoria'], abrir: c => window.Gestao.diretoria(c, contexto) },
    { id: 'visao-geral',   grupo: 'geral',  nome: 'Visão geral',                   etapa: 4, abrir: c => window.Indicadores.visaoGeral(c, contexto) },
    { id: 'colaboradores', grupo: 'geral',  nome: 'Indicadores por colaborador',   etapa: 4, abrir: c => window.Indicadores.porColaborador(c, contexto) },
    { id: 'prazos',        grupo: 'geral',  nome: 'Prazos em risco',               etapa: 4, abrir: c => window.Riscos.prazos(c, contexto) },
    { id: 'reagendamentos',grupo: 'geral',  nome: 'Reagendamentos',                etapa: 4, abrir: c => window.Riscos.reagendamentos(c, contexto) },
    { id: 'tratativa',     grupo: 'geral',  nome: 'Tratativa',                     etapa: 4, abrir: c => window.Riscos.tratativa(c, contexto) },
    { id: 'audiencias',    grupo: 'geral',  nome: 'Audiências',                    etapa: 16, abrir: c => window.Audiencias.abrir(c, contexto) },
    { id: 'minha-pauta',   grupo: 'atlas',  nome: 'Minha pauta',                   etapa: 12, abrir: c => window.Gestao.minhaPauta(c, contexto) },
    { id: 'workflows',     grupo: 'atlas',  nome: 'Workflows jurídicos',           etapa: 20, abrir: c => window.Workflows.abrir(c, contexto) },
    { id: 'solicitacoes',  grupo: 'atlas',  nome: 'Solicitações e reagendamentos', etapa: 12, papeis: ['admin', 'lider', 'diretoria', 'colaborador'], abrir: c => window.Gestao.solicitacoes(c, contexto) },
    { id: 'atlas',         grupo: 'atlas',  nome: 'Sincronização com o Atlas',     etapa: 11, papeis: ['admin'], abrir: c => window.Importacao.atlas(c, contexto) },
    { id: 'cadastro-atlas', grupo: 'atlas', nome: 'Cadastro de processos no Atlas', etapa: 15, papeis: ['admin', 'diretoria'], abrir: c => window.CadastroAtlas.abrir(c, contexto) },
    { id: 'intimacoes-cnj', grupo: 'webjur', nome: 'Intimações CNJ',               etapa: 14, papeis: ['admin', 'diretoria'], abrir: c => window.Cnj.abrir(c, contexto) },
    { id: 'nao-cadastrados', grupo: 'webjur', nome: 'Processos não cadastrados',   etapa: 22, papeis: ['admin', 'diretoria'], abrir: c => window.NaoCadastrados.abrir(c, contexto) },
    { id: 'publicacoes',   grupo: 'webjur', nome: 'Publicações Webjur',            etapa: 6, papeis: ['admin'], abrir: c => window.Publicacoes.abrir(c, contexto) },
    { id: 'inconsistencias', grupo: 'webjur', nome: 'Double check de intimações',  etapa: 12, papeis: ['admin', 'diretoria'], abrir: c => window.Gestao.inconsistencias(c, contexto) },
    { id: 'analise',       grupo: 'webjur', nome: 'Tarefas de análise pendentes',  etapa: 8, papeis: ['admin'], abrir: c => window.Analise.abrir(c, contexto) },
    { id: 'importacao',    grupo: 'advbox', nome: 'Importação do Excel',           etapa: 3, papeis: ['admin'], abrir: c => window.Importacao.abrir(c, contexto) },
    { id: 'double-check',  grupo: 'advbox', nome: 'Double check ADVBOX',           etapa: 7, papeis: ['admin'], abrir: c => window.DoubleCheck.abrir(c, contexto) },
    { id: 'auditoria',     grupo: 'admin',  nome: 'Histórico de auditoria',        etapa: 9, papeis: ['admin'], abrir: c => window.Auditoria.abrir(c, contexto) },
    { id: 'configuracoes', grupo: 'admin',  nome: 'Configurações administrativas', etapa: 9, papeis: ['admin'], abrir: c => window.Configuracoes.abrir(c, contexto) }
  ];

  const contexto = { sb: null, usuario: null, perfil: null };
  const ROTULO_PAPEL = { admin: 'Controladoria', diretoria: 'Diretoria', lider: 'Líder', colaborador: 'Peticionador' };
  const pode = a => !a.papeis || a.papeis.includes(contexto.perfil.papel);

  if (!cfg.SUPABASE_URL || /SEU-PROJETO/.test(cfg.SUPABASE_URL) || !cfg.SUPABASE_ANON_KEY || /COLE-AQUI/.test(cfg.SUPABASE_ANON_KEY)) {
    $('config-erro').hidden = false;
    return;
  }
  // Sessão só na aba atual: fechar o navegador encerra o acesso.
  const armazenamento = {
    getItem: k => { try { return sessionStorage.getItem(k); } catch (e) { return null; } },
    setItem: (k, v) => { try { sessionStorage.setItem(k, v); } catch (e) { /* sem armazenamento */ } },
    removeItem: k => { try { sessionStorage.removeItem(k); } catch (e) { /* idem */ } }
  };
  contexto.sb = window.supabase.createClient(cfg.SUPABASE_URL, cfg.SUPABASE_ANON_KEY, {
    auth: { persistSession: true, storage: armazenamento, autoRefreshToken: true, detectSessionInUrl: false }
  });

  async function carregarSessao() {
    const { data } = await contexto.sb.auth.getSession();
    if (!data.session) return mostrarLogin();
    contexto.usuario = data.session.user;
    const { data: perfil, error } = await contexto.sb.from('perfis').select('papel, colaborador_id').eq('user_id', contexto.usuario.id).maybeSingle();
    if (error || !perfil) {
      mostrarLogin('Usuário autenticado, mas sem perfil cadastrado na controladoria. Peça ao administrador para vincular a sua conta.');
      await contexto.sb.auth.signOut();
      return;
    }
    contexto.perfil = perfil;
    mostrarApp();
  }

  function mostrarLogin(msg) {
    $('tela-app').hidden = true; $('sessao').hidden = true; $('tela-login').hidden = false;
    $('login-erro').textContent = msg || '';
    $('login-email').focus();
  }

  function mostrarApp() {
    $('tela-login').hidden = true; $('tela-app').hidden = false; $('sessao').hidden = false;
    $('sessao-usuario').textContent = contexto.usuario.email || '';
    $('sessao-papel').textContent = ROTULO_PAPEL[contexto.perfil.papel] || contexto.perfil.papel;
    desenharMenu();
    navegar();
  }

  function desenharMenu() {
    const atual = (location.hash || '').replace('#/', '');
    const menu = $('menu'); menu.textContent = '';
    const item = a => {
      const disponivel = !!a.abrir && pode(a);
      return h('li', {}, h('a', {
        href: '#/' + a.id, class: 'menu-item' + (atual === a.id ? ' ativo' : '') + (disponivel ? '' : ' indisponivel'),
        'aria-current': atual === a.id ? 'page' : null
      }, h('span', { class: 'menu-nome' }, a.nome),
         disponivel ? null : h('span', { class: 'menu-etiqueta' }, !pode(a) ? (a.papeis.length === 1 && a.papeis[0] === 'admin' ? 'admin' : 'restrita') : 'Etapa ' + a.etapa)));
    };
    // grupos com alguma área aberta para o perfil vêm primeiro; os totalmente restritos vão para o fim
    const grupos = GRUPOS.map(g => ({ ...g, areas: AREAS.filter(a => a.grupo === g.id) }))
      .map(g => ({ ...g, algum: g.areas.some(a => a.abrir && pode(a)) }));
    const ordem = [...grupos.filter(g => g.algum), ...grupos.filter(g => !g.algum)];
    menu.append(...ordem.map(g => h('div', { class: 'menu-grupo' + (g.algum ? '' : ' menu-grupo-restrito'), role: 'group', 'aria-labelledby': 'menu-g-' + g.id },
      h('p', { class: 'menu-grupo-titulo', id: 'menu-g-' + g.id }, g.nome),
      h('ul', {}, g.areas.map(item)))));
  }

  function navegar() {
    let id = (location.hash || '').replace('#/', '');
    if (!AREAS.some(a => a.id === id)) {
      id = contexto.perfil.papel === 'diretoria' ? 'diretoria' : contexto.perfil.papel === 'colaborador' ? 'minha-pauta' : 'visao-geral';
      history.replaceState(null, '', '#/' + id);
    }
    desenharMenu();
    const area = AREAS.find(a => a.id === id);
    const c = $('conteudo'); c.textContent = '';
    if (!pode(area)) {
      c.append(h('h1', {}, area.nome), UI.aviso('info', area.papeis.length === 1 && area.papeis[0] === 'admin' ? 'Área restrita ao administrador da controladoria.'
        : 'Área restrita a outro perfil de acesso (' + area.papeis.map(p => ROTULO_PAPEL[p]).join(', ') + ').'));
    } else if (!area.abrir) {
      c.append(h('h1', {}, area.nome), UI.aviso('info',
        `Esta área será entregue na Etapa ${area.etapa} do projeto. Nenhum dado é exibido aqui até lá, para não apresentar indicadores incompletos.`));
    } else {
      area.abrir(c);
      if (window.Relatorios) window.Relatorios.anexar(c, contexto, area);   // relatório gerencial (0056): controladoria e diretoria
    }
    c.focus({ preventScroll: true });
  }

  $('form-login').addEventListener('submit', async ev => {
    ev.preventDefault();
    const btn = $('btn-entrar'); btn.disabled = true; $('login-erro').textContent = '';
    const { error } = await contexto.sb.auth.signInWithPassword({ email: $('login-email').value.trim(), password: $('login-senha').value });
    $('login-senha').value = '';
    btn.disabled = false;
    if (error) { $('login-erro').textContent = 'Não foi possível entrar: e-mail ou senha incorretos.'; return; }
    carregarSessao();
  });
  $('btn-sair').addEventListener('click', async () => {
    contexto.perfil = null; contexto.usuario = null;   // antes de tudo: nenhuma área consulta dados sem sessão
    $('conteudo').textContent = '';
    await contexto.sb.auth.signOut(); history.replaceState(null, '', location.pathname); mostrarLogin();
  });
  window.addEventListener('hashchange', () => { if (contexto.perfil) navegar(); });
  carregarSessao();
})();
