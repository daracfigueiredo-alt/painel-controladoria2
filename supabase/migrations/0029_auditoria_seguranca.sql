-- =====================================================================
-- 0029 — Etapa 9: auditoria e segurança (10/11/2026)
-- Auditoria do que já existia (banco de homologação, 10/11/2026):
--  * 22 tabelas com RLS; papel anon sem acesso; usuários logados não gravam direto em
--    nenhuma tabela; 31 funções SECURITY DEFINER — todas chamadas de verdade como
--    colaborador e como usuário sem perfil: as de administrador recusaram as duas.
--  * Lacunas tratadas aqui:
--    1. alterações de parâmetros, perfis, calendário, colaboradores e equipes não guardavam
--       o antes/depois nem quem alterou  -> tabela auditoria_configuracao + gatilhos;
--    2. registros imutáveis barravam UPDATE/DELETE, mas não TRUNCATE -> gatilho de instrução;
--    3. qualquer perfil podia gravar direto no log de integração -> só o próprio sistema;
--    4. não havia visão única do histórico (Prompt Mestre §23) -> auditoria_linha_tempo();
--    5. não havia conferência de integridade -> auditoria_integridade();
--    6. área "Configurações administrativas": parâmetros, perfis e calendário só mudam por
--       funções que exigem motivo e ficam registradas.
-- Nada é apagado. O histórico anterior à implantação continua marcado como "recuperado".
-- =====================================================================

-- ---------------------------------------------------------------- 1. auditoria de configuração
create table if not exists public.auditoria_configuracao (
  id          bigint generated always as identity primary key,
  ocorrido_em timestamptz not null default now(),
  tabela      text not null,
  chave       text not null,
  operacao    text not null check (operacao in ('INSERT','UPDATE','DELETE')),
  antes       jsonb,
  depois      jsonb,
  usuario     uuid,
  motivo      text
);
create index if not exists auditoria_configuracao_em_idx on public.auditoria_configuracao (ocorrido_em desc);
alter table public.auditoria_configuracao enable row level security;
drop policy if exists auditoria_configuracao_leitura on public.auditoria_configuracao;
create policy auditoria_configuracao_leitura on public.auditoria_configuracao for select to authenticated using (public.is_admin());
revoke all on public.auditoria_configuracao from anon, authenticated;
grant select on public.auditoria_configuracao to authenticated;
drop trigger if exists auditoria_configuracao_imutavel on public.auditoria_configuracao;
create trigger auditoria_configuracao_imutavel before update or delete on public.auditoria_configuracao
  for each row execute function public.tg_bloqueia_alteracao();

create or replace function public.tg_auditar_configuracao() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_antes jsonb := case when tg_op <> 'INSERT' then to_jsonb(old) end;
        v_depois jsonb := case when tg_op <> 'DELETE' then to_jsonb(new) end;
        v_chave text;
begin
  if tg_op = 'UPDATE' and v_antes = v_depois then return null; end if;
  v_chave := coalesce(v_depois, v_antes) ->> (case tg_table_name when 'parametros' then 'chave' when 'perfis' then 'user_id' else 'id' end);
  insert into auditoria_configuracao (tabela, chave, operacao, antes, depois, usuario, motivo)
  values (tg_table_name, coalesce(v_chave, '?'), tg_op, v_antes, v_depois, auth.uid(),
          nullif(current_setting('controladoria.motivo', true), ''));
  return null;
end $$;
revoke execute on function public.tg_auditar_configuracao() from public, anon, authenticated;

do $$ declare t text; begin
  foreach t in array array['parametros','perfis','calendario_dias_nao_uteis','colaboradores','equipes'] loop
    execute format('drop trigger if exists %I on public.%I', t || '_auditoria', t);
    execute format('create trigger %I after insert or update or delete on public.%I for each row execute function public.tg_auditar_configuracao()', t || '_auditoria', t);
  end loop;
end $$;

-- ---------------------------------------------------------------- 2. TRUNCATE também é barrado
do $$ declare t text; begin
  foreach t in array array['eventos','linhas_importadas','importacoes','lotes_importacao','publicacoes','publicacoes_coletas',
                           'webjur_remessas','conferencias_publicacao','conferencias_alerta','advbox_intimacoes',
                           'advbox_intimacoes_vistas','advbox_varreduras','log_integracao','tarefas_analise',
                           'tarefas_analise_historico','auditoria_configuracao','tarefas','processos'] loop
    execute format('drop trigger if exists %I on public.%I', t || '_sem_truncate', t);
    execute format('create trigger %I before truncate on public.%I for each statement execute function public.tg_bloqueia_alteracao()', t || '_sem_truncate', t);
  end loop;
end $$;

-- ---------------------------------------------------------------- 3. log de integração: só o sistema grava
-- (as funções do próprio banco continuam gravando, porque rodam como dono)
revoke execute on function public.registrar_log_integracao(text, text, text, text, jsonb) from authenticated;

-- índice para a linha do tempo
create index if not exists eventos_ocorrido_idx on public.eventos (ocorrido_em desc);

-- ---------------------------------------------------------------- 4. histórico de auditoria (§23)
create or replace function public._auditoria_categoria(p_tipo text) returns text
language sql immutable set search_path = public as $$
  select case
    when p_tipo = 'importacao' then 'importacao'
    when p_tipo in ('inicio_tratativa','conclusao','tentativa_conclusao') then 'tratativa'
    when p_tipo in ('alteracao_responsavel','encaminhamento','anotacao_realocacao','tentativa_realocacao','unificacao_tarefa') then 'responsavel'
    when p_tipo in ('alteracao_data_agenda','pedido_reagendamento') then 'reagendamento'
    when p_tipo in ('alteracao_pf_tarefa','tentativa_alteracao_pf') then 'prazo_fatal'
    when p_tipo = 'publicacao_recebida' then 'publicacao'
    when p_tipo = 'publicacao_conferida' then 'conferencia'
    when p_tipo = 'tarefa_analise_status' then 'tarefa_analise'
    when p_tipo = 'erro_integracao' then 'integracao'
    when p_tipo in ('conferencia_alerta','cadastro_administrativo') then 'administrativo'
    else 'outros' end
$$;

create or replace function public.auditoria_linha_tempo(p_inicio date, p_fim date, p_categoria text default null,
                                                        p_busca text default null, p_limite int default 500)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_ini timestamptz; v_fim timestamptz; v_lim int := least(greatest(coalesce(p_limite, 500), 1), 2000);
        v_busca text := nullif(btrim(coalesce(p_busca, '')), ''); v_res jsonb; v_total bigint;
begin
  if not is_admin() then raise exception 'Somente a controladoria' using errcode = '42501'; end if;
  if p_inicio is null or p_fim is null or p_fim < p_inicio then raise exception 'Período inválido'; end if;
  if p_fim - p_inicio > 366 then raise exception 'Período máximo: 1 ano'; end if;
  v_ini := (p_inicio::timestamp) at time zone 'America/Sao_Paulo';
  v_fim := ((p_fim + 1)::timestamp) at time zone 'America/Sao_Paulo';
  with u as (
    select e.ocorrido_em as em, _auditoria_categoria(e.tipo) as categoria, e.tipo,
           e.origem, e.historico_recuperado as recuperado, e.classificacao, e.precisao_ocorrido as precisao,
           coalesce(c.nome_advbox, e.colaborador_txt, us.email) as quem,
           coalesce(tp.advbox_id, t.advbox_id) as advbox_id,
           coalesce(l.processo_cnj, e.evidencia->>'cnj', e.valor_novo->>'cnj') as cnj,
           e.valor_anterior as antes, e.valor_novo as depois, e.justificativa, e.estado_trava,
           e.evidencia, 'eventos' as tabela, e.id::text as ref
      from eventos e
      left join colaboradores c on c.id = e.colaborador_id
      left join tarefas t on t.id = e.tarefa_id
      left join tarefas tp on tp.id = t.unificada_em
      left join linhas_importadas l on l.id = e.linha_id
      left join auth.users us on us.id = nullif(e.evidencia->>'usuario', '')::uuid
     where e.ocorrido_em >= v_ini and e.ocorrido_em < v_fim
    union all
    select g.ocorrido_em, 'integracao', 'log_' || g.nivel, g.origem, false, 'confirmado', 'segundo', us.email, null, null,
           null, null, null, null, jsonb_build_object('operacao', g.operacao, 'mensagem', g.mensagem) || g.detalhe, 'log_integracao', g.id::text
      from log_integracao g left join auth.users us on us.id = g.usuario
     where g.ocorrido_em >= v_ini and g.ocorrido_em < v_fim and g.nivel <> 'erro'   -- erros já estão em eventos
    union all
    select v.realizada_em, 'varredura', 'varredura_advbox', v.origem, false, 'confirmado', 'segundo', us.email, null, null,
           null, null, null, null,
           jsonb_build_object('pagina', v.pagina, 'recebido_de', v.recebido_de, 'recebido_ate', v.recebido_ate,
                              'total_informado', v.total_informado, 'total_lido', v.total_lido, 'completa', v.completa, 'erros', v.erros),
           'advbox_varreduras', v.id::text
      from advbox_varreduras v left join auth.users us on us.id = v.realizada_por
     where v.realizada_em >= v_ini and v.realizada_em < v_fim
    union all
    select a.ocorrido_em, 'configuracao', a.tabela || '_' || lower(a.operacao), 'administrativo', false, 'confirmado', 'segundo', us.email,
           null, null, a.antes, a.depois, a.motivo, null, jsonb_build_object('tabela', a.tabela, 'chave', a.chave), 'auditoria_configuracao', a.id::text
      from auditoria_configuracao a left join auth.users us on us.id = a.usuario
     where a.ocorrido_em >= v_ini and a.ocorrido_em < v_fim
  ), f as (
    select * from u
     where (p_categoria is null or categoria = p_categoria)
       and (v_busca is null or advbox_id = v_busca or cnj ilike '%' || v_busca || '%' or quem ilike '%' || v_busca || '%'
            or tipo ilike '%' || v_busca || '%' or evidencia::text ilike '%' || v_busca || '%')
  )
  select (select count(*) from f), coalesce((select jsonb_agg(to_jsonb(x) order by x.em desc) from (select * from f order by em desc limit v_lim) x), '[]')
    into v_total, v_res;
  return jsonb_build_object('total', v_total, 'limite', v_lim, 'truncado', v_total > v_lim, 'itens', v_res);
end $$;

-- ---------------------------------------------------------------- 5. integridade
create or replace function public.auditoria_integridade()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare r jsonb := '[]';
begin
  if not is_admin() then raise exception 'Somente a controladoria' using errcode = '42501'; end if;
  -- cada verificação: codigo, gravidade (erro | alerta | info), descricao, quantidade, exemplos
  r := r || (select jsonb_build_object('codigo','analise_criada_sem_id','gravidade','erro',
        'descricao','Tarefa de análise "criada" sem ID da tarefa no ADVBOX','quantidade',count(*),'exemplos',coalesce(jsonb_agg(id) filter (where id is not null),'[]'))
        from (select id from tarefas_analise where status = 'criada' and advbox_tarefa_id is null limit 20) x);
  r := r || (select jsonb_build_object('codigo','analise_id_repetido','gravidade','erro',
        'descricao','O mesmo ID de tarefa do ADVBOX registrado em mais de uma tarefa de análise','quantidade',count(*),'exemplos',coalesce(jsonb_agg(advbox_tarefa_id),'[]'))
        from (select advbox_tarefa_id from tarefas_analise where advbox_tarefa_id is not null group by 1 having count(*) > 1 limit 20) x);
  r := r || (select jsonb_build_object('codigo','analise_duplicada','gravidade','erro',
        'descricao','Mais de uma tarefa de análise ativa ou criada para a mesma publicação','quantidade',count(*),'exemplos',coalesce(jsonb_agg(publicacao_id),'[]'))
        from (select publicacao_id from tarefas_analise where publicacao_id is not null and status not in ('rejeitada','ja_tratada')
               group by 1 having count(*) > 1 limit 20) x);
  r := r || (select jsonb_build_object('codigo','analise_presa','gravidade','alerta',
        'descricao','Criação de tarefa de análise em andamento há mais de 10 minutos','quantidade',count(*),'exemplos',coalesce(jsonb_agg(id) filter (where id is not null),'[]'))
        from (select id from tarefas_analise where status = 'criacao_em_andamento' and atualizada_em < now() - interval '10 minutes' limit 20) x);
  r := r || (select jsonb_build_object('codigo','analise_verificar','gravidade','alerta',
        'descricao','Tarefas de análise aguardando conferência no ADVBOX ("verificar no ADVBOX")','quantidade',count(*),'exemplos',coalesce(jsonb_agg(id) filter (where id is not null),'[]'))
        from (select id from tarefas_analise where status = 'verificar_no_advbox' limit 20) x);
  r := r || (select jsonb_build_object('codigo','analise_bloqueada','gravidade','alerta',
        'descricao','Tarefas de análise aprovadas e bloqueadas (nada enviado ao ADVBOX)','quantidade',count(*),'exemplos',coalesce(jsonb_agg(id) filter (where id is not null),'[]'))
        from (select id from tarefas_analise where status = 'aprovada' and bloqueio_criacao is not null limit 20) x);
  r := r || (select jsonb_build_object('codigo','publicacao_sem_conferencia','gravidade','alerta',
        'descricao','Publicações recebidas há mais de 1 dia sem nenhuma conferência no ADVBOX','quantidade',count(*),'exemplos',coalesce(jsonb_agg(id) filter (where id is not null),'[]'))
        from (select p.id from publicacoes p
               where not exists (select 1 from conferencias_publicacao c where c.publicacao_id = p.id)
                 and exists (select 1 from publicacoes_coletas k where k.publicacao_id = p.id and k.coletado_em < now() - interval '1 day')
               limit 20) x);
  r := r || (select jsonb_build_object('codigo','intimacao_em_duas_publicacoes','gravidade','erro',
        'descricao','A mesma intimação do ADVBOX ligada (conferência vigente) a duas publicações','quantidade',count(*),'exemplos',coalesce(jsonb_agg(post),'[]'))
        from (select c.evidencia->>'publicacao_advbox' post from conferencias_publicacao c
               where c.evidencia ? 'publicacao_advbox' and c.situacao = 'encontrada_advbox'
                 and c.id = (select max(y.id) from conferencias_publicacao y where y.publicacao_id = c.publicacao_id)
               group by 1 having count(distinct c.publicacao_id) > 1 limit 20) x);
  r := r || (select jsonb_build_object('codigo','unificacao_em_cadeia','gravidade','erro',
        'descricao','Tarefa unificada em outra que também está unificada (cadeia)','quantidade',count(*),'exemplos',coalesce(jsonb_agg(id) filter (where id is not null),'[]'))
        from (select t.id from tarefas t join tarefas p on p.id = t.unificada_em where p.unificada_em is not null limit 20) x);
  r := r || (select jsonb_build_object('codigo','linha_sem_tarefa','gravidade','alerta',
        'descricao','Linhas válidas do lote atual sem tarefa vinculada','quantidade',count(*),'exemplos',coalesce(jsonb_agg(id) filter (where id is not null),'[]'))
        from (select l.id from linhas_importadas l where l.situacao = 'valida' and l.tarefa_id is null
                and l.lote_id = (select lote_id from v_lote_atual) limit 20) x);
  r := r || (select jsonb_build_object('codigo','colaborador_sem_vinculo','gravidade','alerta',
        'descricao','Perfil de colaborador sem colaborador do ADVBOX vinculado (não verá tarefas)','quantidade',count(*),'exemplos','[]'::jsonb)
        from perfis where papel = 'colaborador' and colaborador_id is null);
  r := r || (select jsonb_build_object('codigo','sem_administrador','gravidade','erro',
        'descricao','Nenhum perfil de administrador','quantidade',case when count(*) = 0 then 1 else 0 end,'exemplos','[]'::jsonb)
        from perfis where papel = 'admin');
  r := r || (select jsonb_build_object('codigo','tabela_sem_rls','gravidade','erro',
        'descricao','Tabela do esquema público sem RLS','quantidade',count(*),'exemplos',coalesce(jsonb_agg(relname),'[]'))
        from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity);
  r := r || (select jsonb_build_object('codigo','anon_com_acesso','gravidade','erro',
        'descricao','Tabela legível pelo papel anônimo (sem login)','quantidade',count(*),'exemplos',coalesce(jsonb_agg(relname),'[]'))
        from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relkind in ('r','v') and has_table_privilege('anon', c.oid, 'select'));
  r := r || (select jsonb_build_object('codigo','funcao_sem_search_path','gravidade','erro',
        'descricao','Função SECURITY DEFINER sem search_path fixo','quantidade',count(*),'exemplos',coalesce(jsonb_agg(proname),'[]'))
        from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.prosecdef and p.proconfig is null);
  r := r || (select jsonb_build_object('codigo','erros_integracao_7d','gravidade','alerta',
        'descricao','Erros de integração nos últimos 7 dias','quantidade',count(*),'exemplos','[]'::jsonb)
        from log_integracao where nivel = 'erro' and ocorrido_em > now() - interval '7 days');
  r := r || (select jsonb_build_object('codigo','parametros_nao_confirmados','gravidade','info',
        'descricao','Parâmetros ainda não confirmados pela controladoria (regras provisórias)','quantidade',count(*),'exemplos',coalesce(jsonb_agg(chave),'[]'))
        from parametros where not confirmado);
  return jsonb_build_object('verificado_em', now(), 'itens', r);
end $$;

-- ---------------------------------------------------------------- 6. configurações administrativas
create or replace function public._exigir_motivo(p_motivo text) returns void
language plpgsql set search_path = public as $$
begin
  if length(btrim(coalesce(p_motivo, ''))) < 10 then raise exception 'Informe o motivo da alteração (mínimo 10 caracteres)'; end if;
  perform set_config('controladoria.motivo', btrim(p_motivo), true);
end $$;
revoke execute on function public._exigir_motivo(text) from public, anon, authenticated;

create or replace function public.admin_definir_parametro(p_chave text, p_valor jsonb, p_confirmado boolean, p_motivo text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare a record;
begin
  if not is_admin() then raise exception 'Somente administradores' using errcode = '42501'; end if;
  select * into a from parametros where chave = p_chave for update;
  if not found then raise exception 'Parâmetro % inexistente (novos parâmetros só por migração)', p_chave; end if;
  -- o tipo do valor não muda (texto continua texto, número continua número); valor ainda vazio (null) aceita qualquer tipo
  if p_valor is null or (jsonb_typeof(a.valor) <> 'null' and jsonb_typeof(p_valor) <> jsonb_typeof(a.valor)) then
    raise exception 'O valor de % deve ser do tipo %', p_chave, jsonb_typeof(a.valor);
  end if;
  perform _exigir_motivo(p_motivo);
  update parametros set valor = p_valor, confirmado = coalesce(p_confirmado, confirmado), atualizado_em = now(), atualizado_por = auth.uid()
   where chave = p_chave;
  return jsonb_build_object('chave', p_chave, 'valor', p_valor, 'confirmado', coalesce(p_confirmado, a.confirmado));
end $$;

create or replace function public.admin_listar_usuarios()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Somente administradores' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('user_id', u.id, 'email', u.email, 'criado_em', u.created_at,
            'ultimo_acesso', u.last_sign_in_at, 'papel', p.papel, 'colaborador_id', p.colaborador_id, 'colaborador', c.nome_advbox)
            order by u.email)
          from auth.users u left join perfis p on p.user_id = u.id left join colaboradores c on c.id = p.colaborador_id), '[]');
end $$;

-- papel null = retirar o acesso (apaga o perfil; a alteração fica em auditoria_configuracao)
create or replace function public.admin_definir_perfil(p_user_id uuid, p_papel text, p_colaborador_id bigint, p_motivo text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_atual text;
begin
  if not is_admin() then raise exception 'Somente administradores' using errcode = '42501'; end if;
  if not exists (select 1 from auth.users where id = p_user_id) then raise exception 'Usuário inexistente no Supabase Auth'; end if;
  if p_papel is not null and p_papel not in ('admin','colaborador') then raise exception 'Papel inválido: %', p_papel; end if;
  if p_papel = 'colaborador' and (p_colaborador_id is null or not exists (select 1 from colaboradores where id = p_colaborador_id)) then
    raise exception 'Colaborador do ADVBOX obrigatório para o papel colaborador';
  end if;
  select papel into v_atual from perfis where user_id = p_user_id;
  if v_atual = 'admin' and coalesce(p_papel, '') <> 'admin' then
    if p_user_id = auth.uid() then raise exception 'Você não pode retirar o seu próprio acesso de administradora'; end if;
    if (select count(*) from perfis where papel = 'admin') <= 1 then raise exception 'Deve existir ao menos um administrador'; end if;
  end if;
  perform _exigir_motivo(p_motivo);
  if p_papel is null then
    delete from perfis where user_id = p_user_id;
  else
    insert into perfis (user_id, papel, colaborador_id) values (p_user_id, p_papel, case when p_papel = 'colaborador' then p_colaborador_id end)
    on conflict (user_id) do update set papel = excluded.papel, colaborador_id = excluded.colaborador_id;
  end if;
  return jsonb_build_object('user_id', p_user_id, 'papel', p_papel);
end $$;

create or replace function public.admin_remover_dia_nao_util(p_id bigint, p_motivo text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare d record;
begin
  if not is_admin() then raise exception 'Somente administradores' using errcode = '42501'; end if;
  select * into d from calendario_dias_nao_uteis where id = p_id;
  if not found then raise exception 'Dia % inexistente no calendário', p_id; end if;
  perform _exigir_motivo(p_motivo);
  delete from calendario_dias_nao_uteis where id = p_id;
  insert into eventos (chave_dedupe, tipo, ocorrido_em, precisao_ocorrido, origem, historico_recuperado, classificacao, valor_anterior, evidencia)
  values ('adm:' || gen_random_uuid(), 'cadastro_administrativo', now(), 'segundo', 'administrativo', false, 'confirmado', to_jsonb(d),
          jsonb_build_object('operacao', 'remover_dia_nao_util', 'calendario_id', p_id, 'motivo', p_motivo, 'usuario', auth.uid()));
  return jsonb_build_object('removido', p_id);
end $$;

create or replace function public.admin_log_integracao(p_dias int default 7, p_nivel text default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Somente administradores' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(to_jsonb(x) order by x.ocorrido_em desc) from (
    select g.id, g.ocorrido_em, g.origem, g.nivel, g.operacao, g.mensagem, g.detalhe, us.email as usuario
      from log_integracao g left join auth.users us on us.id = g.usuario
     where g.ocorrido_em > now() - make_interval(days => least(greatest(coalesce(p_dias, 7), 1), 90))
       and (p_nivel is null or g.nivel = p_nivel)
     order by g.ocorrido_em desc limit 500) x), '[]');
end $$;

-- ---------------------------------------------------------------- privilégios
revoke execute on function public._auditoria_categoria(text) from public, anon;
revoke execute on function public.auditoria_linha_tempo(date, date, text, text, int), public.auditoria_integridade(),
  public.admin_definir_parametro(text, jsonb, boolean, text), public.admin_listar_usuarios(),
  public.admin_definir_perfil(uuid, text, bigint, text), public.admin_remover_dia_nao_util(bigint, text),
  public.admin_log_integracao(int, text) from public, anon;
grant execute on function public._auditoria_categoria(text), public.auditoria_linha_tempo(date, date, text, text, int), public.auditoria_integridade(),
  public.admin_definir_parametro(text, jsonb, boolean, text), public.admin_listar_usuarios(),
  public.admin_definir_perfil(uuid, text, bigint, text), public.admin_remover_dia_nao_util(bigint, text),
  public.admin_log_integracao(int, text) to authenticated;
