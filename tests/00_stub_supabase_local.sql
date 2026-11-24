-- SOMENTE PARA TESTE LOCAL: simula o mínimo do Supabase (roles e auth.uid()).
-- NÃO aplicar no Supabase real.
-- auth.uid() segue a implementação do Supabase: lê request.jwt.claim.sub (testes em psql)
-- ou request.jwt.claims->>'sub' (definido pelo PostgREST nos testes ponta a ponta do painel).
do $$ begin
  if not exists (select 1 from pg_roles where rolname='anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated nologin; end if;
end $$;
create schema if not exists auth;
grant usage on schema auth to anon, authenticated;
create or replace function auth.uid() returns uuid language sql stable as
$$ select coalesce(nullif(current_setting('request.jwt.claim.sub', true), ''),
                  (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub'))::uuid $$;
grant execute on function auth.uid() to anon, authenticated;
grant usage on schema public to anon, authenticated;
-- auth.users mínimo (0029: lista de usuários e e-mails no histórico)
create table if not exists auth.users (id uuid primary key, email text, created_at timestamptz default now(), last_sign_in_at timestamptz);
-- Storage mínimo (0039: bucket "pecas" e políticas em storage.objects)
create schema if not exists storage;
grant usage on schema storage to anon, authenticated;
create table if not exists storage.buckets (id text primary key, name text not null, public boolean default false,
  file_size_limit bigint, allowed_mime_types text[], created_at timestamptz default now());
create table if not exists storage.objects (id uuid primary key default gen_random_uuid(), bucket_id text references storage.buckets(id),
  name text not null, owner uuid default auth.uid(), metadata jsonb, created_at timestamptz default now(), unique (bucket_id, name));
alter table storage.objects enable row level security;
grant select, insert on storage.objects to authenticated;
grant select on storage.buckets to authenticated;
