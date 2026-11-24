-- =====================================================================
-- 0030 — Ajuste da verificação de integridade (10/11/2026)
-- Na primeira execução real (banco de homologação):
--  * as quantidades paravam em 20 (o limite valia para a contagem, não só para os exemplos);
--  * "linhas do lote atual sem tarefa" eram as 87 linhas AMBÍGUAS da importação, que por regra
--    da Etapa 2/3 não são ligadas a nenhuma tarefa (o Excel não permite decidir). Isso não é
--    falha de integridade: passa a ser informativo, separado de linha sem tarefa por outro motivo.
-- Mesmas verificações da 0029; só a contagem e a classificação mudam.
-- =====================================================================
create or replace function public._integridade_item(p_codigo text, p_gravidade text, p_descricao text, p_qtd bigint, p_exemplos jsonb)
returns jsonb language sql immutable set search_path = public as $$
  select jsonb_build_object('codigo', p_codigo, 'gravidade', p_gravidade, 'descricao', p_descricao,
                            'quantidade', coalesce(p_qtd, 0), 'exemplos', coalesce(p_exemplos, '[]'::jsonb))
$$;
revoke execute on function public._integridade_item(text, text, text, bigint, jsonb) from public, anon, authenticated;

create or replace function public.auditoria_integridade()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare r jsonb := '[]'; v_lote bigint := (select lote_id from v_lote_atual);
begin
  if not is_admin() then raise exception 'Somente a controladoria' using errcode = '42501'; end if;
  with a as (select id from tarefas_analise where status = 'criada' and advbox_tarefa_id is null)
  select r || _integridade_item('analise_criada_sem_id', 'erro', 'Tarefa de análise "criada" sem ID da tarefa no ADVBOX',
           (select count(*) from a), (select jsonb_agg(id) from (select id from a limit 20) x)) into r;
  with a as (select advbox_tarefa_id k from tarefas_analise where advbox_tarefa_id is not null group by 1 having count(*) > 1)
  select r || _integridade_item('analise_id_repetido', 'erro', 'O mesmo ID de tarefa do ADVBOX registrado em mais de uma tarefa de análise',
           (select count(*) from a), (select jsonb_agg(k) from (select k from a limit 20) x)) into r;
  with a as (select publicacao_id k from tarefas_analise where publicacao_id is not null and status not in ('rejeitada','ja_tratada') group by 1 having count(*) > 1)
  select r || _integridade_item('analise_duplicada', 'erro', 'Mais de uma tarefa de análise ativa ou criada para a mesma publicação',
           (select count(*) from a), (select jsonb_agg(k) from (select k from a limit 20) x)) into r;
  with a as (select id from tarefas_analise where status = 'criacao_em_andamento' and atualizada_em < now() - interval '10 minutes')
  select r || _integridade_item('analise_presa', 'alerta', 'Criação de tarefa de análise em andamento há mais de 10 minutos',
           (select count(*) from a), (select jsonb_agg(id) from (select id from a limit 20) x)) into r;
  with a as (select id from tarefas_analise where status = 'verificar_no_advbox')
  select r || _integridade_item('analise_verificar', 'alerta', 'Tarefas de análise aguardando conferência no ADVBOX ("verificar no ADVBOX")',
           (select count(*) from a), (select jsonb_agg(id) from (select id from a limit 20) x)) into r;
  with a as (select id from tarefas_analise where status = 'aprovada' and bloqueio_criacao is not null)
  select r || _integridade_item('analise_bloqueada', 'alerta', 'Tarefas de análise aprovadas e bloqueadas (nada enviado ao ADVBOX)',
           (select count(*) from a), (select jsonb_agg(id) from (select id from a limit 20) x)) into r;
  with a as (select p.id from publicacoes p
              where not exists (select 1 from conferencias_publicacao c where c.publicacao_id = p.id)
                and exists (select 1 from publicacoes_coletas k where k.publicacao_id = p.id and k.coletado_em < now() - interval '1 day'))
  select r || _integridade_item('publicacao_sem_conferencia', 'alerta', 'Publicações recebidas há mais de 1 dia sem nenhuma conferência no ADVBOX',
           (select count(*) from a), (select jsonb_agg(id) from (select id from a limit 20) x)) into r;
  with a as (select c.evidencia->>'publicacao_advbox' k from conferencias_publicacao c
              where c.evidencia ? 'publicacao_advbox' and c.situacao = 'encontrada_advbox'
                and c.id = (select max(y.id) from conferencias_publicacao y where y.publicacao_id = c.publicacao_id)
              group by 1 having count(distinct c.publicacao_id) > 1)
  select r || _integridade_item('intimacao_em_duas_publicacoes', 'erro', 'A mesma intimação do ADVBOX ligada (conferência vigente) a duas publicações',
           (select count(*) from a), (select jsonb_agg(k) from (select k from a limit 20) x)) into r;
  with a as (select t.id from tarefas t join tarefas p on p.id = t.unificada_em where p.unificada_em is not null)
  select r || _integridade_item('unificacao_em_cadeia', 'erro', 'Tarefa unificada em outra que também está unificada (cadeia)',
           (select count(*) from a), (select jsonb_agg(id) from (select id from a limit 20) x)) into r;
  with a as (select l.id from linhas_importadas l where l.situacao = 'valida' and l.tarefa_id is null and l.lote_id = v_lote and l.metodo_vinculo <> 'ambigua')
  select r || _integridade_item('linha_sem_tarefa', 'erro', 'Linhas válidas do lote atual sem tarefa vinculada (fora as ambíguas)',
           (select count(*) from a), (select jsonb_agg(id) from (select id from a limit 20) x)) into r;
  with a as (select l.id from linhas_importadas l where l.situacao = 'valida' and l.tarefa_id is null and l.lote_id = v_lote and l.metodo_vinculo = 'ambigua')
  select r || _integridade_item('linhas_ambiguas', 'info', 'Linhas ambíguas do lote atual: o Excel não permite saber a qual tarefa pertencem e, por regra, ficam sem vínculo',
           (select count(*) from a), (select jsonb_agg(id) from (select id from a limit 20) x)) into r;
  select r || _integridade_item('colaborador_sem_vinculo', 'alerta', 'Perfil de colaborador sem colaborador do ADVBOX vinculado (não verá tarefas)',
           (select count(*) from perfis where papel = 'colaborador' and colaborador_id is null), null) into r;
  select r || _integridade_item('sem_administrador', 'erro', 'Nenhum perfil de administrador',
           case when exists (select 1 from perfis where papel = 'admin') then 0 else 1 end, null) into r;
  with a as (select relname k from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity)
  select r || _integridade_item('tabela_sem_rls', 'erro', 'Tabela do esquema público sem RLS', (select count(*) from a), (select jsonb_agg(k) from a)) into r;
  with a as (select relname k from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relkind in ('r','v') and has_table_privilege('anon', c.oid, 'select'))
  select r || _integridade_item('anon_com_acesso', 'erro', 'Tabela ou visão legível pelo papel anônimo (sem login)', (select count(*) from a), (select jsonb_agg(k) from a)) into r;
  with a as (select proname k from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.prosecdef and p.proconfig is null)
  select r || _integridade_item('funcao_sem_search_path', 'erro', 'Função SECURITY DEFINER sem search_path fixo', (select count(*) from a), (select jsonb_agg(k) from a)) into r;
  select r || _integridade_item('erros_integracao_7d', 'alerta', 'Erros de integração nos últimos 7 dias',
           (select count(*) from log_integracao where nivel = 'erro' and ocorrido_em > now() - interval '7 days'), null) into r;
  with a as (select chave k from parametros where not confirmado)
  select r || _integridade_item('parametros_nao_confirmados', 'info', 'Parâmetros ainda não confirmados pela controladoria (regras provisórias)',
           (select count(*) from a), (select jsonb_agg(k) from a)) into r;
  return jsonb_build_object('verificado_em', now(), 'itens', r);
end $$;
