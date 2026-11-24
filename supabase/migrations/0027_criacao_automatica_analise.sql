-- =====================================================================
-- 0027 — Etapa 8: criação automática da tarefa de análise pela extensão (10/11/2026)
-- Conferido no ADVBOX real em 10/11/2026 (tarefa de teste 297747789, caso TESTE 1.0):
--  * tipo "ANÁLISE DO CASO (50 pts)", id 8849391, da fase NEGOCIAÇÃO. Ao escolhê-lo o
--    ADVBOX move o processo para NEGOCIAÇÃO / ANÁLISE DO CASO (sem opção de não mover).
--    A controladoria decidiu MANTER esse tipo, ciente da mudança de etapa (10/11/2026).
--  * responsável Mayra = usuário 296462 do ADVBOX ("MAYRA GABRIELA COSTA GOMES");
--  * a busca de processo do formulário aceita o CNJ com máscara e pode devolver mais de um
--    cadastro para o mesmo CNJ (um por cliente). Nesse caso a extensão NÃO escolhe:
--    a controladoria indica o processo no painel.
-- Fluxo: preparada -> (painel) aprovada -> (extensão) criacao_em_andamento -> criada.
--  * se nada foi enviado ao ADVBOX (processo não achado, ambíguo, formulário divergente),
--    a tarefa volta a "aprovada" com um BLOQUEIO que só a controladoria retira;
--  * se o envio pode ter ocorrido sem confirmação, vai para "verificar_no_advbox" (0008)
--    e não é recriada antes da conferência;
--  * "criacao_em_andamento" esquecida por mais de 10 minutos (aba fechada no meio) vai
--    para "verificar_no_advbox".
-- Tarefas de TESTE (homologação) usam um caso indicado pela controladoria (ex.: TESTE 1.0),
-- sem publicação; ficam marcadas e não entram nos relatórios do double check.
-- =====================================================================

update public.parametros
   set valor = to_jsonb('ANÁLISE DO CASO (50 pts)'::text), confirmado = true,
       descricao = 'Tipo da tarefa de análise no ADVBOX, nome exato da lista. CONFIRMADO em 10/11/2026. '
                || 'O ADVBOX move o processo para NEGOCIAÇÃO / ANÁLISE DO CASO ao criar esta tarefa; mantido por decisão da controladoria.'
 where chave = 'tarefa_analise_tipo';

insert into public.parametros (chave, valor, confirmado, descricao) values
  ('tarefa_analise_tipo_advbox_id', '"8849391"', true,
   'ID do tipo "ANÁLISE DO CASO (50 pts)" na lista de tarefas do ADVBOX, lido no formulário real em 10/11/2026.'),
  ('tarefa_analise_responsavel_advbox_id', '"296462"', true,
   'Usuário do ADVBOX responsável pela tarefa de análise (MAYRA GABRIELA COSTA GOMES), lido no formulário real em 10/11/2026.'),
  ('tarefa_analise_responsavel_advbox_nome', '"MAYRA GABRIELA COSTA GOMES"', true,
   'Nome do responsável como aparece no ADVBOX.'),
  ('tarefa_analise_muda_etapa', '"NEGOCIAÇÃO / ANÁLISE DO CASO"', true,
   'Efeito conhecido do tipo escolhido: o ADVBOX move o processo para esta etapa. Aceito pela controladoria em 10/11/2026.')
on conflict (chave) do nothing;

-- ---------------------------------------------------------------- colunas
alter table public.tarefas_analise alter column publicacao_id drop not null;
alter table public.tarefas_analise
  add column if not exists teste boolean not null default false,
  add column if not exists busca_advbox text,
  add column if not exists advbox_lawsuit_id text,
  add column if not exists bloqueio_criacao text,
  add column if not exists bloqueio_detalhe jsonb not null default '{}',
  add column if not exists tentativas int not null default 0;
alter table public.tarefas_analise drop constraint if exists tarefas_analise_origem_check;
alter table public.tarefas_analise add constraint tarefas_analise_origem_check
  check (teste or publicacao_id is not null);
alter table public.tarefas_analise drop constraint if exists tarefas_analise_teste_check;
alter table public.tarefas_analise add constraint tarefas_analise_teste_check
  check (not teste or (publicacao_id is null and nullif(btrim(busca_advbox), '') is not null));
alter table public.tarefas_analise drop constraint if exists tarefas_analise_bloqueio_check;
alter table public.tarefas_analise add constraint tarefas_analise_bloqueio_check
  check (bloqueio_criacao is null or bloqueio_criacao in
         ('processo_nao_encontrado','processo_ambiguo','processo_divergente','tipo_nao_encontrado',
          'responsavel_divergente','formulario_divergente','formulario_indisponivel'));
alter table public.tarefas_analise drop constraint if exists tarefas_analise_lawsuit_check;
alter table public.tarefas_analise add constraint tarefas_analise_lawsuit_check
  check (advbox_lawsuit_id is null or advbox_lawsuit_id ~ '^\d{1,15}$');

-- tipo das tarefas ainda não criadas passa ao nome exato do ADVBOX
update public.tarefas_analise set tipo = 'ANÁLISE DO CASO (50 pts)', atualizada_em = now()
 where tipo = 'análise do caso' and status not in ('criada','rejeitada','ja_tratada');

-- ---------------------------------------------------------------- prazo fatal previsto
create or replace function public._analise_pf_previsto() returns trigger
language plpgsql set search_path = public as $$
begin
  if new.data_prevista is not null and (tg_op = 'INSERT' or new.data_prevista is distinct from old.data_prevista) then
    new.pf_previsto := somar_dias_uteis(new.data_prevista,
      coalesce((select (valor #>> '{}')::int from parametros where chave = 'tarefa_analise_pf_dias_uteis'), 1));
  end if;
  return new;
end $$;
drop trigger if exists analise_pf_previsto on public.tarefas_analise;
create trigger analise_pf_previsto before insert or update of data_prevista on public.tarefas_analise
  for each row execute function public._analise_pf_previsto();

update public.tarefas_analise set pf_previsto = public.somar_dias_uteis(data_prevista, 1)
 where pf_previsto is null and data_prevista is not null and status not in ('criada','rejeitada','ja_tratada');

-- ---------------------------------------------------------------- conferência ainda vale?
create or replace function public._analise_conferencia_vigente(p_id bigint) returns text
language sql stable security definer set search_path = public as $$
  select c.situacao from conferencias_publicacao c join tarefas_analise t on t.publicacao_id = c.publicacao_id
   where t.id = p_id order by c.realizada_em desc, c.id desc limit 1
$$;

-- ---------------------------------------------------------------- decisão (0008 + teste)
create or replace function public.analise_decidir(p_id bigint, p_acao text, p_nota text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_sit text; v_teste boolean;
begin
  if not is_admin() then raise exception 'Somente a controladoria decide' using errcode = '42501'; end if;
  select teste into v_teste from tarefas_analise where id = p_id;
  if not found then raise exception 'Tarefa de análise % inexistente', p_id; end if;
  if p_acao = 'aprovar' then
    if not v_teste then
      -- só aprova se a conferência mais recente ainda indica ausência no ADVBOX
      v_sit := _analise_conferencia_vigente(p_id);
      if v_sit is null or v_sit not in ('nao_encontrada_advbox','processo_nao_cadastrado') then
        raise exception 'Aprovação recusada: a conferência mais recente é "%". Refaça a conferência.', coalesce(v_sit, 'nenhuma');
      end if;
    end if;
    perform _analise_status(p_id, array['preparada','conferencia_manual'], 'aprovada', p_nota);
  elsif p_acao = 'rejeitar' then
    if nullif(btrim(p_nota),'') is null then raise exception 'Informe o motivo da rejeição'; end if;
    perform _analise_status(p_id, array['preparada','conferencia_manual','aprovada'], 'rejeitada', p_nota);
  elsif p_acao = 'conferencia_manual' then
    perform _analise_status(p_id, array['preparada'], 'conferencia_manual', p_nota);
  elsif p_acao = 'ja_tratada' then
    if nullif(btrim(p_nota),'') is null then raise exception 'Informe onde/como já foi tratada'; end if;
    perform _analise_status(p_id, array['preparada','conferencia_manual'], 'ja_tratada', p_nota);
  else
    raise exception 'Ação inválida: %', p_acao;
  end if;
  return jsonb_build_object('id', p_id, 'status', (select status from tarefas_analise where id = p_id));
end $$;

-- ---------------------------------------------------------------- fila da extensão
-- Devolve a próxima tarefa aprovada e sem bloqueio (uma por vez) e recolhe criações
-- interrompidas há mais de 10 minutos, que passam a "verificar_no_advbox".
create or replace function public.ext_analise_fila()
returns jsonb language plpgsql security definer set search_path = public as $$
declare r record;
begin
  if not is_admin() then return jsonb_build_object('admin', false); end if;
  for r in select id from tarefas_analise
            where status = 'criacao_em_andamento' and atualizada_em < now() - interval '10 minutes' loop
    perform _analise_status(r.id, array['criacao_em_andamento'], 'verificar_no_advbox',
      'Criação interrompida sem confirmação (aba fechada ou recarregada). Confira no ADVBOX se a tarefa foi criada.',
      jsonb_build_object('motivo', 'interrompida'));
  end loop;
  return jsonb_build_object('admin', true,
    'proxima', (select id from tarefas_analise where status = 'aprovada' and bloqueio_criacao is null order by teste desc, id limit 1),
    'aprovadas', (select count(*) from tarefas_analise where status = 'aprovada' and bloqueio_criacao is null),
    'bloqueadas', (select count(*) from tarefas_analise where status = 'aprovada' and bloqueio_criacao is not null),
    'verificar', (select count(*) from tarefas_analise where status = 'verificar_no_advbox'),
    'em_andamento', (select count(*) from tarefas_analise where status = 'criacao_em_andamento'));
end $$;

-- ---------------------------------------------------------------- início da criação (0008, ampliada)
create or replace function public.analise_iniciar_criacao(p_id bigint)
returns jsonb language plpgsql security definer set search_path = public as $$
declare t record; v_sit text;
begin
  if not is_admin() then raise exception 'Somente a controladoria cria tarefas' using errcode = '42501'; end if;
  select * into t from tarefas_analise where id = p_id;
  if not found then raise exception 'Tarefa de análise % inexistente', p_id; end if;
  if t.bloqueio_criacao is not null then
    raise exception 'Criação bloqueada (%): resolva no painel antes.', t.bloqueio_criacao using errcode = 'P0001';
  end if;
  if not t.teste then
    v_sit := _analise_conferencia_vigente(p_id);
    if v_sit is null or v_sit not in ('nao_encontrada_advbox','processo_nao_cadastrado') then
      raise exception 'Criação recusada: a conferência mais recente da publicação é "%".', coalesce(v_sit, 'nenhuma');
    end if;
  end if;
  perform _analise_status(p_id, array['aprovada'], 'criacao_em_andamento', null);
  update tarefas_analise set tentativas = tentativas + 1 where id = p_id;
  return jsonb_build_object('id', t.id, 'teste', t.teste, 'tipo', t.tipo, 'tentativa', t.tentativas + 1,
    'tipo_advbox_id', (select valor #>> '{}' from parametros where chave = 'tarefa_analise_tipo_advbox_id'),
    'responsavel', t.responsavel,
    'responsavel_advbox_id', (select valor #>> '{}' from parametros where chave = 'tarefa_analise_responsavel_advbox_id'),
    'responsavel_advbox_nome', (select valor #>> '{}' from parametros where chave = 'tarefa_analise_responsavel_advbox_nome'),
    'observacoes', t.observacoes, 'data_prevista', t.data_prevista, 'pf_previsto', t.pf_previsto,
    'cnj', t.cnj, 'busca', coalesce(nullif(btrim(t.busca_advbox), ''), t.cnj), 'requer_cadastro', t.requer_cadastro,
    'advbox_processo_id', coalesce(t.advbox_lawsuit_id, (select advbox_lawsuit_id from processos where id = t.processo_id)));
end $$;

-- ---------------------------------------------------------------- nada foi enviado: bloqueio
create or replace function public.analise_bloquear_criacao(p_id bigint, p_motivo text, p_detalhe jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Somente a controladoria' using errcode = '42501'; end if;
  perform _analise_status(p_id, array['criacao_em_andamento'], 'aprovada',
    'Criação não enviada ao ADVBOX: ' || p_motivo, jsonb_build_object('bloqueio', p_motivo) || coalesce(p_detalhe, '{}'));
  update tarefas_analise set bloqueio_criacao = p_motivo, bloqueio_detalhe = coalesce(p_detalhe, '{}') where id = p_id;
  perform registrar_log_integracao('advbox_extensao', 'aviso', 'criar_tarefa_analise', 'Criação bloqueada: ' || p_motivo,
                                   jsonb_build_object('tarefa_analise_id', p_id) || coalesce(p_detalhe, '{}'));
  return jsonb_build_object('id', p_id, 'status', 'aprovada', 'bloqueio', p_motivo);
end $$;

-- A controladoria resolve o bloqueio (processo cadastrado, processo escolhido) e libera nova tentativa.
create or replace function public.analise_desbloquear(p_id bigint, p_advbox_lawsuit_id text, p_nota text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare t record; v_law text := nullif(btrim(coalesce(p_advbox_lawsuit_id, '')), '');
begin
  if not is_admin() then raise exception 'Somente a controladoria' using errcode = '42501'; end if;
  select * into t from tarefas_analise where id = p_id for update;
  if not found then raise exception 'Tarefa de análise % inexistente', p_id; end if;
  if t.status <> 'aprovada' or t.bloqueio_criacao is null then raise exception 'A tarefa % não está bloqueada', p_id; end if;
  if length(btrim(coalesce(p_nota, ''))) < 10 then raise exception 'Descreva o que foi resolvido (mínimo 10 caracteres)'; end if;
  if v_law is not null then
    if v_law !~ '^\d{1,15}$' then raise exception 'Processo do ADVBOX inválido'; end if;
    if jsonb_typeof(t.bloqueio_detalhe->'opcoes') = 'array'
       and not exists (select 1 from jsonb_array_elements(t.bloqueio_detalhe->'opcoes') o where o->>'lawsuit_id' = v_law) then
      raise exception 'O processo % não está entre os encontrados no ADVBOX para este CNJ', v_law;
    end if;
  elsif t.bloqueio_criacao in ('processo_ambiguo','processo_divergente') then
    raise exception 'Escolha qual processo do ADVBOX recebe a tarefa';
  end if;
  update tarefas_analise set bloqueio_criacao = null, bloqueio_detalhe = '{}',
         advbox_lawsuit_id = coalesce(v_law, advbox_lawsuit_id), atualizada_em = now() where id = p_id;
  insert into tarefas_analise_historico (tarefa_analise_id, status_anterior, status_novo, nota, evidencia, por)
  values (p_id, 'aprovada', 'aprovada', 'Bloqueio resolvido: ' || p_nota,
          jsonb_build_object('bloqueio_anterior', t.bloqueio_criacao, 'advbox_lawsuit_id', v_law), auth.uid());
  return jsonb_build_object('id', p_id, 'status', 'aprovada', 'advbox_lawsuit_id', coalesce(v_law, t.advbox_lawsuit_id));
end $$;

-- ---------------------------------------------------------------- confirmação (0008, ampliada)
create or replace function public.analise_confirmar_criacao(p_id bigint, p_advbox_tarefa_id text, p_evidencia jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare t record; v_law text := nullif(coalesce(p_evidencia, '{}')->>'lawsuit_id', '');
begin
  if not is_admin() then raise exception 'Somente a controladoria' using errcode = '42501'; end if;
  if p_advbox_tarefa_id !~ '^\d{1,15}$' then raise exception 'ID de tarefa do ADVBOX inválido'; end if;
  if v_law is not null and v_law !~ '^\d{1,15}$' then v_law := null; end if;
  perform _analise_status(p_id, array['criacao_em_andamento','verificar_no_advbox'], 'criada', null,
                          coalesce(p_evidencia,'{}') || jsonb_build_object('advbox_tarefa_id', p_advbox_tarefa_id));
  update tarefas_analise set advbox_tarefa_id = p_advbox_tarefa_id, criada_no_advbox_em = now(),
         advbox_lawsuit_id = coalesce(v_law, advbox_lawsuit_id) where id = p_id;
  select * into t from tarefas_analise where id = p_id;
  if v_law is not null and t.processo_id is not null then
    update processos set advbox_lawsuit_id = v_law
     where id = t.processo_id and advbox_lawsuit_id is null
       and not exists (select 1 from processos x where x.advbox_lawsuit_id = v_law);
  end if;
  return jsonb_build_object('id', p_id, 'status', 'criada', 'advbox_tarefa_id', p_advbox_tarefa_id);
end $$;

-- ---------------------------------------------------------------- tarefa de teste (homologação)
create or replace function public.analise_preparar_teste(p_busca text, p_observacoes text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id bigint; v_obs text;
begin
  if not is_admin() then raise exception 'Somente a controladoria' using errcode = '42501'; end if;
  if nullif(btrim(coalesce(p_busca, '')), '') is null then raise exception 'Informe o caso de teste do ADVBOX (ex.: TESTE 1.0)'; end if;
  if upper(p_busca) !~ 'TESTE' then raise exception 'Use um caso de TESTE do ADVBOX (o nome deve conter "TESTE")'; end if;
  v_obs := coalesce(nullif(btrim(coalesce(p_observacoes, '')), ''),
    'TESTE CONTROLADORIA — tarefa de análise criada automaticamente pela extensão (homologação). Pode ser desconsiderada.');
  insert into tarefas_analise (publicacao_id, processo_id, cnj, requer_cadastro, tipo, responsavel, observacoes, data_prevista, status, teste, busca_advbox)
  values (null, null, null, false,
          (select valor #>> '{}' from parametros where chave = 'tarefa_analise_tipo'),
          (select valor #>> '{}' from parametros where chave = 'tarefa_analise_responsavel'),
          v_obs, hoje_brasilia(), 'preparada', true, btrim(p_busca))
  returning id into v_id;
  insert into tarefas_analise_historico (tarefa_analise_id, status_anterior, status_novo, nota, evidencia, por)
  values (v_id, null, 'preparada', 'Tarefa de TESTE preparada pela controladoria', jsonb_build_object('busca', p_busca), auth.uid());
  return jsonb_build_object('id', v_id, 'status', 'preparada');
end $$;

-- ---------------------------------------------------------------- painel
create or replace function public.analise_listar(p_status text default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Somente a controladoria' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(x order by x.ordem, x.id) from (
    select t.id, t.status, t.teste, t.cnj, t.busca_advbox, t.requer_cadastro, t.tipo, t.responsavel, t.data_prevista, t.pf_previsto,
           t.advbox_tarefa_id, t.criada_no_advbox_em, t.advbox_lawsuit_id, t.bloqueio_criacao, t.bloqueio_detalhe, t.tentativas,
           t.preparada_em, t.atualizada_em, p.id as publicacao_id, p.data_disponibilizacao, p.data_publicacao, p.tribunal, p.orgao_julgador,
           (select advbox_lawsuit_id from processos where id = t.processo_id) as processo_advbox_id,
           case t.status when 'verificar_no_advbox' then 0 when 'criacao_em_andamento' then 1 when 'aprovada' then 2
                         when 'preparada' then 3 when 'conferencia_manual' then 4 else 5 end as ordem
      from tarefas_analise t left join publicacoes p on p.id = t.publicacao_id
     where p_status is null and (t.status not in ('criada','rejeitada','ja_tratada') or t.atualizada_em > now() - interval '7 days')
        or t.status = p_status) x), '[]'::jsonb);
end $$;

create or replace function public.analise_detalhe(p_id bigint)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Somente a controladoria' using errcode = '42501'; end if;
  return (select jsonb_build_object('tarefa', to_jsonb(t),
            'historico', coalesce((select jsonb_agg(jsonb_build_object('em', h.em, 'de', h.status_anterior, 'para', h.status_novo, 'nota', h.nota, 'evidencia', h.evidencia) order by h.em, h.id)
                                     from tarefas_analise_historico h where h.tarefa_analise_id = t.id), '[]'::jsonb))
            from tarefas_analise t where t.id = p_id);
end $$;

-- ---------------------------------------------------------------- privilégios
revoke execute on function public._analise_pf_previsto() from public, anon;
revoke execute on function public._analise_conferencia_vigente(bigint) from public, anon, authenticated;
revoke execute on function public.analise_decidir(bigint, text, text), public.ext_analise_fila(), public.analise_iniciar_criacao(bigint),
  public.analise_bloquear_criacao(bigint, text, jsonb), public.analise_desbloquear(bigint, text, text),
  public.analise_confirmar_criacao(bigint, text, jsonb), public.analise_preparar_teste(text, text),
  public.analise_listar(text), public.analise_detalhe(bigint) from public, anon;
grant execute on function public.analise_decidir(bigint, text, text), public.ext_analise_fila(), public.analise_iniciar_criacao(bigint),
  public.analise_bloquear_criacao(bigint, text, jsonb), public.analise_desbloquear(bigint, text, text),
  public.analise_confirmar_criacao(bigint, text, jsonb), public.analise_preparar_teste(text, text),
  public.analise_listar(text), public.analise_detalhe(bigint) to authenticated;
