-- =====================================================================
-- 0031 — Desempenho dos indicadores (homologação, 10/11/2026). Mesmos resultados.
-- Achado na Etapa 10: no banco real, "indicadores_resumo" e "indicadores_por_colaborador"
-- passaram a estourar o limite de 30 s (erro 500 no painel), embora a visão sozinha leve
-- ~2,5 s. Dentro da função, o planejador escolhia juntar as linhas com a tabela de processos
-- recalculando normalizar_cnj() para cada par linha x processo (3.568 x 992).
-- Correção: o CNJ normalizado é calculado uma vez por linha (cnj_norm) e a tabela de
-- processos entra como conjunto já materializado; a junção passa a ser por coluna.
-- Mesmas colunas, mesma ordem, mesmos valores (conferido por hash nos testes).
-- =====================================================================
create or replace view public.v_tarefas_atuais with (security_invoker = true) as
with base0 as (
  select l.*, public.hoje_brasilia() as hoje, public.foro_do_cnj(l.processo_cnj) as foro,
         public.normalizar_cnj(l.processo_cnj) as cnj_norm          -- 0031: calculado uma vez por linha
    from public.linhas_importadas l
   where l.situacao = 'valida' and l.lote_id = (select lote_id from public.v_lote_atual)
),
-- foro só muda o cálculo quando o calendário tem dia não útil cadastrado para ele
foros_cal as (select distinct tribunal_cnj, foro_cnj from public.calendario_dias_nao_uteis where abrangencia = 'foro'),
base as (
  select b.*, fc.foro_cnj as fe, coalesce(b.tribunal_cnj, '') as tk, coalesce(fc.foro_cnj, '') as fk
    from base0 b left join foros_cal fc on fc.tribunal_cnj = b.tribunal_cnj and fc.foro_cnj = b.foro
),
enc as (select e.tarefa_id, e.linha_id, e.ocorrido_em from public.eventos e where e.tipo = 'encaminhamento'),
enc_t as (select tarefa_id, min(ocorrido_em) m from enc where tarefa_id is not null group by tarefa_id),
enc_l as (select linha_id, min(ocorrido_em) m from enc where linha_id is not null group by linha_id),
tr as (select * from public.tratativas_visiveis()),
procs as materialized (select id, cnj from public.processos),   -- 0031: junção por coluna, sem função

-- cada combinação (data, tribunal, foro) é calculada uma única vez
k_pf as (select distinct pf_judicial_anotado as p, tribunal_cnj as t, fe, tk, fk from base where pf_judicial_anotado is not null),
m_pf as (select k.*, public.calcular_d4(p, t, fe) as d4, public.calcular_d7_conferencia(p, t, fe) as d7 from k_pf k),
calc as (
  select b.*, m.d4 as d4_r, m.d7 as d7_r, coalesce(b.d4_anotado, m.d4) as d4_f
    from base b left join m_pf m on m.p = b.pf_judicial_anotado and m.tk = b.tk and m.fk = b.fk
),
k_du as (select distinct x, t, fe, tk, fk from (
           select d4_f as x, tribunal_cnj as t, fe, tk, fk from calc
           union select pf_judicial_anotado, tribunal_cnj, fe, tk, fk from calc
           union select pf_tarefa, tribunal_cnj, fe, tk, fk from calc) u where x is not null),
m_du as (select k.*, public.dias_uteis_entre(public.hoje_brasilia(), x, t, fe) as du from k_du k)
select b.id as linha_id, b.tarefa_id, b.metodo_vinculo, b.importacao_id, b.lote_id, b.numero_linha,
       b.prioridade, b.compromisso, b.processo_cnj, b.tribunal_cnj, b.partes, b.tipo_acao, b.local,
       b.responsavel_id, cr.nome_advbox as responsavel, cm.nome_advbox as remetente,
       b.observacoes,
       b.data_agenda                                   as d7_data_agenda,
       b.d7_r                                          as d7_conferencia,
       b.d4_anotado,
       b.d4_r                                          as d4_regra,
       b.d4_f                                          as d4,
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
       du4.du                                          as du_ate_d4,
       dup.du                                          as du_ate_pf_judicial,
       dut.du                                          as du_ate_pf_tarefa,
       tr.inicio_em                                    as inicio_tratativa_em,
       tr.abertura_em                                  as abertura_em,
       least(et.m, el.m)                               as primeira_atribuicao_observada_em,
       (select ultima_importacao_em from public.v_lote_atual) as dados_atualizados_em,
       tr.tarefa_principal                             as tarefa_principal_id,
       tr.advbox_id,
       tr.inicio_por,
       b.foro                                          as foro_cnj,
       pr.id                                           as processo_id,
       cr.equipe_id
  from calc b
  left join public.colaboradores cr on cr.id = b.responsavel_id
  left join public.colaboradores cm on cm.id = b.remetente_id
  left join tr on tr.tarefa_id = b.tarefa_id
  left join enc_t et on et.tarefa_id = b.tarefa_id
  left join enc_l el on el.linha_id = b.id
  left join procs pr on pr.cnj = b.cnj_norm
  left join m_du du4 on du4.x = b.d4_f and du4.tk = b.tk and du4.fk = b.fk
  left join m_du dup on dup.x = b.pf_judicial_anotado and dup.tk = b.tk and dup.fk = b.fk
  left join m_du dut on dut.x = b.pf_tarefa and dut.tk = b.tk and dut.fk = b.fk;

grant select on public.v_tarefas_atuais to authenticated;
revoke all on public.v_tarefas_atuais from anon;
