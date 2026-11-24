-- =====================================================================
-- 0061 — Acessos dos líderes e da diretoria (pedido da controladoria em 24/11/2026)
--   * As contas são criadas pela controladoria no Supabase (Authentication › Users › Add user ›
--     Send invitation). Cada pessoa define a própria senha pelo convite: a senha nunca passa por aqui.
--   * Esta migração deixa o acesso "previsto" por e-mail (acessos_previstos). Quando a conta com
--     aquele e-mail aparece no Auth, o banco cria o perfil sozinho:
--       - Líder: papel 'lider', ligado à equipe (lideres_equipes) e ao colaborador de mesmo nome,
--         se houver (o vínculo com o colaborador pode ser feito depois em Configurações › Usuários);
--       - Diretoria: papel 'diretoria'.
--   * Nunca sobrescreve um perfil que já exista (ex.: alguém que já é controladoria).
--   * Tudo fica registrado em auditoria_configuracao com o motivo.
--   * admin_aplicar_acessos_previstos() refaz a aplicação (contas criadas antes desta migração).
-- =====================================================================

create table if not exists public.acessos_previstos (
  email        text primary key check (email = lower(btrim(email)) and email ~ '^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}$'),
  nome         text not null,
  papel        text not null check (papel in ('lider','diretoria')),
  equipe       text,
  check ((papel = 'lider') = (equipe is not null)),
  criado_em    timestamptz not null default now(),
  aplicado_em  timestamptz,
  user_id      uuid,
  observacao   text
);
alter table public.acessos_previstos enable row level security;
revoke all on public.acessos_previstos from anon, authenticated;
grant select on public.acessos_previstos to authenticated;
drop policy if exists acessos_previstos_leitura on public.acessos_previstos;
create policy acessos_previstos_leitura on public.acessos_previstos for select to authenticated using (public.is_admin());

insert into public.acessos_previstos (email, nome, papel, equipe) values
  ('brendamartinsoecadv@gmail.com',   'Brenda Martins',                      'lider',     'Prime'),
  ('raquelguerraoecadv@gmail.com',    'Raquel Guerra Duarte',                'lider',     'Gold'),
  ('guilhermeladeiaoecadv@gmail.com', 'Guilherme Tadeu Ladeia Santos',       'lider',     'Celeste'),
  ('pedrofrejahoecadv@gmail.com',     'Pedro Frejah',                        'lider',     'Êxitos'),
  ('anaclaraandradeoecadv@gmail.com', 'Ana Clara Andrade Vieira',            'lider',     'Delta'),
  ('leandrosantanaoecadv@gmail.com',  'Leandro Henrique Santana',            'lider',     'Negociações'),
  ('marianacamiloadv@gmail.com',      'Mariana Camilo Silva',                'diretoria', null),
  ('anacaillauxoecadv@gmail.com',     'Ana Flávia Reis Caillaux',            'diretoria', null),
  ('barbaracastrooecadv@gmail.com',   'Bárbara de Castro Silva de Oliveira', 'diretoria', null)
on conflict (email) do nothing;

-- nome sem acento, minúsculo e com espaços únicos (para achar o colaborador)
create or replace function public._nome_simples(p text) returns text
language sql immutable set search_path = public as $$
  select regexp_replace(btrim(translate(lower(coalesce(p, '')),
    'áàâãäéèêëíìîïóòôõöúùûüçñ', 'aaaaaeeeeiiiiooooouuuucn')), '\s+', ' ', 'g')
$$;
revoke execute on function public._nome_simples(text) from public, anon, authenticated;

-- aplica o acesso previsto de uma conta (interna: chamada pelo gatilho e pela função da controladoria)
create or replace function public._aplicar_acesso_previsto(p_user_id uuid) returns text
language plpgsql security definer set search_path = public as $$
declare v_email text; a record; v_eq bigint; v_colab bigint; v_curto text; v_obs text;
begin
  select lower(btrim(email)) into v_email from auth.users where id = p_user_id;
  if v_email is null then return 'sem e-mail'; end if;
  select * into a from acessos_previstos where email = v_email;
  if not found then return 'sem acesso previsto'; end if;
  if exists (select 1 from perfis where user_id = p_user_id) then
    update acessos_previstos set user_id = p_user_id,
           observacao = 'A conta já tinha perfil (' || (select papel from perfis where user_id = p_user_id) || '); nada foi alterado.'
     where email = v_email and aplicado_em is null;
    return 'já tinha perfil';
  end if;

  perform set_config('controladoria.motivo',
    'Acesso previsto na 0061 (pedido da controladoria em 24/11/2026): ' || a.nome || ' — ' || a.papel, true);

  if a.papel = 'lider' then
    select id into v_eq from equipes where _nome_simples(nome) = _nome_simples(a.equipe);
    -- colaborador de mesmo nome: nome completo ou o nome curto do parâmetro equipes_lideres
    select valor ->> a.equipe into v_curto from parametros where chave = 'equipes_lideres';
    select min(c.id) into v_colab from colaboradores c
     where _nome_simples(c.nome_advbox) in (_nome_simples(a.nome), _nome_simples(v_curto))
    having count(*) = 1;
    insert into perfis (user_id, papel, colaborador_id) values (p_user_id, 'lider', v_colab);
    if v_eq is not null then
      insert into lideres_equipes (user_id, equipe_id) values (p_user_id, v_eq) on conflict do nothing;
    end if;
    v_obs := concat_ws(' ',
      case when v_eq is null then 'Equipe "' || a.equipe || '" não encontrada: ligar em Configurações › Usuários.' end,
      case when v_colab is null then 'Colaborador de mesmo nome não encontrado (ou mais de um): ligar em Configurações › Usuários.' end);
  else
    insert into perfis (user_id, papel, colaborador_id) values (p_user_id, 'diretoria', null);
  end if;

  update acessos_previstos set aplicado_em = now(), user_id = p_user_id, observacao = nullif(v_obs, '')
   where email = v_email;
  return 'aplicado';
end $$;
revoke execute on function public._aplicar_acesso_previsto(uuid) from public, anon, authenticated;

-- gatilho: conta nova no Auth → aplica o acesso previsto. Um erro aqui nunca impede a criação da conta.
create or replace function public.tg_acesso_previsto_nova_conta() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  begin
    perform public._aplicar_acesso_previsto(new.id);
  exception when others then
    raise warning '0061: acesso previsto não aplicado para %: %', new.email, sqlerrm;
  end;
  return null;
end $$;
revoke execute on function public.tg_acesso_previsto_nova_conta() from public, anon, authenticated;

drop trigger if exists controladoria_acesso_previsto on auth.users;
create trigger controladoria_acesso_previsto after insert or update of email on auth.users
  for each row execute function public.tg_acesso_previsto_nova_conta();

-- a controladoria confere a situação e reaplica (contas criadas antes da migração ou corrigidas)
create or replace function public.admin_aplicar_acessos_previstos() returns jsonb
language plpgsql security definer set search_path = public as $$
declare u record;
begin
  if not is_admin() then raise exception 'Somente administradores' using errcode = '42501'; end if;
  for u in select au.id from auth.users au join acessos_previstos a on a.email = lower(btrim(au.email))
            where a.aplicado_em is null loop
    perform _aplicar_acesso_previsto(u.id);
  end loop;
  return coalesce((select jsonb_agg(jsonb_build_object(
            'email', a.email, 'nome', a.nome, 'papel', a.papel, 'equipe', a.equipe,
            'situacao', case when a.aplicado_em is not null then 'acesso criado'
                             when exists (select 1 from auth.users au where lower(btrim(au.email)) = a.email) then 'conta existe; ver observação'
                             else 'aguardando a conta no Supabase' end,
            'aplicado_em', a.aplicado_em, 'observacao', a.observacao) order by a.papel desc, a.equipe, a.nome)
          from acessos_previstos a), '[]');
end $$;
revoke execute on function public.admin_aplicar_acessos_previstos() from public, anon;
grant execute on function public.admin_aplicar_acessos_previstos() to authenticated;

-- contas que já existam no momento da migração
do $$ declare u record; begin
  for u in select au.id from auth.users au join public.acessos_previstos a on a.email = lower(btrim(au.email))
            where a.aplicado_em is null loop
    perform public._aplicar_acesso_previsto(u.id);
  end loop;
end $$;
