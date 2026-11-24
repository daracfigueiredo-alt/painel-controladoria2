-- =====================================================================
-- 0019 — Endurecimento após o Security Advisor do Supabase (07/11/2026)
-- Aditiva; não muda resultados.
--  1. search_path fixo em todas as funções do schema public que ainda não o têm
--     (aviso "Function Search Path Mutable").
--  2. montar_observacoes_analise devolvia o teor integral de qualquer publicação a
--     qualquer usuário logado (SECURITY DEFINER sem checagem). Passa a ser só interna.
--     tarefa_canonica idem (só usada dentro de outras funções).
-- Mantidos de propósito (documentado em docs/SUPABASE_IMPLANTACAO.md):
--  * v_lote_atual sem security_invoker: expõe só número/horário do lote, para o
--    colaborador ver a data de atualização (anon não tem acesso);
--  * demais funções SECURITY DEFINER executáveis por "authenticated": cada uma confere
--    o perfil (is_admin ou perfil cadastrado) antes de fazer qualquer coisa.
-- =====================================================================
do $$ declare f record;
begin
  for f in select p.oid::regprocedure as sig
             from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.prokind = 'f'
              and not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c where c like 'search_path=%') loop
    execute format('alter function %s set search_path = public', f.sig);
  end loop;
end $$;

revoke execute on function public.montar_observacoes_analise(bigint, boolean) from public, anon, authenticated;
revoke execute on function public.tarefa_canonica(bigint) from public, anon, authenticated;
