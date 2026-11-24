-- =====================================================================
-- 0041 — Double check Webjur × Atlas e relatório diário de inconsistências (pedido da
-- Dra. Mariana, item 3; 11/11/2026). Aditiva. O double check Webjur × ADVBOX (0024) continua.
-- Fontes:
--   * Webjur: publicações importadas no painel (CSV da DW pelo portal; e-mail como contingência);
--   * Atlas: intimações e prazos pela API (list_deadlines), espelhados em atlas_intimacoes.
-- A rotina do fim do expediente (Edge Function atlas-sync, ação fim_expediente; agendamento na
-- 0042) sincroniza tarefas e intimações do Atlas e roda esta conferência. Também pode ser
-- rodada pelo painel. Tipos de inconsistência:
--   intimacao_nao_cadastrada · divergencia · prazo_nao_lancado · prazo_incorreto ·
--   publicacao_duplicada · pendencia_controladoria
-- Cada inconsistência tem chave estável: reaparece atualizada nas execuções seguintes e é
-- marcada "regularizada" sozinha quando some (corrigida no Atlas). A controladoria pode
-- justificar (com nota) o que não precisa de correção.
-- =====================================================================

insert into public.parametros (chave, valor, confirmado, descricao) values
 ('dc_atlas_janela_dias', '7', false, 'Double check Webjur × Atlas: quantos dias corridos para trás (data de disponibilização) cada execução confere.'),
 ('dc_atlas_tolerancia_dias', '1', false, 'Diferença máxima, em dias, entre a disponibilização na Webjur e no Atlas para considerar a mesma intimação.'),
 ('fim_expediente_horario', '"18:30"', false, 'Horário (Brasília, dias úteis) da rotina automática do fim do expediente (0042).')
on conflict (chave) do nothing;

-- ---------------------------------------------------------------- espelho das intimações do Atlas
create table if not exists public.atlas_intimacoes (
  id                    uuid primary key,
  cnj                   text,
  process_number        text,
  court                 text,
  available_date        date,
  publication_date      date,
  status                text,
  handled_origin        text,
  duplicate_status      text,
  duplicate_of_id       uuid,
  needs_manual_review   boolean,
  needs_mandatory_confirmation boolean,
  inferred_type         text,
  client_id             uuid,
  client_name           text,
  client_match_status   text,
  lawsuit_id            uuid,
  deadline_fatal        date,
  deadline_suggested    date,
  deadline_confirmed_at timestamptz,
  tarefas               jsonb not null default '[]',
  responsaveis          jsonb not null default '[]',
  resumo                text,
  app_url               text,
  atlas_updated_at      timestamptz,
  dados                 jsonb not null,
  sincronizada_em       timestamptz not null default now()
);
create index if not exists atlas_intimacoes_cnj_idx on public.atlas_intimacoes (cnj, available_date);
alter table public.atlas_intimacoes enable row level security;
revoke all on public.atlas_intimacoes from anon, authenticated;
grant select on public.atlas_intimacoes to authenticated;
drop policy if exists atlas_intimacoes_leitura on public.atlas_intimacoes;
create policy atlas_intimacoes_leitura on public.atlas_intimacoes for select to authenticated using (public.pode_ler_tudo());

create or replace function public.atlas_registrar_intimacoes(p_itens jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not is_admin() then raise exception 'Somente a controladoria' using errcode = '42501'; end if;
  if jsonb_typeof(p_itens) <> 'array' then raise exception 'Lista de intimações inválida'; end if;
  insert into atlas_intimacoes (id, cnj, process_number, court, available_date, publication_date, status, handled_origin, duplicate_status,
         duplicate_of_id, needs_manual_review, needs_mandatory_confirmation, inferred_type, client_id, client_name, client_match_status,
         lawsuit_id, deadline_fatal, deadline_suggested, deadline_confirmed_at, tarefas, responsaveis, resumo, app_url, atlas_updated_at,
         dados, sincronizada_em)
  select (i->>'id')::uuid, normalizar_cnj(i->>'process_number'), i->>'process_number', i->>'court',
         (i->>'available_date')::date, (i->>'publication_date')::date, i->>'status', i->>'handled_origin', i->>'duplicate_status',
         nullif(i->>'duplicate_of_id', '')::uuid, (i->>'needs_manual_review')::boolean, (i->>'needs_mandatory_confirmation')::boolean,
         i->>'inferred_type', nullif(i->>'client_id', '')::uuid, i->>'client_name', i->>'client_match_status',
         nullif(i->>'lawsuit_id', '')::uuid, (i->'deadline'->>'fatal_date')::date, (i->'deadline'->>'suggested_date')::date,
         (i->'deadline'->>'confirmed_at')::timestamptz, coalesce(i->'tasks', '[]'), coalesce(i->'responsibles', '[]'),
         left(i->>'summary', 500), i->>'app_url', (i->>'updated_at')::timestamptz, i, now()
    from jsonb_array_elements(p_itens) i
   where i->>'id' ~* '^[0-9a-f-]{36}$'
  on conflict (id) do update set cnj = excluded.cnj, process_number = excluded.process_number, court = excluded.court,
         available_date = excluded.available_date, publication_date = excluded.publication_date, status = excluded.status,
         handled_origin = excluded.handled_origin, duplicate_status = excluded.duplicate_status, duplicate_of_id = excluded.duplicate_of_id,
         needs_manual_review = excluded.needs_manual_review, needs_mandatory_confirmation = excluded.needs_mandatory_confirmation,
         inferred_type = excluded.inferred_type, client_id = excluded.client_id, client_name = excluded.client_name,
         client_match_status = excluded.client_match_status, lawsuit_id = excluded.lawsuit_id, deadline_fatal = excluded.deadline_fatal,
         deadline_suggested = excluded.deadline_suggested, deadline_confirmed_at = excluded.deadline_confirmed_at,
         tarefas = excluded.tarefas, responsaveis = excluded.responsaveis, resumo = excluded.resumo, app_url = excluded.app_url,
         atlas_updated_at = excluded.atlas_updated_at, dados = excluded.dados, sincronizada_em = now();
  get diagnostics n = row_count;
  return jsonb_build_object('registradas', n, 'ultima_atualizacao', (select max(atlas_updated_at) from atlas_intimacoes));
end $$;

-- ponto de partida da próxima sincronização incremental
create or replace function public.atlas_intimacoes_desde() returns timestamptz
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Somente a controladoria' using errcode = '42501'; end if;
  return (select max(atlas_updated_at) from atlas_intimacoes);
end $$;

-- ---------------------------------------------------------------- produtividade (Atlas get_productivity) para a diretoria
create table if not exists public.atlas_produtividade (
  id              bigint generated always as identity primary key,
  coleta          timestamptz not null default now(),
  de              date not null,
  ate             date not null,
  user_id         uuid,
  nome            text,
  ativo           boolean,
  tarefas_concluidas int,
  dias_ativos     int,
  dados           jsonb not null
);
create index if not exists atlas_produtividade_coleta_idx on public.atlas_produtividade (coleta desc);
alter table public.atlas_produtividade enable row level security;
revoke all on public.atlas_produtividade from anon, authenticated;
grant select on public.atlas_produtividade to authenticated;
drop policy if exists atlas_produtividade_leitura on public.atlas_produtividade;
create policy atlas_produtividade_leitura on public.atlas_produtividade for select to authenticated using (public.pode_ler_tudo());

create or replace function public.atlas_registrar_produtividade(p_de date, p_ate date, p_membros jsonb) returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not is_admin() then raise exception 'Somente a controladoria' using errcode = '42501'; end if;
  insert into atlas_produtividade (de, ate, user_id, nome, ativo, tarefas_concluidas, dias_ativos, dados)
  select p_de, p_ate, nullif(m->>'user_id', '')::uuid, m->>'name', (m->>'active')::boolean, (m->>'tasks_completed')::int,
         (m->>'active_days')::int, m
    from jsonb_array_elements(coalesce(p_membros, '[]')) m;
  get diagnostics n = row_count;
  return n;
end $$;

-- painel da diretoria: última coleta, com capacidade média (tarefas concluídas por dia ativo)
create or replace function public.diretoria_produtividade() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_coleta timestamptz;
begin
  if not public.pode_ler_tudo() then raise exception 'Somente a diretoria e a controladoria' using errcode = '42501'; end if;
  select max(coleta) into v_coleta from atlas_produtividade;
  return jsonb_build_object('coleta', v_coleta,
    'periodo', (select jsonb_build_object('de', min(de), 'ate', max(ate)) from atlas_produtividade where coleta = v_coleta),
    'membros', coalesce((select jsonb_agg(jsonb_build_object('nome', p.nome, 'ativo', p.ativo, 'tarefas_concluidas', p.tarefas_concluidas,
                 'dias_ativos', p.dias_ativos,
                 'media_por_dia_ativo', case when coalesce(p.dias_ativos, 0) > 0 then round(p.tarefas_concluidas::numeric / p.dias_ativos, 1) end,
                 'colaborador', c.nome_advbox, 'pendentes_agora', (select count(*) from v_tarefas_atuais v
                                                                  where v.responsavel_id = c.id and v.situacao = 'pendente'))
                 order by p.tarefas_concluidas desc nulls last, p.nome)
              from atlas_produtividade p left join colaboradores c on c.atlas_user_id = p.user_id
             where p.coleta = v_coleta), '[]'));
end $$;

-- ---------------------------------------------------------------- inconsistências e relatório diário
create table if not exists public.relatorios_diarios (
  id            bigint generated always as identity primary key,
  dia           date not null,
  origem        text not null check (origem in ('automatico','manual')),
  executado_em  timestamptz not null default now(),
  executado_por uuid,
  resumo        jsonb not null
);
create index if not exists relatorios_diarios_dia_idx on public.relatorios_diarios (dia desc, executado_em desc);
alter table public.relatorios_diarios enable row level security;
revoke all on public.relatorios_diarios from anon, authenticated;
grant select on public.relatorios_diarios to authenticated;
drop policy if exists relatorios_diarios_leitura on public.relatorios_diarios;
create policy relatorios_diarios_leitura on public.relatorios_diarios for select to authenticated using (public.pode_ler_tudo());
drop trigger if exists relatorios_diarios_imutavel on public.relatorios_diarios;
create trigger relatorios_diarios_imutavel before update or delete on public.relatorios_diarios
  for each row execute function public.tg_bloqueia_alteracao();

create table if not exists public.inconsistencias (
  id                 bigint generated always as identity primary key,
  chave              text not null unique,
  tipo               text not null check (tipo in ('intimacao_nao_cadastrada','divergencia','prazo_nao_lancado','prazo_incorreto',
                                                   'publicacao_duplicada','pendencia_controladoria')),
  gravidade          int not null check (gravidade between 1 and 3),
  dia                date,
  cnj                text,
  publicacao_id      bigint references public.publicacoes(id),
  atlas_intimacao_id uuid,
  atlas_tarefa_id    uuid,
  descricao          text not null,
  acao_sugerida      text,
  dados              jsonb not null default '{}',
  situacao           text not null default 'aberta' check (situacao in ('aberta','regularizada','justificada')),
  primeira_vez_em    timestamptz not null default now(),
  ultima_vez_em      timestamptz not null default now(),
  tratada_por        uuid,
  tratada_em         timestamptz,
  nota               text
);
create index if not exists inconsistencias_situacao_idx on public.inconsistencias (situacao, gravidade, dia);
alter table public.inconsistencias enable row level security;
revoke all on public.inconsistencias from anon, authenticated;
grant select on public.inconsistencias to authenticated;
drop policy if exists inconsistencias_leitura on public.inconsistencias;
create policy inconsistencias_leitura on public.inconsistencias for select to authenticated using (public.pode_ler_tudo());

create table if not exists public.inconsistencias_historico (
  id               bigint generated always as identity primary key,
  inconsistencia_id bigint not null references public.inconsistencias(id),
  situacao_de      text,
  situacao_para    text not null,
  por              uuid,
  nota             text,
  em               timestamptz not null default now()
);
alter table public.inconsistencias_historico enable row level security;
revoke all on public.inconsistencias_historico from anon, authenticated;
grant select on public.inconsistencias_historico to authenticated;
drop policy if exists inconsistencias_hist_leitura on public.inconsistencias_historico;
create policy inconsistencias_hist_leitura on public.inconsistencias_historico for select to authenticated using (public.pode_ler_tudo());
drop trigger if exists inconsistencias_hist_imutavel on public.inconsistencias_historico;
create trigger inconsistencias_hist_imutavel before update or delete on public.inconsistencias_historico
  for each row execute function public.tg_bloqueia_alteracao();

create or replace function public.double_check_atlas_executar(p_dia date default null, p_origem text default 'manual') returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_dia date := coalesce(p_dia, hoje_brasilia()); v_ini date; v_tol int := param_int('dc_atlas_tolerancia_dias');
        v_novas int; v_regs int; v_resumo jsonb; v_ult_sync timestamptz; f constant text := 'DD/MM/YYYY';
begin
  if not is_admin() then raise exception 'Somente a controladoria' using errcode = '42501'; end if;
  if p_origem not in ('manual','automatico') then raise exception 'Origem inválida'; end if;
  v_ini := v_dia - param_int('dc_atlas_janela_dias');
  select max(sincronizada_em) into v_ult_sync from atlas_intimacoes;

  create temporary table if not exists _inc (chave text primary key, tipo text, gravidade int, dia date, cnj text, publicacao_id bigint,
    atlas_intimacao_id uuid, atlas_tarefa_id uuid, descricao text, acao text, dados jsonb) on commit drop;
  truncate _inc;
  create temporary table if not exists _pub on commit drop as select id, cnj, data_disponibilizacao d, teor, tribunal from publicacoes limit 0;
  truncate _pub;
  insert into _pub select id, cnj, data_disponibilizacao, teor, tribunal from publicacoes
   where data_disponibilizacao between v_ini and v_dia;

  -- 5a) duplicidade na Webjur: mesmo processo, mesmo dia, mesmo texto (fica a primeira)
  insert into _inc select 'dup_webjur|' || b.id, 'publicacao_duplicada', 3, b.d, b.cnj, b.id, null, null,
         'Publicação repetida na Webjur (mesmo processo, mesma disponibilização, mesmo texto da publicação #' || a.id || ').',
         'Conferir e desconsiderar a cópia.', jsonb_build_object('publicacao_original', a.id)
    from _pub b join lateral (select a.id from _pub a where a.cnj = b.cnj and a.d = b.d and a.id < b.id
                                and teor_semelhanca(a.teor, b.teor) >= 0.95 order by a.id limit 1) a on true
   where b.cnj is not null
  on conflict (chave) do nothing;

  -- 1) publicação da Webjur sem intimação correspondente no Atlas
  insert into _inc select 'nao_cadastrada|' || p.id, 'intimacao_nao_cadastrada', 1, p.d, p.cnj, p.id, null, null,
         'Publicação de ' || to_char(p.d, f) || ' (processo ' || p.cnj || ') não encontrada nas intimações do Atlas.',
         'Cadastrar a intimação no Atlas ou conferir a captura do Atlas.', jsonb_build_object('tribunal', p.tribunal)
    from _pub p
   where p.cnj is not null
     and not exists (select 1 from _inc x where x.chave = 'dup_webjur|' || p.id)
     and not exists (select 1 from atlas_intimacoes a where a.cnj = p.cnj
                       and coalesce(a.available_date, a.publication_date) between p.d - v_tol and p.d + v_tol)
  on conflict (chave) do nothing;
  insert into _inc select 'sem_cnj|' || p.id, 'pendencia_controladoria', 2, p.d, null, p.id, null, null,
         'Publicação de ' || to_char(p.d, f) || ' sem número de processo válido: não dá para conferir no Atlas.',
         'Identificar o processo manualmente.', '{}'::jsonb
    from _pub p where p.cnj is null
  on conflict (chave) do nothing;

  -- 2) divergências entre a publicação e a intimação do Atlas
  insert into _inc select 'div_data|' || p.id || '|' || a.id, 'divergencia', 2, p.d, p.cnj, p.id, a.id, null,
         'Data de disponibilização diferente: Webjur ' || to_char(p.d, f) || ' × Atlas ' || to_char(a.available_date, f) || '.',
         'Conferir a data da intimação no Atlas (afeta a contagem do prazo).', jsonb_build_object('atlas', a.app_url)
    from _pub p join atlas_intimacoes a on a.cnj = p.cnj and a.available_date between p.d - v_tol and p.d + v_tol
   where a.available_date <> p.d
     and not exists (select 1 from atlas_intimacoes a2 where a2.cnj = p.cnj and a2.available_date = p.d)
  on conflict (chave) do nothing;
  insert into _inc select 'div_cliente|' || a.id, 'divergencia', 2, a.available_date, a.cnj, null, a.id, null,
         'Intimação do processo ' || coalesce(a.cnj, a.process_number, '?') || ' sem cliente confirmado no Atlas ('
           || coalesce(a.client_match_status, 'sem vínculo') || ').',
         'Vincular a intimação ao cliente e ao processo no Atlas.', jsonb_build_object('atlas', a.app_url)
    from atlas_intimacoes a
   where coalesce(a.available_date, a.publication_date) between v_ini and v_dia and coalesce(a.status, '') <> 'arquivada'
     and (a.client_id is null or coalesce(a.client_match_status, '') <> 'confirmado')
  on conflict (chave) do nothing;

  -- 3) prazo não lançado: intimação com prazo e sem tarefa
  insert into _inc select 'prazo_sem_tarefa|' || a.id, 'prazo_nao_lancado', 1, a.available_date, a.cnj, null, a.id, null,
         'Intimação com prazo' || coalesce(' (fatal ' || to_char(a.deadline_fatal, f) || ')', '') || ' sem tarefa no Atlas.',
         'Criar a tarefa do prazo no Atlas.', jsonb_build_object('atlas', a.app_url, 'tipo_inferido', a.inferred_type)
    from atlas_intimacoes a
   where (a.deadline_fatal is not null or a.inferred_type = 'prazo')
     and coalesce(a.status, '') <> 'arquivada' and not (a.status = 'tratada' and a.handled_origin = 'nao_necessita')
     and a.duplicate_status is null
     and jsonb_array_length(a.tarefas) = 0
     and (coalesce(a.available_date, a.publication_date) >= v_ini or a.status in ('nao_lida','lida'))
  on conflict (chave) do nothing;

  -- 4) prazo lançado incorretamente: a tarefa não traz o prazo fatal calculado, ou vence depois dele
  insert into _inc select 'prazo_incorreto|' || a.id || '|' || (t->>'id'), 'prazo_incorreto', 1, a.available_date, a.cnj, null, a.id,
         nullif(t->>'id', '')::uuid,
         'Tarefa "' || coalesce(t->>'title', '?') || '": ' ||
           case when nullif(t->>'fatal_date', '') is null then 'sem prazo fatal; o Atlas calculou ' || to_char(a.deadline_fatal, f)
                when (t->>'fatal_date')::date <> a.deadline_fatal then 'prazo fatal ' || to_char((t->>'fatal_date')::date, f)
                                                                     || ' diferente do calculado na intimação (' || to_char(a.deadline_fatal, f) || ')'
                else 'vencimento ' || to_char((t->>'due_date')::date, f) || ' depois do prazo fatal ' || to_char(a.deadline_fatal, f) end || '.',
         'Corrigir o prazo da tarefa no Atlas (prazo processual: só a controladoria altera).',
         jsonb_build_object('atlas', a.app_url, 'tarefa', t)
    from atlas_intimacoes a cross join lateral jsonb_array_elements(a.tarefas) t
   where a.deadline_fatal is not null and coalesce(a.status, '') <> 'arquivada' and coalesce(t->>'status', '') <> 'done'
     and (nullif(t->>'fatal_date', '') is null or (t->>'fatal_date')::date <> a.deadline_fatal
          or (nullif(t->>'due_date', '') is not null and (t->>'due_date')::date > a.deadline_fatal))
  on conflict (chave) do nothing;

  -- 5b) duplicidade apontada pelo próprio Atlas e ainda não arquivada
  insert into _inc select 'dup_atlas|' || a.id, 'publicacao_duplicada', 3, a.available_date, a.cnj, null, a.id, null,
         'O Atlas marcou a intimação como duplicada (' || a.duplicate_status || ') e ela não foi arquivada.',
         'Conferir e arquivar a duplicata no Atlas.', jsonb_build_object('atlas', a.app_url, 'original', a.duplicate_of_id)
    from atlas_intimacoes a where a.duplicate_status is not null and coalesce(a.status, '') <> 'arquivada'
  on conflict (chave) do nothing;

  -- 6) pendências que precisam da controladoria
  insert into _inc select 'revisao|' || a.id, 'pendencia_controladoria', 2, a.available_date, a.cnj, null, a.id, null,
         case when a.needs_mandatory_confirmation then 'Prazo da intimação aguarda confirmação obrigatória no Atlas.'
              else 'Intimação marcada pelo Atlas para revisão manual.' end,
         'Revisar a intimação no Atlas.', jsonb_build_object('atlas', a.app_url)
    from atlas_intimacoes a
   where coalesce(a.status, '') not in ('arquivada','tratada') and (a.needs_manual_review or a.needs_mandatory_confirmation)
  on conflict (chave) do nothing;
  insert into _inc select 'nao_tratada|' || a.id, 'pendencia_controladoria', case when a.deadline_fatal <= v_dia + 3 then 1 else 2 end,
         a.available_date, a.cnj, null, a.id, null,
         'Intimação de ' || to_char(a.available_date, f) || ' ainda ' || case when a.status = 'nao_lida' then 'não lida' else 'lida e sem tratamento' end
           || ' no fim do expediente' || coalesce(' (prazo fatal ' || to_char(a.deadline_fatal, f) || ')', '') || '.',
         'Ler e tratar a intimação no Atlas.', jsonb_build_object('atlas', a.app_url)
    from atlas_intimacoes a where a.available_date < v_dia and a.duplicate_status is null
     and (a.status = 'nao_lida'
          or (a.status = 'lida' and jsonb_array_length(a.tarefas) = 0 and a.deadline_fatal is null and coalesce(a.inferred_type, '') <> 'prazo'))
  on conflict (chave) do nothing;
  if not exists (select 1 from publicacoes_coletas k join publicacoes p on p.id = k.publicacao_id
                  where (k.coletado_em at time zone 'America/Sao_Paulo')::date = v_dia) then
    insert into _inc values ('webjur_nao_importada|' || v_dia, 'pendencia_controladoria', 1, v_dia, null, null, null, null,
           'A planilha da Webjur (DW) de ' || to_char(v_dia, f) || ' ainda não foi importada: as publicações do dia não foram conferidas.',
           'Importar o CSV da Webjur no painel (Publicações Webjur) e rodar a conferência de novo.', '{}')
    on conflict (chave) do nothing;
  end if;
  if v_ult_sync is null or (v_ult_sync at time zone 'America/Sao_Paulo')::date < v_dia then
    insert into _inc values ('atlas_sem_sync|' || v_dia, 'pendencia_controladoria', 1, v_dia, null, null, null, null,
           'As intimações do Atlas não foram sincronizadas hoje' || coalesce(' (última: ' || to_char(v_ult_sync at time zone 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI') || ')', '') || '.',
           'Rodar "Sincronizar intimações" ou a rotina do fim do expediente.', '{}')
    on conflict (chave) do nothing;
  end if;

  -- gravação: novas, atualizadas e regularizadas (as que sumiram)
  with novas as (
    insert into inconsistencias (chave, tipo, gravidade, dia, cnj, publicacao_id, atlas_intimacao_id, atlas_tarefa_id, descricao, acao_sugerida, dados)
    select chave, tipo, gravidade, dia, cnj, publicacao_id, atlas_intimacao_id, atlas_tarefa_id, descricao, acao, dados from _inc
    on conflict (chave) do update set gravidade = excluded.gravidade, descricao = excluded.descricao, acao_sugerida = excluded.acao_sugerida,
           dados = excluded.dados, ultima_vez_em = now(),
           situacao = case when inconsistencias.situacao = 'regularizada' then 'aberta' else inconsistencias.situacao end
    returning (xmax = 0) as nova, id, situacao)
  select count(*) filter (where nova) into v_novas from novas;
  insert into inconsistencias_historico (inconsistencia_id, situacao_de, situacao_para, por, nota)
  select i.id, null, 'aberta', auth.uid(), 'Encontrada na conferência'
    from inconsistencias i where i.ultima_vez_em = i.primeira_vez_em and i.chave in (select chave from _inc)
     and not exists (select 1 from inconsistencias_historico h where h.inconsistencia_id = i.id);
  with reg as (
    update inconsistencias i set situacao = 'regularizada', tratada_em = now(), tratada_por = auth.uid(),
           nota = 'Não apareceu mais na conferência (corrigida no Atlas ou na Webjur).'
     where i.situacao = 'aberta' and i.chave not in (select chave from _inc)
       and (i.dia is null or i.dia >= v_ini or i.tipo in ('prazo_nao_lancado','prazo_incorreto','pendencia_controladoria','divergencia','publicacao_duplicada'))
    returning i.id)
  insert into inconsistencias_historico (inconsistencia_id, situacao_de, situacao_para, por, nota)
  select id, 'aberta', 'regularizada', auth.uid(), 'Regularizada automaticamente' from reg;
  get diagnostics v_regs = row_count;

  v_resumo := jsonb_build_object('dia', v_dia, 'janela_de', v_ini, 'publicacoes_conferidas', (select count(*) from _pub),
    'intimacoes_atlas', (select count(*) from atlas_intimacoes where coalesce(available_date, publication_date) between v_ini and v_dia),
    'ultima_sincronizacao_atlas', v_ult_sync, 'novas', v_novas, 'regularizadas', v_regs,
    'abertas', (select count(*) from inconsistencias where situacao = 'aberta'),
    'por_tipo', (select coalesce(jsonb_object_agg(tipo, n), '{}') from (select tipo, count(*) n from inconsistencias where situacao = 'aberta' group by tipo) z),
    'criticas', (select count(*) from inconsistencias where situacao = 'aberta' and gravidade = 1));
  insert into relatorios_diarios (dia, origem, executado_por, resumo) values (v_dia, p_origem, auth.uid(), v_resumo);
  return v_resumo;
end $$;

create or replace function public.inconsistencia_tratar(p_id bigint, p_situacao text, p_nota text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_de text;
begin
  if not is_admin() then raise exception 'Somente a controladoria' using errcode = '42501'; end if;
  if p_situacao not in ('justificada','aberta','regularizada') then raise exception 'Situação inválida: %', p_situacao; end if;
  if length(btrim(coalesce(p_nota, ''))) < 10 then raise exception 'Registre a nota (mínimo 10 caracteres)'; end if;
  select situacao into v_de from inconsistencias where id = p_id for update;
  if not found then raise exception 'Inconsistência % inexistente', p_id; end if;
  update inconsistencias set situacao = p_situacao, nota = btrim(p_nota), tratada_por = auth.uid(), tratada_em = now() where id = p_id;
  insert into inconsistencias_historico (inconsistencia_id, situacao_de, situacao_para, por, nota) values (p_id, v_de, p_situacao, auth.uid(), btrim(p_nota));
  return (select to_jsonb(i) from inconsistencias i where id = p_id);
end $$;

create or replace function public.relatorio_inconsistencias(p_situacao text default 'aberta', p_tipo text default null, p_limite int default 1000)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.pode_ler_tudo() then raise exception 'Somente a controladoria e a diretoria' using errcode = '42501'; end if;
  return jsonb_build_object(
    'ultimo_relatorio', (select to_jsonb(r) from relatorios_diarios r order by r.executado_em desc limit 1),
    'execucoes', (select coalesce(jsonb_agg(to_jsonb(r) order by r.executado_em desc), '[]') from (select * from relatorios_diarios order by executado_em desc limit 10) r),
    'por_tipo', (select coalesce(jsonb_object_agg(tipo, n), '{}') from (select tipo, count(*) n from inconsistencias
                  where (p_situacao is null or situacao = p_situacao) group by tipo) z),
    'itens', (select coalesce(jsonb_agg(to_jsonb(x) order by x.gravidade, x.dia nulls last, x.id), '[]') from (
                select i.*, u.email as tratada_por_email from inconsistencias i left join auth.users u on u.id = i.tratada_por
                 where (p_situacao is null or i.situacao = p_situacao) and (p_tipo is null or i.tipo = p_tipo)
                 order by i.gravidade, i.dia nulls last, i.id limit greatest(coalesce(p_limite, 1000), 1)) x));
end $$;

-- painel da diretoria: visão consolidada das pendências
create or replace function public.diretoria_resumo() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.pode_ler_tudo() then raise exception 'Somente a diretoria e a controladoria' using errcode = '42501'; end if;
  return jsonb_build_object(
    'inconsistencias_abertas', (select count(*) from inconsistencias where situacao = 'aberta'),
    'inconsistencias_criticas', (select count(*) from inconsistencias where situacao = 'aberta' and gravidade = 1),
    'solicitacoes_aguardando', (select count(*) from solicitacoes where status = 'aguardando_controladoria'),
    'solicitacoes_mes', (select count(*) from solicitacoes where criada_em >= date_trunc('month', now())),
    'excecoes_d4_ativas', (select count(*) from (select distinct on (tarefa_id) valor_novo from eventos where tipo = 'excecao_d4'
                                                   order by tarefa_id, ocorrido_em desc) z where (valor_novo->>'ativa')::boolean),
    'modalidades_ativas', (select count(*) from modalidades where ativa),
    'ultimo_relatorio', (select to_jsonb(r) from relatorios_diarios r order by r.executado_em desc limit 1),
    'produtividade', public.diretoria_produtividade());
end $$;

revoke execute on function public.atlas_registrar_intimacoes(jsonb), public.atlas_intimacoes_desde(),
  public.atlas_registrar_produtividade(date, date, jsonb), public.diretoria_produtividade(),
  public.double_check_atlas_executar(date, text), public.inconsistencia_tratar(bigint, text, text),
  public.relatorio_inconsistencias(text, text, int), public.diretoria_resumo() from public, anon;
grant execute on function public.atlas_registrar_intimacoes(jsonb), public.atlas_intimacoes_desde(),
  public.atlas_registrar_produtividade(date, date, jsonb), public.diretoria_produtividade(),
  public.double_check_atlas_executar(date, text), public.inconsistencia_tratar(bigint, text, text),
  public.relatorio_inconsistencias(text, text, int), public.diretoria_resumo() to authenticated;

-- ---------------------------------------------------------------- log: a rotina automática (chave de serviço) também registra
create or replace function public.registrar_log_integracao(
  p_origem text, p_nivel text, p_operacao text, p_mensagem text, p_detalhe jsonb default '{}')
returns bigint language plpgsql security definer set search_path = public as $$
declare v_id bigint;
begin
  if not (public._eh_servico() or exists (select 1 from perfis where user_id = auth.uid())) then   -- 0041
    raise exception 'Usuário sem perfil na controladoria' using errcode = '42501';
  end if;
  insert into log_integracao (origem, nivel, operacao, mensagem, detalhe, usuario)
  values (p_origem, p_nivel, p_operacao, p_mensagem, coalesce(p_detalhe,'{}'), auth.uid()) returning id into v_id;
  if p_nivel = 'erro' then
    insert into eventos (chave_dedupe, tipo, ocorrido_em, precisao_ocorrido, origem, historico_recuperado, classificacao, evidencia)
    values ('log:'||v_id, 'erro_integracao', now(), 'segundo', 'sistema', false, 'confirmado',
            jsonb_build_object('log_id',v_id,'origem',p_origem,'operacao',p_operacao,'mensagem',p_mensagem));
  end if;
  return v_id;
end $$;
revoke execute on function public.registrar_log_integracao(text, text, text, text, jsonb) from public, anon, authenticated;

-- mensagem do log conforme a operação
create or replace function public.atlas_registrar(p_operacao text, p_nivel text, p_detalhe jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Somente a controladoria' using errcode = '42501'; end if;
  if p_nivel not in ('info','aviso','erro') then raise exception 'Nível inválido'; end if;
  perform registrar_log_integracao('atlas_api', p_nivel, left(coalesce(p_operacao,''), 60),
    case when p_nivel = 'erro' then coalesce(p_detalhe->>'mensagem', 'Erro na API do Atlas')
         when p_operacao = 'sincronizar' then 'Sincronização com o Atlas: ' || coalesce(p_detalhe->>'tarefas','?') || ' tarefas'
         when p_operacao = 'sincronizar_intimacoes' then 'Intimações do Atlas: ' || coalesce(p_detalhe->>'intimacoes','?') || ' sincronizadas'
         when p_operacao = 'padronizar_descricoes' then 'Descrições padronizadas: ' || coalesce(p_detalhe->>'gravadas','0') || ' gravadas, '
                                                        || coalesce(p_detalhe->>'puladas','0') || ' puladas, ' || coalesce(p_detalhe->>'erros','0') || ' erros'
         when p_operacao = 'fim_expediente' then 'Rotina do fim do expediente' || case when p_nivel = 'aviso' then ' (com falhas em alguma etapa)' else ' concluída' end
         else 'Atlas: ' || coalesce(p_operacao, '?') end,
    coalesce(p_detalhe, '{}'));
end $$;
