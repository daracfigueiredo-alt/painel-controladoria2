-- =====================================================================
-- 0024 — Double check: duas regras decididas pela controladoria em 10/11/2026,
-- após o primeiro double check real (disponibilização 09/11: 51 publicações).
--  1. ÚNICA intimação do mesmo CNJ e data, com sobreposição de palavras >= 0,9,
--     é a mesma publicação (o cabeçalho "Intimação PROCESSO: ... ||" da Webjur
--     baixa o Jaccard para 0,58–0,70). Parâmetro double_check_unica_min_semelhanca.
--  2. Publicação sem par no ADVBOX, mas com OUTRA publicação da Webjur do mesmo
--     CNJ e mesmo dia já encontrada: "duplicidade_webjur" (mesmo ato em dobro:
--     DJEN + caderno "Expediente" do DJe-MG, cópias). Não prepara tarefa de análise.
--     Só conta como duplicidade se o texto for o mesmo (sobreposição >= 0,95) ou se
--     vier de outro caderno/fonte da Webjur (campo tribunal diferente, ex. FINT x TJMG).
--     Limite conhecido: um ato diferente, de OUTRO caderno, no mesmo processo e dia,
--     ausente no ADVBOX, ficaria como duplicidade; a classe aparece no painel e a
--     evidência guarda a semelhança com a publicação equivalente.
--  3. "Não encontrada" sem tarefa aprovada pode ser revista; a tarefa de análise
--     preparada é rejeitada automaticamente se a publicação for reclassificada.
-- =====================================================================
insert into public.parametros (chave, valor, confirmado, descricao) values
  ('double_check_unica_min_semelhanca', '0.9', true,
   'Sobreposição mínima para aceitar a ÚNICA intimação do mesmo CNJ e data como a mesma publicação. Confirmado em 10/11/2026.')
on conflict (chave) do nothing;

alter table public.conferencias_publicacao drop constraint if exists conferencias_publicacao_situacao_check;
alter table public.conferencias_publicacao add constraint conferencias_publicacao_situacao_check check (situacao in (
  'encontrada_advbox','nao_encontrada_advbox','processo_nao_cadastrado','inconclusiva','conferencia_manual',
  'erro_coleta','erro_acesso_advbox','duplicidade_webjur'));

create or replace function public.double_check_executar(p_inicio date, p_fim date)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_alto numeric := coalesce((select (valor #>> '{}')::numeric from parametros where chave = 'double_check_limiar_alto'), 0.85);
        v_baixo numeric := coalesce((select (valor #>> '{}')::numeric from parametros where chave = 'double_check_limiar_baixo'), 0.3);
        v_folga int := coalesce((select (valor #>> '{}')::int from parametros where chave = 'double_check_folga_dias'), 1);
        v_jac_min numeric := coalesce((select (valor #>> '{}')::numeric from parametros where chave = 'double_check_jaccard_min'), 0.7);
        v_jac_grupo numeric := coalesce((select (valor #>> '{}')::numeric from parametros where chave = 'double_check_jaccard_min_grupo'), 0.55);
        v_min_dia int := coalesce((select (valor #>> '{}')::int from parametros where chave = 'double_check_dia_min_publicacoes'), 5);
        v_cob_dia numeric := coalesce((select (valor #>> '{}')::numeric from parametros where chave = 'double_check_dia_min_cobertura'), 0.2);
        v_dist_min_pal int := coalesce((select (valor #>> '{}')::int from parametros where chave = 'double_check_distintiva_min_palavras'), 2);
        v_margem numeric := coalesce((select (valor #>> '{}')::numeric from parametros where chave = 'double_check_margem'), 0.1);
        v_unica numeric := coalesce((select (valor #>> '{}')::numeric from parametros where chave = 'double_check_unica_min_semelhanca'), 0.9);
        v_dup bigint; v_ta record;
        pu record; xr record; v_sit text; v_ult text; v_ev jsonb; v_res jsonb := '[]'; v_cob bigint; v_area text;
begin
  if not is_admin() then raise exception 'Somente a controladoria executa o double check' using errcode = '42501'; end if;
  if p_fim < p_inicio or p_fim - p_inicio > 62 then raise exception 'Período inválido (máximo 62 dias)'; end if;

  create temp table dc_pub on commit drop as
  select v.id, v.cnj, v.data_disponibilizacao as ddisp, v.data_publicacao as dpub, v.teor, teor_palavras(v.teor) as pal, v.tribunal as trib,
         (select c.situacao from conferencias_publicacao c where c.publicacao_id = v.id order by c.realizada_em desc, c.id desc limit 1) as ultima
    from publicacoes v where v.data_disponibilizacao between p_inicio and p_fim;

  -- intimações já ligadas em conferências anteriores (não reutilizáveis)
  create temp table dc_usada on commit drop as
  select distinct c.evidencia->>'publicacao_advbox' as post_id from conferencias_publicacao c
   where c.evidencia ? 'publicacao_advbox'
     and c.id = (select max(c2.id) from conferencias_publicacao c2 where c2.publicacao_id = c.publicacao_id);

  create temp table dc_par on commit drop as
  select p.id as pub_id, a.post_id, a.lawsuit_id, a.data_publicacao, a.capturada_em, teor_palavras(a.teor) as pal_a,
         teor_semelhanca(p.teor, a.teor) as ov, teor_jaccard(p.teor, a.teor) as jac, null::numeric as dist
    from dc_pub p join advbox_intimacoes a on a.cnj = p.cnj
     and (a.data_publicacao = p.dpub or (p.dpub is null and (a.capturada_em at time zone 'America/Sao_Paulo')::date = p.ddisp))
   where p.cnj is not null;

  -- palavras comuns a TODOS os textos do grupo (publicações da Webjur do mesmo CNJ/data + intimações candidatas)
  create temp table dc_grupo on commit drop as
  with g as (select distinct p.cnj, p.dpub, p.ddisp from dc_pub p where p.cnj is not null),
       textos as (
         select g.cnj, g.dpub, g.ddisp, 'w' || w.id as fonte, teor_palavras(w.teor) as pal
           from g join publicacoes w on w.cnj = g.cnj and w.data_publicacao is not distinct from g.dpub
                  and (g.dpub is not null or w.data_disponibilizacao = g.ddisp)
         union
         select g.cnj, g.dpub, g.ddisp, 'a' || a.post_id, teor_palavras(a.teor)
           from g join advbox_intimacoes a on a.cnj = g.cnj
            and (a.data_publicacao = g.dpub or (g.dpub is null and (a.capturada_em at time zone 'America/Sao_Paulo')::date = g.ddisp)))
  select t.cnj, t.dpub, t.ddisp, count(distinct t.fonte) as n,
         -- comuns a todos os textos de UMA MESMA fonte (2+ textos dela no grupo): cabeçalho de partes/advogados
         -- e fórmulas próprias de cada fonte; o que sobra é o que distingue um ato do outro
         array(select w from textos t2, unnest(t2.pal) w
                where t2.cnj = t.cnj and t2.dpub is not distinct from t.dpub and t2.ddisp = t.ddisp and left(t2.fonte, 1) = 'w'
                group by w having count(distinct t2.fonte) = (select count(distinct t3.fonte) from textos t3
                  where t3.cnj = t.cnj and t3.dpub is not distinct from t.dpub and t3.ddisp = t.ddisp and left(t3.fonte, 1) = 'w')
                   and count(distinct t2.fonte) >= 2
               union
               select w from textos t2, unnest(t2.pal) w
                where t2.cnj = t.cnj and t2.dpub is not distinct from t.dpub and t2.ddisp = t.ddisp and left(t2.fonte, 1) = 'a'
                group by w having count(distinct t2.fonte) = (select count(distinct t3.fonte) from textos t3
                  where t3.cnj = t.cnj and t3.dpub is not distinct from t.dpub and t3.ddisp = t.ddisp and left(t3.fonte, 1) = 'a')
                   and count(distinct t2.fonte) >= 2) as comuns
    from textos t group by t.cnj, t.dpub, t.ddisp;

  update dc_par r set dist = (
    select case when least(cardinality(dp), cardinality(da)) < v_dist_min_pal then null   -- poucas palavras próprias: não decide
                else round((select count(*) from unnest(dp) w where w = any(da))::numeric / least(cardinality(dp), cardinality(da)), 3) end
      from (select array(select unnest(p.pal) except select unnest(g.comuns)) as dp,
                   array(select unnest(r.pal_a) except select unnest(g.comuns)) as da
              from dc_pub p join dc_grupo g on g.cnj = p.cnj and g.dpub is not distinct from p.dpub and g.ddisp = p.ddisp
             where p.id = r.pub_id and cardinality(g.comuns) > 0) z)
  where true;

  -- pontuação usada para ordenar e para a margem: a distintiva quando existe, senão a sobreposição
  alter table dc_par add column pont numeric, add column segunda numeric, add column aceito boolean, add column ligado boolean default false;
  update dc_par set pont = coalesce(dist, ov) where true;
  update dc_par r set segunda = (select max(o.pont) from dc_par o where o.pub_id = r.pub_id and o.post_id <> r.post_id) where true;
  -- 0017: com palavras distintivas calculadas (grupo com 2+ textos de uma fonte), o Jaccard exigido é menor,
  -- porque a distintiva já separa atos diferentes; sem elas, vale o Jaccard mais alto.
  -- (0024) também aceita a ÚNICA intimação do mesmo CNJ e data com sobreposição >= 0,9 (cabeçalho da Webjur
  -- "Intimação PROCESSO: ... ||" derruba o Jaccard; decisão da controladoria em 10/11/2026)
  update dc_par set aceito = ((ov >= v_alto and (case when dist is null then jac >= v_jac_min else jac >= v_jac_grupo and dist >= 0.6 end)
                               and (segunda is null or pont - segunda >= v_margem))
                              or (segunda is null and ov >= v_unica
                                  -- textos curtos têm sobreposição alta por acaso: exige 20+ palavras nos dois
                                  and cardinality(pal_a) >= 20
                                  and (select cardinality(p.pal) from dc_pub p where p.id = dc_par.pub_id) >= 20))
                        and post_id not in (select post_id from dc_usada)
                 where true;

  for xr in select * from dc_par where aceito order by pont desc, jac desc, pub_id, post_id loop
    if not exists (select 1 from dc_par where ligado and (pub_id = xr.pub_id or post_id = xr.post_id)) then
      update dc_par set ligado = true where pub_id = xr.pub_id and post_id = xr.post_id;
    end if;
  end loop;

  create temp table dc_dia_suspeito on commit drop as
  select p.ddisp from dc_pub p where p.cnj is not null
   group by p.ddisp
  having count(*) >= v_min_dia
     and count(*) filter (where exists (select 1 from advbox_intimacoes a where a.cnj = p.cnj)) < v_cob_dia * count(*);

  for pu in select * from dc_pub order by ddisp, id loop
    v_ult := pu.ultima;
    select t.id, t.status into v_ta from tarefas_analise t where t.publicacao_id = pu.id;
    -- (0024) "não encontrada" ainda sem tarefa aprovada pode ser revista (ex.: duplicidade da Webjur)
    if v_ult in ('encontrada_advbox','processo_nao_cadastrado','conferencia_manual','duplicidade_webjur')
       or (v_ult = 'nao_encontrada_advbox' and v_ta.status is not null and v_ta.status not in ('preparada','conferencia_manual')) then
      v_res := v_res || jsonb_build_array(jsonb_build_object('publicacao_id', pu.id, 'resultado', 'ja_conferida', 'situacao', v_ult));
      continue;
    end if;
    v_sit := null;
    select * into xr from dc_par where pub_id = pu.id and ligado;
    if pu.cnj is null then
      v_sit := 'inconclusiva';
      v_ev := jsonb_build_object('motivo', 'Publicação sem CNJ identificado: conferir manualmente.');
    elsif xr.post_id is not null then
      v_sit := case when xr.lawsuit_id is null then 'processo_nao_cadastrado' else 'encontrada_advbox' end;
      v_ev := jsonb_build_object('publicacao_advbox', xr.post_id, 'lawsuit_id', xr.lawsuit_id, 'semelhanca', xr.ov, 'jaccard', xr.jac,
                                 'distintiva', xr.dist, 'segunda_melhor', xr.segunda, 'data_publicacao_advbox', xr.data_publicacao,
                                 'capturada_em', xr.capturada_em, 'regra', 'mesmo CNJ + mesma data de publicação + teor equivalente');
    else
      -- melhor intimação semelhante que continua livre (não ligada a outra publicação nesta execução nem antes)
      select * into xr from dc_par r where r.pub_id = pu.id and r.ov >= v_baixo and not r.ligado
         and not exists (select 1 from dc_par o where o.post_id = r.post_id and o.ligado)
         and r.post_id not in (select post_id from dc_usada)
       order by r.pont desc limit 1;
      if xr.post_id is not null then
        v_sit := 'inconclusiva';
        v_ev := jsonb_build_object('candidata', xr.post_id, 'semelhanca', xr.ov, 'jaccard', xr.jac, 'distintiva', xr.dist, 'segunda_melhor', xr.segunda,
                  'motivo', case when xr.segunda is not null and xr.pont - xr.segunda < v_margem then 'Duas ou mais intimações com teor muito parecido no mesmo processo e data.'
                                 when xr.ov >= v_alto then 'Muitas palavras em comum, mas os textos têm partes diferentes (pode ser outro ato do mesmo processo).'
                                 else 'Teor só parcialmente semelhante.' end);
      else
        select max(id) into v_cob from advbox_varreduras
         where completa and recebido_de <= pu.ddisp and recebido_ate >= pu.ddisp + v_folga;
        -- 0018: dia "suspeito" — muitas publicações e quase nenhuma com intimação do mesmo CNJ no ADVBOX.
        -- É o sinal de varredura que não refletiu o período (visto em 07/11/2026) ou de falha geral de captura:
        -- nos dois casos, a resposta certa é conferir a varredura, não gerar ausências em massa.
        if v_cob is not null and exists (select 1 from dc_dia_suspeito s where s.ddisp = pu.ddisp) then
          v_res := v_res || jsonb_build_array(jsonb_build_object('publicacao_id', pu.id, 'resultado', 'aguardando_varredura',
                     'motivo', 'Em ' || to_char(pu.ddisp, 'DD/MM/YYYY') || ' quase nenhuma publicação tem intimação do mesmo processo no ADVBOX. '
                            || 'Confira se a varredura mostrava mesmo o período (filtro, página recarregada) antes de concluir ausência.'));
          continue;
        end if;
        -- (0024) outra publicação da Webjur do MESMO processo e MESMO dia já bateu com o ADVBOX:
        -- é o mesmo ato em dobro na Webjur (DJEN + caderno do DJe, cópias); não é ausência. Decisão de 10/11/2026.
        select o.id into v_dup from dc_pub o
         where o.cnj = pu.cnj and o.ddisp = pu.ddisp and o.id <> pu.id
           -- só é duplicidade se for o MESMO texto (cópia) ou vier de OUTRO caderno/fonte da Webjur
           -- (ex.: "FINT" = caderno Expediente do DJe-MG x "TJMG" = DJEN). Dois atos diferentes do mesmo
           -- caderno continuam como ausência.
           and (teor_semelhanca(pu.teor, o.teor) >= 0.95 or o.trib is distinct from pu.trib)
           and (exists (select 1 from dc_par r where r.pub_id = o.id and r.ligado)
                or o.ultima in ('encontrada_advbox','processo_nao_cadastrado'))
         order by o.id limit 1;
        if v_cob is not null and v_dup is not null then
          v_sit := 'duplicidade_webjur';
          v_ev := jsonb_build_object('publicacao_equivalente', v_dup, 'varredura_id', v_cob,
                    'semelhanca_com_equivalente', (select teor_semelhanca(pu.teor, o.teor) from dc_pub o where o.id = v_dup),
                    'regra', 'outra publicação da Webjur do mesmo CNJ e da mesma disponibilização já foi encontrada no ADVBOX');
        elsif v_cob is not null then
          v_sit := 'nao_encontrada_advbox';
          v_ev := jsonb_build_object('varredura_id', v_cob,
                    'intimacoes_mesmo_cnj', (select count(*) from advbox_intimacoes a where a.cnj = pu.cnj),
                    'intimacoes_mesmo_cnj_data', (select count(*) from dc_par r where r.pub_id = pu.id),
                    'regra', 'nenhuma intimação livre do mesmo CNJ e data com teor semelhante numa varredura completa que cobre a disponibilização');
        else
          v_res := v_res || jsonb_build_array(jsonb_build_object('publicacao_id', pu.id, 'resultado', 'aguardando_varredura',
                     'motivo', 'Nenhuma varredura completa do ADVBOX cobre ' || to_char(pu.ddisp, 'DD/MM/YYYY') ||
                               ' a ' || to_char(pu.ddisp + v_folga, 'DD/MM/YYYY') || '.'));
          continue;
        end if;
      end if;
    end if;
    if v_sit is distinct from v_ult then
      v_area := case when v_ev ? 'publicacao_advbox' then 'intimacoes' else 'nenhuma' end;
      perform pub_registrar_conferencia(pu.id, v_sit, v_area, v_ev, v_ev->>'lawsuit_id', 'extensao');
      if v_ta.id is not null and v_ta.status in ('preparada','conferencia_manual')
         and v_sit not in ('nao_encontrada_advbox','processo_nao_cadastrado') then
        perform _analise_status(v_ta.id, array['preparada','conferencia_manual'], 'rejeitada',
                                'Reclassificada pelo double check: ' || v_sit || ' (tarefa de análise não é mais necessária).');
      end if;
      v_res := v_res || jsonb_build_array(jsonb_build_object('publicacao_id', pu.id, 'resultado', 'conferida', 'situacao', v_sit));
    else
      v_res := v_res || jsonb_build_array(jsonb_build_object('publicacao_id', pu.id, 'resultado', 'sem_mudanca', 'situacao', v_sit));
    end if;
  end loop;

  perform registrar_log_integracao('sistema', 'info', 'double_check_executar',
    'Double check executado de ' || to_char(p_inicio, 'DD/MM/YYYY') || ' a ' || to_char(p_fim, 'DD/MM/YYYY') || '.',
    jsonb_build_object('resumo', (select jsonb_object_agg(k, n) from (select coalesce(z->>'situacao', z->>'resultado') k, count(*) n
                                     from jsonb_array_elements(v_res) z group by 1) q)));
  return jsonb_build_object('total', jsonb_array_length(v_res), 'itens', v_res);
end $$;



create or replace function public.double_check_diario(p_inicio date, p_fim date)
returns jsonb language sql stable security invoker set search_path = public as $$
  select coalesce(jsonb_agg(to_jsonb(x) order by x.dia desc), '[]') from (
    select v.data_disponibilizacao as dia,
           count(*) as recebidas,
           count(*) filter (where v.situacao_conferencia is not null) as conferidas,
           count(*) filter (where v.situacao_conferencia = 'encontrada_advbox') as encontradas,
           count(*) filter (where v.situacao_conferencia = 'nao_encontrada_advbox') as ausentes,
           count(*) filter (where v.situacao_conferencia = 'processo_nao_cadastrado') as processo_nao_cadastrado,
           count(*) filter (where v.situacao_conferencia in ('inconclusiva','conferencia_manual')) as inconclusivas,
           count(*) filter (where v.situacao_conferencia = 'duplicidade_webjur') as duplicidades,
           count(*) filter (where v.situacao_conferencia in ('erro_coleta','erro_acesso_advbox')) as erros_integracao,
           count(*) filter (where v.situacao_conferencia is null) as aguardando,
           count(*) filter (where exists (select 1 from tarefas_analise_historico h where h.tarefa_analise_id = v.tarefa_analise_id and h.status_novo = 'aprovada')) as tarefas_aprovadas,
           count(*) filter (where v.tarefa_analise_status = 'criada') as tarefas_criadas,
           round(100.0 * count(*) filter (where v.situacao_conferencia in ('nao_encontrada_advbox','processo_nao_cadastrado'))
                 / nullif(count(*) filter (where v.situacao_conferencia in ('encontrada_advbox','nao_encontrada_advbox','processo_nao_cadastrado')), 0), 1) as pct_ausentes
      from v_publicacoes v
     where v.data_disponibilizacao between p_inicio and p_fim
     group by v.data_disponibilizacao) x
$$;
revoke execute on function public.double_check_executar(date, date), public.double_check_diario(date, date) from public, anon;
grant execute on function public.double_check_executar(date, date), public.double_check_diario(date, date) to authenticated;
