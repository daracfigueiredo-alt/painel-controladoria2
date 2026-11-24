-- =====================================================================
-- 0010 — Apoio à tela de importação (Etapa 3). Somente visões; aditiva.
-- Classifica cada linha de cada importação para o relatório pedido no
-- Prompt Mestre §6: importadas (novas), atualizadas (já conhecidas),
-- ignoradas (repetidas no lote), rejeitadas, e as sem vínculo seguro.
-- RLS das tabelas de origem vale (security_invoker): só o admin vê importações.
-- =====================================================================

create or replace view public.v_importacao_linhas with (security_invoker = true) as
select l.importacao_id, l.id as linha_id, l.numero_linha, l.situacao,
       case when l.situacao = 'rejeitada' then 'rejeitada'
            when l.situacao = 'duplicada' then 'ignorada_repetida'
            when l.metodo_vinculo = 'ambigua' then 'sem_vinculo_seguro'
            when exists (select 1 from public.linhas_importadas x
                          join public.tarefas tx on tx.id = x.tarefa_id
                          join public.tarefas tl on tl.id = l.tarefa_id
                         where coalesce(tx.unificada_em, tx.id) = coalesce(tl.unificada_em, tl.id)
                           and x.importacao_id < l.importacao_id and x.situacao = 'valida') then 'atualizada'
            else 'nova' end as categoria,
       l.erros,
       jsonb_array_length(l.erros) > 0 as tem_apontamentos,
       l.compromisso, l.processo_cnj, l.data_agenda, l.pf_tarefa, l.data_conclusao,
       c.nome_advbox as responsavel,
       (select count(*) from public.eventos e
         where e.linha_id = l.id and e.origem = 'comparacao_importacoes') as alteracoes_detectadas
  from public.linhas_importadas l
  left join public.colaboradores c on c.id = l.responsavel_id;

create or replace view public.v_importacoes with (security_invoker = true) as
select i.id, i.lote_id, i.nome_arquivo, i.hash_arquivo, i.importado_em, i.importado_por, i.status,
       i.total_linhas, i.linhas_validas, i.linhas_rejeitadas, i.linhas_duplicadas,
       i.tarefas_novas, i.tarefas_vinculadas, i.linhas_ambiguas, i.mensagem,
       l.data_exportacao, l.criado_em as lote_criado_em,
       (i.lote_id = (select lote_id from public.v_lote_atual)) as lote_atual,
       (select count(*) from public.linhas_importadas x where x.importacao_id = i.id
          and x.situacao <> 'rejeitada' and jsonb_array_length(x.erros) > 0) as linhas_com_avisos,
       (select count(*) from public.eventos e join public.linhas_importadas x on x.id = e.linha_id
         where x.importacao_id = i.id and e.origem = 'comparacao_importacoes') as alteracoes_detectadas
  from public.importacoes i join public.lotes_importacao l on l.id = i.lote_id;

grant select on public.v_importacao_linhas, public.v_importacoes to authenticated;
revoke all on public.v_importacao_linhas, public.v_importacoes from anon;
