-- =====================================================================
-- 0037 — Exceções de D-4 (11/11/2026). Aditiva.
-- Regra confirmada pela controladoria em 11/11/2026:
--   * prazo fatal (Atlas) = PF Judicial;
--   * D-4 = data em que o advogado entrega a tarefa; EXCEÇÕES podem ser entregues depois do D-4;
--   * D-7 = primeira data em que a tarefa aparece na agenda do colaborador (coluna Data / vencimento do Atlas).
-- A exceção é marcada pelo LÍDER ou pela CONTROLADORIA, com justificativa, na janela da tarefa no
-- Atlas (extensão) ou no painel (Prazos em risco). Fica registrada como evento "excecao_d4"
-- (append-only; retirar = novo evento). Tarefa com exceção ativa sai dos alertas de D-4
-- (vencido, hoje, próximo) e do indicador "Críticas em D-4". O PF Judicial continua valendo.
-- =====================================================================

alter table public.eventos drop constraint if exists eventos_tipo_check;
alter table public.eventos add constraint eventos_tipo_check check (tipo in (
  'encaminhamento','anotacao_realocacao','pedido_reagendamento','alteracao_data_agenda','alteracao_pf_tarefa',
  'alteracao_responsavel','conclusao','inicio_tratativa','tentativa_conclusao','tentativa_realocacao',
  'tentativa_alteracao_pf','importacao','unificacao_tarefa','publicacao_recebida','publicacao_conferida',
  'tarefa_analise_status','erro_integracao','conferencia_alerta','cadastro_administrativo',
  'excecao_d4'));

-- a exceção vale para a tarefa principal (tarefas unificadas apontam para ela)
create or replace function public._tarefa_principal(p bigint) returns bigint
language sql stable security definer set search_path = public as $$
  select coalesce((select unificada_em from tarefas where id = p), p)
$$;

-- último evento de exceção de D-4 da tarefa (null = nunca marcada)
create or replace function public._excecao_d4_ultima(p_tarefa bigint) returns public.eventos
language sql stable security definer set search_path = public as $$
  select e.* from eventos e
   where e.tipo = 'excecao_d4' and e.tarefa_id = public._tarefa_principal(p_tarefa)
   order by e.ocorrido_em desc, e.observado_em desc limit 1
$$;

-- usada nas visões (que rodam com as permissões de quem consulta): definer, para o colaborador
-- também enxergar a exceção marcada pelo líder na tarefa dele
create or replace function public._excecao_d4_em(p_tarefa bigint) returns boolean
language sql stable security definer set search_path = public as $$
  select p_tarefa is not null and coalesce(((public._excecao_d4_ultima(p_tarefa)).valor_novo->>'ativa')::boolean, false)
$$;

create or replace function public._meu_papel() returns text
language sql stable security definer set search_path = public as $$
  select papel from perfis where user_id = auth.uid()
$$;

-- situação da exceção de uma tarefa (para a extensão e o painel)
create or replace function public._excecao_d4_situacao(p_tarefa bigint) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare e eventos; v_d4 date; v_pf date; v_sit text; v_quem text;
begin
  e := _excecao_d4_ultima(p_tarefa);
  select d4, pf_judicial, situacao into v_d4, v_pf, v_sit from v_tarefas_atuais
   where tarefa_id is not null and _tarefa_principal(tarefa_id) = _tarefa_principal(p_tarefa) limit 1;
  if e.id is not null then
    select coalesce(c.nome_advbox, u.email) into v_quem
      from (select 1) x left join colaboradores c on c.id = e.colaborador_id
      left join auth.users u on u.id = nullif(e.evidencia->>'usuario', '')::uuid;
  end if;
  return jsonb_build_object(
    'tarefa_id', _tarefa_principal(p_tarefa),
    'pode_definir', coalesce(_meu_papel() in ('admin','lider'), false),
    'ativa', coalesce((e.valor_novo->>'ativa')::boolean, false),
    'justificativa', e.justificativa, 'por', v_quem, 'em', e.ocorrido_em,
    'd4', v_d4, 'pf_judicial', v_pf, 'situacao', v_sit,
    'justificativa_minima', param_int('justificativa_minimo_caracteres'));
end $$;

-- marca (p_ativa = true) ou retira (false) a exceção. Só líder ou controladoria.
create or replace function public.excecao_d4_definir(p_tarefa_id bigint, p_ativa boolean, p_justificativa text,
                                                     p_origem text default 'administrativo')
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_papel text := _meu_papel(); v_t bigint; v_just text := btrim(regexp_replace(coalesce(p_justificativa, ''), '\s+', ' ', 'g'));
        v_min int := param_int('justificativa_minimo_caracteres'); v_atual boolean;
begin
  if coalesce(v_papel, '') not in ('admin','lider') then
    raise exception 'Somente líderes e a controladoria autorizam entrega após o D-4' using errcode = '42501';
  end if;
  if p_ativa is null then raise exception 'Informe se a exceção é marcada ou retirada'; end if;
  if p_origem not in ('administrativo','extensao') then raise exception 'Origem inválida: %', p_origem; end if;
  if length(v_just) < v_min then raise exception 'Justificativa obrigatória (mínimo % caracteres)', v_min; end if;
  if not exists (select 1 from tarefas where id = p_tarefa_id) then raise exception 'Tarefa % inexistente', p_tarefa_id; end if;
  v_t := _tarefa_principal(p_tarefa_id);
  v_atual := _excecao_d4_em(v_t);
  if v_atual is distinct from p_ativa then
    insert into eventos (chave_dedupe, tarefa_id, tipo, ocorrido_em, precisao_ocorrido, origem, historico_recuperado,
                         classificacao, colaborador_id, valor_anterior, valor_novo, justificativa, estado_trava, evidencia)
    values ('excd4:' || gen_random_uuid(), v_t, 'excecao_d4', now(), 'segundo', p_origem, false, 'confirmado',
            (select colaborador_id from perfis where user_id = auth.uid()),
            jsonb_build_object('ativa', v_atual), jsonb_build_object('ativa', p_ativa), v_just, 'excecao_autorizada',
            jsonb_build_object('usuario', auth.uid(), 'papel', v_papel,
                               'acao', case when p_ativa then 'autorizar_entrega_apos_d4' else 'retirar_autorizacao' end));
  end if;
  return _excecao_d4_situacao(v_t);
end $$;

-- extensão: a tarefa vem pelo ID externo (uuid do Atlas ou número do ADVBOX).
-- p_ativa null = só consulta (qualquer usuário logado).
create or replace function public.ext_excecao_d4(p_advbox_id text, p_ativa boolean default null, p_justificativa text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_t bigint;
begin
  if _meu_papel() is null then raise exception 'Usuário sem perfil na controladoria' using errcode = '42501'; end if;
  select id into v_t from tarefas where advbox_id = lower(btrim(p_advbox_id)) or advbox_id = btrim(p_advbox_id)
   order by (unificada_em is null) desc, id limit 1;
  if v_t is null then return jsonb_build_object('encontrada', false); end if;
  if p_ativa is null then return jsonb_build_object('encontrada', true) || _excecao_d4_situacao(v_t); end if;
  return jsonb_build_object('encontrada', true) || excecao_d4_definir(v_t, p_ativa, p_justificativa, 'extensao');
end $$;

-- painel: exceções ativas (líder e controladoria)
create or replace function public.excecoes_d4_listar()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if coalesce(_meu_papel(), '') not in ('admin','lider') then
    raise exception 'Somente líderes e a controladoria' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(x order by x.em desc) from (
      select u.tarefa_id, u.justificativa, u.ocorrido_em as em, coalesce(c.nome_advbox, us.email) as por,
             t.advbox_id as id_externo, v.compromisso, v.responsavel, v.processo_cnj, v.d4, v.pf_judicial, v.situacao, v.data_conclusao
        from (select distinct on (e.tarefa_id) e.* from eventos e where e.tipo = 'excecao_d4'
               order by e.tarefa_id, e.ocorrido_em desc, e.observado_em desc) u
        join tarefas t on t.id = u.tarefa_id
        left join colaboradores c on c.id = u.colaborador_id
        left join auth.users us on us.id = nullif(u.evidencia->>'usuario', '')::uuid
        left join lateral (select * from v_tarefas_atuais w where w.tarefa_id is not null
                            and _tarefa_principal(w.tarefa_id) = u.tarefa_id limit 1) v on true
       where (u.valor_novo->>'ativa')::boolean) x), '[]'::jsonb);
end $$;

revoke execute on function public._tarefa_principal(bigint), public._excecao_d4_ultima(bigint), public._excecao_d4_situacao(bigint),
                          public._meu_papel() from public, anon, authenticated;
revoke execute on function public._excecao_d4_em(bigint) from public, anon;
grant execute on function public._excecao_d4_em(bigint) to authenticated;
revoke execute on function public.excecao_d4_definir(bigint, boolean, text, text), public.ext_excecao_d4(text, boolean, text),
                          public.excecoes_d4_listar() from public, anon;
grant execute on function public.excecao_d4_definir(bigint, boolean, text, text), public.ext_excecao_d4(text, boolean, text),
                          public.excecoes_d4_listar() to authenticated;

-- ---------------------------------------------------------------- alertas: exceção sai dos alertas de D-4
-- Cópia fiel da 0011; únicas mudanças: o filtro _excecao_d4_em nas três categorias de D-4.
create or replace view public.v_alertas with (security_invoker = true) as
with t as (select v.*, public.param_int('alerta_dias_uteis_proximo') as prox from public.v_tarefas_atuais v),
fmt as (select t.*, to_char(pf_judicial,'DD/MM/YYYY') as s_pfj, to_char(pf_tarefa,'DD/MM/YYYY') as s_pft,
               to_char(d4,'DD/MM/YYYY') as s_d4, to_char(d7_data_agenda,'DD/MM/YYYY') as s_d7 from t)
select linha_id, tarefa_id, responsavel_id, responsavel, processo_cnj, compromisso, categoria, grupo_risco, gravidade, motivo
from (
  select f.*, 'pf_judicial_vencido' categoria, 'processual' grupo_risco, 1 gravidade,
         'PF Judicial anotado ('||s_pfj||') já passou e não há conclusão registrada. Conferir imediatamente.' motivo
    from fmt f where situacao='pendente' and pf_judicial < hoje
  union all
  select f.*, 'pf_judicial_hoje','processual',1, 'PF Judicial anotado vence hoje ('||s_pfj||') e não há conclusão registrada.'
    from fmt f where situacao='pendente' and pf_judicial = hoje
  union all
  select f.*, 'pf_judicial_proximo','processual',2, 'PF Judicial anotado ('||s_pfj||') em '||du_ate_pf_judicial||' dia(s) útil(eis).'
    from fmt f where situacao='pendente' and pf_judicial > hoje and du_ate_pf_judicial <= prox
  union all
  select f.*, 'pf_judicial_nao_confirmado','processual',2,
         'Tarefa com PF da Tarefa ('||s_pft||') mas sem PF Judicial anotado: prazo judicial não confirmado.'
    from fmt f where situacao='pendente' and pf_tarefa is not null and pf_judicial is null
  union all
  select f.*, 'd4_vencido_sem_entrega','operacional_interno',2,
         'D-4 ('||s_d4||', '||replace(d4_origem,'_',' ')||') passou sem entrega interna confirmada. '
         || case when pf_judicial >= hoje then 'PF Judicial ainda não venceu: atraso operacional interno, não perda de prazo.'
                 when pf_judicial is null then 'PF Judicial não confirmado.' else 'PF Judicial também já passou.' end
    from fmt f where situacao='pendente' and d4 < hoje and not public._excecao_d4_em(f.tarefa_id)
  union all
  select f.*, 'd4_hoje','operacional_interno',2, 'D-4 é hoje ('||s_d4||') e não há entrega interna confirmada.'
    from fmt f where situacao='pendente' and d4 = hoje and not public._excecao_d4_em(f.tarefa_id)
  union all
  select f.*, 'd4_proximo','operacional_interno',3, 'D-4 ('||s_d4||') em '||du_ate_d4||' dia(s) útil(eis).'
    from fmt f where situacao='pendente' and d4 > hoje and du_ate_d4 <= prox and not public._excecao_d4_em(f.tarefa_id)
  union all
  select f.*, 'pf_tarefa_vencido','operacional_interno',2, 'PF da Tarefa ('||s_pft||') já passou e a tarefa segue pendente.'
    from fmt f where situacao='pendente' and pf_tarefa < hoje
  union all
  select f.*, 'pf_tarefa_hoje','operacional_interno',2, 'PF da Tarefa vence hoje ('||s_pft||').'
    from fmt f where situacao='pendente' and pf_tarefa = hoje
  union all
  select f.*, 'pf_tarefa_proximo','operacional_interno',3, 'PF da Tarefa ('||s_pft||') em '||du_ate_pf_tarefa||' dia(s) útil(eis).'
    from fmt f where situacao='pendente' and pf_tarefa > hoje and du_ate_pf_tarefa <= prox
  union all
  select f.*, 'divergencia_pf_tarefa_x_judicial','inconsistencia_cadastral',2,
         'PF da Tarefa ('||s_pft||') diferente do PF Judicial anotado ('||s_pfj||'). Conferir qual está correto; o sistema não presume.'
    from fmt f where pf_tarefa is not null and pf_judicial is not null and pf_tarefa <> pf_judicial
  union all
  select f.*, 'd4_anotado_diverge_regra','inconsistencia_cadastral',3,
         'D-4 anotado ('||to_char(d4_anotado,'DD/MM/YYYY')||') diferente do calculado pela regra ('||to_char(d4_regra,'DD/MM/YYYY')||').'
    from fmt f where d4_anotado is not null and d4_regra is not null and d4_anotado <> d4_regra
  union all
  select f.*, 'd4_posterior_pf_judicial','inconsistencia_cadastral',2,
         'D-4 ('||s_d4||') posterior ao PF Judicial ('||s_pfj||').'
    from fmt f where d4 is not null and pf_judicial is not null and d4 > pf_judicial
  union all
  select f.*, 'agenda_posterior_pf_tarefa','inconsistencia_cadastral',2,
         'Data da agenda ('||s_d7||') posterior ao PF da Tarefa ('||s_pft||').'
    from fmt f where situacao='pendente' and pf_tarefa is not null and d7_data_agenda > pf_tarefa
  union all
  select f.*, 'pf_alterado_violacao','processual',1, e.evidencia->>'motivo'
         ||' ('||coalesce(to_char((e.valor_anterior#>>'{}')::date,'DD/MM/YYYY'),'-')||' -> '
         ||coalesce(to_char((e.valor_novo#>>'{}')::date,'DD/MM/YYYY'),'-')||').'
    from fmt f join public.eventos e on e.tarefa_id = f.tarefa_id
   where e.tipo = 'alteracao_pf_tarefa' and e.estado_trava = 'violacao_detectada'
  union all
  select f.*, 'aberta_24h_sem_inicio','operacional_interno',2,
         'Tarefa criada em '||to_char(abertura_em at time zone 'America/Sao_Paulo','DD/MM/YYYY HH24:MI')
         ||' (lido na tela do ADVBOX) e sem início da tratativa há mais de 24 horas.'
    from fmt f where situacao='pendente' and abertura_em is not null and inicio_tratativa_em is null
                 and now() - abertura_em > interval '24 hours'
  union all
  select f.*, 'd7_atingido_sem_inicio','ausencia_evidencia',3,
         'Data da agenda ('||s_d7||') atingida sem registro de início da tratativa. '
         || 'Observação: o início da tratativa só passa a ser capturado com a extensão.'
    from fmt f where situacao='pendente' and d7_data_agenda <= hoje and inicio_tratativa_em is null
  -- ---------- novas (0011) ----------
  union all
  select f.*, 'reagendamentos_sucessivos','operacional_interno',2,
         'Data da agenda alterada '||r.n||' vezes entre importações (limite: '||public.param_int('reagendamentos_sucessivos_limite')||').'
    from fmt f join lateral (select count(*) n from public.eventos e join public.tarefas te on te.id = e.tarefa_id
                              where e.tipo = 'alteracao_data_agenda'
                                and coalesce(te.unificada_em, te.id) = coalesce(f.tarefa_principal_id, f.tarefa_id)) r on true
   where situacao = 'pendente' and f.tarefa_id is not null
     and r.n >= public.param_int('reagendamentos_sucessivos_limite')
  union all
  select f.*, 'protocolo_sem_evidencia','processual',1,
         upper(f.compromisso)||' com PF da Tarefa ('||s_pft||') vencido e sem conclusão registrada: não há evidência de que o '
         || case when upper(f.compromisso) in (select jsonb_array_elements_text(valor) from public.parametros where chave='compromissos_distribuicao')
                 then 'processo foi distribuído.' else 'protocolo foi realizado.' end
    from fmt f
   where situacao = 'pendente' and pf_tarefa < hoje
     and upper(btrim(f.compromisso)) in (select jsonb_array_elements_text(valor) from public.parametros
                                          where chave in ('compromissos_protocolo','compromissos_distribuicao'))
) x;

-- ---------------------------------------------------------------- indicador "Críticas em D-4"
do $$
declare d text; ancora text := $a$from pos where situacao = 'pendente' and d4 <= hoje and pf_judicial >= hoje$a$;
begin
  d := pg_get_functiondef('public.indicadores_registros(date, date, bigint, bigint, text)'::regprocedure);
  if position('_excecao_d4_em' in d) > 0 then return; end if;
  if (length(d) - length(replace(d, ancora, ''))) / length(ancora) <> 1 then
    raise exception '0037: trecho esperado não encontrado em indicadores_registros';
  end if;
  d := replace(d, ancora, ancora || ' and not public._excecao_d4_em(tarefa_id) /* 0037 */');
  execute d;
end $$;

-- ---------------------------------------------------------------- auditoria: categoria do novo evento
create or replace function public._auditoria_categoria(p_tipo text) returns text
language sql immutable set search_path = public as $$
  select case
    when p_tipo = 'importacao' then 'importacao'
    when p_tipo in ('inicio_tratativa','conclusao','tentativa_conclusao') then 'tratativa'
    when p_tipo in ('alteracao_responsavel','encaminhamento','anotacao_realocacao','tentativa_realocacao','unificacao_tarefa') then 'responsavel'
    when p_tipo in ('alteracao_data_agenda','pedido_reagendamento','excecao_d4') then 'reagendamento'
    when p_tipo in ('alteracao_pf_tarefa','tentativa_alteracao_pf') then 'prazo_fatal'
    when p_tipo = 'publicacao_recebida' then 'publicacao'
    when p_tipo = 'publicacao_conferida' then 'conferencia'
    when p_tipo = 'tarefa_analise_status' then 'tarefa_analise'
    when p_tipo = 'erro_integracao' then 'integracao'
    when p_tipo in ('conferencia_alerta','cadastro_administrativo') then 'administrativo'
    else 'outros' end
$$;

-- ---------------------------------------------------------------- parâmetros: regras confirmadas em 11/11/2026
update public.parametros set descricao = descricao || ' Confirmado em 11/11/2026 para o Atlas: D-7 = primeira data em que a tarefa aparece na agenda do colaborador (vencimento da tarefa no Atlas).'
 where chave = 'd7_dias_uteis_antes_pf' and position('11/11/2026' in descricao) = 0;
update public.parametros set descricao = descricao || ' Confirmado em 11/11/2026 para o Atlas: o prazo fatal da tarefa no Atlas é o PF Judicial (vale a anotação "PF:" da descrição, se houver).'
 where chave = 'pf_judicial_fonte' and position('11/11/2026' in descricao) = 0;
update public.parametros set descricao = descricao || ' 11/11/2026: D-4 = data em que o advogado entrega a tarefa; exceções autorizadas por líder ou pela controladoria (evento excecao_d4) podem ser entregues depois.'
 where chave = 'entrega_interna_criterio' and position('11/11/2026' in descricao) = 0;
