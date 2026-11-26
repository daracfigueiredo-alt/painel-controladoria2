/* Área 11 — Configurações administrativas (Etapa 9). Exclusiva do administrador.
 * Parâmetros (inclusive as regras ainda provisórias do Prompt Mestre, parte XII), usuários e
 * perfis, calendário de dias não úteis e log de integração. Toda alteração passa por uma função
 * do banco que exige motivo e grava antes/depois na auditoria (área 10). */
(function () {
  'use strict';
  const { h, data, dataHora, num, tabela, aviso } = UI;
  let ctx, raiz;
  const fmt = v => v === null || v === undefined ? '—' : typeof v === 'string' ? v : JSON.stringify(v);

  async function abrir(container, contexto) {
    ctx = contexto; raiz = container;
    raiz.append(
      h('h1', {}, 'Configurações administrativas'),
      h('p', { class: 'sutil' }, 'Toda alteração exige motivo e fica no Histórico de auditoria, com o valor anterior, o novo e quem alterou. ',
        'Parâmetros novos só entram por migração do banco.'),
      h('nav', { class: 'sumario', 'aria-label': 'Seções desta página' },
        ...[['cf-backup', 'Backup dos dados'], ['cf-usuarios', 'Usuários e perfis'], ['cf-param', 'Parâmetros'], ['cf-cal', 'Calendário'], ['cf-log', 'Log de integração'],
            ['cf-modalidades', 'Modalidades'], ['cf-capacidade', 'Capacidade diária']].map(([id, rot]) =>
          h('button', { type: 'button', class: 'chip', onclick: () => raiz.querySelector('#' + id).scrollIntoView({ behavior: 'smooth', block: 'start' }) }, rot))),
      h('p', { class: 'grupo-titulo' }, 'Geral'),
      h('section', { class: 'cartao', id: 'cf-backup' }),
      h('section', { class: 'cartao', id: 'cf-usuarios' }), h('section', { class: 'cartao', id: 'cf-param' }),
      h('section', { class: 'cartao', id: 'cf-cal' }), h('section', { class: 'cartao', id: 'cf-log' }),
      h('p', { class: 'grupo-titulo' }, 'Atlas Gestor'),
      h('section', { class: 'cartao', id: 'cf-modalidades' }), h('section', { class: 'cartao', id: 'cf-capacidade' }));
    backup();
    await Promise.all([parametros(), usuarios(), modalidades(), capacidade(), calendario(), logs()]);
  }

  // ---------------------------------------------------------------- backup dos dados (0060, 18/11/2026)
  // O arquivo sai do banco direto para este computador (nada passa por terceiros). Só leitura.
  // Senhas, chaves e segredos não entram: ficam com a controladoria. Restauração: docs/RESTAURAR.md.
  function backup() {
    const el = raiz.querySelector('#cf-backup');
    const msg = h('p', { class: 'sutil', 'aria-live': 'polite' });
    const bt = h('button', { type: 'button', class: 'btn', onclick: baixar }, 'Baixar backup dos dados');
    el.append(h('h2', {}, 'Backup dos dados'),
      h('p', { class: 'sutil' }, 'Baixa um arquivo com todas as tabelas do sistema (tarefas, eventos, importações, intimações, audiências, parâmetros, perfis, auditoria…). ',
        'Guarde-o junto com o backup do código. Senhas, chaves e segredos não entram no arquivo. A restauração está em docs/RESTAURAR.md.'),
      h('div', { class: 'acoes' }, bt), msg);
    async function baixar() {
      bt.disabled = true; msg.className = 'sutil';
      try {
        const r1 = await ctx.sb.rpc('backup_tabelas'); if (r1.error) throw r1.error;
        const meta = r1.data, saida = { ...meta, tabelas: {} };
        const total = meta.tabelas.reduce((s, t) => s + Number(t.linhas), 0); let feitas = 0;
        for (const t of meta.tabelas) {
          const linhas = [];
          for (let pg = 0; linhas.length < t.linhas; pg++) {
            const r = await ctx.sb.rpc('backup_tabela', { p_tabela: t.tabela, p_pagina: pg, p_tamanho: 500 });
            if (r.error) throw r.error;
            if (!r.data.length) break;
            linhas.push(...r.data); feitas += r.data.length;
            msg.textContent = `Lendo ${t.tabela}… ${num(feitas)} de ${num(total)} linhas`;
          }
          if (linhas.length !== Number(t.linhas)) throw new Error(`${t.tabela}: ${linhas.length} linhas lidas, ${t.linhas} esperadas. Tente de novo.`);
          saida.tabelas[t.tabela] = { colunas: t.colunas, chave: t.chave, linhas };
        }
        const ru = await ctx.sb.rpc('backup_usuarios'); if (ru.error) throw ru.error;
        saida.usuarios = ru.data;
        const texto = JSON.stringify(saida);
        const hash = [...new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(texto)))].map(b => b.toString(16).padStart(2, '0')).join('');
        const dia = new Date().toLocaleString('sv-SE', { timeZone: 'America/Sao_Paulo' }).slice(0, 16).replace(' ', '_').replace(':', 'h');
        const nome = `backup_dados_controladoria_${dia}.json`;
        const url = URL.createObjectURL(new Blob([texto], { type: 'application/json' }));
        const a = h('a', { href: url, download: nome }); document.body.append(a); a.click(); a.remove();
        setTimeout(() => URL.revokeObjectURL(url), 60000);
        msg.textContent = `Backup baixado: ${nome} — ${meta.tabelas.length} tabelas, ${num(total)} linhas, ${(texto.length / 1048576).toLocaleString('pt-BR', { maximumFractionDigits: 1 })} MB. ` +
          `Conferência (SHA-256): ${hash}`;
        msg.dataset.hash = hash; msg.dataset.arquivo = nome;
      } catch (e) {
        msg.className = 'erro'; msg.textContent = 'Backup não concluído: ' + (e.message || e);
      } finally { bt.disabled = false; }
    }
  }

  // ---------------------------------------------------------------- parâmetros
  async function parametros() {
    const el = raiz.querySelector('#cf-param');
    const { data: d, error } = await ctx.sb.from('parametros').select('chave, valor, confirmado, descricao, atualizado_em').order('chave');
    el.textContent = '';
    el.append(h('h2', {}, 'Parâmetros e regras'));
    if (error) { el.append(aviso('erro', error.message)); return; }
    const prov = d.filter(p => !p.confirmado);
    let filtro = null;
    const corpo = h('div');
    const chips = h('div', { class: 'filtros', role: 'group', 'aria-label': 'Filtrar parâmetros por sistema' });
    const desenhar = () => {
      chips.textContent = '';
      chips.append(...[[null, 'Todos'], ...SISTEMAS.map(x => [x, x])].map(([v, rot]) =>
        h('button', { type: 'button', class: 'chip' + (filtro === v ? ' ativo' : ''), 'aria-pressed': String(filtro === v),
          onclick: () => { filtro = v; desenhar(); } }, rot + ' (' + num(d.filter(p => !v || sistemaParam(p.chave) === v).length) + ')')));
      const vis = d.filter(p => !filtro || sistemaParam(p.chave) === filtro);
      const pv = vis.filter(p => !p.confirmado), cf = vis.filter(p => p.confirmado);
      corpo.textContent = '';
      corpo.append(pv.length ? tabelaParam(pv, 'linha-alerta') : h('p', { class: 'sutil' }, 'Nenhum parâmetro provisório' + (filtro ? ' neste sistema.' : '.')),
        h('details', { id: 'cf-param-confirmados' }, h('summary', {}, `Ver os ${num(cf.length)} parâmetros confirmados`), tabelaParam(cf, null)));
    };
    el.append(h('p', { class: 'sutil', id: 'cf-param-resumo' }, `${num(d.length)} parâmetros; ${num(prov.length)} ainda provisório(s), aguardando confirmação da controladoria (aparecem primeiro).`),
      chips, corpo);
    desenhar();
  }
  // sistema a que cada parâmetro se refere (só para organizar a tela; não muda regra nenhuma)
  const SISTEMAS = ['Geral', 'Atlas', 'ADVBOX', 'Webjur', 'CNJ'];
  function sistemaParam(k) {
    if (/^webjur_/.test(k)) return 'Webjur';
    if (/^cnj_/.test(k)) return 'CNJ';
    if (/^(atlas_|capacidade_|planejamento_|fim_expediente_|anexo_)/.test(k) || k === 'trava_execucao_modo' || k === 'tarefa_sem_modalidade_pontos'
        || k === 'tarefa_analise_destino' || k === 'tarefa_analise_responsavel_email') return 'Atlas';
    if (/^(advbox_|double_check_)/.test(k) || /_advbox_/.test(k) || ['importacao_vinculo_sem_remetente', 'periodicidade_importacao_horas', 'tarefa_analise_tipo',
        'tarefa_analise_muda_etapa', 'tarefa_analise_criacao', 'tarefa_analise_sem_processo'].includes(k)) return 'ADVBOX';
    return 'Geral';
  }
  function tabelaParam(lista, classe) {
    return tabela([
        { titulo: 'Situação', valor: p => p.confirmado ? 'Confirmado' : h('b', { class: 'texto-alerta' }, 'Provisório') },
        { titulo: 'Sistema', valor: p => h('span', { class: 'etiqueta-sistema sis-' + sistemaParam(p.chave).toLowerCase() }, sistemaParam(p.chave)) },
        { titulo: 'Parâmetro', valor: p => h('code', {}, p.chave) },
        { titulo: 'Valor', valor: p => h('code', {}, fmt(p.valor)) },
        { titulo: 'Descrição', larga: true, valor: p => p.descricao || '—' },
        { titulo: 'Atualizado', valor: p => dataHora(p.atualizado_em) },
        { titulo: '', valor: p => h('button', { type: 'button', class: 'btn btn-sec btn-peq cf-editar', onclick: () => editarParametro(p) }, 'Alterar') }
      ], lista, { vazio: 'Nenhum.', classeLinha: () => classe });
  }

  let dlg = null;
  function dialogo(titulo, ...corpo) {
    if (!dlg) { dlg = h('dialog', { class: 'detalhe', 'aria-labelledby': 'cf-dlg-titulo' }); document.body.append(dlg); }
    dlg.textContent = '';
    dlg.append(h('div', { class: 'detalhe-topo' }, h('h2', { id: 'cf-dlg-titulo' }, titulo), h('button', { type: 'button', class: 'btn btn-sec btn-peq', onclick: () => dlg.close() }, 'Fechar')),
      h('div', { class: 'detalhe-corpo' }, ...corpo));
    dlg.showModal();
  }

  function editarParametro(p) {
    const tipo = p.valor === null ? 'null' : Array.isArray(p.valor) ? 'array' : typeof p.valor;
    const val = h('textarea', { id: 'cf-valor', rows: 3, class: 'pub-texto', 'aria-label': 'Novo valor' }, tipo === 'string' ? p.valor : JSON.stringify(p.valor));
    const conf = h('input', { type: 'checkbox', id: 'cf-confirmado', checked: !!p.confirmado, class: 'caixa' });
    const motivo = h('textarea', { id: 'cf-motivo', rows: 2, class: 'pub-texto', placeholder: 'Motivo da alteração (obrigatório, mínimo 10 caracteres). Ex.: decisão da coordenação em 10/11/2026.', 'aria-label': 'Motivo' });
    const saida = h('div');
    dialogo(`Alterar ${p.chave}`,
      h('p', { class: 'sutil' }, p.descricao || ''),
      h('p', {}, h('b', {}, 'Valor atual: '), h('code', {}, fmt(p.valor))),
      h('label', { class: 'filtro' }, h('span', {}, tipo === 'string' ? 'Novo valor (texto)' : tipo === 'null' ? 'Novo valor (JSON: texto entre aspas, número, lista…)' : `Novo valor (${tipo === 'number' ? 'número' : 'JSON'})`), val),
      h('p', {}, h('label', {}, conf, ' Regra confirmada pela controladoria')),
      motivo,
      h('div', { class: 'acoes' }, h('button', { type: 'button', class: 'btn', id: 'cf-salvar', onclick: async () => {
        saida.textContent = '';
        let v;
        try { v = tipo === 'string' ? val.value : JSON.parse(val.value); } catch (e) { saida.append(aviso('erro', 'Valor inválido: use o formato JSON (texto entre aspas, número sem aspas, lista entre colchetes).')); return; }
        const { error } = await ctx.sb.rpc('admin_definir_parametro', { p_chave: p.chave, p_valor: v, p_confirmado: conf.checked, p_motivo: motivo.value });
        if (error) { saida.append(aviso('erro', error.message)); return; }
        dlg.close(); await parametros();
      } }, 'Salvar')), saida);
  }

  // ---------------------------------------------------------------- usuários e perfis
  async function usuarios() {
    const el = raiz.querySelector('#cf-usuarios');
    const [{ data: us, error }, { data: cols }, { data: lid }] = await Promise.all([ctx.sb.rpc('admin_listar_usuarios'), ctx.sb.from('colaboradores').select('id, nome_advbox').order('nome_advbox'),
      ctx.sb.from('parametros').select('valor').eq('chave', 'atlas_lideres').maybeSingle()]);
    const nomesLideres = Array.isArray(lid && lid.valor) ? lid.valor.join(', ') : '';
    el.textContent = '';
    el.append(h('h2', {}, 'Usuários e perfis'),
      h('p', { class: 'sutil' }, 'As contas são criadas no Supabase (Authentication → Users → Add user → Create new user, com "Auto Confirm User"), com o cadastro público desligado. A senha é definida pela controladoria e pode ser trocada aqui em "Definir senha". Aqui se define o papel: ',
        'controladoria (administradora) vê e altera tudo; diretoria vê tudo, sem alterar; peticionador (colaborador) vê só as próprias tarefas e precisa estar ligado ao seu nome; ',
        'líder' + (nomesLideres ? ' (' + nomesLideres + ')' : '') + ' vê as tarefas das equipes que acompanha, solicita tarefas e reagendamentos ',
        'e altera data, responsável e prazo fatal sem bloqueio da extensão, com tudo registrado.'));
    if (error) { el.append(aviso('erro', error.message)); return; }
    const saida = h('div', { id: 'cf-usuarios-saida' });
    el.append(saida, tabela([
      { titulo: 'E-mail', valor: u => u.email },
      { titulo: 'Último acesso', valor: u => dataHora(u.ultimo_acesso) },
      { titulo: 'Papel atual', valor: u => u.papel === 'admin' ? 'Administradora' : u.papel === 'colaborador' ? `Peticionador — ${u.colaborador || '?'}`
          : u.papel === 'lider' ? h('span', {}, `Líder — ${u.colaborador || '?'}`, h('br'), h('span', { class: 'sutil' }, 'Equipes: ' + ((u.equipes_lideradas || []).map(e => e.nome).join(', ') || 'nenhuma')))
          : u.papel === 'diretoria' ? 'Diretoria' : h('span', { class: 'sutil' }, 'Sem acesso') },
      { titulo: 'Novo papel', valor: u => {
          const papel = h('select', { 'aria-label': 'Papel de ' + u.email, class: 'cf-papel' }, h('option', { value: '' }, 'Sem acesso'), h('option', { value: 'colaborador' }, 'Peticionador (colaborador)'), h('option', { value: 'lider' }, 'Líder (equipes, solicitações, altera sem trava)'), h('option', { value: 'diretoria' }, 'Diretoria (vê tudo, não altera)'), h('option', { value: 'admin' }, 'Administradora (controladoria)'));
          papel.value = u.papel || '';
          const col = h('select', { 'aria-label': 'Colaborador do ADVBOX de ' + u.email, class: 'cf-colab' }, h('option', { value: '' }, '— colaborador (ADVBOX/Atlas) —'), (cols || []).map(c => h('option', { value: c.id }, c.nome_advbox)));
          col.value = u.colaborador_id || '';
          const motivo = h('input', { type: 'text', placeholder: 'Motivo', 'aria-label': 'Motivo da alteração de ' + u.email, class: 'cf-motivo-perfil' });
          return h('div', { class: 'acoes' }, papel, col, motivo, h('button', { type: 'button', class: 'btn btn-sec btn-peq', onclick: async () => {
            saida.textContent = '';
            const { error: e } = await ctx.sb.rpc('admin_definir_perfil', { p_user_id: u.user_id, p_papel: papel.value || null, p_colaborador_id: col.value ? Number(col.value) : null, p_motivo: motivo.value });
            if (e) { saida.append(aviso('erro', `${u.email}: ${e.message}`)); return; }
            await usuarios();
            raiz.querySelector('#cf-usuarios-saida').append(aviso('info', `${u.email}: papel atualizado.`));
          } }, 'Salvar'), u.papel === 'lider' ? equipesLider(u, saida) : null);
        } },
      { titulo: 'Senha', valor: u => definirSenha(u, saida) }
    ], us || []));
  }
  // senha definida pela controladoria (0062, Edge Function admin-senha); a senha não é guardada no painel nem no banco
  function definirSenha(u, saida) {
    const caixa = h('details', { class: 'cf-senha' }, h('summary', {}, 'Definir senha'));
    const senha = h('input', { type: 'password', autocomplete: 'new-password', placeholder: 'Nova senha (mín. 8)', 'aria-label': 'Nova senha de ' + u.email });
    const conf = h('input', { type: 'password', autocomplete: 'new-password', placeholder: 'Repita a senha', 'aria-label': 'Repita a senha de ' + u.email });
    const motivo = h('input', { type: 'text', placeholder: 'Motivo', 'aria-label': 'Motivo (senha de ' + u.email + ')' });
    const msg = h('p', { class: 'erro', role: 'alert' });
    const botao = h('button', { type: 'button', class: 'btn btn-sec btn-peq', onclick: async () => {
      msg.textContent = ''; saida.textContent = '';
      if (senha.value.length < 8) { msg.textContent = 'A senha precisa ter pelo menos 8 caracteres.'; return; }
      if (senha.value !== conf.value) { msg.textContent = 'As duas senhas não são iguais.'; return; }
      if (motivo.value.trim().length < 10) { msg.textContent = 'Informe o motivo (mínimo 10 caracteres).'; return; }
      botao.disabled = true;
      const { data: d, error: e } = await ctx.sb.functions.invoke('admin-senha', { body: { user_id: u.user_id, senha: senha.value, motivo: motivo.value } });
      botao.disabled = false;
      let erro = e ? e.message : (d && d.erro) || null;
      if (e && e.context && typeof e.context.json === 'function') { try { const j = await e.context.json(); if (j && j.erro) erro = j.erro; } catch (_) { /* sem corpo */ } }
      if (erro) { msg.textContent = erro; return; }
      senha.value = ''; conf.value = ''; motivo.value = ''; caixa.open = false;
      saida.append(aviso('info', `${u.email}: senha definida. Passe a senha à pessoa por um canal seguro (de preferência pessoalmente).`));
    } }, 'Salvar senha');
    caixa.append(senha, conf, motivo, botao, msg);
    return caixa;
  }
  // equipes que o líder acompanha (0038)
  function equipesLider(u, saida) {
    const caixa = h('details', {}, h('summary', {}, 'Equipes que acompanha'));
    caixa.addEventListener('toggle', async () => {
      if (!caixa.open || caixa.childElementCount > 1) return;
      const { data: eqs } = await ctx.sb.from('equipes').select('id, nome').order('nome');
      const marcadas = new Set((u.equipes_lideradas || []).map(e => e.id));
      const boxes = (eqs || []).map(e => h('label', { class: 'opcao' }, h('input', { type: 'checkbox', value: e.id, checked: marcadas.has(e.id) }), ' ', e.nome));
      const motivo = h('input', { type: 'text', placeholder: 'Motivo', 'aria-label': 'Motivo (equipes de ' + u.email + ')' });
      caixa.append(...boxes, motivo, h('button', { type: 'button', class: 'btn btn-sec btn-peq', onclick: async () => {
        saida.textContent = '';
        const ids = boxes.map(b => b.querySelector('input')).filter(i => i.checked).map(i => Number(i.value));
        const { error: e } = await ctx.sb.rpc('admin_definir_lider_equipes', { p_user_id: u.user_id, p_equipes: ids, p_motivo: motivo.value });
        if (e) { saida.append(aviso('erro', `${u.email}: ${e.message}`)); return; }
        await usuarios(); raiz.querySelector('#cf-usuarios-saida').append(aviso('info', `${u.email}: equipes atualizadas.`));
      } }, 'Salvar equipes'));
      if (!(eqs || []).length) caixa.append(h('p', { class: 'sutil' }, 'Nenhuma equipe cadastrada (as equipes são definidas nos colaboradores).'));
    });
    return caixa;
  }

  // ---------------------------------------------------------------- modalidades padronizadas (0039)
  async function modalidades() {
    const el = raiz.querySelector('#cf-modalidades');
    const { data: ms, error } = await ctx.sb.from('modalidades').select('*').order('nome');
    el.textContent = '';
    el.append(h('h2', {}, 'Modalidades de tarefas (checklist, treinamento e NotebookLM)'),
      h('p', { class: 'sutil' }, 'Cada modalidade tem checklist obrigatório, links do material de treinamento e da conferência técnica no NotebookLM, orientações, ',
        'pontos de complexidade (planejamento da pauta) e a exigência de anexar a peça e o parecer de autoavaliação. A modalidade é reconhecida pelo título da tarefa ',
        '(trechos, sem acento). Só modalidade ATIVA trava a conclusão no Atlas. As do modelo inicial nascem inativas para revisão.'));
    if (error) { el.append(aviso('erro', error.message)); return; }
    const saida = h('div', { id: 'cf-mod-saida' }); const form = h('div');
    el.append(saida, tabela([
      { titulo: 'Modalidade', valor: m => h('b', {}, m.nome) },
      { titulo: 'Situação', valor: m => h('span', { class: 'tag ' + (m.ativa ? 'tag-ok' : 'tag-neutra') }, m.ativa ? 'Ativa' : 'Inativa') },
      { titulo: 'Reconhece no título', valor: m => (m.padroes || []).join(', ') || '—', larga: true },
      { titulo: 'Pontos', num: true, valor: m => String(m.pontos) },
      { titulo: 'Checklist', num: true, valor: m => String((m.checklist || []).length) },
      { titulo: 'Links', valor: m => [m.link_treinamento ? 'treinamento' : null, m.link_notebooklm ? 'NotebookLM' : null].filter(Boolean).join(', ') || h('span', { class: 'texto-alerta' }, 'faltam') },
      { titulo: '', valor: m => h('button', { type: 'button', class: 'btn btn-sec btn-peq', onclick: () => editar(m) }, 'Editar') }
    ], ms || [], { compacta: true }), h('div', { class: 'acoes' }, h('button', { type: 'button', class: 'btn btn-sec', onclick: () => editar(null) }, 'Nova modalidade')), form);
    function editar(m) {
      m = m || { nome: '', padroes: [], pontos: 2, checklist: [], exige_peca: true, exige_parecer: true, ativa: false };
      form.textContent = '';
      const c = {
        nome: h('input', { type: 'text', value: m.nome, 'aria-label': 'Nome' }),
        padroes: h('input', { type: 'text', value: (m.padroes || []).join(', '), 'aria-label': 'Trechos do título' }),
        pontos: h('input', { type: 'number', min: 1, max: 10, value: m.pontos, 'aria-label': 'Pontos' }),
        checklist: h('textarea', { rows: 8, 'aria-label': 'Checklist (um item por linha: id | texto)' }),
        treino: h('input', { type: 'url', value: m.link_treinamento || '', placeholder: 'https://', 'aria-label': 'Link do treinamento' }),
        nb: h('input', { type: 'url', value: m.link_notebooklm || '', placeholder: 'https://notebooklm.google.com/...', 'aria-label': 'Link do NotebookLM' }),
        orient: h('textarea', { rows: 3, 'aria-label': 'Orientações' }),
        peca: h('input', { type: 'checkbox', checked: m.exige_peca }), parecer: h('input', { type: 'checkbox', checked: m.exige_parecer }),
        ativa: h('input', { type: 'checkbox', checked: m.ativa }), motivo: h('input', { type: 'text', placeholder: 'Motivo da alteração', 'aria-label': 'Motivo' }) };
      c.checklist.value = (m.checklist || []).map(i => `${i.id} | ${i.texto}`).join('\n');
      c.orient.value = m.orientacoes || '';
      const msg = h('p', { class: 'erro' });
      const campo = (rot, el) => h('label', { class: 'filtro filtro-largo' }, h('span', {}, rot), el);
      form.append(h('h3', {}, m.id ? `Editar: ${m.nome}` : 'Nova modalidade'), campo('Nome', c.nome), campo('Trechos do título (separados por vírgula)', c.padroes),
        campo('Pontos de complexidade (1 a 10)', c.pontos), campo('Checklist — um item por linha, no formato "id | texto" (id com letras minúsculas, números e _)', c.checklist),
        campo('Material de treinamento', c.treino), campo('Conferência técnica (NotebookLM)', c.nb), campo('Orientações específicas', c.orient),
        h('div', { class: 'acoes' }, h('label', { class: 'opcao' }, c.peca, ' Exige a peça'), h('label', { class: 'opcao' }, c.parecer, ' Exige o parecer de autoavaliação'),
          h('label', { class: 'opcao' }, c.ativa, ' Ativa (trava a conclusão)')),
        campo('Motivo', c.motivo), h('div', { class: 'acoes' }, h('button', { type: 'button', class: 'btn', onclick: async () => {
          msg.textContent = '';
          const itens = c.checklist.value.split('\n').map(l => l.trim()).filter(Boolean).map(l => { const [id, ...t] = l.split('|'); return { id: id.trim(), texto: t.join('|').trim() }; });
          const dados = { id: m.id || null, nome: c.nome.value, padroes: c.padroes.value.split(',').map(x => x.trim()).filter(Boolean), pontos: Number(c.pontos.value),
            checklist: itens, link_treinamento: c.treino.value.trim(), link_notebooklm: c.nb.value.trim(), orientacoes: c.orient.value.trim(),
            exige_peca: c.peca.checked, exige_parecer: c.parecer.checked, ativa: c.ativa.checked };
          const { error: e } = await ctx.sb.rpc('admin_salvar_modalidade', { p_dados: dados, p_motivo: c.motivo.value });
          if (e) { msg.textContent = e.message; return; }
          await modalidades(); raiz.querySelector('#cf-mod-saida').append(aviso('info', `Modalidade "${dados.nome}" salva.`));
        } }, 'Salvar modalidade'), h('button', { type: 'button', class: 'btn btn-sec', onclick: () => { form.textContent = ''; } }, 'Cancelar')), msg);
      c.nome.focus();
    }
  }

  // ---------------------------------------------------------------- capacidade diária (0040)
  async function capacidade() {
    const el = raiz.querySelector('#cf-capacidade');
    const [{ data: cols, error }, { data: caps }, { data: par }] = await Promise.all([
      ctx.sb.from('colaboradores').select('id, nome_advbox').order('nome_advbox'), ctx.sb.from('capacidade_colaborador').select('colaborador_id, pontos_dia'),
      ctx.sb.from('parametros').select('valor').eq('chave', 'capacidade_pontos_dia').maybeSingle()]);
    el.textContent = '';
    el.append(h('h2', {}, 'Capacidade diária dos advogados'),
      h('p', { class: 'sutil' }, `Usada no planejamento da pauta (solicitações dos líderes). Padrão do escritório: ${par ? par.valor : '?'} pontos por dia `,
        '(parâmetro capacidade_pontos_dia). Aqui se ajusta por advogado; vazio = padrão.'));
    if (error) { el.append(aviso('erro', error.message)); return; }
    const mapa = new Map((caps || []).map(c => [c.colaborador_id, c.pontos_dia])); const saida = h('div');
    el.append(saida, tabela([
      { titulo: 'Advogado', valor: c => c.nome_advbox, larga: true },
      { titulo: 'Pontos por dia', valor: c => {
          const v = h('input', { type: 'number', min: 1, max: 50, value: mapa.get(c.id) || '', placeholder: 'padrão', 'aria-label': 'Capacidade de ' + c.nome_advbox, class: 'campo-curto' });
          const motivo = h('input', { type: 'text', placeholder: 'Motivo', 'aria-label': 'Motivo (capacidade de ' + c.nome_advbox + ')' });
          return h('div', { class: 'acoes' }, v, motivo, h('button', { type: 'button', class: 'btn btn-sec btn-peq', onclick: async () => {
            saida.textContent = '';
            const { error: e } = await ctx.sb.rpc('admin_definir_capacidade', { p_colaborador: c.id, p_pontos: v.value ? Number(v.value) : null, p_motivo: motivo.value });
            saida.append(e ? aviso('erro', `${c.nome_advbox}: ${e.message}`) : aviso('info', `${c.nome_advbox}: capacidade atualizada.`));
          } }, 'Salvar'));
        } }
    ], (cols || []).filter(c => !/^SEM RESPONSÁVEL|^ATLAS \(/.test(c.nome_advbox)), { compacta: true }));
  }

  // ---------------------------------------------------------------- calendário
  async function calendario() {
    const el = raiz.querySelector('#cf-cal');
    const desde = new Date().toLocaleDateString('sv-SE', { timeZone: 'America/Sao_Paulo' }).slice(0, 4) + '-01-01';
    const { data: d, error } = await ctx.sb.from('calendario_dias_nao_uteis').select('id, data, abrangencia, tribunal_cnj, foro_cnj, tipo, descricao, fundamento').gte('data', desde).order('data');
    el.textContent = '';
    el.append(h('h2', {}, 'Calendário de dias não úteis'),
      h('p', { class: 'sutil' }, 'Usado na contagem de D-4, D-7 e dos prazos em dias úteis. Remover um dia muda os prazos calculados daí em diante; o dia removido fica guardado na auditoria.'));
    if (error) { el.append(aviso('erro', error.message)); return; }
    const saida = h('div', { id: 'cf-cal-saida' });
    const f = {
      data: h('input', { type: 'date', id: 'cf-cal-data' }),
      abr: h('select', { id: 'cf-cal-abr' }, h('option', { value: 'nacional' }, 'Nacional'), h('option', { value: 'tribunal' }, 'Tribunal'), h('option', { value: 'foro' }, 'Foro (comarca)')),
      trib: h('input', { type: 'text', id: 'cf-cal-trib', placeholder: 'ex.: 8.13', size: 6 }),
      foro: h('input', { type: 'text', id: 'cf-cal-foro', placeholder: 'ex.: 0024', size: 6 }),
      tipo: h('select', { id: 'cf-cal-tipo' }, ['feriado', 'recesso', 'suspensao', 'ponto_facultativo'].map(t => h('option', { value: t }, t.replace('_', ' ')))),
      desc: h('input', { type: 'text', id: 'cf-cal-desc', placeholder: 'Descrição' }),
      fund: h('input', { type: 'text', id: 'cf-cal-fund', placeholder: 'Fundamento (lei, portaria, ato)' })
    };
    el.append(h('div', { class: 'filtros-barra' },
        h('label', { class: 'filtro' }, h('span', {}, 'Data'), f.data), h('label', { class: 'filtro' }, h('span', {}, 'Abrangência'), f.abr),
        h('label', { class: 'filtro' }, h('span', {}, 'Tribunal (J.TR)'), f.trib), h('label', { class: 'filtro' }, h('span', {}, 'Foro'), f.foro),
        h('label', { class: 'filtro' }, h('span', {}, 'Tipo'), f.tipo), h('label', { class: 'filtro' }, h('span', {}, 'Descrição'), f.desc),
        h('label', { class: 'filtro filtro-largo' }, h('span', {}, 'Fundamento'), f.fund),
        h('div', { class: 'acoes' }, h('button', { type: 'button', class: 'btn', id: 'cf-cal-incluir', onclick: async () => {
          saida.textContent = '';
          const { error: e } = await ctx.sb.rpc('admin_cadastrar_dia_nao_util', { p_data: f.data.value || null, p_abrangencia: f.abr.value, p_tipo: f.tipo.value,
            p_descricao: f.desc.value, p_fundamento: f.fund.value, p_tribunal: f.abr.value === 'nacional' ? null : f.trib.value || null, p_foro: f.abr.value === 'foro' ? f.foro.value || null : null });
          if (e) { saida.append(aviso('erro', e.message)); return; }
          await calendario(); raiz.querySelector('#cf-cal-saida').append(aviso('info', 'Dia incluído.'));
        } }, 'Incluir'))),
      saida,
      h('details', { id: 'cf-cal-lista' }, h('summary', {}, `Ver os ${num((d || []).length)} dias cadastrados a partir de ${data(desde)}`), tabela([
        { titulo: 'Data', valor: c => h('span', { class: 'nowrap' }, data(c.data)) },
        { titulo: 'Abrangência', valor: c => c.abrangencia + (c.tribunal_cnj ? ' ' + c.tribunal_cnj : '') + (c.foro_cnj ? ' / ' + c.foro_cnj : '') },
        { titulo: 'Tipo', valor: c => c.tipo.replace('_', ' ') },
        { titulo: 'Descrição', larga: true, valor: c => c.descricao || '—' },
        { titulo: 'Fundamento', valor: c => c.fundamento || '—' },
        { titulo: '', valor: c => {
            const m = h('input', { type: 'text', placeholder: 'Motivo da remoção', 'aria-label': 'Motivo da remoção de ' + data(c.data) });
            return h('div', { class: 'acoes' }, m, h('button', { type: 'button', class: 'btn btn-sec btn-peq', onclick: async () => {
              saida.textContent = '';
              const { error: e } = await ctx.sb.rpc('admin_remover_dia_nao_util', { p_id: c.id, p_motivo: m.value });
              if (e) { saida.append(aviso('erro', e.message)); return; }
              await calendario(); raiz.querySelector('#cf-cal-saida').append(aviso('info', `${data(c.data)} removido do calendário.`));
            } }, 'Remover'));
          } }
      ], d || [], { compacta: true })));
  }

  // ---------------------------------------------------------------- log de integração
  async function logs() {
    const el = raiz.querySelector('#cf-log');
    const { data: d, error } = await ctx.sb.rpc('admin_log_integracao', { p_dias: 7, p_nivel: null });
    el.textContent = '';
    el.append(h('h2', {}, 'Log de integração (7 dias)'));
    if (error) { el.append(aviso('erro', error.message)); return; }
    el.append(tabela([
      { titulo: 'Quando', valor: g => dataHora(g.ocorrido_em) },
      { titulo: 'Nível', valor: g => g.nivel === 'erro' ? h('b', { class: 'texto-alerta' }, 'Erro') : g.nivel === 'aviso' ? 'Aviso' : 'Info' },
      { titulo: 'Origem', valor: g => g.origem },
      { titulo: 'Operação', valor: g => g.operacao },
      { titulo: 'Mensagem', larga: true, valor: g => g.mensagem },
      { titulo: 'Usuário', valor: g => g.usuario || '—' }
    ], d || [], { compacta: true, vazio: 'Nenhum registro nos últimos 7 dias.', classeLinha: g => g.nivel === 'erro' ? 'linha-alerta' : null }));
  }

  window.Configuracoes = { abrir };
})();
