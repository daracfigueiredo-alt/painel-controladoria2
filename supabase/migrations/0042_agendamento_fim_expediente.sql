-- =====================================================================
-- 0042 — Agendamento da rotina do fim do expediente (pedido da Dra. Mariana, item 3; 11/11/2026).
-- Dias úteis, 18:30 (Brasília) = 21:30 UTC: o pg_cron chama a Edge Function atlas-sync
-- (ação fim_expediente) pelo pg_net. A função confere o segredo CRON_SECRET (o mesmo valor
-- guardado no Vault com o nome "atlas_cron_secret") e roda com a chave de serviço:
--   1) sincroniza as tarefas do Atlas;  2) sincroniza as intimações (list_deadlines);
--   3) coleta a produtividade (get_productivity);  4) roda o double check Webjur × Atlas e
--   grava o relatório diário. Só LEITURA no Atlas: nada é alterado lá pela rotina automática.
-- O job nasce DESATIVADO: a controladoria liga depois de conferir as permissões da chave.
-- Sem pg_cron/pg_net (banco local de testes), a migração só avisa e não faz nada.
-- Endereço e chave pública do projeto de homologação (dados públicos; a chave é a "anon" legada,
-- em formato JWT, porque a função tem verify_jwt ligado). Num projeto novo, ajustar antes.
-- =====================================================================
insert into public.parametros (chave, valor, confirmado, descricao) values
 ('fim_expediente_url', '"https://impoejdocxuihficjvxm.supabase.co/functions/v1/atlas-sync"', true,
  'Endereço da Edge Function chamada pela rotina do fim do expediente (0042).'),
 ('fim_expediente_chave_publica', '"eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImltcG9lamRvY3h1aWhmaWNqdnhtIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTQwODU4MjgsImV4cCI6MjEwOTY2MTgyOH0.8Q3kHln772M2wfYFXqU4QSTNIGi1KgvshHN7J6XldNo"', true,
  'Chave pública (anon, JWT) usada só para passar pelo verify_jwt da função; a autorização real é o segredo CRON_SECRET (0042).')
on conflict (chave) do nothing;

do $$
declare v_url text; v_anon text; v_job bigint;
begin
  if not exists (select 1 from pg_available_extensions where name = 'pg_cron')
     or not exists (select 1 from pg_available_extensions where name = 'pg_net') then
    raise notice '0042: pg_cron/pg_net indisponíveis neste banco; agendamento não criado.';
    return;
  end if;
  create extension if not exists pg_net;
  create extension if not exists pg_cron;
  -- configuração (pública) do projeto: endereço da função e chave publicável, guardadas como parâmetros
  v_url := (select valor #>> '{}' from public.parametros where chave = 'fim_expediente_url');
  v_anon := (select valor #>> '{}' from public.parametros where chave = 'fim_expediente_chave_publica');
  if v_url is null or v_anon is null then
    raise notice '0042: parâmetros fim_expediente_url / fim_expediente_chave_publica ausentes; agendamento não criado.';
    return;
  end if;
  perform cron.unschedule(jobid) from cron.job where jobname = 'controladoria_fim_expediente';
  select cron.schedule('controladoria_fim_expediente', '30 21 * * 1-5', format($c$
    select net.http_post(url := %L,
      headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || %L,
                                    'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'atlas_cron_secret')),
      body := '{"acao":"fim_expediente"}'::jsonb, timeout_milliseconds := 150000)
  $c$, v_url, v_anon)) into v_job;
  perform cron.alter_job(v_job, active := false);
end $$;
