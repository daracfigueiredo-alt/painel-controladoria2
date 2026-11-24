/* Cadastro de processos no Atlas (14/11/2026, migração 0048, Edge Function atlas-cadastro).
 * Pedido da controladoria: os processos do ADVBOX também precisam estar no Atlas. O robô lê a exportação de
 * processos do ADVBOX, casa cada processo com um cliente que JÁ existe no Atlas (CPF/CNPJ, código do cliente
 * como "C362", nome) e monta a prévia. Nada vai para o Atlas sem a aprovação da controladoria.
 * Cliente não encontrado no Atlas fica só na lista (o robô não cria cliente). Processos encerrados também entram.
 * Toda permissão é decidida no banco; a chave do Atlas fica só no servidor. */
(function () {
  'use strict';
  const { h, num, dataHora, aviso, tabela } = UI;
  const msgErro = e => (e && (e.message || e.erro)) || String(e);
  const SITUACOES = {
    previa: 'Prévia (aguarda aprovação)', revisar: 'Revisar o cliente', sem_cliente: 'Cliente não encontrado no Atlas',
    aprovado: 'Aprovado (na fila)', enviando: 'Enviando', cadastrado: 'Cadastrado no Atlas', no_atlas: 'Já estava no Atlas', erro: 'Erro no cadastro'
  };
  const TAG = { previa: 'tag', revisar: 'tag tag-alerta', sem_cliente: 'tag tag-erro', aprovado: 'tag', enviando: 'tag',
                cadastrado: 'tag tag-ok', no_atlas: 'tag tag-ok', erro: 'tag tag-erro' };
  const LOTE_ENVIO = 1000;   // linhas por chamada ao banco

  async function chamar(ctx, corpo) {
    const { data: d, error } = await ctx.sb.functions.invoke('atlas-cadastro', { body: corpo });
    if (error) {
      let msg = error.message;
      try { const j = await error.context.json(); msg = j.erro || msg; } catch (e) { /* sem corpo */ }
      throw new Error(msg);
    }
    return d;
  }

  async function abrir(raiz, ctx) {
    const admin = ctx.perfil.papel === 'admin';
    const f = { situacao: 'previa', busca: '' };
    const marcados = new Set();
    raiz.append(h('h1', {}, 'Cadastro de processos no Atlas'),
      h('p', { class: 'subtitulo' }, 'Atlas Gestor'),
      h('p', { class: 'sutil' }, 'Robô que cadastra no Atlas os processos do ADVBOX que ainda não estão lá. Cada processo é ligado a um cliente que já existe ',
        'no Atlas (pelo CPF/CNPJ, pelo código do cliente, como "C362", ou pelo nome). Nada é gravado no Atlas sem a aprovação da controladoria; ',
        'antes de cada cadastro o robô confere no Atlas se o número já existe. Cliente não encontrado fica só na lista. ',
        'Depois do cadastro, o próprio Atlas completa tribunal, vara, classe e andamentos pelo DataJud.'));
    const topo = h('div'), corpo = h('div'); raiz.append(topo, corpo);
    const saida = h('div', { 'aria-live': 'polite' });

    if (admin) {
      const arquivo = h('input', { type: 'file', accept: '.xlsx,application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', 'aria-label': 'Exportação de processos do ADVBOX (.xlsx)' });
      const btImportar = h('button', { type: 'button', class: 'btn', onclick: importar }, 'Importar e montar a prévia');
      const btClientes = botao('Atualizar clientes do Atlas', 'Lendo os clientes do Atlas…', async () => {
        const r = await chamar(ctx, { acao: 'clientes' });
        return `${num(r.lidos)} cliente(s) lidos do Atlas (${num(r.com_documento)} com CPF/CNPJ); prévia refeita.`;
      });
      const btCadastrar = botao('Cadastrar 5 agora', 'Cadastrando no Atlas…', async () => {
        const r = await chamar(ctx, { acao: 'cadastrar', limite: 5 });
        if (!r.fila) return 'Nenhum processo aprovado na fila.';
        return `${num(r.cadastrados)} cadastrado(s), ${num(r.ja_existiam)} já existia(m) no Atlas, ${num(r.erros)} erro(s)`
          + (r.adiados ? `, ${num(r.adiados)} volta(m) para a fila` : '') + '.' + (r.mensagens.length ? ' ' + r.mensagens.join(' · ') : '')
          + (r.parou ? ' ' + r.parou : '');
      });
      topo.append(h('section', { class: 'cartao' },
        h('h2', {}, '1. Importar a exportação de processos do ADVBOX'),
        h('p', { class: 'sutil' }, 'ADVBOX › Processos › exportar (Excel). Linhas sem número de processo (assessoria, negociação) ficam de fora. ',
          'Pode importar de novo quando quiser: o que já foi aprovado ou cadastrado não volta para a prévia.'),
        h('div', { class: 'acoes' }, h('label', { class: 'arquivo' }, h('span', {}, 'Arquivo .xlsx'), arquivo), btImportar),
        h('h2', {}, '2. Conferir e aprovar'),
        h('p', { class: 'sutil' }, 'Os clientes do Atlas são relidos todo dia às 23:40. Depois de cadastrar um cliente que faltava, use "Atualizar clientes do Atlas". ',
          'Os aprovados são cadastrados automaticamente, a cada 2 minutos, 15 por vez.'),
        h('div', { class: 'acoes' }, btClientes, btCadastrar), saida));

      async function importar() {
        saida.textContent = '';
        const f0 = arquivo.files[0];
        if (!f0) { saida.append(aviso('alerta', 'Escolha o arquivo .xlsx exportado do ADVBOX.')); return; }
        btImportar.disabled = true; const txt = btImportar.textContent; btImportar.textContent = 'Lendo a planilha…';
        try {
          const p = OCPlanilha.lerPlanilha(new Uint8Array(await f0.arrayBuffer()));
          const faltam = ['Nome do cliente', 'Número do processo'].filter(c => !p.cabecalho.includes(c));
          if (faltam.length) throw new Error('Esta não é a exportação de processos do ADVBOX: faltam as colunas ' + faltam.join(' e ') + '.');
          const tot = { linhas: 0, linhas_com_processo: 0, novos: 0, atualizados: 0, da_carteira: 0 };
          for (let i = 0; i < p.linhas.length; i += LOTE_ENVIO) {
            btImportar.textContent = `Enviando ${num(Math.min(i + LOTE_ENVIO, p.linhas.length))} de ${num(p.linhas.length)}…`;
            const fim = i + LOTE_ENVIO >= p.linhas.length;
            const { data: r, error } = await ctx.sb.rpc('atlas_cadastro_importar', { p_linhas: p.linhas.slice(i, i + LOTE_ENVIO), p_arquivo: f0.name, p_final: fim });
            if (error) throw error;
            for (const k of Object.keys(tot)) tot[k] += r[k] || 0;
          }
          saida.append(aviso('ok', `${num(tot.linhas)} linha(s) lidas; ${num(tot.linhas_com_processo)} com número de processo válido; `,
            `${num(tot.novos)} processo(s) novo(s) na lista e ${num(tot.atualizados)} atualizado(s)`,
            tot.da_carteira ? `; ${num(tot.da_carteira)} processo(s) da Webjur/CNJ fora do Atlas e fora da planilha entraram na lista.` : '.'),
            ...p.avisos.map(a => aviso('alerta', a)));
          f.situacao = 'previa'; desenhar();
        } catch (e) { saida.append(aviso('erro', msgErro(e))); }
        finally { btImportar.disabled = false; btImportar.textContent = txt; }
      }
    }

    function botao(rot, ocupado, fn) {
      const b = h('button', { type: 'button', class: 'btn btn-sec', onclick: async () => {
        const txt = b.textContent; b.disabled = true; b.textContent = ocupado; saida.textContent = '';
        try { saida.append(aviso('ok', await fn())); desenhar(); } catch (e) { saida.append(aviso('erro', msgErro(e))); }
        finally { b.disabled = false; b.textContent = txt; } } }, rot);
      return b;
    }

    const campo = (rot, el) => h('label', { class: 'filtro' }, h('span', {}, rot), el);
    const selSit = h('select', {}, h('option', { value: '' }, 'Todas'), Object.entries(SITUACOES).map(([v, t]) => h('option', { value: v }, t)));
    const busca = h('input', { type: 'search', placeholder: 'Processo, cliente ou parte', 'aria-label': 'Buscar' });
    const filtros = h('form', { class: 'filtros-barra', onsubmit: e => { e.preventDefault(); f.situacao = selSit.value; f.busca = busca.value; desenhar(); } },
      campo('Situação', selSit), campo('Busca', busca), h('button', { type: 'submit', class: 'btn btn-sec' }, 'Filtrar'));

    async function desenhar() {
      selSit.value = f.situacao; marcados.clear();
      corpo.textContent = ''; corpo.append(h('p', { class: 'sutil' }, 'Carregando…'));
      let r;
      try {
        const { data: d, error } = await ctx.sb.rpc('atlas_cadastro_painel', { p_situacao: f.situacao || null, p_busca: f.busca || null, p_limite: 3000 });
        if (error) throw error; r = d;
      } catch (e) { corpo.textContent = ''; corpo.append(aviso('erro', msgErro(e))); return; }
      corpo.textContent = '';
      const c = r.contagem || {};
      const k = (sit, rot, desc, atencao) => h('button', { type: 'button', class: 'kpi kpi-botao' + (atencao ? ' kpi-atencao' : '') + (f.situacao === sit ? ' kpi-ativo' : ''),
        onclick: () => { f.situacao = sit; desenhar(); } },
        h('span', { class: 'kpi-rotulo' }, rot), h('span', { class: 'kpi-valor' }, num(c[sit] || 0)), desc ? h('span', { class: 'kpi-desc' }, desc) : null);
      corpo.append(h('section', { class: 'kpis' },
        k('previa', 'Prévia', 'aguardam aprovação'),
        k('sem_cliente', 'Cliente não encontrado', 'só listados', (c.sem_cliente || 0) > 0),
        k('revisar', 'Revisar o cliente', 'mais de um possível', (c.revisar || 0) > 0),
        k('aprovado', 'Na fila', (c.enviando ? `${num(c.enviando)} enviando` : 'cadastro automático')),
        k('cadastrado', 'Cadastrados', 'pelo robô'),
        k('no_atlas', 'Já estavam no Atlas'),
        k('erro', 'Erros', 'conferir', (c.erro || 0) > 0)));
      const ca = r.clientes_atlas || {};
      corpo.append(h('p', { class: 'sutil' },
        ca.total ? `Clientes do Atlas: ${num(ca.total)} (${num(ca.com_documento)} com CPF/CNPJ), lidos em ${dataHora(ca.lidos_em)}. ` : 'Os clientes do Atlas ainda não foram lidos. ',
        r.ultima_importacao ? `Última importação: ${r.ultima_importacao.detalhe.arquivo || 'planilha'} em ${dataHora(r.ultima_importacao.em)}. ` : 'Nenhuma importação ainda. ',
        r.ultima_execucao ? `Último envio ao Atlas: ${dataHora(r.ultima_execucao.em)} (${num(r.ultima_execucao.detalhe.cadastrados)} cadastrado(s), ${num(r.ultima_execucao.detalhe.erros)} erro(s)).` : ''));
      corpo.append(filtros);

      const itens = r.itens || [];
      const aprovaveis = itens.filter(i => (i.situacao === 'previa' || i.situacao === 'erro') && i.atlas_client_id);
      const acoes = h('div', { class: 'acoes' });
      if (admin && aprovaveis.length) {
        const btSel = h('button', { type: 'button', class: 'btn', onclick: async () => {
          if (!marcados.size) { saida.textContent = ''; saida.append(aviso('alerta', 'Marque os processos na lista.')); return; }
          await rpcAcao('atlas_cadastro_aprovar', { p_cnjs: [...marcados], p_todos: false }, r2 => `${num(r2.aprovados)} aprovado(s); ${num(r2.na_fila)} na fila.`);
        } }, 'Aprovar marcados');
        let confirmar = false;
        const btTodos = h('button', { type: 'button', class: 'btn btn-sec', onclick: async () => {
          if (!confirmar) { confirmar = true; btTodos.textContent = `Confirmar: aprovar todos os ${num(c.previa || 0)} da prévia`; return; }
          await rpcAcao('atlas_cadastro_aprovar', { p_cnjs: null, p_todos: true }, r2 => `${num(r2.aprovados)} aprovado(s); ${num(r2.na_fila)} na fila.`);
        } }, 'Aprovar todos da prévia');
        acoes.append(btSel, btTodos);
      }
      if (admin && f.situacao === 'aprovado' && itens.length) acoes.append(h('button', { type: 'button', class: 'btn btn-sec', onclick: () =>
        rpcAcao('atlas_cadastro_suspender', { p_cnjs: marcados.size ? [...marcados] : null, p_todos: !marcados.size }, r2 => `${num(r2.suspensos)} devolvido(s) para a prévia.`) },
        'Tirar da fila (marcados ou todos)'));
      if (itens.length) acoes.append(h('button', { type: 'button', class: 'btn btn-sec', onclick: () => baixarCsv(itens) }, 'Baixar esta lista (CSV)'));
      corpo.append(acoes);
      if (itens.length >= 3000) corpo.append(aviso('alerta', 'Mostrando os 3.000 primeiros; use os filtros.'));

      const colunas = [];
      if (admin) colunas.push({ titulo: '', valor: i => (i.situacao === 'previa' || i.situacao === 'erro' || i.situacao === 'aprovado') && i.atlas_client_id
        ? h('input', { type: 'checkbox', 'aria-label': 'Marcar ' + i.cnj, onchange: e => { e.target.checked ? marcados.add(i.cnj) : marcados.delete(i.cnj); } }) : '' });
      colunas.push(
        { titulo: 'Processo', valor: i => h('span', { class: 'nowrap' }, i.cnj) },
        { titulo: 'Cliente no ADVBOX', valor: i => i.cliente_advbox ? i.cliente_advbox.split(';').join('; ') : '—' },
        { titulo: 'Cliente no Atlas', valor: i => i.atlas_cliente_nome
            ? h('span', {}, i.atlas_cliente_nome, h('br'), h('span', { class: 'sutil' }, 'por ' + (i.casado_por || '—')))
            : (admin && ['sem_cliente', 'revisar', 'previa', 'erro'].includes(i.situacao) && i.origem === 'advbox' ? escolherCliente(i) : '—') },
        { titulo: 'Tipo (ADVBOX → Atlas)', valor: i => i.tipo_advbox ? `${i.tipo_advbox} → ${i.tipo_atlas || '—'}` : '—' },
        { titulo: 'Situação', valor: i => h('span', {}, h('span', { class: TAG[i.situacao] || 'tag' }, SITUACOES[i.situacao] || i.situacao),
            i.motivo ? h('span', { class: 'sutil' }, h('br'), i.motivo) : null,
            i.ultimo_erro ? h('span', { class: 'sutil' }, h('br'), 'Atlas: ' + i.ultimo_erro) : null) },
        { titulo: 'O que vai para o Atlas', larga: true, valor: i => i.situacao === 'sem_cliente' && !i.tipo_atlas ? '—' : h('details', {},
            h('summary', {}, [i.tipo_atlas, i.valor_causa ? 'R$ ' + Number(i.valor_causa).toLocaleString('pt-BR', { minimumFractionDigits: 2 }) : null].filter(Boolean).join(' · ') || 'ver'),
            h('p', {}, h('b', {}, 'Autores: '), i.autores || '—'), h('p', {}, h('b', {}, 'Réus: '), i.reus || '—'),
            h('p', { class: 'teor-cnj' }, i.notas || ''),
            i.atlas_lawsuit_id ? h('p', { class: 'sutil' }, 'Id no Atlas: ' + i.atlas_lawsuit_id) : null) });
      corpo.append(tabela(colunas, itens, { compacta: true, vazio: 'Nenhum processo nesta situação.',
        classeLinha: i => ['sem_cliente', 'revisar', 'erro'].includes(i.situacao) ? 'linha-alerta' : null }));
    }

    async function rpcAcao(nome, args, msg) {
      saida.textContent = '';
      const { data: r, error } = await ctx.sb.rpc(nome, args);
      if (error) { saida.append(aviso('erro', msgErro(error))); return; }
      saida.append(aviso('ok', msg(r))); desenhar();
    }

    // vários clientes possíveis ou nenhum: a controladoria escolhe entre os clientes lidos do Atlas
    function escolherCliente(i) {
      const caixa = h('details', {}, h('summary', {}, 'Escolher cliente'));
      const termo = h('input', { type: 'search', placeholder: 'Nome, código (C362) ou CPF/CNPJ', 'aria-label': 'Buscar cliente do Atlas para ' + i.cnj });
      const lista = h('div');
      caixa.append(h('form', { onsubmit: async e => {
        e.preventDefault(); lista.textContent = '';
        const { data: cs, error } = await ctx.sb.rpc('atlas_clientes_buscar', { p_busca: termo.value });
        if (error) { lista.append(aviso('erro', msgErro(error))); return; }
        if (!cs.length) { lista.append(h('p', { class: 'sutil' }, 'Nenhum cliente do Atlas encontrado.')); return; }
        lista.append(...cs.map(c => h('button', { type: 'button', class: 'btn btn-sec btn-peq', onclick: () =>
          rpcAcao('atlas_cadastro_definir_cliente', { p_cnj: i.cnj, p_client_id: c.id }, r2 => `${r2.cnj}: cliente ${r2.cliente}. Confira e aprove.`) }, c.nome)));
      } }, termo, h('button', { type: 'submit', class: 'btn btn-sec btn-peq' }, 'Buscar')), lista);
      return caixa;
    }

    function baixarCsv(itens) {
      const cols = [['cnj', 'Processo'], ['situacao', 'Situação'], ['motivo', 'Motivo'], ['cliente_advbox', 'Cliente no ADVBOX'], ['atlas_cliente_nome', 'Cliente no Atlas'],
                    ['parte_contraria', 'Parte contrária'], ['tipo_advbox', 'Tipo no ADVBOX'], ['tipo_atlas', 'Tipo no Atlas'], ['tribunal', 'Tribunal'],
                    ['responsavel_advbox', 'Responsável no ADVBOX'], ['ultimo_erro', 'Erro do Atlas']];
      const esc = v => { const s = v === null || v === undefined ? '' : String(v); return /[";\n]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s; };
      const linhas = [cols.map(c => c[1]).join(';'), ...itens.map(i => cols.map(([k]) => esc(k === 'situacao' ? SITUACOES[i[k]] || i[k] : i[k])).join(';'))];
      const url = URL.createObjectURL(new Blob(['﻿' + linhas.join('\r\n')], { type: 'text/csv;charset=utf-8' }));
      const a = h('a', { href: url, download: `cadastro_atlas_${f.situacao || 'todos'}.csv` }); document.body.append(a); a.click(); a.remove();
      setTimeout(() => URL.revokeObjectURL(url), 5000);
    }

    desenhar();
  }

  window.CadastroAtlas = { abrir, chamar };
})();
