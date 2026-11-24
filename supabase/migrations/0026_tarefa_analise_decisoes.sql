-- =====================================================================
-- 0026 — Etapa 8: decisões da controladoria sobre as tarefas de análise (10/11/2026)
--  * Data da tarefa = data da conferência (pendência 9 do Prompt Mestre, resolvida).
--  * Prazo fatal da tarefa = data da tarefa + 1 dia útil.
--  * Processo não cadastrado no ADVBOX: a controladoria cadastra o processo ANTES;
--    a tarefa só é criada depois, já ligada ao processo.
--  * Criação: a extensão cria a tarefa sozinha após a aprovação no painel.
-- O tipo exato da tarefa no ADVBOX continua a conferir na tela real.
-- =====================================================================
update public.parametros set confirmado = true,
       descricao = 'Data da tarefa de análise = data da conferência. CONFIRMADO pela controladoria em 10/11/2026.'
 where chave = 'tarefa_analise_data_regra' and valor #>> '{}' = 'data_conferencia';

insert into public.parametros (chave, valor, confirmado, descricao) values
  ('tarefa_analise_pf_dias_uteis', '1', true,
   'Prazo fatal da tarefa de análise = data da tarefa + N dias úteis. Confirmado em 10/11/2026 (N = 1).'),
  ('tarefa_analise_sem_processo', '"cadastrar_antes"', true,
   'Processo não cadastrado no ADVBOX: a controladoria cadastra o processo antes; a tarefa é criada depois, ligada a ele. Confirmado em 10/11/2026.'),
  ('tarefa_analise_criacao', '"automatica_extensao"', true,
   'Criação da tarefa aprovada: a extensão cria sozinha no ADVBOX após a aprovação no painel. Confirmado em 10/11/2026.')
on conflict (chave) do nothing;

alter table public.tarefas_analise add column if not exists pf_previsto date;
update public.tarefas_analise set pf_previsto = public.somar_dias_uteis(data_prevista, 1)
 where pf_previsto is null and data_prevista is not null and status not in ('criada','rejeitada','ja_tratada');
