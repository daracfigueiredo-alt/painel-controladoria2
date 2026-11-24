-- =====================================================================
-- 0008 — Novas estruturas (Etapa 2 do Prompt Mestre). Migração ADITIVA.
--  1. Processos (CNJ normalizado, dígito verificador, foro de origem)
--  2. Equipes
--  3. Calendário por foro (feriados municipais) e regras de dias úteis por foro
--  4. Publicações Webjur, conferências (double check) e tarefas de análise
--  5. Log de integração
--  6. Conferência de alertas (ex.: PF Judicial vencido = pendência de conferência)
--  7. Relatório diário do double check
-- Regras ainda não validadas ficam em `parametros` com confirmado = false.
-- =====================================================================

-- ---------------------------------------------------------------- eventos
alter table public.eventos drop constraint if exists eventos_tipo_check;
alter table public.eventos add constraint eventos_tipo_check check (tipo in (
  'encaminhamento','anotacao_realocacao','pedido_reagendamento','alteracao_data_agenda',
  'alteracao_pf_tarefa','alteracao_responsavel','conclusao','inicio_tratativa',
  'tentativa_conclusao','tentativa_realocacao','tentativa_alteracao_pf','importacao',
  'unificacao_tarefa',
  'publicacao_recebida','publicacao_conferida','tarefa_analise_status','erro_integracao',
  'conferencia_alerta','cadastro_administrativo'));
alter table public.eventos drop constraint if exists eventos_origem_check;
alter table public.eventos add constraint eventos_origem_check check (origem in (
  'excel_campo','excel_observacoes','comparacao_importacoes','extensao','sistema','administrativo',
  'webjur_portal','webjur_gmail'));

-- ---------------------------------------------------------------- parâmetros
insert into public.parametros (chave, valor, confirmado, descricao) values
 ('tarefa_analise_responsavel', '"Mayra Gomes"', true,
  'Responsável pelas tarefas de análise de publicação não capturada pelo ADVBOX (Prompt Mestre §18).'),
 ('tarefa_analise_tipo', '"análise do caso"', false,
  'Tipo da tarefa de análise. A grafia exata do tipo no ADVBOX ainda precisa ser conferida na tela real.'),
 ('tarefa_analise_data_regra', '"data_conferencia"', false,
  'Data da tarefa de análise: data_conferencia | proximo_dia_util. PENDENTE (Prompt Mestre, pendência 9).'),
 ('webjur_fonte_principal', '"indefinida"', false,
  'Fonte principal das publicações: portal | gmail. PENDENTE até a comparação com exemplos reais (pendência 7).'),
 ('advbox_area_conferencia', '"indefinida"', false,
  'Área do ADVBOX que comprova a captura: publicacoes | movimentacoes. PENDENTE (pendência 8).')
on conflict (chave) do nothing;

-- =====================================================================
-- 1. PROCESSOS
-- =====================================================================
-- "0000001-00.2026.8.13.0001", "00000010020268130001" ou com espaços -> formato CNJ; senão null.
create or replace function public.normalizar_cnj(p text) returns text
language sql immutable as $$
  select case when d ~ '^\d{20}$' then
    substr(d,1,7)||'-'||substr(d,8,2)||'.'||substr(d,10,4)||'.'||substr(d,14,1)||'.'||substr(d,15,2)||'.'||substr(d,17,4) end
  from (select regexp_replace(coalesce(p,''), '\D', '', 'g') as d) x
$$;

-- Dígito verificador (Res. CNJ 65/2008, ISO 7064 mód 97-10).
create or replace function public.cnj_digito_valido(p text) returns boolean
language sql immutable as $$
  select case when n is null then null else
    (98 - ((substr(d,1,7)||substr(d,10,11))::numeric * 100 % 97))::int = substr(d,8,2)::int end
  from (select public.normalizar_cnj(p) as n, regexp_replace(coalesce(p,''), '\D', '', 'g') as d) x
$$;

create or replace function public.foro_do_cnj(p text) returns text
language sql immutable as $$ select right(public.normalizar_cnj(p), 4) $$;

create table public.processos (
  id                 bigint generated always as identity primary key,
  cnj                text not null unique check (cnj = public.normalizar_cnj(cnj)),
  tribunal_cnj       text generated always as (public.tribunal_do_cnj(cnj)) stored,
  foro_cnj           text generated always as (right(cnj, 4)) stored,
  cnj_digito_valido  boolean not null,
  advbox_lawsuit_id  text unique,             -- lawsuits/{id} visto na tela (extensão), quando houver
  origem             text not null check (origem in ('excel_importacao','webjur','extensao')),
  primeira_vez_visto timestamptz not null default now()
);

create or replace function public._registrar_processos(p_lote bigint, p_origem text default 'excel_importacao')
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  insert into processos (cnj, cnj_digito_valido, origem)
  select distinct normalizar_cnj(l.processo_cnj), cnj_digito_valido(l.processo_cnj), p_origem
    from linhas_importadas l
   where l.lote_id = p_lote and l.situacao = 'valida' and normalizar_cnj(l.processo_cnj) is not null
  on conflict (cnj) do nothing;
  get diagnostics n = row_count;
  return n;
end $$;
-- processos das importações já feitas
do $$ declare r record; begin
  for r in select distinct lote_id from public.linhas_importadas loop perform public._registrar_processos(r.lote_id); end loop;
end $$;

-- =====================================================================
-- 2. EQUIPES
-- =====================================================================
create table public.equipes (
  id        bigint generated always as identity primary key,
  nome      text not null unique,
  criado_em timestamptz not null default now()
);
alter table public.colaboradores add column if not exists equipe_id bigint references public.equipes(id);

create or replace function public.admin_definir_equipe(p_colaborador bigint, p_equipe text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_eq bigint; v_ant bigint;
begin
  if not is_admin() then raise exception 'Somente administradores' using errcode = '42501'; end if;
  if nullif(btrim(p_equipe),'') is null then raise exception 'Nome da equipe obrigatório'; end if;
  insert into equipes (nome) values (btrim(p_equipe)) on conflict (nome) do nothing;
  select id into v_eq from equipes where nome = btrim(p_equipe);
  select equipe_id into v_ant from colaboradores where id = p_colaborador;
  if not found then raise exception 'Colaborador % inexistente', p_colaborador; end if;
  update colaboradores set equipe_id = v_eq where id = p_colaborador;
  insert into eventos (chave_dedupe, tipo, ocorrido_em, precisao_ocorrido, colaborador_id, valor_anterior, valor_novo,
                       origem, historico_recuperado, classificacao, evidencia)
  values ('adm:'||gen_random_uuid(), 'cadastro_administrativo', now(), 'segundo', p_colaborador,
          to_jsonb(v_ant), to_jsonb(v_eq), 'administrativo', false, 'confirmado',
          jsonb_build_object('operacao','definir_equipe','equipe',btrim(p_equipe),'usuario',auth.uid()));
  return jsonb_build_object('colaborador_id', p_colaborador, 'equipe_id', v_eq);
end $$;

-- =====================================================================
-- 3. CALENDÁRIO POR FORO (feriados municipais/locais)
-- Feriado estadual = cadastrado no tribunal estadual (abrangência tribunal).
-- Feriado municipal = abrangência foro (tribunal + código de origem OOOO do CNJ).
-- =====================================================================
alter table public.calendario_dias_nao_uteis add column if not exists foro_cnj text;
alter table public.calendario_dias_nao_uteis drop constraint if exists calendario_dias_nao_uteis_abrangencia_check;
alter table public.calendario_dias_nao_uteis drop constraint if exists calendario_dias_nao_uteis_check;
alter table public.calendario_dias_nao_uteis add constraint calendario_abrangencia_check check (
     (abrangencia = 'nacional' and tribunal_cnj is null and foro_cnj is null)
  or (abrangencia = 'tribunal' and tribunal_cnj ~ '^\d\.\d{2}$' and foro_cnj is null)
  or (abrangencia = 'foro'     and tribunal_cnj ~ '^\d\.\d{2}$' and foro_cnj ~ '^\d{4}$'));
drop index if exists public.calendario_unq;
create unique index calendario_unq
  on public.calendario_dias_nao_uteis (data, abrangencia, coalesce(tribunal_cnj,''), coalesce(foro_cnj,''));

create or replace function public.e_dia_util(p_data date, p_tribunal text, p_foro text)
returns boolean language sql stable as $$
  select extract(isodow from p_data) < 6
     and not exists (
       select 1 from public.calendario_dias_nao_uteis c
        where c.data = p_data
          and c.tipo in ('feriado','recesso','suspensao')
          and (c.abrangencia = 'nacional'
               or (c.abrangencia = 'tribunal' and c.tribunal_cnj = p_tribunal)
               or (c.abrangencia = 'foro' and c.tribunal_cnj = p_tribunal and c.foro_cnj = p_foro)))
$$;
create or replace function public.e_dia_util(p_data date, p_tribunal text default null)
returns boolean language sql stable as $$ select public.e_dia_util(p_data, p_tribunal, null::text) $$;

create or replace function public.somar_dias_uteis(p_data date, p_n int, p_tribunal text, p_foro text)
returns date language plpgsql stable as $$
declare d date := p_data; passo int := sign(p_n); faltam int := abs(p_n);
begin
  if p_data is null or p_n is null then return null; end if;
  while faltam > 0 loop
    d := d + passo;
    if public.e_dia_util(d, p_tribunal, p_foro) then faltam := faltam - 1; end if;
  end loop;
  return d;
end $$;
create or replace function public.somar_dias_uteis(p_data date, p_n int, p_tribunal text default null)
returns date language sql stable as $$ select public.somar_dias_uteis(p_data, p_n, p_tribunal, null::text) $$;

create or replace function public.dias_uteis_entre(a date, b date, p_tribunal text, p_foro text)
returns int language sql stable as $$
  select case when a is null or b is null then null
              when b >= a then (select count(*)::int from generate_series(a + 1, b, interval '1 day') g
                                 where public.e_dia_util(g::date, p_tribunal, p_foro))
              else -(select count(*)::int from generate_series(b + 1, a, interval '1 day') g
                      where public.e_dia_util(g::date, p_tribunal, p_foro)) end
$$;
create or replace function public.dias_uteis_entre(a date, b date, p_tribunal text default null)
returns int language sql stable as $$ select public.dias_uteis_entre(a, b, p_tribunal, null::text) $$;

-- REGRA CENTRAL D-4/D-7 — continua única; agora aceita o foro.
create or replace function public.calcular_d4(p_pf_judicial date, p_tribunal text, p_foro text)
returns date language sql stable as $$
  select public.somar_dias_uteis(p_pf_judicial, -public.param_int('d4_dias_uteis_antes_pf'), p_tribunal, p_foro)
$$;
create or replace function public.calcular_d4(p_pf_judicial date, p_tribunal text default null)
returns date language sql stable as $$ select public.calcular_d4(p_pf_judicial, p_tribunal, null::text) $$;
create or replace function public.calcular_d7_conferencia(p_pf_judicial date, p_tribunal text, p_foro text)
returns date language sql stable as $$
  select public.somar_dias_uteis(p_pf_judicial, -public.param_int('d7_dias_uteis_antes_pf'), p_tribunal, p_foro)
$$;
create or replace function public.calcular_d7_conferencia(p_pf_judicial date, p_tribunal text default null)
returns date language sql stable as $$ select public.calcular_d7_conferencia(p_pf_judicial, p_tribunal, null::text) $$;

create or replace function public.admin_cadastrar_dia_nao_util(
  p_data date, p_abrangencia text, p_tipo text, p_descricao text, p_fundamento text,
  p_tribunal text default null, p_foro text default null)
returns bigint language plpgsql security definer set search_path = public as $$
declare v_id bigint;
begin
  if not is_admin() then raise exception 'Somente administradores' using errcode = '42501'; end if;
  if nullif(btrim(p_fundamento),'') is null then raise exception 'Informe o fundamento (lei, portaria ou ato)'; end if;
  insert into calendario_dias_nao_uteis (data, abrangencia, tribunal_cnj, foro_cnj, tipo, descricao, fundamento, criado_por)
  values (p_data, p_abrangencia, p_tribunal, p_foro, p_tipo, p_descricao, p_fundamento, auth.uid())
  returning id into v_id;
  insert into eventos (chave_dedupe, tipo, ocorrido_em, precisao_ocorrido, origem, historico_recuperado, classificacao, valor_novo, evidencia)
  values ('adm:'||gen_random_uuid(), 'cadastro_administrativo', now(), 'segundo', 'administrativo', false, 'confirmado',
          jsonb_build_object('data',p_data,'abrangencia',p_abrangencia,'tribunal',p_tribunal,'foro',p_foro,'tipo',p_tipo),
          jsonb_build_object('operacao','cadastrar_dia_nao_util','calendario_id',v_id,'fundamento',p_fundamento,'usuario',auth.uid()));
  return v_id;
end $$;

-- =====================================================================
-- 4. PUBLICAÇÕES WEBJUR, DOUBLE CHECK E TAREFAS DE ANÁLISE
-- =====================================================================
-- Teor normalizado para comparação (o original é guardado sem alteração).
create or replace function public.normalizar_teor(p text) returns text
language sql immutable as $$ select btrim(regexp_replace(lower(coalesce(p,'')), '\s+', ' ', 'g')) $$;

create table public.publicacoes (
  id                    bigint generated always as identity primary key,
  fornecedor            text not null default 'webjur',
  cnj_original          text,
  cnj                   text,                 -- normalizado; null se o número não tem 20 dígitos
  cnj_digito_valido     boolean,
  processo_id           bigint references public.processos(id),
  data_disponibilizacao date,
  data_publicacao       date,
  tribunal              text,
  orgao_julgador        text,
  teor                  text not null check (btrim(teor) <> ''),
  teor_hash             text not null,        -- md5 do teor normalizado
  resumo                text,
  url_origem            text,
  conteudo_original     jsonb not null,       -- registro bruto recebido (auditoria)
  -- Chave de duplicidade: CNJ + data + conteúdo. Publicações diferentes do
  -- mesmo processo e da mesma data têm teor diferente e NÃO se fundem.
  chave_dedupe          text not null unique,
  registrada_em         timestamptz not null default now(),
  registrada_por        uuid
);
create index on public.publicacoes (cnj);
create index on public.publicacoes (data_publicacao);

-- Cada vez que a publicação foi vista em uma fonte (portal, Gmail). A mesma
-- publicação vista nas duas fontes gera 1 publicação e 2 coletas.
create table public.publicacoes_coletas (
  id             bigint generated always as identity primary key,
  publicacao_id  bigint not null references public.publicacoes(id),
  origem         text not null check (origem in ('webjur_portal','webjur_gmail','manual')),
  id_origem      text,                         -- id no portal ou id da mensagem no Gmail
  recebido_em    timestamptz,                  -- data/hora do e-mail ou da listagem, se exibida
  coletado_em    timestamptz not null default now(),
  coletado_por   uuid,
  unique (origem, id_origem)
);

create table public.conferencias_publicacao (
  id                 bigint generated always as identity primary key,
  publicacao_id      bigint not null references public.publicacoes(id),
  situacao           text not null check (situacao in (
                       'encontrada_advbox','nao_encontrada_advbox','processo_nao_cadastrado',
                       'inconclusiva','conferencia_manual','erro_coleta','erro_acesso_advbox')),
  area_conferida     text not null check (area_conferida in ('publicacoes','movimentacoes','ambas','nenhuma')),
  advbox_processo_id text,
  evidencia          jsonb not null,
  origem             text not null check (origem in ('extensao','manual')),
  realizada_em       timestamptz not null default now(),
  realizada_por      uuid,
  -- "Encontrada" exige a publicação ESPECÍFICA no ADVBOX, não só o processo.
  check (situacao <> 'encontrada_advbox' or (evidencia ? 'publicacao_advbox' and area_conferida <> 'nenhuma')),
  -- erro de acesso/coleta não é ausência de publicação
  check (situacao not in ('erro_acesso_advbox','erro_coleta') or evidencia ? 'erro')
);
create index on public.conferencias_publicacao (publicacao_id, realizada_em desc);

create table public.tarefas_analise (
  id                 bigint generated always as identity primary key,
  publicacao_id      bigint not null unique references public.publicacoes(id),  -- 1 tarefa por publicação
  processo_id        bigint references public.processos(id),
  cnj                text,
  requer_cadastro    boolean not null,         -- processo não cadastrado no ADVBOX
  tipo               text not null,
  responsavel        text not null,
  observacoes        text not null,
  data_prevista      date,
  status             text not null check (status in (
                       'preparada','aprovada','rejeitada','conferencia_manual','ja_tratada',
                       'criacao_em_andamento','verificar_no_advbox','criada')),
  advbox_tarefa_id   text unique,
  criada_no_advbox_em timestamptz,
  preparada_em       timestamptz not null default now(),
  atualizada_em      timestamptz not null default now()
);

create table public.tarefas_analise_historico (
  id               bigint generated always as identity primary key,
  tarefa_analise_id bigint not null references public.tarefas_analise(id),
  status_anterior  text,
  status_novo      text not null,
  nota             text,
  evidencia        jsonb not null default '{}',
  por              uuid,
  em               timestamptz not null default now()
);

-- =====================================================================
-- 5. LOG DE INTEGRAÇÃO
-- =====================================================================
create table public.log_integracao (
  id          bigint generated always as identity primary key,
  ocorrido_em timestamptz not null default now(),
  origem      text not null check (origem in ('advbox_extensao','webjur_portal','webjur_gmail','importacao_excel','sistema')),
  nivel       text not null check (nivel in ('info','aviso','erro')),
  operacao    text not null,
  mensagem    text not null,
  detalhe     jsonb not null default '{}',
  usuario     uuid
);
create index on public.log_integracao (ocorrido_em desc);

-- =====================================================================
-- 6. CONFERÊNCIA DE ALERTAS
-- =====================================================================
create table public.conferencias_alerta (
  id         bigint generated always as identity primary key,
  linha_id   bigint not null references public.linhas_importadas(id),
  tarefa_id  bigint references public.tarefas(id),
  categoria  text not null,
  resultado  text not null check (resultado in (
               'em_analise','procedente','providencia_em_outra_tarefa','dado_incorreto_no_advbox','outro')),
  nota       text not null check (length(btrim(nota)) >= 10),
  por        uuid,
  em         timestamptz not null default now()
);
create index on public.conferencias_alerta (linha_id, categoria, em desc);

-- imutabilidade (append-only)
create trigger publicacoes_imutavel before update or delete on public.publicacoes
  for each row execute function public.tg_bloqueia_alteracao();
create trigger coletas_imutavel before update or delete on public.publicacoes_coletas
  for each row execute function public.tg_bloqueia_alteracao();
create trigger conferencias_pub_imutavel before update or delete on public.conferencias_publicacao
  for each row execute function public.tg_bloqueia_alteracao();
create trigger analise_hist_imutavel before update or delete on public.tarefas_analise_historico
  for each row execute function public.tg_bloqueia_alteracao();
create trigger log_integracao_imutavel before update or delete on public.log_integracao
  for each row execute function public.tg_bloqueia_alteracao();
create trigger conferencias_alerta_imutavel before update or delete on public.conferencias_alerta
  for each row execute function public.tg_bloqueia_alteracao();
create trigger tarefas_analise_sem_delete before delete on public.tarefas_analise
  for each row execute function public.tg_bloqueia_alteracao();

-- ---------------------------------------------------------------- funções: publicações
create or replace function public.registrar_log_integracao(
  p_origem text, p_nivel text, p_operacao text, p_mensagem text, p_detalhe jsonb default '{}')
returns bigint language plpgsql security definer set search_path = public as $$
declare v_id bigint;
begin
  if not exists (select 1 from perfis where user_id = auth.uid()) then
    raise exception 'Usuário sem perfil na controladoria' using errcode = '42501';
  end if;
  insert into log_integracao (origem, nivel, operacao, mensagem, detalhe, usuario)
  values (p_origem, p_nivel, p_operacao, p_mensagem, coalesce(p_detalhe,'{}'), auth.uid()) returning id into v_id;
  if p_nivel = 'erro' then
    insert into eventos (chave_dedupe, tipo, ocorrido_em, precisao_ocorrido, origem, historico_recuperado, classificacao, evidencia)
    values ('log:'||v_id, 'erro_integracao', now(), 'segundo', 'sistema', false, 'confirmado',
            jsonb_build_object('log_id',v_id,'origem',p_origem,'operacao',p_operacao,'mensagem',p_mensagem));
  end if;
  return v_id;
end $$;

-- Registra uma publicação coletada (idempotente). Campos aceitos em p_pub:
-- cnj, data_disponibilizacao, data_publicacao (dd/mm/aaaa ou aaaa-mm-dd), tribunal,
-- orgao_julgador, teor, resumo, url_origem, recebido_em. O objeto inteiro é guardado.
create or replace function public.pub_registrar(p_pub jsonb, p_origem text, p_id_origem text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_cnj text; v_teor text; v_dpub date; v_ddisp date; v_chave text; v_id bigint; v_proc bigint;
        v_nova boolean := false; v_coleta boolean;
begin
  if not is_admin() then raise exception 'Somente a controladoria registra publicações' using errcode = '42501'; end if;
  if p_origem not in ('webjur_portal','webjur_gmail','manual') then raise exception 'Origem inválida: %', p_origem; end if;
  v_teor := p_pub->>'teor';
  if nullif(btrim(coalesce(v_teor,'')),'') is null then
    perform registrar_log_integracao(p_origem, 'erro', 'pub_registrar', 'Publicação sem teor; não registrada.',
                                     jsonb_build_object('id_origem', p_id_origem, 'recebido', p_pub));
    return jsonb_build_object('status','rejeitada','motivo','teor_ausente');
  end if;
  begin
    v_dpub  := coalesce(_dt_tela(p_pub->>'data_publicacao'), (nullif(p_pub->>'data_publicacao',''))::date);
    v_ddisp := coalesce(_dt_tela(p_pub->>'data_disponibilizacao'), (nullif(p_pub->>'data_disponibilizacao',''))::date);
  exception when others then
    perform registrar_log_integracao(p_origem, 'erro', 'pub_registrar', 'Data inválida na publicação.',
                                     jsonb_build_object('id_origem', p_id_origem, 'recebido', p_pub));
    return jsonb_build_object('status','rejeitada','motivo','data_invalida');
  end;
  v_cnj := normalizar_cnj(p_pub->>'cnj');
  v_chave := md5(coalesce(v_cnj, 'sem_cnj:' || coalesce(p_pub->>'cnj','')) || '|' ||
                 coalesce(v_dpub::text, v_ddisp::text, '') || '|' || md5(normalizar_teor(v_teor)));

  select id into v_id from publicacoes where chave_dedupe = v_chave;
  if v_id is null then
    if v_cnj is not null then
      insert into processos (cnj, cnj_digito_valido, origem) values (v_cnj, cnj_digito_valido(v_cnj), 'webjur')
      on conflict (cnj) do nothing;
      select id into v_proc from processos where cnj = v_cnj;
    end if;
    insert into publicacoes (fornecedor, cnj_original, cnj, cnj_digito_valido, processo_id, data_disponibilizacao,
                             data_publicacao, tribunal, orgao_julgador, teor, teor_hash, resumo, url_origem,
                             conteudo_original, chave_dedupe, registrada_por)
    values ('webjur', p_pub->>'cnj', v_cnj, cnj_digito_valido(v_cnj), v_proc, v_ddisp, v_dpub,
            nullif(btrim(p_pub->>'tribunal'),''), nullif(btrim(p_pub->>'orgao_julgador'),''), v_teor,
            md5(normalizar_teor(v_teor)), nullif(btrim(p_pub->>'resumo'),''), nullif(btrim(p_pub->>'url_origem'),''),
            p_pub, v_chave, auth.uid())
    returning id into v_id;
    v_nova := true;
    insert into eventos (chave_dedupe, tipo, ocorrido_em, precisao_ocorrido, origem, historico_recuperado, classificacao, evidencia)
    values ('pub:'||v_id, 'publicacao_recebida', now(), 'segundo', p_origem, false, 'confirmado',
            jsonb_build_object('publicacao_id',v_id,'cnj',v_cnj,'data_publicacao',v_dpub,'usuario',auth.uid()));
  end if;

  insert into publicacoes_coletas (publicacao_id, origem, id_origem, recebido_em, coletado_por)
  values (v_id, p_origem, p_id_origem, (nullif(p_pub->>'recebido_em',''))::timestamptz, auth.uid())
  on conflict (origem, id_origem) do nothing;
  v_coleta := found;

  return jsonb_build_object('status', case when v_nova then 'nova' else 'ja_registrada' end,
                            'publicacao_id', v_id, 'cnj', v_cnj, 'cnj_digito_valido', cnj_digito_valido(v_cnj),
                            'coleta_nova', v_coleta);
end $$;

create or replace function public.montar_observacoes_analise(p_pub bigint, p_requer_cadastro boolean)
returns text language sql stable security definer set search_path = public as $$
  select 'WEBJUR — Disponibilizada em ' || coalesce(to_char(p.data_disponibilizacao,'DD/MM/YYYY'),'(data não informada)') || '.'
      || case when p.data_publicacao is not null then E'\n\nPublicada em ' || to_char(p.data_publicacao,'DD/MM/YYYY') || '.' else '' end
      || E'\n\nNúmero do processo: ' || coalesce(p.cnj, p.cnj_original, '(não informado)') || '.'
      || E'\n\nTribunal: ' || coalesce(p.tribunal,'(não informado)') || '.'
      || E'\n\nÓrgão julgador: ' || coalesce(p.orgao_julgador,'(não informado)') || '.'
      || case when p_requer_cadastro then E'\n\nATENÇÃO: processo não localizado no ADVBOX — necessidade de cadastro e análise.' else '' end
      || E'\n\nTEOR INTEGRAL DA PUBLICAÇÃO:\n\n' || p.teor
    from publicacoes p where p.id = p_pub
$$;

create or replace function public._analise_status(p_id bigint, p_de text[], p_para text, p_nota text, p_evid jsonb default '{}')
returns void language plpgsql security definer set search_path = public as $$
declare v_atual text;
begin
  select status into v_atual from tarefas_analise where id = p_id for update;
  if not found then raise exception 'Tarefa de análise % inexistente', p_id; end if;
  if not (v_atual = any(p_de)) then
    raise exception 'Operação não permitida: a tarefa de análise % está "%"', p_id, v_atual using errcode = 'P0001';
  end if;
  update tarefas_analise set status = p_para, atualizada_em = now() where id = p_id;
  insert into tarefas_analise_historico (tarefa_analise_id, status_anterior, status_novo, nota, evidencia, por)
  values (p_id, v_atual, p_para, p_nota, coalesce(p_evid,'{}'), auth.uid());
  insert into eventos (chave_dedupe, tipo, ocorrido_em, precisao_ocorrido, origem, historico_recuperado, classificacao,
                       valor_anterior, valor_novo, justificativa, evidencia)
  values ('ta:'||p_id||':'||gen_random_uuid(), 'tarefa_analise_status', now(), 'segundo', 'sistema', false, 'confirmado',
          to_jsonb(v_atual), to_jsonb(p_para), p_nota,
          coalesce(p_evid,'{}') || jsonb_build_object('tarefa_analise_id', p_id, 'usuario', auth.uid()));
end $$;

-- Registra o resultado de uma conferência no ADVBOX. Ausência ou processo
-- não cadastrado PREPARA (não cria) a tarefa de análise, uma por publicação.
create or replace function public.pub_registrar_conferencia(
  p_publicacao bigint, p_situacao text, p_area text, p_evidencia jsonb,
  p_advbox_processo_id text default null, p_origem text default 'extensao')
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_conf bigint; v_ta bigint; v_req boolean; v_pub record; v_data date;
begin
  if not is_admin() then raise exception 'Somente a controladoria registra conferências' using errcode = '42501'; end if;
  select * into v_pub from publicacoes where id = p_publicacao;
  if not found then raise exception 'Publicação % inexistente', p_publicacao; end if;
  insert into conferencias_publicacao (publicacao_id, situacao, area_conferida, advbox_processo_id, evidencia, origem, realizada_por)
  values (p_publicacao, p_situacao, p_area, p_advbox_processo_id, coalesce(p_evidencia,'{}'), p_origem, auth.uid())
  returning id into v_conf;
  if p_advbox_processo_id is not null and v_pub.processo_id is not null then
    update processos set advbox_lawsuit_id = p_advbox_processo_id
     where id = v_pub.processo_id and advbox_lawsuit_id is null
       and not exists (select 1 from processos x where x.advbox_lawsuit_id = p_advbox_processo_id);
  end if;
  insert into eventos (chave_dedupe, tipo, ocorrido_em, precisao_ocorrido, origem, historico_recuperado, classificacao, valor_novo, evidencia)
  values ('conf:'||v_conf, 'publicacao_conferida', now(), 'segundo', 'extensao', false, 'confirmado', to_jsonb(p_situacao),
          jsonb_build_object('publicacao_id',p_publicacao,'conferencia_id',v_conf,'area',p_area,'usuario',auth.uid()));

  if p_situacao in ('nao_encontrada_advbox','processo_nao_cadastrado') then
    v_req := p_situacao = 'processo_nao_cadastrado';
    v_data := case (select valor #>> '{}' from parametros where chave = 'tarefa_analise_data_regra')
                when 'proximo_dia_util' then somar_dias_uteis(hoje_brasilia(), 1)
                else hoje_brasilia() end;
    insert into tarefas_analise (publicacao_id, processo_id, cnj, requer_cadastro, tipo, responsavel, observacoes, data_prevista, status)
    values (p_publicacao, case when v_req then null else v_pub.processo_id end, v_pub.cnj, v_req,
            (select valor #>> '{}' from parametros where chave = 'tarefa_analise_tipo'),
            (select valor #>> '{}' from parametros where chave = 'tarefa_analise_responsavel'),
            montar_observacoes_analise(p_publicacao, v_req), v_data, 'preparada')
    on conflict (publicacao_id) do nothing
    returning id into v_ta;
    if v_ta is not null then
      insert into tarefas_analise_historico (tarefa_analise_id, status_anterior, status_novo, nota, evidencia, por)
      values (v_ta, null, 'preparada', 'Preparada automaticamente pela conferência', jsonb_build_object('conferencia_id', v_conf), auth.uid());
    end if;
  end if;
  return jsonb_build_object('conferencia_id', v_conf, 'tarefa_analise_preparada', v_ta,
    'tarefa_analise_existente', (select id from tarefas_analise where publicacao_id = p_publicacao));
end $$;

-- Decisão da controladoria sobre a tarefa preparada.
create or replace function public.analise_decidir(p_id bigint, p_acao text, p_nota text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_sit text;
begin
  if not is_admin() then raise exception 'Somente a controladoria decide' using errcode = '42501'; end if;
  if p_acao = 'aprovar' then
    -- só aprova se a conferência mais recente ainda indica ausência no ADVBOX
    select c.situacao into v_sit from conferencias_publicacao c join tarefas_analise t on t.publicacao_id = c.publicacao_id
     where t.id = p_id order by c.realizada_em desc, c.id desc limit 1;
    if v_sit not in ('nao_encontrada_advbox','processo_nao_cadastrado') then
      raise exception 'Aprovação recusada: a conferência mais recente é "%". Refaça a conferência.', v_sit;
    end if;
    perform _analise_status(p_id, array['preparada','conferencia_manual'], 'aprovada', p_nota);
  elsif p_acao = 'rejeitar' then
    if nullif(btrim(p_nota),'') is null then raise exception 'Informe o motivo da rejeição'; end if;
    perform _analise_status(p_id, array['preparada','conferencia_manual','aprovada'], 'rejeitada', p_nota);
  elsif p_acao = 'conferencia_manual' then
    perform _analise_status(p_id, array['preparada'], 'conferencia_manual', p_nota);
  elsif p_acao = 'ja_tratada' then
    if nullif(btrim(p_nota),'') is null then raise exception 'Informe onde/como já foi tratada'; end if;
    perform _analise_status(p_id, array['preparada','conferencia_manual'], 'ja_tratada', p_nota);
  else
    raise exception 'Ação inválida: %', p_acao;
  end if;
  return jsonb_build_object('id', p_id, 'status', (select status from tarefas_analise where id = p_id));
end $$;

-- Início da criação no ADVBOX: trava contra repetição (extensão aberta de novo,
-- duplo clique). Devolve o conteúdo exato a ser lançado.
create or replace function public.analise_iniciar_criacao(p_id bigint)
returns jsonb language plpgsql security definer set search_path = public as $$
declare t record;
begin
  if not is_admin() then raise exception 'Somente a controladoria cria tarefas' using errcode = '42501'; end if;
  perform _analise_status(p_id, array['aprovada'], 'criacao_em_andamento', null);
  select * into t from tarefas_analise where id = p_id;
  return jsonb_build_object('id', t.id, 'tipo', t.tipo, 'responsavel', t.responsavel, 'observacoes', t.observacoes,
    'data_prevista', t.data_prevista, 'cnj', t.cnj, 'requer_cadastro', t.requer_cadastro,
    'advbox_processo_id', (select advbox_lawsuit_id from processos where id = t.processo_id));
end $$;

create or replace function public.analise_confirmar_criacao(p_id bigint, p_advbox_tarefa_id text, p_evidencia jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Somente a controladoria' using errcode = '42501'; end if;
  if p_advbox_tarefa_id !~ '^\d{1,15}$' then raise exception 'ID de tarefa do ADVBOX inválido'; end if;
  perform _analise_status(p_id, array['criacao_em_andamento','verificar_no_advbox'], 'criada', null,
                          coalesce(p_evidencia,'{}') || jsonb_build_object('advbox_tarefa_id', p_advbox_tarefa_id));
  update tarefas_analise set advbox_tarefa_id = p_advbox_tarefa_id, criada_no_advbox_em = now() where id = p_id;
  return jsonb_build_object('id', p_id, 'status', 'criada', 'advbox_tarefa_id', p_advbox_tarefa_id);
end $$;

-- Falha na criação. Se não há certeza de que nada foi gravado no ADVBOX,
-- a tarefa vai para "verificar_no_advbox" e NÃO pode ser recriada antes da conferência.
create or replace function public.analise_falha_criacao(p_id bigint, p_erro text, p_certeza_nao_criada boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Somente a controladoria' using errcode = '42501'; end if;
  perform _analise_status(p_id, array['criacao_em_andamento'],
                          case when p_certeza_nao_criada then 'aprovada' else 'verificar_no_advbox' end,
                          p_erro, jsonb_build_object('erro', p_erro));
  perform registrar_log_integracao('advbox_extensao', 'erro', 'criar_tarefa_analise', coalesce(p_erro,'(sem mensagem)'),
                                   jsonb_build_object('tarefa_analise_id', p_id, 'certeza_nao_criada', p_certeza_nao_criada));
  return jsonb_build_object('id', p_id, 'status', (select status from tarefas_analise where id = p_id));
end $$;

create or replace function public.analise_confirmar_nao_criada(p_id bigint, p_nota text)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Somente a controladoria' using errcode = '42501'; end if;
  if nullif(btrim(p_nota),'') is null then raise exception 'Descreva a conferência feita no ADVBOX'; end if;
  perform _analise_status(p_id, array['verificar_no_advbox'], 'aprovada', p_nota);
  return jsonb_build_object('id', p_id, 'status', 'aprovada');
end $$;

-- ---------------------------------------------------------------- conferência de alertas
create or replace function public.admin_conferir_alerta(p_linha bigint, p_categoria text, p_resultado text, p_nota text)
returns bigint language plpgsql security definer set search_path = public as $$
declare v_id bigint; v_t bigint;
begin
  if not is_admin() then raise exception 'Somente administradores' using errcode = '42501'; end if;
  select tarefa_id into v_t from linhas_importadas where id = p_linha;
  if not found then raise exception 'Linha % inexistente', p_linha; end if;
  insert into conferencias_alerta (linha_id, tarefa_id, categoria, resultado, nota, por)
  values (p_linha, v_t, p_categoria, p_resultado, p_nota, auth.uid()) returning id into v_id;
  insert into eventos (chave_dedupe, tarefa_id, linha_id, tipo, ocorrido_em, precisao_ocorrido, origem, historico_recuperado,
                       classificacao, valor_novo, justificativa, evidencia)
  values ('calerta:'||v_id, v_t, p_linha, 'conferencia_alerta', now(), 'segundo', 'administrativo', false, 'confirmado',
          to_jsonb(p_resultado), p_nota, jsonb_build_object('categoria', p_categoria, 'usuario', auth.uid()));
  return v_id;
end $$;

-- ---------------------------------------------------------------- importação: registra processos
create or replace function public.importar_arquivo(
  p_nome_arquivo    text,
  p_hash_arquivo    text,
  p_linhas          jsonb,
  p_lote_id         bigint default null,
  p_data_exportacao timestamptz default null,
  p_confirmar_lote_novo_so_concluidas boolean default false
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_res jsonb; v_existente bigint; n_unif int; n_proc int;
begin
  if not public.is_admin() then
    raise exception 'Somente administradores podem importar' using errcode = '42501';
  end if;
  select id into v_existente from importacoes where hash_arquivo = p_hash_arquivo;
  if found then
    return jsonb_build_object('status','ja_importado','importacao_id',v_existente,
      'mensagem','Este arquivo já foi importado; nenhuma alteração foi feita.');
  end if;
  if p_lote_id is null and not p_confirmar_lote_novo_so_concluidas
     and jsonb_typeof(p_linhas) = 'array' and jsonb_array_length(p_linhas) > 0
     and exists (select 1 from importacoes where status = 'concluida')
     and not exists (select 1 from jsonb_array_elements(p_linhas) e
                      where nullif(btrim(e->>'Data Conclusão'),'') is null) then
    return jsonb_build_object('status','requer_confirmacao','lote_atual',(select lote_id from v_lote_atual),
      'mensagem','Todas as linhas deste arquivo são tarefas concluídas. Importado como nova fotografia, ele '
       || 'substituiria a base atual. Informe o lote do dia (complementar) ou confirme expressamente o lote novo.');
  end if;
  v_res := _importar_arquivo_base(p_nome_arquivo, p_hash_arquivo, p_linhas, p_lote_id, p_data_exportacao);
  if v_res->>'status' = 'concluida' then
    n_unif := _unificar_apos_importacao((v_res->>'lote_id')::bigint);
    n_proc := _registrar_processos((v_res->>'lote_id')::bigint);
    v_res := v_res || jsonb_build_object('tarefas_unificadas_pelo_id_advbox', n_unif, 'processos_novos', n_proc);
  end if;
  return v_res;
end $$;

-- ---------------------------------------------------------------- visões
-- v_tarefas_atuais: D-4/D-7 e dias úteis passam a considerar o foro (feriados municipais).
create or replace view public.v_tarefas_atuais with (security_invoker = true) as
with base as (
  select l.*, public.hoje_brasilia() as hoje, public.foro_do_cnj(l.processo_cnj) as foro
    from public.linhas_importadas l
   where l.situacao = 'valida' and l.lote_id = (select lote_id from public.v_lote_atual)
)
select b.id as linha_id, b.tarefa_id, b.metodo_vinculo, b.importacao_id, b.lote_id, b.numero_linha,
       b.prioridade, b.compromisso, b.processo_cnj, b.tribunal_cnj, b.partes, b.tipo_acao, b.local,
       b.responsavel_id, cr.nome_advbox as responsavel, cm.nome_advbox as remetente,
       b.observacoes,
       b.data_agenda                                   as d7_data_agenda,
       public.calcular_d7_conferencia(b.pf_judicial_anotado, b.tribunal_cnj, b.foro) as d7_conferencia,
       b.d4_anotado,
       public.calcular_d4(b.pf_judicial_anotado, b.tribunal_cnj, b.foro)            as d4_regra,
       coalesce(b.d4_anotado, public.calcular_d4(b.pf_judicial_anotado, b.tribunal_cnj, b.foro)) as d4,
       case when b.d4_anotado is not null then 'anotado_na_tarefa'
            when b.pf_judicial_anotado is not null then 'calculado_regra'
            else 'indisponivel' end                    as d4_origem,
       b.pf_judicial_anotado                           as pf_judicial,
       case when b.pf_judicial_anotado is not null then 'anotado_na_tarefa'
            else 'nao_confirmado' end                  as pf_judicial_status,
       b.pf_tarefa,
       b.prazo_dias_anotado,
       b.data_conclusao,
       case when b.data_conclusao is not null then 'concluida' else 'pendente' end as situacao,
       b.hoje,
       public.dias_uteis_entre(b.hoje, coalesce(b.d4_anotado, public.calcular_d4(b.pf_judicial_anotado, b.tribunal_cnj, b.foro)), b.tribunal_cnj, b.foro) as du_ate_d4,
       public.dias_uteis_entre(b.hoje, b.pf_judicial_anotado, b.tribunal_cnj, b.foro) as du_ate_pf_judicial,
       public.dias_uteis_entre(b.hoje, b.pf_tarefa, b.tribunal_cnj, b.foro)           as du_ate_pf_tarefa,
       tr.inicio_em                                    as inicio_tratativa_em,
       tr.abertura_em                                  as abertura_em,
       (select min(e.ocorrido_em) from public.eventos e
         where e.tipo = 'encaminhamento'
           and (e.tarefa_id = b.tarefa_id or e.linha_id = b.id))              as primeira_atribuicao_observada_em,
       (select ultima_importacao_em from public.v_lote_atual) as dados_atualizados_em,
       tr.tarefa_principal                             as tarefa_principal_id,
       tr.advbox_id,
       tr.inicio_por,
       -- novas colunas (0008)
       b.foro                                          as foro_cnj,
       (select p.id from public.processos p where p.cnj = public.normalizar_cnj(b.processo_cnj)) as processo_id,
       cr.equipe_id
  from base b
  left join public.colaboradores cr on cr.id = b.responsavel_id
  left join public.colaboradores cm on cm.id = b.remetente_id
  left join lateral public.tratativa_da_tarefa(b.tarefa_id) tr on b.tarefa_id is not null;

-- Alertas + situação da conferência humana (a mais recente).
create or replace view public.v_alertas_conferencia with (security_invoker = true) as
select a.*, c.resultado as conferencia_resultado, c.nota as conferencia_nota, c.em as conferido_em,
       case when c.id is null then 'pendente_conferencia'
            when c.resultado = 'em_analise' then 'em_analise' else 'conferido' end as situacao_conferencia
  from public.v_alertas a
  left join lateral (select * from public.conferencias_alerta x
                      where x.linha_id = a.linha_id and x.categoria = a.categoria
                      order by x.em desc, x.id desc limit 1) c on true;

create or replace view public.v_publicacoes with (security_invoker = true) as
select p.id, p.cnj, p.cnj_original, p.cnj_digito_valido, p.processo_id, p.data_disponibilizacao, p.data_publicacao,
       p.tribunal, p.orgao_julgador, p.teor, p.resumo, p.url_origem, p.registrada_em,
       (p.registrada_em at time zone 'America/Sao_Paulo')::date as dia_coleta,
       (select string_agg(distinct k.origem, ',') from public.publicacoes_coletas k where k.publicacao_id = p.id) as origens,
       c.situacao as situacao_conferencia, c.area_conferida, c.realizada_em as conferida_em, c.evidencia as evidencia_conferencia,
       (select count(*) from public.conferencias_publicacao x where x.publicacao_id = p.id) as n_conferencias,
       t.id as tarefa_analise_id, t.status as tarefa_analise_status, t.requer_cadastro, t.advbox_tarefa_id
  from public.publicacoes p
  left join lateral (select * from public.conferencias_publicacao x where x.publicacao_id = p.id
                      order by x.realizada_em desc, x.id desc limit 1) c on true
  left join public.tarefas_analise t on t.publicacao_id = p.id;

-- Relatório diário. Percentual de ausentes: só sobre publicações efetivamente
-- conferidas (encontrada, não encontrada, processo não cadastrado); exclui
-- erros de acesso/coleta e casos inconclusivos (Prompt Mestre §21).
create or replace view public.v_double_check_diario with (security_invoker = true) as
select dia_coleta as dia,
       count(*)                                                                    as recebidas,
       count(*) filter (where situacao_conferencia is not null)                    as com_conferencia,
       count(*) filter (where situacao_conferencia = 'encontrada_advbox')          as encontradas,
       count(*) filter (where situacao_conferencia = 'nao_encontrada_advbox')      as ausentes,
       count(*) filter (where situacao_conferencia = 'processo_nao_cadastrado')    as processo_nao_cadastrado,
       count(*) filter (where situacao_conferencia in ('inconclusiva','conferencia_manual')) as inconclusivas,
       count(*) filter (where situacao_conferencia in ('erro_coleta','erro_acesso_advbox'))  as erros_integracao,
       count(*) filter (where exists (select 1 from public.tarefas_analise_historico h
                                       where h.tarefa_analise_id = v.tarefa_analise_id and h.status_novo = 'aprovada')) as tarefas_aprovadas,
       count(*) filter (where tarefa_analise_status = 'criada')                    as tarefas_criadas,
       count(*) filter (where situacao_conferencia in ('encontrada_advbox','nao_encontrada_advbox','processo_nao_cadastrado')) as conferidas_efetivas,
       round(100.0 * count(*) filter (where situacao_conferencia in ('nao_encontrada_advbox','processo_nao_cadastrado'))
             / nullif(count(*) filter (where situacao_conferencia in ('encontrada_advbox','nao_encontrada_advbox','processo_nao_cadastrado')), 0), 1)
                                                                                   as pct_ausentes_sobre_conferidas
  from public.v_publicacoes v
 group by dia_coleta;

-- ---------------------------------------------------------------- segurança
do $$ declare t text;
begin
  foreach t in array array['processos','equipes','publicacoes','publicacoes_coletas','conferencias_publicacao',
                           'tarefas_analise','tarefas_analise_historico','log_integracao','conferencias_alerta'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
    execute format('grant select on public.%I to authenticated', t);
  end loop;
end $$;
create policy equipes_leitura   on public.equipes for select to authenticated using (true);
create policy processos_leitura on public.processos for select to authenticated
  using (public.is_admin() or exists (select 1 from public.linhas_importadas l
           where public.normalizar_cnj(l.processo_cnj) = processos.cnj and l.responsavel_id = public.meu_colaborador_id()));
-- Publicações, double check, tarefas de análise, logs e conferências: só a controladoria.
create policy publicacoes_admin  on public.publicacoes for select to authenticated using (public.is_admin());
create policy coletas_admin      on public.publicacoes_coletas for select to authenticated using (public.is_admin());
create policy conf_pub_admin     on public.conferencias_publicacao for select to authenticated using (public.is_admin());
create policy analise_admin      on public.tarefas_analise for select to authenticated using (public.is_admin());
create policy analise_hist_admin on public.tarefas_analise_historico for select to authenticated using (public.is_admin());
create policy log_admin          on public.log_integracao for select to authenticated using (public.is_admin());
create policy conf_alerta_admin  on public.conferencias_alerta for select to authenticated using (public.is_admin());

grant select on public.v_tarefas_atuais, public.v_alertas_conferencia, public.v_publicacoes, public.v_double_check_diario to authenticated;
revoke all on public.v_tarefas_atuais, public.v_alertas_conferencia, public.v_publicacoes, public.v_double_check_diario from anon;

revoke execute on all functions in schema public from public, anon;
grant  execute on all functions in schema public to authenticated;
do $$ declare f text;
begin
  foreach f in array array[
    'public._gerar_eventos_importacao(bigint, timestamptz)',
    'public._importar_arquivo_base(text, text, jsonb, bigint, timestamptz)',
    'public._tarefa_por_advbox(text, jsonb)', 'public._candidatos_tela(jsonb, bigint)',
    'public._tem_linha_no_lote(bigint, bigint)', 'public._unificar(bigint, bigint, text, jsonb)',
    'public._unificar_apos_importacao(bigint)', 'public._dt_tela(text)', 'public._ts_tela(text)',
    'public._registrar_processos(bigint, text)', 'public._analise_status(bigint, text[], text, text, jsonb)',
    'public.tg_bloqueia_alteracao()', 'public.tg_importacao_fechada()', 'public.tg_linha_imutavel()'] loop
    execute format('revoke execute on function %s from public, anon, authenticated', f);
  end loop;
end $$;
