-- =====================================================================
-- 0058 — Decisões da controladoria de 17/11/2026 (00:24), depois de conferir a documentação da API do Atlas:
--   1) Conclusão de tarefa do Atlas exige JUSTIFICATIVA. A API do Atlas não permite barrar a conclusão
--      (não há gancho antes de concluir, e tarefa concluída não reabre pela API); a trava fica na extensão
--      (versão 0.7.0), que pede a justificativa ao concluir ou dar baixa. Rede de segurança: a sincronização
--      com o Atlas traz cada conclusão com dia e hora; o double check das 18:30 aponta a conclusão sem
--      justificativa registrada (feita fora do Chrome com a extensão, ou com extensão antiga) — inconsistência
--      "conclusao_sem_justificativa". O servidor também reclassifica a conclusão declarada sem justificativa.
--   2) Tarefa "em andamento" no Atlas CONTA COMO INÍCIO DA TRATATIVA: a sincronização registra o início na
--      primeira vez que vê a tarefa em andamento (e a extensão registra na hora, quando a pessoa muda a situação).
--   3) O PETICIONADOR pode pedir reagendamento pelo painel: até o D-4, decide o líder da equipe; depois do D-4
--      (nova data depois do D-4, ou pedido feito quando o D-4 já passou), só a controladoria. Pedido do líder
--      sem decisão que passa do D-4 sobe para a controladoria.
-- =====================================================================

-- ---------------------------------------------------------------- parâmetros
do $$ begin
  perform set_config('controladoria.motivo', 'Decisões da controladoria de 17/11/2026 sobre conclusão, início da tratativa e reagendamento', true);
  insert into public.parametros (chave, valor, confirmado, descricao) values
   ('atlas_conclusao_exige_justificativa', 'true', true,
    'Atlas: concluir ou dar baixa numa tarefa exige justificativa (extensão 0.7.0). Decidido pela controladoria em 17/11/2026.'),
   ('atlas_conclusao_justificativa_desde', '"2026-11-18"', false,
    'Atlas: o double check aponta conclusão sem justificativa a partir deste dia (AAAA-MM-DD). Dá tempo de a equipe atualizar a extensão para a 0.7.0.'),
   ('atlas_em_andamento_inicia_tratativa', 'true', true,
    'Atlas: tarefa em andamento no Atlas conta como início da tratativa. Decidido pela controladoria em 17/11/2026.')
  on conflict (chave) do nothing;
end $$;

create or replace function public._param_bool(p_chave text) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select valor = 'true'::jsonb from parametros where chave = p_chave), false)
$$;
revoke execute on function public._param_bool(text) from public, anon, authenticated;

-- ---------------------------------------------------------------- 1) conclusão com justificativa
-- a extensão pergunta ao servidor se a conclusão exige justificativa
do $$
declare d text; a constant text := $a$    'justificativa_minima', param_int('justificativa_minimo_caracteres'),$a$;
begin
  d := pg_get_functiondef('public.ext_status_tarefa(text, jsonb)'::regprocedure);
  if position('-- 0058' in d) > 0 then return; end if;
  if position(a in d) = 0 then raise exception '0058: âncora de ext_status_tarefa não encontrada'; end if;
  d := replace(d, a, $b$    'conclusao_exige_justificativa', p_advbox_id ~ '^[0-9a-fA-F]{8}-' and public._param_bool('atlas_conclusao_exige_justificativa'),   -- 0058
$b$ || a);
  execute d;
end $$;

-- o servidor confere: conclusão no Atlas declarada como permitida sem justificativa vira violação
do $$
declare d text; a constant text := $a$    elsif p_tipo in ('tentativa_realocacao','tentativa_alteracao_pf')$a$;
begin
  d := pg_get_functiondef('public.ext_registrar_evento(uuid, text, text, jsonb, text, text, jsonb, timestamptz)'::regprocedure);
  if position('-- 0058' in d) > 0 then return; end if;
  if position(a in d) = 0 then raise exception '0058: âncora de ext_registrar_evento não encontrada'; end if;
  d := replace(d, a, $b$    elsif p_tipo = 'tentativa_conclusao' and p_advbox_id ~ '^[0-9a-fA-F]{8}-'   -- 0058
          and public._param_bool('atlas_conclusao_exige_justificativa')
          and length(regexp_replace(btrim(coalesce(p_justificativa,'')), '\s+', ' ', 'g')) < v_min then
      v_estado := 'violacao_detectada';
      v_verif := jsonb_build_object('motivo_servidor','Conclusão no Atlas sem justificativa (exigida desde 17/11/2026).');
$b$ || a);
  execute d;
end $$;

-- rede de segurança no double check
alter table public.inconsistencias drop constraint if exists inconsistencias_tipo_check;
alter table public.inconsistencias add constraint inconsistencias_tipo_check check (tipo in
  ('intimacao_nao_cadastrada','divergencia','prazo_nao_lancado','prazo_incorreto','publicacao_duplicada','pendencia_controladoria',
   'captura_divergente','audiencia_pendente','conclusao_sem_justificativa'));

create or replace function public._dc_conclusoes(p_ini date, p_dia date) returns void
language plpgsql security definer set search_path = public as $$
declare v_desde date := coalesce((select (valor #>> '{}')::date from parametros where chave = 'atlas_conclusao_justificativa_desde'), p_dia);
begin
  if not public._param_bool('atlas_conclusao_exige_justificativa') then return; end if;
  insert into _inc
  select 'conclusao_sem_just|' || coalesce(t.tarefa_principal_id, t.tarefa_id), 'conclusao_sem_justificativa', 2,
         (t.data_conclusao at time zone 'America/Sao_Paulo')::date, t.processo_cnj, null, null,
         case when t.advbox_id ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then t.advbox_id::uuid end,
         'Tarefa "' || coalesce(t.compromisso, '?') || '" (' || coalesce(t.responsavel, 'sem responsável') || ') concluída no Atlas em '
           || to_char(t.data_conclusao at time zone 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI') || ' sem justificativa registrada.',
         'Pedir a justificativa ao responsável e conferir se ele está com a extensão 0.7.0 ativa no Chrome; registrar a justificativa aqui.',
         jsonb_build_object('tarefa_id', coalesce(t.tarefa_principal_id, t.tarefa_id), 'responsavel', t.responsavel,
                            'concluida_em', t.data_conclusao, 'atlas_id', t.advbox_id)
    from v_tarefas_atuais t
   where t.situacao = 'concluida'
     and t.advbox_id ~ '^[0-9a-fA-F]{8}-'
     and (t.data_conclusao at time zone 'America/Sao_Paulo')::date between greatest(p_ini, v_desde) and p_dia
     and not exists (
       select 1 from eventos e join tarefas x on x.id = e.tarefa_id
        where coalesce(x.unificada_em, x.id) = coalesce(t.tarefa_principal_id, t.tarefa_id)
          and e.tipo = 'tentativa_conclusao' and e.justificativa is not null
          and coalesce(e.estado_trava, '') in ('permitida_apos_validacao','excecao_autorizada')
          and e.ocorrido_em >= t.data_conclusao - interval '1 day')
  on conflict (chave) do nothing;
end $$;
revoke execute on function public._dc_conclusoes(date, date) from public, anon, authenticated;

-- ---------------------------------------------------------------- 2) "em andamento" no Atlas = início da tratativa
-- chamada pela sincronização (atlas-sync) depois de gravar o lote; registra o início das tarefas que estão
-- "em andamento" no Atlas e ainda não têm início. Hora = a da sincronização que viu (precisão: entre importações).
create or replace function public.atlas_registrar_em_andamento(p_lote bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare n int := 0;
begin
  if not is_admin() then raise exception 'Somente a controladoria' using errcode = '42501'; end if;
  if not public._param_bool('atlas_em_andamento_inicia_tratativa') then return jsonb_build_object('registrados', 0, 'desligado', true); end if;
  insert into eventos (chave_dedupe, tarefa_id, linha_id, tipo, ocorrido_em, precisao_ocorrido, colaborador_id,
                       origem, historico_recuperado, classificacao, evidencia)
  select distinct on (coalesce(t.unificada_em, t.id))
         'atlas_em_andamento|' || coalesce(t.unificada_em, t.id), coalesce(t.unificada_em, t.id), l.id, 'inicio_tratativa', now(),
         'entre_importacoes', l.responsavel_id, 'sistema', false, 'confirmado',
         jsonb_build_object('fonte', 'atlas_em_andamento', 'lote_id', l.lote_id, 'atlas_id', l.dados_brutos->>'_atlas_id',
                            'regra', 'Tarefa em andamento no Atlas conta como início da tratativa (controladoria, 17/11/2026).')
    from linhas_importadas l join tarefas t on t.id = l.tarefa_id
   where l.lote_id = p_lote and l.situacao = 'valida' and l.dados_brutos->>'_atlas_status' = 'doing'
     and not exists (select 1 from eventos e join tarefas x on x.id = e.tarefa_id
                      where coalesce(x.unificada_em, x.id) = coalesce(t.unificada_em, t.id) and e.tipo = 'inicio_tratativa')
   order by coalesce(t.unificada_em, t.id), l.id
  on conflict (chave_dedupe) do nothing;
  get diagnostics n = row_count;
  return jsonb_build_object('registrados', n);
end $$;
revoke execute on function public.atlas_registrar_em_andamento(bigint) from public, anon;
grant execute on function public.atlas_registrar_em_andamento(bigint) to authenticated;

-- ---------------------------------------------------------------- 3) reagendamento pedido pelo peticionador
alter table public.solicitacoes drop constraint if exists solicitacoes_status_check;
alter table public.solicitacoes add constraint solicitacoes_status_check check (status in
  ('aguardando_lider','aguardando_controladoria','aprovada','recusada','em_execucao','executada','falhou','cancelada'));

-- p_nova_data: nova data na pauta (vencimento no Atlas). Só a data muda; o responsável continua o mesmo.
create or replace function public.solicitacao_reagendamento_pedir(p_tarefa bigint, p_nova_data date, p_justificativa text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_min int := param_int('justificativa_minimo_caracteres'); v_just text := btrim(regexp_replace(coalesce(p_justificativa, ''), '\s+', ' ', 'g'));
        v_t bigint; v record; v_atlas text; v_hoje date := hoje_brasilia(); v_motivos text[] := '{}'; v_st text; v_id bigint;
        f constant text := 'DD/MM/YYYY';
begin
  if coalesce(public.meu_papel(), '') <> 'colaborador' then
    raise exception 'Somente o peticionador pede reagendamento por aqui (líder e controladoria usam a solicitação completa)' using errcode = '42501';
  end if;
  if length(v_just) < v_min then raise exception 'Justificativa obrigatória (mínimo % caracteres)', v_min; end if;
  if p_nova_data is null then raise exception 'Informe a nova data'; end if;
  if p_nova_data < v_hoje then raise exception 'A nova data não pode ser anterior a hoje'; end if;
  v_t := public._tarefa_principal(p_tarefa);
  select * into v from v_tarefas_atuais x where x.tarefa_id is not null and public._tarefa_principal(x.tarefa_id) = v_t and x.situacao = 'pendente' limit 1;
  if not found then raise exception 'Tarefa não encontrada entre as pendentes da base atual'; end if;
  if not (v.responsavel_id = any (public.meus_colaboradores())) then
    raise exception 'Você só pode pedir reagendamento das suas tarefas' using errcode = '42501';
  end if;
  select atlas_id into v_atlas from tarefas where id = v_t;
  if v_atlas is null then raise exception 'Só tarefas do Atlas podem ser reagendadas pelo painel'; end if;
  if p_nova_data = v.d7_data_agenda then raise exception 'A nova data é igual à data atual'; end if;
  if v.pf_tarefa is not null and p_nova_data > v.pf_tarefa then raise exception 'A nova data não pode passar do prazo fatal (%)', to_char(v.pf_tarefa, f); end if;
  if exists (select 1 from solicitacoes s where s.tipo = 'reagendamento' and (s.dados->>'tarefa_id')::bigint = v_t
               and s.status in ('aguardando_lider','aguardando_controladoria','aprovada','em_execucao')) then
    raise exception 'Já existe um pedido de reagendamento em andamento para esta tarefa';
  end if;
  -- regra da controladoria (17/11/2026): até o D-4, o líder; depois do D-4, só a controladoria
  if v.d4 is not null and not public._excecao_d4_em(v_t) then
    if v_hoje > v.d4 then v_motivos := v_motivos || ('Pedido feito depois do D-4 (' || to_char(v.d4, f) || ')'); end if;
    if p_nova_data > v.d4 then v_motivos := v_motivos || ('Nova data depois do D-4 (' || to_char(v.d4, f) || ')'); end if;
  end if;
  v_st := case when cardinality(v_motivos) > 0 then 'aguardando_controladoria' else 'aguardando_lider' end;
  insert into solicitacoes (tipo, status, solicitante, solicitante_papel, colaborador_id, dados, remanejamento, analise, justificativa,
                            exige_controladoria, motivos_controladoria)
  values ('reagendamento', v_st, auth.uid(), 'colaborador', v.responsavel_id,
          jsonb_build_object('tarefa_id', v_t, 'nova_data', p_nova_data, 'data_atual', v.d7_data_agenda, 'compromisso', v.compromisso,
                             'd4', v.d4, 'pf_judicial', v.pf_judicial, 'atlas_id', v_atlas, 'origem', 'peticionador'),
          null, null, v_just, cardinality(v_motivos) > 0, v_motivos)
  returning id into v_id;
  insert into solicitacoes_historico (solicitacao_id, status_de, status_para, por, nota)
  values (v_id, null, v_st, auth.uid(), case when v_st = 'aguardando_lider' then 'Pedido do peticionador: aguardando o líder da equipe (antes do D-4)'
                                             else 'Pedido do peticionador: aguardando a controladoria — ' || array_to_string(v_motivos, '; ') end);
  return (select to_jsonb(s) from solicitacoes s where id = v_id);
end $$;
revoke execute on function public.solicitacao_reagendamento_pedir(bigint, date, text) from public, anon;
grant execute on function public.solicitacao_reagendamento_pedir(bigint, date, text) to authenticated;

-- decisão: "aguardando o líder" = líder da equipe do advogado ou controladoria; "aguardando a controladoria" = só a controladoria.
-- O líder que decide depois que o D-4 passou não aprova: o pedido sobe para a controladoria.
create or replace function public.solicitacao_decidir(p_id bigint, p_aprovar boolean, p_nota text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s solicitacoes; v_lider boolean; v_d4 date; f constant text := 'DD/MM/YYYY';
begin
  if coalesce(public.meu_papel(), '') not in ('admin','lider','servico') then
    raise exception 'Somente o líder da equipe ou a controladoria' using errcode = '42501';
  end if;
  if length(btrim(coalesce(p_nota, ''))) < 10 then raise exception 'Registre o motivo da decisão (mínimo 10 caracteres)'; end if;
  select * into s from solicitacoes where id = p_id for update;
  if s.id is null then raise exception 'Solicitação % inexistente', p_id; end if;
  v_lider := not is_admin() and coalesce(public.meu_papel() = 'lider', false) and public._pode_planejar(s.colaborador_id);
  if s.status = 'aguardando_controladoria' then
    if not is_admin() then raise exception 'Somente a controladoria aprova' using errcode = '42501'; end if;
  elsif s.status = 'aguardando_lider' then
    if not (is_admin() or v_lider) then raise exception 'Somente o líder da equipe ou a controladoria' using errcode = '42501'; end if;
    v_d4 := (s.dados->>'d4')::date;
    if v_lider and p_aprovar and v_d4 is not null and hoje_brasilia() > v_d4
       and not public._excecao_d4_em((s.dados->>'tarefa_id')::bigint) then
      update solicitacoes set exige_controladoria = true,
             motivos_controladoria = motivos_controladoria || ('O D-4 (' || to_char(v_d4, f) || ') passou antes da decisão do líder')
       where id = p_id;
      perform _solicitacao_status(p_id, 'aguardando_controladoria', 'Líder aprovou depois do D-4: o pedido subiu para a controladoria. Nota do líder: ' || btrim(p_nota));
      return (select to_jsonb(x) || jsonb_build_object('encaminhada_controladoria', true) from solicitacoes x where id = p_id);
    end if;
  else
    raise exception 'Só solicitações aguardando decisão podem ser decididas (atual: %)', s.status;
  end if;
  update solicitacoes set decidido_por = auth.uid(), decidido_em = now(), decisao_nota = btrim(p_nota) where id = p_id;
  perform _solicitacao_status(p_id, case when p_aprovar then 'aprovada' else 'recusada' end,
          (case when v_lider then 'Líder: ' else 'Controladoria: ' end) || btrim(p_nota));
  return (select to_jsonb(x) from solicitacoes x where id = p_id);
end $$;

-- execução no Atlas: o líder da equipe também executa o pedido que aprovou (antes: só quem pediu)
do $$
declare d text; a constant text := $a$if not (is_admin() or (s.solicitante = auth.uid() and public._pode_planejar(s.colaborador_id))) then$a$;
begin
  d := pg_get_functiondef('public.solicitacao_para_execucao(bigint)'::regprocedure);
  if position('-- 0058' in d) > 0 then return; end if;
  if position(a in d) = 0 then raise exception '0058: âncora de solicitacao_para_execucao não encontrada'; end if;
  d := replace(d, a, $b$if not (is_admin() or public._pode_planejar(s.colaborador_id)) then   -- 0058: líder da equipe$b$);
  execute d;
end $$;

-- o resultado da execução também é registrado quando quem executou foi o líder da equipe (não o autor do pedido)
do $$
declare d text; a constant text := $a$if not (is_admin() or s.solicitante = auth.uid()) then raise exception 'Somente quem pediu ou a controladoria' using errcode = '42501'; end if;$a$;
begin
  d := pg_get_functiondef('public.solicitacao_resultado(bigint, boolean, jsonb)'::regprocedure);
  if position('/* 0058 */' in d) > 0 then return; end if;
  if position(a in d) = 0 then raise exception '0058: âncora de solicitacao_resultado não encontrada'; end if;
  d := replace(d, a, $b$if not (is_admin() or s.solicitante = auth.uid() or public._pode_planejar(s.colaborador_id)) /* 0058 */ then raise exception 'Somente quem pediu, o líder da equipe ou a controladoria' using errcode = '42501'; end if;$b$);
  execute d;
end $$;

-- quem pediu (agora também o peticionador) pode cancelar, inclusive enquanto aguarda o líder
do $$
declare d text;
        a constant text := $a$if s.status not in ('aguardando_controladoria','aprovada','falhou') then$a$;
        p constant text := $a$if coalesce(public.meu_papel(), '') not in ('admin','lider','servico') then raise exception 'Somente líderes e a controladoria' using errcode = '42501'; end if;$a$;
begin
  d := pg_get_functiondef('public.solicitacao_cancelar(bigint, text)'::regprocedure);
  if position('/* 0058 */' in d) > 0 then return; end if;
  if position(a in d) = 0 or position(p in d) = 0 then raise exception '0058: âncora de solicitacao_cancelar não encontrada'; end if;
  d := replace(d, a, $b$if s.status not in ('aguardando_lider','aguardando_controladoria','aprovada','falhou') /* 0058 */ then$b$);
  d := replace(d, p, $b$if public.meu_papel() is null then raise exception 'Usuário sem perfil na controladoria' using errcode = '42501'; end if;   /* 0058: o peticionador cancela o próprio pedido */$b$);
  execute d;
end $$;

-- pedido parado com o líder que passa do D-4 sobe para a controladoria (rodado no double check das 18:30)
create or replace function public._solicitacoes_escalar(p_dia date) returns int
language plpgsql security definer set search_path = public as $$
declare r record; n int := 0; f constant text := 'DD/MM/YYYY';
begin
  for r in select s.id, (s.dados->>'d4')::date d4 from solicitacoes s
            where s.status = 'aguardando_lider' and (s.dados->>'d4') is not null and p_dia > (s.dados->>'d4')::date
              and not public._excecao_d4_em((s.dados->>'tarefa_id')::bigint) loop
    update solicitacoes set exige_controladoria = true,
           motivos_controladoria = motivos_controladoria || ('Passou do D-4 (' || to_char(r.d4, f) || ') sem decisão do líder')
     where id = r.id;
    perform _solicitacao_status(r.id, 'aguardando_controladoria', 'Passou do D-4 sem decisão do líder: subiu para a controladoria');
    n := n + 1;
  end loop;
  return n;
end $$;
revoke execute on function public._solicitacoes_escalar(date) from public, anon, authenticated;

do $$
declare d text; a constant text := '  perform public._dc_audiencias(v_dia);   -- 0051 audiencias';
begin
  d := pg_get_functiondef('public.double_check_atlas_executar(date, text)'::regprocedure);
  if position('-- 0058' in d) > 0 then return; end if;
  if position(a in d) = 0 then raise exception '0058: âncora do double_check_atlas_executar não encontrada'; end if;
  d := replace(d, a, a || chr(10) || '  perform public._dc_conclusoes(v_ini, v_dia);   -- 0058 conclusao' || chr(10)
                         || '  perform public._solicitacoes_escalar(v_dia);   -- 0058 reagendamento');
  execute d;
end $$;
