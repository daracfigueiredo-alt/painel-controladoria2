-- =====================================================================
-- 0055 — Audiências: decisões da controladoria de 16/11/2026 (11:13)
--   * a regra da equipe pela letra do código do cliente está CONFIRMADA (C = Celeste, P = Prime, G = Gold,
--     E = Êxitos, D = Delta); a equipe "A" deixou de existir (cliente "A..." fica "sem equipe");
--   * criar tarefa de audiência no Atlas está autorizado, mas a equipe ainda NÃO acompanha audiências pelo Atlas:
--     a pendência "sem tarefa no Atlas" fica desligada (parâmetro audiencias_cobrar_tarefa_atlas = false) até a
--     equipe passar a usar o Atlas para isso.
-- =====================================================================
do $$ begin
  perform set_config('controladoria.motivo', 'Decisões da controladoria sobre audiências em 16/11/2026', true);
  update public.parametros set confirmado = true,
         descricao = 'Equipe do cliente pela letra do código do cliente (C362 = Celeste). Confirmado pela controladoria em 16/11/2026; a equipe "A" deixou de existir.'
   where chave = 'equipes_por_letra';
  insert into public.parametros (chave, valor, confirmado, descricao) values
   ('audiencias_cobrar_tarefa_atlas', 'false', true,
    'Audiências: cobrar a tarefa de audiência no Atlas (pendência "sem tarefa no Atlas"). Desligado em 16/11/2026: a equipe ainda não acompanha audiências pelo Atlas.')
  on conflict (chave) do nothing;
end $$;

create or replace function public._audiencia_pendencias(a audiencias) returns text[]
language sql stable security definer set search_path = public as $$
  select array_remove(array[
    case when a.situacao = 'agendada' and a.data is null then 'sem_data' end,
    case when a.situacao = 'agendada' and (a.data is null or a.data >= hoje_brasilia()) and a.advogado_id is null then 'sem_advogado' end,
    case when a.situacao = 'agendada' and a.data >= hoje_brasilia() and a.confirmada_em is null
              and a.data <= somar_dias_uteis(hoje_brasilia(), param_int('audiencias_confirmar_dias')) then 'sem_confirmacao' end,
    case when a.situacao = 'agendada' and a.data >= hoje_brasilia()
              and coalesce((select valor = 'true'::jsonb from parametros where chave = 'audiencias_cobrar_tarefa_atlas'), false)   -- 0055
              and not exists (
           select 1 from v_tarefas_atuais t
            where concat_ws(' ', t.compromisso, t.observacoes) ~* 'audi[eê]ncia'
              and (t.processo_cnj = a.cnj
                   or concat_ws(' ', t.compromisso, t.observacoes, t.partes) like '%' || a.cnj || '%'
                   or regexp_replace(concat_ws(' ', t.compromisso, t.observacoes), '\D', '', 'g') like '%' || regexp_replace(a.cnj, '\D', '', 'g') || '%')
              and coalesce(t.d7_data_agenda, t.pf_tarefa) between a.data - param_int('audiencias_tarefa_dias') and a.data) then 'sem_tarefa_atlas' end,
    case when a.situacao = 'agendada' and a.data < hoje_brasilia() and a.resultado is null then 'sem_ata' end
  ], null)
$$;
revoke execute on function public._audiencia_pendencias(audiencias) from public, anon, authenticated;
