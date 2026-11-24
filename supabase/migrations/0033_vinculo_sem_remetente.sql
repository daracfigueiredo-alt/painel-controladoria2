-- =====================================================================
-- 0033 — Importações sucessivas: o "Remetente" muda no encaminhamento (homologação, 10/11/2026)
-- Achado no teste real P1 (2ª exportação, lote 6, comparado com o lote 5 de 07/11):
--  * 301 tarefas pendentes em 07/11 não apareciam em 10/11; 205 delas tinham, no arquivo de
--    10/11, uma tarefa "nova" com o mesmo processo, compromisso, partes, tipo de ação e 1º
--    parágrafo de Observações — só o Remetente era diferente, e em 175 o novo Remetente era o
--    responsável de 07/11 (encaminhamento). A chave estável (0002) contava o Remetente como
--    campo que não muda; no ADVBOX ele muda quando a tarefa é encaminhada.
-- Correção, sem mudar a chave (mudar a chave tornaria "novas" todas as tarefas já conhecidas):
--  1. importação: linha que criaria tarefa nova procura, nos lotes anteriores, a tarefa ainda
--     pendente com os mesmos dados SEM o Remetente; só liga quando o par é único dos dois lados
--     (senão continua nova, como antes). O encaminhamento passa a aparecer como troca de
--     responsável entre as importações;
--  2. comparação entre importações: usa a tarefa principal (inclui tarefas unificadas);
--  3. reparo do lote atual: os pares únicos já importados como "novos" são unificados na tarefa
--     anterior (mesmo mecanismo da 0007/0023, com evento de unificação) e as alterações entre
--     as importações são geradas. Pares ambíguos não são tocados.
-- Parâmetro importacao_vinculo_sem_remetente (true) permite desligar o item 1.
-- =====================================================================
insert into public.parametros (chave, valor, confirmado, descricao) values
  ('importacao_vinculo_sem_remetente', 'true', true,
   'Ligar linha nova à tarefa anterior (ainda pendente) com os mesmos dados exceto o Remetente, só quando o par é único. '
   || 'O Remetente muda no encaminhamento (constatado na homologação de 10/11/2026).')
on conflict (chave) do nothing;

create or replace function public.chave_sem_remetente(p_compromisso text, p_partes text, p_processo text, p_tipo text, p_obs text)
returns text language sql immutable set search_path = public as $$
  select public.chave_estavel(p_compromisso, null, p_partes, p_processo, p_tipo, p_obs)
$$;

-- ---------------------------------------------------------------- 1. importação
do $$
declare d text; ancora text := 'update _vinc set metodo = ''ambigua'' where chave is null;';
begin
  d := pg_get_functiondef('public._importar_arquivo_base(text, text, jsonb, bigint, timestamptz)'::regprocedure);
  if position('0033: vinculo sem remetente' in d) > 0 then return; end if;
  if (length(d) - length(replace(d, ancora, ''))) / length(ancora) <> 1 then
    raise exception '0033: trecho esperado não encontrado em _importar_arquivo_base';
  end if;
  d := replace(d, ancora, ancora || $blk$
  -- 0033: vinculo sem remetente. O Remetente muda quando a tarefa é encaminhada no ADVBOX.
  -- Linha que criaria tarefa nova -> tarefa anterior ainda pendente com os mesmos dados sem o
  -- Remetente, somente se o par for único dos dois lados.
  if coalesce((select (valor #>> '{}')::boolean from parametros where chave = 'importacao_vinculo_sem_remetente'), true) then
    create temporary table _fb on commit drop as
    with cand as (
      select v.id, chave_sem_remetente(l.compromisso, l.partes, l.processo_cnj, l.tipo_acao, l.observacoes) k2
        from _vinc v join linhas_importadas l on l.id = v.id
       where v.metodo = 'chave_estavel' and not exists (select 1 from tarefas t where t.chave_identificacao = v.chave)),
    no_lote as (select distinct coalesce(ty.unificada_em, ty.id) pr from linhas_importadas y join tarefas ty on ty.id = y.tarefa_id
                 where y.lote_id = v_lote and y.situacao = 'valida'),
    ult as (select distinct on (coalesce(t.unificada_em, t.id)) coalesce(t.unificada_em, t.id) pr, x.*
              from linhas_importadas x join tarefas t on t.id = x.tarefa_id
             where x.situacao = 'valida' and x.lote_id < v_lote
             order by coalesce(t.unificada_em, t.id), x.lote_id desc, x.id desc),
    ant as (select u.pr, chave_sem_remetente(u.compromisso, u.partes, u.processo_cnj, u.tipo_acao, u.observacoes) k2
              from ult u where u.data_conclusao is null and u.pr not in (select pr from no_lote)),
    par as (select c.id, a.pr from cand c join ant a on a.k2 = c.k2)
    select p.id, p.pr from par p
     where (select count(*) from par q where q.id = p.id) = 1 and (select count(*) from par q where q.pr = p.pr) = 1
       and p.pr not in (select t.id from _vinc w join tarefas t on t.chave_identificacao = w.chave);
    update _vinc v set chave = t.chave_identificacao from _fb f join tarefas t on t.id = f.pr where v.id = f.id;
    if exists (select 1 from _fb) then
      perform registrar_log_integracao('importacao_excel', 'info', 'vinculo_sem_remetente',
        (select count(*) from _fb) || ' linha(s) ligada(s) à tarefa anterior apesar da troca de Remetente (encaminhamento).',
        jsonb_build_object('importacao_id', v_imp, 'linhas', (select jsonb_agg(id) from _fb)));
    end if;
  end if;$blk$);
  execute d;
end $$;

-- ---------------------------------------------------------------- 2. comparação pela tarefa principal
do $$
declare d text; antes text := 'where x.tarefa_id = l.tarefa_id and x.lote_id < l.lote_id and x.situacao = ''valida''';
begin
  d := pg_get_functiondef('public._gerar_eventos_importacao(bigint, timestamptz)'::regprocedure);
  if position('0033: principal' in d) > 0 then return; end if;
  if (length(d) - length(replace(d, antes, ''))) / length(antes) <> 1 then
    raise exception '0033: trecho esperado não encontrado em _gerar_eventos_importacao';
  end if;
  d := replace(d, antes,
    'where x.tarefa_id in (select g.id from tarefas g, tarefas me where me.id = l.tarefa_id /* 0033: principal */'
    || ' and coalesce(g.unificada_em, g.id) = coalesce(me.unificada_em, me.id)) and x.lote_id < l.lote_id and x.situacao = ''valida''');
  execute d;
end $$;

-- ---------------------------------------------------------------- 3. reparo de um lote já importado
create or replace function public._reparar_vinculo_sem_remetente(p_lote bigint)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r record; n int := 0; v_ref timestamptz;
begin
  create temporary table _rp on commit drop as
  with no_lote as (select distinct coalesce(ty.unificada_em, ty.id) pr from linhas_importadas y join tarefas ty on ty.id = y.tarefa_id
                    where y.lote_id = p_lote and y.situacao = 'valida'),
  antes as (select distinct coalesce(ty.unificada_em, ty.id) pr from linhas_importadas y join tarefas ty on ty.id = y.tarefa_id
             where y.lote_id < p_lote and y.situacao = 'valida'),
  ult as (select distinct on (coalesce(t.unificada_em, t.id)) coalesce(t.unificada_em, t.id) pr, x.*
            from linhas_importadas x join tarefas t on t.id = x.tarefa_id
           where x.situacao = 'valida' and x.lote_id < p_lote
           order by coalesce(t.unificada_em, t.id), x.lote_id desc, x.id desc),
  velhas as (select u.pr, chave_sem_remetente(u.compromisso, u.partes, u.processo_cnj, u.tipo_acao, u.observacoes) k2
               from ult u where u.data_conclusao is null and u.pr not in (select pr from no_lote)),
  -- tarefas que só existem a partir deste lote, principais e sem outras unificadas nelas
  novas as (select distinct on (t.id) t.id pr, chave_sem_remetente(x.compromisso, x.partes, x.processo_cnj, x.tipo_acao, x.observacoes) k2
              from linhas_importadas x join tarefas t on t.id = x.tarefa_id
             where x.lote_id = p_lote and x.situacao = 'valida' and t.unificada_em is null
               and t.id not in (select pr from antes)
               and not exists (select 1 from tarefas z where z.unificada_em = t.id)
             order by t.id, x.id desc),
  par as (select v.pr velha, n.pr nova from velhas v join novas n on n.k2 = v.k2)
  select p.* from par p
   where (select count(*) from par q where q.velha = p.velha) = 1 and (select count(*) from par q where q.nova = p.nova) = 1;

  for r in select * from _rp loop
    update tarefas set unificada_em = r.velha where id = r.nova and unificada_em is null;
    insert into eventos (chave_dedupe, tarefa_id, tipo, ocorrido_em, precisao_ocorrido, valor_anterior, valor_novo,
                         origem, historico_recuperado, classificacao, evidencia)
    values ('unif-rem:' || r.nova, r.velha, 'unificacao_tarefa', now(), 'segundo', to_jsonb(r.nova), to_jsonb(r.velha),
            'administrativo', false, 'confirmado',
            jsonb_build_object('motivo', 'remetente_mudou_no_encaminhamento', 'lote', p_lote,
              'regra', 'Mesmo compromisso, processo, partes, tipo de ação e 1º parágrafo de Observações; só o Remetente mudou. Par único.',
              'tarefa_nova', r.nova, 'tarefa_anterior', r.velha, 'usuario', auth.uid()))
    on conflict (chave_dedupe) do nothing;
    n := n + 1;
  end loop;

  -- alterações entre as importações para as tarefas unificadas (as demais não mudam: chaves de dedupe)
  if n > 0 then
    select data_exportacao into v_ref from lotes_importacao where id = p_lote;
    for r in select id from importacoes where lote_id = p_lote and status = 'concluida' order by id loop
      drop table if exists _l, _cmp;
      perform _gerar_eventos_importacao(r.id, coalesce(v_ref, now()));
    end loop;
  end if;
  return jsonb_build_object('lote', p_lote, 'unificadas', n);
end $$;
revoke execute on function public._reparar_vinculo_sem_remetente(bigint) from public, anon, authenticated;
revoke execute on function public.chave_sem_remetente(text, text, text, text, text) from public, anon;
grant execute on function public.chave_sem_remetente(text, text, text, text, text) to authenticated;
