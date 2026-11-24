-- =====================================================================
-- 0028 — Tarefas de análise: cadastro do processo confirmado pela extensão (10/11/2026)
-- Observado pela controladoria: depois de cadastrar no ADVBOX os processos que o double
-- check marcou como "não cadastrados", a lista continuava dizendo "processo a cadastrar".
-- O banco só fica sabendo do cadastro quando a extensão encontra o processo no formulário
-- "Nova tarefa" do ADVBOX. A partir desta migração, ao confirmar a criação:
--   * a tarefa registra a data em que o cadastro foi confirmado (cadastro_confirmado_em);
--   * o processo entra na tabela de processos (origem "extensao") com o ID do ADVBOX, se ainda
--     não estava, e fica ligado à tarefa.
-- O retrato da conferência (requer_cadastro) não é apagado: é o que a conferência viu naquele dia.
-- =====================================================================
alter table public.tarefas_analise add column if not exists cadastro_confirmado_em timestamptz;

create or replace function public.analise_confirmar_criacao(p_id bigint, p_advbox_tarefa_id text, p_evidencia jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare t record; v_law text := nullif(coalesce(p_evidencia, '{}')->>'lawsuit_id', ''); v_proc bigint;
begin
  if not is_admin() then raise exception 'Somente a controladoria' using errcode = '42501'; end if;
  if p_advbox_tarefa_id !~ '^\d{1,15}$' then raise exception 'ID de tarefa do ADVBOX inválido'; end if;
  if v_law is not null and v_law !~ '^\d{1,15}$' then v_law := null; end if;
  perform _analise_status(p_id, array['criacao_em_andamento','verificar_no_advbox'], 'criada', null,
                          coalesce(p_evidencia,'{}') || jsonb_build_object('advbox_tarefa_id', p_advbox_tarefa_id));
  update tarefas_analise set advbox_tarefa_id = p_advbox_tarefa_id, criada_no_advbox_em = now(),
         advbox_lawsuit_id = coalesce(v_law, advbox_lawsuit_id) where id = p_id;
  select * into t from tarefas_analise where id = p_id;
  if t.cnj is not null and coalesce(v_law, t.advbox_lawsuit_id) is not null then
    v_proc := t.processo_id;
    if v_proc is null then
      insert into processos (cnj, cnj_digito_valido, origem) values (normalizar_cnj(t.cnj), cnj_digito_valido(normalizar_cnj(t.cnj)), 'extensao')
      on conflict (cnj) do nothing;
      select id into v_proc from processos where cnj = normalizar_cnj(t.cnj);
    end if;
    update processos set advbox_lawsuit_id = coalesce(v_law, t.advbox_lawsuit_id)
     where id = v_proc and advbox_lawsuit_id is null
       and not exists (select 1 from processos x where x.advbox_lawsuit_id = coalesce(v_law, t.advbox_lawsuit_id));
    update tarefas_analise set processo_id = coalesce(processo_id, v_proc),
           cadastro_confirmado_em = case when requer_cadastro then now() else cadastro_confirmado_em end
     where id = p_id;
  end if;
  return jsonb_build_object('id', p_id, 'status', 'criada', 'advbox_tarefa_id', p_advbox_tarefa_id);
end $$;

create or replace function public.analise_listar(p_status text default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Somente a controladoria' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(x order by x.ordem, x.id) from (
    select t.id, t.status, t.teste, t.cnj, t.busca_advbox, t.requer_cadastro, t.cadastro_confirmado_em, t.tipo, t.responsavel,
           t.data_prevista, t.pf_previsto,
           t.advbox_tarefa_id, t.criada_no_advbox_em, t.advbox_lawsuit_id, t.bloqueio_criacao, t.bloqueio_detalhe, t.tentativas,
           t.preparada_em, t.atualizada_em, p.id as publicacao_id, p.data_disponibilizacao, p.data_publicacao, p.tribunal, p.orgao_julgador,
           (select advbox_lawsuit_id from processos where id = t.processo_id) as processo_advbox_id,
           case t.status when 'verificar_no_advbox' then 0 when 'criacao_em_andamento' then 1 when 'aprovada' then 2
                         when 'preparada' then 3 when 'conferencia_manual' then 4 else 5 end as ordem
      from tarefas_analise t left join publicacoes p on p.id = t.publicacao_id
     where p_status is null and (t.status not in ('criada','rejeitada','ja_tratada') or t.atualizada_em > now() - interval '7 days')
        or t.status = p_status) x), '[]'::jsonb);
end $$;
