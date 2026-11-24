-- =====================================================================
-- 0040 — Planejamento da pauta e solicitações dos líderes (pedido da Dra. Mariana, item 4;
-- 11/11/2026). Aditiva.
-- O líder pede, pelo painel, uma tarefa nova ou um reagendamento para um advogado da equipe.
-- Antes de enviar, o sistema analisa a pauta do advogado:
--   * carga de cada dia (pontos de complexidade das tarefas pendentes; modalidade, 0039);
--   * capacidade diária (por advogado, ou o padrão do escritório);
--   * prazos internos (D-4) e processuais (PF Judicial), prioridade e complexidade;
-- e sugere qual tarefa pode ser remanejada, para qual dia, com a justificativa.
-- Critérios de segurança (nunca são sugeridos): tarefa urgente; D-4 já atingido; nova data
-- depois do D-4 (com folga mínima) ou do prazo fatal; tarefa sem dia livre na janela.
-- Aprovação: quando o reagendamento envolve PF Judicial ou passa do D-4, a solicitação vai
-- para a CONTROLADORIA aprovar. Nos demais casos fica aprovada pela autoridade do líder.
-- Execução no Atlas pela API (create_task / edit_task / add_task_comment), pela Edge Function.
-- =====================================================================

insert into public.parametros (chave, valor, confirmado, descricao) values
 ('capacidade_pontos_dia', '6', false,
  'Capacidade diária padrão de um advogado, em pontos de complexidade (soma dos pontos das modalidades das tarefas do dia; tarefa sem modalidade = 1 ponto). '
  'Pode ser ajustada por advogado. PROVISÓRIO: confirmar com a coordenação.'),
 ('planejamento_janela_dias_uteis', '10', false, 'Quantos dias úteis à frente o planejamento procura dia livre para remanejar uma tarefa.'),
 ('planejamento_folga_minima_dias_uteis', '1', false,
  'Folga mínima, em dias úteis, entre a nova data da tarefa remanejada e o D-4 (ou o prazo fatal, se não houver D-4).'),
 ('tarefa_sem_modalidade_pontos', '1', false, 'Pontos de complexidade de uma tarefa sem modalidade reconhecida.')
on conflict (chave) do nothing;

create table if not exists public.capacidade_colaborador (
  id             bigint generated always as identity primary key,
  colaborador_id bigint not null unique references public.colaboradores(id),
  pontos_dia     int not null check (pontos_dia between 1 and 50),
  em             timestamptz not null default now()
);
alter table public.capacidade_colaborador enable row level security;
revoke all on public.capacidade_colaborador from anon, authenticated;
grant select on public.capacidade_colaborador to authenticated;
drop policy if exists capacidade_leitura on public.capacidade_colaborador;
create policy capacidade_leitura on public.capacidade_colaborador for select to authenticated using (true);
drop trigger if exists capacidade_colaborador_auditoria on public.capacidade_colaborador;
create trigger capacidade_colaborador_auditoria after insert or update or delete on public.capacidade_colaborador
  for each row execute function public.tg_auditar_configuracao();

create or replace function public.admin_definir_capacidade(p_colaborador bigint, p_pontos int, p_motivo text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Somente administradores' using errcode = '42501'; end if;
  perform _exigir_motivo(p_motivo);
  if p_pontos is null then delete from capacidade_colaborador where colaborador_id = p_colaborador;
  else
    insert into capacidade_colaborador (colaborador_id, pontos_dia) values (p_colaborador, p_pontos)
    on conflict (colaborador_id) do update set pontos_dia = excluded.pontos_dia, em = now();
  end if;
  return jsonb_build_object('colaborador_id', p_colaborador, 'pontos_dia', p_pontos);
end $$;

create or replace function public._capacidade(p_colaborador bigint) returns int
language sql stable security definer set search_path = public as $$
  select coalesce((select pontos_dia from capacidade_colaborador where colaborador_id = p_colaborador), param_int('capacidade_pontos_dia'))
$$;

create or replace function public._pontos_tarefa(p_tarefa bigint) returns int
language sql stable security definer set search_path = public as $$
  select coalesce((select m.pontos from modalidades m where m.id = public.modalidade_da_tarefa(p_tarefa)), param_int('tarefa_sem_modalidade_pontos'))
$$;

-- quem pode planejar a pauta de um advogado: controladoria e o líder da equipe dele
create or replace function public._pode_planejar(p_colaborador bigint) returns boolean
language sql stable security definer set search_path = public as $$
  select public.is_admin() or coalesce(public.meu_papel() = 'lider' and p_colaborador = any (public.meus_colaboradores()), false)
$$;

-- ---------------------------------------------------------------- análise da pauta
-- p_data: dia em que a nova tarefa (ou a tarefa reagendada) entra; p_pontos: complexidade dela.
-- p_ignorar: tarefa a não contar na carga (a que está sendo reagendada).
create or replace function public.analisar_pauta(p_colaborador bigint, p_data date, p_pontos int default null,
                                                 p_urgente boolean default false, p_ignorar bigint default null)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare v_hoje date := hoje_brasilia(); v_cap int; v_jan int := param_int('planejamento_janela_dias_uteis');
        v_folga int := param_int('planejamento_folga_minima_dias_uteis'); v_dia date; v_fim date;
        v_pontos int := coalesce(p_pontos, param_int('tarefa_sem_modalidade_pontos'));
        v_dias jsonb; v_carga_dia int; v_excesso int; v_cand jsonb := '[]'; v_bloq jsonb := '[]';
        r record; v_lim date; v_nova date; v_ok boolean; v_motivo text; v_just text; f constant text := 'DD/MM/YYYY';
begin
  if not public._pode_planejar(p_colaborador) then
    raise exception 'Somente a controladoria e o líder da equipe do advogado' using errcode = '42501';
  end if;
  if p_data is null then raise exception 'Informe a data'; end if;
  if p_data < v_hoje then raise exception 'A data não pode ser anterior a hoje'; end if;
  v_cap := public._capacidade(p_colaborador);
  v_fim := somar_dias_uteis(p_data, v_jan);

  create temporary table if not exists _pauta (tarefa_id bigint, compromisso text, dia date, d4 date, pf_judicial date, pf_tarefa date,
                                               prioridade text, pontos int, atlas_id uuid) on commit drop;
  truncate _pauta;
  insert into _pauta
  select v.tarefa_id, v.compromisso, greatest(coalesce(v.d7_data_agenda, v_hoje), v_hoje), v.d4, v.pf_judicial, v.pf_tarefa,
         v.prioridade, public._pontos_tarefa(v.tarefa_id), t.atlas_id
    from v_tarefas_atuais v left join tarefas t on t.id = v.tarefa_id
   where v.situacao = 'pendente' and v.responsavel_id = p_colaborador and v.tarefa_id is not null
     and (p_ignorar is null or public._tarefa_principal(v.tarefa_id) <> public._tarefa_principal(p_ignorar));

  -- carga por dia útil na janela
  select coalesce(jsonb_agg(jsonb_build_object('dia', d, 'carga', c, 'capacidade', v_cap,
            'tarefas', (select coalesce(jsonb_agg(jsonb_build_object('tarefa_id', tarefa_id, 'compromisso', compromisso, 'pontos', pontos)
                               order by pontos desc), '[]') from _pauta where dia = d)) order by d), '[]')
    into v_dias
    from (select g::date d, coalesce((select sum(pontos) from _pauta where dia = g::date), 0)::int c
            from generate_series(p_data, v_fim, interval '1 day') g where e_dia_util(g::date, null, null)) x;

  v_carga_dia := coalesce((select sum(pontos) from _pauta where dia = p_data), 0);
  v_excesso := greatest(v_carga_dia + v_pontos - v_cap, 0);

  if v_excesso > 0 then
    for r in select * from _pauta where dia = p_data order by pontos desc, compromisso loop
      v_motivo := null; v_nova := null;
      v_lim := coalesce(somar_dias_uteis(r.d4, -v_folga), somar_dias_uteis(r.pf_tarefa, -v_folga), v_fim);
      if r.prioridade ilike 'urg%' then v_motivo := 'tarefa urgente';
      elsif r.d4 is not null and r.d4 <= p_data then v_motivo := 'D-4 (' || to_char(r.d4, f) || ') já atingido';
      elsif r.pf_judicial is not null and r.pf_judicial <= somar_dias_uteis(p_data, 2) then v_motivo := 'PF Judicial muito próximo (' || to_char(r.pf_judicial, f) || ')';
      else
        -- primeiro dia útil depois de p_data, dentro do limite, com espaço para a tarefa
        select d into v_nova from (
          select g::date d from generate_series(p_data + 1, least(v_lim, v_fim), interval '1 day') g
           where e_dia_util(g::date, null, null)
             and coalesce((select sum(pontos) from _pauta where dia = g::date), 0) + r.pontos <= v_cap) x
         order by d limit 1;
        if v_nova is null then v_motivo := 'sem dia com capacidade antes do ' || case when r.d4 is not null then 'D-4' when r.pf_tarefa is not null then 'prazo fatal' else 'fim da janela' end; end if;
      end if;
      if v_motivo is not null then
        v_bloq := v_bloq || jsonb_build_object('tarefa_id', r.tarefa_id, 'compromisso', r.compromisso, 'motivo', v_motivo);
        continue;
      end if;
      v_just := 'Remanejar "' || r.compromisso || '" (' || r.pontos || ' ponto(s)) de ' || to_char(p_data, f) || ' para ' || to_char(v_nova, f)
             || ': libera capacidade no dia (carga ' || v_carga_dia || ' + nova ' || v_pontos || ' de ' || v_cap || ' pontos). '
             || case when r.d4 is not null then 'A nova data fica ' || dias_uteis_entre(v_nova, r.d4) || ' dia(s) útil(eis) antes do D-4 (' || to_char(r.d4, f) || ')'
                     when r.pf_tarefa is not null then 'A nova data fica antes do prazo fatal (' || to_char(r.pf_tarefa, f) || ')'
                     else 'Tarefa sem prazo interno ou fatal' end
             || case when r.pf_judicial is not null then '; envolve prazo processual (PF Judicial ' || to_char(r.pf_judicial, f) || '): exige aprovação da controladoria.'
                     else '; prazo interno: o líder pode aprovar.' end;
      v_cand := v_cand || jsonb_build_object('tarefa_id', r.tarefa_id, 'atlas_id', r.atlas_id, 'compromisso', r.compromisso, 'pontos', r.pontos,
                  'data_de', p_data, 'data_para', v_nova, 'd4', r.d4, 'pf_judicial', r.pf_judicial, 'pf_tarefa', r.pf_tarefa,
                  'folga_dias_uteis', dias_uteis_entre(v_nova, v_lim), 'exige_controladoria', r.pf_judicial is not null,
                  'libera_o_suficiente', r.pontos >= v_excesso, 'justificativa', v_just);
    end loop;
    -- melhor primeiro: prazo interno antes de processual; libera o suficiente; maior folga
    select coalesce(jsonb_agg(c order by (c->>'exige_controladoria')::boolean, (c->>'libera_o_suficiente')::boolean desc,
                                         (c->>'folga_dias_uteis')::int desc, (c->>'pontos')::int), '[]')
      into v_cand from jsonb_array_elements(v_cand) c;
  end if;

  return jsonb_build_object(
    'colaborador_id', p_colaborador, 'colaborador', (select nome_advbox from colaboradores where id = p_colaborador),
    'data', p_data, 'pontos_novos', v_pontos, 'urgente', coalesce(p_urgente, false),
    'capacidade', v_cap, 'carga_no_dia', v_carga_dia, 'excesso', v_excesso, 'cabe_sem_remanejar', v_excesso = 0,
    'dias', v_dias, 'sugestoes', v_cand, 'nao_remanejaveis', v_bloq,
    'recomendacao', case when v_excesso = 0 then 'A pauta comporta a tarefa no dia ' || to_char(p_data, f) || ' sem remanejar nada.'
                         when jsonb_array_length(v_cand) > 0 then v_cand->0->>'justificativa'
                         else 'Nenhuma tarefa pode ser remanejada com segurança nesse dia: escolha outra data ou outro advogado, ou peça à controladoria.' end,
    'gerada_em', now());
end $$;

-- ---------------------------------------------------------------- solicitações
create table if not exists public.solicitacoes (
  id                   bigint generated always as identity primary key,
  tipo                 text not null check (tipo in ('nova_tarefa','reagendamento')),
  status               text not null check (status in ('aguardando_controladoria','aprovada','recusada','em_execucao','executada','falhou','cancelada')),
  solicitante          uuid,
  solicitante_papel    text,
  colaborador_id       bigint not null references public.colaboradores(id),
  dados                jsonb not null,
  remanejamento        jsonb,                -- sugestão escolhida (ou null)
  analise              jsonb,                -- fotografia da análise no envio
  justificativa        text not null,
  exige_controladoria  boolean not null,
  motivos_controladoria text[] not null default '{}',
  decidido_por         uuid,
  decidido_em          timestamptz,
  decisao_nota         text,
  resultado            jsonb,
  criada_em            timestamptz not null default now(),
  atualizada_em        timestamptz not null default now()
);
create index if not exists solicitacoes_status_idx on public.solicitacoes (status, criada_em desc);
alter table public.solicitacoes enable row level security;
revoke all on public.solicitacoes from anon, authenticated;
grant select on public.solicitacoes to authenticated;
drop policy if exists solicitacoes_leitura on public.solicitacoes;
create policy solicitacoes_leitura on public.solicitacoes for select to authenticated
  using (public.pode_ler_tudo() or solicitante = auth.uid() or colaborador_id = any ((select public.meus_colaboradores())::bigint[]));
drop trigger if exists solicitacoes_sem_delete on public.solicitacoes;
create trigger solicitacoes_sem_delete before delete on public.solicitacoes for each row execute function public.tg_bloqueia_alteracao();

create table if not exists public.solicitacoes_historico (
  id             bigint generated always as identity primary key,
  solicitacao_id bigint not null references public.solicitacoes(id),
  status_de      text,
  status_para    text not null,
  por            uuid,
  nota           text,
  em             timestamptz not null default now()
);
alter table public.solicitacoes_historico enable row level security;
revoke all on public.solicitacoes_historico from anon, authenticated;
grant select on public.solicitacoes_historico to authenticated;
drop policy if exists solicitacoes_hist_leitura on public.solicitacoes_historico;
create policy solicitacoes_hist_leitura on public.solicitacoes_historico for select to authenticated
  using (exists (select 1 from public.solicitacoes s where s.id = solicitacao_id));
drop trigger if exists solicitacoes_hist_imutavel on public.solicitacoes_historico;
create trigger solicitacoes_hist_imutavel before update or delete on public.solicitacoes_historico
  for each row execute function public.tg_bloqueia_alteracao();

create or replace function public._solicitacao_status(p_id bigint, p_para text, p_nota text default null) returns void
language plpgsql security definer set search_path = public as $$
declare v_de text;
begin
  select status into v_de from solicitacoes where id = p_id for update;
  update solicitacoes set status = p_para, atualizada_em = now() where id = p_id;
  insert into solicitacoes_historico (solicitacao_id, status_de, status_para, por, nota) values (p_id, v_de, p_para, auth.uid(), p_nota);
end $$;

-- p_dados (nova_tarefa): {titulo, descricao?, prioridade (normal|urgent), data, pf?, modalidade_id?}
-- p_dados (reagendamento): {tarefa_id, nova_data?, novo_colaborador_id?}
-- p_remanejamento: uma das sugestões de analisar_pauta (ou null)
create or replace function public.solicitacao_criar(p_tipo text, p_colaborador bigint, p_dados jsonb, p_remanejamento jsonb, p_justificativa text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_min int := param_int('justificativa_minimo_caracteres'); v_just text := btrim(regexp_replace(coalesce(p_justificativa, ''), '\s+', ' ', 'g'));
        v_motivos text[] := '{}'; v_id bigint; v_analise jsonb; v_data date; v_pontos int; v record; f constant text := 'DD/MM/YYYY';
        v_t bigint; v_sug jsonb; v_novo bigint;
begin
  if not public._pode_planejar(p_colaborador) then
    raise exception 'Somente a controladoria e o líder da equipe do advogado' using errcode = '42501';
  end if;
  if p_tipo not in ('nova_tarefa','reagendamento') then raise exception 'Tipo inválido: %', p_tipo; end if;
  if length(v_just) < v_min then raise exception 'Justificativa obrigatória (mínimo % caracteres)', v_min; end if;
  if p_tipo = 'nova_tarefa' then
    if length(btrim(coalesce(p_dados->>'titulo', ''))) < 3 then raise exception 'Título da tarefa obrigatório'; end if;
    v_data := (p_dados->>'data')::date;
    if v_data is null or v_data < hoje_brasilia() then raise exception 'Data da tarefa inválida'; end if;
    if coalesce(p_dados->>'prioridade', 'normal') not in ('normal','urgent') then raise exception 'Prioridade inválida'; end if;
    if (p_dados->>'pf')::date is not null and (p_dados->>'pf')::date < v_data then raise exception 'O prazo fatal não pode ser anterior à data da tarefa'; end if;
    v_pontos := coalesce((select pontos from modalidades where id = (p_dados->>'modalidade_id')::bigint), param_int('tarefa_sem_modalidade_pontos'));
    v_analise := public.analisar_pauta(p_colaborador, v_data, v_pontos, p_dados->>'prioridade' = 'urgent', null);
  else
    v_t := public._tarefa_principal((p_dados->>'tarefa_id')::bigint);
    select * into v from v_tarefas_atuais x where x.tarefa_id is not null and public._tarefa_principal(x.tarefa_id) = v_t and x.situacao = 'pendente' limit 1;
    if not found then raise exception 'Tarefa não encontrada entre as pendentes da base atual'; end if;
    if v.responsavel_id is distinct from p_colaborador then raise exception 'A tarefa não é do advogado informado'; end if;
    v_data := coalesce((p_dados->>'nova_data')::date, v.d7_data_agenda);
    v_novo := nullif(p_dados->>'novo_colaborador_id', '')::bigint;
    if (p_dados->>'nova_data') is null and v_novo is null then raise exception 'Informe a nova data ou o novo responsável'; end if;
    if v_data < hoje_brasilia() then raise exception 'A nova data não pode ser anterior a hoje'; end if;
    if v_novo is not null and not public._pode_planejar(v_novo) then raise exception 'O novo responsável precisa ser da sua equipe'; end if;
    if v.pf_judicial is not null then v_motivos := v_motivos || ('Tarefa com PF Judicial (' || to_char(v.pf_judicial, f) || ')'); end if;
    if v.d4 is not null and v_data > v.d4 and not public._excecao_d4_em(v_t) then
      v_motivos := v_motivos || ('Nova data depois do D-4 (' || to_char(v.d4, f) || ')');
    end if;
    if v.pf_tarefa is not null and v_data > v.pf_tarefa then raise exception 'A nova data não pode passar do prazo fatal (%)', to_char(v.pf_tarefa, f); end if;
    v_analise := public.analisar_pauta(coalesce(v_novo, p_colaborador), greatest(v_data, hoje_brasilia()), public._pontos_tarefa(v_t), false, v_t);
    p_dados := p_dados || jsonb_build_object('tarefa_id', v_t, 'data_atual', v.d7_data_agenda, 'compromisso', v.compromisso,
                 'd4', v.d4, 'pf_judicial', v.pf_judicial, 'atlas_id', (select atlas_id from tarefas where id = v_t));
  end if;
  -- o remanejamento escolhido precisa ser uma das sugestões da análise atual
  if p_remanejamento is not null then
    select s into v_sug from jsonb_array_elements(v_analise->'sugestoes') s
     where (s->>'tarefa_id')::bigint = (p_remanejamento->>'tarefa_id')::bigint limit 1;
    if v_sug is null then raise exception 'O remanejamento escolhido não está entre as sugestões seguras da análise'; end if;
    if (v_sug->>'exige_controladoria')::boolean then
      v_motivos := v_motivos || ('Remanejamento de tarefa com PF Judicial (' || to_char((v_sug->>'pf_judicial')::date, f) || ')');
    end if;
  end if;
  insert into solicitacoes (tipo, status, solicitante, solicitante_papel, colaborador_id, dados, remanejamento, analise, justificativa,
                            exige_controladoria, motivos_controladoria)
  values (p_tipo, case when cardinality(v_motivos) > 0 then 'aguardando_controladoria' else 'aprovada' end, auth.uid(), public.meu_papel(),
          p_colaborador, p_dados, v_sug, v_analise, v_just, cardinality(v_motivos) > 0, v_motivos)
  returning id into v_id;
  insert into solicitacoes_historico (solicitacao_id, status_de, status_para, por, nota)
  values (v_id, null, case when cardinality(v_motivos) > 0 then 'aguardando_controladoria' else 'aprovada' end, auth.uid(),
          case when cardinality(v_motivos) > 0 then 'Aguardando a controladoria: ' || array_to_string(v_motivos, '; ')
               else 'Aprovada pela autoridade do líder (prazo interno)' end);
  return (select to_jsonb(s) from solicitacoes s where id = v_id);
end $$;

create or replace function public.solicitacao_decidir(p_id bigint, p_aprovar boolean, p_nota text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_st text;
begin
  if not is_admin() then raise exception 'Somente a controladoria aprova' using errcode = '42501'; end if;
  if length(btrim(coalesce(p_nota, ''))) < 10 then raise exception 'Registre o motivo da decisão (mínimo 10 caracteres)'; end if;
  select status into v_st from solicitacoes where id = p_id for update;
  if v_st is distinct from 'aguardando_controladoria' then raise exception 'Só solicitações aguardando a controladoria podem ser decididas (atual: %)', v_st; end if;
  update solicitacoes set decidido_por = auth.uid(), decidido_em = now(), decisao_nota = btrim(p_nota) where id = p_id;
  perform _solicitacao_status(p_id, case when p_aprovar then 'aprovada' else 'recusada' end, btrim(p_nota));
  return (select to_jsonb(s) from solicitacoes s where id = p_id);
end $$;

create or replace function public.solicitacao_cancelar(p_id bigint, p_nota text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s solicitacoes;
begin
  if coalesce(public.meu_papel(), '') not in ('admin','lider','servico') then raise exception 'Somente líderes e a controladoria' using errcode = '42501'; end if;
  select * into s from solicitacoes where id = p_id for update;
  if s.id is null then raise exception 'Solicitação % inexistente', p_id; end if;
  if not (is_admin() or s.solicitante = auth.uid()) then raise exception 'Somente quem pediu ou a controladoria' using errcode = '42501'; end if;
  if s.status not in ('aguardando_controladoria','aprovada','falhou') then raise exception 'Solicitação % não pode mais ser cancelada (%)', p_id, s.status; end if;
  perform _solicitacao_status(p_id, 'cancelada', nullif(btrim(coalesce(p_nota, '')), ''));
  return (select to_jsonb(x) from solicitacoes x where id = p_id);
end $$;

-- operações no Atlas para executar a solicitação (a Edge Function executa e devolve o resultado)
create or replace function public.solicitacao_para_execucao(p_id bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s solicitacoes; v_ops jsonb := '[]'; v_atlas_user uuid; v_novo uuid; v_desc text; l linhas_importadas;
        v_linha text; f constant text := 'DD/MM/YYYY'; v_dest bigint;
begin
  if coalesce(public.meu_papel(), '') not in ('admin','lider','servico') then raise exception 'Somente líderes e a controladoria' using errcode = '42501'; end if;
  select * into s from solicitacoes where id = p_id for update;
  if s.id is null then raise exception 'Solicitação % inexistente', p_id; end if;
  if not (is_admin() or (s.solicitante = auth.uid() and public._pode_planejar(s.colaborador_id))) then
    raise exception 'Somente quem pediu ou a controladoria' using errcode = '42501';
  end if;
  if s.status not in ('aprovada','falhou') then raise exception 'Solicitação % não está aprovada (%)', p_id, s.status; end if;
  v_dest := coalesce(nullif(s.dados->>'novo_colaborador_id', '')::bigint, s.colaborador_id);
  select atlas_user_id into v_atlas_user from colaboradores where id = v_dest;
  if v_atlas_user is null then raise exception 'O advogado ainda não tem usuário do Atlas ligado (sincronize as tarefas)'; end if;
  v_linha := to_char(hoje_brasilia(), 'DD/MM') || ' - Tarefa realocada pela controladoria (solicitação #' || s.id || '): ' || s.justificativa;
  if s.tipo = 'nova_tarefa' then
    v_ops := v_ops || jsonb_build_object('op', 'create_task', 'idempotencia', 'controladoria-solic-' || s.id || '-nova',
      'data', jsonb_strip_nulls(jsonb_build_object('title', s.dados->>'titulo',
         'description', coalesce(nullif(s.dados->>'descricao', ''), '') || E'\n\nSolicitação #' || s.id || ' (planejamento da controladoria): ' || s.justificativa,
         'priority', coalesce(s.dados->>'prioridade', 'normal'), 'dueDate', s.dados->>'data', 'fatalDate', s.dados->>'pf',
         'assigneeUserId', v_atlas_user)));
  else
    l := public._linha_atual((s.dados->>'tarefa_id')::bigint);
    v_ops := v_ops || jsonb_build_object('op', 'edit_task', 'data', jsonb_strip_nulls(jsonb_build_object(
      'taskId', s.dados->>'atlas_id', 'dueDate', s.dados->>'nova_data',
      'assigneeUserId', case when s.dados->>'novo_colaborador_id' is not null then v_atlas_user::text end,
      'description', case when not coalesce((l.dados_brutos->>'_atlas_descricao_truncada')::boolean, true)
                          then coalesce(l.dados_brutos->>'_atlas_descricao', '') || E'\n' || v_linha end)));
    v_ops := v_ops || jsonb_build_object('op', 'add_task_comment', 'opcional', true,
      'data', jsonb_build_object('taskId', s.dados->>'atlas_id', 'body', v_linha));
  end if;
  if s.remanejamento is not null then
    l := public._linha_atual((s.remanejamento->>'tarefa_id')::bigint);
    v_linha := to_char(hoje_brasilia(), 'DD/MM') || ' - Tarefa realocada pela controladoria (solicitação #' || s.id || '): ' || (s.remanejamento->>'justificativa');
    v_ops := v_ops || jsonb_build_object('op', 'edit_task', 'data', jsonb_strip_nulls(jsonb_build_object(
      'taskId', s.remanejamento->>'atlas_id', 'dueDate', s.remanejamento->>'data_para',
      'description', case when not coalesce((l.dados_brutos->>'_atlas_descricao_truncada')::boolean, true)
                          then coalesce(l.dados_brutos->>'_atlas_descricao', '') || E'\n' || v_linha end)));
    v_ops := v_ops || jsonb_build_object('op', 'add_task_comment', 'opcional', true,
      'data', jsonb_build_object('taskId', s.remanejamento->>'atlas_id', 'body', v_linha));
  end if;
  if exists (select 1 from jsonb_array_elements(v_ops) o where o->>'op' = 'edit_task' and coalesce(o->'data'->>'taskId', '') = '') then
    raise exception 'Tarefa sem ID do Atlas: só tarefas sincronizadas do Atlas podem ser reagendadas pela API';
  end if;
  perform _solicitacao_status(p_id, 'em_execucao', null);
  return jsonb_build_object('id', s.id, 'operacoes', v_ops);
end $$;

create or replace function public.solicitacao_resultado(p_id bigint, p_ok boolean, p_resultado jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s solicitacoes; v_t bigint; f constant text := 'DD/MM/YYYY';
begin
  if coalesce(public.meu_papel(), '') not in ('admin','lider','servico') then raise exception 'Somente líderes e a controladoria' using errcode = '42501'; end if;
  select * into s from solicitacoes where id = p_id for update;
  if s.id is null then raise exception 'Solicitação % inexistente', p_id; end if;
  if not (is_admin() or s.solicitante = auth.uid()) then raise exception 'Somente quem pediu ou a controladoria' using errcode = '42501'; end if;
  if s.status <> 'em_execucao' then raise exception 'Solicitação % não está em execução (%)', p_id, s.status; end if;
  update solicitacoes set resultado = p_resultado where id = p_id;
  perform _solicitacao_status(p_id, case when p_ok then 'executada' else 'falhou' end,
                              case when p_ok then 'Executada no Atlas' else 'Falha no Atlas: ' || coalesce(p_resultado->>'erro', '?') end);
  if p_ok then
    -- registra os reagendamentos autorizados (aparecem em Reagendamentos com a justificativa)
    for v_t in select (x->>'tarefa_id')::bigint from (select case when s.tipo = 'reagendamento' then s.dados end x
                                                       union all select s.remanejamento) z where x is not null loop
      insert into eventos (chave_dedupe, tarefa_id, tipo, ocorrido_em, precisao_ocorrido, origem, historico_recuperado, classificacao,
                           colaborador_id, valor_anterior, valor_novo, justificativa, estado_trava, evidencia)
      values ('solic:' || s.id || ':' || v_t, v_t, 'tentativa_realocacao', now(), 'segundo', 'sistema', false, 'confirmado',
              (select colaborador_id from perfis where user_id = s.solicitante),
              to_jsonb(coalesce(case when s.tipo = 'reagendamento' and (s.dados->>'tarefa_id')::bigint = v_t then s.dados->>'data_atual' end,
                                s.remanejamento->>'data_de')),
              to_jsonb(coalesce(case when s.tipo = 'reagendamento' and (s.dados->>'tarefa_id')::bigint = v_t then s.dados->>'nova_data' end,
                                s.remanejamento->>'data_para')),
              case when s.tipo = 'reagendamento' and (s.dados->>'tarefa_id')::bigint = v_t then s.justificativa else s.remanejamento->>'justificativa' end,
              case when s.exige_controladoria then 'permitida_apos_validacao' else 'excecao_autorizada' end,
              jsonb_build_object('origem', 'atlas', 'solicitacao', s.id, 'aprovada_por', coalesce(s.decidido_por::text, 'lider'),
                                 'alteracoes', jsonb_build_array('data')))
      on conflict (chave_dedupe) do nothing;
    end loop;
  end if;
  return (select to_jsonb(x) from solicitacoes x where id = p_id);
end $$;

create or replace function public.solicitacoes_listar(p_status text default null, p_limite int default 200) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if public.meu_papel() is null then raise exception 'Usuário sem perfil na controladoria' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(x order by x.criada_em desc) from (
    select s.*, c.nome_advbox as colaborador, coalesce(cs.nome_advbox, us.email) as solicitante_nome, ud.email as decidido_por_email,
           (select coalesce(jsonb_agg(jsonb_build_object('de', h.status_de, 'para', h.status_para, 'nota', h.nota, 'em', h.em) order by h.em), '[]')
              from solicitacoes_historico h where h.solicitacao_id = s.id) as historico
      from solicitacoes s join colaboradores c on c.id = s.colaborador_id
      left join auth.users us on us.id = s.solicitante left join perfis ps on ps.user_id = s.solicitante
      left join colaboradores cs on cs.id = ps.colaborador_id left join auth.users ud on ud.id = s.decidido_por
     where (public.pode_ler_tudo() or s.solicitante = auth.uid() or s.colaborador_id = any (public.meus_colaboradores()))
       and (p_status is null or s.status = p_status)
     order by s.criada_em desc limit greatest(coalesce(p_limite, 200), 1)) x), '[]');
end $$;

-- advogados que a pessoa pode planejar (para o formulário)
create or replace function public.planejamento_colaboradores() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'nome', c.nome_advbox, 'equipe', e.nome, 'capacidade', public._capacidade(c.id),
                                               'atlas', c.atlas_user_id is not null) order by c.nome_advbox), '[]')
    from colaboradores c left join equipes e on e.id = c.equipe_id
   where public._pode_planejar(c.id) and c.nome_advbox not like 'SEM RESPONSÁVEL%' and c.nome_advbox not like 'ATLAS (%'
$$;

-- o líder também pode chamar a Edge Function para executar as solicitações dele
create or replace function public.atlas_conferir_acesso(p_acao text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if p_acao = 'executar_solicitacao' then
    if not (is_admin() or coalesce(public.meu_papel() = 'lider', false)) then raise exception 'Somente líderes e a controladoria' using errcode = '42501'; end if;
  elsif not is_admin() then raise exception 'Somente a controladoria usa a integração com o Atlas' using errcode = '42501';
  end if;
  if p_acao not in ('testar','sincronizar','criar_tarefa','executar_solicitacao','padronizar_descricoes','sincronizar_intimacoes','fim_expediente') then
    raise exception 'Ação desconhecida: %', p_acao;
  end if;
  return jsonb_build_object('ok', true, 'usuario', auth.uid());
end $$;

revoke execute on function public._capacidade(bigint), public._pontos_tarefa(bigint), public._solicitacao_status(bigint, text, text)
  from public, anon, authenticated;
revoke execute on function public._pode_planejar(bigint), public.admin_definir_capacidade(bigint, int, text),
  public.analisar_pauta(bigint, date, int, boolean, bigint), public.solicitacao_criar(text, bigint, jsonb, jsonb, text),
  public.solicitacao_decidir(bigint, boolean, text), public.solicitacao_cancelar(bigint, text), public.solicitacao_para_execucao(bigint),
  public.solicitacao_resultado(bigint, boolean, jsonb), public.solicitacoes_listar(text, int), public.planejamento_colaboradores()
  from public, anon;
grant execute on function public._pode_planejar(bigint), public.admin_definir_capacidade(bigint, int, text),
  public.analisar_pauta(bigint, date, int, boolean, bigint), public.solicitacao_criar(text, bigint, jsonb, jsonb, text),
  public.solicitacao_decidir(bigint, boolean, text), public.solicitacao_cancelar(bigint, text), public.solicitacao_para_execucao(bigint),
  public.solicitacao_resultado(bigint, boolean, jsonb), public.solicitacoes_listar(text, int), public.planejamento_colaboradores()
  to authenticated;
