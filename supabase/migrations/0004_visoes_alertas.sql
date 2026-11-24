-- =====================================================================
-- 0004 — Visões de prazos e alertas (critério único para todas as telas)
-- Base "atual" = último lote com importação concluída (fotografia mais recente).
-- =====================================================================

-- Sem security_invoker de propósito: expõe só identificação e horário do lote
-- (necessário para o colaborador ver a data de atualização dos dados).
create or replace view public.v_lote_atual as
select l.id as lote_id, l.data_exportacao,
       max(i.importado_em) as ultima_importacao_em,
       count(i.id) as arquivos,
       sum(i.linhas_validas) as linhas_validas
  from public.lotes_importacao l join public.importacoes i on i.lote_id = l.id and i.status = 'concluida'
 group by l.id
 order by l.id desc limit 1;

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
       -- ===== quatro referências, sempre separadas =====
       b.data_agenda                                   as d7_data_agenda,      -- valor de origem (coluna Data)
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
       -- tratativa (só a extensão registra; antes dela, ausente)
       (select min(e.ocorrido_em) from public.eventos e
         where e.tarefa_id = b.tarefa_id and e.tipo = 'inicio_tratativa')     as inicio_tratativa_em,
       -- abertura: o Excel NÃO traz a criação; vem da tela do ADVBOX lida pela extensão (senão, nula)
       (select t.criada_em_advbox from public.tarefas t where t.id = b.tarefa_id) as abertura_em,
       (select min(e.ocorrido_em) from public.eventos e
         where e.tipo = 'encaminhamento'
           and (e.tarefa_id = b.tarefa_id or e.linha_id = b.id))              as primeira_atribuicao_observada_em,
       (select ultima_importacao_em from public.v_lote_atual) as dados_atualizados_em
  from base b
  left join public.colaboradores cr on cr.id = b.responsavel_id
  left join public.colaboradores cm on cm.id = b.remetente_id;

-- ---------------------------------------------------------------------
-- Alertas: uma linha por (tarefa, condição), com motivo objetivo.
-- grupo_risco: operacional_interno | processual | inconsistencia_cadastral | ausencia_evidencia
-- ---------------------------------------------------------------------
create or replace view public.v_alertas with (security_invoker = true) as
with t as (select v.*, public.param_int('alerta_dias_uteis_proximo') as prox from public.v_tarefas_atuais v),
fmt as (select t.*, to_char(pf_judicial,'DD/MM/YYYY') as s_pfj, to_char(pf_tarefa,'DD/MM/YYYY') as s_pft,
               to_char(d4,'DD/MM/YYYY') as s_d4, to_char(d7_data_agenda,'DD/MM/YYYY') as s_d7 from t)
select linha_id, tarefa_id, responsavel_id, responsavel, processo_cnj, compromisso, categoria, grupo_risco, gravidade, motivo
from (
  -- ---------- risco processual ----------
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
  -- ---------- risco operacional interno ----------
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
  -- ---------- inconsistência cadastral ----------
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
  -- ---------- ausência de evidência ----------
  union all
  select f.*, 'd7_atingido_sem_inicio','ausencia_evidencia',3,
         'Data da agenda ('||s_d7||') atingida sem registro de início da tratativa. '
         || 'Observação: o início da tratativa só passa a ser capturado com a extensão.'
    from fmt f where situacao='pendente' and d7_data_agenda <= hoje and inicio_tratativa_em is null
) x;

-- Alterações de data/PF/responsável sem anotação de justificativa (entre importações)
create or replace view public.v_alteracoes_sem_justificativa with (security_invoker = true) as
select e.id as evento_id, e.tarefa_id, e.linha_id, e.tipo, e.valor_anterior, e.valor_novo, e.observado_em,
       (e.evidencia->>'antecipacao')::boolean as antecipacao_pf
  from public.eventos e
 where e.origem = 'comparacao_importacoes' and e.justificativa is null
   and e.tipo in ('alteracao_data_agenda','alteracao_pf_tarefa','alteracao_responsavel');
