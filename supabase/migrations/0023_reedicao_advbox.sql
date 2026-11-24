-- =====================================================================
-- 0023 — "Editar tarefa" no ADVBOX recria a tarefa (08/11/2026)
-- Observado no ADVBOX real: ao salvar "Editar tarefa", a tarefa original é
-- EXCLUÍDA ("Esta tarefa foi excluída!") e outra é criada, com novo ID e nova
-- data de criação ("Criado por ... <hora da edição>"). Ex.: 296831568 -> 296831584.
-- Sem tratamento, a tarefa editada perderia o início da tratativa, a data de
-- criação original (regra das 24 h) e o histórico.
-- A extensão informa a troca logo após o envio da edição; o banco liga o novo ID
-- ao registro principal da tarefa (mesmo mecanismo de unificação da 0007), de
-- modo que tratativa, abertura e histórico continuam valendo. Nada é apagado.
-- Salvaguardas contra ligar tarefas que não têm relação:
--   * a nova tarefa precisa ter sido criada há no máximo 10 minutos (lido na tela);
--   * título igual OU mesmas partes;
--   * o novo ID não pode já ser principal de outros registros.
-- =====================================================================
alter table public.tarefas drop constraint if exists tarefas_vinculo_excel_check;
alter table public.tarefas add constraint tarefas_vinculo_excel_check
  check (vinculo_excel in ('excel_unico','sem_correspondencia','ambiguo','reedicao'));

create or replace function public.ext_registrar_reedicao(p_antigo text, p_novo text, p_snap_novo jsonb, p_snap_antigo jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_papel text; v_old bigint; v_new record; v_cria timestamptz; v_mesma boolean;
begin
  select papel into v_papel from perfis where user_id = auth.uid();
  if v_papel is null then raise exception 'Usuário sem perfil na controladoria' using errcode = '42501'; end if;
  if p_antigo !~ '^\d{1,15}$' or p_novo !~ '^\d{1,15}$' then raise exception 'ID de tarefa inválido'; end if;
  if p_antigo = p_novo then return jsonb_build_object('status', 'mesmo_id'); end if;

  v_cria := _ts_tela(p_snap_novo->>'criado_em');
  if v_cria is null or v_cria < now() - interval '10 minutes' then
    return jsonb_build_object('status', 'recusada', 'motivo', 'A tarefa nova não foi criada agora (criado em: ' || coalesce(p_snap_novo->>'criado_em', '?') || ').');
  end if;
  v_mesma := upper(btrim(coalesce(p_snap_novo->>'titulo', ''))) = upper(btrim(coalesce(p_snap_antigo->>'titulo', '')))
             and btrim(coalesce(p_snap_novo->>'titulo', '')) <> ''
          or (jsonb_array_length(coalesce(p_snap_novo->'partes', '[]')) > 0
              and coalesce(p_snap_novo->'partes', '[]') = coalesce(p_snap_antigo->'partes', '[]'));
  if not v_mesma then
    return jsonb_build_object('status', 'recusada', 'motivo', 'Título e partes diferentes: não parece a mesma tarefa.');
  end if;

  select coalesce(unificada_em, id) into v_old from tarefas where advbox_id = p_antigo;
  if v_old is null then v_old := _tarefa_por_advbox(p_antigo, coalesce(p_snap_antigo, '{}')); end if;

  select id, unificada_em into v_new from tarefas where advbox_id = p_novo;
  if v_new.id is null then
    insert into tarefas (chave_identificacao, metodo, advbox_id, vinculo_excel, unificada_em, criada_em_advbox, criada_por_advbox)
    values ('A:' || p_novo, 'advbox_id', p_novo, 'reedicao', v_old, v_cria, nullif(btrim(p_snap_novo->>'criado_por'), ''))
    on conflict (chave_identificacao) do nothing;
  elsif coalesce(v_new.unificada_em, v_new.id) = v_old then
    return jsonb_build_object('status', 'ja_ligada', 'tarefa_id', v_old);
  elsif v_new.unificada_em is not null or exists (select 1 from tarefas where unificada_em = v_new.id) then
    return jsonb_build_object('status', 'recusada', 'motivo', 'O novo ID já está ligado a outro registro.');
  else
    update tarefas set unificada_em = v_old, vinculo_excel = 'reedicao' where id = v_new.id;
  end if;

  update tarefas set ultimo_snapshot = p_snap_novo, ultimo_snapshot_em = now() where id = v_old;
  insert into eventos (chave_dedupe, tarefa_id, tipo, ocorrido_em, precisao_ocorrido, colaborador_id, valor_anterior, valor_novo,
                       origem, historico_recuperado, classificacao, evidencia)
  values ('reed:' || p_novo, v_old, 'unificacao_tarefa', now(), 'segundo',
          (select colaborador_id from perfis where user_id = auth.uid()),
          to_jsonb(p_antigo), to_jsonb(p_novo), 'extensao', false, 'confirmado',
          jsonb_build_object('motivo', 'reedicao_advbox',
            'regra', 'No ADVBOX, "Editar tarefa" exclui a original e cria outra; o novo ID continua a mesma tarefa.',
            'advbox_antigo', p_antigo, 'advbox_novo', p_novo, 'criado_em_novo', p_snap_novo->>'criado_em',
            'tela_antiga', coalesce(p_snap_antigo, '{}'), 'tela_nova', p_snap_novo, 'usuario', auth.uid()))
  on conflict (chave_dedupe) do nothing;
  return jsonb_build_object('status', 'ligada', 'tarefa_id', v_old, 'advbox_antigo', p_antigo, 'advbox_novo', p_novo);
end $$;

revoke execute on function public.ext_registrar_reedicao(text, text, jsonb, jsonb) from public, anon;
grant execute on function public.ext_registrar_reedicao(text, text, jsonb, jsonb) to authenticated;
