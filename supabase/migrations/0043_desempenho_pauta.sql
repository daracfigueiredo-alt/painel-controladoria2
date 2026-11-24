-- =====================================================================
-- 0043 — Desempenho e ajuste do double check (homologação, 11/11/2026). Mesmos resultados.
-- Achados no banco real, logo após a 0039–0041:
--   * "Minha pauta" da controladoria (346 tarefas) levou 14,7 s: a execução de cada tarefa era
--     montada uma a uma (linha atual, modalidade, checklist, anexos). Agora é calculada de uma vez
--     para todas as tarefas, com a mesma visibilidade (controladoria e diretoria: todas; líder: a
--     equipe; peticionador: as próprias).
--   * A lista de descrições a padronizar consultava a base inteira para cada tarefa. Agora os
--     prazos vêm da mesma consulta; o texto do bloco continua idêntico (mesma função de texto).
--   * Double check Webjur × Atlas antes da primeira sincronização das intimações: todas as
--     publicações apareciam como "não cadastradas no Atlas". Sem nenhuma intimação sincronizada,
--     as regras que comparam com o Atlas não rodam; fica só a pendência "intimações do Atlas não
--     sincronizadas".
-- =====================================================================

-- modalidade a partir do título já conhecido (sem buscar a linha de novo)
create or replace function public._modalidade_de(p_principal bigint, p_titulo text) returns bigint
language sql stable security definer set search_path = public as $$
  select case when exists (select 1 from tarefas_modalidade where tarefa_id = p_principal)
              then (select modalidade_id from tarefas_modalidade where tarefa_id = p_principal)
              else public._modalidade_por_titulo(p_titulo) end
$$;

-- texto do bloco (única fonte; usado pela função de uma tarefa e pela lista)
create or replace function public._bloco_texto(m public.modalidades, p_d4 date, p_pf date, p_d7 date) returns text
language plpgsql stable set search_path = public as $$
declare v_txt text; it jsonb; f constant text := 'DD/MM/YYYY';
begin
  if m.id is null or not m.ativa then return null; end if;
  v_txt := '=== Controladoria Oliveira e Camilo (padrão) ===' || E'\n'
        || 'Modalidade: ' || m.nome || E'\n'
        || 'Prazo judicial (fatal): ' || coalesce(to_char(p_pf, f), 'não informado')
        || ' | Entrega interna (D-4): ' || coalesce(to_char(p_d4, f), 'não calculado')
        || ' | Agenda (D-7): ' || coalesce(to_char(p_d7, f), '-') || E'\n';
  if m.orientacoes is not null then v_txt := v_txt || 'Orientações: ' || m.orientacoes || E'\n'; end if;
  if m.link_treinamento is not null then v_txt := v_txt || 'Material de treinamento: ' || m.link_treinamento || E'\n'; end if;
  if m.link_notebooklm is not null then v_txt := v_txt || 'Conferência técnica (NotebookLM): ' || m.link_notebooklm || E'\n'; end if;
  v_txt := v_txt || 'Checklist obrigatório (marcar na extensão ou em Minha pauta):' || E'\n';
  for it in select * from jsonb_array_elements(m.checklist) loop v_txt := v_txt || '[ ] ' || (it->>'texto') || E'\n'; end loop;
  if m.exige_peca then v_txt := v_txt || 'Anexo obrigatório: peça produzida' || E'\n'; end if;
  if m.exige_parecer then v_txt := v_txt || 'Anexo obrigatório: parecer de autoavaliação (após a conferência no NotebookLM)' || E'\n'; end if;
  return v_txt || '=== fim do padrão da controladoria ===';
end $$;

create or replace function public.bloco_descricao_padrao(p_tarefa bigint) returns text
language plpgsql stable security definer set search_path = public as $$
declare v_t bigint := public._tarefa_principal(p_tarefa); m modalidades; v record;
begin
  select * into m from modalidades where id = public.modalidade_da_tarefa(v_t);
  if m.id is null or not m.ativa then return null; end if;
  select d4, pf_judicial, d7_data_agenda into v from v_tarefas_atuais where tarefa_id is not null
     and public._tarefa_principal(tarefa_id) = v_t limit 1;
  return public._bloco_texto(m, v.d4, v.pf_judicial, v.d7_data_agenda);
end $$;

create or replace function public.descricoes_para_padronizar(p_limite int default 200) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Somente administradores' using errcode = '42501'; end if;
  if not exists (select 1 from modalidades where ativa) then return '[]'::jsonb; end if;
  return coalesce((select jsonb_agg(x) from (
    select t.id as tarefa_id, t.atlas_id, l.dados_brutos->>'_atlas_descricao' as descricao_original,
           coalesce((l.dados_brutos->>'_atlas_descricao_truncada')::boolean, false) as truncada,
           b.bloco, md5(b.bloco) as hash_bloco
      from v_tarefas_atuais v join tarefas t on t.id = v.tarefa_id
      join linhas_importadas l on l.id = v.linha_id
      join modalidades m on m.ativa and m.id = public._modalidade_de(coalesce(t.unificada_em, t.id), v.compromisso)
      cross join lateral (select public._bloco_texto(m, v.d4, v.pf_judicial, v.d7_data_agenda) as bloco) b
     where v.situacao = 'pendente' and t.atlas_id is not null and b.bloco is not null
       and md5(b.bloco) is distinct from (select d.hash_bloco from descricoes_padronizadas d
                                           where d.tarefa_id = t.id and d.resultado = 'gravada' order by d.em desc limit 1)
     order by v.d7_data_agenda nulls last limit greatest(coalesce(p_limite, 200), 1)) x), '[]');
end $$;

-- ---------------------------------------------------------------- pauta: cálculo de uma vez
create or replace function public.minha_pauta(p_colaborador bigint default null, p_dias int default 30)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_res jsonb; v_tudo boolean := public.pode_ler_tudo(); v_admin boolean := public.is_admin();
        v_mc bigint[] := public.meus_colaboradores(); v_modo text := (select valor #>> '{}' from parametros where chave = 'trava_execucao_modo');
        v_max int := param_int('anexo_tamanho_maximo_mb');
begin
  if public.meu_papel() is null then raise exception 'Usuário sem perfil na controladoria' using errcode = '42501'; end if;
  with p as (
    select v.*, coalesce(t.unificada_em, t.id) as principal, t.atlas_id
      from v_tarefas_atuais v join tarefas t on t.id = v.tarefa_id
     where v.situacao = 'pendente'
       and (v_tudo or v.responsavel_id = any (v_mc))                      -- mesma visibilidade da base
       and (p_colaborador is null or v.responsavel_id = p_colaborador)
       and (v.d7_data_agenda is null or v.d7_data_agenda <= v.hoje + greatest(coalesce(p_dias, 30), 1))
  ), pm as (
    select p.*, m.id as m_id, m.nome as m_nome, m.ativa as m_ativa, m.checklist as m_check, m.link_treinamento, m.link_notebooklm,
           m.orientacoes, m.exige_peca, m.exige_parecer, m.pontos as m_pontos,
           exists (select 1 from tarefas_modalidade tm where tm.tarefa_id = p.principal) as manual
      from p left join modalidades m on m.id = public._modalidade_de(p.principal, p.compromisso)
  ), marc as (
    select distinct on (e.tarefa_id, e.item_id) e.tarefa_id, e.item_id, e.marcado
      from execucao_checklist e where e.tarefa_id in (select principal from pm)
     order by e.tarefa_id, e.item_id, e.em desc, e.id desc
  ), ck as (
    select pm.principal, jsonb_agg(jsonb_build_object('id', i->>'id', 'texto', i->>'texto', 'marcado', coalesce(mc.marcado, false)) order by o) itens,
           array_agg('Checklist: ' || (i->>'texto') order by o) filter (where not coalesce(mc.marcado, false)) pend
      from pm cross join lateral jsonb_array_elements(pm.m_check) with ordinality x(i, o)
      left join marc mc on mc.tarefa_id = pm.principal and mc.item_id = i->>'id'
     where pm.m_id is not null group by pm.principal
  ), ax as (
    select a.tarefa_id, jsonb_agg(jsonb_build_object('id', a.id, 'tipo', a.tipo, 'nome', a.nome_arquivo, 'tamanho', a.tamanho,
             'caminho', a.caminho, 'em', a.em, 'por', coalesce(c.nome_advbox, u.email)) order by a.em desc) lista,
           bool_or(a.tipo = 'peca') peca, bool_or(a.tipo = 'parecer_autoavaliacao') parecer
      from anexos_tarefa a left join colaboradores c on c.id = a.colaborador_id left join auth.users u on u.id = a.por
     where a.tarefa_id in (select principal from pm) group by a.tarefa_id
  ), ex as (
    select pm.*, coalesce(ck.itens, '[]') as itens, coalesce(ax.lista, '[]') as anexos,
           case when pm.m_id is null then '{}'::text[]
                else coalesce(ck.pend, '{}')
                     || case when pm.exige_peca and not coalesce(ax.peca, false) then array['Anexar a peça produzida'] else '{}'::text[] end
                     || case when pm.exige_parecer and not coalesce(ax.parecer, false) then array['Anexar o parecer de autoavaliação'] else '{}'::text[] end
           end as pend
      from pm left join ck on ck.principal = pm.principal left join ax on ax.tarefa_id = pm.principal
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'tarefa_id', e.principal, 'compromisso', e.compromisso, 'responsavel', e.responsavel, 'responsavel_id', e.responsavel_id,
           'processo_cnj', e.processo_cnj, 'partes', e.partes, 'prioridade', e.prioridade,
           'data_agenda', e.d7_data_agenda, 'd4', e.d4, 'pf_judicial', e.pf_judicial, 'pf_tarefa', e.pf_tarefa,
           'inicio_tratativa_em', e.inicio_tratativa_em, 'excecao_d4', public._excecao_d4_em(e.principal),
           'atlas_url', case when e.atlas_id is not null then 'https://gestor.atlasjus.com/#/tasks?task=' || e.atlas_id end,
           'modalidade', case when e.m_id is null then null else jsonb_build_object('id', e.m_id, 'nome', e.m_nome, 'ativa', e.m_ativa,
               'link_treinamento', e.link_treinamento, 'link_notebooklm', e.link_notebooklm, 'orientacoes', e.orientacoes,
               'exige_peca', e.exige_peca, 'exige_parecer', e.exige_parecer, 'pontos', e.m_pontos) end,
           'modalidade_manual', e.manual,
           'checklist', e.itens, 'anexos', e.anexos, 'pendencias', to_jsonb(e.pend),
           'exigido', coalesce(e.m_ativa, false), 'completo', cardinality(e.pend) = 0, 'modo', v_modo,
           'pode_editar', v_admin or coalesce(e.responsavel_id = any (v_mc), false), 'anexo_tamanho_maximo_mb', v_max)
         order by e.d7_data_agenda nulls last, e.d4 nulls last, e.compromisso), '[]')
    into v_res from ex e;
  return v_res;
end $$;

-- pontos da tarefa pelo título já conhecido (planejamento)
create or replace function public._pontos_de(p_principal bigint, p_titulo text) returns int
language sql stable security definer set search_path = public as $$
  select coalesce((select m.pontos from modalidades m where m.id = public._modalidade_de(p_principal, p_titulo)), param_int('tarefa_sem_modalidade_pontos'))
$$;

do $$
declare d text; a text := $x$v.prioridade, public._pontos_tarefa(v.tarefa_id), t.atlas_id$x$;
begin
  d := pg_get_functiondef('public.analisar_pauta(bigint, date, int, boolean, bigint)'::regprocedure);
  if position('_pontos_de' in d) > 0 then return; end if;
  if position(a in d) = 0 then raise exception '0043: trecho esperado não encontrado em analisar_pauta'; end if;
  d := replace(d, a, $x$v.prioridade, public._pontos_de(coalesce(t.unificada_em, t.id), v.compromisso), t.atlas_id$x$);
  execute d;
end $$;

-- ---------------------------------------------------------------- double check: nada a comparar antes da 1ª sincronização
do $$
declare d text;
begin
  d := pg_get_functiondef('public.double_check_atlas_executar(date, text)'::regprocedure);
  if position('0043' in d) > 0 then return; end if;
  -- sem intimação sincronizada, a janela de publicações fica vazia (as comparações não rodam); as pendências continuam
  d := replace(d, $x$  insert into _pub select id, cnj, data_disponibilizacao, teor, tribunal from publicacoes
   where data_disponibilizacao between v_ini and v_dia;$x$,
                  $x$  insert into _pub select id, cnj, data_disponibilizacao, teor, tribunal from publicacoes
   where data_disponibilizacao between v_ini and v_dia
     and v_ult_sync is not null;   -- 0043: sem intimações do Atlas sincronizadas, não há com o que comparar$x$);
  if position('0043' in d) = 0 then raise exception '0043: trecho esperado não encontrado em double_check_atlas_executar'; end if;
  execute d;
end $$;

revoke execute on function public._modalidade_de(bigint, text), public._bloco_texto(public.modalidades, date, date, date),
                          public._pontos_de(bigint, text) from public, anon, authenticated;
revoke execute on function public.minha_pauta(bigint, int) from public, anon;
grant execute on function public.minha_pauta(bigint, int) to authenticated;
