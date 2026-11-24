/* Relatório gerencial de cada menu, com gráficos de pizza (pedido da controladoria, 16/11/2026, migração 0056).
 * Um bloco recolhível no topo de cada área, para a controladoria e a diretoria. Os números vêm de relatorio_gerencial
 * (o banco decide quem pode ler). Cada pizza tem até 6 fatias (o resto vira "Outros"), legenda com quantidade e %,
 * tabela e dica ao passar o mouse. Paleta categórica validada (claro e escuro) no CSS: .fatia-1 … .fatia-6, .fatia-outros.
 * "Imprimir / PDF" imprime só o relatório. */
(function () {
  'use strict';
  const { h, num, data, aviso } = UI;
  const SVG = 'http://www.w3.org/2000/svg';
  const MAX_FATIAS = 6;
  const hojeISO = () => new Date().toLocaleDateString('sv-SE', { timeZone: 'America/Sao_Paulo' });
  const somaDias = (iso, n) => { const d = new Date(iso + 'T12:00:00'); d.setDate(d.getDate() + n); return d.toISOString().slice(0, 10); };
  const msgErro = e => (e && (e.message || e.erro)) || String(e);
  const AREAS_COM_RELATORIO = ['diretoria', 'visao-geral', 'colaboradores', 'prazos', 'reagendamentos', 'tratativa', 'audiencias',
    'minha-pauta', 'solicitacoes', 'atlas', 'cadastro-atlas', 'intimacoes-cnj', 'publicacoes', 'inconsistencias', 'analise',
    'importacao', 'double-check', 'auditoria', 'configuracoes'];

  // rótulos do banco → texto da tela (o que não está aqui: "_" vira espaço e a 1ª letra fica maiúscula)
  const ROTULOS = {
    pendente: 'Pendente', concluida: 'Concluída', agendada: 'Agendada', realizada: 'Realizada', redesignada: 'Redesignada',
    cancelada: 'Cancelada', nao_realizada: 'Não realizada', descartada: 'Descartada',
    sem_data: 'Sem data na intimação', sem_advogado: 'Sem advogado', sem_confirmacao: 'Sem confirmação',
    sem_tarefa_atlas: 'Sem tarefa no Atlas', sem_ata: 'Sem ata/resultado',
    acordo: 'Acordo', sem_acordo: 'Sem acordo', instrucao_concluida: 'Instrução concluída',
    ausencia_evidencia: 'Ausência de evidência', operacional_interno: 'Operacional interno', processual: 'Processual',
    pendente_conferencia: 'Pendente de conferência', conferido: 'Conferido',
    anotado: 'Anotado', potencial: 'Potencial', confirmado: 'Confirmado',
    aberta: 'Aberta', regularizada: 'Regularizada', justificada: 'Justificada',
    no_atlas: 'Já estava no Atlas', sem_cliente: 'Cliente não encontrado', revisar: 'Revisar o cliente', previa: 'Prévia',
    aprovado: 'Aprovado', enviando: 'Enviando', cadastrado: 'Cadastrado', erro: 'Erro',
    admin: 'Controladoria', diretoria: 'Diretoria', lider: 'Líder', colaborador: 'Peticionador',
    concluido: 'Concluído', concluida_com_alertas: 'Concluída com alertas', falhou: 'Falhou', processando: 'Processando',
    rejeitada: 'Rejeitada', criada: 'Criada', preparada: 'Preparada', aprovada: 'Aprovada', recusada: 'Recusada',
    info: 'Informação', aviso: 'Aviso', INSERT: 'Inclusão', UPDATE: 'Alteração', DELETE: 'Exclusão',
    intimacao_nao_cadastrada: 'Intimação não cadastrada no Atlas', divergencia: 'Divergência Webjur × Atlas', prazo_nao_lancado: 'Prazo não lançado',
    prazo_incorreto: 'Prazo lançado incorretamente', publicacao_duplicada: 'Publicação duplicada', pendencia_controladoria: 'Pendência da controladoria',
    captura_divergente: 'Captura divergente CNJ × Webjur', audiencia_pendente: 'Audiência pendente', conclusao_sem_justificativa: 'Conclusão sem justificativa',
    aguardando_lider: 'Aguardando o líder', aguardando_controladoria: 'Aguardando a controladoria', executada: 'Executada no Atlas',
    'codigo': 'Pelo código do cliente', 'doc': 'Pelo CPF/CNPJ', 'nome': 'Pelo nome', 'controladoria': 'Escolha da controladoria'
  };
  // os rótulos já usados nas outras telas (Comum.ROTULOS: categoria, grupo, natureza, status…) valem aqui também
  const rotComum = r => { const R = (window.Comum && window.Comum.ROTULOS) || {}; for (const g in R) if (R[g] && Object.prototype.hasOwnProperty.call(R[g], r)) return R[g][r]; return null; };
  const rotulo = r => ROTULOS[r] || rotComum(r) || (r.length > 1 && /_/.test(r) ? (r.charAt(0).toUpperCase() + r.slice(1)).replace(/_/g, ' ') : r.charAt(0).toUpperCase() + r.slice(1));
  const pct = (v, t) => t ? (v * 100 / t).toLocaleString('pt-BR', { maximumFractionDigits: 1 }) + '%' : '—';

  // até 6 fatias; o resto entra em "Outros" (sempre por último)
  function fatias(itens) {
    const ord = itens.slice().sort((a, b) => b.valor - a.valor);
    if (ord.length <= MAX_FATIAS) return ord.map((x, i) => ({ ...x, cls: 'fatia-' + (i + 1) }));
    const top = ord.slice(0, MAX_FATIAS - 1).map((x, i) => ({ ...x, cls: 'fatia-' + (i + 1) }));
    const resto = ord.slice(MAX_FATIAS - 1);
    top.push({ rotulo: `Outros (${resto.length})`, valor: resto.reduce((s, x) => s + Number(x.valor), 0), cls: 'fatia-outros', outros: resto });
    return top;
  }

  function el(tag, attrs) { const e = document.createElementNS(SVG, tag); for (const k in attrs) e.setAttribute(k, attrs[k]); return e; }

  function pizza(g, dica) {
    const lista = fatias(g.itens.map(x => ({ rotulo: rotulo(String(x.rotulo)), valor: Number(x.valor) })));
    const total = lista.reduce((s, x) => s + x.valor, 0);
    const R = 80, C = 90;
    const svg = el('svg', { viewBox: '0 0 180 180', class: 'pizza', role: 'img',
      'aria-label': g.titulo + ': ' + lista.map(x => `${x.rotulo} ${x.valor} (${pct(x.valor, total)})`).join('; ') });
    let ang = -Math.PI / 2;
    for (const f of lista) {
      const frac = f.valor / total;
      let forma;
      if (frac >= 0.9999) forma = el('circle', { cx: C, cy: C, r: R });
      else {
        const a2 = ang + frac * 2 * Math.PI;
        const p = (a) => (C + R * Math.cos(a)).toFixed(2) + ' ' + (C + R * Math.sin(a)).toFixed(2);
        forma = el('path', { d: `M ${C} ${C} L ${p(ang)} A ${R} ${R} 0 ${frac > 0.5 ? 1 : 0} 1 ${p(a2)} Z` });
        ang = a2;
      }
      forma.setAttribute('class', 'fatia ' + f.cls);
      forma.setAttribute('tabindex', '0');
      const texto = `${f.rotulo}: ${num(f.valor)} (${pct(f.valor, total)})`;
      forma.addEventListener('mousemove', ev => dica.mostrar(texto, ev.clientX, ev.clientY));
      forma.addEventListener('mouseleave', () => dica.esconder());
      forma.addEventListener('focus', () => { const r = forma.getBoundingClientRect(); dica.mostrar(texto, r.left + r.width / 2, r.top + r.height / 2); });
      forma.addEventListener('blur', () => dica.esconder());
      svg.append(forma);
    }
    const legenda = h('ul', { class: 'legenda' }, lista.map(f => h('li', { title: f.outros ? f.outros.map(o => `${o.rotulo}: ${num(o.valor)}`).join('\n') : null },
      h('span', { class: 'amostra ' + f.cls, 'aria-hidden': 'true' }), h('span', { class: 'legenda-rotulo' }, f.rotulo),
      h('span', { class: 'legenda-valor' }, num(f.valor)), h('span', { class: 'legenda-pct' }, pct(f.valor, total)))));
    // tabela completa (sem agrupar "Outros")
    const todas = g.itens.map(x => ({ rotulo: rotulo(String(x.rotulo)), valor: Number(x.valor) })).sort((a, b) => b.valor - a.valor);
    const tab = h('details', { class: 'pizza-tabela' }, h('summary', {}, 'Ver tabela'),
      UI.tabela([{ titulo: 'Item', valor: x => x.rotulo }, { titulo: 'Quantidade', num: true, valor: x => num(x.valor) },
        { titulo: '%', num: true, valor: x => pct(x.valor, total) }], todas, { compacta: true }));
    return h('div', { class: 'pizza-corpo' }, svg, h('div', {}, legenda, h('p', { class: 'pizza-total' }, 'Total: ', h('strong', {}, num(total))), tab));
  }

  function criarDica() {
    const d = h('div', { class: 'dica-grafico', role: 'tooltip', hidden: true });
    document.body.append(d);
    return {
      mostrar(t, x, y) { d.textContent = t; d.hidden = false; d.style.left = Math.min(x + 12, window.innerWidth - d.offsetWidth - 8) + 'px'; d.style.top = (y + 14) + 'px'; },
      esconder() { d.hidden = true; },
      remover() { d.remove(); }
    };
  }

  function cartaoGrafico(g, dica) {
    const cab = h('div', { class: 'grafico-cab' }, h('h3', {}, g.titulo),
      h('span', { class: 'etiqueta-base' + (g.base === 'no período' ? ' etiqueta-periodo' : '') }, g.base === 'no período' ? 'No período' : 'Situação atual'));
    return h('section', { class: 'cartao grafico' }, cab,
      g.itens.length ? pizza(g, dica) : h('p', { class: 'sutil vazio-grafico' }, g.base === 'no período' ? 'Nada registrado no período.' : 'Nada registrado.'));
  }

  // bloco do relatório; idArea = id do menu
  function bloco(ctx, idArea, nomeArea) {
    if (!AREAS_COM_RELATORIO.includes(idArea) || !['admin', 'diretoria'].includes(ctx.perfil.papel)) return null;
    const f = { inicio: somaDias(hojeISO(), -30), fim: hojeISO() };
    const corpo = h('div', { class: 'relatorio-corpo', 'aria-live': 'polite' });
    const ini = h('input', { type: 'date', value: f.inicio, 'aria-label': 'Início do período' });
    const fim = h('input', { type: 'date', value: f.fim, 'aria-label': 'Fim do período' });
    const atalhos = [['7 dias', 7], ['30 dias', 30], ['90 dias', 90]].map(([t, n]) => h('button', { type: 'button', class: 'btn btn-sec btn-peq', onclick: () => {
      ini.value = somaDias(hojeISO(), -n); fim.value = hojeISO(); carregar(); } }, t));
    const btnImp = h('button', { type: 'button', class: 'btn btn-sec btn-peq', onclick: imprimir }, 'Imprimir / PDF');
    const det = h('details', { class: 'relatorio cartao', 'data-area': idArea },
      h('summary', {}, h('span', { class: 'relatorio-titulo' }, 'Relatório gerencial'), h('span', { class: 'sutil relatorio-dica' }, ' indicadores e gráficos desta área')),
      h('div', { class: 'relatorio-filtros' },
        h('label', {}, 'De ', ini), h('label', {}, 'até ', fim),
        h('button', { type: 'button', class: 'btn btn-peq', onclick: () => carregar() }, 'Atualizar'), ...atalhos, btnImp),
      h('p', { class: 'relatorio-imp-cab' }, ''),
      corpo);
    let dica = null, carregado = false, seq = 0;
    det.addEventListener('toggle', () => { if (det.open && !carregado) carregar(); });

    async function carregar() {
      const n = ++seq; carregado = true;
      corpo.textContent = ''; corpo.append(h('p', { class: 'sutil' }, 'Carregando…'));
      const { data: r, error } = await ctx.sb.rpc('relatorio_gerencial', { p_area: idArea, p_inicio: ini.value || null, p_fim: fim.value || null });
      if (n !== seq) return;
      corpo.textContent = '';
      if (error) { corpo.append(aviso('erro', msgErro(error))); return; }
      if (!dica) dica = criarDica();
      det.querySelector('.relatorio-imp-cab').textContent =
        `${nomeArea} — período de ${data(r.periodo.de)} a ${data(r.periodo.ate)} — gerado em ${new Date(r.gerado_em).toLocaleString('pt-BR', { timeZone: 'America/Sao_Paulo' })}`;
      corpo.append(
        h('p', { class: 'sutil relatorio-periodo' }, `Período: ${data(r.periodo.de)} a ${data(r.periodo.ate)}. "Situação atual" é o retrato de agora; "no período" segue as datas escolhidas.`),
        h('div', { class: 'kpis relatorio-kpis' }, r.indicadores.map(k => h('div', { class: 'kpi kpi-estatico' },
          h('span', { class: 'kpi-rotulo' }, k.rotulo), h('span', { class: 'kpi-valor' }, num(k.valor))))),
        h('div', { class: 'graficos' }, r.graficos.map(g => cartaoGrafico(g, dica))));
    }
    function imprimir() {
      const vai = () => {
        document.body.classList.add('imprimindo-relatorio'); det.classList.add('relatorio-impresso');
        det.querySelectorAll('.pizza-tabela').forEach(t => { t.dataset.aberta = t.open ? '1' : ''; t.open = true; });
        const fim = () => {
          document.body.classList.remove('imprimindo-relatorio'); det.classList.remove('relatorio-impresso');
          det.querySelectorAll('.pizza-tabela').forEach(t => { t.open = t.dataset.aberta === '1'; });
          window.removeEventListener('afterprint', fim);
        };
        window.addEventListener('afterprint', fim);
        window.print();
      };
      if (!det.open) { det.open = true; }
      if (!carregado) carregar().then(vai); else vai();
    }
    // a dica fica no body: some quando a área for trocada
    window.addEventListener('hashchange', () => { if (dica) { dica.remover(); dica = null; } }, { once: true });
    return det;
  }

  // coloca o bloco logo abaixo do título da área (h1 e subtítulo/descrição), assim que a área montar o título
  let anexos = 0;
  function anexar(raiz, ctx, area) {
    const vez = String(++anexos); raiz.dataset.relatorioVez = vez;   // a área pode ser trocada antes do título aparecer
    const b = bloco(ctx, area.id, area.nome);
    if (!b) return;
    const valendo = () => raiz.dataset.relatorioVez === vez;
    const colocar = () => {
      if (!valendo()) return true;
      if (b.isConnected) return true;
      const h1 = raiz.querySelector(':scope > h1');
      if (!h1) return false;
      let ref = h1;
      while (ref.nextElementSibling && ref.nextElementSibling.matches('p.subtitulo, p.sutil')) ref = ref.nextElementSibling;
      ref.after(b);
      return true;
    };
    if (colocar()) return;
    const obs = new MutationObserver(() => { if (colocar()) obs.disconnect(); });
    obs.observe(raiz, { childList: true });
    setTimeout(() => { obs.disconnect(); if (valendo() && !b.isConnected && raiz.isConnected) raiz.prepend(b); }, 8000);
  }

  window.Relatorios = { anexar, bloco, fatias, AREAS: AREAS_COM_RELATORIO };
})();
