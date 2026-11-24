-- =====================================================================
-- 0046 — Double check sem o módulo de intimações do Atlas (achado no banco real, 12/11/2026)
-- A 0043 só carregava as publicações da Webjur na conferência quando havia intimações do Atlas sincronizadas.
-- Sem o módulo (atlas_modulo_intimacoes = false), as checagens que dependem só da Webjur (publicação
-- duplicada, publicação sem número de processo) ficavam desligadas: a conferência real mostrou
-- "0 publicações conferidas". Agora:
--   * as publicações entram quando há sincronização do Atlas OU quando o módulo não é usado;
--   * a comparação com as intimações do Atlas ("não encontrada nas intimações do Atlas") só roda
--     quando houve sincronização (sem o módulo, quem confere a captura é o CNJ — 0044).
-- Padrão das 0033/0034: trecho-âncora, idempotente.
-- =====================================================================
do $$
declare d text;
  a1 constant text := '     and v_ult_sync is not null;   -- 0043: sem intimações do Atlas sincronizadas, não há com o que comparar';
  a2 constant text := '     and not exists (select 1 from atlas_intimacoes a where a.cnj = p.cnj' || chr(10) ||
                      '                       and coalesce(a.available_date, a.publication_date) between p.d - v_tol and p.d + v_tol)';
begin
  d := pg_get_functiondef('public.double_check_atlas_executar(date, text)'::regprocedure);
  if position('-- 0046' in d) > 0 then return; end if;
  if position(a1 in d) = 0 or position(a2 in d) = 0 then
    raise exception '0046: âncoras do double_check_atlas_executar não encontradas';
  end if;
  d := replace(d, a1,
    '     and (v_ult_sync is not null   -- 0046: sem o módulo do Atlas, as checagens só da Webjur continuam' || chr(10) ||
    '          or not coalesce((select valor = ''true''::jsonb from parametros where chave = ''atlas_modulo_intimacoes''), false));');
  d := replace(d, a2, '     and v_ult_sync is not null   -- 0046: só compara com o Atlas quando houve sincronização' || chr(10) || a2);
  execute d;
end $$;
