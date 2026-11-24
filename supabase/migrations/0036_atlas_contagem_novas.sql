-- =====================================================================
-- 0036 — Sincronização com o Atlas: contagem de tarefas novas (11/11/2026)
-- Achado na 1ª sincronização real (lote 7, importação 11): 527 tarefas, todas novas, mas o resumo
-- disse "0 novas, 527 já conhecidas". A 0035 criava as tarefas do Atlas ANTES da contagem das já
-- conhecidas. Os dados estavam certos (527 linhas ligadas pelo ID do Atlas); só o resumo errava.
-- Correção: a tarefa do Atlas é criada pelo passo normal da importação (depois da contagem) e o
-- ID do Atlas é gravado logo em seguida.
-- =====================================================================
do $$
declare d text;
  pre text := $a$
  insert into tarefas (chave_identificacao, metodo, advbox_id, atlas_id)
  select distinct v.chave, 'atlas_id', substr(v.chave, 4), substr(v.chave, 4)::uuid
    from _vinc v where v.metodo = 'atlas_id'
  on conflict (chave_identificacao) do nothing;$a$;
  ancora text := $a$  update tarefas t set ultima_linha_id = l.id
    from linhas_importadas l where l.importacao_id = v_imp and l.tarefa_id = t.id;$a$;
begin
  d := pg_get_functiondef('public._importar_arquivo_base(text, text, jsonb, bigint, timestamptz)'::regprocedure);
  if position('0036: atlas' in d) > 0 then return; end if;
  if position(pre in d) = 0 or position(ancora in d) = 0 then raise exception '0036: trechos esperados não encontrados'; end if;
  d := replace(d, pre, '');
  d := replace(d, ancora, ancora || $b$
  -- 0036: atlas. ID do Atlas nas tarefas criadas por esta importação (depois da contagem das já conhecidas).
  update tarefas t set atlas_id = substr(t.chave_identificacao, 4)::uuid, advbox_id = substr(t.chave_identificacao, 4)
   where t.metodo = 'atlas_id' and t.atlas_id is null
     and t.id in (select tarefa_id from linhas_importadas where importacao_id = v_imp);$b$);
  execute d;
end $$;

-- O resumo da importação 11 NÃO é corrigido: importação encerrada é imutável (tg_importacao_fechada).
-- O número certo (527 novas, 0 já conhecidas) fica registrado em docs/ETAPA11_ATLAS.md.
