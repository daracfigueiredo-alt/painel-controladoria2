-- =====================================================================
-- Reconstrução num projeto Supabase NOVO — passo 3 (depois das migrações e da restauração dos dados).
-- As migrações e o backup trazem os endereços do projeto antigo (impoejdocxuihficjvxm). Este script:
--   1) aponta os parâmetros para o projeto novo (endereços das funções e a chave pública "anon");
--   2) recria os 7 agendamentos exatamente como estavam em 18/11/2026 (todos ativos).
-- Pré-requisito: o segredo do Vault "atlas_cron_secret" criado no projeto novo, com o MESMO valor do
-- segredo CRON_SECRET das Edge Functions (a controladoria cria os dois; o valor não fica em arquivo nenhum).
--
-- Uso (psql; a senha é digitada pela controladoria):
--   psql "<string de conexão>" -v ref=<id do projeto novo> -v chave_anon=<chave anon (legada, começa com eyJ)> -f 3_apontar_novo_projeto.sql
-- =====================================================================
\set ON_ERROR_STOP on
begin;
select set_config('controladoria.motivo', 'Reconstrução: parâmetros apontados para o projeto novo ' || :'ref', true);
select set_config('reconstrucao.ref', :'ref', true), set_config('reconstrucao.anon', :'chave_anon', true);

do $p$
declare v_ref text := current_setting('reconstrucao.ref'); v_anon text := current_setting('reconstrucao.anon');
        base text;
begin
  if v_ref !~ '^[a-z0-9]{20}$' then raise exception 'ref inválido: use o id do projeto (20 letras/números), ex.: abcdefghijklmnopqrst'; end if;
  if v_anon !~ '^eyJ' then raise exception 'chave_anon inválida: use a chave anon legada (JWT, começa com eyJ) em Settings › API'; end if;
  base := 'https://' || v_ref || '.supabase.co/functions/v1/';
  update public.parametros set valor = to_jsonb(base || 'atlas-sync')     where chave = 'fim_expediente_url';
  update public.parametros set valor = to_jsonb(base || 'cnj-captura')    where chave = 'cnj_captura_url';
  update public.parametros set valor = to_jsonb(base || 'atlas-cadastro') where chave = 'atlas_cadastro_url';
  update public.parametros set valor = to_jsonb(v_anon)                   where chave = 'fim_expediente_chave_publica';
  if (select count(*) from public.parametros where chave in ('fim_expediente_url','cnj_captura_url','atlas_cadastro_url','fim_expediente_chave_publica')
        and valor #>> '{}' like '%' || case when chave = 'fim_expediente_chave_publica' then v_anon else v_ref end || '%') <> 4 then
    raise exception 'Parâmetros não encontrados: rode antes todas as migrações e a restauração dos dados';
  end if;
  raise notice 'Parâmetros apontados para %', base;
end $p$;

do $c$
declare v_anon text := current_setting('reconstrucao.anon'); u record; j record;
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') or not exists (select 1 from pg_extension where extname = 'pg_net') then
    raise notice 'pg_cron/pg_net não instalados neste banco: agendamentos não recriados (banco de teste?)'; return;
  end if;
  if not exists (select 1 from vault.secrets where name = 'atlas_cron_secret') then
    raise exception 'Crie antes o segredo atlas_cron_secret no Vault (mesmo valor do CRON_SECRET das funções)';
  end if;
  select (select valor #>> '{}' from public.parametros where chave = 'fim_expediente_url') fim,
         (select valor #>> '{}' from public.parametros where chave = 'cnj_captura_url') cnj,
         (select valor #>> '{}' from public.parametros where chave = 'atlas_cadastro_url') cad into u;
  for j in select * from (values
      ('controladoria_fim_expediente', '30 21 * * 1-5', u.fim, '{"acao":"fim_expediente"}', ''),
      ('controladoria_cnj_carteira',   '45 2 * * *',    u.cnj, '{"acao":"carteira"}', ''),
      ('controladoria_cnj_lote',       '*/2 3-9 * * *', u.cnj, '{"acao":"lote"}', ''),
      ('controladoria_cnj_oab',        '20 9,20 * * *', u.cnj, '{"acao":"oab"}', ''),
      ('controladoria_atlas_cadastro', '* * * * *',     u.cad, '{"acao":"cadastrar"}', 'where exists (select 1 from public.atlas_cadastro where situacao = ''aprovado'')'),
      ('controladoria_atlas_clientes', '40 2 * * *',    u.cad, '{"acao":"clientes"}', '')) as t(nome, quando, url, corpo, condicao) loop
    perform cron.unschedule(jobid) from cron.job where jobname = j.nome;
    perform cron.schedule(j.nome, j.quando, format($s$
      select net.http_post(url := %L,
        headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || %L,
                                      'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'atlas_cron_secret')),
        body := %L::jsonb, timeout_milliseconds := 150000) %s
    $s$, j.url, v_anon, j.corpo, j.condicao));
  end loop;
  perform cron.unschedule(jobid) from cron.job where jobname = 'controladoria_audiencias';
  perform cron.schedule('controladoria_audiencias', '15 * * * *', 'select public._audiencias_ler(null)');
  raise notice 'Agendamentos recriados: %', (select string_agg(jobname || ' (' || schedule || ')', ', ' order by jobname) from cron.job);
end $c$;
commit;
\echo 'Projeto novo configurado. Confira em Configurações › Log de integração depois da primeira rotina.'
