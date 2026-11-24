-- =====================================================================
-- 0006 — Funções usadas pela extensão de navegador
-- A extensão usa SOMENTE a chave anon + sessão do usuário (login no
-- Supabase da controladoria). Toda gravação passa por estas funções.
-- O horário oficial dos eventos é o do servidor (não aceita retroativo).
-- =====================================================================

insert into public.parametros (chave, valor, confirmado, descricao) values
 ('trava_conclusao_modo', '"bloquear"', false,
  'Trava 3 (conclusão sem início da tratativa): bloquear | observar. Bloqueio atua só na tela, com a extensão ativa.'),
 ('trava_realocacao_modo', '"observar"', false,
  'Trava 1 (realocação sem justificativa): observar até o teste confirmar o significado dos campos do formulário "Atribuir tarefa".'),
 ('trava_pf_modo', '"observar"', false,
  'Trava 2 (alteração de prazo fatal): observar até o teste confirmar o significado do campo date_deadline.'),
 ('justificativa_minimo_caracteres', '15', false,
  'Tamanho mínimo do texto aceito como justificativa nas travas 1 e 2.');

-- "seg, 26/10/2026" / "26/10/2026" -> date ; "23/10/2026 17:33" -> timestamptz (Brasília)
create or replace function public._dt_tela(p text) returns date language sql immutable as $$
  select to_date((regexp_match(coalesce(p,''), '(\d{2}/\d{2}/\d{4})'))[1], 'DD/MM/YYYY')
$$;
create or replace function public._ts_tela(p text) returns timestamptz language sql immutable as $$
  select (to_timestamp((regexp_match(coalesce(p,''), '(\d{2}/\d{2}/\d{4} \d{2}:\d{2})'))[1], 'DD/MM/YYYY HH24:MI')::timestamp)
         at time zone 'America/Sao_Paulo'
$$;

-- ---------------------------------------------------------------------
-- Localiza/cria a tarefa pelo ID do ADVBOX e tenta vincular à linha do
-- Excel do lote atual (compromisso + data + PF + partes). Só vincula se
-- houver EXATAMENTE uma correspondência; caso contrário, registra o motivo.
-- ---------------------------------------------------------------------
create or replace function public._tarefa_por_advbox(p_advbox_id text, p_snap jsonb)
returns bigint language plpgsql security definer set search_path = public as $$
declare v_id bigint; v_cand bigint[]; v_vinc text;
  v_data date := _dt_tela(p_snap->>'data_evento');
  v_pf   date := _dt_tela(p_snap->>'prazo_fatal');
begin
  select id into v_id from tarefas where advbox_id = p_advbox_id;
  if v_id is null then
    select array_agg(distinct l.tarefa_id) into v_cand
      from linhas_importadas l
     where l.lote_id = (select lote_id from v_lote_atual) and l.situacao = 'valida' and l.tarefa_id is not null
       and upper(btrim(l.compromisso)) = upper(btrim(p_snap->>'titulo'))
       and l.data_agenda = v_data
       and l.pf_tarefa is not distinct from v_pf
       and not exists (select 1 from jsonb_array_elements_text(coalesce(p_snap->'partes','[]')) pt
                        where position(upper(btrim(pt)) in upper(coalesce(l.partes,''))) = 0)
       and not exists (select 1 from tarefas t where t.id = l.tarefa_id and t.advbox_id is not null);
    if coalesce(array_length(v_cand,1),0) = 1 then
      update tarefas set advbox_id = p_advbox_id, vinculo_excel = 'excel_unico' where id = v_cand[1];
      v_id := v_cand[1];
    else
      v_vinc := case when coalesce(array_length(v_cand,1),0) = 0 then 'sem_correspondencia' else 'ambiguo' end;
      insert into tarefas (chave_identificacao, metodo, advbox_id, vinculo_excel)
      values ('A:' || p_advbox_id, 'advbox_id', p_advbox_id, v_vinc)
      on conflict (chave_identificacao) do nothing;
      select id into v_id from tarefas where advbox_id = p_advbox_id;
    end if;
  end if;
  -- data de criação lida na tela: grava só a primeira observação (não sobrescreve)
  update tarefas set criada_em_advbox = _ts_tela(p_snap->>'criado_em'),
                     criada_por_advbox = nullif(btrim(p_snap->>'criado_por'),'')
   where id = v_id and criada_em_advbox is null and _ts_tela(p_snap->>'criado_em') is not null;
  return v_id;
end $$;

-- ---------------------------------------------------------------------
-- Consulta ao abrir a tarefa na tela
-- ---------------------------------------------------------------------
create or replace function public.ext_status_tarefa(p_advbox_id text, p_snapshot jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_t bigint; v_ini record; v_papel text; v_linha record;
begin
  select papel into v_papel from perfis where user_id = auth.uid();
  if v_papel is null then raise exception 'Usuário sem perfil na controladoria' using errcode = '42501'; end if;
  if p_advbox_id !~ '^\d{1,15}$' then raise exception 'ID de tarefa inválido'; end if;

  v_t := _tarefa_por_advbox(p_advbox_id, p_snapshot);
  select e.ocorrido_em, c.nome_advbox as por into v_ini
    from eventos e left join colaboradores c on c.id = e.colaborador_id
   where e.tarefa_id = v_t and e.tipo = 'inicio_tratativa' order by e.ocorrido_em limit 1;
  select l.pf_judicial_anotado, l.lote_id into v_linha
    from linhas_importadas l where l.tarefa_id = v_t and l.situacao = 'valida' order by l.lote_id desc, l.id desc limit 1;

  return jsonb_build_object(
    'tarefa_id', v_t,
    'vinculo_excel', (select vinculo_excel from tarefas where id = v_t),
    'inicio_tratativa_em', v_ini.ocorrido_em, 'inicio_por', v_ini.por,
    'pf_judicial_excel', v_linha.pf_judicial_anotado,
    'papel', v_papel,
    'modos', jsonb_build_object(
       'conclusao', (select valor #>> '{}' from parametros where chave='trava_conclusao_modo'),
       'realocacao', (select valor #>> '{}' from parametros where chave='trava_realocacao_modo'),
       'pf', (select valor #>> '{}' from parametros where chave='trava_pf_modo')),
    'justificativa_minima', param_int('justificativa_minimo_caracteres'),
    'servidor_agora', now());
end $$;

-- ---------------------------------------------------------------------
-- Registro de eventos observados pela extensão (idempotente por id_cliente)
-- ---------------------------------------------------------------------
create or replace function public.ext_registrar_evento(
  p_id_cliente   uuid,
  p_tipo         text,
  p_advbox_id    text,
  p_snapshot     jsonb,
  p_estado_trava text default null,
  p_justificativa text default null,
  p_evidencia    jsonb default '{}',
  p_horario_cliente timestamptz default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_papel text; v_colab bigint; v_t bigint; v_ex record; v_id uuid;
begin
  select papel, colaborador_id into v_papel, v_colab from perfis where user_id = auth.uid();
  if v_papel is null then raise exception 'Usuário sem perfil na controladoria' using errcode = '42501'; end if;
  if p_tipo not in ('inicio_tratativa','tentativa_conclusao','tentativa_realocacao','tentativa_alteracao_pf') then
    raise exception 'Tipo de evento não permitido para a extensão: %', p_tipo;
  end if;
  if p_advbox_id !~ '^\d{1,15}$' then raise exception 'ID de tarefa inválido'; end if;
  if p_tipo = 'inicio_tratativa' and p_estado_trava is not null then
    raise exception 'Início da tratativa não tem estado de trava';
  end if;
  if p_tipo <> 'inicio_tratativa' and (p_estado_trava is null or p_estado_trava not in
       ('bloqueio_efetivo','permitida_apos_validacao','excecao_autorizada','violacao_detectada','nao_monitorada')) then
    raise exception 'Estado de trava inválido';
  end if;
  if p_estado_trava = 'excecao_autorizada' and v_papel <> 'admin' then
    raise exception 'Somente a controladoria (admin) autoriza exceções' using errcode = '42501';
  end if;

  -- repetição do mesmo envio (rede instável): devolve o que já existe
  select id, ocorrido_em into v_ex from eventos where chave_dedupe = 'ext:' || p_id_cliente;
  if found then return jsonb_build_object('status','ja_registrado','evento_id',v_ex.id,'ocorrido_em',v_ex.ocorrido_em); end if;

  v_t := _tarefa_por_advbox(p_advbox_id, coalesce(p_snapshot,'{}'));

  if p_tipo = 'inicio_tratativa' then
    select e.id, e.ocorrido_em into v_ex from eventos e
     where e.tarefa_id = v_t and e.tipo = 'inicio_tratativa' order by e.ocorrido_em limit 1;
    if found then
      return jsonb_build_object('status','ja_iniciada','evento_id',v_ex.id,'ocorrido_em',v_ex.ocorrido_em);
    end if;
  end if;

  insert into eventos (chave_dedupe, tarefa_id, tipo, ocorrido_em, precisao_ocorrido, colaborador_id,
                       justificativa, origem, historico_recuperado, classificacao, estado_trava, evidencia)
  values ('ext:' || p_id_cliente, v_t, p_tipo, now(), 'segundo', v_colab,
          nullif(btrim(p_justificativa),''), 'extensao', false, 'confirmado', p_estado_trava,
          coalesce(p_evidencia,'{}') || jsonb_build_object(
            'advbox_id', p_advbox_id, 'usuario', auth.uid(), 'horario_cliente', p_horario_cliente,
            'tela', coalesce(p_snapshot,'{}'),
            'mecanismo', 'extensao_navegador (atua somente na tela, com a extensão ativa)'))
  returning id into v_id;

  return jsonb_build_object('status','registrado','evento_id',v_id,'ocorrido_em',now(),'tarefa_id',v_t);
end $$;

revoke execute on function public._tarefa_por_advbox(text, jsonb) from public, anon, authenticated;
revoke execute on function public.ext_status_tarefa(text, jsonb) from public, anon;
revoke execute on function public.ext_registrar_evento(uuid, text, text, jsonb, text, text, jsonb, timestamptz) from public, anon;
grant execute on function public.ext_status_tarefa(text, jsonb) to authenticated;
grant execute on function public.ext_registrar_evento(uuid, text, text, jsonb, text, text, jsonb, timestamptz) to authenticated;

-- Visão de auditoria das travas (o que foi bloqueado x apenas detectado)
create or replace view public.v_travas with (security_invoker = true) as
select e.id, e.tipo, e.estado_trava, e.ocorrido_em, e.colaborador_id, c.nome_advbox as colaborador,
       e.tarefa_id, e.evidencia->>'advbox_id' as advbox_id, e.justificativa,
       e.evidencia->>'motivo' as motivo, e.evidencia->>'modo' as modo, e.origem
  from public.eventos e left join public.colaboradores c on c.id = e.colaborador_id
 where e.estado_trava is not null;
grant select on public.v_travas to authenticated;
revoke all on public.v_travas from anon;
