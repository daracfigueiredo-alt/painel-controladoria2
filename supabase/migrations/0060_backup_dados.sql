-- =====================================================================
-- 0060 — Backup dos dados (pedido da controladoria, 18/11/2026)
-- O painel (Configurações › Backup dos dados) baixa um arquivo JSON com todas as tabelas do sistema,
-- direto do banco para o computador da controladoria. Só a controladoria. Só leitura: nada é alterado.
-- A restauração usa integracoes/backup/restaurar_dados.py (gera o SQL) — ver docs/RESTAURAR.md.
-- Não entram: senhas, chaves e segredos (Auth, Vault, segredos das Edge Functions), que ficam com a controladoria.
-- =====================================================================

-- lista das tabelas, com colunas (tipo, gerada, sequência) e quantidade exata de linhas
create or replace function public.backup_tabelas() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r record; n bigint; v jsonb := '[]'; m jsonb := null;
begin
  if not public.is_admin() or public._eh_servico() then
    raise exception 'Somente a controladoria (com login) baixa o backup' using errcode = '42501';
  end if;
  for r in
    select c.oid, c.relname,
           (select jsonb_agg(jsonb_build_object('nome', a.attname, 'tipo', format_type(a.atttypid, a.atttypmod),
                     'gerada', a.attgenerated <> '', 'identidade', a.attidentity <> '',
                     'sequencia', a.attidentity <> '' or coalesce(pg_get_expr(d.adbin, d.adrelid), '') like 'nextval(%')
                   order by a.attnum)
              from pg_attribute a left join pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
             where a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped) colunas,
           (select jsonb_agg(a.attname order by k.ord)
              from pg_index i cross join lateral unnest(i.indkey) with ordinality k(attnum, ord)
              join pg_attribute a on a.attrelid = i.indrelid and a.attnum = k.attnum
             where i.indrelid = c.oid and i.indisprimary) chave
      from pg_class c join pg_namespace s on s.oid = c.relnamespace
     where s.nspname = 'public' and c.relkind = 'r'
     order by c.relname
  loop
    execute format('select count(*) from public.%I', r.relname) into n;
    v := v || jsonb_build_object('tabela', r.relname, 'linhas', n, 'colunas', r.colunas, 'chave', coalesce(r.chave, '[]'));
  end loop;
  begin
    execute 'select jsonb_agg(version order by version) from supabase_migrations.schema_migrations' into m;
  exception when others then m := null;   -- banco local de teste não tem o registro de migrações do Supabase
  end;
  return jsonb_build_object('formato', 'controladoria-backup-1', 'gerado_em', now(), 'banco', current_database(),
                            'migracoes', m, 'tabelas', v);
end $$;
revoke execute on function public.backup_tabelas() from public, anon;
grant execute on function public.backup_tabelas() to authenticated;

-- uma página de uma tabela, em ordem estável (chave primária; sem chave, a linha inteira)
create or replace function public.backup_tabela(p_tabela text, p_pagina int, p_tamanho int default 500) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_ordem text; r jsonb; v_tam int := least(greatest(coalesce(p_tamanho, 500), 1), 2000); v_nulos text;
begin
  if not public.is_admin() or public._eh_servico() then
    raise exception 'Somente a controladoria (com login) baixa o backup' using errcode = '42501';
  end if;
  if not exists (select 1 from pg_class c join pg_namespace s on s.oid = c.relnamespace
                  where s.nspname = 'public' and c.relkind = 'r' and c.relname = p_tabela) then
    raise exception 'Tabela desconhecida: %', p_tabela;
  end if;
  if coalesce(p_pagina, -1) < 0 then raise exception 'Página inválida'; end if;
  select string_agg(format('t.%I', a.attname), ', ' order by k.ord) into v_ordem
    from pg_index i cross join lateral unnest(i.indkey) with ordinality k(attnum, ord)
    join pg_attribute a on a.attrelid = i.indrelid and a.attnum = k.attnum
   where i.indrelid = format('public.%I', p_tabela)::regclass and i.indisprimary;
  -- campos json/jsonb: no arquivo, "vazio" (SQL NULL) e o valor null do JSON ficariam iguais; os vazios vão listados em __sql_nulos
  select string_agg(format('case when t.%I is null then %L end', a.attname, a.attname), ', ') into v_nulos
    from pg_attribute a
   where a.attrelid = format('public.%I', p_tabela)::regclass and a.attnum > 0 and not a.attisdropped
     and a.atttypid in ('json'::regtype, 'jsonb'::regtype);
  execute format('select coalesce(jsonb_agg(x.j order by x.o), ''[]'') from (select to_jsonb(t) %s j, row_number() over (order by %s) o
                    from public.%I t order by %s limit %s offset %s) x',
                 case when v_nulos is null then ''
                      else format('|| jsonb_build_object(''__sql_nulos'', to_jsonb(array_remove(array[%s]::text[], null)))', v_nulos) end,
                 coalesce(v_ordem, 't::text'), p_tabela, coalesce(v_ordem, 't::text'), v_tam, p_pagina::bigint * v_tam)
    into r;
  return r;
end $$;
revoke execute on function public.backup_tabela(text, int, int) from public, anon;
grant execute on function public.backup_tabela(text, int, int) to authenticated;

-- contas: só identificação (id e e-mail), para remapear depois de recriar as contas. Sem senha.
create or replace function public.backup_usuarios() returns jsonb
language plpgsql stable security definer set search_path = public, auth as $$
begin
  if not public.is_admin() or public._eh_servico() then
    raise exception 'Somente a controladoria (com login) baixa o backup' using errcode = '42501';
  end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('id', u.id, 'email', u.email) order by u.email), '[]') from auth.users u);
end $$;
revoke execute on function public.backup_usuarios() from public, anon;
grant execute on function public.backup_usuarios() to authenticated;
