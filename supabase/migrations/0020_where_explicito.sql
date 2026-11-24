-- =====================================================================
-- 0020 — WHERE explícito em todo UPDATE (07/11/2026)
-- No Supabase, as chamadas pela API rodam com a extensão pg-safeupdate, que recusa
-- UPDATE sem WHERE ("UPDATE requires a WHERE clause"). A primeira importação real
-- foi recusada por isso. Os UPDATE afetados mexem só em tabelas temporárias da
-- própria função; o resultado não muda. Os arquivos 0003 e 0016–0018 já foram
-- corrigidos; esta migração corrige as funções que já estão no banco.
-- =====================================================================
do $$
declare d text; n int;
begin
  -- 1. _importar_arquivo_base (0003)
  d := pg_get_functiondef('public._importar_arquivo_base(text, text, jsonb, bigint, timestamptz)'::regprocedure);
  if position('= v.chave_oc) where true;' in d) = 0 then
    n := (length(d) - length(replace(d, '= v.chave_oc);', ''))) / length('= v.chave_oc);');
    if n <> 1 then raise exception '0020: trecho esperado não encontrado em _importar_arquivo_base (%)', n; end if;
    execute replace(d, '= v.chave_oc);', '= v.chave_oc) where true;');
  end if;

  -- 2. double_check_executar (0018)
  d := pg_get_functiondef('public.double_check_executar(date, date)'::regprocedure);
  if position('coalesce(dist, ov) where true;' in d) = 0 then
    if position('update dc_par set pont = coalesce(dist, ov);' in d) = 0
       or position('o.post_id <> r.post_id);' in d) = 0
       or position('and post_id not in (select post_id from dc_usada);' in d) = 0 then
      raise exception '0020: trechos esperados não encontrados em double_check_executar';
    end if;
    d := replace(d, 'update dc_par set pont = coalesce(dist, ov);', 'update dc_par set pont = coalesce(dist, ov) where true;');
    d := replace(d, 'o.post_id <> r.post_id);', 'o.post_id <> r.post_id) where true;');
    d := replace(d, 'and post_id not in (select post_id from dc_usada);', 'and post_id not in (select post_id from dc_usada) where true;');
    execute d;
  end if;
end $$;

-- create or replace preserva os privilégios; reforço por segurança
revoke execute on function public._importar_arquivo_base(text, text, jsonb, bigint, timestamptz) from public, anon, authenticated;
revoke execute on function public.double_check_executar(date, date) from public, anon;
grant execute on function public.double_check_executar(date, date) to authenticated;
