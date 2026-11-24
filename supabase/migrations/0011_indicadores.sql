-- =====================================================================
-- 0011 — Indicadores, prazos em risco, reagendamentos e tratativa (Etapa 4)
-- Aditiva. Princípio: cada indicador é definido UMA vez, em
-- indicadores_registros(); os cartões e as tabelas contam exatamente essas
-- linhas, e o detalhamento devolve as mesmas linhas (reprodutível por
-- construção). Tudo roda com as permissões de quem consulta (RLS).
-- =====================================================================

insert into public.parametros (chave, valor, confirmado, descricao) values
 ('reagendamentos_sucessivos_limite', '2', false,
  'Quantidade de alterações da data da agenda (entre importações) a partir da qual a tarefa entra em "reagendamentos sucessivos". PROVISÓRIO.'),
 ('tratativa_monitorada_desde', 'null', false,
  'Data/hora em que a extensão entrou em uso real. Conclusões ANTES disso não são "concluídas sem início" (não havia como registrar o início). Preencher na implantação.')
on conflict (chave) do nothing;

-- ---------------------------------------------------------------- alertas: novas categorias
-- v_alertas mantém as mesmas colunas; ganha 2 categorias.
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
    from fmt f where situacao='pendente' and d4 < hoje
  union all
  select f.*, 'd4_hoje','operacional_interno',2, 'D-4 é hoje ('||s_d4||') e não há entrega interna confirmada.'
    from fmt f where situacao='pendente' and d4 = hoje
  union all
  select f.*, 'd4_proximo','operacional_interno',3, 'D-4 ('||s_d4||') em '||du_ate_d4||' dia(s) útil(eis).'
    from fmt f where situacao='pendente' and d4 > hoje and du_ate_d4 <= prox
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

-- ---------------------------------------------------------------- prazos em risco (tela)
create or replace view public.v_prazos_risco with (security_invoker = true) as
select a.linha_id, a.tarefa_id, a.responsavel_id, a.responsavel, t.equipe_id, a.processo_cnj, a.compromisso,
       a.categoria, a.grupo_risco, a.gravidade,
       case a.gravidade when 1 then 'critica' when 2 then 'alta' else 'media' end as criticidade,
       a.motivo, t.pf_judicial, t.pf_tarefa, t.d4, t.d7_data_agenda, t.situacao,
       case when a.categoria = 'pf_judicial_nao_confirmado' then t.pf_tarefa
            when a.categoria like 'pf_judicial%' then t.pf_judicial
            when a.categoria like 'd4%' then t.d4
            when a.categoria in ('pf_tarefa_vencido','pf_tarefa_hoje','pf_tarefa_proximo','protocolo_sem_evidencia',
                                 'divergencia_pf_tarefa_x_judicial','agenda_posterior_pf_tarefa') then t.pf_tarefa
            else t.d7_data_agenda end as data_referencia,
       a.situacao_conferencia, a.conferencia_resultado, a.conferencia_nota, a.conferido_em,
       t.dados_atualizados_em
  from public.v_alertas_conferencia a join public.v_tarefas_atuais t on t.linha_id = a.linha_id;

-- ---------------------------------------------------------------- reagendamentos (tela)
create or replace view public.v_reagendamentos with (security_invoker = true) as
select e.id as evento_id, e.tipo,
       case e.tipo when 'pedido_reagendamento' then 'solicitacao'
                   when 'anotacao_realocacao' then 'anotacao_de_realocacao'
                   when 'tentativa_realocacao' then 'tentativa_pela_extensao'
                   when 'tentativa_alteracao_pf' then 'tentativa_pela_extensao'
                   else 'efetivacao' end as natureza,
       e.classificacao, e.origem, e.ocorrido_em, e.precisao_ocorrido, e.observado_em,
       coalesce(e.ocorrido_em, e.observado_em) as data_referencia,
       coalesce(c.nome_advbox, e.colaborador_txt) as autor,
       e.justificativa, coalesce(e.evidencia->>'texto', e.justificativa) as texto_original,
       e.valor_anterior, e.valor_novo, e.estado_trava,
       (e.origem = 'comparacao_importacoes' and e.justificativa is null
         and e.tipo in ('alteracao_data_agenda','alteracao_pf_tarefa','alteracao_responsavel')) as sem_justificativa,
       (e.tipo = 'alteracao_pf_tarefa'
         or (e.tipo = 'alteracao_data_agenda' and l.pf_tarefa is not null and (e.valor_novo#>>'{}')::date > l.pf_tarefa)) as impacto_no_prazo,
       -- solicitação seguida de alteração efetiva da data na mesma tarefa
       case when e.tipo = 'pedido_reagendamento' then exists (
              select 1 from public.eventos x join public.tarefas tx on tx.id = x.tarefa_id join public.tarefas te on te.id = e.tarefa_id
               where x.tipo = 'alteracao_data_agenda' and coalesce(tx.unificada_em, tx.id) = coalesce(te.unificada_em, te.id)
                 and x.observado_em >= e.observado_em) end as efetivada_depois,
       e.tarefa_id, e.linha_id, l.compromisso, l.processo_cnj, l.responsavel_id, r.nome_advbox as responsavel, r.equipe_id
  from public.eventos e
  left join public.linhas_importadas l on l.id = e.linha_id
  left join public.colaboradores r on r.id = l.responsavel_id
  left join public.colaboradores c on c.id = e.colaborador_id
 where e.tipo in ('pedido_reagendamento','anotacao_realocacao','alteracao_data_agenda','alteracao_pf_tarefa',
                  'alteracao_responsavel','tentativa_realocacao','tentativa_alteracao_pf');

-- ---------------------------------------------------------------- tratativa (tela)
create or replace view public.v_tratativa with (security_invoker = true) as
select t.linha_id, t.tarefa_id, t.tarefa_principal_id, t.advbox_id, t.compromisso, t.processo_cnj, t.responsavel_id,
       t.responsavel, t.equipe_id, t.situacao, t.d7_data_agenda, t.pf_tarefa, t.pf_judicial,
       t.abertura_em, t.inicio_tratativa_em, t.inicio_por, t.data_conclusao,
       case when t.situacao = 'pendente' and t.inicio_tratativa_em is null then 'pendente_sem_inicio'
            when t.situacao = 'pendente' then 'iniciada_nao_concluida'
            when t.inicio_tratativa_em is not null then 'concluida_com_inicio'
            when m.desde is not null and t.data_conclusao >= m.desde then 'concluida_sem_inicio'
            else 'concluida_antes_do_monitoramento' end as status_tratativa,
       round(extract(epoch from (t.inicio_tratativa_em - t.abertura_em)) / 3600.0, 1) as horas_abertura_inicio,
       round(extract(epoch from (t.data_conclusao - t.inicio_tratativa_em)) / 3600.0, 1) as horas_inicio_conclusao
  from public.v_tarefas_atuais t
  cross join (select (select valor #>> '{}' from public.parametros where chave = 'tratativa_monitorada_desde')::timestamptz as desde) m;

-- =====================================================================
-- INDICADORES — definição única
-- p_inicio/p_fim: período (datas de Brasília) para indicadores de EVENTO
-- (concluídas, protocolos, distribuições, pedidos, reagendamentos efetivados).
-- Indicadores de POSIÇÃO (pendentes, vencidas, hoje, D-4, sem início) refletem
-- a fotografia atual e não dependem do período.
-- =====================================================================
create or replace function public.indicadores_registros(
  p_inicio date, p_fim date, p_equipe bigint default null, p_colaborador bigint default null, p_indicador text default null)
returns table (indicador text, linha_id bigint, tarefa_id bigint, evento_id uuid, responsavel_id bigint, responsavel text,
               equipe_id bigint, compromisso text, processo_cnj text, data_referencia date, detalhe text)
language sql stable security invoker set search_path = public as $$
  with prot as (select jsonb_array_elements_text(valor) c from parametros where chave = 'compromissos_protocolo'),
  dist as (select jsonb_array_elements_text(valor) c from parametros where chave = 'compromissos_distribuicao'),
  pos as (select * from v_tarefas_atuais
           where (p_equipe is null or equipe_id = p_equipe) and (p_colaborador is null or responsavel_id = p_colaborador)),
  ev as (select e.*, l.compromisso, l.processo_cnj, coalesce(e.colaborador_id, l.responsavel_id) as resp_id,
                ((coalesce(e.ocorrido_em, e.observado_em)) at time zone 'America/Sao_Paulo')::date as dia
           from eventos e left join linhas_importadas l on l.id = e.linha_id),
  evf as (select ev.*, c.nome_advbox as resp_nome, c.equipe_id as resp_equipe from ev left join colaboradores c on c.id = ev.resp_id
           where ev.dia between p_inicio and p_fim
             and (p_equipe is null or c.equipe_id = p_equipe) and (p_colaborador is null or ev.resp_id = p_colaborador)),
  todos (indicador, linha_id, tarefa_id, evento_id, responsavel_id, responsavel, equipe_id, compromisso, processo_cnj, data_referencia, detalhe) as (
    select 'pendentes', linha_id, tarefa_id, null::uuid, responsavel_id, responsavel, equipe_id, compromisso, processo_cnj, d7_data_agenda,
           'Pendente na exportação mais recente' from pos where situacao = 'pendente'
    union all
    select 'vencidas', linha_id, tarefa_id, null, responsavel_id, responsavel, equipe_id, compromisso, processo_cnj, pf_tarefa,
           'PF da Tarefa (ADVBOX) em '||to_char(pf_tarefa,'DD/MM/YYYY')||' já passou' from pos where situacao = 'pendente' and pf_tarefa < hoje
    union all
    select 'pf_judicial_vencido_conferir', linha_id, tarefa_id, null, responsavel_id, responsavel, equipe_id, compromisso, processo_cnj, pf_judicial,
           'PF Judicial anotado em '||to_char(pf_judicial,'DD/MM/YYYY')||' passou sem conclusão: pendência de conferência, não perda de prazo presumida'
      from pos where situacao = 'pendente' and pf_judicial < hoje
    union all
    select 'vencem_hoje', linha_id, tarefa_id, null, responsavel_id, responsavel, equipe_id, compromisso, processo_cnj, hoje,
           case when pf_judicial = hoje and pf_tarefa = hoje then 'PF Judicial e PF da Tarefa vencem hoje'
                when pf_judicial = hoje then 'PF Judicial vence hoje' else 'PF da Tarefa vence hoje' end
      from pos where situacao = 'pendente' and (pf_tarefa = hoje or pf_judicial = hoje)
    union all
    select 'd4_criticas', linha_id, tarefa_id, null, responsavel_id, responsavel, equipe_id, compromisso, processo_cnj, d4,
           'D-4 em '||to_char(d4,'DD/MM/YYYY')||' ('||replace(d4_origem,'_',' ')||'); PF Judicial em '||to_char(pf_judicial,'DD/MM/YYYY')
      from pos where situacao = 'pendente' and d4 <= hoje and pf_judicial >= hoje
    union all
    select 'sem_inicio', linha_id, tarefa_id, null, responsavel_id, responsavel, equipe_id, compromisso, processo_cnj, d7_data_agenda,
           'Pendente sem início da tratativa registrado' from pos where situacao = 'pendente' and inicio_tratativa_em is null
    union all
    select 'sem_inicio_24h', linha_id, tarefa_id, null, responsavel_id, responsavel, equipe_id, compromisso, processo_cnj,
           (abertura_em at time zone 'America/Sao_Paulo')::date,
           'Aberta em '||to_char(abertura_em at time zone 'America/Sao_Paulo','DD/MM/YYYY HH24:MI')||' e sem início há mais de 24 h'
      from pos where situacao = 'pendente' and inicio_tratativa_em is null and abertura_em is not null and now() - abertura_em > interval '24 hours'
    union all
    select 'concluidas', linha_id, tarefa_id, id, resp_id, resp_nome, resp_equipe, compromisso, processo_cnj, dia,
           'Concluída em '||to_char(ocorrido_em at time zone 'America/Sao_Paulo','DD/MM/YYYY HH24:MI')||' (responsável = Destinatário na exportação)'
      from evf where tipo = 'conclusao'
    union all
    select 'protocolos_realizados', linha_id, tarefa_id, id, resp_id, resp_nome, resp_equipe, compromisso, processo_cnj, dia,
           'Tarefa de protocolo concluída (regra confirmada em 24/10/2026)'
      from evf where tipo = 'conclusao' and upper(btrim(compromisso)) in (select c from prot)
    union all
    select 'distribuicoes_realizadas', linha_id, tarefa_id, id, resp_id, resp_nome, resp_equipe, compromisso, processo_cnj, dia,
           'Tarefa de distribuição concluída (regra confirmada em 24/10/2026)'
      from evf where tipo = 'conclusao' and upper(btrim(compromisso)) in (select c from dist)
    union all
    select 'pedidos_reagendamento', linha_id, tarefa_id, id, resp_id, resp_nome, resp_equipe, compromisso, processo_cnj, dia,
           'Solicitação (identificada por texto; não é alteração efetiva): '||left(coalesce(justificativa,''), 200)
      from evf where tipo = 'pedido_reagendamento'
    union all
    select 'reagendamentos_efetivados', linha_id, tarefa_id, id, resp_id, resp_nome, resp_equipe, compromisso, processo_cnj, dia,
           'Data da agenda alterada de '||coalesce(to_char((valor_anterior#>>'{}')::date,'DD/MM/YYYY'),'-')||' para '
           ||coalesce(to_char((valor_novo#>>'{}')::date,'DD/MM/YYYY'),'-')||' (observado entre importações)'
      from evf where tipo = 'alteracao_data_agenda'
  )
  select * from todos where p_indicador is null or todos.indicador = p_indicador
$$;

-- Cartões: contagem exata dos registros acima + avisos de qualidade dos dados.
create or replace function public.indicadores_resumo(
  p_inicio date, p_fim date, p_equipe bigint default null, p_colaborador bigint default null)
returns jsonb language sql stable security invoker set search_path = public as $$
  select jsonb_build_object(
    'contagens', coalesce((select jsonb_object_agg(indicador, n) from (
        select indicador, count(*) n from indicadores_registros(p_inicio, p_fim, p_equipe, p_colaborador) group by indicador) x), '{}'),
    'periodo', jsonb_build_object('inicio', p_inicio, 'fim', p_fim),
    'dados_atualizados_em', (select ultima_importacao_em from v_lote_atual),
    'data_exportacao', (select data_exportacao from v_lote_atual),
    'hoje', hoje_brasilia(),
    'pendentes_com_abertura_conhecida', (select count(*) from v_tarefas_atuais where situacao = 'pendente' and abertura_em is not null
                                           and (p_equipe is null or equipe_id = p_equipe) and (p_colaborador is null or responsavel_id = p_colaborador)),
    'pendentes_com_inicio', (select count(*) from v_tarefas_atuais where situacao = 'pendente' and inicio_tratativa_em is not null
                                           and (p_equipe is null or equipe_id = p_equipe) and (p_colaborador is null or responsavel_id = p_colaborador)),
    'exportacoes_concluidas_possivelmente_cortadas', (select count(*) from importacoes i
        where i.status = 'concluida' and i.total_linhas in (25,50,100,200,500,1000)
          and i.lote_id = (select lote_id from v_lote_atual)))
$$;

-- Concluídas por dia (gráfico 1). Dias sem conclusão aparecem com 0 (contagem real, não estimativa).
create or replace function public.indicadores_concluidas_por_dia(
  p_inicio date, p_fim date, p_equipe bigint default null, p_colaborador bigint default null)
returns table (dia date, concluidas bigint)
language sql stable security invoker set search_path = public as $$
  select g::date, count(r.evento_id)
    from generate_series(p_inicio, p_fim, interval '1 day') g
    left join indicadores_registros(p_inicio, p_fim, p_equipe, p_colaborador, 'concluidas') r on r.data_referencia = g::date
   group by g order by g
$$;

-- Por colaborador (§13): mesmos registros, agrupados pelo responsável; tempos médios da tratativa.
create or replace function public.indicadores_por_colaborador(
  p_inicio date, p_fim date, p_equipe bigint default null, p_colaborador bigint default null)
returns table (responsavel_id bigint, responsavel text, equipe text, concluidas bigint, pendentes bigint, vencidas bigint,
               vencem_hoje bigint, d4_criticas bigint, pf_judicial_vencido_conferir bigint, protocolos_realizados bigint,
               distribuicoes_realizadas bigint, pedidos_reagendamento bigint, reagendamentos_efetivados bigint,
               sem_inicio bigint, sem_inicio_24h bigint,
               media_horas_abertura_inicio numeric, n_abertura_inicio bigint,
               media_horas_inicio_conclusao numeric, n_inicio_conclusao bigint)
language sql stable security invoker set search_path = public as $$
  with r as (select * from indicadores_registros(p_inicio, p_fim, p_equipe, p_colaborador)),
  t as (select * from v_tratativa where (p_equipe is null or equipe_id = p_equipe) and (p_colaborador is null or responsavel_id = p_colaborador)),
  ids as (select distinct responsavel_id from r where responsavel_id is not null)
  select i.responsavel_id, c.nome_advbox, e.nome,
         count(*) filter (where r.indicador = 'concluidas'), count(*) filter (where r.indicador = 'pendentes'),
         count(*) filter (where r.indicador = 'vencidas'), count(*) filter (where r.indicador = 'vencem_hoje'),
         count(*) filter (where r.indicador = 'd4_criticas'), count(*) filter (where r.indicador = 'pf_judicial_vencido_conferir'),
         count(*) filter (where r.indicador = 'protocolos_realizados'), count(*) filter (where r.indicador = 'distribuicoes_realizadas'),
         count(*) filter (where r.indicador = 'pedidos_reagendamento'), count(*) filter (where r.indicador = 'reagendamentos_efetivados'),
         count(*) filter (where r.indicador = 'sem_inicio'), count(*) filter (where r.indicador = 'sem_inicio_24h'),
         (select round(avg(horas_abertura_inicio), 1) from t where t.responsavel_id = i.responsavel_id and horas_abertura_inicio is not null),
         (select count(*) from t where t.responsavel_id = i.responsavel_id and horas_abertura_inicio is not null),
         (select round(avg(horas_inicio_conclusao), 1) from t where t.responsavel_id = i.responsavel_id and horas_inicio_conclusao is not null),
         (select count(*) from t where t.responsavel_id = i.responsavel_id and horas_inicio_conclusao is not null)
    from ids i join colaboradores c on c.id = i.responsavel_id left join equipes e on e.id = c.equipe_id
    left join r on r.responsavel_id = i.responsavel_id
   group by i.responsavel_id, c.nome_advbox, e.nome
   order by c.nome_advbox
$$;

grant select on public.v_prazos_risco, public.v_reagendamentos, public.v_tratativa to authenticated;
revoke all on public.v_prazos_risco, public.v_reagendamentos, public.v_tratativa from anon;
revoke execute on all functions in schema public from public, anon;
grant execute on function public.indicadores_registros(date, date, bigint, bigint, text),
                         public.indicadores_resumo(date, date, bigint, bigint),
                         public.indicadores_concluidas_por_dia(date, date, bigint, bigint),
                         public.indicadores_por_colaborador(date, date, bigint, bigint) to authenticated;

-- =====================================================================
-- Listagens para as telas: filtro no banco, total exato e no máximo
-- p_limite linhas (o Supabase devolve até 1.000 linhas por consulta).
-- =====================================================================
create or replace function public.indicadores_detalhe(
  p_inicio date, p_fim date, p_indicador text, p_equipe bigint default null, p_colaborador bigint default null, p_limite int default 500)
returns jsonb language sql stable security invoker set search_path = public as $$
  with r as (select * from indicadores_registros(p_inicio, p_fim, p_equipe, p_colaborador, p_indicador))
  select jsonb_build_object('total', (select count(*) from r),
    'linhas', coalesce((select jsonb_agg(to_jsonb(x)) from (select * from r order by data_referencia nulls last, responsavel, compromisso
                                                              limit least(coalesce(p_limite, 500), 1000)) x), '[]'))
$$;

create or replace function public.prazos_risco_listar(
  p_categoria text default null, p_criticidade text default null, p_situacao_conferencia text default null,
  p_equipe bigint default null, p_colaborador bigint default null, p_processo text default null,
  p_inicio date default null, p_fim date default null, p_grupo text default null, p_limite int default 500)
returns jsonb language sql stable security invoker set search_path = public as $$
  with base as (select * from v_prazos_risco
     where (p_criticidade is null or criticidade = p_criticidade)
       and (p_situacao_conferencia is null or situacao_conferencia = p_situacao_conferencia)
       and (p_equipe is null or equipe_id = p_equipe) and (p_colaborador is null or responsavel_id = p_colaborador)
       and (p_processo is null or regexp_replace(coalesce(processo_cnj,''), '\D', '', 'g') like '%'||regexp_replace(p_processo, '\D', '', 'g')||'%')
       and (p_inicio is null or data_referencia >= p_inicio) and (p_fim is null or data_referencia <= p_fim)
       and (p_grupo is null or grupo_risco = p_grupo)),
  f as (select * from base where p_categoria is null or categoria = p_categoria)
  select jsonb_build_object(
    'total', (select count(*) from f),
    'por_categoria', coalesce((select jsonb_object_agg(categoria, n) from (select categoria, count(*) n from base group by 1) x), '{}'),
    'por_criticidade', coalesce((select jsonb_object_agg(criticidade, n) from (select criticidade, count(*) n from f group by 1) x), '{}'),
    'linhas', coalesce((select jsonb_agg(to_jsonb(x)) from (select * from f order by gravidade, data_referencia nulls last, responsavel
                                                              limit least(coalesce(p_limite, 500), 1000)) x), '[]'))
$$;

create or replace function public.reagendamentos_listar(
  p_natureza text default null, p_inicio date default null, p_fim date default null, p_equipe bigint default null,
  p_colaborador bigint default null, p_processo text default null, p_so_sem_justificativa boolean default false, p_limite int default 500)
returns jsonb language sql stable security invoker set search_path = public as $$
  with base as (select * from v_reagendamentos
     where (p_inicio is null or (data_referencia at time zone 'America/Sao_Paulo')::date >= p_inicio)
       and (p_fim is null or (data_referencia at time zone 'America/Sao_Paulo')::date <= p_fim)
       and (p_equipe is null or equipe_id = p_equipe) and (p_colaborador is null or responsavel_id = p_colaborador)
       and (p_processo is null or regexp_replace(coalesce(processo_cnj,''), '\D', '', 'g') like '%'||regexp_replace(p_processo, '\D', '', 'g')||'%')
       and (not coalesce(p_so_sem_justificativa, false) or sem_justificativa)),
  f as (select * from base where p_natureza is null or natureza = p_natureza)
  select jsonb_build_object(
    'total', (select count(*) from f),
    'por_natureza', coalesce((select jsonb_object_agg(natureza, n) from (select natureza, count(*) n from base group by 1) x), '{}'),
    'sem_justificativa', (select count(*) from f where sem_justificativa),
    'com_impacto_no_prazo', (select count(*) from f where impacto_no_prazo),
    'linhas', coalesce((select jsonb_agg(to_jsonb(x)) from (select * from f order by data_referencia desc nulls last
                                                              limit least(coalesce(p_limite, 500), 1000)) x), '[]'))
$$;

create or replace function public.tratativa_listar(
  p_status text default null, p_equipe bigint default null, p_colaborador bigint default null, p_processo text default null, p_limite int default 500)
returns jsonb language sql stable security invoker set search_path = public as $$
  with base as (select * from v_tratativa
     where (p_equipe is null or equipe_id = p_equipe) and (p_colaborador is null or responsavel_id = p_colaborador)
       and (p_processo is null or regexp_replace(coalesce(processo_cnj,''), '\D', '', 'g') like '%'||regexp_replace(p_processo, '\D', '', 'g')||'%')),
  f as (select * from base where p_status is null or status_tratativa = p_status)
  select jsonb_build_object(
    'total', (select count(*) from f),
    'por_status', coalesce((select jsonb_object_agg(status_tratativa, n) from (select status_tratativa, count(*) n from base group by 1) x), '{}'),
    'monitorada_desde', (select valor #>> '{}' from parametros where chave = 'tratativa_monitorada_desde'),
    'travas', coalesce((select jsonb_agg(to_jsonb(x)) from (select * from v_travas order by ocorrido_em desc limit 200) x), '[]'),
    'sem_linha_atual', coalesce((select jsonb_agg(to_jsonb(x)) from (select * from v_tarefas_sem_linha_atual limit 200) x), '[]'),
    'linhas', coalesce((select jsonb_agg(to_jsonb(x)) from (select * from f order by d7_data_agenda nulls last, responsavel
                                                              limit least(coalesce(p_limite, 500), 1000)) x), '[]'))
$$;

revoke execute on all functions in schema public from public, anon;
grant execute on function public.indicadores_detalhe(date, date, text, bigint, bigint, int),
                         public.prazos_risco_listar(text, text, text, bigint, bigint, text, date, date, text, int),
                         public.reagendamentos_listar(text, date, date, bigint, bigint, text, boolean, int),
                         public.tratativa_listar(text, bigint, bigint, text, int) to authenticated;
