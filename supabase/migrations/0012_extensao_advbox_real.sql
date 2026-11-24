-- =====================================================================
-- 0012 — Extensão no ADVBOX real (Etapa 5). Aditiva.
-- Estrutura conferida na tela real em 06/11/2026: ver docs/ETAPA5_EXTENSAO.md.
--  1. ext_inicios_por_ids(): a extensão consulta, de uma vez, se as tarefas visíveis
--     na LISTA já têm início da tratativa (a conclusão também acontece na lista,
--     sem abrir a janela). Só leitura: não cria nem altera registros.
--  2. _tarefa_por_advbox(): o clique na lista (só título) não sobrescreve mais a
--     última leitura completa da janela, usada para unificar tarefas.
-- =====================================================================

create or replace function public.ext_inicios_por_ids(p_ids text[])
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_papel text;
begin
  select papel into v_papel from perfis where user_id = auth.uid();
  if v_papel is null then raise exception 'Usuário sem perfil na controladoria' using errcode = '42501'; end if;
  if coalesce(array_length(p_ids, 1), 0) > 200 then raise exception 'No máximo 200 tarefas por consulta'; end if;
  if exists (select 1 from unnest(p_ids) x where x !~ '^\d{1,15}$') then raise exception 'ID de tarefa inválido'; end if;
  return jsonb_build_object(
    'inicios', coalesce((
      select jsonb_object_agg(i.id, (
        select min(e.ocorrido_em) from tarefas t
          join tarefas m on coalesce(m.unificada_em, m.id) = coalesce(t.unificada_em, t.id)
          join eventos e on e.tarefa_id = m.id and e.tipo = 'inicio_tratativa'
         where t.advbox_id = i.id))
        from unnest(p_ids) as i(id)), '{}'),
    'modos', jsonb_build_object(
       'conclusao', (select valor #>> '{}' from parametros where chave='trava_conclusao_modo'),
       'realocacao', (select valor #>> '{}' from parametros where chave='trava_realocacao_modo'),
       'pf', (select valor #>> '{}' from parametros where chave='trava_pf_modo')),
    'servidor_agora', now());
end $$;

create or replace function public._tarefa_por_advbox(p_advbox_id text, p_snap jsonb)
returns bigint language plpgsql security definer set search_path = public as $$
declare v_id bigint; v_cand bigint[]; v_lote bigint := (select lote_id from v_lote_atual);
begin
  select coalesce(unificada_em, id) into v_id from tarefas where advbox_id = p_advbox_id;
  v_cand := _candidatos_tela(p_snap, v_lote);
  if v_id is null then
    if coalesce(array_length(v_cand,1),0) = 1 then
      update tarefas set advbox_id = p_advbox_id, vinculo_excel = 'excel_unico' where id = v_cand[1];
      v_id := v_cand[1];
    else
      insert into tarefas (chave_identificacao, metodo, advbox_id, vinculo_excel)
      values ('A:' || p_advbox_id, 'advbox_id', p_advbox_id,
              case when coalesce(array_length(v_cand,1),0) = 0 then 'sem_correspondencia' else 'ambiguo' end)
      on conflict (chave_identificacao) do nothing;
      select id into v_id from tarefas where advbox_id = p_advbox_id;
    end if;
  elsif v_lote is not null and not _tem_linha_no_lote(v_id, v_lote) then
    -- A1/A2: a tarefa conhecida pelo ID não tem linha no lote atual (realocada,
    -- ou criada depois da exportação anterior). Se a tela corresponder a UMA
    -- única linha ainda sem ID, unifica; senão, nada é presumido.
    if coalesce(array_length(v_cand,1),0) = 1 then
      perform _unificar(v_id, v_cand[1], 'extensao_reabriu_tarefa', jsonb_build_object('advbox_id', p_advbox_id));
    elsif coalesce(array_length(v_cand,1),0) > 1 then
      update tarefas set vinculo_excel = 'ambiguo' where id = v_id and vinculo_excel <> 'excel_unico';
    end if;
  end if;
  -- só uma leitura COMPLETA da janela (com data do evento) vira a "última tela vista";
  -- o clique na lista traz só o título e não pode apagar a leitura anterior.
  if p_snap ? 'titulo' and nullif(p_snap->>'data_evento','') is not null then
    update tarefas set ultimo_snapshot = p_snap, ultimo_snapshot_em = now() where id = v_id;
  end if;
  update tarefas set criada_em_advbox = _ts_tela(p_snap->>'criado_em'),
                     criada_por_advbox = nullif(btrim(p_snap->>'criado_por'),'')
   where id = v_id and criada_em_advbox is null and _ts_tela(p_snap->>'criado_em') is not null;
  return v_id;
end $$;

revoke execute on all functions in schema public from public, anon;
grant execute on function public.ext_inicios_por_ids(text[]) to authenticated;
revoke execute on function public._tarefa_por_advbox(text, jsonb) from public, anon, authenticated;
