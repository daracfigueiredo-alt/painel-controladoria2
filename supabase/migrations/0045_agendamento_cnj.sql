-- =====================================================================
-- 0045 — Agendamento da captura do CNJ (0044), pelo pg_cron + pg_net, chamando a Edge Function cnj-captura
-- com o mesmo segredo da rotina das 18:30 (Vault atlas_cron_secret = segredo CRON_SECRET das funções).
-- Horários (Brasília, todos os dias):
--   23:45           atualiza a carteira (processos do Atlas + processos já conhecidos)
--   00:00 a 06:58   varredura por processo, a cada 2 minutos (cnj_lote_processos por execução: 12 x 210 = 2.520 processos/noite)
--   06:20 e 17:20   consulta por OAB (a das 17:20 abastece o double check das 18:30)
-- Sem pg_cron/pg_net (banco local de testes), só avisa.
-- =====================================================================
insert into public.parametros (chave, valor, confirmado, descricao) values
 ('cnj_captura_url', '"https://impoejdocxuihficjvxm.supabase.co/functions/v1/cnj-captura"', true,
  'Endereço da Edge Function da captura do CNJ, chamada pelo agendamento (0045).')
on conflict (chave) do nothing;
-- teste real (12/11/2026): uma execução com 40 processos esgotou os recursos da Edge Function depois de 24 consultas
update public.parametros set valor = '12', descricao = 'Quantos processos cada execução da varredura consulta (a varredura roda a cada 2 minutos de madrugada). Reduzido de 40 para 12 em 12/11/2026, após o teste real.'
 where chave = 'cnj_lote_processos' and valor = '40'::jsonb;

do $$
declare v_url text; v_anon text;
  job record;
begin
  if not exists (select 1 from pg_available_extensions where name = 'pg_cron')
     or not exists (select 1 from pg_available_extensions where name = 'pg_net') then
    raise notice '0045: pg_cron/pg_net indisponíveis neste banco; agendamento não criado.';
    return;
  end if;
  create extension if not exists pg_net;
  create extension if not exists pg_cron;
  v_url := (select valor #>> '{}' from public.parametros where chave = 'cnj_captura_url');
  v_anon := (select valor #>> '{}' from public.parametros where chave = 'fim_expediente_chave_publica');
  if v_url is null or v_anon is null then
    raise notice '0045: parâmetros cnj_captura_url / fim_expediente_chave_publica ausentes; agendamento não criado.';
    return;
  end if;
  for job in select * from (values
      ('controladoria_cnj_carteira', '45 2 * * *',      'carteira'),
      ('controladoria_cnj_lote',     '*/2 3-9 * * *',   'lote'),
      ('controladoria_cnj_oab',      '20 9,20 * * *',   'oab')) as t(nome, quando, acao) loop
    perform cron.unschedule(jobid) from cron.job where jobname = job.nome;
    perform cron.schedule(job.nome, job.quando, format($c$
      select net.http_post(url := %L,
        headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || %L,
                                      'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'atlas_cron_secret')),
        body := %L::jsonb, timeout_milliseconds := 150000)
    $c$, v_url, v_anon, json_build_object('acao', job.acao)::text));
  end loop;
end $$;
