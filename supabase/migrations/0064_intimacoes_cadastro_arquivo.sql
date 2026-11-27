-- =====================================================================
-- 0064 — Intimações: cadastro automático do processo no Atlas, publicações arquivadas e processos não cadastrados
-- (controladoria, 27/11/2026).
-- Decisões da controladoria (27/11/2026):
--   * processo com intimação (CNJ ou Webjur) que não está no Atlas é cadastrado no Atlas pela API (robô atlas-cadastro,
--     o mesmo da etapa 15), vinculado ao cliente do Atlas encontrado pelas partes da intimação;
--   * AUTOMÁTICO quando o casamento é seguro: CPF/CNPJ citado na intimação, ou nome da parte idêntico a um nome da
--     ficha do cliente no Atlas ("C362 - FULANO - EMPRESA LTDA - PJ"), apontando para um único cliente;
--     nome só parecido, ou mais de um cliente possível = a controladoria confere (sugestões na tela);
--   * cliente que não existe no Atlas: a controladoria escolhe no painel (o robô não cria cliente — decisão de 14/11);
--   * arquivar intimação: só a controladoria, motivo opcional, pode desarquivar;
--   * área "Processos não cadastrados": volume e situação dos processos que chegaram por intimação sem estar no Atlas.
-- Também: a diretoria passa a ver a lista de entregas autorizadas após o D-4 (atalho do painel da diretoria).
-- =====================================================================

-- ---------------------------------------------------------------- parâmetro
insert into public.parametros (chave, valor, confirmado, descricao) values
 ('cnj_cadastro_automatico', 'false', true,
  'Intimações (0064): processo com intimação fora do Atlas e cliente casado com segurança (CPF/CNPJ ou nome idêntico, um só cliente) vai direto para a fila do robô de cadastro no Atlas. Desligado: fica em "Prontos para cadastrar", esperando a controladoria. Começa desligado (decisão de 27/11/2026: conferir o primeiro lote na tela antes de ligar).')
on conflict (chave) do nothing;

-- ---------------------------------------------------------------- arquivamento das intimações do CNJ
alter table public.cnj_comunicacoes add column if not exists arquivada_em timestamptz;
alter table public.cnj_comunicacoes add column if not exists arquivada_por uuid;
alter table public.cnj_comunicacoes add column if not exists arquivada_motivo text;
create index if not exists cnj_comunicacoes_arquivada_idx on public.cnj_comunicacoes (arquivada_em) where arquivada_em is not null;

create table if not exists public.cnj_arquivo_eventos (
  id      bigint generated always as identity primary key,
  em      timestamptz not null default now(),
  usuario uuid default auth.uid(),
  acao    text not null check (acao in ('arquivar','desarquivar')),
  ids     bigint[] not null,
  motivo  text
);
alter table public.cnj_arquivo_eventos enable row level security;
revoke all on public.cnj_arquivo_eventos from anon, authenticated;
grant select on public.cnj_arquivo_eventos to authenticated;
drop policy if exists cnj_arquivo_eventos_leitura on public.cnj_arquivo_eventos;
create policy cnj_arquivo_eventos_leitura on public.cnj_arquivo_eventos for select to authenticated using (public.pode_ler_tudo());
drop trigger if exists cnj_arquivo_eventos_imutavel on public.cnj_arquivo_eventos;
create trigger cnj_arquivo_eventos_imutavel before update or delete on public.cnj_arquivo_eventos
  for each row execute function public.tg_bloqueia_alteracao();

create or replace function public.cnj_arquivar(p_ids bigint[], p_motivo text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_n int; v_mot text := nullif(btrim(coalesce(p_motivo, '')), '');
begin
  if not is_admin() then raise exception 'Somente a controladoria arquiva intimações' using errcode = '42501'; end if;
  if coalesce(cardinality(p_ids), 0) = 0 then raise exception 'Escolha as intimações'; end if;
  if length(v_mot) > 500 then raise exception 'Motivo muito longo (máximo de 500 caracteres)'; end if;
  update cnj_comunicacoes set arquivada_em = now(), arquivada_por = auth.uid(), arquivada_motivo = v_mot
   where id = any(p_ids) and arquivada_em is null;
  get diagnostics v_n = row_count;
  if v_n > 0 then insert into cnj_arquivo_eventos (acao, ids, motivo) values ('arquivar', p_ids, v_mot); end if;
  return jsonb_build_object('arquivadas', v_n);
end $$;

create or replace function public.cnj_desarquivar(p_ids bigint[]) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_n int;
begin
  if not is_admin() then raise exception 'Somente a controladoria desarquiva intimações' using errcode = '42501'; end if;
  if coalesce(cardinality(p_ids), 0) = 0 then raise exception 'Escolha as intimações'; end if;
  update cnj_comunicacoes set arquivada_em = null, arquivada_por = null, arquivada_motivo = null
   where id = any(p_ids) and arquivada_em is not null;
  get diagnostics v_n = row_count;
  if v_n > 0 then insert into cnj_arquivo_eventos (acao, ids) values ('desarquivar', p_ids); end if;
  return jsonb_build_object('desarquivadas', v_n);
end $$;

-- ---------------------------------------------------------------- fila de cadastro: processos vindos das intimações
alter table public.atlas_cadastro drop constraint if exists atlas_cadastro_origem_check;
alter table public.atlas_cadastro add constraint atlas_cadastro_origem_check check (origem in ('advbox','carteira','intimacao'));
alter table public.atlas_cadastro add column if not exists detectado_em timestamptz;          -- chegou intimação e o processo não estava no Atlas
alter table public.atlas_cadastro add column if not exists fontes text[] not null default '{}'; -- cnj | webjur
alter table public.atlas_cadastro add column if not exists primeira_intimacao date;
alter table public.atlas_cadastro add column if not exists classe text;
alter table public.atlas_cadastro add column if not exists orgao text;
alter table public.atlas_cadastro add column if not exists partes jsonb;                       -- [{nome, polo}] das intimações do CNJ
alter table public.atlas_cadastro add column if not exists sugestoes jsonb;                    -- clientes possíveis [{id, nome, por, parte, pontos}]
alter table public.atlas_cadastro add column if not exists aprovado_automatico boolean not null default false;
create index if not exists atlas_cadastro_detectado_idx on public.atlas_cadastro (detectado_em) where detectado_em is not null;

-- palavras que não identificam ninguém
create or replace function public._nome_tokens(p text) returns text[] language sql immutable set search_path = public as $$
  select coalesce(array_agg(distinct t order by t), '{}') from unnest(string_to_array(coalesce(_nome_cliente_norm(p), ''), ' ')) t
   where length(t) > 1 and t not in ('DE','DA','DO','DAS','DOS','E','LTDA','ME','MEI','EIRELI','EIRELE','SA','EPP','PF','PJ','CIA','EM','RECUPERACAO','JUDICIAL')
$$;

-- casamento do cliente pelas partes das intimações e montagem do cadastro (interna; também roda pelo agendamento)
create or replace function public._cnj_cadastro_detectar() returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_novos int; v_auto int := 0; v_rev int; v_sem int; v_hoje text := to_char(hoje_brasilia(), 'DD/MM/YYYY');
        v_automatico boolean := coalesce((select (valor #>> '{}')::boolean from parametros where chave = 'cnj_cadastro_automatico'), true);
        v_aprovados text[];
begin
  -- 1) universo: processos com intimação (CNJ ou Webjur) que não estão no Atlas
  with fontes as (
    select cnj, 'cnj' f, min(data_disponibilizacao) d from cnj_comunicacoes
     where cnj ~ '^\d{7}-\d{2}\.\d{4}\.\d\.\d{2}\.\d{4}$' and cnj_digito_valido(cnj) group by cnj
    union all
    select cnj, 'webjur', min(data_disponibilizacao) from publicacoes
     where cnj ~ '^\d{7}-\d{2}\.\d{4}\.\d\.\d{2}\.\d{4}$' and coalesce(cnj_digito_valido, true) group by cnj),
  f as (select cnj, array_agg(distinct f order by f) fontes, min(d) primeira from fontes x
         where not exists (select 1 from cnj_carteira k where k.cnj = x.cnj and 'atlas' = any(k.origens)) group by cnj),
  ins as (
    insert into atlas_cadastro (cnj, origem, situacao, motivo, detectado_em, fontes, primeira_intimacao)
    select cnj, 'intimacao', 'sem_cliente', 'Processo com intimação fora do Atlas', now(), fontes, primeira from f
    on conflict (cnj) do update set
       fontes = (select array_agg(distinct x order by x) from unnest(atlas_cadastro.fontes || excluded.fontes) x),
       primeira_intimacao = least(atlas_cadastro.primeira_intimacao, excluded.primeira_intimacao),
       detectado_em = coalesce(atlas_cadastro.detectado_em,
                               case when atlas_cadastro.situacao not in ('cadastrado','no_atlas') then now() end),
       origem = case when atlas_cadastro.origem = 'carteira' then 'intimacao' else atlas_cadastro.origem end
    returning (xmax = 0) novo)
  select count(*) filter (where novo) into v_novos from ins;

  -- 2) já está no Atlas (carteira lida pela API)
  update atlas_cadastro a set situacao = 'no_atlas', motivo = 'Processo já cadastrado no Atlas', atualizado_em = now(),
         atlas_lawsuit_id = coalesce(a.atlas_lawsuit_id, k.atlas_lawsuit_id)
    from cnj_carteira k
   where k.cnj = a.cnj and 'atlas' = any(k.origens) and a.detectado_em is not null and a.situacao in ('sem_cliente','revisar','previa','erro');

  -- 3) dados do processo pelas intimações do CNJ (só para o que não veio do ADVBOX)
  with p as (
    select c.cnj,
           (array_agg(c.nome_classe order by c.data_disponibilizacao desc) filter (where c.nome_classe is not null))[1] classe,
           (array_agg(c.nome_orgao order by c.data_disponibilizacao desc) filter (where c.nome_orgao is not null))[1] orgao,
           (array_agg(c.sigla_tribunal order by c.data_disponibilizacao desc) filter (where c.sigla_tribunal is not null))[1] tribunal,
           (select coalesce(jsonb_agg(jsonb_build_object('nome', nome, 'polo', polo) order by polo, nome), '[]') from (
              select distinct on (_nome_cliente_norm(d->>'nome'), d->>'polo') btrim(d->>'nome') nome, d->>'polo' polo
                from cnj_comunicacoes c2, jsonb_array_elements(c2.destinatarios) d
               where c2.cnj = c.cnj and nullif(btrim(d->>'nome'), '') is not null
               order by _nome_cliente_norm(d->>'nome'), d->>'polo', c2.data_disponibilizacao desc) dd) partes
      from cnj_comunicacoes c join atlas_cadastro a on a.cnj = c.cnj
     where a.origem = 'intimacao' and a.situacao in ('sem_cliente','revisar','previa')
     group by c.cnj)
  update atlas_cadastro a set classe = p.classe, orgao = p.orgao, tribunal = coalesce(p.tribunal, a.tribunal), partes = p.partes,
         tipo_advbox = p.classe, tipo_atlas = _tipo_atlas(p.classe),
         autores = left(nullif((select string_agg(x->>'nome', '; ' order by x->>'nome') from jsonb_array_elements(p.partes) x where x->>'polo' = 'A'), ''), 1000),
         reus    = left(nullif((select string_agg(x->>'nome', '; ' order by x->>'nome') from jsonb_array_elements(p.partes) x where x->>'polo' = 'P'), ''), 1000),
         notas = left(concat_ws(E'\n',
           'Cadastrado pela controladoria a partir de intimação (' || array_to_string(a.fontes, ' e ') || ') em ' || v_hoje
             || ': o processo não estava no Atlas.',
           'Primeira intimação: ' || to_char(a.primeira_intimacao, 'DD/MM/YYYY'),
           'Classe: ' || p.classe, 'Órgão: ' || nullif(concat_ws(' / ', p.tribunal, p.orgao), ''),
           'Partes intimadas: ' || nullif((select string_agg(coalesce(x->>'nome', '') || coalesce(' (' || case x->>'polo' when 'A' then 'polo ativo'
                                       when 'P' then 'polo passivo' else 'outro' end || ')', ''), '; ') from jsonb_array_elements(p.partes) x), ''),
           'Data de distribuição não informada: o Atlas registra a data do cadastro até o DataJud completar.'), 2000),
         atualizado_em = now()
    from p where a.cnj = p.cnj;

  -- 4) casamento do cliente pelas partes (CPF/CNPJ citado ou nome idêntico = seguro; nome parecido = conferir)
  create temporary table if not exists _cnj_cand (cnj text, id uuid, nome text, por text, parte text, pontos numeric, rescindido boolean) on commit drop;
  truncate _cnj_cand;
  with alvo as (
    select a.cnj from atlas_cadastro a
     where a.detectado_em is not null and a.situacao in ('sem_cliente','revisar')
       and coalesce(a.casado_por, '') <> 'escolha da controladoria'),
  partes as (
    select distinct c.cnj, btrim(d->>'nome') nome, _nome_cliente_norm(d->>'nome') norm, _nome_tokens(d->>'nome') tk
      from alvo join cnj_comunicacoes c on c.cnj = alvo.cnj, jsonb_array_elements(c.destinatarios) d
     where nullif(btrim(d->>'nome'), '') is not null),
  docs as (
    select distinct alvo.cnj, unnest(_docs_do_texto(c.texto)) doc from alvo join cnj_comunicacoes c on c.cnj = alvo.cnj
    union
    select distinct alvo.cnj, unnest(_docs_do_texto(p.teor)) from alvo join publicacoes p on p.cnj = alvo.cnj),
  seg as (  -- cada nome dentro da ficha do cliente do Atlas ("C362 - FULANO - EMPRESA LTDA - PJ")
    select a.id, a.nome, _nome_cliente_norm(s) norm, _nome_tokens(s) tk, coalesce(a.status, '') ~* 'rescind' rescindido
      from atlas_clientes a, regexp_split_to_table(a.nome, '\s+-\s*|\s*-\s+|/|;') s
     where coalesce(a.status, '') !~* 'trash|lixeira|deleted|exclu')
  insert into _cnj_cand
  select d.cnj, c.id, c.nome, 'CPF/CNPJ', d.doc, 100, coalesce(c.status, '') ~* 'rescind' from docs d join atlas_clientes c on c.doc = d.doc
   where coalesce(c.status, '') !~* 'trash|lixeira|deleted|exclu'
  union all
  select p.cnj, s.id, s.nome, 'nome idêntico', p.nome, 90, s.rescindido from partes p join seg s on s.norm = p.norm
   where cardinality(p.tk) >= 2 and length(p.norm) >= 10
  union all
  select p.cnj, s.id, s.nome, 'nome parecido', p.nome,
         round(100 * cardinality(array(select unnest(p.tk) intersect select unnest(s.tk)))::numeric / greatest(cardinality(p.tk), cardinality(s.tk))),
         s.rescindido
    from partes p join seg s on s.tk && p.tk and s.norm <> p.norm
   where cardinality(p.tk) >= 2 and cardinality(s.tk) >= 2
     and cardinality(array(select unnest(p.tk) intersect select unnest(s.tk)))::numeric / greatest(cardinality(p.tk), cardinality(s.tk)) >= 0.6;

  with por_cliente as (
    select cnj, id, min(nome) nome, max(pontos) pontos, bool_or(por in ('CPF/CNPJ','nome idêntico')) and not bool_or(rescindido) seguro, bool_or(rescindido) rescindido,
           string_agg(distinct por, ', ') por, (array_agg(parte order by pontos desc))[1] parte
      from _cnj_cand group by cnj, id),
  res as (
    select cnj, count(*) filter (where seguro) n_seg,
           (array_agg(id order by pontos desc) filter (where seguro))[1] id,
           (array_agg(nome order by pontos desc) filter (where seguro))[1] nome,
           (array_agg(por order by pontos desc) filter (where seguro))[1] por,
           jsonb_agg(jsonb_build_object('id', id, 'nome', nome, 'por', por, 'parte', parte, 'pontos', pontos, 'rescindido', rescindido) order by pontos desc, nome) sug
      from por_cliente group by cnj)
  , u as (
  update atlas_cadastro a set
     sugestoes = (select jsonb_agg(x) from (select x from jsonb_array_elements(r.sug) x limit 5) y),
     atlas_client_id = case when r.n_seg = 1 then r.id end,
     atlas_cliente_nome = case when r.n_seg = 1 then r.nome end,
     casado_por = case when r.n_seg = 1 then 'partes da intimação (' || r.por || ')' end,
     situacao = case when r.n_seg = 1 and v_automatico then 'aprovado' when r.n_seg = 1 then 'previa' else 'revisar' end,
     aprovado_em = case when r.n_seg = 1 and v_automatico then now() end,
     aprovado_por = null,
     aprovado_automatico = (r.n_seg = 1 and v_automatico),
     motivo = case when r.n_seg = 1 then null
                   when r.n_seg > 1 then 'Mais de um cliente do Atlas aparece nas partes: escolha o certo'
                   else 'Nome da parte só parecido com cliente do Atlas (ou cliente com contrato rescindido): confira a sugestão' end,
     atualizado_em = now()
    from res r
   where a.cnj = r.cnj and a.situacao in ('sem_cliente','revisar') and coalesce(a.casado_por, '') <> 'escolha da controladoria'
  returning a.cnj, a.situacao)
  select array_agg(cnj) filter (where situacao = 'aprovado') into v_aprovados from u;

  update atlas_cadastro a set sugestoes = null, situacao = 'sem_cliente',
         motivo = case when a.partes is null or jsonb_array_length(a.partes) = 0
                       then 'Sem partes na intimação (só Webjur): escolha o cliente'
                       else 'Nenhuma parte da intimação é cliente do Atlas: escolha ou cadastre o cliente no Atlas' end
   where a.detectado_em is not null and a.situacao in ('sem_cliente','revisar') and coalesce(a.casado_por, '') <> 'escolha da controladoria'
     and a.origem = 'intimacao' and not exists (select 1 from _cnj_cand c where c.cnj = a.cnj);

  v_auto := coalesce(cardinality(v_aprovados), 0);
  select count(*) filter (where situacao = 'revisar'), count(*) filter (where situacao = 'sem_cliente')
    into v_rev, v_sem from atlas_cadastro where detectado_em is not null;
  if v_novos > 0 or v_auto > 0 then
    insert into atlas_cadastro_eventos (tipo, usuario, detalhe) values ('preparacao', null,
      jsonb_build_object('origem', 'intimacoes', 'novos', v_novos, 'aprovados_automaticamente', v_auto, 'revisar', v_rev, 'sem_cliente', v_sem));
  end if;
  if v_auto > 0 then
    insert into atlas_cadastro_eventos (tipo, usuario, detalhe) values ('aprovacao', null,
      jsonb_build_object('automatico', true, 'aprovados', v_auto, 'processos', to_jsonb(v_aprovados)));
  end if;
  return jsonb_build_object('novos', v_novos, 'aprovados_automaticamente', v_auto, 'revisar', v_rev, 'sem_cliente', v_sem,
                            'automatico_ligado', v_automatico);
end $$;

create or replace function public.cnj_cadastro_detectar() returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Somente a controladoria' using errcode = '42501'; end if;
  return _cnj_cadastro_detectar();
end $$;

-- cliente escolhido pela controladoria na tela dos processos não cadastrados; já entra na fila do robô
create or replace function public.cnj_cadastro_escolher(p_cnj text, p_client_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_cnj text := normalizar_cnj(p_cnj); r jsonb;
begin
  if not is_admin() then raise exception 'Somente a controladoria' using errcode = '42501'; end if;
  if not exists (select 1 from atlas_cadastro where cnj = v_cnj and detectado_em is not null) then
    raise exception 'Processo não está entre os processos não cadastrados';
  end if;
  r := atlas_cadastro_definir_cliente(v_cnj, p_client_id);
  update atlas_cadastro set situacao = 'aprovado', aprovado_em = now(), aprovado_por = auth.uid(), aprovado_automatico = false,
         motivo = null, ultimo_erro = null, atualizado_em = now()
   where cnj = v_cnj and situacao = 'previa' and atlas_client_id is not null;
  insert into atlas_cadastro_eventos (tipo, cnj, detalhe) values ('aprovacao', v_cnj, jsonb_build_object('automatico', false, 'origem', 'intimacoes'));
  return r || jsonb_build_object('situacao', (select situacao from atlas_cadastro where cnj = v_cnj));
end $$;

-- área "Processos não cadastrados"
create or replace function public.cnj_nao_cadastrados(p_grupo text default null, p_busca text default null, p_limite int default 1000) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_busca text := nullif(btrim(coalesce(p_busca, '')), '');
begin
  if not pode_ler_tudo() then raise exception 'Somente a controladoria e a diretoria' using errcode = '42501'; end if;
  return jsonb_build_object(
    'automatico', coalesce((select (valor #>> '{}')::boolean from parametros where chave = 'cnj_cadastro_automatico'), true),
    'ultima_execucao', (select max(em) from atlas_cadastro_eventos where tipo = 'preparacao' and detalhe->>'origem' = 'intimacoes'),
    'contagem', (select jsonb_build_object(
        'total', count(*),
        'aguardando_cliente', count(*) filter (where situacao = 'sem_cliente'),
        'revisar', count(*) filter (where situacao = 'revisar'),
        'prontos', count(*) filter (where situacao = 'previa'),
        'na_fila', count(*) filter (where situacao in ('aprovado','enviando')),
        'cadastrados', count(*) filter (where situacao = 'cadastrado'),
        'automaticos', count(*) filter (where situacao = 'cadastrado' and aprovado_automatico),
        'ja_estavam', count(*) filter (where situacao = 'no_atlas'),
        'erro', count(*) filter (where situacao = 'erro'))
      from atlas_cadastro where detectado_em is not null),
    'por_mes', (select coalesce(jsonb_agg(jsonb_build_object('mes', m, 'total', n, 'cadastrados', c) order by m), '[]') from (
        select to_char(coalesce(primeira_intimacao, detectado_em::date), 'YYYY-MM') m, count(*) n,
               count(*) filter (where situacao in ('cadastrado','no_atlas')) c
          from atlas_cadastro where detectado_em is not null group by 1) x),
    'por_tribunal', (select coalesce(jsonb_agg(jsonb_build_object('tribunal', t, 'total', n) order by n desc, t), '[]') from (
        select coalesce(nullif(tribunal, ''), tribunal_do_cnj(cnj), '?') t, count(*) n
          from atlas_cadastro where detectado_em is not null group by 1 order by 2 desc limit 15) x),
    'itens', (select coalesce(jsonb_agg(x order by x->>'ordem', x->>'primeira_intimacao' desc nulls last), '[]') from (
      select jsonb_build_object(
        'ordem', case a.situacao when 'erro' then '1' when 'previa' then '2' when 'revisar' then '3' when 'sem_cliente' then '4'
                                 when 'aprovado' then '5' when 'enviando' then '5' else '9' end,
        'cnj', a.cnj, 'situacao', a.situacao, 'origem', a.origem, 'fontes', a.fontes, 'primeira_intimacao', a.primeira_intimacao,
        'detectado_em', a.detectado_em, 'cliente_advbox', a.cliente_advbox, 'cliente', a.atlas_cliente_nome, 'client_id', a.atlas_client_id, 'casado_por', a.casado_por,
        'motivo', a.motivo, 'sugestoes', a.sugestoes, 'partes', a.partes, 'classe', coalesce(a.classe, a.tipo_advbox),
        'orgao', coalesce(a.orgao, nullif(concat_ws(' / ', a.comarca, a.vara), '')), 'tribunal', a.tribunal, 'tipo_atlas', a.tipo_atlas,
        'erro', a.ultimo_erro, 'cadastrado_em', a.cadastrado_em, 'atlas_lawsuit_id', a.atlas_lawsuit_id, 'automatico', a.aprovado_automatico,
        'intimacoes', (select count(*) from cnj_comunicacoes c where c.cnj = a.cnj) + (select count(*) from publicacoes p where p.cnj = a.cnj),
        'ultima_intimacao', greatest((select max(data_disponibilizacao) from cnj_comunicacoes c where c.cnj = a.cnj),
                                     (select max(data_disponibilizacao) from publicacoes p where p.cnj = a.cnj))) x
        from atlas_cadastro a
       where a.detectado_em is not null
         and (p_grupo is null or p_grupo = ''
              or (p_grupo = 'aguardando_cliente' and a.situacao = 'sem_cliente')
              or (p_grupo = 'revisar' and a.situacao = 'revisar')
              or (p_grupo = 'prontos' and a.situacao = 'previa')
              or (p_grupo = 'na_fila' and a.situacao in ('aprovado','enviando'))
              or (p_grupo = 'cadastrados' and a.situacao = 'cadastrado')
              or (p_grupo = 'ja_estavam' and a.situacao = 'no_atlas')
              or (p_grupo = 'erro' and a.situacao = 'erro'))
         and (v_busca is null or a.cnj ilike '%' || v_busca || '%' or a.atlas_cliente_nome ilike '%' || v_busca || '%'
              or a.cliente_advbox ilike '%' || v_busca || '%' or a.partes::text ilike '%' || v_busca || '%')
       limit greatest(least(coalesce(p_limite, 1000), 3000), 1)) s));
end $$;

-- ---------------------------------------------------------------- a rotina de cadastro da etapa 15 não desfaz o casamento das intimações
do $$
declare v_def text; v_ant text := 'and coalesce(a.casado_por, '''') <> ''escolha da controladoria''),';
begin
  v_def := pg_get_functiondef('public._atlas_cadastro_preparar(text[])'::regprocedure);
  if position('origem <> ''intimacao''' in v_def) > 0 then return; end if;   -- já aplicado
  if position(v_ant in v_def) = 0 then raise exception '0064: trecho esperado de _atlas_cadastro_preparar não encontrado'; end if;
  v_def := replace(v_def, v_ant, 'and coalesce(a.casado_por, '''') <> ''escolha da controladoria'''
    || E'\n       and a.origem <> ''intimacao'' and coalesce(a.casado_por, '''') not like ''partes da intimação%''),');
  execute v_def;
end $$;

-- ---------------------------------------------------------------- painel das intimações do CNJ (arquivadas e situação no Atlas)
create or replace function public.cnj_painel(p_inicio date default null, p_fim date default null, p_busca text default null,
                                              p_filtro text default null, p_limite int default 500) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_fim date := coalesce(p_fim, hoje_brasilia()); v_ini date := coalesce(p_inicio, coalesce(p_fim, hoje_brasilia()) - 7);
        v_tol int := param_int('dc_atlas_tolerancia_dias'); v_busca text := nullif(btrim(coalesce(p_busca, '')), '');
        v_arq boolean := coalesce(p_filtro, '') = 'arquivadas';
begin
  if not public.pode_ler_tudo() then raise exception 'Somente a controladoria e a diretoria' using errcode = '42501'; end if;
  return jsonb_build_object(
    'periodo', jsonb_build_object('de', v_ini, 'ate', v_fim),
    'carteira', jsonb_build_object(
       'total', (select count(*) from cnj_carteira where ativo),
       'do_atlas', (select count(*) from cnj_carteira where ativo and 'atlas' = any(origens)),
       'consultados_hoje', (select count(*) from cnj_carteira where ativo and (ultima_consulta at time zone 'America/Sao_Paulo')::date = hoje_brasilia()),
       'com_falha', (select count(*) from cnj_carteira where ativo and falhas_seguidas > 0)),
    'arquivadas_periodo', (select count(*) from cnj_comunicacoes where data_disponibilizacao between v_ini and v_fim and arquivada_em is not null),
    'execucoes', (select coalesce(jsonb_agg(to_jsonb(e) - 'detalhe' order by e.inicio desc), '[]')
                    from (select distinct on (tipo) * from cnj_execucoes order by tipo, inicio desc) e),
    'oabs', (select valor from parametros where chave = 'cnj_oabs'),
    'itens', (select coalesce(jsonb_agg(x order by x->>'data_disponibilizacao' desc, (x->>'id')::bigint desc), '[]') from (
       select jsonb_build_object('id', c.id, 'cnj', c.cnj, 'data_disponibilizacao', c.data_disponibilizacao, 'tribunal', c.sigla_tribunal,
                'tipo', c.tipo_comunicacao, 'documento', c.tipo_documento, 'orgao', c.nome_orgao, 'classe', c.nome_classe,
                'texto', left(c.texto, 4000), 'link', c.link, 'ativo', c.ativo, 'encontrada_por', c.encontrada_por,
                'advogados', c.advogados, 'na_carteira', k.cnj is not null,
                'no_atlas', coalesce('atlas' = any(k.origens), false),
                'cadastro', (select jsonb_build_object('situacao', a.situacao, 'cliente', a.atlas_cliente_nome, 'automatico', a.aprovado_automatico)
                               from atlas_cadastro a where a.cnj = c.cnj and a.detectado_em is not null),
                'arquivada', case when c.arquivada_em is not null then jsonb_build_object('em', c.arquivada_em, 'motivo', c.arquivada_motivo,
                               'por', (select email from auth.users u where u.id = c.arquivada_por)) end,
                'webjur', (select jsonb_build_object('id', p.id, 'exata', p.id_documento = c.id::text)
                             from publicacoes p
                            where p.id_documento = c.id::text
                               or (p.cnj = c.cnj and p.data_disponibilizacao between c.data_disponibilizacao - v_tol and c.data_disponibilizacao + v_tol
                                   and not exists (select 1 from cnj_comunicacoes c2 where c2.id = public._id_cnj(p.id_documento)))
                            order by (p.id_documento = c.id::text) desc limit 1)) x
         from cnj_comunicacoes c left join cnj_carteira k on k.cnj = c.cnj
        where c.data_disponibilizacao between v_ini and v_fim
          and (c.arquivada_em is not null) = v_arq
          and (v_busca is null or c.cnj ilike '%' || v_busca || '%' or c.texto ilike '%' || v_busca || '%'
               or c.sigla_tribunal ilike v_busca or c.nome_orgao ilike '%' || v_busca || '%')
        order by c.data_disponibilizacao desc, c.id desc
        limit greatest(coalesce(p_limite, 500), 1)) z(x)
       where p_filtro is null or p_filtro in ('', 'arquivadas')
          or (p_filtro = 'sem_webjur' and x->'webjur' = 'null'::jsonb)
          or (p_filtro = 'com_webjur' and x->'webjur' <> 'null'::jsonb)
          or (p_filtro = 'fora_atlas' and not (x->>'no_atlas')::boolean)));
end $$;

-- ---------------------------------------------------------------- diretoria: lista das entregas autorizadas após o D-4 (só leitura)
create or replace function public.excecoes_d4_listar()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if coalesce(_meu_papel(), '') not in ('admin','lider','diretoria') then
    raise exception 'Somente líderes, a controladoria e a diretoria' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(x order by x.em desc) from (
      select u.tarefa_id, u.justificativa, u.ocorrido_em as em, coalesce(c.nome_advbox, us.email) as por,
             t.advbox_id as id_externo, v.compromisso, v.responsavel, v.processo_cnj, v.d4, v.pf_judicial, v.situacao, v.data_conclusao
        from (select distinct on (e.tarefa_id) e.* from eventos e where e.tipo = 'excecao_d4'
               order by e.tarefa_id, e.ocorrido_em desc, e.observado_em desc) u
        join tarefas t on t.id = u.tarefa_id
        left join colaboradores c on c.id = u.colaborador_id
        left join auth.users us on us.id = nullif(u.evidencia->>'usuario', '')::uuid
        left join lateral (select * from v_tarefas_atuais w where w.tarefa_id is not null
                            and _tarefa_principal(w.tarefa_id) = u.tarefa_id limit 1) v on true
       where (u.valor_novo->>'ativa')::boolean) x), '[]'::jsonb);
end $$;

-- ---------------------------------------------------------------- permissões
revoke execute on function public._nome_tokens(text), public._cnj_cadastro_detectar() from public, anon, authenticated;
revoke execute on function public.cnj_arquivar(bigint[], text), public.cnj_desarquivar(bigint[]), public.cnj_cadastro_detectar(),
  public.cnj_cadastro_escolher(text, uuid), public.cnj_nao_cadastrados(text, text, int) from public, anon;
grant execute on function public.cnj_arquivar(bigint[], text), public.cnj_desarquivar(bigint[]), public.cnj_cadastro_detectar(),
  public.cnj_cadastro_escolher(text, uuid), public.cnj_nao_cadastrados(text, text, int) to authenticated;

-- ---------------------------------------------------------------- agendamento: a cada 15 minutos (o robô de cadastro já roda a cada minuto)
do $$
begin
  if to_regclass('cron.job') is null then
    raise notice '0064: pg_cron indisponível neste banco; agendamento não criado.';
    return;
  end if;
  perform cron.unschedule(jobid) from cron.job where jobname = 'controladoria_cnj_cadastro';
  perform cron.schedule('controladoria_cnj_cadastro', '*/15 * * * *', 'select public._cnj_cadastro_detectar()');
end $$;
