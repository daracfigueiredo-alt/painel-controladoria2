-- =====================================================================
-- 0007 — Correções dos achados da auditoria de 05/11/2026 (A1–A6)
-- Migração ADITIVA: não recria tabelas nem apaga dados. Ver
-- docs/ETAPA2_BANCO.md para o detalhamento de cada correção.
--
--  A1/A2  Identidade: o ID real do ADVBOX (advbox_id) passa a ser a
--         identidade principal. Registros da mesma tarefa criados por
--         caminhos diferentes (Excel x extensão) são UNIFICADOS: o registro
--         secundário aponta para o principal (tarefas.unificada_em). Nada
--         é apagado; a unificação vira evento de auditoria.
--  A3     O início da tratativa é lido por função própria, visível ao
--         responsável mesmo quando outra pessoa registrou o início.
--  A4     O servidor confere o estado de trava declarado pela extensão
--         e reclassifica o que não se sustenta.
--  A5     Arquivo só de concluídas não substitui a fotografia atual
--         sem confirmação expressa.
--  A6     Privilégios de execução revistos (anon não executa nada).
-- Decisão de 05/11/2026 (A7): colaborador PODE iniciar a tratativa em
-- tarefa de outro responsável; o autor do início continua registrado.
-- =====================================================================

-- ---------------------------------------------------------------- tabelas
alter table public.tarefas
  add column if not exists unificada_em       bigint references public.tarefas(id),
  add column if not exists ultimo_snapshot    jsonb,
  add column if not exists ultimo_snapshot_em timestamptz;
alter table public.tarefas drop constraint if exists tarefas_unificada_nao_propria;
alter table public.tarefas add constraint tarefas_unificada_nao_propria check (unificada_em is null or unificada_em <> id);
create index if not exists tarefas_unificada_idx on public.tarefas (unificada_em);

alter table public.eventos drop constraint if exists eventos_tipo_check;
alter table public.eventos add constraint eventos_tipo_check check (tipo in (
  'encaminhamento','anotacao_realocacao','pedido_reagendamento','alteracao_data_agenda',
  'alteracao_pf_tarefa','alteracao_responsavel','conclusao','inicio_tratativa',
  'tentativa_conclusao','tentativa_realocacao','tentativa_alteracao_pf','importacao',
  'unificacao_tarefa'));

-- ---------------------------------------------------------------- identidade
-- Registro principal de uma tarefa (um nível: o secundário sempre aponta
-- direto para o principal).
create or replace function public.tarefa_canonica(p_tarefa bigint) returns bigint
language sql stable security definer set search_path = public as $$
  select coalesce(t.unificada_em, t.id) from tarefas t where t.id = p_tarefa
$$;

-- Tarefas (ids) do lote atual cuja linha corresponde ao que a tela mostra.
-- Mesmo critério da fase 2 (título = Compromisso, Data do evento = Data,
-- PF da Tarefa, partes contidas). Exclui registros que já têm ID do ADVBOX
-- ou já foram unificados. Critério ainda NÃO validado no ADVBOX real (A8).
create or replace function public._candidatos_tela(p_snap jsonb, p_lote bigint)
returns bigint[] language sql stable security definer set search_path = public as $$
  select array_agg(distinct l.tarefa_id)
    from linhas_importadas l
   where l.lote_id = p_lote and l.situacao = 'valida' and l.tarefa_id is not null
     and nullif(btrim(p_snap->>'titulo'),'') is not null
     and upper(btrim(l.compromisso)) = upper(btrim(p_snap->>'titulo'))
     and l.data_agenda = _dt_tela(p_snap->>'data_evento')
     and l.pf_tarefa is not distinct from _dt_tela(p_snap->>'prazo_fatal')
     and not exists (select 1 from jsonb_array_elements_text(coalesce(p_snap->'partes','[]')) pt
                      where position(upper(btrim(pt)) in upper(coalesce(l.partes,''))) = 0)
     and not exists (select 1 from tarefas t where t.id = l.tarefa_id
                       and (t.advbox_id is not null or t.unificada_em is not null))
$$;

-- Tem linha no lote informado (considerando os registros unificados)?
create or replace function public._tem_linha_no_lote(p_tarefa bigint, p_lote bigint) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from linhas_importadas l join tarefas t on t.id = l.tarefa_id
                  where l.lote_id = p_lote and l.situacao = 'valida'
                    and coalesce(t.unificada_em, t.id) = p_tarefa)
$$;

-- Unifica o registro secundário no principal e registra o evento.
create or replace function public._unificar(p_principal bigint, p_secundario bigint, p_motivo text, p_evid jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_principal = p_secundario then return; end if;
  if exists (select 1 from tarefas where unificada_em = p_secundario) then
    raise exception 'Registro % já é principal de outros; unificação recusada', p_secundario;
  end if;
  update tarefas set unificada_em = p_principal where id = p_secundario and unificada_em is null;
  if not found then return; end if;
  update tarefas set vinculo_excel = 'excel_unico' where id = p_principal;
  insert into eventos (chave_dedupe, tarefa_id, tipo, ocorrido_em, precisao_ocorrido, valor_anterior, valor_novo,
                       origem, historico_recuperado, classificacao, evidencia)
  values ('unif:' || p_secundario, p_principal, 'unificacao_tarefa', now(), 'segundo',
          to_jsonb(p_secundario), to_jsonb(p_principal), 'sistema', false, 'confirmado',
          coalesce(p_evid,'{}') || jsonb_build_object('motivo', p_motivo, 'usuario', auth.uid(),
            'regra', 'correspondência única no lote atual (título, data do evento, prazo fatal, partes)'))
  on conflict (chave_dedupe) do nothing;
end $$;

-- Substitui a função da fase 2 (mesma assinatura).
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
  if p_snap ? 'titulo' then
    update tarefas set ultimo_snapshot = p_snap, ultimo_snapshot_em = now() where id = v_id;
  end if;
  update tarefas set criada_em_advbox = _ts_tela(p_snap->>'criado_em'),
                     criada_por_advbox = nullif(btrim(p_snap->>'criado_por'),'')
   where id = v_id and criada_em_advbox is null and _ts_tela(p_snap->>'criado_em') is not null;
  return v_id;
end $$;

-- Na importação: tarefas conhecidas pelo ID sem linha no novo lote são
-- unificadas quando a ÚLTIMA tela vista corresponde a uma única linha nova.
create or replace function public._unificar_apos_importacao(p_lote bigint)
returns int language plpgsql security definer set search_path = public as $$
declare r record; v_cand bigint[]; n int := 0;
begin
  for r in select t.id, t.advbox_id, t.ultimo_snapshot from tarefas t
            where t.advbox_id is not null and t.unificada_em is null and t.ultimo_snapshot is not null
              and not _tem_linha_no_lote(t.id, p_lote) loop
    v_cand := _candidatos_tela(r.ultimo_snapshot, p_lote);
    if coalesce(array_length(v_cand,1),0) = 1 then
      perform _unificar(r.id, v_cand[1], 'importacao_tela_anterior', jsonb_build_object('advbox_id', r.advbox_id, 'lote_id', p_lote));
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;

-- ---------------------------------------------------------------- A5: importação
-- A função da fase 2 vira interna; a pública acrescenta a proteção de lote
-- e a unificação. Chamadas antigas (5 argumentos) continuam válidas.
alter function public.importar_arquivo(text, text, jsonb, bigint, timestamptz) rename to _importar_arquivo_base;
revoke execute on function public._importar_arquivo_base(text, text, jsonb, bigint, timestamptz) from public, anon, authenticated;

create or replace function public.importar_arquivo(
  p_nome_arquivo    text,
  p_hash_arquivo    text,
  p_linhas          jsonb,
  p_lote_id         bigint default null,
  p_data_exportacao timestamptz default null,
  p_confirmar_lote_novo_so_concluidas boolean default false
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_res jsonb; v_existente bigint; n_unif int;
begin
  if not public.is_admin() then
    raise exception 'Somente administradores podem importar' using errcode = '42501';
  end if;
  select id into v_existente from importacoes where hash_arquivo = p_hash_arquivo;
  if found then
    return jsonb_build_object('status','ja_importado','importacao_id',v_existente,
      'mensagem','Este arquivo já foi importado; nenhuma alteração foi feita.');
  end if;
  -- Arquivo em que TODAS as linhas têm Data Conclusão, enviado como nova
  -- fotografia, quando já existe base: a visão atual passaria a ter só as
  -- concluídas. Exige confirmação expressa (ou o lote do dia).
  if p_lote_id is null and not p_confirmar_lote_novo_so_concluidas
     and jsonb_typeof(p_linhas) = 'array' and jsonb_array_length(p_linhas) > 0
     and exists (select 1 from importacoes where status = 'concluida')
     and not exists (select 1 from jsonb_array_elements(p_linhas) e
                      where nullif(btrim(e->>'Data Conclusão'),'') is null) then
    return jsonb_build_object('status','requer_confirmacao','lote_atual',(select lote_id from v_lote_atual),
      'mensagem','Todas as linhas deste arquivo são tarefas concluídas. Importado como nova fotografia, ele '
       || 'substituiria a base atual. Informe o lote do dia (complementar) ou confirme expressamente o lote novo.');
  end if;
  v_res := _importar_arquivo_base(p_nome_arquivo, p_hash_arquivo, p_linhas, p_lote_id, p_data_exportacao);
  if v_res->>'status' = 'concluida' then
    n_unif := _unificar_apos_importacao((v_res->>'lote_id')::bigint);
    v_res := v_res || jsonb_build_object('tarefas_unificadas_pelo_id_advbox', n_unif);
  end if;
  return v_res;
end $$;

-- ---------------------------------------------------------------- A3: tratativa
-- Dados de tratativa do registro principal. Acesso: admin, responsável por
-- alguma linha do grupo, ou quem registrou o início.
create or replace function public.tratativa_da_tarefa(p_tarefa bigint)
returns table (tarefa_principal bigint, advbox_id text, abertura_em timestamptz,
               inicio_em timestamptz, inicio_por text, inicio_colaborador_id bigint)
language sql stable security definer set search_path = public as $$
  with g as (select public.tarefa_canonica(p_tarefa) as principal),
  membros as (select t.id from tarefas t, g where coalesce(t.unificada_em, t.id) = g.principal),
  ini as (select e.ocorrido_em, e.colaborador_id, c.nome_advbox
            from eventos e left join colaboradores c on c.id = e.colaborador_id
           where e.tipo = 'inicio_tratativa' and e.tarefa_id in (select id from membros)
           order by e.ocorrido_em limit 1)
  select g.principal, p.advbox_id, p.criada_em_advbox, ini.ocorrido_em, ini.nome_advbox, ini.colaborador_id
    from g join tarefas p on p.id = g.principal left join ini on true
   where public.is_admin()
      or exists (select 1 from linhas_importadas l where l.tarefa_id in (select id from membros)
                   and l.responsavel_id = public.meu_colaborador_id())
      or ini.colaborador_id = public.meu_colaborador_id()
$$;

create or replace view public.v_tarefas_atuais with (security_invoker = true) as
with base as (
  select l.*, public.hoje_brasilia() as hoje
    from public.linhas_importadas l
   where l.situacao = 'valida' and l.lote_id = (select lote_id from public.v_lote_atual)
)
select b.id as linha_id, b.tarefa_id, b.metodo_vinculo, b.importacao_id, b.lote_id, b.numero_linha,
       b.prioridade, b.compromisso, b.processo_cnj, b.tribunal_cnj, b.partes, b.tipo_acao, b.local,
       b.responsavel_id, cr.nome_advbox as responsavel, cm.nome_advbox as remetente,
       b.observacoes,
       b.data_agenda                                   as d7_data_agenda,
       public.calcular_d7_conferencia(b.pf_judicial_anotado, b.tribunal_cnj) as d7_conferencia,
       b.d4_anotado,
       public.calcular_d4(b.pf_judicial_anotado, b.tribunal_cnj)            as d4_regra,
       coalesce(b.d4_anotado, public.calcular_d4(b.pf_judicial_anotado, b.tribunal_cnj)) as d4,
       case when b.d4_anotado is not null then 'anotado_na_tarefa'
            when b.pf_judicial_anotado is not null then 'calculado_regra'
            else 'indisponivel' end                    as d4_origem,
       b.pf_judicial_anotado                           as pf_judicial,
       case when b.pf_judicial_anotado is not null then 'anotado_na_tarefa'
            else 'nao_confirmado' end                  as pf_judicial_status,
       b.pf_tarefa,
       b.prazo_dias_anotado,
       b.data_conclusao,
       case when b.data_conclusao is not null then 'concluida' else 'pendente' end as situacao,
       b.hoje,
       public.dias_uteis_entre(b.hoje, coalesce(b.d4_anotado, public.calcular_d4(b.pf_judicial_anotado, b.tribunal_cnj)), b.tribunal_cnj) as du_ate_d4,
       public.dias_uteis_entre(b.hoje, b.pf_judicial_anotado, b.tribunal_cnj) as du_ate_pf_judicial,
       public.dias_uteis_entre(b.hoje, b.pf_tarefa, b.tribunal_cnj)           as du_ate_pf_tarefa,
       tr.inicio_em                                    as inicio_tratativa_em,
       tr.abertura_em                                  as abertura_em,
       (select min(e.ocorrido_em) from public.eventos e
         where e.tipo = 'encaminhamento'
           and (e.tarefa_id = b.tarefa_id or e.linha_id = b.id))              as primeira_atribuicao_observada_em,
       (select ultima_importacao_em from public.v_lote_atual) as dados_atualizados_em,
       -- novas colunas (0007)
       tr.tarefa_principal                             as tarefa_principal_id,
       tr.advbox_id,
       tr.inicio_por
  from base b
  left join public.colaboradores cr on cr.id = b.responsavel_id
  left join public.colaboradores cm on cm.id = b.remetente_id
  left join lateral public.tratativa_da_tarefa(b.tarefa_id) tr on b.tarefa_id is not null;

-- Tarefas vistas pela extensão (com ID do ADVBOX) que não aparecem na
-- fotografia atual: o vínculo precisa ser refeito abrindo a tarefa no ADVBOX.
create or replace view public.v_tarefas_sem_linha_atual with (security_invoker = true) as
select t.id as tarefa_id, t.advbox_id, t.vinculo_excel, t.criada_em_advbox, t.ultimo_snapshot_em,
       t.ultimo_snapshot->>'titulo' as titulo_tela, t.ultimo_snapshot->>'data_evento' as data_evento_tela,
       (select min(e.ocorrido_em) from public.eventos e where e.tarefa_id = t.id and e.tipo = 'inicio_tratativa') as inicio_tratativa_em
  from public.tarefas t
 where t.advbox_id is not null and t.unificada_em is null and public.is_admin()
   and (select lote_id from public.v_lote_atual) is not null
   and not exists (select 1 from public.linhas_importadas l join public.tarefas m on m.id = l.tarefa_id
                    where l.lote_id = (select lote_id from public.v_lote_atual) and l.situacao = 'valida'
                      and coalesce(m.unificada_em, m.id) = t.id);

-- ---------------------------------------------------------------- extensão
create or replace function public.ext_status_tarefa(p_advbox_id text, p_snapshot jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_t bigint; v_ini record; v_papel text; v_linha record;
begin
  select papel into v_papel from perfis where user_id = auth.uid();
  if v_papel is null then raise exception 'Usuário sem perfil na controladoria' using errcode = '42501'; end if;
  if p_advbox_id !~ '^\d{1,15}$' then raise exception 'ID de tarefa inválido'; end if;

  v_t := _tarefa_por_advbox(p_advbox_id, coalesce(p_snapshot,'{}'));
  select e.ocorrido_em, c.nome_advbox as por into v_ini
    from eventos e join tarefas t on t.id = e.tarefa_id left join colaboradores c on c.id = e.colaborador_id
   where coalesce(t.unificada_em, t.id) = v_t and e.tipo = 'inicio_tratativa' order by e.ocorrido_em limit 1;
  select l.pf_judicial_anotado, l.lote_id into v_linha
    from linhas_importadas l join tarefas t on t.id = l.tarefa_id
   where coalesce(t.unificada_em, t.id) = v_t and l.situacao = 'valida'
   order by l.lote_id desc, l.id desc limit 1;

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
        v_estado text := p_estado_trava; v_verif jsonb := '{}'; v_tem_inicio boolean; v_pfj date;
        v_min int := coalesce(param_int('justificativa_minimo_caracteres'), 15);
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

  select id, ocorrido_em into v_ex from eventos where chave_dedupe = 'ext:' || p_id_cliente;
  if found then return jsonb_build_object('status','ja_registrado','evento_id',v_ex.id,'ocorrido_em',v_ex.ocorrido_em); end if;

  v_t := _tarefa_por_advbox(p_advbox_id, coalesce(p_snapshot,'{}'));
  v_tem_inicio := exists (select 1 from eventos e join tarefas t on t.id = e.tarefa_id
                           where coalesce(t.unificada_em, t.id) = v_t and e.tipo = 'inicio_tratativa');

  if p_tipo = 'inicio_tratativa' then
    select e.id, e.ocorrido_em into v_ex from eventos e join tarefas t on t.id = e.tarefa_id
     where coalesce(t.unificada_em, t.id) = v_t and e.tipo = 'inicio_tratativa' order by e.ocorrido_em limit 1;
    if found then
      return jsonb_build_object('status','ja_iniciada','evento_id',v_ex.id,'ocorrido_em',v_ex.ocorrido_em);
    end if;
  end if;

  -- A4: o servidor confere o que consegue conferir. 'bloqueio_efetivo' e
  -- 'nao_monitorada' descrevem o que aconteceu na tela e ficam como declarados.
  if v_estado = 'permitida_apos_validacao' then
    select l.pf_judicial_anotado into v_pfj from linhas_importadas l join tarefas t on t.id = l.tarefa_id
     where coalesce(t.unificada_em, t.id) = v_t and l.situacao = 'valida' order by l.lote_id desc, l.id desc limit 1;
    if p_tipo = 'tentativa_conclusao' and not v_tem_inicio then
      v_estado := 'violacao_detectada';
      v_verif := jsonb_build_object('motivo_servidor','Conclusão declarada como permitida, mas não há início da tratativa registrado.');
    elsif p_tipo = 'tentativa_alteracao_pf' and v_pfj is not null then
      v_estado := 'violacao_detectada';
      v_verif := jsonb_build_object('motivo_servidor','Prazo fatal alterado em tarefa com PF Judicial anotado ('||to_char(v_pfj,'DD/MM/YYYY')||').');
    elsif p_tipo = 'tentativa_alteracao_pf' and v_papel <> 'admin' then
      v_estado := 'violacao_detectada';
      v_verif := jsonb_build_object('motivo_servidor','Alteração de prazo fatal sem perfil de controladoria.');
    elsif p_tipo in ('tentativa_realocacao','tentativa_alteracao_pf')
          and length(regexp_replace(btrim(coalesce(p_justificativa,'')), '\s+', ' ', 'g')) < v_min then
      v_estado := 'violacao_detectada';
      v_verif := jsonb_build_object('motivo_servidor','Justificativa ausente ou menor que '||v_min||' caracteres.');
    end if;
  end if;
  v_verif := v_verif || jsonb_build_object(
    'estado_declarado', p_estado_trava,
    'estado_conferido_servidor', p_estado_trava in ('permitida_apos_validacao','excecao_autorizada','violacao_detectada'),
    'reclassificado_servidor', v_estado is distinct from p_estado_trava);

  insert into eventos (chave_dedupe, tarefa_id, tipo, ocorrido_em, precisao_ocorrido, colaborador_id,
                       justificativa, origem, historico_recuperado, classificacao, estado_trava, evidencia)
  values ('ext:' || p_id_cliente, v_t, p_tipo, now(), 'segundo', v_colab,
          nullif(btrim(p_justificativa),''), 'extensao', false, 'confirmado', v_estado,
          coalesce(p_evidencia,'{}') || case when p_tipo = 'inicio_tratativa' then '{}'::jsonb else v_verif end
          || jsonb_build_object(
            'advbox_id', p_advbox_id, 'usuario', auth.uid(), 'horario_cliente', p_horario_cliente,
            'tela', coalesce(p_snapshot,'{}'),
            'mecanismo', 'extensao_navegador (atua somente na tela, com a extensão ativa)'))
  returning id into v_id;

  return jsonb_build_object('status','registrado','evento_id',v_id,'ocorrido_em',now(),'tarefa_id',v_t,
                            'estado_trava', v_estado);
end $$;

-- ---------------------------------------------------------------- A6: privilégios
revoke execute on all functions in schema public from public, anon;
grant  execute on all functions in schema public to authenticated;
do $$ declare f text;
begin
  foreach f in array array[
    'public._gerar_eventos_importacao(bigint, timestamptz)',
    'public._importar_arquivo_base(text, text, jsonb, bigint, timestamptz)',
    'public._tarefa_por_advbox(text, jsonb)',
    'public._candidatos_tela(jsonb, bigint)',
    'public._tem_linha_no_lote(bigint, bigint)',
    'public._unificar(bigint, bigint, text, jsonb)',
    'public._unificar_apos_importacao(bigint)',
    'public._dt_tela(text)', 'public._ts_tela(text)',
    'public.tg_bloqueia_alteracao()', 'public.tg_importacao_fechada()', 'public.tg_linha_imutavel()'] loop
    execute format('revoke execute on function %s from public, anon, authenticated', f);
  end loop;
end $$;

grant select on public.v_tarefas_atuais, public.v_tarefas_sem_linha_atual to authenticated;
revoke all on public.v_tarefas_atuais, public.v_tarefas_sem_linha_atual from anon;
