-- =====================================================================
-- 0034 — Double check: "canceling statement due to statement timeout" (homologação, 10/11/2026)
-- Achado no teste real P2 (double check de 10/11, 38 publicações): a comparação de teores levava
-- 36 s para 37 pares. teor_semelhanca/teor_jaccard contavam as palavras comuns com
-- "w = any(array)" — cada palavra de um texto contra todas do outro (quadrático); publicações
-- longas têm 1.500 a 2.000 palavras distintas.
-- Correção: interseção de conjuntos (hash). As listas de palavras já são distintas
-- (array_agg distinct / except), então a contagem é a mesma. Conferido no banco real: 37 pares,
-- 0 diferenças, de 36 s para 0,7 s.
-- =====================================================================
create or replace function public.teor_semelhanca(a text, b text) returns numeric
language sql immutable set search_path = public as $$
  with x as (select teor_palavras(a) pa, teor_palavras(b) pb)
  select case when least(cardinality(pa), cardinality(pb)) = 0 then 0
              else round((select count(*) from (select unnest(pa) intersect select unnest(pb)) i)::numeric
                         / least(cardinality(pa), cardinality(pb)), 3) end
    from x
$$;

create or replace function public.teor_jaccard(a text, b text) returns numeric
language sql immutable set search_path = public as $$
  with x as (select teor_palavras(a) pa, teor_palavras(b) pb)
  select case when cardinality(pa) = 0 or cardinality(pb) = 0 then 0
              else round((select count(*) from (select unnest(pa) intersect select unnest(pb)) i)::numeric
                         / (select count(*) from (select unnest(pa) union select unnest(pb)) u), 3) end
    from x
$$;

-- palavras distintivas no double check (mesma troca; dp e da vêm de "except", logo distintas)
do $$
declare d text; antes text := '(select count(*) from unnest(dp) w where w = any(da))';
begin
  d := pg_get_functiondef('public.double_check_executar(date, date)'::regprocedure);
  if position('0034: intersect' in d) > 0 then return; end if;
  if (length(d) - length(replace(d, antes, ''))) / length(antes) <> 1 then
    raise exception '0034: trecho esperado não encontrado em double_check_executar';
  end if;
  d := replace(d, antes, '(select count(*) from (select unnest(dp) intersect select unnest(da)) i /* 0034: intersect */)');
  execute d;
end $$;
