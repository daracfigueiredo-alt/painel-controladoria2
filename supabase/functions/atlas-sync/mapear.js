// Conversão das tarefas do Atlas (list_tasks) para o formato de linha que a importação já usa
// (as mesmas 17 colunas do Excel do ADVBOX), mais os campos _atlas_* que identificam a tarefa.
// Módulo puro (sem rede): roda no Deno (Edge Function) e no Node (testes).

export const CABECALHO = ['Prioridade', 'Data', 'Hora', 'Término', 'Hora Término', 'Prazo fatal',
  'Data Conclusão', 'Pontuação', 'Compromisso', 'Local', 'Remetente', 'Destinatário', 'Partes',
  'Processo (CNJ)', 'Protocolo', 'Tipo de ação', 'Observações'];

export const SEM_RESPONSAVEL = 'SEM RESPONSÁVEL (ATLAS)';
export const CRIADOR_DESCONHECIDO = 'ATLAS (criador não identificado)';

const TZ = 'America/Sao_Paulo';
// mesma expressão da importação (0003): a última anotação "PF: dd/mm" das Observações vale como PF Judicial
const RE_PF = /(?:^|[^a-z])(?:PF|Prazo[ \t]+Fatal)[ \t]*:?[ \t]*\d{1,2}\/\d{1,2}/i;

// bloco padrão da controladoria (0039) dentro da descrição do Atlas
export const BLOCO_INICIO = '=== Controladoria Oliveira e Camilo (padrão) ===';
export const BLOCO_FIM = '=== fim do padrão da controladoria ===';
export function semBloco(texto) {
  const t = String(texto || '');
  const i = t.indexOf(BLOCO_INICIO); if (i < 0) return t;
  const j = t.indexOf(BLOCO_FIM, i);
  return (t.slice(0, i) + (j < 0 ? '' : t.slice(j + BLOCO_FIM.length))).replace(/\n{3,}/g, '\n\n').trim();
}
// descrição original + bloco novo (o texto do Atlas é preservado; o bloco antigo é trocado)
export function comBloco(descricao, bloco) {
  const base = semBloco(descricao);
  return (base ? base + '\n\n' : '') + bloco;
}

export function dataBr(iso) {               // 'AAAA-MM-DD' -> 'DD/MM/AAAA'
  if (!iso) return '';
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(iso));
  return m ? `${m[3]}/${m[2]}/${m[1]}` : '';
}

function partesBrasilia(instante) {
  const f = new Intl.DateTimeFormat('en-GB', { timeZone: TZ, year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', hourCycle: 'h23' });
  const p = Object.fromEntries(f.formatToParts(new Date(instante)).map(x => [x.type, x.value]));
  return p;
}
export function dataHoraBr(instante) {      // instante ISO -> 'DD/MM/AAAA HH:MM' (Brasília)
  if (!instante) return '';
  const p = partesBrasilia(instante);
  return `${p.day}/${p.month}/${p.year} ${p.hour}:${p.minute}`;
}
export function diaBr(instante) {
  if (!instante) return '';
  const p = partesBrasilia(instante);
  return `${p.day}/${p.month}/${p.year}`;
}

// usuários vistos nas tarefas (responsáveis com nome)
export function usuariosDasTarefas(tarefas) {
  const m = new Map();
  for (const t of tarefas) for (const a of t.assignees || []) {
    if (a.user_id && !m.has(a.user_id)) m.set(a.user_id, a.name || null);
  }
  return [...m].map(([id, name]) => ({ id, name }));
}

// nomes: { user_id: nome no sistema da controladoria } (resposta de atlas_mapear_usuarios)
export function tarefaParaLinha(t, nomes) {
  const principal = (t.assignees || []).find(a => a.is_principal) || (t.assignees || [])[0];
  const destinatario = principal ? (nomes[principal.user_id] || principal.name || SEM_RESPONSAVEL) : SEM_RESPONSAVEL;
  const remetente = (t.created_by && nomes[t.created_by]) || CRIADOR_DESCONHECIDO;
  let concl = '';
  if (t.status === 'done') {
    const baixas = (t.assignees || []).map(a => a.completed_at).filter(Boolean).sort();
    concl = dataHoraBr(baixas[baixas.length - 1] || t.updated_at);
  }
  let obs = semBloco(t.description || '');
  if (t.fatal_date && !RE_PF.test(obs)) obs = (obs ? obs + '\n\n' : '') + `[Atlas] PF: ${dataBr(t.fatal_date)}`;
  const linha = {
    'Prioridade': t.priority === 'urgent' ? 'URGENTE' : 'NORMAL',
    'Data': dataBr(t.due_date) || diaBr(t.created_at),
    'Hora': '', 'Término': '', 'Hora Término': '',
    'Prazo fatal': dataBr(t.fatal_date),
    'Data Conclusão': concl,
    'Pontuação': '',
    'Compromisso': t.title || '',
    'Local': '',
    'Remetente': remetente,
    'Destinatário': destinatario,
    'Partes': t.client_name || '',
    'Processo (CNJ)': t.source_intimacao_number || t.lawsuit_number || '',
    'Protocolo': '',
    'Tipo de ação': '',
    'Observações': obs,
    '_atlas_id': String(t.id).toLowerCase(),
    '_atlas_status': t.status,
    '_atlas_url': t.app_url || null,
    '_atlas_descricao': t.description || '',
    '_atlas_descricao_truncada': !!t.description_truncated,
    '_atlas_responsaveis': (t.assignees || []).map(a => ({ id: a.user_id, nome: a.name, principal: !!a.is_principal, baixa: a.completed_at })),
  };
  if (!t.due_date) linha['_atlas_sem_prazo'] = true;
  return linha;
}

// tarefas repetidas entre as consultas (abertas x concluídas) entram uma vez só
export function semRepetir(tarefas) {
  const m = new Map();
  for (const t of tarefas) if (!t.deleted_at) m.set(String(t.id).toLowerCase(), t);
  return [...m.values()];
}

export function emBlocos(lista, tamanho = 1000) {
  const r = [];
  for (let i = 0; i < lista.length; i += tamanho) r.push(lista.slice(i, i + tamanho));
  return r;
}
