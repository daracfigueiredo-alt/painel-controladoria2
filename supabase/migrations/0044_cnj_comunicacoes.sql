-- =====================================================================
-- 0044 — Intimações capturadas pelo CNJ (API pública de comunicações do DJEN)
-- Pedido da controladoria (12/11/2026): o escritório NÃO vai contratar o módulo de intimações do Atlas,
-- mas precisa do double check. A captura passa a ser feita direto no CNJ:
--   * por OAB do escritório (parâmetro cnj_oabs), todo dia;
--   * por processo: varredura DIÁRIA de toda a carteira (processos do Atlas + processos já conhecidos).
-- A Edge Function cnj-captura consulta a API e grava aqui; o double check compara CNJ × Webjur.
-- Ligação exata CNJ × Webjur: o "Identificador do documento" da Webjur é o id da comunicação no CNJ.
-- =====================================================================

insert into public.parametros (chave, valor, confirmado, descricao) values
 ('cnj_oabs', '["176787/MG"]', true,
  'OABs do escritório consultadas todo dia na API de comunicações do CNJ (DJEN), no formato "número/UF". Confirmado pela controladoria em 12/11/2026.'),
 ('cnj_janela_dias', '7', true,
  'Varredura por processo: quantos dias para trás (data de disponibilização) cada consulta diária cobre.'),
 ('cnj_lote_processos', '40', true,
  'Quantos processos cada execução da varredura consulta (a varredura roda a cada 5 minutos de madrugada).'),
 ('atlas_modulo_intimacoes', 'false', true,
  'O escritório decidiu não contratar o módulo de intimações do Atlas (12/11/2026). Com false, o double check não cobra a sincronização das intimações do Atlas e usa o CNJ.')
on conflict (chave) do nothing;

-- identificador da Webjur -> id da comunicação no CNJ (bigint), para usar o índice
create or replace function public._id_cnj(p text) returns bigint language sql immutable as
$$ select case when p ~ '^\d{1,18}$' then p::bigint end $$;
create index if not exists publicacoes_id_documento_idx on public.publicacoes (id_documento);

-- ---------------------------------------------------------------- comunicações
create table if not exists public.cnj_comunicacoes (
  id                    bigint primary key,            -- id da comunicação no CNJ (= "Identificador do documento" da Webjur)
  hash                  text,
  cnj                   text,                          -- normalizado (normalizar_cnj)
  numero_processo       text,
  sigla_tribunal        text,
  tipo_comunicacao      text,
  tipo_documento        text,
  nome_orgao            text,
  nome_classe           text,
  data_disponibilizacao date,
  texto                 text,
  link                  text,
  meio                  text,
  destinatarios         jsonb not null default '[]',
  advogados             jsonb not null default '[]',
  ativo                 boolean,
  status                text,
  data_cancelamento     text,
  encontrada_por        text[] not null default '{}',
  primeira_vez_em       timestamptz not null default now(),
  ultima_vez_em         timestamptz not null default now(),
  dados                 jsonb not null
);
create index if not exists cnj_comunicacoes_cnj_idx on public.cnj_comunicacoes (cnj, data_disponibilizacao);
create index if not exists cnj_comunicacoes_disp_idx on public.cnj_comunicacoes (data_disponibilizacao desc);
alter table public.cnj_comunicacoes enable row level security;
revoke all on public.cnj_comunicacoes from anon, authenticated;
grant select on public.cnj_comunicacoes to authenticated;
drop policy if exists cnj_comunicacoes_leitura on public.cnj_comunicacoes;
create policy cnj_comunicacoes_leitura on public.cnj_comunicacoes for select to authenticated using (public.pode_ler_tudo());

-- ---------------------------------------------------------------- carteira (processos varridos)
create table if not exists public.cnj_carteira (
  cnj               text primary key,                 -- normalizado
  origens           text[] not null default '{}',     -- atlas | base
  atlas_lawsuit_id  text,
  cliente           text,
  ativo             boolean not null default true,
  incluido_em       timestamptz not null default now(),
  ultima_consulta   timestamptz,                      -- última consulta COM sucesso
  ultima_tentativa  timestamptz,
  ultima_qtd        int,
  falhas_seguidas   int not null default 0,
  ultimo_erro       text
);
create index if not exists cnj_carteira_fila_idx on public.cnj_carteira (ativo, ultima_consulta nulls first);
alter table public.cnj_carteira enable row level security;
revoke all on public.cnj_carteira from anon, authenticated;
grant select on public.cnj_carteira to authenticated;
drop policy if exists cnj_carteira_leitura on public.cnj_carteira;
create policy cnj_carteira_leitura on public.cnj_carteira for select to authenticated using (public.pode_ler_tudo());

create table if not exists public.cnj_execucoes (
  id          bigint generated always as identity primary key,
  tipo        text not null check (tipo in ('oab','lote','carteira','manual')),
  inicio      timestamptz not null default now(),
  consultas   int not null default 0,
  sucesso     int not null default 0,
  falhas      int not null default 0,
  comunicacoes int not null default 0,
  novas       int not null default 0,
  detalhe     jsonb not null default '{}'
);
create index if not exists cnj_execucoes_idx on public.cnj_execucoes (tipo, inicio desc);
alter table public.cnj_execucoes enable row level security;
revoke all on public.cnj_execucoes from anon, authenticated;
grant select on public.cnj_execucoes to authenticated;
drop policy if exists cnj_execucoes_leitura on public.cnj_execucoes;
create policy cnj_execucoes_leitura on public.cnj_execucoes for select to authenticated using (public.pode_ler_tudo());
drop trigger if exists cnj_execucoes_imutavel on public.cnj_execucoes;
create trigger cnj_execucoes_imutavel before update or delete on public.cnj_execucoes
  for each row execute function public.tg_bloqueia_alteracao();

-- ---------------------------------------------------------------- funções da Edge Function (controladoria ou chave de serviço)
create or replace function public.cnj_conferir_acesso() returns boolean
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Somente a controladoria' using errcode = '42501'; end if;
  return true;
end $$;

create or replace function public.cnj_parametro(p_chave text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Somente a controladoria' using errcode = '42501'; end if;
  if p_chave not like 'cnj\_%' then raise exception 'Parâmetro não disponível'; end if;
  return (select valor from parametros where chave = p_chave);
end $$;

-- carteira: processos já conhecidos pelo sistema (base) + os enviados pela função (Atlas)
create or replace function public.cnj_carteira_registrar(p_itens jsonb, p_origem text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare n_novos int; n_base int := 0;
begin
  if not is_admin() then raise exception 'Somente a controladoria' using errcode = '42501'; end if;
  if p_origem not in ('atlas','base') then raise exception 'Origem inválida'; end if;
  with itens as (
    select distinct on (c) c, i->>'lawsuit_id' lawsuit_id, i->>'cliente' cliente
      from jsonb_array_elements(coalesce(p_itens, '[]')) i
      cross join lateral (select normalizar_cnj(i->>'cnj') c) z
     where c is not null and cnj_digito_valido(c)
     order by c),
  ins as (
    insert into cnj_carteira (cnj, origens, atlas_lawsuit_id, cliente)
    select c, array[p_origem], lawsuit_id, cliente from itens
    on conflict (cnj) do update set
      origens = (select array_agg(distinct o) from unnest(cnj_carteira.origens || excluded.origens) o),
      atlas_lawsuit_id = coalesce(excluded.atlas_lawsuit_id, cnj_carteira.atlas_lawsuit_id),
      cliente = coalesce(excluded.cliente, cnj_carteira.cliente), ativo = true
    returning (xmax = 0) novo)
  select count(*) filter (where novo) into n_novos from ins;
  if p_origem = 'atlas' or p_itens is null then
    with b as (
      insert into cnj_carteira (cnj, origens)
      select p.cnj, array['base'] from processos p where p.cnj_digito_valido
      on conflict (cnj) do update set
        origens = (select array_agg(distinct o) from unnest(cnj_carteira.origens || array['base']) o)
      returning (xmax = 0) novo)
    select count(*) filter (where novo) into n_base from b;
  end if;
  return jsonb_build_object('novos', n_novos + n_base, 'carteira', (select count(*) from cnj_carteira where ativo));
end $$;

-- próximos processos da varredura do dia (quem nunca foi consultado ou não foi hoje; sem repetir tentativa recente)
create or replace function public.cnj_proximos(p_limite int default null) returns setof text
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Somente a controladoria' using errcode = '42501'; end if;
  return query
    select k.cnj from cnj_carteira k
     where k.ativo
       and (k.ultima_consulta is null or (k.ultima_consulta at time zone 'America/Sao_Paulo')::date < hoje_brasilia())
       and (k.ultima_tentativa is null or k.ultima_tentativa < now() - interval '20 minutes')
     order by k.falhas_seguidas, k.ultima_consulta nulls first, k.cnj
     limit greatest(1, least(coalesce(p_limite, param_int('cnj_lote_processos')), 200));
end $$;

create or replace function public.cnj_registrar(p_itens jsonb, p_encontrada_por text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_recebidas int; v_novas int;
begin
  if not is_admin() then raise exception 'Somente a controladoria' using errcode = '42501'; end if;
  if jsonb_typeof(p_itens) <> 'array' then raise exception 'Lista inválida'; end if;
  with ins as (
    insert into cnj_comunicacoes (id, hash, cnj, numero_processo, sigla_tribunal, tipo_comunicacao, tipo_documento, nome_orgao,
           nome_classe, data_disponibilizacao, texto, link, meio, destinatarios, advogados, ativo, status, data_cancelamento,
           encontrada_por, dados)
    select (i->>'id')::bigint, i->>'hash', normalizar_cnj(coalesce(i->>'numeroprocessocommascara', i->>'numero_processo')),
           i->>'numero_processo', i->>'siglaTribunal', i->>'tipoComunicacao', i->>'tipoDocumento', i->>'nomeOrgao', i->>'nomeClasse',
           (i->>'data_disponibilizacao')::date, i->>'texto', i->>'link', i->>'meiocompleto',
           coalesce(i->'destinatarios', '[]'), coalesce(i->'destinatarioadvogados', '[]'),
           case when i->>'ativo' in ('true','false') then (i->>'ativo')::boolean end, i->>'status', i->>'data_cancelamento',
           array[p_encontrada_por], i
      from jsonb_array_elements(p_itens) i
     where i->>'id' ~ '^\d+$'
    on conflict (id) do update set status = excluded.status, ativo = excluded.ativo, data_cancelamento = excluded.data_cancelamento,
           encontrada_por = (select array_agg(distinct e) from unnest(cnj_comunicacoes.encontrada_por || excluded.encontrada_por) e),
           ultima_vez_em = now(), dados = excluded.dados
    returning (xmax = 0) nova)
  select count(*), count(*) filter (where nova) into v_recebidas, v_novas from ins;
  return jsonb_build_object('recebidas', v_recebidas, 'novas', v_novas);
end $$;

create or replace function public.cnj_marcar(p_cnj text, p_ok boolean, p_qtd int, p_erro text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Somente a controladoria' using errcode = '42501'; end if;
  update cnj_carteira set ultima_tentativa = now(),
         ultima_consulta = case when p_ok then now() else ultima_consulta end,
         ultima_qtd = case when p_ok then p_qtd else ultima_qtd end,
         falhas_seguidas = case when p_ok then 0 else falhas_seguidas + 1 end,
         ultimo_erro = case when p_ok then null else left(p_erro, 300) end
   where cnj = normalizar_cnj(p_cnj);
end $$;

create or replace function public.cnj_execucao_registrar(p_tipo text, p_detalhe jsonb) returns bigint
language plpgsql security definer set search_path = public as $$
declare v_id bigint;
begin
  if not is_admin() then raise exception 'Somente a controladoria' using errcode = '42501'; end if;
  insert into cnj_execucoes (tipo, consultas, sucesso, falhas, comunicacoes, novas, detalhe)
  values (p_tipo, coalesce((p_detalhe->>'consultas')::int, 0), coalesce((p_detalhe->>'sucesso')::int, 0),
          coalesce((p_detalhe->>'falhas')::int, 0), coalesce((p_detalhe->>'comunicacoes')::int, 0),
          coalesce((p_detalhe->>'novas')::int, 0), coalesce(p_detalhe, '{}'))
  returning id into v_id;
  return v_id;
end $$;

-- ---------------------------------------------------------------- painel "Intimações CNJ"
create or replace function public.cnj_painel(p_inicio date default null, p_fim date default null, p_busca text default null,
                                              p_filtro text default null, p_limite int default 500) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_fim date := coalesce(p_fim, hoje_brasilia()); v_ini date := coalesce(p_inicio, coalesce(p_fim, hoje_brasilia()) - 7);
        v_tol int := param_int('dc_atlas_tolerancia_dias'); v_busca text := nullif(btrim(coalesce(p_busca, '')), '');
begin
  if not public.pode_ler_tudo() then raise exception 'Somente a controladoria e a diretoria' using errcode = '42501'; end if;
  return jsonb_build_object(
    'periodo', jsonb_build_object('de', v_ini, 'ate', v_fim),
    'carteira', jsonb_build_object(
       'total', (select count(*) from cnj_carteira where ativo),
       'do_atlas', (select count(*) from cnj_carteira where ativo and 'atlas' = any(origens)),
       'consultados_hoje', (select count(*) from cnj_carteira where ativo and (ultima_consulta at time zone 'America/Sao_Paulo')::date = hoje_brasilia()),
       'com_falha', (select count(*) from cnj_carteira where ativo and falhas_seguidas > 0)),
    'execucoes', (select coalesce(jsonb_agg(to_jsonb(e) - 'detalhe' order by e.inicio desc), '[]')
                    from (select distinct on (tipo) * from cnj_execucoes order by tipo, inicio desc) e),
    'oabs', (select valor from parametros where chave = 'cnj_oabs'),
    'itens', (select coalesce(jsonb_agg(x order by x->>'data_disponibilizacao' desc, (x->>'id')::bigint desc), '[]') from (
       select jsonb_build_object('id', c.id, 'cnj', c.cnj, 'data_disponibilizacao', c.data_disponibilizacao, 'tribunal', c.sigla_tribunal,
                'tipo', c.tipo_comunicacao, 'documento', c.tipo_documento, 'orgao', c.nome_orgao, 'classe', c.nome_classe,
                'texto', left(c.texto, 4000), 'link', c.link, 'ativo', c.ativo, 'encontrada_por', c.encontrada_por,
                'advogados', c.advogados, 'na_carteira', k.cnj is not null,
                'webjur', (select jsonb_build_object('id', p.id, 'exata', p.id_documento = c.id::text)
                             from publicacoes p
                            where p.id_documento = c.id::text
                               or (p.cnj = c.cnj and p.data_disponibilizacao between c.data_disponibilizacao - v_tol and c.data_disponibilizacao + v_tol
                                   and not exists (select 1 from cnj_comunicacoes c2 where c2.id = public._id_cnj(p.id_documento)))
                            order by (p.id_documento = c.id::text) desc limit 1)) x
         from cnj_comunicacoes c left join cnj_carteira k on k.cnj = c.cnj
        where c.data_disponibilizacao between v_ini and v_fim
          and (v_busca is null or c.cnj ilike '%' || v_busca || '%' or c.texto ilike '%' || v_busca || '%'
               or c.sigla_tribunal ilike v_busca or c.nome_orgao ilike '%' || v_busca || '%')
        order by c.data_disponibilizacao desc, c.id desc
        limit greatest(coalesce(p_limite, 500), 1)) z(x)
       where p_filtro is null
          or (p_filtro = 'sem_webjur' and x->'webjur' = 'null'::jsonb)
          or (p_filtro = 'com_webjur' and x->'webjur' <> 'null'::jsonb)));
end $$;

-- ---------------------------------------------------------------- double check: CNJ × Webjur
alter table public.inconsistencias drop constraint if exists inconsistencias_tipo_check;
alter table public.inconsistencias add constraint inconsistencias_tipo_check check (tipo in
  ('intimacao_nao_cadastrada','divergencia','prazo_nao_lancado','prazo_incorreto','publicacao_duplicada','pendencia_controladoria',
   'captura_divergente'));

-- chamada de dentro de double_check_atlas_executar (usa a tabela temporária _inc dela)
create or replace function public._dc_cnj(p_ini date, p_dia date, p_tol int) returns void
language plpgsql security definer set search_path = public as $$
declare f constant text := 'DD/MM/YYYY'; v_cart int; v_hoje int; v_oab timestamptz;
begin
  -- a) comunicação do CNJ não capturada pela Webjur (nem pelo identificador, nem por processo e data)
  insert into _inc select 'cnj_sem_webjur|' || c.id, 'captura_divergente', 2, c.data_disponibilizacao, c.cnj, null, null, null,
         'Comunicação do CNJ de ' || to_char(c.data_disponibilizacao, f) || ' (' || coalesce(c.sigla_tribunal, '?') || ', '
           || coalesce(c.tipo_comunicacao, 'comunicação') || ') não capturada pela Webjur.',
         'Ler a comunicação (link da certidão), tratar no Atlas e avisar a Webjur se for falha de captura.',
         jsonb_build_object('cnj_id', c.id, 'link', c.link, 'tribunal', c.sigla_tribunal, 'tipo', c.tipo_comunicacao, 'orgao', c.nome_orgao)
    from cnj_comunicacoes c
   where c.data_disponibilizacao between p_ini and p_dia - 1      -- a Webjur entrega no dia seguinte
     and coalesce(c.ativo, true) and c.data_cancelamento is null
     and coalesce(c.tipo_comunicacao, '') !~* 'distribui'
     and not exists (select 1 from publicacoes p where p.id_documento = c.id::text)
     -- por processo e data só vale publicação sem identificador de outra comunicação do CNJ (ex.: diário estadual próprio)
     and not exists (select 1 from publicacoes p where p.cnj = c.cnj and p.data_disponibilizacao between c.data_disponibilizacao - p_tol
                                                                                              and c.data_disponibilizacao + p_tol
                       and not exists (select 1 from cnj_comunicacoes c2 where c2.id = public._id_cnj(p.id_documento)))
  on conflict (chave) do nothing;

  -- b) publicação da Webjur no DJEN que o CNJ não mostra (só para processo já varrido depois da publicação)
  insert into _inc select 'webjur_sem_cnj|' || p.id, 'captura_divergente', 3, p.data_disponibilizacao, p.cnj, p.id, null, null,
         'Publicação da Webjur de ' || to_char(p.data_disponibilizacao, f) || ' (DJEN) não encontrada na consulta ao CNJ.',
         'Conferir a publicação no portal do CNJ (comunica.pje.jus.br); pode ter sido cancelada.',
         jsonb_build_object('id_documento', p.id_documento)
    from publicacoes p join cnj_carteira k on k.cnj = p.cnj
   where p.data_disponibilizacao between p_ini and p_dia
     and p.id_documento is not null
     and coalesce(p.conteudo_original->>'local', p.conteudo_original->>'tribunal_texto', '') ~* '^DJEN'
     and k.ultima_consulta >= (p.data_disponibilizacao + 1)::timestamptz
     and not exists (select 1 from cnj_comunicacoes c where c.id = public._id_cnj(p.id_documento))
  on conflict (chave) do nothing;

  -- c) pendências da captura do CNJ
  select count(*), count(*) filter (where (ultima_consulta at time zone 'America/Sao_Paulo')::date = p_dia)
    into v_cart, v_hoje from cnj_carteira where ativo;
  if v_cart > 0 and v_hoje < v_cart then
    insert into _inc values ('cnj_varredura|' || p_dia, 'pendencia_controladoria', 2, p_dia, null, null, null, null,
           'Varredura do CNJ incompleta hoje: ' || v_hoje || ' de ' || v_cart || ' processos consultados.',
           'Conferir o painel Intimações CNJ (a API do CNJ pode ter ficado indisponível); a varredura continua na próxima madrugada.',
           jsonb_build_object('consultados', v_hoje, 'carteira', v_cart))
    on conflict (chave) do nothing;
  end if;
  select max(inicio) into v_oab from cnj_execucoes where tipo = 'oab' and sucesso > 0;
  if v_oab is null or (v_oab at time zone 'America/Sao_Paulo')::date < p_dia then
    insert into _inc values ('cnj_oab|' || p_dia, 'pendencia_controladoria', 1, p_dia, null, null, null, null,
           'A consulta das intimações por OAB no CNJ não rodou hoje' || coalesce(' (última: ' || to_char(v_oab at time zone 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI') || ')', '') || '.',
           'Rodar "Consultar agora" no painel Intimações CNJ.', '{}')
    on conflict (chave) do nothing;
  end if;
end $$;
revoke execute on function public._dc_cnj(date, date, int) from public, anon, authenticated;

-- encaixe no double check (padrão das 0033/0034: trecho-âncora, idempotente)
do $$
declare d text;
begin
  d := pg_get_functiondef('public.double_check_atlas_executar(date, text)'::regprocedure);
  if position('-- 0044 cnj' in d) > 0 then return; end if;
  if position('  -- gravação: novas, atualizadas e regularizadas (as que sumiram)' in d) = 0
     or position('  if v_ult_sync is null or (v_ult_sync at time zone ''America/Sao_Paulo'')::date < v_dia then' in d) = 0 then
    raise exception '0044: âncoras do double_check_atlas_executar não encontradas';
  end if;
  d := replace(d, '  -- gravação: novas, atualizadas e regularizadas (as que sumiram)',
               '  perform public._dc_cnj(v_ini, v_dia, v_tol);   -- 0044 cnj' || chr(10) ||
               '  -- gravação: novas, atualizadas e regularizadas (as que sumiram)');
  d := replace(d, '  if v_ult_sync is null or (v_ult_sync at time zone ''America/Sao_Paulo'')::date < v_dia then',
               '  if coalesce((select valor = ''true''::jsonb from parametros where chave = ''atlas_modulo_intimacoes''), false)   -- 0044' || chr(10) ||
               '     and (v_ult_sync is null or (v_ult_sync at time zone ''America/Sao_Paulo'')::date < v_dia) then');
  execute d;
end $$;

revoke execute on function public.cnj_conferir_acesso(), public.cnj_parametro(text), public.cnj_carteira_registrar(jsonb, text), public.cnj_proximos(int),
  public.cnj_registrar(jsonb, text), public.cnj_marcar(text, boolean, int, text), public.cnj_execucao_registrar(text, jsonb),
  public.cnj_painel(date, date, text, text, int) from public, anon;
grant execute on function public.cnj_conferir_acesso(), public.cnj_parametro(text), public.cnj_carteira_registrar(jsonb, text), public.cnj_proximos(int),
  public.cnj_registrar(jsonb, text), public.cnj_marcar(text, boolean, int, text), public.cnj_execucao_registrar(text, jsonb),
  public.cnj_painel(date, date, text, text, int) to authenticated;
