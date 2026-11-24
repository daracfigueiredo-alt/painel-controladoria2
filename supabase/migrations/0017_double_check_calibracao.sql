-- =====================================================================
-- 0017 — Etapa 7: calibração do double check com dados REAIS (07/11/2026)
--
-- Amostra: 21 intimações do ADVBOX (publicação 09/11/2026, capturadas em 06/11) comparadas com a
-- exportação real do portal Webjur de 06/11 (as mesmas publicações). Resultados (sobreposição/Jaccard):
--   DJEN, uma publicação por processo:      0,98–1,00 / 0,75–0,95  → as regras da 0016 acertam;
--   DJE do TJMG (textos curtos, vários atos do mesmo processo e data):
--                                           0,98 / 0,61–0,70 na correta, e 0,93–0,98 / 0,45–0,61 nas
--                                           erradas → só a "distintiva" separa (1,00 x 0,50 num caso);
--                                           num processo com 5 atos quase iguais a distintiva tem 1–3
--                                           palavras e empata → deve ir para conferência manual.
-- Ajustes (nada é apagado):
--   * Jaccard mínimo 0,70 quando a distintiva não é calculada; 0,55 quando é (grupo com 2+ textos de uma fonte);
--   * a distintiva só vale com 2+ palavras próprias em cada texto; abaixo disso não decide (empates → inconclusiva);
--   * área de conferência "intimacoes" e fonte principal CONFIRMADAS pela controladoria (06–07/11/2026).
-- =====================================================================
update public.parametros set valor = '0.7',
       descricao = 'Jaccard mínimo quando a distintiva NÃO é calculada. Calibrado em 07/11/2026 com 21 pares reais (DJEN: 0,75–0,95).'
 where chave = 'double_check_jaccard_min';
insert into public.parametros (chave, valor, confirmado, descricao) values
  ('double_check_jaccard_min_grupo', '0.55', false,
   'Jaccard mínimo quando a distintiva é calculada (DJE do TJMG: 0,61–0,70 nos pares corretos, 07/11/2026).'),
  ('double_check_distintiva_min_palavras', '2', false,
   'Mínimo de palavras próprias (fora do cabeçalho comum) em cada texto para a distintiva decidir.')
on conflict (chave) do nothing;
update public.parametros set confirmado = true,
       descricao = 'Área do ADVBOX que comprova a captura: Intimações (tela "Intimações recebidas" e aba Intimações do processo). '
                || 'CONFIRMADO pela controladoria em 07/11/2026. Andamentos/movimentações não comprovam a captura.'
 where chave = 'advbox_area_conferencia';

create or replace function public.double_check_executar(p_inicio date, p_fim date)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_alto numeric := coalesce((select (valor #>> '{}')::numeric from parametros where chave = 'double_check_limiar_alto'), 0.85);
        v_baixo numeric := coalesce((select (valor #>> '{}')::numeric from parametros where chave = 'double_check_limiar_baixo'), 0.3);
        v_folga int := coalesce((select (valor #>> '{}')::int from parametros where chave = 'double_check_folga_dias'), 1);
        v_jac_min numeric := coalesce((select (valor #>> '{}')::numeric from parametros where chave = 'double_check_jaccard_min'), 0.7);
        v_jac_grupo numeric := coalesce((select (valor #>> '{}')::numeric from parametros where chave = 'double_check_jaccard_min_grupo'), 0.55);
        v_dist_min_pal int := coalesce((select (valor #>> '{}')::int from parametros where chave = 'double_check_distintiva_min_palavras'), 2);
        v_margem numeric := coalesce((select (valor #>> '{}')::numeric from parametros where chave = 'double_check_margem'), 0.1);
        pu record; xr record; v_sit text; v_ult text; v_ev jsonb; v_res jsonb := '[]'; v_cob bigint; v_area text;
begin
  if not is_admin() then raise exception 'Somente a controladoria executa o double check' using errcode = '42501'; end if;
  if p_fim < p_inicio or p_fim - p_inicio > 62 then raise exception 'Período inválido (máximo 62 dias)'; end if;

  create temp table dc_pub on commit drop as
  select v.id, v.cnj, v.data_disponibilizacao as ddisp, v.data_publicacao as dpub, v.teor, teor_palavras(v.teor) as pal,
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
  update dc_par set aceito = ov >= v_alto and (case when dist is null then jac >= v_jac_min else jac >= v_jac_grupo and dist >= 0.6 end)
                        and (segunda is null or pont - segunda >= v_margem)
                        and post_id not in (select post_id from dc_usada)
                 where true;

  for xr in select * from dc_par where aceito order by pont desc, jac desc, pub_id, post_id loop
    if not exists (select 1 from dc_par where ligado and (pub_id = xr.pub_id or post_id = xr.post_id)) then
      update dc_par set ligado = true where pub_id = xr.pub_id and post_id = xr.post_id;
    end if;
  end loop;

  for pu in select * from dc_pub order by ddisp, id loop
    v_ult := pu.ultima;
    if v_ult in ('encontrada_advbox','nao_encontrada_advbox','processo_nao_cadastrado','conferencia_manual') then
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
        if v_cob is not null then
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


revoke execute on function public.double_check_executar(date, date) from public, anon;
grant execute on function public.double_check_executar(date, date) to authenticated;

-- ---------------------------------------------------------------- ritmo de leitura da extensão
-- Em 07/11/2026 o ADVBOX respondeu HTTP 413 depois de ~20 janelas abertas em ~25 s, e numa tentativa
-- anterior (0,25 s entre janelas) a sessão caiu. A extensão passa a: (1) abrir só as intimações cujo
-- teor ainda não está no banco; (2) esperar alguns segundos entre janelas; (3) parar na primeira
-- recusa do ADVBOX e registrar a varredura como incompleta. A espera (4 s) fica na extensão.
create or replace function public.ext_intimacoes_conhecidas(p_posts text[])
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Somente a controladoria' using errcode = '42501'; end if;
  if cardinality(p_posts) > 2000 then raise exception 'Mais de 2000 intimações'; end if;
  return coalesce((select jsonb_agg(post_id) from advbox_intimacoes where post_id = any(p_posts) and teor is not null), '[]');
end $$;
revoke execute on function public.ext_intimacoes_conhecidas(text[]) from public, anon;
grant execute on function public.ext_intimacoes_conhecidas(text[]) to authenticated;
