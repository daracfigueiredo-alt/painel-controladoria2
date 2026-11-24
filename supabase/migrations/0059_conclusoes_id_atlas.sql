-- =====================================================================
-- 0059 — Rede de segurança da conclusão (0058): o ID do Atlas passa a vir do cadastro da tarefa
-- (tarefas.atlas_id), e não do campo advbox_id da visão v_tarefas_atuais, que depende de quem consulta
-- (vem da tratativa visível ao usuário). Visto no banco real em 17/11/2026: consultado sem usuário nenhum,
-- o campo vem vazio (com a controladoria ou com a chave de serviço da rotina das 18:30 ele vem preenchido).
-- Ler do cadastro deixa a regra independente de quem roda. Reforço; não houve falha em produção.
-- =====================================================================
create or replace function public._dc_conclusoes(p_ini date, p_dia date) returns void
language plpgsql security definer set search_path = public as $$
declare v_desde date := coalesce((select (valor #>> '{}')::date from parametros where chave = 'atlas_conclusao_justificativa_desde'), p_dia);
begin
  if not public._param_bool('atlas_conclusao_exige_justificativa') then return; end if;
  insert into _inc
  select 'conclusao_sem_just|' || ta.id, 'conclusao_sem_justificativa', 2,
         (t.data_conclusao at time zone 'America/Sao_Paulo')::date, t.processo_cnj, null, null,
         case when ta.atlas_id::text ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then ta.atlas_id::text::uuid end,
         'Tarefa "' || coalesce(t.compromisso, '?') || '" (' || coalesce(t.responsavel, 'sem responsável') || ') concluída no Atlas em '
           || to_char(t.data_conclusao at time zone 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI') || ' sem justificativa registrada.',
         'Pedir a justificativa ao responsável e conferir se ele está com a extensão 0.7.0 ativa no Chrome; registrar a justificativa aqui.',
         jsonb_build_object('tarefa_id', ta.id, 'responsavel', t.responsavel, 'concluida_em', t.data_conclusao, 'atlas_id', ta.atlas_id)
    from v_tarefas_atuais t
    join tarefas ta on ta.id = public._tarefa_principal(t.tarefa_id)
   where t.situacao = 'concluida'
     and ta.atlas_id is not null
     and (t.data_conclusao at time zone 'America/Sao_Paulo')::date between greatest(p_ini, v_desde) and p_dia
     and not exists (
       select 1 from eventos e join tarefas x on x.id = e.tarefa_id
        where coalesce(x.unificada_em, x.id) = ta.id
          and e.tipo = 'tentativa_conclusao' and e.justificativa is not null
          and coalesce(e.estado_trava, '') in ('permitida_apos_validacao','excecao_autorizada')
          and e.ocorrido_em >= t.data_conclusao - interval '1 day')
  on conflict (chave) do nothing;
end $$;
revoke execute on function public._dc_conclusoes(date, date) from public, anon, authenticated;
