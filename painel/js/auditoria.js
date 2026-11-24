/* Área 10 — Histórico de auditoria (Etapa 9, Prompt Mestre §23). Exclusiva do administrador.
 * Uma linha do tempo única: eventos das tarefas (inclusive os recuperados do Excel, marcados
 * como tal), importações, publicações, conferências, tarefas de análise, varreduras do ADVBOX,
 * erros de integração e alterações de configuração (antes/depois, quem e motivo).
 * Também roda a verificação de integridade do banco. Somente leitura. */
(function () {
  'use strict';
  const { h, data, dataHora, num, tabela, aviso } = UI;
  const CAT = { importacao: 'Importação', tratativa: 'Tratativa e conclusão', responsavel: 'Responsável / realocação',
    reagendamento: 'Reagendamento / datas', prazo_fatal: 'Prazo fatal', publicacao: 'Publicação recebida', conferencia: 'Conferência no ADVBOX',
    tarefa_analise: 'Tarefa de análise', integracao: 'Integração (erros e avisos)', varredura: 'Varredura do ADVBOX',
    configuracao: 'Configuração', administrativo: 'Ato administrativo', outros: 'Outros' };
  const TIPO = { encaminhamento: 'Encaminhamento', anotacao_realocacao: 'Anotação de realocação', pedido_reagendamento: 'Pedido de reagendamento',
    alteracao_data_agenda: 'Alteração da data da agenda', alteracao_pf_tarefa: 'Alteração do prazo fatal da tarefa', alteracao_responsavel: 'Alteração de responsável',
    conclusao: 'Conclusão', inicio_tratativa: 'Início da tratativa', tentativa_conclusao: 'Tentativa de conclusão (trava)',
    tentativa_realocacao: 'Tentativa de realocação (trava)', tentativa_alteracao_pf: 'Tentativa de alterar o prazo fatal (trava)',
    importacao: 'Importação de planilha', unificacao_tarefa: 'Unificação de tarefa', publicacao_recebida: 'Publicação recebida',
    publicacao_conferida: 'Publicação conferida no ADVBOX', tarefa_analise_status: 'Tarefa de análise', erro_integracao: 'Erro de integração',
    conferencia_alerta: 'Conferência de alerta', cadastro_administrativo: 'Cadastro administrativo', varredura_advbox: 'Varredura das intimações',
    log_aviso: 'Aviso de integração', log_info: 'Informação de integração' };
  const ORIGEM = { excel_campo: 'Excel (campo)', excel_observacoes: 'Excel (observações)', comparacao_importacoes: 'Comparação de importações',
    extensao: 'Extensão', sistema: 'Sistema', administrativo: 'Painel (admin)', webjur_portal: 'Webjur (portal)', webjur_gmail: 'Webjur (Gmail)',
    webjur_email: 'Webjur (e-mail)', manual: 'Manual', advbox_extensao: 'Extensão', importacao_excel: 'Importação Excel', atlas_api: 'API do Atlas' };
  const hoje = () => new Date().toLocaleDateString('sv-SE', { timeZone: 'America/Sao_Paulo' });
  const menosDias = (iso, n) => { const d = new Date(iso + 'T12:00:00Z'); d.setUTCDate(d.getUTCDate() - n); return d.toISOString().slice(0, 10); };
  const curto = (v, n = 140) => { if (v === null || v === undefined) return ''; const s = typeof v === 'string' ? v : JSON.stringify(v); return s.length > n ? s.slice(0, n) + '…' : s; };
  const TABELA = { parametros: 'parâmetro', perfis: 'perfil de acesso', calendario_dias_nao_uteis: 'calendário', colaboradores: 'colaborador', equipes: 'equipe' };
  const OPER = { insert: 'inclusão', update: 'alteração', delete: 'remoção' };
  const rotulo = i => i.categoria === 'configuracao'
    ? `${(OPER[i.tipo.split('_').pop()] || 'alteração').replace(/^./, c => c.toUpperCase())} de ${TABELA[(i.evidencia || {}).tabela] || (i.evidencia || {}).tabela}`
    : (TIPO[i.tipo] || i.tipo.replace(/_/g, ' '));
  const linkTarefa = id => /^\d{1,15}$/.test(id || '') ? h('a', { href: `https://app.advbox.com.br/0?t=${id}`, target: '_blank', rel: 'noopener noreferrer' }, id) : '—';
  let ctx, raiz, ultimo = null;

  function resumo(i) {
    const ev = i.evidencia || {};
    if (i.categoria === 'configuracao') {
      const ch = ev.chave, ant = i.antes || {}, dep = i.depois || {};
      if (ev.tabela === 'parametros') return `Parâmetro ${ch}: ${curto(ant.valor, 40)} → ${curto(dep.valor, 40)}${dep.confirmado !== ant.confirmado ? (dep.confirmado ? ' (confirmado)' : ' (desconfirmado)') : ''}`;
      if (ev.tabela === 'perfis') return `Perfil ${curto(ch, 12)}: ${ant.papel || 'sem acesso'} → ${dep.papel || 'sem acesso'}`;
      if (ev.tabela === 'calendario_dias_nao_uteis') return `Calendário: ${i.tipo.endsWith('delete') ? 'removido' : i.tipo.endsWith('insert') ? 'cadastrado' : 'alterado'} ${data((dep.data || ant.data))} ${dep.descricao || ant.descricao || ''}`;
      return `${ev.tabela} ${ch}: ${i.tipo.split('_').pop()}`;
    }
    if (i.tipo === 'varredura_advbox') return `${ev.recebido_de ? data(ev.recebido_de) + ' a ' + data(ev.recebido_ate) : ''} — ${num(ev.total_lido)} de ${num(ev.total_informado)} lidas${ev.completa ? '' : ' (INCOMPLETA)'}`;
    if (i.tipo === 'log_aviso' || i.tipo === 'log_info' || i.tipo === 'erro_integracao') return `${ev.operacao || ''}: ${curto(ev.mensagem, 160)}`;
    if (i.tipo === 'cadastro_administrativo') return `${String(ev.operacao || '').replace(/_/g, ' ')}${(i.depois || i.antes || {}).data ? ' ' + data((i.depois || i.antes).data) : ''}${ev.motivo ? ' — ' + curto(ev.motivo, 90) : ''}${ev.fundamento ? ' — ' + curto(ev.fundamento, 60) : ''}`;
    if (i.tipo === 'publicacao_conferida') return `Resultado: ${String(i.depois || '').replace(/_/g, ' ')}${i.antes ? ' (antes: ' + String(i.antes).replace(/_/g, ' ') + ')' : ''}`;
    if (i.tipo === 'tarefa_analise_status') return `#${ev.tarefa_analise_id || ''}: ${i.antes || 'nova'} → ${i.depois || ''}${i.justificativa ? ' — ' + curto(i.justificativa, 90) : ''}${ev.advbox_tarefa_id ? ' (tarefa ' + ev.advbox_tarefa_id + ')' : ''}`;
    if (i.antes !== null && i.antes !== undefined || i.depois !== null && i.depois !== undefined) return `${curto(i.antes, 50) || '—'} → ${curto(i.depois, 50) || '—'}`;
    if (ev.cnj || ev.mensagem) return curto(ev.mensagem || ev.cnj, 140);
    return i.justificativa ? curto(i.justificativa) : '';
  }
  const registro = i => i.recuperado
    ? h('span', { class: 'sutil', title: 'Lido de texto anterior à implantação (observações/Excel). Não é registro feito na hora.' }, 'Recuperado' + (i.classificacao !== 'confirmado' ? ` (${i.classificacao})` : ''))
    : h('span', {}, 'Registrado' + (i.classificacao !== 'confirmado' ? ` (${i.classificacao})` : ''));

  async function abrir(container, contexto) {
    ctx = contexto; raiz = container;
    const fim = hoje();
    const ini = h('input', { type: 'date', id: 'au-ini', value: menosDias(fim, 7) }), fimEl = h('input', { type: 'date', id: 'au-fim', value: fim });
    const cat = h('select', { id: 'au-cat' }, h('option', { value: '' }, 'Todas'), Object.entries(CAT).map(([k, v]) => h('option', { value: k }, v)));
    const busca = h('input', { type: 'search', id: 'au-busca', placeholder: 'ID da tarefa, CNJ, pessoa ou texto' });
    raiz.append(
      h('h1', {}, 'Histórico de auditoria'),
      h('p', { class: 'sutil' }, 'Linha do tempo de tudo o que o sistema registrou. "Recuperado" = lido de texto anterior à implantação (observações do Excel); ',
        'não é registro feito no momento. "Registrado" = gravado no momento em que aconteceu, pela extensão, pelo painel ou pelo próprio banco. Nada aqui pode ser alterado ou apagado.'),
      h('section', { class: 'cartao' },
        h('div', { class: 'filtros-barra' },
          h('label', { class: 'filtro' }, h('span', {}, 'De'), ini), h('label', { class: 'filtro' }, h('span', {}, 'Até'), fimEl),
          h('label', { class: 'filtro' }, h('span', {}, 'Categoria'), cat), h('label', { class: 'filtro filtro-largo' }, h('span', {}, 'Buscar'), busca),
          h('div', { class: 'acoes' },
            h('button', { type: 'button', class: 'btn', id: 'au-consultar', onclick: consultar }, 'Consultar'),
            h('button', { type: 'button', class: 'btn btn-sec', id: 'au-csv', onclick: exportar }, 'Exportar CSV'))),
        h('div', { id: 'au-resultado' })),
      h('section', { class: 'cartao' }, h('h2', {}, 'Integridade do banco'),
        h('p', { class: 'sutil' }, 'Conferências automáticas: duplicidades, tarefas de análise sem ID do ADVBOX, criações presas, publicações sem conferência, ',
          'tabelas sem RLS, acesso anônimo, funções sem proteção e parâmetros ainda provisórios.'),
        h('div', { class: 'acoes' }, h('button', { type: 'button', class: 'btn btn-sec', id: 'au-integridade', onclick: integridade }, 'Verificar integridade agora')),
        h('div', { id: 'au-int' })));
    busca.addEventListener('keydown', e => { if (e.key === 'Enter') consultar(); });
    await consultar();
  }

  async function consultar() {
    const el = raiz.querySelector('#au-resultado');
    el.textContent = ''; el.append(h('p', { class: 'sutil' }, 'Consultando…'));
    const { data: d, error } = await ctx.sb.rpc('auditoria_linha_tempo', { p_inicio: raiz.querySelector('#au-ini').value, p_fim: raiz.querySelector('#au-fim').value,
      p_categoria: raiz.querySelector('#au-cat').value || null, p_busca: raiz.querySelector('#au-busca').value || null, p_limite: 1000 });
    el.textContent = '';
    if (error) { el.append(aviso('erro', error.message)); return; }
    ultimo = d.itens;
    const rec = d.itens.filter(i => i.recuperado).length;
    el.append(h('p', { class: 'sutil', id: 'au-total' }, `${num(d.total)} registro(s)`, d.truncado ? ` — mostrando os ${num(d.limite)} mais recentes; refine o período ou a busca.` : '.',
        rec ? ` ${num(rec)} recuperado(s) de texto anterior à implantação.` : ''),
      tabela([
        { titulo: 'Quando', valor: i => h('span', { class: 'nowrap', title: i.precisao && i.precisao !== 'segundo' ? 'Precisão: ' + i.precisao : null }, i.precisao === 'dia' ? data(i.em) : dataHora(i.em)) },
        { titulo: 'Categoria', valor: i => CAT[i.categoria] || i.categoria },
        { titulo: 'O que', larga: true, valor: i => h('div', {}, h('div', {}, rotulo(i)), h('div', { class: 'sutil' }, resumo(i))) },
        { titulo: 'Quem', valor: i => i.quem || '—' },
        { titulo: 'Tarefa ADVBOX', valor: i => linkTarefa(i.advbox_id) },
        { titulo: 'Processo', valor: i => i.cnj ? h('span', { class: 'nowrap' }, i.cnj) : '—' },
        { titulo: 'Origem', valor: i => h('div', {}, ORIGEM[i.origem] || i.origem, h('div', {}, registro(i))) },
        { titulo: '', valor: i => h('button', { type: 'button', class: 'btn btn-sec btn-peq', onclick: () => detalhe(i) }, 'Ver') }
      ], d.itens, { vazio: 'Nenhum registro no período.', classeLinha: i => /erro|INCOMPLETA/.test(i.tipo + resumo(i)) ? 'linha-alerta' : null }));
  }

  let dlg = null;
  function detalhe(i) {
    if (!dlg) { dlg = h('dialog', { class: 'detalhe', 'aria-labelledby': 'au-det-titulo' }); document.body.append(dlg); }
    dlg.textContent = '';
    const bloco = (t, v) => v === null || v === undefined ? '' : h('div', {}, h('h3', {}, t), h('pre', { class: 'pub-teor', tabindex: '0' }, JSON.stringify(v, null, 2)));
    dlg.append(h('div', { class: 'detalhe-topo' }, h('div', {}, h('h2', { id: 'au-det-titulo' }, rotulo(i)), h('p', { class: 'sutil' }, `${dataHora(i.em)} — ${CAT[i.categoria] || i.categoria}`)),
        h('button', { type: 'button', class: 'btn btn-sec btn-peq', onclick: () => dlg.close() }, 'Fechar')),
      h('div', { class: 'detalhe-corpo' },
        h('dl', { class: 'resumo' },
          h('div', {}, h('dt', {}, 'Quem'), h('dd', {}, i.quem || '—')), h('div', {}, h('dt', {}, 'Origem'), h('dd', {}, ORIGEM[i.origem] || i.origem)),
          h('div', {}, h('dt', {}, 'Registro'), h('dd', {}, i.recuperado ? 'Recuperado de texto anterior à implantação' : 'Registrado no momento')),
          h('div', {}, h('dt', {}, 'Classificação'), h('dd', {}, i.classificacao)), h('div', {}, h('dt', {}, 'Precisão da data'), h('dd', {}, i.precisao || '—')),
          h('div', {}, h('dt', {}, 'Registro de origem'), h('dd', {}, `${i.tabela} ${i.ref}`)),
          h('div', {}, h('dt', {}, 'Tarefa ADVBOX'), h('dd', {}, linkTarefa(i.advbox_id))), h('div', {}, h('dt', {}, 'Processo'), h('dd', {}, i.cnj || '—'))),
        i.justificativa ? h('div', {}, h('h3', {}, i.categoria === 'configuracao' ? 'Motivo' : 'Justificativa'), h('p', {}, i.justificativa)) : '',
        i.estado_trava ? h('p', {}, h('b', {}, 'Trava: '), i.estado_trava.replace(/_/g, ' ')) : '',
        bloco('Antes', i.antes), bloco('Depois', i.depois), bloco('Evidência', i.evidencia)));
    dlg.showModal();
  }

  function exportar() {
    if (!ultimo || !ultimo.length) return;
    const esc = v => { const s = v === null || v === undefined ? '' : String(v); return /[";\n\r]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s; };
    const linhas = [['quando', 'categoria', 'tipo', 'resumo', 'quem', 'tarefa_advbox', 'processo', 'origem', 'registro', 'classificacao', 'tabela', 'ref']]
      .concat(ultimo.map(i => [i.em, CAT[i.categoria] || i.categoria, rotulo(i), resumo(i), i.quem, i.advbox_id, i.cnj, ORIGEM[i.origem] || i.origem,
        i.recuperado ? 'recuperado' : 'registrado', i.classificacao, i.tabela, i.ref]));
    const blob = new Blob(['﻿' + linhas.map(l => l.map(esc).join(';')).join('\r\n')], { type: 'text/csv;charset=utf-8' });
    const a = h('a', { href: URL.createObjectURL(blob), download: `auditoria_${raiz.querySelector('#au-ini').value}_${raiz.querySelector('#au-fim').value}.csv` });
    document.body.append(a); a.click(); a.remove(); setTimeout(() => URL.revokeObjectURL(a.href), 5000);
  }

  async function integridade() {
    const el = raiz.querySelector('#au-int');
    el.textContent = ''; el.append(h('p', { class: 'sutil' }, 'Verificando…'));
    const { data: d, error } = await ctx.sb.rpc('auditoria_integridade');
    el.textContent = '';
    if (error) { el.append(aviso('erro', error.message)); return; }
    const ord = { erro: 0, alerta: 1, info: 2 };
    const itens = d.itens.slice().sort((a, b) => (b.quantidade > 0) - (a.quantidade > 0) || ord[a.gravidade] - ord[b.gravidade]);
    const erros = itens.filter(i => i.gravidade === 'erro' && i.quantidade > 0).length;
    el.append(aviso(erros ? 'erro' : 'info', erros ? `${erros} problema(s) de integridade encontrado(s).` : 'Nenhum problema de integridade encontrado.',
        ` Verificado em ${dataHora(d.verificado_em)}.`),
      tabela([
        { titulo: 'Situação', valor: i => i.quantidade > 0 ? h('b', { class: i.gravidade === 'info' ? null : 'texto-alerta' }, { erro: 'Erro', alerta: 'Atenção', info: 'Informativo' }[i.gravidade]) : 'OK' },
        { titulo: 'Verificação', larga: true, valor: i => i.descricao },
        { titulo: 'Qtd.', num: true, valor: i => num(i.quantidade) },
        { titulo: 'Exemplos', valor: i => (i.exemplos || []).slice(0, 8).join(', ') || '—' }
      ], itens, { compacta: true, classeLinha: i => i.quantidade > 0 && i.gravidade !== 'info' ? 'linha-alerta' : null }));
  }

  window.Auditoria = { abrir };
})();
