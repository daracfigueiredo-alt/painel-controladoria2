-- =====================================================================
-- 0038 — Acessos por perfil (pedido da Dra. Mariana, item 6; 11/11/2026). Aditiva.
--   * Diretoria (novo papel 'diretoria'): acompanhamento geral, indicadores, produtividade e
--     pendências. Lê tudo o que a controladoria lê; não grava nada (as funções que gravam
--     continuam exigindo is_admin()).
--   * Controladoria ('admin'): como antes.
--   * Líderes ('lider'): passam a ver as tarefas das EQUIPES que lideram (lideres_equipes), além
--     das próprias. Solicitam tarefas e reagendamentos (0040).
--   * Peticionadores ('colaborador'): veem a própria pauta, com instruções, checklist,
--     documentos e validações (0039).
--   * Serviço (rotina automática do fim do expediente, 0041): o papel service_role do Supabase
--     é tratado como controladoria, sem usuário (auth.uid() nulo).
-- =====================================================================

alter table public.perfis drop constraint if exists perfis_papel_check;
alter table public.perfis add constraint perfis_papel_check check (papel in ('admin','colaborador','lider','diretoria'));

-- chamada pela rotina automática (Edge Function com a chave de serviço)
create or replace function public._eh_servico() returns boolean
language sql stable set search_path = public as $$
  select coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role', '') = 'service_role'
$$;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.perfis where user_id = auth.uid() and papel = 'admin') or public._eh_servico()
$$;

-- leitura geral: controladoria e diretoria
create or replace function public.pode_ler_tudo() returns boolean
language sql stable security definer set search_path = public as $$
  select public.is_admin() or exists (select 1 from public.perfis where user_id = auth.uid() and papel = 'diretoria')
$$;

create or replace function public.meu_papel() returns text
language sql stable security definer set search_path = public as $$
  select case when public._eh_servico() then 'servico' else (select papel from public.perfis where user_id = auth.uid()) end
$$;

-- equipes que cada líder acompanha
create table if not exists public.lideres_equipes (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references public.perfis(user_id) on delete cascade,
  equipe_id  bigint not null references public.equipes(id),
  criado_em  timestamptz not null default now(),
  unique (user_id, equipe_id)
);
alter table public.lideres_equipes enable row level security;
revoke all on public.lideres_equipes from anon, authenticated;
grant select on public.lideres_equipes to authenticated;
drop trigger if exists lideres_equipes_auditoria on public.lideres_equipes;
create trigger lideres_equipes_auditoria after insert or update or delete on public.lideres_equipes
  for each row execute function public.tg_auditar_configuracao();

-- colaboradores cujas tarefas a pessoa logada enxerga (além de pode_ler_tudo):
-- ela mesma e, para o líder, os membros das equipes que lidera
create or replace function public.meus_colaboradores() returns bigint[]
language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(distinct x), '{}') from (
    select p.colaborador_id x from perfis p where p.user_id = auth.uid() and p.colaborador_id is not null
    union
    select c.id from lideres_equipes le join perfis p on p.user_id = le.user_id and p.papel = 'lider'
                     join colaboradores c on c.equipe_id = le.equipe_id
     where le.user_id = auth.uid()) s
$$;

drop policy if exists lideres_equipes_leitura on public.lideres_equipes;
create policy lideres_equipes_leitura on public.lideres_equipes for select to authenticated
  using (public.pode_ler_tudo() or user_id = auth.uid());

-- ---------------------------------------------------------------- políticas de leitura
-- 1) as que eram "só administradora": passam a valer também para a diretoria
do $$ declare r record; begin
  for r in select tablename, policyname from pg_policies
            where schemaname = 'public' and cmd = 'SELECT' and qual = 'is_admin()' loop
    execute format('alter policy %I on public.%I using (public.pode_ler_tudo())', r.policyname, r.tablename);
  end loop;
end $$;
-- 2) as que dependem do responsável: diretoria vê tudo; líder vê as equipes dele
alter policy perfis_leitura on public.perfis using (user_id = auth.uid() or public.pode_ler_tudo());
alter policy linhas_leitura on public.linhas_importadas
  using (public.pode_ler_tudo() or responsavel_id = any ((select public.meus_colaboradores())::bigint[]));
alter policy tarefas_leitura on public.tarefas
  using (public.pode_ler_tudo() or exists (select 1 from public.linhas_importadas l
           where l.tarefa_id = tarefas.id and l.responsavel_id = any ((select public.meus_colaboradores())::bigint[])));
alter policy eventos_leitura on public.eventos
  using (public.pode_ler_tudo() or colaborador_id = any ((select public.meus_colaboradores())::bigint[])
         or exists (select 1 from public.linhas_importadas l
                     where l.id = eventos.linha_id and l.responsavel_id = any ((select public.meus_colaboradores())::bigint[])));
alter policy processos_leitura on public.processos
  using (public.pode_ler_tudo() or exists (select 1 from public.linhas_importadas l
           where public.normalizar_cnj(l.processo_cnj) = processos.cnj
             and l.responsavel_id = any ((select public.meus_colaboradores())::bigint[])));

-- tratativa: mesma visibilidade
create or replace function public.tratativas_visiveis()
 returns table(tarefa_id bigint, tarefa_principal bigint, advbox_id text, abertura_em timestamp with time zone,
               inicio_em timestamp with time zone, inicio_por text, inicio_colaborador_id bigint)
 language sql stable security definer set search_path to 'public' as $function$
  with grp as (select t.id, coalesce(t.unificada_em, t.id) as pr from tarefas t),
  ini as (select distinct on (g.pr) g.pr, e.ocorrido_em, e.colaborador_id, c.nome_advbox
            from eventos e join grp g on g.id = e.tarefa_id left join colaboradores c on c.id = e.colaborador_id
           where e.tipo = 'inicio_tratativa'
           order by g.pr, e.ocorrido_em),
  eu as (select public.pode_ler_tudo() as adm, public.meus_colaboradores() as mc),   -- 0038
  meus as (select distinct g.pr from linhas_importadas l join grp g on g.id = l.tarefa_id, eu
            where not eu.adm and l.responsavel_id = any (eu.mc))
  select g.id, g.pr, p.advbox_id, p.criada_em_advbox, i.ocorrido_em, i.nome_advbox, i.colaborador_id
    from grp g join tarefas p on p.id = g.pr left join ini i on i.pr = g.pr cross join eu
   where eu.adm or i.colaborador_id = any (eu.mc) or g.pr in (select pr from meus)
$function$;

create or replace function public.tratativa_da_tarefa(p_tarefa bigint)
 returns table(tarefa_principal bigint, advbox_id text, abertura_em timestamp with time zone,
               inicio_em timestamp with time zone, inicio_por text, inicio_colaborador_id bigint)
 language sql stable security definer set search_path to 'public' as $function$
  with g as (select public.tarefa_canonica(p_tarefa) as principal),
  membros as (select t.id from tarefas t, g where coalesce(t.unificada_em, t.id) = g.principal),
  ini as (select e.ocorrido_em, e.colaborador_id, c.nome_advbox
            from eventos e left join colaboradores c on c.id = e.colaborador_id
           where e.tipo = 'inicio_tratativa' and e.tarefa_id in (select id from membros)
           order by e.ocorrido_em limit 1)
  select g.principal, p.advbox_id, p.criada_em_advbox, ini.ocorrido_em, ini.nome_advbox, ini.colaborador_id
    from g join tarefas p on p.id = g.principal left join ini on true
   where public.pode_ler_tudo()   -- 0038
      or exists (select 1 from linhas_importadas l where l.tarefa_id in (select id from membros)
                   and l.responsavel_id = any (public.meus_colaboradores()))
      or ini.colaborador_id = any (public.meus_colaboradores())
$function$;

-- ---------------------------------------------------------------- cadastro dos papéis
do $$
declare d text;
begin
  d := pg_get_functiondef('public.admin_definir_perfil(uuid, text, bigint, text)'::regprocedure);
  if position('0038' in d) > 0 then return; end if;
  d := replace(d, $a$p_papel not in ('admin','colaborador','lider') /* 0035 */$a$,
                  $a$p_papel not in ('admin','colaborador','lider','diretoria') /* 0035, 0038 */$a$);
  if position('0038' in d) = 0 then raise exception '0038: admin_definir_perfil não reconhecido'; end if;
  -- diretoria: colaborador opcional (se informado, fica guardado)
  d := replace(d, $a$case when p_papel in ('colaborador','lider') then p_colaborador_id end$a$,
                  $a$case when p_papel in ('colaborador','lider','diretoria') then p_colaborador_id end$a$);
  execute d;
end $$;

create or replace function public.admin_definir_lider_equipes(p_user_id uuid, p_equipes bigint[], p_motivo text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_papel text;
begin
  if not is_admin() then raise exception 'Somente administradores' using errcode = '42501'; end if;
  select papel into v_papel from perfis where user_id = p_user_id;
  if v_papel is distinct from 'lider' then raise exception 'Só líderes acompanham equipes (papel atual: %)', coalesce(v_papel, 'sem acesso'); end if;
  if exists (select 1 from unnest(coalesce(p_equipes, '{}')) e where not exists (select 1 from equipes where id = e)) then
    raise exception 'Equipe inexistente';
  end if;
  perform _exigir_motivo(p_motivo);
  delete from lideres_equipes where user_id = p_user_id and equipe_id <> all (coalesce(p_equipes, '{}'));
  insert into lideres_equipes (user_id, equipe_id) select p_user_id, e from unnest(coalesce(p_equipes, '{}')) e
  on conflict (user_id, equipe_id) do nothing;
  return jsonb_build_object('user_id', p_user_id, 'equipes', (select coalesce(jsonb_agg(equipe_id order by equipe_id), '[]') from lideres_equipes where user_id = p_user_id));
end $$;

create or replace function public.admin_listar_usuarios()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Somente administradores' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('user_id', u.id, 'email', u.email, 'criado_em', u.created_at,
            'ultimo_acesso', u.last_sign_in_at, 'papel', p.papel, 'colaborador_id', p.colaborador_id, 'colaborador', c.nome_advbox,
            'equipes_lideradas', (select coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'nome', e.nome) order by e.nome), '[]')
                                    from lideres_equipes le join equipes e on e.id = le.equipe_id where le.user_id = u.id))
            order by u.email)
          from auth.users u left join perfis p on p.user_id = u.id left join colaboradores c on c.id = p.colaborador_id), '[]');
end $$;

revoke execute on function public._eh_servico() from public, anon;
grant execute on function public._eh_servico() to authenticated;
revoke execute on function public.pode_ler_tudo(), public.meu_papel(), public.meus_colaboradores(),
                          public.admin_definir_lider_equipes(uuid, bigint[], text) from public, anon;
grant execute on function public.pode_ler_tudo(), public.meu_papel(), public.meus_colaboradores(),
                          public.admin_definir_lider_equipes(uuid, bigint[], text) to authenticated;

-- 0037 usava um auxiliar interno com o mesmo papel; passa a reaproveitar meu_papel()
create or replace function public._meu_papel() returns text
language sql stable security definer set search_path = public as $$ select public.meu_papel() $$;
