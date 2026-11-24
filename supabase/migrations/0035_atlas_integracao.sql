-- =====================================================================
-- 0035 — Atlas Gestor como sistema principal (11/11/2026)
-- Decisão da coordenação: as tarefas da equipe passam a ser as do Atlas Gestor
-- (gestor.atlasjus.com), lidas pela API do Atlas (list_tasks). O ADVBOX fica como histórico.
--  * cada sincronização com o Atlas é uma "fotografia" (lote), como a importação do Excel:
--    indicadores, D-4/D-7, reagendamentos, trocas de responsável e de prazo continuam iguais;
--  * a tarefa é identificada pelo ID do Atlas (uuid): chave 'AT:<uuid>', método 'atlas_id';
--    o uuid fica também em tarefas.advbox_id ("ID externo" usado pela extensão), sem colisão com
--    os IDs numéricos do ADVBOX;
--  * colaboradores ganham atlas_user_id; os nomes do Atlas são casados com os já existentes;
--  * novo papel 'lider' (Brenda Martins, Pedro Frejah, Raquel Guerra, Guilherme Ladeia, Ana Clara):
--    altera data, responsável e prazo fatal sem bloqueio da extensão; tudo registrado
--    (exceção autorizada). A trava de conclusão sem início continua valendo para eles.
-- A chave da API do Atlas NÃO fica no banco: só como segredo da Edge Function atlas-sync.
-- =====================================================================

alter table public.tarefas add column if not exists atlas_id uuid unique;
alter table public.tarefas drop constraint if exists tarefas_metodo_check;
alter table public.tarefas add constraint tarefas_metodo_check
  check (metodo in ('chave_estavel','chave_ocorrencia','advbox_id','atlas_id'));
alter table public.linhas_importadas drop constraint if exists linhas_importadas_metodo_vinculo_check;
alter table public.linhas_importadas add constraint linhas_importadas_metodo_vinculo_check
  check (metodo_vinculo in ('chave_estavel','chave_ocorrencia','ambigua','atlas_id'));

alter table public.colaboradores add column if not exists atlas_user_id uuid unique;
alter table public.colaboradores drop constraint if exists colaboradores_origem_check;
alter table public.colaboradores add constraint colaboradores_origem_check
  check (origem in ('excel_importacao','administrativo','atlas'));

alter table public.perfis drop constraint if exists perfis_papel_check;
alter table public.perfis add constraint perfis_papel_check check (papel in ('admin','colaborador','lider'));

alter table public.lotes_importacao add column if not exists origem text not null default 'excel_advbox';
alter table public.lotes_importacao drop constraint if exists lotes_importacao_origem_check;
alter table public.lotes_importacao add constraint lotes_importacao_origem_check
  check (origem in ('excel_advbox','atlas'));

insert into public.parametros (chave, valor, confirmado, descricao) values
  ('atlas_lideres', '["Brenda Martins","Pedro Frejah","Raquel Guerra","Guilherme Ladeia","Ana Clara"]', true,
   'Líderes definidos pela coordenação em 11/11/2026: podem alterar as tarefas (data, responsável, prazo fatal) '
   || 'sem bloqueio da extensão; tudo fica registrado. O acesso de cada um é dado no painel (Configurações › Usuários, papel Líder).'),
  ('atlas_concluidas_dias', '90', true,
   'Na sincronização com o Atlas, traz também as tarefas concluídas com prazo nos últimos N dias (para registrar as conclusões).')
on conflict (chave) do nothing;

-- ---------------------------------------------------------------- usuários do Atlas -> colaboradores
create or replace function public._nome_normalizado(p text) returns text
language sql immutable set search_path = public as $$
  select regexp_replace(upper(btrim(translate(coalesce(p,''),
    'ÁÀÂÃÄáàâãäÉÈÊËéèêëÍÌÎÏíìîïÓÒÔÕÖóòôõöÚÙÛÜúùûüÇçÑñ',
    'AAAAAaaaaaEEEEeeeeIIIIiiiiOOOOOoooooUUUUuuuuCcNn'))), '\s+', ' ', 'g')
$$;

-- Recebe [{id, name}] dos responsáveis/autores vistos no Atlas e devolve {id: nome no sistema}.
-- Casa por atlas_user_id; senão pelo nome (sem acento/maiúsculas) com um colaborador ainda sem
-- vínculo; senão cria o colaborador (origem 'atlas').
create or replace function public.atlas_mapear_usuarios(p_usuarios jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare u jsonb; v_id bigint; v_nome text; v_res jsonb := '{}'; v_uid uuid;
begin
  if not is_admin() then raise exception 'Somente a controladoria sincroniza com o Atlas' using errcode = '42501'; end if;
  if jsonb_typeof(p_usuarios) <> 'array' then raise exception 'p_usuarios deve ser uma lista'; end if;
  for u in select * from jsonb_array_elements(p_usuarios) loop
    begin v_uid := (u->>'id')::uuid; exception when others then raise exception 'ID de usuário do Atlas inválido: %', u->>'id'; end;
    v_nome := nullif(btrim(u->>'name'), '');
    select id, nome_advbox into v_id, v_nome from colaboradores where atlas_user_id = v_uid;
    if v_id is null then
      v_nome := coalesce(nullif(btrim(u->>'name'), ''), 'USUÁRIO ATLAS ' || left(v_uid::text, 8));
      select id into v_id from colaboradores
       where atlas_user_id is null and _nome_normalizado(nome_advbox) = _nome_normalizado(v_nome)
       order by id limit 1;
      if v_id is not null then
        update colaboradores set atlas_user_id = v_uid where id = v_id;
        select nome_advbox into v_nome from colaboradores where id = v_id;
      else
        insert into colaboradores (nome_advbox, origem, atlas_user_id) values (v_nome, 'atlas', v_uid)
        on conflict (nome_advbox) do nothing returning id into v_id;
        if v_id is null then
          -- nome igual a um colaborador que já tem outro usuário do Atlas: diferencia
          v_nome := v_nome || ' (' || left(v_uid::text, 8) || ')';
          insert into colaboradores (nome_advbox, origem, atlas_user_id) values (v_nome, 'atlas', v_uid) returning id into v_id;
        end if;
      end if;
    end if;
    v_res := v_res || jsonb_build_object(v_uid::text, v_nome);
  end loop;
  return v_res;
end $$;
revoke execute on function public.atlas_mapear_usuarios(jsonb) from public, anon;
grant execute on function public.atlas_mapear_usuarios(jsonb) to authenticated;

-- ---------------------------------------------------------------- importação: vínculo pelo ID do Atlas
do $$
declare d text; ancora text := 'update _vinc set metodo = ''ambigua'' where chave is null;';
begin
  d := pg_get_functiondef('public._importar_arquivo_base(text, text, jsonb, bigint, timestamptz)'::regprocedure);
  if position('0035: atlas' in d) > 0 then return; end if;
  if (length(d) - length(replace(d, ancora, ''))) / length(ancora) <> 1 then
    raise exception '0035: trecho esperado não encontrado em _importar_arquivo_base';
  end if;
  d := replace(d, ancora, ancora || $blk$
  -- 0035: atlas. Linha vinda do Atlas: a tarefa é a do ID do Atlas (sem chave estável nem ambiguidade).
  update _vinc v set chave = 'AT:' || lower(l.dados_brutos->>'_atlas_id'), metodo = 'atlas_id'
    from linhas_importadas l where l.id = v.id and l.dados_brutos ? '_atlas_id';
  insert into tarefas (chave_identificacao, metodo, advbox_id, atlas_id)
  select distinct v.chave, 'atlas_id', substr(v.chave, 4), substr(v.chave, 4)::uuid
    from _vinc v where v.metodo = 'atlas_id'
  on conflict (chave_identificacao) do nothing;
  update lotes_importacao set origem = 'atlas'
   where id = v_lote and exists (select 1 from _vinc where metodo = 'atlas_id');$blk$);
  execute d;
end $$;

-- A extensão chama com o ID da tarefa na tela: número (ADVBOX) ou uuid (Atlas).
create or replace function public._eh_uuid(p text) returns boolean
language sql immutable set search_path = public as $$
  select coalesce(p ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$', false)
$$;

do $$
declare d text;
begin
  d := pg_get_functiondef('public._tarefa_por_advbox(text, jsonb)'::regprocedure);
  if position('0035: atlas' in d) > 0 then return; end if;
  d := replace(d, $a$begin
  select coalesce(unificada_em, id) into v_id from tarefas where advbox_id = p_advbox_id;$a$, $b$begin
  -- 0035: atlas. Tarefa do Atlas (uuid): identificada pelo ID, sem candidatos da tela.
  if _eh_uuid(p_advbox_id) then
    p_advbox_id := lower(p_advbox_id);
    insert into tarefas (chave_identificacao, metodo, advbox_id, atlas_id)
    values ('AT:' || p_advbox_id, 'atlas_id', p_advbox_id, p_advbox_id::uuid)
    on conflict (chave_identificacao) do nothing;
    select coalesce(unificada_em, id) into v_id from tarefas where chave_identificacao = 'AT:' || p_advbox_id;
    if p_snap ? 'titulo' then
      update tarefas set ultimo_snapshot = p_snap, ultimo_snapshot_em = now() where id = v_id;
    end if;
    return v_id;
  end if;
  select coalesce(unificada_em, id) into v_id from tarefas where advbox_id = p_advbox_id;$b$);
  if position('0035: atlas' in d) = 0 then raise exception '0035: trecho esperado não encontrado em _tarefa_por_advbox'; end if;
  execute d;
end $$;

-- validação do ID nas funções da extensão + líderes
do $$
declare f text; d text; n int;
  re_antigo text := $r$'^\d{1,15}$'$r$;
  re_novo text := $r$'^(\d{1,15}|[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})$' /* 0035 */$r$;
  modo_real text := $m$'realocacao', (select valor #>> '{}' from parametros where chave='trava_realocacao_modo')$m$;
  modo_real_n text := $m$'realocacao', case when v_papel = 'lider' then 'lider_livre' else (select valor #>> '{}' from parametros where chave='trava_realocacao_modo') end$m$;
  modo_pf text := $m$'pf', (select valor #>> '{}' from parametros where chave='trava_pf_modo')$m$;
  modo_pf_n text := $m$'pf', case when v_papel = 'lider' then 'lider_livre' else (select valor #>> '{}' from parametros where chave='trava_pf_modo') end$m$;
begin
  foreach f in array array['public.ext_status_tarefa(text, jsonb)',
                           'public.ext_registrar_evento(uuid, text, text, jsonb, text, text, jsonb, timestamptz)',
                           'public.ext_inicios_por_ids(text[])'] loop
    d := pg_get_functiondef(f::regprocedure);
    if position('/* 0035 */' in d) > 0 then continue; end if;
    n := (length(d) - length(replace(d, re_antigo, ''))) / length(re_antigo);
    if n <> 1 then raise exception '0035: validação de ID não encontrada em %', f; end if;
    d := replace(d, re_antigo, re_novo);
    if f <> 'public.ext_registrar_evento(uuid, text, text, jsonb, text, text, jsonb, timestamptz)' then
      if position(modo_real in d) = 0 or position(modo_pf in d) = 0 then raise exception '0035: modos não encontrados em %', f; end if;
      d := replace(replace(d, modo_real, modo_real_n), modo_pf, modo_pf_n);
    else
      d := replace(d, $x$if p_estado_trava = 'excecao_autorizada' and v_papel <> 'admin' then$x$,
        $x$if p_estado_trava = 'excecao_autorizada' and not (v_papel = 'admin'
       or (v_papel = 'lider' and p_tipo in ('tentativa_realocacao','tentativa_alteracao_pf'))) then$x$);
      if position($x$v_papel = 'lider' and p_tipo in$x$ in d) = 0 then raise exception '0035: regra de exceção não encontrada'; end if;
    end if;
    execute d;
  end loop;
end $$;

-- ---------------------------------------------------------------- papel 'lider' no painel
do $$
declare d text;
begin
  d := pg_get_functiondef('public.admin_definir_perfil(uuid, text, bigint, text)'::regprocedure);
  if position('0035' in d) > 0 then return; end if;
  d := replace(d, $a$p_papel not in ('admin','colaborador')$a$, $a$p_papel not in ('admin','colaborador','lider') /* 0035 */$a$);
  d := replace(d, $a$if p_papel = 'colaborador' and (p_colaborador_id is null$a$, $a$if p_papel in ('colaborador','lider') and (p_colaborador_id is null$a$);
  d := replace(d, $a$case when p_papel = 'colaborador' then p_colaborador_id end$a$, $a$case when p_papel in ('colaborador','lider') then p_colaborador_id end$a$);
  if position($a$p_papel in ('colaborador','lider') then p_colaborador_id$a$ in d) = 0 then
    raise exception '0035: admin_definir_perfil não reconhecido';
  end if;
  execute d;
end $$;

-- ---------------------------------------------------------------- funções de apoio da Edge Function atlas-sync
alter table public.log_integracao drop constraint if exists log_integracao_origem_check;
alter table public.log_integracao add constraint log_integracao_origem_check check (origem in
  ('advbox_extensao','webjur_portal','webjur_gmail','webjur_email','importacao_excel','sistema','atlas_api'));

-- a Edge Function chama primeiro: só a controladoria (admin) usa a API do Atlas
create or replace function public.atlas_conferir_acesso(p_acao text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Somente a controladoria usa a integração com o Atlas' using errcode = '42501'; end if;
  if p_acao not in ('testar','sincronizar','criar_tarefa') then raise exception 'Ação desconhecida: %', p_acao; end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.atlas_parametro(p_chave text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Somente a controladoria' using errcode = '42501'; end if;
  if p_chave not like 'atlas\_%' and p_chave not like 'tarefa\_analise\_%' then raise exception 'Parâmetro não disponível'; end if;
  return (select valor from parametros where chave = p_chave);
end $$;

create or replace function public.atlas_registrar(p_operacao text, p_nivel text, p_detalhe jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Somente a controladoria' using errcode = '42501'; end if;
  if p_nivel not in ('info','aviso','erro') then raise exception 'Nível inválido'; end if;
  perform registrar_log_integracao('atlas_api', p_nivel, left(coalesce(p_operacao,''), 60),
    case when p_nivel = 'erro' then coalesce(p_detalhe->>'mensagem', 'Erro na API do Atlas')
         else 'Sincronização com o Atlas: ' || coalesce(p_detalhe->>'tarefas','?') || ' tarefas' end,
    coalesce(p_detalhe, '{}'));
end $$;

-- ---------------------------------------------------------------- tarefas de análise criadas no Atlas (create_task)
alter table public.tarefas_analise add column if not exists atlas_tarefa_id uuid unique;
alter table public.tarefas_analise add column if not exists atlas_app_url text;

insert into public.parametros (chave, valor, confirmado, descricao) values
  ('tarefa_analise_destino', '"atlas"', true,
   'Onde as tarefas de análise são criadas: atlas (API do Atlas, create_task) ou advbox (extensão na tela do ADVBOX). Atlas desde 11/11/2026.'),
  ('tarefa_analise_responsavel_email', '"mayra.gomes.oecadv@gmail.com"', true,
   'E-mail no Atlas da responsável pelas tarefas de análise (conta da controladoria, informada em 11/11/2026).')
on conflict (chave) do nothing;

create or replace function public._analise_destino() returns text
language sql stable set search_path = public as $$
  select coalesce((select valor #>> '{}' from parametros where chave = 'tarefa_analise_destino'), 'advbox')
$$;

-- com destino Atlas, a extensão não cria tarefa de análise na tela do ADVBOX
do $$
declare d text; a text := $a$'proxima', (select id from tarefas_analise where status = 'aprovada' and bloqueio_criacao is null order by teste desc, id limit 1),$a$;
begin
  d := pg_get_functiondef('public.ext_analise_fila()'::regprocedure);
  if position('0035' in d) > 0 then return; end if;
  if position(a in d) = 0 then raise exception '0035: ext_analise_fila não reconhecida'; end if;
  d := replace(d, a, $b$'proxima', case when _analise_destino() = 'atlas' then null /* 0035: criadas pela API do Atlas */ else (select id from tarefas_analise where status = 'aprovada' and bloqueio_criacao is null order by teste desc, id limit 1) end, 'destino', _analise_destino(),$b$);
  execute d;
end $$;

-- 1º passo da criação no Atlas: mesmas conferências de antes (analise_iniciar_criacao) e o corpo do create_task
create or replace function public.analise_dados_para_atlas(p_id bigint)
returns jsonb language plpgsql security definer set search_path = public as $$
declare i jsonb; t record;
begin
  if not is_admin() then raise exception 'Somente a controladoria cria tarefas' using errcode = '42501'; end if;
  if _analise_destino() <> 'atlas' then raise exception 'As tarefas de análise estão configuradas para o ADVBOX'; end if;
  i := analise_iniciar_criacao(p_id);       -- confere bloqueio e conferência; status aprovada -> criacao_em_andamento
  select * into t from tarefas_analise where id = p_id;
  return jsonb_build_object('tentativa', (i->>'tentativa')::int,
    'idempotencia', 'controladoria-analise-' || p_id || '-' || (i->>'tentativa'),
    'payload', jsonb_strip_nulls(jsonb_build_object(
      'title', left(coalesce(nullif(btrim(t.tipo), ''), 'ANÁLISE DO CASO') || coalesce(' — ' || t.cnj, ''), 500),
      'description', left(coalesce(t.observacoes, ''), 10000),
      'priority', 'normal',
      'dueDate', t.data_prevista,
      'fatalDate', t.pf_previsto,
      'assigneeEmail', (select valor #>> '{}' from parametros where chave = 'tarefa_analise_responsavel_email'))));
end $$;

create or replace function public.analise_confirmar_atlas(p_id bigint, p_tentativa int, p_resposta jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_task uuid;
begin
  if not is_admin() then raise exception 'Somente a controladoria' using errcode = '42501'; end if;
  begin v_task := (p_resposta->>'taskId')::uuid; exception when others then v_task := null; end;
  if v_task is null then raise exception 'Resposta do Atlas sem taskId'; end if;
  perform _analise_status(p_id, array['criacao_em_andamento','verificar_no_advbox'], 'criada', null,
    jsonb_build_object('atlas_tarefa_id', v_task, 'tentativa', p_tentativa, 'resposta_atlas', p_resposta, 'via', 'api_atlas'));
  update tarefas_analise set atlas_tarefa_id = v_task, atlas_app_url = p_resposta->>'appUrl', criada_no_advbox_em = now()
   where id = p_id;
  return jsonb_build_object('id', p_id, 'status', 'criada', 'atlas_tarefa_id', v_task, 'app_url', p_resposta->>'appUrl',
                            'avisos', p_resposta->'warnings');
end $$;

-- Erro devolvido pelo Atlas antes de gravar (validação, permissão, chave) = certeza de que não criou:
-- volta para "aprovada". Falha de rede/erro interno = pode ter criado: vai para "verificar".
create or replace function public.analise_falha_atlas(p_id bigint, p_erro text, p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_certeza boolean := coalesce(p_code, '') in ('validation_error','permission_denied','not_found','read_only_key',
  'invalid_api_key','missing_api_key','api_not_in_plan','tenant_inactive','invalid_request','unknown_action','sem_chave',
  'no_active_admin','rate_limited','idempotency_conflict');
begin
  if not is_admin() then raise exception 'Somente a controladoria' using errcode = '42501'; end if;
  if (select status from tarefas_analise where id = p_id) <> 'criacao_em_andamento' then
    return jsonb_build_object('id', p_id, 'status', (select status from tarefas_analise where id = p_id));
  end if;
  perform _analise_status(p_id, array['criacao_em_andamento'],
    case when v_certeza then 'aprovada' else 'verificar_no_advbox' end,
    'Atlas: ' || coalesce(p_erro, '(sem mensagem)'), jsonb_build_object('erro', p_erro, 'code', p_code, 'via', 'api_atlas'));
  perform registrar_log_integracao('atlas_api', 'erro', 'criar_tarefa_analise', coalesce(p_erro,'(sem mensagem)'),
    jsonb_build_object('tarefa_analise_id', p_id, 'code', p_code, 'certeza_nao_criada', v_certeza));
  return jsonb_build_object('id', p_id, 'status', (select status from tarefas_analise where id = p_id));
end $$;

revoke execute on function public.atlas_conferir_acesso(text), public.atlas_parametro(text), public.atlas_registrar(text,text,jsonb),
  public.analise_dados_para_atlas(bigint), public.analise_confirmar_atlas(bigint,int,jsonb), public.analise_falha_atlas(bigint,text,text)
  from public, anon;
grant execute on function public.atlas_conferir_acesso(text), public.atlas_parametro(text), public.atlas_registrar(text,text,jsonb),
  public.analise_dados_para_atlas(bigint), public.analise_confirmar_atlas(bigint,int,jsonb), public.analise_falha_atlas(bigint,text,text)
  to authenticated;
revoke execute on function public._eh_uuid(text), public._nome_normalizado(text), public._analise_destino() from public, anon;

-- lista do painel: ID e link da tarefa no Atlas e o destino configurado
do $$
declare d text;
begin
  d := pg_get_functiondef('public.analise_listar(text)'::regprocedure);
  if position('atlas_tarefa_id' in d) > 0 then return; end if;
  if position('t.advbox_tarefa_id, t.criada_no_advbox_em,' in d) = 0 then raise exception '0035: analise_listar não reconhecida'; end if;
  d := replace(d, 't.advbox_tarefa_id, t.criada_no_advbox_em,', 't.advbox_tarefa_id, t.atlas_tarefa_id, t.atlas_app_url, _analise_destino() as destino, t.criada_no_advbox_em,');
  execute d;
end $$;
