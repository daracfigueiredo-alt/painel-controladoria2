-- =====================================================================
-- 0057 — Relatório gerencial: indicador de média sem dado aparece como "—", não como 0 (16/11/2026)
-- Na Tratativa, "Horas médias até o início" dava 0 quando nenhuma tarefa teve a tratativa iniciada no período.
-- _rg_media devolve nulo nesse caso; o painel mostra "—". A 0056 não é editada: troca pontual no corpo da função.
-- =====================================================================
create or replace function public._rg_media(p_sql text) returns numeric
language plpgsql stable security definer set search_path = public as $$
declare n numeric;
begin execute p_sql into n; return n; end $$;
revoke execute on function public._rg_media(text) from public, anon, authenticated;

do $$
declare d text; antes text := '''Horas médias até o início (período)'', ''valor'', _rg_num(';
begin
  d := pg_get_functiondef('public.relatorio_gerencial(text, date, date)'::regprocedure);
  if position(antes in d) = 0 then raise exception '0057: trecho da média não encontrado em relatorio_gerencial'; end if;
  execute replace(d, antes, '''Horas médias até o início (período)'', ''valor'', _rg_media(');
end $$;
revoke execute on function public.relatorio_gerencial(text, date, date) from public, anon;
grant execute on function public.relatorio_gerencial(text, date, date) to authenticated;
