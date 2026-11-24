-- =====================================================================
-- 0051 — Painel de audiências (pedido da controladoria, 14/11/2026)
-- Fonte (decisão da controladoria): as intimações do CNJ (cnj_comunicacoes) e da Webjur (publicacoes).
-- O robô lê o texto e extrai a audiência designada: data, hora, tipo, modalidade e link.
-- O painel mostra a agenda por dia e equipe, cobra as pendências (sem data, sem advogado, sem confirmação,
-- sem tarefa no Atlas, sem ata) e registra a ata e o resultado. As pendências entram no double check diário.
-- Equipe: a API do Atlas não informa a equipe (squad) do cliente; vale a letra do código do cliente
-- ("C362" -> Celeste), pelo parâmetro equipes_por_letra (a confirmar com a controladoria).
-- =====================================================================

insert into public.parametros (chave, valor, confirmado, descricao) values
 ('equipes_por_letra', '{"C":"Celeste","P":"Prime","G":"Gold","E":"Êxitos","D":"Delta"}', false,
  'Equipe do cliente pela letra do código do cliente (C362 = Celeste). A API do Atlas não informa a equipe; a confirmar com a controladoria.'),
 ('audiencias_confirmar_dias', '2', true,
  'Audiências: quantos dias úteis antes a audiência precisa estar confirmada (advogado/preposto e cliente avisados).'),
 ('audiencias_tarefa_dias', '20', true,
  'Audiências: a tarefa de audiência no Atlas é procurada com vencimento até este número de dias antes da audiência.')
on conflict (chave) do nothing;

-- ---------------------------------------------------------------- tabelas
create table if not exists public.audiencias (
  id               bigint generated always as identity primary key,
  chave            text not null unique,                   -- cnj|data|hora (ou cnj|sem-data|disponibilização)
  cnj              text not null,
  data             date,                                   -- null = a intimação não trouxe a data (conferir no processo)
  hora             text,                                   -- HH:MI
  tipo             text,
  modalidade       text,                                   -- presencial | virtual | híbrida | null (não informada)
  link             text,
  orgao            text,
  redesignacao     boolean not null default false,
  trecho           text,                                   -- trecho da intimação que designa a audiência
  disponibilizada_em date,                                 -- 1ª intimação que trouxe a audiência
  situacao         text not null default 'agendada' check (situacao in ('agendada','redesignada','cancelada','realizada','nao_realizada')),
  advogado_id      bigint references public.colaboradores(id),
  preposto         text,
  designado_em     timestamptz, designado_por uuid,
  confirmada_em    timestamptz, confirmada_por uuid, confirmacao_obs text,
  resultado        text check (resultado in ('acordo','sem_acordo','redesignada','nao_realizada','realizada_sem_acordo_possivel','instrucao_concluida')),
  ata              text,
  resultado_em     timestamptz, resultado_por uuid,
  corrigida_em     timestamptz, corrigida_por uuid,
  identificada_em  timestamptz not null default now(),
  atualizado_em    timestamptz not null default now()
);
create index if not exists audiencias_data_idx on public.audiencias (data);
create index if not exists audiencias_cnj_idx on public.audiencias (cnj);
alter table public.audiencias enable row level security;
revoke all on public.audiencias from anon, authenticated;

create table if not exists public.audiencia_fontes (
  origem          text not null check (origem in ('cnj','webjur')),
  origem_id       text not null,
  audiencia_id    bigint references public.audiencias(id),
  achou           boolean not null,                        -- false = intimação lida sem audiência designada
  data_disponibilizacao date,
  lida_em         timestamptz not null default now(),
  primary key (origem, origem_id)
);
create index if not exists audiencia_fontes_aud_idx on public.audiencia_fontes (audiencia_id);
alter table public.audiencia_fontes enable row level security;
revoke all on public.audiencia_fontes from anon, authenticated;

create table if not exists public.audiencia_eventos (
  id           bigint generated always as identity primary key,
  audiencia_id bigint references public.audiencias(id),
  em           timestamptz not null default now(),
  usuario      uuid default auth.uid(),
  tipo         text not null check (tipo in ('identificada','nova_fonte','designacao','confirmacao','correcao','resultado','redesignada')),
  detalhe      jsonb not null default '{}'
);
create index if not exists audiencia_eventos_idx on public.audiencia_eventos (audiencia_id, em);
alter table public.audiencia_eventos enable row level security;
revoke all on public.audiencia_eventos from anon, authenticated;
drop trigger if exists audiencia_eventos_imutavel on public.audiencia_eventos;
create trigger audiencia_eventos_imutavel before update or delete on public.audiencia_eventos
  for each row execute function public.tg_bloqueia_alteracao();

-- ---------------------------------------------------------------- leitura do texto (interna)
create or replace function public._texto_norm(p text) returns text language sql immutable as $$
  select regexp_replace(upper(translate(regexp_replace(coalesce(p, ''), '<[^>]+>', ' ', 'g'),
           'áàâãäéèêëíìîïóòôõöúùûüçÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇºª', 'aaaaaeeeeiiiiooooouuuucAAAAAEEEEIIIIOOOOOUUUUCOA')), '\s+', ' ', 'g')
$$;

-- devolve a audiência designada no texto (ou null): {data, hora, tipo, modalidade, link, redesignacao, trecho}
-- p_ref: data de disponibilização; data anterior a ela é data do ato (ex.: "AUDIÊNCIA DESIGNADA (03/11/2026)"), não da audiência
create or replace function public._audiencia_extrair(p_texto text, p_ref date default null) returns jsonb
language plpgsql immutable set search_path = public as $$
declare
  o text := regexp_replace(regexp_replace(coalesce(p_texto, ''), '<[^>]+>', ' ', 'g'), '\s+', ' ', 'g');   -- texto limpo
  t text := _texto_norm(p_texto);                                                                        -- mesmo tamanho, maiúsculo e sem acento
  meses constant text[] := array['JANEIRO','FEVEREIRO','MARCO','ABRIL','MAIO','JUNHO','JULHO','AGOSTO','SETEMBRO','OUTUBRO','NOVEMBRO','DEZEMBRO'];
  pos int := 0; p int; w text; antes text; depois text; m text[]; md text[]; v_data date; v_hora text;
  r jsonb := null; v_tipo text; v_mod text; v_link text; v_amplo text;
begin
  if t = '' or position('AUDIENCIA' in t) = 0 then return null; end if;
  loop
    p := position('AUDIENCIA' in substr(t, pos + 1));
    exit when p = 0;
    pos := pos + p;
    antes := substr(t, greatest(1, pos - 140), least(pos - 1, 140));
    depois := substr(t, pos, 380);
    w := antes || depois;
    -- precisa de um verbo de designação perto da palavra; frases que NÃO designam audiência ficam de fora
    if w !~ '(RE)?DESIGN(O|A-SE|E-SE|ADA|ANDO|ACAO DE)|FICA (RE)?MARCADA|\mMARCO\M|\mAGENDO\M|AGENDADA PARA'
       or substr(t, greatest(1, pos - 40), least(pos - 1, 40)) ~ 'DEIXO DE DESIGNAR( A)?|NAO (HA COMO )?DESIGN|DISPENSO( A)?|INTERESSE NA (REALIZACAO|DESIGNACAO)( DE| DA)?|EVENTUAL|RESULTADO INFRUTIFERO DA|ATA DE|CANCELO( A)?|RETIRO DE PAUTA( A)?|CONVENIENCIA DA'
       or substr(t, pos, 70) ~ 'ANTERIORMENTE DESIGNADA|DESNECESSARIA|CANCELADA|SEM EFEITO|RESTOU PREJUDICADA|FOI REALIZADA|REALIZADA EM|INFRUTIFERA'
    then continue; end if;
    -- data da audiência (depois da palavra): "dia 16/11/2026", "para 16/11/26", "dia 19 de novembro de 2026"
    v_data := null; v_hora := null; md := null;
    m := regexp_match(depois, '(?:DIA|PARA|EM|DATA:?)\s*(\d{1,2})/(\d{1,2})/(\d{4}|\d{2})\M(.{0,70})');
    if m is not null then
      begin v_data := make_date(case when length(m[3]) = 2 then 2000 + m[3]::int else m[3]::int end, m[2]::int, m[1]::int);
      exception when others then v_data := null; end;
      md := array[m[4]];
    else
      m := regexp_match(depois, '(\d{1,2})O? DE (JANEIRO|FEVEREIRO|MARCO|ABRIL|MAIO|JUNHO|JULHO|AGOSTO|SETEMBRO|OUTUBRO|NOVEMBRO|DEZEMBRO) DE (\d{4})(.{0,70})');
      if m is not null then
        begin v_data := make_date(m[3]::int, array_position(meses, m[2]), m[1]::int); exception when others then v_data := null; end;
        md := array[m[4]];
      end if;
    end if;
    if v_data is not null and p_ref is not null and v_data < p_ref then v_data := null; end if;   -- data do ato, não da audiência
    if v_data is not null then   -- hora logo depois da data: "às 08:23", "as 14h30", "às 9 horas"
      m := regexp_match(md[1], '(?:AS|A PARTIR DAS|HORARIO:?|HORA:?|,)\s*(\d{1,2})\s*(?::|H|HORAS?)\s*(\d{2})?');
      if m is not null and m[1]::int between 0 and 23 and coalesce(m[2], '00')::int < 60 then
        v_hora := lpad(m[1], 2, '0') || ':' || coalesce(m[2], '00');
      end if;
    end if;
    -- tipo
    v_tipo := case
      when w ~ 'INSTRUCAO E JULGAMENTO|AUDIENCIA DE INSTRUCAO|AIJ\M' then 'Instrução e julgamento'
      when w ~ 'DEPOIMENTO PESSOAL|OITIVA|TESTEMUNH' then 'Instrução (depoimento/testemunhas)'
      when w ~ 'AUDIENCIA UNA|\mUNA\M' then 'Una'
      when w ~ 'MEDIACAO' then 'Mediação'
      when w ~ 'CONCILIA' then 'Conciliação'
      when w ~ 'JUSTIFICACAO' then 'Justificação'
      when w ~ 'SANEAMENTO' then 'Saneamento'
      when w ~ 'INICIAL' then 'Inicial'
      end;
    -- modalidade (no texto todo perto da audiência)
    v_amplo := substr(t, greatest(1, pos - 300), 1200);
    v_mod := case
      when v_amplo ~ 'HIBRID' then 'híbrida'
      when v_amplo ~ 'VIDEOCONFERENCIA|TELEPRESENCIAL|VIRTUAL|REMOTA|TEAMS|ZOOM|GOOGLE MEET|WEBEX|ACESSO REMOTO' then 'virtual'
      when v_amplo ~ 'PRESENCIAL|COMPARECER (NA|AO|NO) (SALA|FORUM|ESTACAO|AUDITORIO|ENDERECO)|ESTACAO PASSIVA|SALA DE AUDIENCIAS' then 'presencial'
      end;
    select (regexp_match(u[1], '^(.*?)[.,;)]*$'))[1] into v_link
      from regexp_matches(coalesce(p_texto, ''), '(https?://[^\s"<>'']+)', 'g') u
     where u[1] ~* 'teams\.(microsoft|live)|zoom\.us|meet\.google|webex|jit\.si|whereby|videoconf|bit\.ly|tinyurl|link\.cnj|cnj\.jus\.br/.*(sala|video)'
     limit 1;
    r := jsonb_build_object('data', v_data, 'hora', v_hora, 'tipo', v_tipo, 'modalidade', v_mod, 'link', v_link,
                            'redesignacao', w ~ 'REDESIGN|NOVA AUDIENCIA|NOVA DATA', 'trecho', btrim(substr(o, greatest(1, pos - 140), 600)));
    exit when v_data is not null;   -- a 1ª designação com data vale; sem data, continua procurando uma com data
  end loop;
  return r;
end $$;

-- equipe e cliente do processo (interna): cliente do Atlas (carteira ou cadastro) e a letra do código do cliente
create or replace function public._audiencia_cliente_equipe(p_cnj text) returns jsonb
language sql stable security definer set search_path = public as $$
  with c as (
    select coalesce((select atlas_cliente_nome from atlas_cadastro where cnj = p_cnj and atlas_cliente_nome is not null),
                    (select cliente from cnj_carteira where cnj = p_cnj and cliente is not null),
                    (select cliente_advbox from atlas_cadastro where cnj = p_cnj)) nome)
  select jsonb_build_object('cliente', c.nome,
           'equipe', (select valor ->> left(_codigo_cliente(split_part(c.nome, ';', 1)), 1) from parametros where chave = 'equipes_por_letra'))
    from c
$$;

-- lê as intimações ainda não lidas e registra as audiências (interna; chamada pelo agendamento e pelo double check)
create or replace function public._audiencias_ler(p_desde date default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare f record; x jsonb; v_chave text; v_id bigint; v_novo boolean; n_lidas int := 0; n_aud int := 0; n_novas int := 0; ce jsonb;
begin
  for f in
    select 'cnj'::text origem, c.id::text origem_id, c.cnj, c.texto, c.data_disponibilizacao disp, c.nome_orgao orgao
      from cnj_comunicacoes c
     where c.cnj is not null and c.data_disponibilizacao >= coalesce(p_desde, hoje_brasilia() - 60)
       and not exists (select 1 from audiencia_fontes a where a.origem = 'cnj' and a.origem_id = c.id::text)
    union all
    select 'webjur', p.id::text, p.cnj, p.teor, p.data_disponibilizacao, null
      from publicacoes p
     where p.cnj is not null and p.data_disponibilizacao >= coalesce(p_desde, hoje_brasilia() - 60)
       and not exists (select 1 from audiencia_fontes a where a.origem = 'webjur' and a.origem_id = p.id::text)
     order by disp, origem, origem_id
  loop
    n_lidas := n_lidas + 1;
    x := _audiencia_extrair(f.texto, f.disp);
    if x is null then
      insert into audiencia_fontes (origem, origem_id, achou, data_disponibilizacao) values (f.origem, f.origem_id, false, f.disp);
      continue;
    end if;
    n_aud := n_aud + 1;
    v_chave := f.cnj || '|' || coalesce(x->>'data', 'sem-data:' || f.disp) || '|' || coalesce(x->>'hora', '');
    ce := _audiencia_cliente_equipe(f.cnj);
    insert into audiencias (chave, cnj, data, hora, tipo, modalidade, link, orgao, redesignacao, trecho, disponibilizada_em)
    values (v_chave, f.cnj, (x->>'data')::date, x->>'hora', x->>'tipo', x->>'modalidade', x->>'link', f.orgao,
            coalesce((x->>'redesignacao')::boolean, false), x->>'trecho', f.disp)
    on conflict (chave) do update set   -- outra intimação da mesma audiência completa o que faltava
      tipo = coalesce(audiencias.tipo, excluded.tipo), modalidade = coalesce(audiencias.modalidade, excluded.modalidade),
      link = coalesce(audiencias.link, excluded.link), orgao = coalesce(audiencias.orgao, excluded.orgao), atualizado_em = now()
    returning id, (xmax = 0) into v_id, v_novo;
    insert into audiencia_fontes (origem, origem_id, audiencia_id, achou, data_disponibilizacao) values (f.origem, f.origem_id, v_id, true, f.disp);
    insert into audiencia_eventos (audiencia_id, tipo, detalhe)
    values (v_id, case when v_novo then 'identificada' else 'nova_fonte' end, jsonb_build_object('origem', f.origem, 'id', f.origem_id) || (x - 'trecho'));
    if v_novo then
      n_novas := n_novas + 1;
      -- nova data no mesmo processo: as audiências futuras ainda agendadas com outra data passam a "redesignada"
      if (x->>'data') is not null and coalesce((x->>'redesignacao')::boolean, false) then
        with u as (
          update audiencias set situacao = 'redesignada', atualizado_em = now()
           where cnj = f.cnj and id <> v_id and situacao = 'agendada' and data is distinct from (x->>'data')::date
             and (data is null or data >= f.disp)
          returning id)
        insert into audiencia_eventos (audiencia_id, tipo, detalhe) select id, 'redesignada', jsonb_build_object('nova', v_id) from u;
      end if;
    end if;
  end loop;
  return jsonb_build_object('lidas', n_lidas, 'com_audiencia', n_aud, 'novas', n_novas);
end $$;
revoke execute on function public._texto_norm(text), public._audiencia_extrair(text, date), public._audiencia_cliente_equipe(text),
  public._audiencias_ler(date) from public, anon, authenticated;

-- ---------------------------------------------------------------- permissões
-- pode mexer: controladoria; líder das equipes que acompanha; o advogado designado (confirmar e registrar ata)
create or replace function public._audiencia_pode(p_id bigint, p_acao text) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(is_admin(), false)
      or (coalesce(meu_papel() = 'lider', false) and exists (
            select 1 from audiencias a
             where a.id = p_id
               and ((_audiencia_cliente_equipe(a.cnj)->>'equipe') in (select e.nome from lideres_equipes le join equipes e on e.id = le.equipe_id where le.user_id = auth.uid())
                    or a.advogado_id = any(meus_colaboradores()))))
      or (p_acao in ('confirmar','resultado') and exists (
            select 1 from audiencias a where a.id = p_id and a.advogado_id = any(meus_colaboradores())))
$$;
revoke execute on function public._audiencia_pode(bigint, text) from public, anon, authenticated;

create or replace function public.audiencias_ler() returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Somente a controladoria' using errcode = '42501'; end if;
  return _audiencias_ler(null);
end $$;

create or replace function public.audiencia_designar(p_id bigint, p_advogado_id bigint, p_preposto text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not _audiencia_pode(p_id, 'designar') then raise exception 'Somente a controladoria, o líder da equipe ou o advogado designado (designar)' using errcode = '42501'; end if;
  if p_advogado_id is not null and not exists (select 1 from colaboradores where id = p_advogado_id) then raise exception 'Advogado não encontrado'; end if;
  update audiencias set advogado_id = p_advogado_id, preposto = nullif(btrim(coalesce(p_preposto, '')), ''),
         designado_em = now(), designado_por = auth.uid(), atualizado_em = now() where id = p_id;
  insert into audiencia_eventos (audiencia_id, tipo, detalhe) values (p_id, 'designacao', jsonb_build_object('advogado_id', p_advogado_id, 'preposto', p_preposto));
  return jsonb_build_object('id', p_id, 'advogado', (select nome_advbox from colaboradores where id = p_advogado_id));
end $$;

create or replace function public.audiencia_confirmar(p_id bigint, p_obs text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not _audiencia_pode(p_id, 'confirmar') then raise exception 'Somente a controladoria, o líder da equipe ou o advogado designado (confirmar)' using errcode = '42501'; end if;
  if (select advogado_id from audiencias where id = p_id) is null then raise exception 'Designe o advogado antes de confirmar'; end if;
  update audiencias set confirmada_em = now(), confirmada_por = auth.uid(), confirmacao_obs = nullif(btrim(coalesce(p_obs, '')), ''), atualizado_em = now()
   where id = p_id;
  insert into audiencia_eventos (audiencia_id, tipo, detalhe) values (p_id, 'confirmacao', jsonb_build_object('obs', p_obs));
  return jsonb_build_object('id', p_id, 'confirmada', true);
end $$;

-- corrigir/completar data, hora, tipo, modalidade e link (ex.: intimação sem a data); exige justificativa
create or replace function public.audiencia_corrigir(p_id bigint, p_data date, p_hora text, p_tipo text, p_modalidade text, p_link text, p_motivo text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare a audiencias;
begin
  if not _audiencia_pode(p_id, 'corrigir') then raise exception 'Somente a controladoria, o líder da equipe ou o advogado designado (corrigir)' using errcode = '42501'; end if;
  if length(btrim(coalesce(p_motivo, ''))) < 10 then raise exception 'Informe o motivo da correção (mínimo 10 caracteres)'; end if;
  if p_hora is not null and p_hora !~ '^([01]\d|2[0-3]):[0-5]\d$' then raise exception 'Hora no formato HH:MM'; end if;
  if p_modalidade is not null and p_modalidade not in ('presencial','virtual','híbrida') then raise exception 'Modalidade inválida'; end if;
  select * into a from audiencias where id = p_id for update;
  update audiencias set data = p_data, hora = p_hora, tipo = coalesce(nullif(btrim(p_tipo), ''), tipo), modalidade = p_modalidade,
         link = nullif(btrim(coalesce(p_link, '')), ''), corrigida_em = now(), corrigida_por = auth.uid(), atualizado_em = now()
   where id = p_id;
  insert into audiencia_eventos (audiencia_id, tipo, detalhe) values (p_id, 'correcao', jsonb_build_object('motivo', p_motivo,
     'antes', jsonb_build_object('data', a.data, 'hora', a.hora, 'tipo', a.tipo, 'modalidade', a.modalidade, 'link', a.link),
     'depois', jsonb_build_object('data', p_data, 'hora', p_hora, 'tipo', p_tipo, 'modalidade', p_modalidade, 'link', p_link)));
  return jsonb_build_object('id', p_id);
end $$;

create or replace function public.audiencia_registrar_resultado(p_id bigint, p_resultado text, p_ata text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a audiencias;
begin
  if not _audiencia_pode(p_id, 'resultado') then raise exception 'Somente a controladoria, o líder da equipe ou o advogado designado (resultado)' using errcode = '42501'; end if;
  select * into a from audiencias where id = p_id for update;
  if a.data is null or a.data > hoje_brasilia() then raise exception 'O resultado só pode ser registrado no dia da audiência ou depois'; end if;
  if p_resultado not in ('acordo','sem_acordo','redesignada','nao_realizada','instrucao_concluida') then raise exception 'Resultado inválido'; end if;
  if length(btrim(coalesce(p_ata, ''))) < 20 then raise exception 'Descreva o que aconteceu na audiência (mínimo 20 caracteres)'; end if;
  update audiencias set resultado = p_resultado, ata = btrim(p_ata), resultado_em = now(), resultado_por = auth.uid(),
         situacao = case p_resultado when 'redesignada' then 'redesignada' when 'nao_realizada' then 'nao_realizada' else 'realizada' end,
         atualizado_em = now()
   where id = p_id;
  insert into audiencia_eventos (audiencia_id, tipo, detalhe) values (p_id, 'resultado', jsonb_build_object('resultado', p_resultado, 'ata', left(p_ata, 2000),
     'resultado_anterior', a.resultado));
  return jsonb_build_object('id', p_id, 'resultado', p_resultado);
end $$;

-- ---------------------------------------------------------------- pendências (interna) e painel
create or replace function public._audiencia_pendencias(a audiencias) returns text[]
language sql stable security definer set search_path = public as $$
  select array_remove(array[
    case when a.situacao = 'agendada' and a.data is null then 'sem_data' end,
    case when a.situacao = 'agendada' and (a.data is null or a.data >= hoje_brasilia()) and a.advogado_id is null then 'sem_advogado' end,
    case when a.situacao = 'agendada' and a.data >= hoje_brasilia() and a.confirmada_em is null
              and a.data <= somar_dias_uteis(hoje_brasilia(), param_int('audiencias_confirmar_dias')) then 'sem_confirmacao' end,
    case when a.situacao = 'agendada' and a.data >= hoje_brasilia() and not exists (
           select 1 from v_tarefas_atuais t
            where concat_ws(' ', t.compromisso, t.observacoes) ~* 'audi[eê]ncia'
              and (t.processo_cnj = a.cnj
                   or concat_ws(' ', t.compromisso, t.observacoes, t.partes) like '%' || a.cnj || '%'
                   or regexp_replace(concat_ws(' ', t.compromisso, t.observacoes), '\D', '', 'g') like '%' || regexp_replace(a.cnj, '\D', '', 'g') || '%')
              and coalesce(t.d7_data_agenda, t.pf_tarefa) between a.data - param_int('audiencias_tarefa_dias') and a.data) then 'sem_tarefa_atlas' end,
    case when a.situacao = 'agendada' and a.data < hoje_brasilia() and a.resultado is null then 'sem_ata' end
  ], null)
$$;
revoke execute on function public._audiencia_pendencias(audiencias) from public, anon, authenticated;

create or replace function public.audiencias_painel(p_inicio date default null, p_fim date default null, p_equipe text default null,
                                                     p_pendencia text default null, p_busca text default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_ini date := coalesce(p_inicio, hoje_brasilia() - 7); v_fim date := coalesce(p_fim, hoje_brasilia() + 60);
        v_busca text := nullif(btrim(coalesce(p_busca, '')), ''); v_papel text := meu_papel(); v_eqs text[]; v_colabs bigint[];
begin
  if v_papel is null then raise exception 'Somente usuários do painel' using errcode = '42501'; end if;
  v_colabs := meus_colaboradores();
  select coalesce(array_agg(e.nome), '{}') into v_eqs from lideres_equipes le join equipes e on e.id = le.equipe_id where le.user_id = auth.uid();
  return (
    with base as (
      select a.*, ce->>'cliente' cliente, ce->>'equipe' equipe, _audiencia_pendencias(a) pend
        from audiencias a cross join lateral (select _audiencia_cliente_equipe(a.cnj) ce) z
       where (a.data between v_ini and v_fim or (a.data is null and a.disponibilizada_em >= v_ini - 30)
              or (a.situacao = 'agendada' and a.data < hoje_brasilia() and a.resultado is null))   -- sem ata não some da tela
         and (v_busca is null or a.cnj ilike '%' || v_busca || '%' or a.trecho ilike '%' || v_busca || '%')),
    vis as (
      select b.* from base b
       where pode_ler_tudo() or b.advogado_id = any(v_colabs) or (v_papel = 'lider' and b.equipe = any(v_eqs))),
    filt as (
      select v.* from vis v
       where (p_equipe is null or coalesce(v.equipe, 'Sem equipe') = p_equipe)
         and (p_pendencia is null or p_pendencia = any(v.pend)))
    select jsonb_build_object(
      'periodo', jsonb_build_object('de', v_ini, 'ate', v_fim),
      'contagem', jsonb_build_object(
         'proximos_7', (select count(*) from vis where situacao = 'agendada' and data between hoje_brasilia() and hoje_brasilia() + 7),
         'sem_data', (select count(*) from vis where 'sem_data' = any(pend)),
         'sem_advogado', (select count(*) from vis where 'sem_advogado' = any(pend)),
         'sem_confirmacao', (select count(*) from vis where 'sem_confirmacao' = any(pend)),
         'sem_tarefa_atlas', (select count(*) from vis where 'sem_tarefa_atlas' = any(pend)),
         'sem_ata', (select count(*) from vis where 'sem_ata' = any(pend))),
      'equipes', (select coalesce(jsonb_agg(distinct coalesce(equipe, 'Sem equipe')), '[]') from vis),
      'pode_editar', is_admin() or coalesce(v_papel = 'lider', false),
      'ultima_leitura', (select max(lida_em) from audiencia_fontes),
      'itens', (select coalesce(jsonb_agg(jsonb_build_object(
          'id', f.id, 'cnj', f.cnj, 'data', f.data, 'hora', f.hora, 'tipo', f.tipo, 'modalidade', f.modalidade, 'link', f.link,
          'orgao', f.orgao, 'situacao', f.situacao, 'cliente', f.cliente, 'equipe', f.equipe, 'trecho', f.trecho,
          'disponibilizada_em', f.disponibilizada_em, 'redesignacao', f.redesignacao,
          'advogado_id', f.advogado_id, 'advogado', (select nome_advbox from colaboradores where id = f.advogado_id), 'preposto', f.preposto,
          'confirmada_em', f.confirmada_em, 'confirmacao_obs', f.confirmacao_obs,
          'resultado', f.resultado, 'ata', f.ata, 'resultado_em', f.resultado_em, 'pendencias', f.pend,
          'pode_editar', _audiencia_pode(f.id, 'corrigir'), 'pode_ata', _audiencia_pode(f.id, 'resultado'),
          'fontes', (select jsonb_agg(jsonb_build_object('origem', s.origem, 'id', s.origem_id, 'disp', s.data_disponibilizacao,
                       'link', case when s.origem = 'cnj' then (select link from cnj_comunicacoes where id = s.origem_id::bigint) end))
                       from audiencia_fontes s where s.audiencia_id = f.id))
          order by f.data nulls first, f.hora nulls last, f.cnj), '[]') from filt f)));
end $$;

create or replace function public.audiencias_advogados() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not (is_admin() or coalesce(meu_papel() = 'lider', false)) then raise exception 'Somente a controladoria ou o líder' using errcode = '42501'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'nome', nome_advbox, 'no_atlas', atlas_user_id is not null)
                                    order by atlas_user_id is null, nome_advbox), '[]') from colaboradores);
end $$;

revoke execute on function public.audiencias_ler(), public.audiencia_designar(bigint, bigint, text), public.audiencia_confirmar(bigint, text),
  public.audiencia_corrigir(bigint, date, text, text, text, text, text), public.audiencia_registrar_resultado(bigint, text, text),
  public.audiencias_painel(date, date, text, text, text), public.audiencias_advogados() from public, anon;
grant execute on function public.audiencias_ler(), public.audiencia_designar(bigint, bigint, text), public.audiencia_confirmar(bigint, text),
  public.audiencia_corrigir(bigint, date, text, text, text, text, text), public.audiencia_registrar_resultado(bigint, text, text),
  public.audiencias_painel(date, date, text, text, text), public.audiencias_advogados() to authenticated;

-- ---------------------------------------------------------------- double check
alter table public.inconsistencias drop constraint if exists inconsistencias_tipo_check;
alter table public.inconsistencias add constraint inconsistencias_tipo_check check (tipo in
  ('intimacao_nao_cadastrada','divergencia','prazo_nao_lancado','prazo_incorreto','publicacao_duplicada','pendencia_controladoria',
   'captura_divergente','audiencia_pendente'));

create or replace function public._dc_audiencias(p_dia date) returns void
language plpgsql security definer set search_path = public as $$
declare f constant text := 'DD/MM/YYYY';
begin
  perform _audiencias_ler(p_dia - 60);
  insert into _inc
  select 'audiencia|' || a.id || '|' || p, 'audiencia_pendente',
         case p when 'sem_data' then 2 when 'sem_tarefa_atlas' then case when a.data <= p_dia + 7 then 1 else 2 end
                when 'sem_advogado' then case when a.data <= p_dia + 7 then 1 else 2 end when 'sem_confirmacao' then 1 else 3 end,
         coalesce(a.data, a.disponibilizada_em), a.cnj, null, null, null,
         case p
           when 'sem_data' then 'Audiência designada sem data na intimação (' || coalesce(a.tipo, 'tipo não informado') || ').'
           when 'sem_tarefa_atlas' then 'Audiência de ' || to_char(a.data, f) || coalesce(' às ' || a.hora, '') || ' sem tarefa de audiência no Atlas.'
           when 'sem_advogado' then 'Audiência de ' || coalesce(to_char(a.data, f), 'data a confirmar') || ' sem advogado designado.'
           when 'sem_confirmacao' then 'Audiência de ' || to_char(a.data, f) || coalesce(' às ' || a.hora, '') || ' ainda não confirmada.'
           else 'Audiência de ' || to_char(a.data, f) || ' sem ata/resultado registrado.' end,
         case p
           when 'sem_data' then 'Conferir a data no processo e completar no painel Audiências.'
           when 'sem_tarefa_atlas' then 'Criar a tarefa da audiência no Atlas (com o número do processo).'
           when 'sem_advogado' then 'Designar o advogado/preposto no painel Audiências.'
           when 'sem_confirmacao' then 'Confirmar com o advogado e o cliente e marcar no painel Audiências.'
           else 'Registrar a ata e o resultado no painel Audiências.' end,
         jsonb_build_object('audiencia_id', a.id, 'pendencia', p, 'data', a.data, 'hora', a.hora, 'tipo', a.tipo)
    from audiencias a cross join lateral unnest(_audiencia_pendencias(a)) p
  on conflict (chave) do nothing;
end $$;
revoke execute on function public._dc_audiencias(date) from public, anon, authenticated;

do $$
declare d text;
begin
  d := pg_get_functiondef('public.double_check_atlas_executar(date, text)'::regprocedure);
  if position('-- 0051 audiencias' in d) > 0 then return; end if;
  if position('  perform public._dc_cnj(v_ini, v_dia, v_tol);   -- 0044 cnj' in d) = 0 then
    raise exception '0051: âncora do double_check_atlas_executar não encontrada';
  end if;
  d := replace(d, '  perform public._dc_cnj(v_ini, v_dia, v_tol);   -- 0044 cnj',
               '  perform public._dc_cnj(v_ini, v_dia, v_tol);   -- 0044 cnj' || chr(10) ||
               '  perform public._dc_audiencias(v_dia);   -- 0051 audiencias');
  execute d;
end $$;

-- ---------------------------------------------------------------- agendamento: lê as intimações novas a cada hora (só banco)
do $$
begin
  if to_regclass('cron.job') is null then
    raise notice '0051: pg_cron indisponível neste banco; agendamento não criado.';
    return;
  end if;
  execute $x$select cron.unschedule(jobid) from cron.job where jobname = 'controladoria_audiencias'$x$;
  execute $x$select cron.schedule('controladoria_audiencias', '15 * * * *', 'select public._audiencias_ler(null)')$x$;
end $$;
