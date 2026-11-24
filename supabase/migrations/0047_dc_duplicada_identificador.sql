-- =====================================================================
-- 0047 — "Publicação duplicada" não vale para comunicações oficiais diferentes (achado no banco real, 12/11/2026)
-- Com as publicações da Webjur de volta à conferência (0046), apareceram "duplicadas" com o mesmo texto,
-- processo e data, mas com identificadores do documento diferentes: são comunicações distintas do CNJ
-- (ex.: uma intimação para cada parte), não cópias. Quando as duas têm identificador e eles diferem,
-- não é duplicidade. Sem identificador (diários estaduais), a regra de antes continua.
-- =====================================================================
do $$
declare d text;
  a1 constant text := 'and teor_semelhanca(a.teor, b.teor) >= 0.95 order by a.id limit 1) a on true';
begin
  d := pg_get_functiondef('public.double_check_atlas_executar(date, text)'::regprocedure);
  if position('-- 0047' in d) > 0 then return; end if;
  if position(a1 in d) = 0 then raise exception '0047: âncora do double_check_atlas_executar não encontrada'; end if;
  d := replace(d, a1,
    'and teor_semelhanca(a.teor, b.teor) >= 0.95' || chr(10) ||
    '                                and not exists (select 1 from publicacoes x join publicacoes y on y.id = b.id   -- 0047' || chr(10) ||
    '                                                 where x.id = a.id and x.id_documento <> y.id_documento)' || chr(10) ||
    '                              order by a.id limit 1) a on true');
  execute d;
end $$;
