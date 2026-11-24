-- =====================================================================
-- 0025 — Correção de double_check_manual (10/11/2026)
-- Erro visto no painel ao confirmar "não está no ADVBOX": record "a" is not
-- assigned yet. A função lia a.lawsuit_id mesmo quando nenhuma intimação do
-- ADVBOX tinha sido escolhida (situações sem post_id). Agora o processo do
-- ADVBOX só é lido quando há intimação informada. Regras inalteradas.
-- =====================================================================
create or replace function public.double_check_manual(p_publicacao bigint, p_situacao text, p_post_id text, p_nota text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_law text; v_tem_post boolean := nullif(btrim(coalesce(p_post_id, '')), '') is not null;
begin
  if not is_admin() then raise exception 'Somente a controladoria registra conferências' using errcode = '42501'; end if;
  if p_situacao not in ('encontrada_advbox','nao_encontrada_advbox','processo_nao_cadastrado','conferencia_manual') then
    raise exception 'Situação inválida para conferência manual: %', p_situacao;
  end if;
  if length(btrim(coalesce(p_nota,''))) < 10 then raise exception 'Descreva a conferência (mínimo 10 caracteres)'; end if;
  if p_situacao = 'encontrada_advbox' and not v_tem_post then
    raise exception 'Informe a intimação do ADVBOX que corresponde à publicação';
  end if;
  if v_tem_post then
    select lawsuit_id into v_law from advbox_intimacoes where post_id = p_post_id;
    if not found then raise exception 'Intimação % não está nas varreduras do ADVBOX', p_post_id; end if;
    if exists (select 1 from conferencias_publicacao x where x.evidencia->>'publicacao_advbox' = p_post_id and x.publicacao_id <> p_publicacao
                 and x.id = (select max(y.id) from conferencias_publicacao y where y.publicacao_id = x.publicacao_id)) then
      raise exception 'A intimação % já foi ligada a outra publicação', p_post_id;
    end if;
  end if;
  return pub_registrar_conferencia(p_publicacao, p_situacao, case when v_tem_post then 'intimacoes' else 'nenhuma' end,
           jsonb_build_object('nota', p_nota) || case when v_tem_post then
             jsonb_build_object('publicacao_advbox', p_post_id, 'lawsuit_id', v_law) else '{}'::jsonb end,
           v_law, 'manual');
end $$;

revoke execute on function public.double_check_manual(bigint, text, text, text) from public, anon;
grant execute on function public.double_check_manual(bigint, text, text, text) to authenticated;
