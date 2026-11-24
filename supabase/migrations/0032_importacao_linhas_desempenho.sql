-- =====================================================================
-- 0032 — "Detalhar" da importação estourava o tempo (homologação, 10/11/2026). Mesmo resultado.
-- Achado no 2º arquivo real (importação 9, 686 linhas): a visão v_importacao_linhas classificava
-- cada linha como "nova" ou "atualizada" procurando, linha a linha, outra linha de importação
-- anterior da mesma tarefa, numa junção sem índice possível (por coalesce(unificada_em, id)).
-- Na 1ª base não havia importação anterior; na 2ª, virou 686 x ~3.500 comparações e o limite de
-- 30 s foi atingido (erro 500 no painel).
-- Agora cada tarefa (já resolvida para a principal, em caso de unificação) tem calculada UMA vez a
-- primeira importação em que apareceu como linha válida; a linha é "atualizada" quando essa
-- primeira importação é anterior à dela. É a mesma condição de antes, escrita de outra forma.
-- =====================================================================
create or replace view public.v_importacao_linhas with (security_invoker = true) as
with primeira as materialized (
  select coalesce(t.unificada_em, t.id) as principal, min(x.importacao_id) as primeira_importacao
    from public.linhas_importadas x join public.tarefas t on t.id = x.tarefa_id
   where x.situacao = 'valida'
   group by 1
)
select l.importacao_id, l.id as linha_id, l.numero_linha, l.situacao,
       case when l.situacao = 'rejeitada' then 'rejeitada'
            when l.situacao = 'duplicada' then 'ignorada_repetida'
            when l.metodo_vinculo = 'ambigua' then 'sem_vinculo_seguro'
            when p.primeira_importacao < l.importacao_id then 'atualizada'
            else 'nova' end as categoria,
       l.erros,
       jsonb_array_length(l.erros) > 0 as tem_apontamentos,
       l.compromisso, l.processo_cnj, l.data_agenda, l.pf_tarefa, l.data_conclusao,
       c.nome_advbox as responsavel,
       (select count(*) from public.eventos e
         where e.linha_id = l.id and e.origem = 'comparacao_importacoes') as alteracoes_detectadas
  from public.linhas_importadas l
  left join public.colaboradores c on c.id = l.responsavel_id
  left join public.tarefas tl on tl.id = l.tarefa_id
  left join primeira p on p.principal = coalesce(tl.unificada_em, tl.id);

grant select on public.v_importacao_linhas to authenticated;
revoke all on public.v_importacao_linhas from anon;
