-- =====================================================================
-- 0050 — Ritmo do robô de cadastro no Atlas (achado no lote real de 14/11/2026, 21:46)
-- A 1ª execução do lote cadastrou 9 de 15 processos: cada processo leva ~5 s (conferência + cadastro, com
-- pausa para respeitar o limite do Atlas) e a função para em 45 s. Os 6 que sobraram voltaram para a fila,
-- mas CONTANDO como tentativa: depois de 3 adiamentos virariam "erro" sem nunca terem ido ao Atlas.
--   * novo resultado 'adiado': volta para a fila sem gastar tentativa (a função não chegou a chamar o Atlas);
--   * lote de 9 por execução e agendamento a cada minuto (~18 chamadas/min ao Atlas, limite 60).
-- =====================================================================
update public.parametros set valor = '9',
       descricao = 'Robô de cadastro de processos no Atlas: quantos processos aprovados cada execução cadastra (cerca de 5 s por processo; a execução para em 45 s). Ajustado de 15 para 9 em 14/11/2026, após o lote real.'
 where chave = 'atlas_cadastro_lote';

create or replace function public.atlas_cadastro_resultado(p_cnj text, p_resultado text, p_lawsuit_id text, p_erro text, p_detalhe jsonb default '{}')
returns void language plpgsql security definer set search_path = public as $$
declare v_cnj text := normalizar_cnj(p_cnj);
begin
  if not is_admin() then raise exception 'Somente a controladoria' using errcode = '42501'; end if;
  if p_resultado not in ('cadastrado','ja_existia','erro','tentar_de_novo','adiado') then raise exception 'Resultado inválido'; end if;
  if p_resultado = 'adiado' then   -- 0050: não chegou a chamar o Atlas; não gasta tentativa
    update atlas_cadastro set situacao = 'aprovado', tentativas = greatest(tentativas - 1, 0), atualizado_em = now()
     where cnj = v_cnj and situacao = 'enviando';
    return;
  end if;
  update atlas_cadastro set
     situacao = case p_resultado when 'cadastrado' then 'cadastrado' when 'ja_existia' then 'no_atlas'
                                 when 'tentar_de_novo' then case when tentativas >= 3 then 'erro' else 'aprovado' end
                                 else 'erro' end,
     atlas_lawsuit_id = coalesce(p_lawsuit_id, atlas_lawsuit_id),
     cadastrado_em = case when p_resultado = 'cadastrado' then now() else cadastrado_em end,
     motivo = case p_resultado when 'ja_existia' then 'Já existia no Atlas (conferido antes de cadastrar)' else motivo end,
     ultimo_erro = case when p_resultado in ('erro','tentar_de_novo') then left(p_erro, 500) end,
     atualizado_em = now()
   where cnj = v_cnj;
  if p_resultado in ('cadastrado','ja_existia') then
    insert into cnj_carteira (cnj, origens, atlas_lawsuit_id) values (v_cnj, array['atlas'], p_lawsuit_id)
    on conflict (cnj) do update set origens = (select array_agg(distinct o) from unnest(cnj_carteira.origens || array['atlas']) o),
       atlas_lawsuit_id = coalesce(excluded.atlas_lawsuit_id, cnj_carteira.atlas_lawsuit_id), ativo = true;
  end if;
  insert into atlas_cadastro_eventos (tipo, cnj, detalhe)
  values (case p_resultado when 'cadastrado' then 'cadastro' when 'ja_existia' then 'ja_existia' else 'erro' end, v_cnj,
          coalesce(p_detalhe, '{}') || jsonb_build_object('lawsuit_id', p_lawsuit_id, 'erro', left(p_erro, 500), 'resultado', p_resultado));
end $$;

-- os adiados do lote real voltam a ter as tentativas que de fato foram ao Atlas
update public.atlas_cadastro set ultimo_erro = null where situacao = 'aprovado' and ultimo_erro = 'Tempo da execução esgotado; volta na próxima';
update public.atlas_cadastro set tentativas = 0 where situacao = 'aprovado' and ultimo_erro is null and tentativas > 0;

do $$
begin
  if to_regclass('cron.job') is null then
    raise notice '0050: pg_cron indisponível neste banco; agendamento não alterado.';
    return;
  end if;
  execute $x$select cron.alter_job(jobid, schedule := '* * * * *') from cron.job where jobname = 'controladoria_atlas_cadastro'$x$;
end $$;
