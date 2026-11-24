-- =====================================================================
-- 0016 — Etapa 7: double check Webjur x ADVBOX
--
-- Base: inspeção somente leitura do ADVBOX real em 06/11/2026.
--   Tela "Intimações recebidas" (/publications), tabela DataTables com paginação NO SERVIDOR:
--     colunas Processo (partes) | Publicação (data de publicação) | Tribunal | Número do processo |
--     Responsável | Situação; cada linha é um post (posts/<id>/edit) e, quando há processo
--     vinculado, um link lawsuits/<id>/edit.
--   Linha "N/A": intimação capturada SEM processo vinculado. A janela diz "Nenhum processo
--     vinculado / Cadastrar um novo processo". O CNJ só aparece no teor ("Processo: ...").
--   Janela da intimação (GET posts/<id>/edit): teor integral, "Inteiro Teor" (link do tribunal),
--     "Nome pesquisado", "Data da publicação", "Criado por" (órgão + data/hora da captura), "Processo".
--   Janela do processo: abas Tarefas | Andamentos | Intimações | Financeiro. Andamentos
--     (movimentações) não são usados como prova de captura (Prompt Mestre §17).
--   Filtro de período por data de RECEBIMENTO no ADVBOX (Hoje, 3, 7 ou 30 dias, ou De/Até).
--
-- Estrutura (nada é apagado):
--   advbox_varreduras         cada leitura da tela feita pela extensão (filtro, completude, quem, quando)
--   advbox_intimacoes         cada intimação do ADVBOX já vista (teor da 1ª leitura preservado)
--   advbox_intimacoes_vistas  quais intimações cada varredura viu (cobertura)
--   ext_registrar_varredura   RPC da extensão (só admin)
--   double_check_executar     compara Webjur x ADVBOX e grava as conferências (só admin)
--   double_check_listar / double_check_diario   painel
-- =====================================================================

-- Fonte principal das publicações CONFIRMADA pela controladoria em 06/11/2026: exportação Planilha do portal.
update public.parametros
   set valor = '"portal_exportacao_planilha"', confirmado = true,
       descricao = 'Fonte principal das publicações Webjur: exportação "Planilha" (CSV) do portal, importada no painel. '
                || 'Contingência e segunda contagem: e-mail diário. CONFIRMADO pela controladoria em 06/11/2026.'
 where chave = 'webjur_fonte_principal';

insert into public.parametros (chave, valor, confirmado, descricao) values
  ('double_check_limiar_alto', '0.85', false,
   'Sobreposição mínima de palavras do teor (0 a 1) para dar uma intimação do ADVBOX como a MESMA publicação da Webjur (mesmo CNJ e data). PROVISÓRIO: calibrar com uma varredura real.'),
  ('double_check_jaccard_min', '0.75', false,
   'Jaccard mínimo (palavras em comum ÷ palavras das duas) exigido junto com o limiar alto. Protege contra atos diferentes do mesmo processo com o mesmo cabeçalho de partes.'),
  ('double_check_margem', '0.1', false,
   'Diferença mínima entre a melhor e a segunda melhor intimação do mesmo CNJ e data; abaixo disso, inconclusiva.'),
  ('double_check_limiar_baixo', '0.3', false,
   'Abaixo do limiar alto e acima deste: correspondência inconclusiva (conferência manual).'),
  ('double_check_folga_dias', '1', false,
   'Dias corridos após a disponibilização que a varredura do ADVBOX precisa cobrir antes de concluir "não encontrada".')
on conflict (chave) do nothing;

update public.parametros
   set valor = '"intimacoes"',
       descricao = 'Área do ADVBOX que comprova a captura. PROPOSTA (Etapa 7, 06/11/2026): "Intimações" (tela Intimações recebidas e aba '
                || 'Intimações do processo). Andamentos/movimentações não comprovam a captura. Aguardando confirmação.'
 where chave = 'advbox_area_conferencia' and confirmado = false;

-- a área "intimacoes" passa a ser aceita nas conferências (as anteriores continuam valendo)
alter table public.conferencias_publicacao drop constraint if exists conferencias_publicacao_area_conferida_check;
alter table public.conferencias_publicacao add constraint conferencias_publicacao_area_conferida_check
  check (area_conferida in ('publicacoes','movimentacoes','ambas','nenhuma','intimacoes'));

-- ---------------------------------------------------------------- varreduras e intimações
create table public.advbox_varreduras (
  id              bigint generated always as identity primary key,
  origem          text not null default 'extensao' check (origem in ('extensao','manual')),
  pagina          text not null,                       -- ex.: /publications
  filtro          jsonb not null,                      -- {intervalo, de, ate, responsavel} como a tela mostrava
  recebido_de     date,                                -- período coberto (data de recebimento no ADVBOX)
  recebido_ate    date,
  total_informado int,                                 -- "1-84 de 84" → 84
  total_lido      int not null,
  completa        boolean not null,                    -- lidas = informadas e todas as janelas abertas sem erro
  erros           jsonb not null default '[]',
  realizada_em    timestamptz not null default now(),
  realizada_por   uuid,
  check (recebido_de is null or recebido_ate is null or recebido_de <= recebido_ate)
);
create trigger advbox_varreduras_imutavel before update or delete on public.advbox_varreduras
  for each row execute function public.tg_bloqueia_alteracao();

create table public.advbox_intimacoes (
  post_id            text primary key check (post_id ~ '^\d{1,15}$'),
  cnj                text,                              -- normalizado (lista ou "Processo:" do teor)
  cnj_original       text,
  data_publicacao    date,
  tribunal           text,
  orgao              text,                              -- "Criado por" (órgão)
  capturada_em       timestamptz,                       -- "Criado por" (data/hora)
  lawsuit_id         text,                              -- null = sem processo vinculado ("N/A")
  partes             text,
  nome_pesquisado    text,
  teor               text,                              -- da 1ª leitura com teor (nunca sobrescrito)
  teor_hash          text,
  url_inteiro_teor   text,
  situacao_advbox    text,                              -- última vista (ex.: Pendente)
  primeira_varredura bigint not null references public.advbox_varreduras(id),
  ultima_varredura   bigint not null references public.advbox_varreduras(id),
  conteudo_original  jsonb not null,                    -- 1ª leitura completa
  ultima_leitura     jsonb not null
);
create index on public.advbox_intimacoes (cnj, data_publicacao);

create table public.advbox_intimacoes_vistas (
  varredura_id bigint not null references public.advbox_varreduras(id),
  post_id      text not null references public.advbox_intimacoes(post_id),
  primary key (varredura_id, post_id)
);

-- Só o que muda na tela é atualizado; teor, captura e 1ª leitura ficam como na primeira vez.
create or replace function public.tg_advbox_intimacao_preserva() returns trigger language plpgsql as $$
begin
  if tg_op = 'DELETE' then raise exception 'Intimações do ADVBOX não são apagadas (auditoria)'; end if;
  new.post_id := old.post_id; new.primeira_varredura := old.primeira_varredura; new.conteudo_original := old.conteudo_original;
  new.capturada_em := coalesce(old.capturada_em, new.capturada_em);
  if old.teor is not null then new.teor := old.teor; new.teor_hash := old.teor_hash; end if;
  new.cnj := coalesce(old.cnj, new.cnj); new.cnj_original := coalesce(old.cnj_original, new.cnj_original);
  new.data_publicacao := coalesce(old.data_publicacao, new.data_publicacao);
  return new;
end $$;
create trigger advbox_intimacoes_preserva before update or delete on public.advbox_intimacoes
  for each row execute function public.tg_advbox_intimacao_preserva();
create trigger advbox_intimacoes_vistas_imutavel before update or delete on public.advbox_intimacoes_vistas
  for each row execute function public.tg_bloqueia_alteracao();

-- ---------------------------------------------------------------- semelhança de teor
-- Palavras com 4+ letras/dígitos, sem acento e sem caixa; coeficiente de sobreposição |A∩B| / min(|A|,|B|).
-- Usa o menor conjunto porque uma fonte costuma trazer cabeçalhos a mais (lista de advogados, "Inteiro Teor").
create or replace function public.teor_palavras(p text) returns text[]
language sql immutable as $$
  select coalesce(array_agg(distinct w), '{}') from regexp_split_to_table(
    lower(translate(coalesce(p, ''), 'ÁÀÂÃÄáàâãäÉÈÊËéèêëÍÌÎÏíìîïÓÒÔÕÖóòôõöÚÙÛÜúùûüÇçÑñ',
                                     'AAAAAaaaaaEEEEeeeeIIIIiiiiOOOOOoooooUUUUuuuuCcNn')), '[^a-z0-9]+') w
  where length(w) >= 4
$$;
create or replace function public.teor_jaccard(a text, b text) returns numeric
language sql immutable as $$
  with x as (select teor_palavras(a) pa, teor_palavras(b) pb)
  select case when cardinality(pa) = 0 or cardinality(pb) = 0 then 0
              else round((select count(*) from unnest(pa) w where w = any(pb))::numeric
                         / (select count(*) from (select unnest(pa) union select unnest(pb)) u), 3) end
    from x
$$;
create or replace function public.teor_semelhanca(a text, b text) returns numeric
language sql immutable as $$
  with x as (select teor_palavras(a) pa, teor_palavras(b) pb)
  select case when least(cardinality(pa), cardinality(pb)) = 0 then 0
              else round((select count(*) from unnest(pa) w where w = any(pb))::numeric / least(cardinality(pa), cardinality(pb)), 3) end
    from x
$$;

-- ---------------------------------------------------------------- RPC da extensão
-- p_varredura: {pagina, filtro:{intervalo, de, ate, responsavel}, recebido_de, recebido_ate, total_informado, erros:[...]}
-- p_intimacoes: [{post_id, cnj, data_publicacao, tribunal, orgao, capturada_em, lawsuit_id, partes, nome_pesquisado,
--                 teor, url_inteiro_teor, situacao}]
create or replace function public.ext_registrar_varredura(p_varredura jsonb, p_intimacoes jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id bigint; i jsonb; v_cnj text; v_n int; v_inf int; v_erros jsonb; v_novas int := 0; v_ja int := 0;
        v_de date; v_ate date;
begin
  if not is_admin() then raise exception 'Somente a controladoria registra varreduras do ADVBOX' using errcode = '42501'; end if;
  if jsonb_typeof(p_intimacoes) <> 'array' then raise exception 'p_intimacoes deve ser uma lista'; end if;
  v_n := jsonb_array_length(p_intimacoes);
  if v_n > 2000 then raise exception 'Mais de 2000 intimações numa varredura'; end if;
  v_inf := nullif(p_varredura->>'total_informado','')::int;
  v_erros := coalesce(p_varredura->'erros', '[]');
  v_de := coalesce(_dt_tela(p_varredura->>'recebido_de'), nullif(p_varredura->>'recebido_de','')::date);
  v_ate := coalesce(_dt_tela(p_varredura->>'recebido_ate'), nullif(p_varredura->>'recebido_ate','')::date);
  if (select count(distinct x->>'post_id') from jsonb_array_elements(p_intimacoes) x) <> v_n then
    raise exception 'Intimação repetida na varredura';
  end if;
  insert into advbox_varreduras (pagina, filtro, recebido_de, recebido_ate, total_informado, total_lido, completa, erros, realizada_por)
  values (coalesce(p_varredura->>'pagina','?'), coalesce(p_varredura->'filtro','{}'), v_de, v_ate, v_inf, v_n,
          v_inf is not null and v_inf = v_n and jsonb_array_length(v_erros) = 0 and v_de is not null and v_ate is not null,
          v_erros, auth.uid())
  returning id into v_id;

  for i in select * from jsonb_array_elements(p_intimacoes) loop
    if (i->>'post_id') !~ '^\d{1,15}$' then raise exception 'post_id inválido: %', i->>'post_id'; end if;
    v_cnj := normalizar_cnj(i->>'cnj');
    if exists (select 1 from advbox_intimacoes where post_id = i->>'post_id') then v_ja := v_ja + 1; else v_novas := v_novas + 1; end if;
    insert into advbox_intimacoes (post_id, cnj, cnj_original, data_publicacao, tribunal, orgao, capturada_em, lawsuit_id, partes,
                                   nome_pesquisado, teor, teor_hash, url_inteiro_teor, situacao_advbox, primeira_varredura,
                                   ultima_varredura, conteudo_original, ultima_leitura)
    values (i->>'post_id', v_cnj, nullif(i->>'cnj',''), _dt_tela(i->>'data_publicacao'), nullif(i->>'tribunal',''), nullif(i->>'orgao',''),
            nullif(i->>'capturada_em','')::timestamptz, nullif(i->>'lawsuit_id',''), nullif(i->>'partes',''),
            nullif(i->>'nome_pesquisado',''), nullif(i->>'teor',''), case when nullif(i->>'teor','') is not null then md5(normalizar_teor(i->>'teor')) end,
            nullif(i->>'url_inteiro_teor',''), nullif(i->>'situacao',''), v_id, v_id, i, i)
    on conflict (post_id) do update set
      ultima_varredura = excluded.ultima_varredura, ultima_leitura = excluded.ultima_leitura,
      situacao_advbox = excluded.situacao_advbox, lawsuit_id = coalesce(excluded.lawsuit_id, advbox_intimacoes.lawsuit_id),
      tribunal = coalesce(advbox_intimacoes.tribunal, excluded.tribunal), orgao = coalesce(advbox_intimacoes.orgao, excluded.orgao),
      partes = coalesce(excluded.partes, advbox_intimacoes.partes), nome_pesquisado = coalesce(advbox_intimacoes.nome_pesquisado, excluded.nome_pesquisado),
      url_inteiro_teor = coalesce(advbox_intimacoes.url_inteiro_teor, excluded.url_inteiro_teor),
      teor = excluded.teor, teor_hash = excluded.teor_hash, cnj = excluded.cnj, cnj_original = excluded.cnj_original,
      data_publicacao = excluded.data_publicacao, capturada_em = excluded.capturada_em;
    insert into advbox_intimacoes_vistas values (v_id, i->>'post_id');
  end loop;

  if jsonb_array_length(v_erros) > 0 then
    perform registrar_log_integracao('advbox_extensao', 'erro', 'ext_registrar_varredura',
      'Varredura do ADVBOX com intimações que não puderam ser lidas: não serve para concluir ausência.',
      jsonb_build_object('varredura_id', v_id, 'erros', v_erros));
  end if;
  return jsonb_build_object('varredura_id', v_id, 'completa', (select completa from advbox_varreduras where id = v_id),
                            'lidas', v_n, 'informadas', v_inf, 'novas', v_novas, 'ja_vistas', v_ja);
end $$;

-- ---------------------------------------------------------------- comparação
-- Comparação (uma execução = um período de DISPONIBILIZAÇÃO).
-- 1. Grupo = mesmo CNJ + mesma data de publicação (sem data de publicação na Webjur: intimações
--    capturadas no dia da disponibilização). No grupo entram as publicações da Webjur e as intimações do ADVBOX.
-- 2. Para cada par (publicação, intimação) do grupo:
--      sobreposição = palavras em comum ÷ palavras do texto menor;
--      jaccard      = palavras em comum ÷ palavras dos dois;
--      distintiva   = sobreposição só das palavras que NÃO são comuns a todos os textos da mesma fonte
--                     no grupo (calculada quando uma fonte tem 2+ textos no grupo): tira o cabeçalho de
--                     partes e advogados, que se repete em atos diferentes do mesmo processo.
-- 3. Par aceito quando: sobreposição >= limiar alto, jaccard >= mínimo, distintiva >= 0.6 (se calculada)
--    e a melhor intimação da publicação supera a segunda por pelo menos a margem.
-- 4. Ligação um-para-um, dos pares mais fortes para os mais fracos (nem a publicação nem a intimação
--    são usadas duas vezes, nem as já ligadas em conferências anteriores).
-- 5. Resultado: ligada com processo → encontrada_advbox; ligada sem processo ("N/A") → processo_nao_cadastrado;
--    sem ligação mas com intimação livre semelhante (>= limiar baixo) → inconclusiva;
--    sem candidata e com varredura COMPLETA cobrindo [disponibilização, +folga] → nao_encontrada_advbox;
--    senão → aguardando (nada é gravado: falta de leitura não é ausência).
-- Rodar de novo não duplica: só grava quando a situação muda; conferência manual nunca é desfeita.
create or replace function public.double_check_executar(p_inicio date, p_fim date)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_alto numeric := coalesce((select (valor #>> '{}')::numeric from parametros where chave = 'double_check_limiar_alto'), 0.85);
        v_baixo numeric := coalesce((select (valor #>> '{}')::numeric from parametros where chave = 'double_check_limiar_baixo'), 0.3);
        v_folga int := coalesce((select (valor #>> '{}')::int from parametros where chave = 'double_check_folga_dias'), 1);
        v_jac_min numeric := coalesce((select (valor #>> '{}')::numeric from parametros where chave = 'double_check_jaccard_min'), 0.75);
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
    select case when cardinality(dp) = 0 or cardinality(da) = 0 then 0
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
  update dc_par set aceito = ov >= v_alto and jac >= v_jac_min and (dist is null or dist >= 0.6)
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

-- Conferência manual a partir do painel (correspondência escolhida ou ausência confirmada)
create or replace function public.double_check_manual(p_publicacao bigint, p_situacao text, p_post_id text, p_nota text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare a record;
begin
  if not is_admin() then raise exception 'Somente a controladoria registra conferências' using errcode = '42501'; end if;
  if p_situacao not in ('encontrada_advbox','nao_encontrada_advbox','processo_nao_cadastrado','conferencia_manual') then
    raise exception 'Situação inválida para conferência manual: %', p_situacao;
  end if;
  if length(btrim(coalesce(p_nota,''))) < 10 then raise exception 'Descreva a conferência (mínimo 10 caracteres)'; end if;
  if p_situacao = 'encontrada_advbox' then
    select * into a from advbox_intimacoes where post_id = p_post_id;
    if not found then raise exception 'Intimação % não está nas varreduras do ADVBOX', p_post_id; end if;
    if exists (select 1 from conferencias_publicacao x where x.evidencia->>'publicacao_advbox' = p_post_id and x.publicacao_id <> p_publicacao) then
      raise exception 'A intimação % já foi ligada a outra publicação', p_post_id;
    end if;
  end if;
  return pub_registrar_conferencia(p_publicacao, p_situacao, case when p_post_id is not null then 'intimacoes' else 'nenhuma' end,
           jsonb_build_object('nota', p_nota) || case when p_post_id is not null then
             jsonb_build_object('publicacao_advbox', p_post_id, 'lawsuit_id', a.lawsuit_id) else '{}'::jsonb end,
           a.lawsuit_id, 'manual');
end $$;

-- ---------------------------------------------------------------- painel
create or replace view public.v_double_check with (security_invoker = true) as
select v.id as publicacao_id, v.cnj, v.data_disponibilizacao, v.data_publicacao, v.tribunal, v.orgao_julgador, left(v.teor, 280) as teor_inicio,
       v.situacao_conferencia, v.conferida_em, v.evidencia_conferencia, v.tarefa_analise_id, v.tarefa_analise_status,
       a.post_id as advbox_post_id, a.lawsuit_id as advbox_lawsuit_id, a.data_publicacao as advbox_data_publicacao,
       (v.evidencia_conferencia->>'semelhanca')::numeric as semelhanca
  from public.v_publicacoes v
  left join public.advbox_intimacoes a on a.post_id = coalesce(v.evidencia_conferencia->>'publicacao_advbox', v.evidencia_conferencia->>'candidata');

-- Relatório diário por DATA DE DISPONIBILIZAÇÃO (Prompt Mestre §21). O percentual de ausentes
-- usa só as conferidas efetivas (encontradas + ausentes + processo não cadastrado).
-- Devolve UMA lista JSON (não SETOF): o formato da resposta da API fica inequívoco.
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

create or replace function public.double_check_listar(p_inicio date, p_fim date, p_situacao text default null, p_limite int default 500)
returns jsonb language sql stable security invoker set search_path = public as $$
  with base as (
    select d.* from v_double_check d
     where d.data_disponibilizacao between p_inicio and p_fim
       and (p_situacao is null or p_situacao = '' or coalesce(d.situacao_conferencia, 'aguardando') = p_situacao))
  select jsonb_build_object('total', (select count(*) from base),
    'linhas', coalesce((select jsonb_agg(to_jsonb(b) order by b.data_disponibilizacao desc, b.publicacao_id)
                          from (select * from base order by data_disponibilizacao desc, publicacao_id
                                limit least(greatest(coalesce(p_limite, 500), 1), 500)) b), '[]'),
    'varreduras', coalesce((select jsonb_agg(to_jsonb(r) order by r.id desc) from
                  (select id, realizada_em, recebido_de, recebido_ate, total_informado, total_lido, completa, jsonb_array_length(erros) as erros
                     from advbox_varreduras order by id desc limit 10) r), '[]'));
$$;

create or replace function public.double_check_candidatas(p_publicacao bigint)
returns jsonb language sql stable security invoker set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('post_id', a.post_id, 'data_publicacao', a.data_publicacao, 'lawsuit_id', a.lawsuit_id,
           'tribunal', a.tribunal, 'orgao', a.orgao, 'capturada_em', a.capturada_em, 'teor', a.teor,
           'semelhanca', teor_semelhanca(p.teor, a.teor)) order by teor_semelhanca(p.teor, a.teor) desc), '[]')
    from publicacoes p join advbox_intimacoes a on a.cnj = p.cnj
   where p.id = p_publicacao;
$$;

-- ---------------------------------------------------------------- segurança
alter table public.advbox_varreduras enable row level security;
alter table public.advbox_intimacoes enable row level security;
alter table public.advbox_intimacoes_vistas enable row level security;
revoke all on public.advbox_varreduras, public.advbox_intimacoes, public.advbox_intimacoes_vistas from anon, authenticated;
grant select on public.advbox_varreduras, public.advbox_intimacoes, public.advbox_intimacoes_vistas to authenticated;
create policy varreduras_admin on public.advbox_varreduras for select to authenticated using (public.is_admin());
create policy intimacoes_admin on public.advbox_intimacoes for select to authenticated using (public.is_admin());
create policy intimacoes_vistas_admin on public.advbox_intimacoes_vistas for select to authenticated using (public.is_admin());
grant select on public.v_double_check to authenticated;
revoke all on public.v_double_check from anon;

revoke execute on function public.ext_registrar_varredura(jsonb, jsonb), public.double_check_executar(date, date),
                           public.double_check_manual(bigint, text, text, text), public.double_check_diario(date, date),
                           public.double_check_listar(date, date, text, int), public.double_check_candidatas(bigint) from public, anon;
grant execute on function public.ext_registrar_varredura(jsonb, jsonb), public.double_check_executar(date, date),
                          public.double_check_manual(bigint, text, text, text), public.double_check_diario(date, date),
                          public.double_check_listar(date, date, text, int), public.double_check_candidatas(bigint) to authenticated;
