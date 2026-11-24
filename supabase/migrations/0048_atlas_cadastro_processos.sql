-- =====================================================================
-- 0048 — Robô de cadastro de processos no Atlas (pedido da controladoria, 13–14/11/2026)
-- "É necessário que os processos do ADVBOX também estejam no Atlas." A API do Atlas cadastra processo
-- (create_lawsuit, permissão "Gravar Processos", Idempotency-Key obrigatória), sempre ligado a um
-- cliente que já existe no Atlas. Decisões da controladoria (14/11/2026):
--   * cliente não encontrado no Atlas: só listar (o robô NÃO cria cliente);
--   * processos encerrados no ADVBOX também são cadastrados.
-- Fluxo: importar a exportação de processos do ADVBOX -> ler os clientes do Atlas -> casar cliente
-- (CPF/CNPJ, código do cliente "C362", nome) -> prévia -> a controladoria aprova -> a Edge Function
-- atlas-cadastro cadastra em lotes (confere antes no Atlas se o número já existe; não duplica).
-- Também: as cinco equipes do escritório (Prime, Gold, Celeste, Delta, Êxitos), informadas em 14/11/2026.
-- =====================================================================

insert into public.parametros (chave, valor, confirmado, descricao) values
 ('atlas_cadastro_lote', '15', true,
  'Robô de cadastro de processos no Atlas: quantos processos aprovados cada execução cadastra (2 chamadas ao Atlas por processo; o limite do Atlas é 60 por minuto).'),
 ('atlas_cadastro_url', '"https://impoejdocxuihficjvxm.supabase.co/functions/v1/atlas-cadastro"', true,
  'Endereço da Edge Function atlas-cadastro, chamada pelo agendamento enquanto houver processos aprovados.')
on conflict (chave) do nothing;

-- equipes do escritório (as mesmas "squads" do Atlas)
do $$ begin
  perform set_config('controladoria.motivo', 'Equipes do escritório informadas pela controladoria em 14/11/2026', true);
  insert into public.equipes (nome) values ('Prime'), ('Gold'), ('Celeste'), ('Delta'), ('Êxitos') on conflict (nome) do nothing;
end $$;

-- ---------------------------------------------------------------- clientes do Atlas (cópia para casar o cliente)
create table if not exists public.atlas_clientes (
  id              uuid primary key,
  nome            text not null,
  doc             text,                 -- só dígitos
  codigo          text,                 -- "C362" do início do nome
  nome_norm       text,
  status          text,
  sincronizado_em timestamptz not null default now()
);
create index if not exists atlas_clientes_doc_idx on public.atlas_clientes (doc);
create index if not exists atlas_clientes_codigo_idx on public.atlas_clientes (codigo);
create index if not exists atlas_clientes_nome_idx on public.atlas_clientes (nome_norm);
alter table public.atlas_clientes enable row level security;
revoke all on public.atlas_clientes from anon, authenticated;

-- ---------------------------------------------------------------- fila de cadastro
create table if not exists public.atlas_cadastro (
  cnj               text primary key,                  -- normalizado
  origem            text not null default 'advbox' check (origem in ('advbox','carteira')),
  cliente_advbox    text,
  docs              text[] not null default '{}',
  codigos           text[] not null default '{}',
  parte_contraria   text,
  grupo_acao        text,
  tipo_advbox       text,
  fase              text,
  etapa             text,
  tribunal          text,
  comarca           text,
  vara              text,
  processo_originario text,
  valor_causa       numeric(14,2),
  data_requerimento date,
  data_fechamento   date,
  resultado         text,
  responsavel_advbox text,
  linhas_planilha   int not null default 1,
  atlas_client_id   uuid,
  atlas_cliente_nome text,
  casado_por        text,
  tipo_atlas        text,
  autores           text,
  reus              text,
  notas             text,
  situacao          text not null default 'previa' check (situacao in
                      ('no_atlas','sem_cliente','revisar','previa','aprovado','enviando','cadastrado','erro')),
  motivo            text,
  atlas_lawsuit_id  text,
  tentativas        int not null default 0,
  ultimo_erro       text,
  aprovado_em       timestamptz,
  aprovado_por      uuid,
  importado_em      timestamptz not null default now(),
  atualizado_em     timestamptz not null default now(),
  cadastrado_em     timestamptz
);
create index if not exists atlas_cadastro_situacao_idx on public.atlas_cadastro (situacao);
alter table public.atlas_cadastro enable row level security;
revoke all on public.atlas_cadastro from anon, authenticated;
grant select on public.atlas_cadastro to authenticated;
drop policy if exists atlas_cadastro_leitura on public.atlas_cadastro;
create policy atlas_cadastro_leitura on public.atlas_cadastro for select to authenticated using (public.pode_ler_tudo());

-- histórico imutável: importações, aprovações, cadastros e erros
create table if not exists public.atlas_cadastro_eventos (
  id        bigint generated always as identity primary key,
  em        timestamptz not null default now(),
  usuario   uuid default auth.uid(),
  tipo      text not null check (tipo in ('importacao','clientes','preparacao','aprovacao','cadastro','ja_existia','erro','execucao')),
  cnj       text,
  detalhe   jsonb not null default '{}'
);
create index if not exists atlas_cadastro_eventos_idx on public.atlas_cadastro_eventos (cnj, em desc);
alter table public.atlas_cadastro_eventos enable row level security;
revoke all on public.atlas_cadastro_eventos from anon, authenticated;
grant select on public.atlas_cadastro_eventos to authenticated;
drop policy if exists atlas_cadastro_eventos_leitura on public.atlas_cadastro_eventos;
create policy atlas_cadastro_eventos_leitura on public.atlas_cadastro_eventos for select to authenticated using (public.pode_ler_tudo());
drop trigger if exists atlas_cadastro_eventos_imutavel on public.atlas_cadastro_eventos;
create trigger atlas_cadastro_eventos_imutavel before update or delete on public.atlas_cadastro_eventos
  for each row execute function public.tg_bloqueia_alteracao();

-- ---------------------------------------------------------------- auxiliares (internas)
-- nome sem acento, maiúsculo, sem documento entre parênteses, sem código do cliente e sem sufixos " - PJ"/" - PF"
create or replace function public._nome_cliente_norm(p text) returns text language sql immutable as $$
  select nullif(btrim(regexp_replace(regexp_replace(regexp_replace(regexp_replace(
    upper(translate(coalesce(p, ''), 'áàâãäéèêëíìîïóòôõöúùûüçÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇ', 'aaaaaeeeeiiiiooooouuuucAAAAAEEEEIIIIOOOOOUUUUC')),
    '\(?\d{2,3}\.?\d{3}\.?\d{3}[/-]?\d{0,4}-?\d{2}\)?', ' ', 'g'),          -- CPF/CNPJ
    '^\s*(RC\d\s*-?\s*)?[A-Z]{0,2}\d{2,4}\s*-\s*', ''),                    -- "RC3 - E091 - ", "C362 - "
    '\s+-\s+P[JF](\s+E\s+P[JF])?\s*$', ''),                                -- " - PJ", " - PJ e PF"
    '[^A-Z0-9]+', ' ', 'g')), '')
$$;

-- código do cliente no início do nome ("C362", "P662", "E091"); o "RCn" de recuperação de crédito é ignorado
create or replace function public._codigo_cliente(p text) returns text language sql immutable as $$
  select (regexp_match(upper(btrim(coalesce(p, ''))), '^(?:RC\d\s*-?\s*)?([A-Z]\d{2,4})\s*-'))[1]
$$;

-- documentos (CPF com 11 e CNPJ com 14 dígitos) citados no texto
create or replace function public._docs_do_texto(p text) returns text[] language sql immutable as $$
  select coalesce(array_agg(distinct d), '{}') from (
    select regexp_replace(m[1], '\D', '', 'g') d
      from regexp_matches(coalesce(p, ''), '(\d{2}\.\d{3}\.\d{3}/\d{4}-\d{2}|\d{3}\.\d{3}\.\d{3}-\d{2}|\m\d{14}\M|\m\d{11}\M)', 'g') m) x
   where length(d) in (11, 14)
$$;

create or replace function public._data_br(p text) returns date language sql immutable as $$
  select case when p ~ '^\s*\d{2}/\d{2}/\d{4}' then to_date(substr(btrim(p), 1, 10), 'DD/MM/YYYY')
              when p ~ '^\s*\d{4}-\d{2}-\d{2}' then substr(btrim(p), 1, 10)::date end
$$;

-- "R$80.057,66" -> 80057.66
create or replace function public._valor_br(p text) returns numeric language sql immutable as $$
  select case when v ~ '^\d+(,\d{1,2})?$' then replace(v, ',', '.')::numeric
              when v ~ '^\d+(\.\d{1,2})?$' then v::numeric end
    from (select case when s like '%,%' or s ~ '^\d{1,3}(\.\d{3})+$' then replace(s, '.', '') else s end v
            from (select regexp_replace(coalesce(p, ''), '[^0-9,.]', '', 'g') s) y) x
$$;

-- tipo de ação do ADVBOX -> tipo de processo do Atlas (lista fechada da tela; o que não casa vira "Outros")
create or replace function public._tipo_atlas(p text) returns text language sql immutable as $$
  select case
    when t ~ 'REVISIONAL|LIMITACAO DE 30' then 'Revisional de Contrato'
    when t ~ 'EMBARGOS A EXECUCAO|EMBARGOS DO DEVEDOR' then 'Embargos à Execução'
    when t ~ 'EXECUCAO FISCAL' then 'Execução Fiscal'
    when t ~ 'EXECUCAO DE TITULO|EXECUCAO EXTRAJUDICIAL' then 'Execução de Título Extrajudicial'
    when t ~ 'CUMPRIMENTO DE SENTENCA' then 'Cumprimento de Sentença'
    when t ~ 'MONITORIA' then 'Ação Monitória'
    when t ~ 'BUSCA E APREENSAO' then 'Busca e Apreensão (Veículos)'
    when t ~ 'ACAO DE COBRANCA' then 'Ação de Cobrança'
    when t ~ 'EXIBICAO DE DOCUMENTOS' then 'Exibição de Documentos'
    when t ~ 'FALENCIA|RECUPERACAO JUDICIAL' then 'Falência / Recuperação Judicial'
    when t ~ 'PROCEDIMENTO COMUM|PROCEDIMENTO ORDINARIO|ACAO DE CONHECIMENTO|OBRIGACAO DE FAZER' then 'Procedimento Comum Cível'
    else 'Outros' end
  from (select upper(translate(coalesce(p, ''), 'áàâãéêíóôõúçÁÀÂÃÉÊÍÓÔÕÚÇ', 'aaaaeeiooouc' || 'AAAAEEIOOOUC')) t) x
$$;

-- polo do cliente pelo tipo de ação (carteira bancária): true = cliente é réu; false = autor; null = não dá para afirmar
create or replace function public._cliente_reu(p text) returns boolean language sql immutable as $$
  select case
    when t ~ 'EXECUCAO DE TITULO|EXECUCAO FISCAL|MONITORIA|BUSCA E APREENSAO|ACAO DE COBRANCA' then true
    when t ~ 'REVISIONAL|LIMITACAO DE 30|EMBARGOS A EXECUCAO|EMBARGOS DE TERCEIRO|SUPERENDIVIDAMENTO|EXIBICAO DE DOCUMENTOS|ANULA|REESTRUTURACAO|OBRIGACAO DE FAZER|INDENIZACAO|DANO MORAL' then false
    end
  from (select upper(translate(coalesce(p, ''), 'áàâãéêíóôõúçÁÀÂÃÉÊÍÓÔÕÚÇ', 'aaaaeeiooouc' || 'AAAAEEIOOOUC')) t) x
$$;

revoke execute on function public._nome_cliente_norm(text), public._codigo_cliente(text), public._docs_do_texto(text),
  public._data_br(text), public._valor_br(text), public._tipo_atlas(text), public._cliente_reu(text) from public, anon, authenticated;

-- ---------------------------------------------------------------- casar cliente e montar o cadastro (interna)
create or replace function public._atlas_cadastro_preparar(p_cnjs text[] default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_hoje text := to_char(hoje_brasilia(), 'DD/MM/YYYY'); v_n int;
begin
  -- já está no Atlas (carteira lida pela API todo dia, ou cliente/processo devolvidos pelo próprio cadastro)
  update atlas_cadastro a set situacao = 'no_atlas', motivo = 'Processo já cadastrado no Atlas', atualizado_em = now(),
         atlas_lawsuit_id = coalesce(a.atlas_lawsuit_id, k.atlas_lawsuit_id)
    from cnj_carteira k
   where k.cnj = a.cnj and 'atlas' = any(k.origens) and a.situacao in ('sem_cliente','revisar','previa','erro')
     and (p_cnjs is null or a.cnj = any(p_cnjs));

  with alvo as (
    select a.*, coalesce((select array_agg(n) from unnest(string_to_array(a.cliente_advbox, ';')) x
                                  cross join lateral (select _nome_cliente_norm(x) n) z where n is not null), '{}') nomes
      from atlas_cadastro a
     where a.situacao in ('sem_cliente','revisar','previa') and (p_cnjs is null or a.cnj = any(p_cnjs))
       and coalesce(a.casado_por, '') <> 'escolha da controladoria'),
  pares as (  -- clientes do Atlas que casam por documento, código ou nome (três buscas pelos índices)
    select a.cnj, c.id, c.nome, 'doc' por from alvo a join atlas_clientes c on c.doc = any(a.docs)
    union all
    select a.cnj, c.id, c.nome, 'codigo' from alvo a join atlas_clientes c on c.codigo = any(a.codigos)
    union all
    select a.cnj, c.id, c.nome, 'nome' from alvo a join atlas_clientes c on c.nome_norm = any(a.nomes)),
  cand as (
    select cnj, id, nome, bool_or(por = 'doc') por_doc, bool_or(por = 'codigo') por_codigo, bool_or(por = 'nome') por_nome
      from pares group by cnj, id, nome),
  forte as (  -- quando há mais de um, fica o que casa por mais critérios (documento vale mais)
    select cnj, id, nome, por_doc, por_codigo, por_nome,
           (por_doc::int * 4 + por_codigo::int * 2 + por_nome::int) pontos,
           max(por_doc::int * 4 + por_codigo::int * 2 + por_nome::int) over (partition by cnj) melhor
      from cand),
  escolha as (
    select cnj, count(*) n, min(id::text)::uuid id, min(nome) nome, string_agg(nome, ' | ' order by nome) nomes,
           bool_or(por_doc) por_doc, bool_or(por_codigo) por_codigo, bool_or(por_nome) por_nome
      from forte where pontos = melhor group by cnj)
  update atlas_cadastro a set
     atlas_client_id = case when e.n = 1 then e.id end,
     atlas_cliente_nome = case when e.n = 1 then e.nome end,
     casado_por = case when e.n = 1 then concat_ws(', ', case when e.por_doc then 'CPF/CNPJ' end,
                                                         case when e.por_codigo then 'código do cliente' end,
                                                         case when e.por_nome then 'nome' end) end,
     situacao = case when a.origem = 'carteira' and e.cnj is null then 'sem_cliente'
                     when e.cnj is null then 'sem_cliente'
                     when e.n > 1 then 'revisar'
                     else 'previa' end,
     motivo = case when e.cnj is null and a.origem = 'carteira'
                     then 'Processo fora da exportação do ADVBOX (veio da Webjur/CNJ): cliente desconhecido'
                   when e.cnj is null then 'Cliente não encontrado no Atlas (CPF/CNPJ, código e nome)'
                   when e.n > 1 then 'Mais de um cliente do Atlas possível: ' || left(e.nomes, 300)
                   when not e.por_doc and not e.por_codigo then 'Cliente casado só pelo nome: confira'
                   end,
     tipo_atlas = _tipo_atlas(a.tipo_advbox),
     autores = case _cliente_reu(a.tipo_advbox) when false then left(replace(a.cliente_advbox, ';', '; '), 1000)
                                                 when true then left(a.parte_contraria, 1000) end,
     reus    = case _cliente_reu(a.tipo_advbox) when true then left(replace(a.cliente_advbox, ';', '; '), 1000)
                                                 when false then left(a.parte_contraria, 1000) end,
     notas = left(concat_ws(E'\n',
       'Cadastrado pela controladoria a partir do ADVBOX em ' || v_hoje || '.',
       case when a.origem = 'carteira' then 'Origem: processo capturado pela Webjur/CNJ, fora da exportação do ADVBOX.' end,
       'Tipo no ADVBOX: ' || nullif(concat_ws(' / ', a.grupo_acao, a.tipo_advbox), ''),
       'Fase/etapa no ADVBOX: ' || nullif(concat_ws(' / ', a.fase, a.etapa), ''),
       'Juízo: ' || nullif(concat_ws(' / ', a.tribunal, a.comarca, a.vara), ''),
       case when _cliente_reu(a.tipo_advbox) is null then
         'Partes (polo não informado no ADVBOX): cliente ' || coalesce(replace(a.cliente_advbox, ';', '; '), '—')
         || '; parte contrária ' || coalesce(a.parte_contraria, '—') end,
       'Processo originário: ' || a.processo_originario,
       'Responsável no ADVBOX: ' || a.responsavel_advbox,
       'Encerrado no ADVBOX em ' || to_char(a.data_fechamento, 'DD/MM/YYYY')
         || coalesce(' (' || a.resultado || ')', '') || '.'), 2000),
     atualizado_em = now()
    from alvo t left join escolha e on e.cnj = t.cnj
   where a.cnj = t.cnj;
  get diagnostics v_n = row_count;
  return jsonb_build_object('preparados', v_n);
end $$;
revoke execute on function public._atlas_cadastro_preparar(text[]) from public, anon, authenticated;

-- ---------------------------------------------------------------- importação da exportação de processos do ADVBOX
-- p_linhas: linhas da planilha, como lidas no painel ({"Nome do cliente": ..., "Número do processo": ...}).
-- Linha sem número CNJ válido (assessoria, negociação) não é processo judicial e fica de fora.
create or replace function public.atlas_cadastro_importar(p_linhas jsonb, p_arquivo text default null, p_final boolean default true)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_lidas int; v_validas int; v_novos int; v_atualizados int; v_carteira int := 0; r jsonb;
begin
  if not is_admin() then raise exception 'Somente a controladoria' using errcode = '42501'; end if;
  if jsonb_typeof(p_linhas) <> 'array' then raise exception 'Lista de linhas inválida'; end if;
  if jsonb_array_length(p_linhas) > 5000 then raise exception 'No máximo 5.000 linhas por envio'; end if;
  if jsonb_array_length(p_linhas) > 0 and not (p_linhas->0 ? 'Número do processo' and p_linhas->0 ? 'Nome do cliente') then
    raise exception 'A planilha não é a exportação de processos do ADVBOX (faltam as colunas "Nome do cliente" e "Número do processo")';
  end if;
  v_lidas := jsonb_array_length(p_linhas);
  with l as (
    select normalizar_cnj(i->>'Número do processo') cnj, i
      from jsonb_array_elements(p_linhas) i),
  v as (select * from l where cnj is not null and cnj_digito_valido(cnj)),
  g as (   -- o ADVBOX pode repetir o processo (uma linha por parte): junta as linhas
    select cnj, count(*) n,
           string_agg(distinct nullif(btrim(i->>'Nome do cliente'), ''), ';') cliente,
           string_agg(distinct nullif(btrim(i->>'Parte contrária'), ''), '; ') parte,
           max(nullif(btrim(i->>'Grupo de ação'), '')) grupo, max(nullif(btrim(i->>'Tipo de ação'), '')) tipo,
           max(nullif(btrim(i->>'Fase judicial'), '')) fase, max(nullif(btrim(i->>'Etapa'), '')) etapa,
           max(nullif(btrim(i->>'Tribunal'), '')) tribunal, max(nullif(btrim(i->>'Comarca'), '')) comarca,
           max(nullif(btrim(i->>'Vara'), '')) vara, max(normalizar_cnj(i->>'Processo originário')) originario,
           max(_valor_br(i->>'Expectiva/Valor da causa (R$)')) valor, min(_data_br(i->>'Data do requerimento')) requerimento,
           max(_data_br(i->>'Data do fechamento')) fechamento, max(nullif(btrim(i->>'Resultado do processo'), '')) resultado,
           max(nullif(btrim(i->>'Responsável'), '')) responsavel
      from v group by cnj),
  up as (
    insert into atlas_cadastro as a (cnj, origem, cliente_advbox, docs, codigos, parte_contraria, grupo_acao, tipo_advbox, fase, etapa,
           tribunal, comarca, vara, processo_originario, valor_causa, data_requerimento, data_fechamento, resultado, responsavel_advbox,
           linhas_planilha, situacao)
    select cnj, 'advbox', cliente, _docs_do_texto(cliente),
           coalesce((select array_agg(distinct c) from unnest(string_to_array(cliente, ';')) x cross join lateral (select _codigo_cliente(x) c) z where c is not null), '{}'),
           parte, grupo, tipo, fase, etapa, tribunal, comarca, vara, originario, valor, requerimento, fechamento, resultado, responsavel, n, 'previa'
      from g
    on conflict (cnj) do update set
      origem = 'advbox', cliente_advbox = excluded.cliente_advbox, docs = excluded.docs, codigos = excluded.codigos,
      parte_contraria = excluded.parte_contraria, grupo_acao = excluded.grupo_acao, tipo_advbox = excluded.tipo_advbox,
      fase = excluded.fase, etapa = excluded.etapa, tribunal = excluded.tribunal, comarca = excluded.comarca, vara = excluded.vara,
      processo_originario = excluded.processo_originario, valor_causa = excluded.valor_causa,
      data_requerimento = excluded.data_requerimento, data_fechamento = excluded.data_fechamento, resultado = excluded.resultado,
      responsavel_advbox = excluded.responsavel_advbox, linhas_planilha = excluded.linhas_planilha,
      -- o que já foi aprovado, enviado ou cadastrado não volta para a prévia
      situacao = case when a.situacao in ('aprovado','enviando','cadastrado') then a.situacao else 'previa' end,
      importado_em = now(), atualizado_em = now()
    returning (xmax = 0) novo)
  select count(*) filter (where novo), count(*) filter (where not novo) into v_novos, v_atualizados from up;
  select count(*) into v_validas from jsonb_array_elements(p_linhas) i where normalizar_cnj(i->>'Número do processo') is not null
     and cnj_digito_valido(normalizar_cnj(i->>'Número do processo'));

  if p_final then
    -- processos que o sistema conhece (Webjur/CNJ) fora do Atlas e fora da planilha: entram na lista "sem cliente"
    with c as (
      insert into atlas_cadastro (cnj, origem, situacao, motivo)
      select k.cnj, 'carteira', 'sem_cliente', 'Processo fora da exportação do ADVBOX (veio da Webjur/CNJ): cliente desconhecido'
        from cnj_carteira k
       where k.ativo and not ('atlas' = any(k.origens))
      on conflict (cnj) do nothing
      returning 1)
    select count(*) into v_carteira from c;
    r := _atlas_cadastro_preparar(null);
  end if;
  insert into atlas_cadastro_eventos (tipo, detalhe) values ('importacao', jsonb_build_object('arquivo', p_arquivo, 'linhas', v_lidas,
     'linhas_com_processo', v_validas, 'processos_novos', v_novos, 'processos_atualizados', v_atualizados, 'da_carteira', v_carteira));
  return jsonb_build_object('linhas', v_lidas, 'linhas_com_processo', v_validas, 'novos', v_novos, 'atualizados', v_atualizados,
                            'da_carteira', v_carteira);
end $$;

-- ---------------------------------------------------------------- clientes do Atlas (gravados pela Edge Function)
create or replace function public.atlas_clientes_registrar(p_itens jsonb, p_completo boolean default true) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_n int; v_rem int := 0;
begin
  if not is_admin() then raise exception 'Somente a controladoria' using errcode = '42501'; end if;
  if jsonb_typeof(p_itens) <> 'array' then raise exception 'Lista inválida'; end if;
  insert into atlas_clientes (id, nome, doc, codigo, nome_norm, status, sincronizado_em)
  select (i->>'id')::uuid, coalesce(i->>'name', ''), nullif(regexp_replace(coalesce(i->>'doc_id', i->>'docId', ''), '\D', '', 'g'), ''),
         _codigo_cliente(i->>'name'), _nome_cliente_norm(i->>'name'), i->>'status', now()
    from jsonb_array_elements(p_itens) i where i->>'id' ~ '^[0-9a-fA-F-]{36}$'
  on conflict (id) do update set nome = excluded.nome, doc = excluded.doc, codigo = excluded.codigo, nome_norm = excluded.nome_norm,
     status = excluded.status, sincronizado_em = now();
  get diagnostics v_n = row_count;
  if p_completo then   -- leitura completa: quem não veio saiu do Atlas (lixeira)
    delete from atlas_clientes where sincronizado_em < now() - interval '1 minute';
    get diagnostics v_rem = row_count;
    perform _atlas_cadastro_preparar(null);
  end if;
  insert into atlas_cadastro_eventos (tipo, detalhe) values ('clientes', jsonb_build_object('recebidos', v_n, 'removidos', v_rem,
     'total', (select count(*) from atlas_clientes), 'com_documento', (select count(*) from atlas_clientes where doc is not null)));
  return jsonb_build_object('recebidos', v_n, 'removidos', v_rem, 'total', (select count(*) from atlas_clientes));
end $$;

-- ---------------------------------------------------------------- aprovação (prévia -> fila)
create or replace function public.atlas_cadastro_aprovar(p_cnjs text[] default null, p_todos boolean default false) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_n int;
begin
  if not is_admin() then raise exception 'Somente a controladoria' using errcode = '42501'; end if;
  if not coalesce(p_todos, false) and coalesce(cardinality(p_cnjs), 0) = 0 then raise exception 'Escolha os processos ou "aprovar todos"'; end if;
  with u as (
    update atlas_cadastro set situacao = 'aprovado', aprovado_em = now(), aprovado_por = auth.uid(), motivo = null,
           ultimo_erro = case when situacao = 'erro' then ultimo_erro end, atualizado_em = now()
     where situacao in ('previa','erro') and atlas_client_id is not null
       and (coalesce(p_todos, false) or cnj = any(select normalizar_cnj(x) from unnest(p_cnjs) x))
    returning cnj)
  select count(*) into v_n from u;
  insert into atlas_cadastro_eventos (tipo, detalhe) values ('aprovacao', jsonb_build_object('aprovados', v_n, 'todos', coalesce(p_todos, false),
     'escolhidos', coalesce(cardinality(p_cnjs), 0)));
  return jsonb_build_object('aprovados', v_n, 'na_fila', (select count(*) from atlas_cadastro where situacao = 'aprovado'));
end $$;

-- cliente escolhido pela controladoria (vários clientes possíveis, ou casado só pelo nome)
create or replace function public.atlas_cadastro_definir_cliente(p_cnj text, p_client_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_cnj text := normalizar_cnj(p_cnj); v_nome text;
begin
  if not is_admin() then raise exception 'Somente a controladoria' using errcode = '42501'; end if;
  select nome into v_nome from atlas_clientes where id = p_client_id;
  if v_nome is null then raise exception 'Cliente não encontrado entre os clientes lidos do Atlas'; end if;
  update atlas_cadastro set atlas_client_id = p_client_id, atlas_cliente_nome = v_nome, casado_por = 'escolha da controladoria',
         situacao = 'previa', motivo = null, atualizado_em = now()
   where cnj = v_cnj and situacao in ('sem_cliente','revisar','previa','erro');
  if not found then raise exception 'Processo não encontrado ou já enviado ao Atlas'; end if;
  insert into atlas_cadastro_eventos (tipo, cnj, detalhe) values ('preparacao', v_cnj, jsonb_build_object('cliente_escolhido', p_client_id, 'nome', v_nome));
  return jsonb_build_object('cnj', v_cnj, 'cliente', v_nome);
end $$;

-- clientes do Atlas para a escolha manual (busca por nome, código ou documento)
create or replace function public.atlas_clientes_buscar(p_busca text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare b text := btrim(coalesce(p_busca, ''));
begin
  if not is_admin() then raise exception 'Somente a controladoria' using errcode = '42501'; end if;
  if length(b) < 3 then return '[]'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'nome', nome, 'doc', doc) order by nome), '[]') from (
    select * from atlas_clientes
     where nome ilike '%' || b || '%' or doc = regexp_replace(b, '\D', '', 'g') or codigo = upper(b)
     order by nome limit 20) c);
end $$;

-- volta da fila para a prévia (antes de ser enviado)
create or replace function public.atlas_cadastro_suspender(p_cnjs text[] default null, p_todos boolean default false) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_n int;
begin
  if not is_admin() then raise exception 'Somente a controladoria' using errcode = '42501'; end if;
  update atlas_cadastro set situacao = 'previa', aprovado_em = null, aprovado_por = null, atualizado_em = now()
   where situacao = 'aprovado' and (coalesce(p_todos, false) or cnj = any(select normalizar_cnj(x) from unnest(p_cnjs) x));
  get diagnostics v_n = row_count;
  insert into atlas_cadastro_eventos (tipo, detalhe) values ('aprovacao', jsonb_build_object('suspensos', v_n));
  return jsonb_build_object('suspensos', v_n);
end $$;

-- ---------------------------------------------------------------- Edge Function: próximos da fila e resultado
create or replace function public.atlas_cadastro_proximos(p_limite int default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r jsonb;
begin
  if not is_admin() then raise exception 'Somente a controladoria' using errcode = '42501'; end if;
  -- "enviando" há mais de 10 minutos: a execução caiu no meio; volta para a fila (a Idempotency-Key evita duplicar)
  update atlas_cadastro set situacao = 'aprovado' where situacao = 'enviando' and atualizado_em < now() - interval '10 minutes';
  with p as (
    select cnj from atlas_cadastro where situacao = 'aprovado'
     order by tentativas, aprovado_em, cnj
     limit greatest(1, least(coalesce(p_limite, param_int('atlas_cadastro_lote')), 50))
     for update skip locked),
  u as (
    update atlas_cadastro a set situacao = 'enviando', tentativas = a.tentativas + 1, atualizado_em = now()
      from p where a.cnj = p.cnj
    returning a.*)
  select coalesce(jsonb_agg(jsonb_build_object('cnj', cnj, 'clientId', atlas_client_id, 'type', tipo_atlas, 'causeValue', coalesce(valor_causa, 0),
           'protocolDate', data_requerimento, 'authors', autores, 'defendants', reus, 'notes', notas,
           'tentativa', tentativas, 'idempotencyKey', 'ctrl-cadastro-' || regexp_replace(cnj, '\D', '', 'g') || '-' || left(md5(atlas_client_id::text), 8))), '[]')
    into r from u;
  return r;
end $$;

create or replace function public.atlas_cadastro_resultado(p_cnj text, p_resultado text, p_lawsuit_id text, p_erro text, p_detalhe jsonb default '{}')
returns void language plpgsql security definer set search_path = public as $$
declare v_cnj text := normalizar_cnj(p_cnj);
begin
  if not is_admin() then raise exception 'Somente a controladoria' using errcode = '42501'; end if;
  if p_resultado not in ('cadastrado','ja_existia','erro','tentar_de_novo') then raise exception 'Resultado inválido'; end if;
  update atlas_cadastro set
     situacao = case p_resultado when 'cadastrado' then 'cadastrado' when 'ja_existia' then 'no_atlas'
                                 when 'tentar_de_novo' then case when tentativas >= 3 then 'erro' else 'aprovado' end
                                 else 'erro' end,
     atlas_lawsuit_id = coalesce(p_lawsuit_id, atlas_lawsuit_id),
     cadastrado_em = case when p_resultado = 'cadastrado' then now() else cadastrado_em end,
     motivo = case p_resultado when 'ja_existia' then 'Já existia no Atlas (conferido antes de cadastrar)' else motivo end,
     ultimo_erro = case when p_resultado in ('erro','tentar_de_novo') then left(p_erro, 500) end,
     atualizado_em = now()
   where cnj = v_cnj;
  if p_resultado in ('cadastrado','ja_existia') then   -- entra na carteira do CNJ como processo do Atlas
    insert into cnj_carteira (cnj, origens, atlas_lawsuit_id) values (v_cnj, array['atlas'], p_lawsuit_id)
    on conflict (cnj) do update set origens = (select array_agg(distinct o) from unnest(cnj_carteira.origens || array['atlas']) o),
       atlas_lawsuit_id = coalesce(excluded.atlas_lawsuit_id, cnj_carteira.atlas_lawsuit_id), ativo = true;
  end if;
  insert into atlas_cadastro_eventos (tipo, cnj, detalhe)
  values (case p_resultado when 'cadastrado' then 'cadastro' when 'ja_existia' then 'ja_existia' else 'erro' end, v_cnj,
          coalesce(p_detalhe, '{}') || jsonb_build_object('lawsuit_id', p_lawsuit_id, 'erro', left(p_erro, 500), 'resultado', p_resultado));
end $$;

create or replace function public.atlas_cadastro_execucao(p_detalhe jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Somente a controladoria' using errcode = '42501'; end if;
  insert into atlas_cadastro_eventos (tipo, detalhe) values ('execucao', coalesce(p_detalhe, '{}'));
end $$;

-- ---------------------------------------------------------------- painel
create or replace function public.atlas_cadastro_painel(p_situacao text default null, p_busca text default null, p_limite int default 500)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_busca text := nullif(btrim(coalesce(p_busca, '')), '');
begin
  if not pode_ler_tudo() then raise exception 'Somente a controladoria e a diretoria' using errcode = '42501'; end if;
  return jsonb_build_object(
    'contagem', (select coalesce(jsonb_object_agg(situacao, n), '{}') from (select situacao, count(*) n from atlas_cadastro group by 1) x),
    'clientes_atlas', jsonb_build_object('total', (select count(*) from atlas_clientes),
                                         'com_documento', (select count(*) from atlas_clientes where doc is not null),
                                         'lidos_em', (select max(sincronizado_em) from atlas_clientes)),
    'ultima_importacao', (select to_jsonb(e) - 'usuario' from atlas_cadastro_eventos e where tipo = 'importacao' order by id desc limit 1),
    'ultima_execucao', (select to_jsonb(e) - 'usuario' from atlas_cadastro_eventos e where tipo = 'execucao' order by id desc limit 1),
    'itens', (select coalesce(jsonb_agg(to_jsonb(a) - 'docs' - 'codigos' - 'aprovado_por' order by a.situacao, a.cliente_advbox nulls last, a.cnj), '[]') from (
       select * from atlas_cadastro a
        where (p_situacao is null or a.situacao = p_situacao)
          and (v_busca is null or a.cnj ilike '%' || v_busca || '%' or a.cliente_advbox ilike '%' || v_busca || '%'
               or a.atlas_cliente_nome ilike '%' || v_busca || '%' or a.parte_contraria ilike '%' || v_busca || '%')
        order by a.situacao, a.cliente_advbox nulls last, a.cnj
        limit greatest(coalesce(p_limite, 500), 1)) a));
end $$;

revoke execute on function public.atlas_cadastro_importar(jsonb, text, boolean), public.atlas_clientes_registrar(jsonb, boolean),
  public.atlas_cadastro_aprovar(text[], boolean), public.atlas_cadastro_suspender(text[], boolean), public.atlas_cadastro_proximos(int),
  public.atlas_cadastro_resultado(text, text, text, text, jsonb), public.atlas_cadastro_execucao(jsonb),
  public.atlas_cadastro_painel(text, text, int), public.atlas_cadastro_definir_cliente(text, uuid), public.atlas_clientes_buscar(text) from public, anon;
grant execute on function public.atlas_cadastro_importar(jsonb, text, boolean), public.atlas_clientes_registrar(jsonb, boolean),
  public.atlas_cadastro_aprovar(text[], boolean), public.atlas_cadastro_suspender(text[], boolean), public.atlas_cadastro_proximos(int),
  public.atlas_cadastro_resultado(text, text, text, text, jsonb), public.atlas_cadastro_execucao(jsonb),
  public.atlas_cadastro_painel(text, text, int), public.atlas_cadastro_definir_cliente(text, uuid), public.atlas_clientes_buscar(text) to authenticated;

-- ---------------------------------------------------------------- agendamento (pg_cron + pg_net, mesmo segredo das outras rotinas)
--   a cada 2 minutos: cadastra os aprovados (só chama a função se houver processo aprovado na fila)
--   23:40 (Brasília): relê os clientes do Atlas e refaz o casamento da prévia
do $$
declare v_url text; v_anon text; job record;
begin
  if not exists (select 1 from pg_available_extensions where name = 'pg_cron')
     or not exists (select 1 from pg_available_extensions where name = 'pg_net') then
    raise notice '0048: pg_cron/pg_net indisponíveis neste banco; agendamento não criado.';
    return;
  end if;
  v_url := (select valor #>> '{}' from public.parametros where chave = 'atlas_cadastro_url');
  v_anon := (select valor #>> '{}' from public.parametros where chave = 'fim_expediente_chave_publica');
  if v_url is null or v_anon is null then
    raise notice '0048: parâmetros atlas_cadastro_url / fim_expediente_chave_publica ausentes; agendamento não criado.';
    return;
  end if;
  for job in select * from (values
      ('controladoria_atlas_cadastro', '*/2 * * * *', 'cadastrar', 'where exists (select 1 from public.atlas_cadastro where situacao = ''aprovado'')'),
      ('controladoria_atlas_clientes', '40 2 * * *',  'clientes',  '')) as t(nome, quando, acao, condicao) loop
    perform cron.unschedule(jobid) from cron.job where jobname = job.nome;
    perform cron.schedule(job.nome, job.quando, format($c$
      select net.http_post(url := %L,
        headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || %L,
                                      'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'atlas_cron_secret')),
        body := %L::jsonb, timeout_milliseconds := 150000) %s
    $c$, v_url, v_anon, json_build_object('acao', job.acao)::text, job.condicao));
  end loop;
end $$;
