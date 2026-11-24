-- =====================================================================
-- Controladoria Jurídica — Oliveira e Camilo
-- 0001 — Esquema base (PostgreSQL / Supabase)
--
-- Princípios aplicados:
--  * Sem API do ADVBOX. Fontes: (a) Excel exportado; (b) extensão (fase posterior).
--  * Toda informação guarda ORIGEM e momento de coleta.
--  * Dado importado nunca é corrigido: divergências são registradas à parte.
--  * Quatro referências de prazo separadas: D-7 (data da agenda),
--    D-4 (entrega interna), PF Judicial e PF da Tarefa.
--  * Sem exclusão de importações, sem exportação CSV, sem edição manual
--    de cadastros (escopo excluído intencionalmente).
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- Parâmetros centrais (regras do escritório). "confirmado" = validado
-- pela coordenação. Regras não confirmadas são exibidas como tal.
-- ---------------------------------------------------------------------
create table public.parametros (
  chave          text primary key,
  valor          jsonb not null,
  confirmado     boolean not null default false,
  descricao      text not null,
  atualizado_em  timestamptz not null default now(),
  atualizado_por uuid
);

-- ---------------------------------------------------------------------
-- Perfis de acesso (ligados ao Supabase Auth)
-- ---------------------------------------------------------------------
create table public.colaboradores (
  id             bigint generated always as identity primary key,
  nome_advbox    text not null unique,      -- nome exatamente como no Excel
  handle_advbox  text unique,               -- ex.: mayragomes (visto em "@x encaminhou")
  origem         text not null default 'excel_importacao'
                 check (origem in ('excel_importacao','administrativo')),
  criado_em      timestamptz not null default now()
);

create table public.perfis (
  user_id        uuid primary key,          -- auth.users.id
  papel          text not null check (papel in ('admin','colaborador')),
  colaborador_id bigint references public.colaboradores(id),
  criado_em      timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- Calendário de dias não úteis
-- abrangencia: nacional | tribunal (código J.TR do CNJ, ex. 8.13 = TJMG)
-- ---------------------------------------------------------------------
create table public.calendario_dias_nao_uteis (
  id             bigint generated always as identity primary key,
  data           date not null,
  abrangencia    text not null check (abrangencia in ('nacional','tribunal')),
  tribunal_cnj   text,                      -- obrigatório se abrangencia = tribunal
  tipo           text not null check (tipo in ('feriado','recesso','suspensao','ponto_facultativo')),
  descricao      text not null,
  fundamento     text,                      -- lei/ato que fundamenta
  criado_em      timestamptz not null default now(),
  criado_por     uuid,
  check ((abrangencia = 'nacional' and tribunal_cnj is null)
      or (abrangencia = 'tribunal' and tribunal_cnj ~ '^\d\.\d{2}$'))
);
create unique index calendario_unq
  on public.calendario_dias_nao_uteis (data, abrangencia, coalesce(tribunal_cnj,''));

-- ---------------------------------------------------------------------
-- Importações
-- Um LOTE = uma "fotografia" da base exportada. Quando a exportação
-- exceder 1.000 linhas, vários arquivos entram no MESMO lote.
-- ---------------------------------------------------------------------
create table public.lotes_importacao (
  id               bigint generated always as identity primary key,
  criado_em        timestamptz not null default now(),
  criado_por       uuid,
  data_exportacao  timestamptz,             -- momento da exportação no ADVBOX (informado/derivado do nome)
  descricao        text
);

create table public.importacoes (
  id               bigint generated always as identity primary key,
  lote_id          bigint not null references public.lotes_importacao(id),
  nome_arquivo     text not null,
  hash_arquivo     text not null unique,    -- mesmo arquivo não é importado duas vezes
  importado_em     timestamptz not null default now(),
  importado_por    uuid,
  status           text not null default 'processando'
                   check (status in ('processando','concluida','rejeitada')),
  total_linhas     int,
  linhas_validas   int,
  linhas_rejeitadas int,
  linhas_duplicadas int,                    -- repetidas dentro do lote (ignoradas)
  tarefas_novas    int,
  tarefas_vinculadas int,                   -- já conhecidas, vinculadas por chave
  linhas_ambiguas  int,                     -- sem identificação segura (não vinculadas)
  mensagem         text
);

-- Cada linha do Excel, preservada integralmente (dados_brutos) e interpretada.
create table public.linhas_importadas (
  id                  bigint generated always as identity primary key,
  importacao_id       bigint not null references public.importacoes(id),
  lote_id             bigint not null references public.lotes_importacao(id),
  numero_linha        int not null,          -- linha da planilha (cabeçalho = 1)
  dados_brutos        jsonb not null,
  hash_linha          text not null,
  situacao            text not null check (situacao in ('valida','rejeitada','duplicada')),
  erros               jsonb not null default '[]',

  -- campos interpretados (nomes do ADVBOX entre parênteses)
  prioridade          text,                  -- (Prioridade)
  data_agenda         date,                  -- (Data)  -> D-7 nos prazos de 15 dias
  hora_agenda         time,                  -- (Hora)
  termino             timestamptz,           -- (Término + Hora Término)
  pf_tarefa           date,                  -- (Prazo fatal) -> PF da Tarefa
  data_conclusao      timestamptz,           -- (Data Conclusão)
  pontuacao           int,                   -- (Pontuação)
  compromisso         text,                  -- (Compromisso)
  local               text,                  -- (Local)
  remetente_id        bigint references public.colaboradores(id),    -- (Remetente)
  responsavel_id      bigint references public.colaboradores(id),    -- (Destinatário)
  partes              text,                  -- (Partes)
  processo_cnj        text,                  -- (Processo (CNJ))
  tribunal_cnj        text,                  -- derivado do CNJ: J.TR
  protocolo           text,                  -- (Protocolo)
  tipo_acao           text,                  -- (Tipo de ação)
  observacoes         text,                  -- (Observações)

  -- extraído das anotações em Observações (origem: texto, não validado)
  pf_judicial_anotado      date,
  pf_judicial_anotado_txt  text,
  d4_anotado               date,
  d4_anotado_txt           text,
  prazo_dias_anotado       int,

  -- identificação
  chave_estavel       text,                  -- impressão digital sem campos que mudam na realocação
  tarefa_id           bigint,                -- FK adicionada abaixo
  metodo_vinculo      text check (metodo_vinculo in ('chave_estavel','chave_ocorrencia','ambigua')),
  unique (importacao_id, numero_linha)
);
create index on public.linhas_importadas (lote_id, situacao);
create index on public.linhas_importadas (lote_id, hash_linha);
create index on public.linhas_importadas (chave_estavel);
create index on public.linhas_importadas (responsavel_id);

-- Identidade da tarefa ao longo das importações.
-- O Excel do ADVBOX NÃO traz identificador da tarefa. A chave abaixo é
-- uma estratégia documentada (ver docs/IDENTIFICACAO.md); quando a
-- extensão capturar o ID real do ADVBOX ele é gravado em advbox_id.
create table public.tarefas (
  id                  bigint generated always as identity primary key,
  chave_identificacao text not null unique,
  metodo              text not null check (metodo in ('chave_estavel','chave_ocorrencia','advbox_id')),
  advbox_id           text unique,               -- ID real (posts/{id}) visto pela extensão
  vinculo_excel       text check (vinculo_excel in ('excel_unico','sem_correspondencia','ambiguo')),
  criada_em_advbox    timestamptz,               -- "Criado por ... dd/mm/aaaa hh:mm" lido na tela (1ª observação; não muda)
  criada_por_advbox   text,
  primeira_vez_vista  timestamptz not null default now(),
  ultima_linha_id     bigint
);
alter table public.linhas_importadas
  add constraint linhas_tarefa_fk foreign key (tarefa_id) references public.tarefas(id);

-- ---------------------------------------------------------------------
-- Eventos (trilha de auditoria append-only)
-- ---------------------------------------------------------------------
create table public.eventos (
  id                 uuid primary key default gen_random_uuid(),
  chave_dedupe       text not null unique,   -- impede o mesmo evento duas vezes
  tarefa_id          bigint references public.tarefas(id),
  linha_id           bigint references public.linhas_importadas(id),
  tipo               text not null check (tipo in (
                       'encaminhamento',             -- "@x encaminhou para @y em ..."
                       'anotacao_realocacao',        -- "MG - dd/mm - Tarefa realocada"
                       'pedido_reagendamento',       -- comentário pedindo reagendar/realocar
                       'alteracao_data_agenda',      -- observada entre importações
                       'alteracao_pf_tarefa',        -- observada entre importações
                       'alteracao_responsavel',      -- observada entre importações
                       'conclusao',                  -- Data Conclusão no Excel
                       'inicio_tratativa',           -- extensão (fase 7)
                       'tentativa_conclusao',        -- extensão (fase 8)
                       'tentativa_realocacao',       -- extensão (fase 8)
                       'tentativa_alteracao_pf',     -- extensão (fase 8)
                       'importacao')),
  ocorrido_em        timestamptz,            -- quando aconteceu (se conhecido)
  precisao_ocorrido  text not null check (precisao_ocorrido in ('segundo','minuto','dia','entre_importacoes','desconhecida')),
  observado_em       timestamptz not null default now(),  -- quando o sistema registrou
  colaborador_id     bigint references public.colaboradores(id),
  colaborador_txt    text,                   -- autor como aparece na fonte (iniciais/handle)
  valor_anterior     jsonb,
  valor_novo         jsonb,
  justificativa      text,
  origem             text not null check (origem in (
                       'excel_campo','excel_observacoes','comparacao_importacoes',
                       'extensao','sistema','administrativo')),
  historico_recuperado boolean not null,     -- true = evento anterior à implantação, lido do texto
  classificacao      text not null check (classificacao in ('confirmado','potencial','anotado')),
  estado_trava       text check (estado_trava in (
                       'bloqueio_efetivo','permitida_apos_validacao','excecao_autorizada',
                       'violacao_detectada','nao_monitorada')),
  evidencia          jsonb not null default '{}'
);
create index on public.eventos (tarefa_id, tipo);
create index on public.eventos (tipo, ocorrido_em);

-- ---------------------------------------------------------------------
-- Imutabilidade: auditoria e importações não podem ser apagadas/alteradas
-- ---------------------------------------------------------------------
create or replace function public.tg_bloqueia_alteracao() returns trigger
language plpgsql as $$
begin
  raise exception 'Registro de auditoria/importação é imutável (% em %)', tg_op, tg_table_name;
end $$;

create trigger eventos_imutavel before update or delete on public.eventos
  for each row execute function public.tg_bloqueia_alteracao();
create trigger linhas_sem_delete before delete on public.linhas_importadas
  for each row execute function public.tg_bloqueia_alteracao();
create trigger importacoes_sem_delete before delete on public.importacoes
  for each row execute function public.tg_bloqueia_alteracao();
create trigger lotes_sem_delete before delete on public.lotes_importacao
  for each row execute function public.tg_bloqueia_alteracao();

-- importação só pode ser atualizada enquanto está "processando"
create or replace function public.tg_importacao_fechada() returns trigger
language plpgsql as $$
begin
  if old.status <> 'processando' then
    raise exception 'Importação % já encerrada; não pode ser alterada', old.id;
  end if;
  return new;
end $$;
create trigger importacoes_fechada before update on public.importacoes
  for each row execute function public.tg_importacao_fechada();

-- linhas: só podem receber o vínculo de tarefa (uma vez); dados não mudam
create or replace function public.tg_linha_imutavel() returns trigger
language plpgsql as $$
begin
  if (to_jsonb(new) - 'tarefa_id' - 'metodo_vinculo') <> (to_jsonb(old) - 'tarefa_id' - 'metodo_vinculo')
     or (old.metodo_vinculo is not null) then
    raise exception 'Linha importada % é imutável', old.id;
  end if;
  return new;
end $$;
create trigger linhas_imutavel before update on public.linhas_importadas
  for each row execute function public.tg_linha_imutavel();
