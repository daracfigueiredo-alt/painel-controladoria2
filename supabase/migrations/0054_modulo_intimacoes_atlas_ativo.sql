-- =====================================================================
-- 0054 — Módulo de intimações do Atlas ATIVADO (informado pela controladoria em 16/11/2026, 10:55)
-- Muda a decisão de 12/11 (0044). Com o módulo, a rotina do fim do expediente volta a espelhar as intimações do
-- Atlas (list_deadlines -> atlas_intimacoes) e o double check volta a comparar Webjur × Atlas (0041/0043/0046),
-- além do CNJ × Webjur (0044), que continua.
-- =====================================================================
do $$ begin
  perform set_config('controladoria.motivo', 'Módulo de intimações do Atlas ativado pela controladoria em 16/11/2026', true);
  update public.parametros set valor = 'true'::jsonb,
         descricao = 'O escritório usa o módulo de intimações do Atlas (ativado em 16/11/2026). Ligado: sincroniza as intimações do Atlas e compara com a Webjur no double check.'
   where chave = 'atlas_modulo_intimacoes';
end $$;
