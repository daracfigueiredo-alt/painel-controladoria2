-- =====================================================================
-- 0039 — Modalidades padronizadas, checklist e anexos obrigatórios (pedido da Dra. Mariana,
-- item 5; 11/11/2026). Aditiva.
-- Cada modalidade de tarefa jurídica (contestação, apelação...) tem: checklist obrigatório,
-- link do material de treinamento, link do NotebookLM para a conferência técnica da peça,
-- orientações, pontos de complexidade (planejamento, 0040) e a exigência de anexar a PEÇA e o
-- PARECER DE AUTOAVALIAÇÃO do advogado.
--   * A modalidade da tarefa é reconhecida pelo título (padrões) ou definida manualmente.
--   * Só modalidade ATIVA exige checklist e anexos (as do modelo inicial nascem inativas,
--     para a controladoria revisar e completar os links antes de ligar).
--   * O peticionador marca o checklist e anexa os arquivos na janela da tarefa no Atlas
--     (extensão) ou em "Minha pauta" (painel). Arquivos no Storage do Supabase (bucket privado
--     "pecas"), com hash; tudo append-only.
--   * Conclusão de tarefa de modalidade ativa com pendência: trava (parâmetro trava_execucao_modo).
--   * A descrição da tarefa no Atlas é PRESERVADA e complementada com um bloco da controladoria
--     (prazos, orientações, checklist, links), por edit_task (Edge Function, ação explícita).
-- =====================================================================

create table if not exists public.modalidades (
  id               bigint generated always as identity primary key,
  nome             text not null unique,
  padroes          text[] not null default '{}',     -- trechos do título (sem acento, minúsculas)
  pontos           int not null default 2 check (pontos between 1 and 10),   -- complexidade (0040)
  checklist        jsonb not null default '[]' check (jsonb_typeof(checklist) = 'array'),
  link_treinamento text,
  link_notebooklm  text,
  orientacoes      text,
  exige_peca       boolean not null default true,
  exige_parecer    boolean not null default true,
  ativa            boolean not null default false,
  criado_em        timestamptz not null default now(),
  atualizado_em    timestamptz not null default now()
);
alter table public.modalidades enable row level security;
revoke all on public.modalidades from anon, authenticated;
grant select on public.modalidades to authenticated;
drop policy if exists modalidades_leitura on public.modalidades;
create policy modalidades_leitura on public.modalidades for select to authenticated using (true);
drop trigger if exists modalidades_auditoria on public.modalidades;
create trigger modalidades_auditoria after insert or update or delete on public.modalidades
  for each row execute function public.tg_auditar_configuracao();

-- modalidade definida manualmente (prevalece sobre o título)
create table if not exists public.tarefas_modalidade (
  id            bigint generated always as identity primary key,
  tarefa_id     bigint not null unique references public.tarefas(id),
  modalidade_id bigint references public.modalidades(id),   -- null = "sem modalidade" (não exige nada)
  por           uuid,
  em            timestamptz not null default now()
);
alter table public.tarefas_modalidade enable row level security;
revoke all on public.tarefas_modalidade from anon, authenticated;
drop trigger if exists tarefas_modalidade_auditoria on public.tarefas_modalidade;
create trigger tarefas_modalidade_auditoria after insert or update or delete on public.tarefas_modalidade
  for each row execute function public.tg_auditar_configuracao();

-- marcações do checklist (append-only: vale a última de cada item)
create table if not exists public.execucao_checklist (
  id             bigint generated always as identity primary key,
  tarefa_id      bigint not null references public.tarefas(id),
  modalidade_id  bigint not null references public.modalidades(id),
  item_id        text not null,
  marcado        boolean not null,
  por            uuid,
  colaborador_id bigint references public.colaboradores(id),
  origem         text not null check (origem in ('extensao','painel')),
  em             timestamptz not null default now()
);
create index if not exists execucao_checklist_tarefa_idx on public.execucao_checklist (tarefa_id, item_id, em desc);
alter table public.execucao_checklist enable row level security;
revoke all on public.execucao_checklist from anon, authenticated;

-- anexos (peça e parecer de autoavaliação). Append-only: um novo anexo do mesmo tipo substitui o anterior.
create table if not exists public.anexos_tarefa (
  id             bigint generated always as identity primary key,
  tarefa_id      bigint not null references public.tarefas(id),
  tipo           text not null check (tipo in ('peca','parecer_autoavaliacao','outro')),
  caminho        text not null unique,                 -- <tarefa_id>/<arquivo> no bucket "pecas"
  nome_arquivo   text not null,
  tamanho        bigint not null check (tamanho > 0),
  sha256         text check (sha256 ~ '^[0-9a-f]{64}$'),
  por            uuid,
  colaborador_id bigint references public.colaboradores(id),
  origem         text not null check (origem in ('extensao','painel')),
  em             timestamptz not null default now()
);
create index if not exists anexos_tarefa_idx on public.anexos_tarefa (tarefa_id, tipo, em desc);
alter table public.anexos_tarefa enable row level security;
revoke all on public.anexos_tarefa from anon, authenticated;

do $$ declare t text; begin
  foreach t in array array['execucao_checklist','anexos_tarefa'] loop
    execute format('drop trigger if exists %I on public.%I', t || '_imutavel', t);
    execute format('create trigger %I before update or delete on public.%I for each row execute function public.tg_bloqueia_alteracao()', t || '_imutavel', t);
    execute format('drop trigger if exists %I on public.%I', t || '_sem_truncate', t);
    execute format('create trigger %I before truncate on public.%I for each statement execute function public.tg_bloqueia_alteracao()', t || '_sem_truncate', t);
  end loop;
end $$;

insert into public.parametros (chave, valor, confirmado, descricao) values
 ('trava_execucao_modo', '"bloquear"', false,
  'Conclusão de tarefa de modalidade ATIVA sem checklist completo, sem a peça ou sem o parecer de autoavaliação: bloquear | observar. '
  'Pedido da Dra. Mariana (11/11/2026, item 5). As modalidades do modelo inicial nascem inativas.'),
 ('anexo_tamanho_maximo_mb', '20', false, 'Tamanho máximo de cada anexo (peça, parecer), em MB.')
on conflict (chave) do nothing;

-- ---------------------------------------------------------------- modelo inicial (inativo: a controladoria revisa e liga)
insert into public.modalidades (nome, padroes, pontos, checklist, orientacoes) values
 ('Contestação', '{contestacao,contestar}', 3,
  '[{"id":"orientacoes","texto":"Li as orientações e o material de treinamento da modalidade"},
    {"id":"prazos","texto":"Conferi o PF Judicial e o D-4 desta tarefa"},
    {"id":"documentos","texto":"Reuni os documentos do cliente (contrato, extratos, procuração)"},
    {"id":"preliminares","texto":"Analisei as preliminares cabíveis (art. 337 do CPC)"},
    {"id":"impugnacao","texto":"Impugnei especificamente os fatos e os documentos da inicial (art. 341 do CPC)"},
    {"id":"notebooklm","texto":"Submeti a peça à conferência técnica no NotebookLM e corrigi os apontamentos"},
    {"id":"autoavaliacao","texto":"Elaborei o parecer de autoavaliação após a conferência"}]',
  'Modelo inicial: completar com as orientações do escritório para contestação.'),
 ('Réplica', '{replica,"impugnacao a contestacao"}', 2,
  '[{"id":"orientacoes","texto":"Li as orientações e o material de treinamento da modalidade"},
    {"id":"prazos","texto":"Conferi o PF Judicial e o D-4 desta tarefa"},
    {"id":"rebate","texto":"Rebati as preliminares e os documentos novos da contestação"},
    {"id":"notebooklm","texto":"Submeti a peça à conferência técnica no NotebookLM e corrigi os apontamentos"},
    {"id":"autoavaliacao","texto":"Elaborei o parecer de autoavaliação após a conferência"}]',
  'Modelo inicial: completar com as orientações do escritório para réplica.'),
 ('Recurso de apelação', '{apelacao,"recurso de apelacao"}', 4,
  '[{"id":"orientacoes","texto":"Li as orientações e o material de treinamento da modalidade"},
    {"id":"prazos","texto":"Conferi o PF Judicial e o D-4 desta tarefa"},
    {"id":"preparo","texto":"Conferi o preparo (custas e porte) ou a gratuidade"},
    {"id":"dialeticidade","texto":"Impugnei especificamente os fundamentos da sentença"},
    {"id":"notebooklm","texto":"Submeti a peça à conferência técnica no NotebookLM e corrigi os apontamentos"},
    {"id":"autoavaliacao","texto":"Elaborei o parecer de autoavaliação após a conferência"}]',
  'Modelo inicial: completar com as orientações do escritório para apelação.'),
 ('Contrarrazões', '{contrarrazoes,contrarrazao}', 3,
  '[{"id":"orientacoes","texto":"Li as orientações e o material de treinamento da modalidade"},
    {"id":"prazos","texto":"Conferi o PF Judicial e o D-4 desta tarefa"},
    {"id":"admissibilidade","texto":"Analisei os requisitos de admissibilidade do recurso da parte contrária"},
    {"id":"notebooklm","texto":"Submeti a peça à conferência técnica no NotebookLM e corrigi os apontamentos"},
    {"id":"autoavaliacao","texto":"Elaborei o parecer de autoavaliação após a conferência"}]',
  'Modelo inicial: completar com as orientações do escritório para contrarrazões.'),
 ('Agravo', '{agravo}', 3,
  '[{"id":"orientacoes","texto":"Li as orientações e o material de treinamento da modalidade"},
    {"id":"prazos","texto":"Conferi o PF Judicial e o D-4 desta tarefa"},
    {"id":"cabimento","texto":"Conferi o cabimento (art. 1.015 do CPC ou lei específica)"},
    {"id":"pecas","texto":"Juntei as peças obrigatórias e o preparo"},
    {"id":"notebooklm","texto":"Submeti a peça à conferência técnica no NotebookLM e corrigi os apontamentos"},
    {"id":"autoavaliacao","texto":"Elaborei o parecer de autoavaliação após a conferência"}]',
  'Modelo inicial: completar com as orientações do escritório para agravo.'),
 ('Embargos de declaração', '{"embargos de declaracao","embargos declaratorios"}', 2,
  '[{"id":"orientacoes","texto":"Li as orientações e o material de treinamento da modalidade"},
    {"id":"prazos","texto":"Conferi o PF Judicial e o D-4 desta tarefa"},
    {"id":"vicio","texto":"Apontei omissão, contradição, obscuridade ou erro material (art. 1.022 do CPC)"},
    {"id":"notebooklm","texto":"Submeti a peça à conferência técnica no NotebookLM e corrigi os apontamentos"},
    {"id":"autoavaliacao","texto":"Elaborei o parecer de autoavaliação após a conferência"}]',
  'Modelo inicial: completar com as orientações do escritório para embargos de declaração.'),
 ('Petição inicial', '{"peticao inicial","distribuicao - novo processo"}', 3,
  '[{"id":"orientacoes","texto":"Li as orientações e o material de treinamento da modalidade"},
    {"id":"documentos","texto":"Reuni os documentos indispensáveis e a procuração"},
    {"id":"requisitos","texto":"Conferi os requisitos do art. 319 do CPC e o valor da causa"},
    {"id":"custas","texto":"Conferi custas ou pedido de gratuidade"},
    {"id":"notebooklm","texto":"Submeti a peça à conferência técnica no NotebookLM e corrigi os apontamentos"},
    {"id":"autoavaliacao","texto":"Elaborei o parecer de autoavaliação após a conferência"}]',
  'Modelo inicial: completar com as orientações do escritório para petição inicial.'),
 ('Manifestação', '{manifestacao,manifestar}', 1,
  '[{"id":"orientacoes","texto":"Li as orientações da modalidade"},
    {"id":"prazos","texto":"Conferi o PF Judicial e o D-4 desta tarefa"},
    {"id":"notebooklm","texto":"Submeti a peça à conferência técnica no NotebookLM e corrigi os apontamentos"},
    {"id":"autoavaliacao","texto":"Elaborei o parecer de autoavaliação após a conferência"}]',
  'Modelo inicial: completar com as orientações do escritório para manifestação.')
on conflict (nome) do nothing;

-- ---------------------------------------------------------------- apoio
create or replace function public._texto_busca(p text) returns text
language sql immutable set search_path = public as $$ select lower(public._nome_normalizado(p)) $$;

-- linha da tarefa na base atual (última sincronização)
create or replace function public._linha_atual(p_tarefa bigint) returns public.linhas_importadas
language sql stable security definer set search_path = public as $$
  select l.* from linhas_importadas l join tarefas t on t.id = l.tarefa_id
   where coalesce(t.unificada_em, t.id) = public._tarefa_principal(p_tarefa)
     and l.situacao = 'valida' and l.lote_id = (select lote_id from v_lote_atual)
   order by l.id limit 1
$$;

-- modalidade reconhecida pelo título (o padrão mais longo que aparece no título)
create or replace function public._modalidade_por_titulo(p_titulo text) returns bigint
language sql stable security definer set search_path = public as $$
  select m.id from modalidades m, unnest(m.padroes) p
   where length(btrim(p)) > 0 and position(public._texto_busca(p) in public._texto_busca(p_titulo)) > 0
   order by length(p) desc, m.id limit 1
$$;

create or replace function public.modalidade_da_tarefa(p_tarefa bigint) returns bigint
language plpgsql stable security definer set search_path = public as $$
declare v_t bigint := public._tarefa_principal(p_tarefa); v_m bigint; l linhas_importadas;
begin
  select modalidade_id into v_m from tarefas_modalidade where tarefa_id = v_t;
  if found then return v_m; end if;
  l := public._linha_atual(v_t);
  return public._modalidade_por_titulo(l.compromisso);
end $$;

-- a pessoa pode trabalhar na tarefa: controladoria, responsável (inclusive corresponsável no
-- Atlas) ou líder da equipe do responsável
create or replace function public.pode_trabalhar_tarefa(p_tarefa bigint) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare l linhas_importadas; v_mc bigint[] := public.meus_colaboradores();
begin
  if public.is_admin() then return true; end if;
  if p_tarefa is null or cardinality(v_mc) = 0 then return false; end if;
  l := public._linha_atual(p_tarefa);
  if l.id is null then return false; end if;
  if coalesce(l.responsavel_id = any (v_mc), false) then return true; end if;
  return exists (select 1 from jsonb_array_elements(coalesce(l.dados_brutos->'_atlas_responsaveis', '[]')) r
                   join colaboradores c on c.atlas_user_id::text = r->>'id'
                  where c.id = any (v_mc));
end $$;

-- situação da execução: modalidade, checklist, anexos e pendências
create or replace function public.execucao_situacao(p_tarefa bigint) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_t bigint := public._tarefa_principal(p_tarefa); v_m bigint := public.modalidade_da_tarefa(p_tarefa);
        m modalidades; v_itens jsonb := '[]'; v_anexos jsonb; v_pend text[] := '{}'; it jsonb; v_marc boolean;
        v_tem_peca boolean; v_tem_parecer boolean;
begin
  select * into m from modalidades where id = v_m;
  select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'tipo', a.tipo, 'nome', a.nome_arquivo, 'tamanho', a.tamanho,
            'caminho', a.caminho, 'em', a.em, 'por', coalesce(c.nome_advbox, u.email)) order by a.em desc), '[]')
    into v_anexos
    from anexos_tarefa a left join colaboradores c on c.id = a.colaborador_id left join auth.users u on u.id = a.por
   where a.tarefa_id = v_t;
  v_tem_peca := exists (select 1 from anexos_tarefa where tarefa_id = v_t and tipo = 'peca');
  v_tem_parecer := exists (select 1 from anexos_tarefa where tarefa_id = v_t and tipo = 'parecer_autoavaliacao');
  if m.id is not null then
    for it in select * from jsonb_array_elements(m.checklist) loop
      select e.marcado into v_marc from execucao_checklist e
       where e.tarefa_id = v_t and e.item_id = it->>'id' order by e.em desc, e.id desc limit 1;
      v_itens := v_itens || jsonb_build_object('id', it->>'id', 'texto', it->>'texto', 'marcado', coalesce(v_marc, false));
      if not coalesce(v_marc, false) then v_pend := v_pend || ('Checklist: ' || (it->>'texto')); end if;
    end loop;
    if m.exige_peca and not v_tem_peca then v_pend := v_pend || 'Anexar a peça produzida'::text; end if;
    if m.exige_parecer and not v_tem_parecer then v_pend := v_pend || 'Anexar o parecer de autoavaliação'::text; end if;
  end if;
  return jsonb_build_object(
    'tarefa_id', v_t,
    'modalidade', case when m.id is null then null else jsonb_build_object('id', m.id, 'nome', m.nome, 'ativa', m.ativa,
        'link_treinamento', m.link_treinamento, 'link_notebooklm', m.link_notebooklm, 'orientacoes', m.orientacoes,
        'exige_peca', m.exige_peca, 'exige_parecer', m.exige_parecer, 'pontos', m.pontos) end,
    'modalidade_manual', exists (select 1 from tarefas_modalidade where tarefa_id = v_t),
    'checklist', v_itens, 'anexos', v_anexos,
    'pendencias', to_jsonb(v_pend),
    'exigido', coalesce(m.ativa, false),
    'completo', cardinality(v_pend) = 0,
    'modo', (select valor #>> '{}' from parametros where chave = 'trava_execucao_modo'),
    'pode_editar', public.pode_trabalhar_tarefa(v_t),
    'anexo_tamanho_maximo_mb', param_int('anexo_tamanho_maximo_mb'));
end $$;

create or replace function public.execucao_tarefa(p_tarefa bigint) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not (public.pode_trabalhar_tarefa(p_tarefa) or public.pode_ler_tudo()) then
    raise exception 'Somente o responsável, o líder da equipe e a controladoria' using errcode = '42501';
  end if;
  return public.execucao_situacao(p_tarefa);
end $$;

create or replace function public._tarefa_por_id_externo(p_id text) returns bigint
language sql stable security definer set search_path = public as $$
  select id from tarefas where advbox_id = lower(btrim(p_id)) or advbox_id = btrim(p_id)
   order by (unificada_em is null) desc, id limit 1
$$;

create or replace function public.ext_execucao(p_advbox_id text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_t bigint;
begin
  if public.meu_papel() is null then raise exception 'Usuário sem perfil na controladoria' using errcode = '42501'; end if;
  v_t := public._tarefa_por_id_externo(p_advbox_id);
  if v_t is null then return jsonb_build_object('encontrada', false); end if;
  if not (public.pode_trabalhar_tarefa(v_t) or public.pode_ler_tudo()) then
    return jsonb_build_object('encontrada', true, 'tarefa_id', public._tarefa_principal(v_t), 'sem_acesso', true);
  end if;
  return jsonb_build_object('encontrada', true) || public.execucao_situacao(v_t);
end $$;

create or replace function public.execucao_marcar(p_tarefa bigint, p_item text, p_marcado boolean, p_origem text default 'painel')
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_t bigint := public._tarefa_principal(p_tarefa); v_m bigint;
begin
  if not public.pode_trabalhar_tarefa(v_t) then
    raise exception 'Somente o responsável, o líder da equipe e a controladoria' using errcode = '42501';
  end if;
  if p_origem not in ('painel','extensao') then raise exception 'Origem inválida'; end if;
  v_m := public.modalidade_da_tarefa(v_t);
  if v_m is null then raise exception 'Tarefa sem modalidade: não há checklist'; end if;
  if not exists (select 1 from modalidades m, jsonb_array_elements(m.checklist) i where m.id = v_m and i->>'id' = p_item) then
    raise exception 'Item de checklist inexistente: %', p_item;
  end if;
  insert into execucao_checklist (tarefa_id, modalidade_id, item_id, marcado, por, colaborador_id, origem)
  values (v_t, v_m, p_item, coalesce(p_marcado, false), auth.uid(), (select colaborador_id from perfis where user_id = auth.uid()), p_origem);
  return public.execucao_situacao(v_t);
end $$;

create or replace function public.ext_execucao_marcar(p_advbox_id text, p_item text, p_marcado boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_t bigint := public._tarefa_por_id_externo(p_advbox_id);
begin
  if public.meu_papel() is null then raise exception 'Usuário sem perfil na controladoria' using errcode = '42501'; end if;
  if v_t is null then raise exception 'Tarefa ainda não sincronizada com a controladoria'; end if;
  return jsonb_build_object('encontrada', true) || public.execucao_marcar(v_t, p_item, p_marcado, 'extensao');
end $$;

-- caminho no bucket: "<tarefa_id>/<arquivo>"
create or replace function public._tarefa_do_caminho(p_caminho text) returns bigint
language sql immutable set search_path = public as $$
  select case when split_part(p_caminho, '/', 1) ~ '^[0-9]{1,18}$' then split_part(p_caminho, '/', 1)::bigint end
$$;

-- registra o anexo depois do envio ao Storage (o arquivo precisa existir no bucket)
create or replace function public.anexo_registrar(p_tarefa bigint, p_tipo text, p_caminho text, p_nome text,
                                                  p_tamanho bigint, p_sha256 text, p_origem text default 'painel')
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_t bigint := public._tarefa_principal(p_tarefa); v_max bigint := param_int('anexo_tamanho_maximo_mb')::bigint * 1048576;
begin
  if not public.pode_trabalhar_tarefa(v_t) then
    raise exception 'Somente o responsável, o líder da equipe e a controladoria' using errcode = '42501';
  end if;
  if p_tipo not in ('peca','parecer_autoavaliacao','outro') then raise exception 'Tipo de anexo inválido: %', p_tipo; end if;
  if p_origem not in ('painel','extensao') then raise exception 'Origem inválida'; end if;
  if public._tarefa_do_caminho(p_caminho) is distinct from v_t then raise exception 'O arquivo deve ficar na pasta da tarefa (%/...)', v_t; end if;
  if coalesce(p_tamanho, 0) <= 0 or p_tamanho > v_max then raise exception 'Arquivo vazio ou maior que % MB', param_int('anexo_tamanho_maximo_mb'); end if;
  if length(btrim(coalesce(p_nome, ''))) = 0 then raise exception 'Nome do arquivo obrigatório'; end if;
  if not exists (select 1 from storage.objects o where o.bucket_id = 'pecas' and o.name = p_caminho) then
    raise exception 'Arquivo não encontrado no armazenamento: envie o arquivo antes de registrar';
  end if;
  insert into anexos_tarefa (tarefa_id, tipo, caminho, nome_arquivo, tamanho, sha256, por, colaborador_id, origem)
  values (v_t, p_tipo, p_caminho, btrim(p_nome), p_tamanho, lower(p_sha256), auth.uid(),
          (select colaborador_id from perfis where user_id = auth.uid()), p_origem)
  on conflict (caminho) do nothing;
  return public.execucao_situacao(v_t);
end $$;

create or replace function public.ext_anexo_registrar(p_advbox_id text, p_tipo text, p_caminho text, p_nome text, p_tamanho bigint, p_sha256 text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_t bigint := public._tarefa_por_id_externo(p_advbox_id);
begin
  if public.meu_papel() is null then raise exception 'Usuário sem perfil na controladoria' using errcode = '42501'; end if;
  if v_t is null then raise exception 'Tarefa ainda não sincronizada com a controladoria'; end if;
  return jsonb_build_object('encontrada', true) || public.anexo_registrar(v_t, p_tipo, p_caminho, p_nome, p_tamanho, p_sha256, 'extensao');
end $$;

-- ---------------------------------------------------------------- administração das modalidades
create or replace function public.admin_salvar_modalidade(p_dados jsonb, p_motivo text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_id bigint := nullif(p_dados->>'id', '')::bigint; v_check jsonb := coalesce(p_dados->'checklist', '[]'); it jsonb;
        v_ids text[] := '{}';
begin
  if not is_admin() then raise exception 'Somente administradores' using errcode = '42501'; end if;
  perform _exigir_motivo(p_motivo);
  if length(btrim(coalesce(p_dados->>'nome', ''))) < 3 then raise exception 'Nome da modalidade obrigatório'; end if;
  if jsonb_typeof(v_check) <> 'array' then raise exception 'Checklist inválido'; end if;
  for it in select * from jsonb_array_elements(v_check) loop
    if coalesce(it->>'id', '') !~ '^[a-z0-9_]{2,40}$' or length(btrim(coalesce(it->>'texto', ''))) < 5 then
      raise exception 'Item de checklist inválido: id (letras minúsculas, números e _) e texto (mínimo 5 caracteres)';
    end if;
    if (it->>'id') = any (v_ids) then raise exception 'Item de checklist repetido: %', it->>'id'; end if;
    v_ids := v_ids || (it->>'id');
  end loop;
  if coalesce(p_dados->>'link_treinamento', '') !~ '^(|https://\S+)$' or coalesce(p_dados->>'link_notebooklm', '') !~ '^(|https://\S+)$' then
    raise exception 'Links devem começar com https://';
  end if;
  if coalesce((p_dados->>'ativa')::boolean, false) and jsonb_array_length(v_check) = 0 then
    raise exception 'Modalidade ativa precisa de checklist';
  end if;
  if v_id is null then
    insert into modalidades (nome, padroes, pontos, checklist, link_treinamento, link_notebooklm, orientacoes, exige_peca, exige_parecer, ativa)
    values (btrim(p_dados->>'nome'),
            coalesce((select array_agg(public._texto_busca(x)) from jsonb_array_elements_text(coalesce(p_dados->'padroes', '[]')) x where btrim(x) <> ''), '{}'),
            coalesce((p_dados->>'pontos')::int, 2), v_check, nullif(btrim(p_dados->>'link_treinamento'), ''),
            nullif(btrim(p_dados->>'link_notebooklm'), ''), nullif(btrim(p_dados->>'orientacoes'), ''),
            coalesce((p_dados->>'exige_peca')::boolean, true), coalesce((p_dados->>'exige_parecer')::boolean, true),
            coalesce((p_dados->>'ativa')::boolean, false))
    returning id into v_id;
  else
    update modalidades set nome = btrim(p_dados->>'nome'),
           padroes = coalesce((select array_agg(public._texto_busca(x)) from jsonb_array_elements_text(coalesce(p_dados->'padroes', '[]')) x where btrim(x) <> ''), '{}'),
           pontos = coalesce((p_dados->>'pontos')::int, pontos), checklist = v_check,
           link_treinamento = nullif(btrim(p_dados->>'link_treinamento'), ''), link_notebooklm = nullif(btrim(p_dados->>'link_notebooklm'), ''),
           orientacoes = nullif(btrim(p_dados->>'orientacoes'), ''),
           exige_peca = coalesce((p_dados->>'exige_peca')::boolean, exige_peca), exige_parecer = coalesce((p_dados->>'exige_parecer')::boolean, exige_parecer),
           ativa = coalesce((p_dados->>'ativa')::boolean, ativa), atualizado_em = now()
     where id = v_id;
    if not found then raise exception 'Modalidade % inexistente', v_id; end if;
  end if;
  return (select to_jsonb(m) from modalidades m where id = v_id);
end $$;

-- modalidade definida à mão para uma tarefa (controladoria ou líder); null = "sem modalidade"; p_remover volta ao automático
create or replace function public.definir_modalidade_tarefa(p_tarefa bigint, p_modalidade bigint, p_remover boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_t bigint := public._tarefa_principal(p_tarefa);
begin
  if not (is_admin() or coalesce(public.meu_papel() = 'lider', false)) then raise exception 'Somente líderes e a controladoria' using errcode = '42501'; end if;
  if not exists (select 1 from tarefas where id = v_t) then raise exception 'Tarefa % inexistente', p_tarefa; end if;
  if p_modalidade is not null and not exists (select 1 from modalidades where id = p_modalidade) then raise exception 'Modalidade inexistente'; end if;
  if p_remover then delete from tarefas_modalidade where tarefa_id = v_t;
  else
    insert into tarefas_modalidade (tarefa_id, modalidade_id, por) values (v_t, p_modalidade, auth.uid())
    on conflict (tarefa_id) do update set modalidade_id = excluded.modalidade_id, por = excluded.por, em = now();
  end if;
  return public.execucao_situacao(v_t);
end $$;

-- ---------------------------------------------------------------- pauta (peticionador, líder, controladoria, diretoria)
-- Tarefas pendentes visíveis para quem consulta (RLS da base), com prazos, modalidade e execução.
create or replace function public.minha_pauta(p_colaborador bigint default null, p_dias int default 30)
returns jsonb language plpgsql stable security invoker set search_path = public as $$
declare v_res jsonb;
begin
  if public.meu_papel() is null then raise exception 'Usuário sem perfil na controladoria' using errcode = '42501'; end if;
  with p as (
    select v.*, t.atlas_id from v_tarefas_atuais v left join tarefas t on t.id = v.tarefa_id
     where v.situacao = 'pendente'
       and (p_colaborador is null or v.responsavel_id = p_colaborador)
       and (v.d7_data_agenda is null or v.d7_data_agenda <= v.hoje + greatest(coalesce(p_dias, 30), 1))
  ), e as (select p.*, public.execucao_tarefa(p.tarefa_id) as ex from p where p.tarefa_id is not null)
  select coalesce(jsonb_agg(jsonb_build_object(
           'tarefa_id', e.tarefa_id, 'compromisso', e.compromisso, 'responsavel', e.responsavel, 'responsavel_id', e.responsavel_id,
           'processo_cnj', e.processo_cnj, 'partes', e.partes, 'prioridade', e.prioridade,
           'data_agenda', e.d7_data_agenda, 'd4', e.d4, 'pf_judicial', e.pf_judicial, 'pf_tarefa', e.pf_tarefa,
           'inicio_tratativa_em', e.inicio_tratativa_em, 'excecao_d4', public._excecao_d4_em(e.tarefa_id),
           'atlas_url', case when e.atlas_id is not null then 'https://gestor.atlasjus.com/#/tasks?task=' || e.atlas_id end,
           'modalidade', e.ex->'modalidade', 'checklist', e.ex->'checklist', 'anexos', e.ex->'anexos',
           'pendencias', e.ex->'pendencias', 'exigido', e.ex->'exigido', 'pode_editar', e.ex->'pode_editar')
         order by e.d7_data_agenda nulls last, e.d4 nulls last, e.compromisso), '[]')
    into v_res from e;
  return v_res;
end $$;

-- ---------------------------------------------------------------- bloco padrão na descrição do Atlas
-- O texto original do Atlas é preservado; o bloco fica entre os marcadores e é substituído a cada atualização.
create or replace function public.bloco_descricao_padrao(p_tarefa bigint) returns text
language plpgsql stable security definer set search_path = public as $$
declare v_t bigint := public._tarefa_principal(p_tarefa); m modalidades; v record; v_txt text; it jsonb;
        f constant text := 'DD/MM/YYYY';
begin
  select * into m from modalidades where id = public.modalidade_da_tarefa(v_t);
  if m.id is null or not m.ativa then return null; end if;
  select d4, pf_judicial, pf_tarefa, d7_data_agenda into v from v_tarefas_atuais where tarefa_id is not null
     and public._tarefa_principal(tarefa_id) = v_t limit 1;
  v_txt := '=== Controladoria Oliveira e Camilo (padrão) ===' || E'\n'
        || 'Modalidade: ' || m.nome || E'\n'
        || 'Prazo judicial (fatal): ' || coalesce(to_char(v.pf_judicial, f), 'não informado')
        || ' | Entrega interna (D-4): ' || coalesce(to_char(v.d4, f), 'não calculado')
        || ' | Agenda (D-7): ' || coalesce(to_char(v.d7_data_agenda, f), '-') || E'\n';
  if m.orientacoes is not null then v_txt := v_txt || 'Orientações: ' || m.orientacoes || E'\n'; end if;
  if m.link_treinamento is not null then v_txt := v_txt || 'Material de treinamento: ' || m.link_treinamento || E'\n'; end if;
  if m.link_notebooklm is not null then v_txt := v_txt || 'Conferência técnica (NotebookLM): ' || m.link_notebooklm || E'\n'; end if;
  v_txt := v_txt || 'Checklist obrigatório (marcar na extensão ou em Minha pauta):' || E'\n';
  for it in select * from jsonb_array_elements(m.checklist) loop v_txt := v_txt || '[ ] ' || (it->>'texto') || E'\n'; end loop;
  if m.exige_peca then v_txt := v_txt || 'Anexo obrigatório: peça produzida' || E'\n'; end if;
  if m.exige_parecer then v_txt := v_txt || 'Anexo obrigatório: parecer de autoavaliação (após a conferência no NotebookLM)' || E'\n'; end if;
  return v_txt || '=== fim do padrão da controladoria ===';
end $$;

-- tarefas do Atlas (pendentes, modalidade ativa) cuja descrição precisa receber/atualizar o bloco
create table if not exists public.descricoes_padronizadas (
  id         bigint generated always as identity primary key,
  tarefa_id  bigint not null references public.tarefas(id),
  atlas_id   uuid not null,
  hash_bloco text not null,
  resultado  text not null check (resultado in ('gravada','pulada_descricao_longa','erro')),
  detalhe    text,
  em         timestamptz not null default now()
);
create index if not exists descricoes_padronizadas_idx on public.descricoes_padronizadas (tarefa_id, em desc);
alter table public.descricoes_padronizadas enable row level security;
revoke all on public.descricoes_padronizadas from anon, authenticated;
grant select on public.descricoes_padronizadas to authenticated;
drop policy if exists descricoes_padronizadas_leitura on public.descricoes_padronizadas;
create policy descricoes_padronizadas_leitura on public.descricoes_padronizadas for select to authenticated using (public.pode_ler_tudo());

create or replace function public.descricoes_para_padronizar(p_limite int default 200) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Somente administradores' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(x) from (
    select t.id as tarefa_id, t.atlas_id, l.dados_brutos->>'_atlas_descricao' as descricao_original,
           coalesce((l.dados_brutos->>'_atlas_descricao_truncada')::boolean, false) as truncada,
           b.bloco, md5(b.bloco) as hash_bloco
      from v_tarefas_atuais v join tarefas t on t.id = v.tarefa_id
      join linhas_importadas l on l.id = v.linha_id
      cross join lateral (select public.bloco_descricao_padrao(t.id) as bloco) b
     where v.situacao = 'pendente' and t.atlas_id is not null and b.bloco is not null
       and md5(b.bloco) is distinct from (select d.hash_bloco from descricoes_padronizadas d
                                           where d.tarefa_id = t.id and d.resultado = 'gravada' order by d.em desc limit 1)
     order by v.d7_data_agenda nulls last limit greatest(coalesce(p_limite, 200), 1)) x), '[]');
end $$;

create or replace function public.descricao_padronizada_registrar(p_tarefa bigint, p_hash text, p_resultado text, p_detalhe text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Somente administradores' using errcode = '42501'; end if;
  insert into descricoes_padronizadas (tarefa_id, atlas_id, hash_bloco, resultado, detalhe)
  select t.id, t.atlas_id, p_hash, p_resultado, p_detalhe from tarefas t where t.id = p_tarefa and t.atlas_id is not null;
end $$;

-- ---------------------------------------------------------------- Storage: bucket privado "pecas"
-- Pasta = id da tarefa. Envio e leitura só para quem pode trabalhar na tarefa (ou lê tudo).
do $$
begin
  insert into storage.buckets (id, name, public, file_size_limit)
  values ('pecas', 'pecas', false, 20971520) on conflict (id) do nothing;
  drop policy if exists pecas_envio on storage.objects;
  create policy pecas_envio on storage.objects for insert to authenticated
    with check (bucket_id = 'pecas' and public.pode_trabalhar_tarefa(public._tarefa_do_caminho(name)));
  drop policy if exists pecas_leitura on storage.objects;
  create policy pecas_leitura on storage.objects for select to authenticated
    using (bucket_id = 'pecas' and (public.pode_ler_tudo() or public.pode_trabalhar_tarefa(public._tarefa_do_caminho(name))));
exception when insufficient_privilege then
  raise warning '0039: sem permissão para configurar o Storage por SQL (%). Criar o bucket "pecas" e as políticas pelo painel do Supabase.', sqlerrm;
end $$;

-- ---------------------------------------------------------------- permissões
revoke execute on function public._linha_atual(bigint), public._modalidade_por_titulo(text), public.modalidade_da_tarefa(bigint), public.execucao_situacao(bigint),
                          public._tarefa_por_id_externo(text), public.bloco_descricao_padrao(bigint) from public, anon, authenticated;
revoke execute on function public.pode_trabalhar_tarefa(bigint), public.execucao_tarefa(bigint),
                          public.ext_execucao(text), public.execucao_marcar(bigint, text, boolean, text),
                          public.ext_execucao_marcar(text, text, boolean), public._tarefa_do_caminho(text), public._texto_busca(text),
                          public.anexo_registrar(bigint, text, text, text, bigint, text, text),
                          public.ext_anexo_registrar(text, text, text, text, bigint, text),
                          public.admin_salvar_modalidade(jsonb, text), public.definir_modalidade_tarefa(bigint, bigint, boolean),
                          public.minha_pauta(bigint, int), public.descricoes_para_padronizar(int),
                          public.descricao_padronizada_registrar(bigint, text, text, text) from public, anon;
grant execute on function public.pode_trabalhar_tarefa(bigint), public.execucao_tarefa(bigint),
                          public.ext_execucao(text), public.execucao_marcar(bigint, text, boolean, text),
                          public.ext_execucao_marcar(text, text, boolean), public._tarefa_do_caminho(text), public._texto_busca(text),
                          public.anexo_registrar(bigint, text, text, text, bigint, text, text),
                          public.ext_anexo_registrar(text, text, text, text, bigint, text),
                          public.admin_salvar_modalidade(jsonb, text), public.definir_modalidade_tarefa(bigint, bigint, boolean),
                          public.minha_pauta(bigint, int), public.descricoes_para_padronizar(int),
                          public.descricao_padronizada_registrar(bigint, text, text, text) to authenticated;
