-- =====================================================================
-- 0061 — Workflows jurídicos, fase 1 (controladoria, 26/11/2026). Aditiva.
-- Especificação: "Especificação Técnica dos Workflows Jurídicos – Atlas" v1.0 (controladoria).
-- Fase 1 = workflow-mestre (tratamento de intimações) + rotinas transversais de comunicação com o
-- cliente, solicitação de documentos e protocolo operacional.
--
-- Por que o motor fica aqui e não no Atlas: o Gestor Flow do Atlas (conferido em 26/11/2026) não tem
-- condições, dependências nem encadeamento (tarefa criada por ele não dispara "Tarefa Concluída").
-- Aqui cada etapa vira UMA tarefa no Atlas (create_task, com Idempotency-Key) só quando é liberada:
--   * dependências: a etapa espera as etapas de que depende ficarem concluídas ou dispensadas;
--     etapas sem dependência entre si correm em paralelo (ex.: documentos × elaboração da peça);
--   * condições (SE/ENTÃO): a etapa só existe se a decisão do advogado ou da controladoria disser que
--     sim (precisa de documentos? de comunicação? de peça?). Resposta "não" = etapa dispensada;
--     sem resposta = a etapa espera ("aguardando decisão");
--   * rotinas transversais: uma etapa pode abrir um fluxo filho (comunicação, documentos, protocolo);
--     a etapa termina quando o filho termina;
--   * responsável por PAPEL: advogado (escolhido na triagem), assistente (da equipe, tabela
--     equipes_assistentes) e controladoria (parâmetro wf_controladoria_email);
--   * uma tarefa por troca de responsável: os passos miúdos da especificação viram checklist na
--     descrição da tarefa, para não encher a pauta de tarefas de 5 minutos.
-- O ciclo (Edge Function atlas-sync, ação "workflows", a cada 10 minutos pelo agendamento):
--   1) lê no Atlas as tarefas concluídas desde o último ciclo (list_tasks) e marca as etapas;
--   2) libera as etapas seguintes;  3) cria no Atlas as etapas liberadas (se wf_criar_no_atlas = true).
-- O PF continua valendo em qualquer caso: pendência do cliente não suspende a etapa jurídica.
-- Segurança: tabelas sem acesso direto; tudo por funções SECURITY DEFINER com checagem de perfil.
-- =====================================================================

-- ---------------------------------------------------------------- parâmetros
insert into public.parametros (chave, valor, confirmado, descricao) values
 ('wf_criar_no_atlas', 'false', false,
  'Workflows (0061): cria no Atlas as etapas liberadas. Desligado até a controladoria conferir o primeiro fluxo de teste; enquanto isso as etapas ficam "liberadas" só no painel.'),
 ('wf_controladoria_email', to_jsonb(coalesce((select valor #>> '{}' from public.parametros where chave = 'tarefa_analise_responsavel_email'), '')), false,
  'Workflows (0061): e-mail do usuário do Atlas que recebe as etapas da controladoria (protocolo, registro de ciência).')
on conflict (chave) do nothing;

-- ---------------------------------------------------------------- assistentes por equipe
create table if not exists public.equipes_assistentes (
  equipe_id      bigint primary key references public.equipes(id),
  colaborador_id bigint not null references public.colaboradores(id),
  criado_em      timestamptz not null default now(),
  atualizado_em  timestamptz not null default now()
);
alter table public.equipes_assistentes enable row level security;
revoke all on public.equipes_assistentes from anon, authenticated;
drop trigger if exists equipes_assistentes_auditoria on public.equipes_assistentes;
create trigger equipes_assistentes_auditoria after insert or update or delete on public.equipes_assistentes
  for each row execute function public.tg_auditar_configuracao();

-- assistentes informadas pela controladoria em 26/11/2026 (casadas pelo nome do cadastro de colaboradores)
do $$
declare r record; v_eq bigint; v_col bigint;
begin
  perform set_config('controladoria.motivo', 'Assistentes das equipes informadas pela controladoria em 26/11/2026 (0061)', true);
  for r in select * from (values ('Celeste', 'BARBARA FERREIRA DOS REIS'), ('Delta', 'ALICIA MORAIS DE ANDRADE DIAS'),
                                 ('Êxitos', 'CAMILA LUIZA SILVA REIS'), ('Prime', 'LUCAS MINARE VENDRAMINI'),
                                 ('Gold', 'ANA FREITAS')) x(equipe, nome) loop
    select id into v_eq from equipes where nome = r.equipe;
    select id into v_col from colaboradores where _nome_normalizado(nome_advbox) = r.nome order by (atlas_user_id is null), id limit 1;
    if v_eq is not null and v_col is not null then
      insert into equipes_assistentes (equipe_id, colaborador_id) values (v_eq, v_col) on conflict (equipe_id) do nothing;
    end if;
  end loop;
end $$;

-- ---------------------------------------------------------------- modelos
create table if not exists public.wf_modelos (
  id         bigint generated always as identity primary key,
  codigo     text not null unique,
  nome       text not null,
  tipo       text not null check (tipo in ('mestre','especializado','transversal')),
  descricao  text,
  ativo      boolean not null default true,
  criado_em  timestamptz not null default now()
);
create table if not exists public.wf_etapas_modelo (
  id              bigint generated always as identity primary key,
  modelo_id       bigint not null references public.wf_modelos(id),
  codigo          text not null,
  ordem           int not null,
  titulo          text not null,                    -- {providencia}, {motivo}, {cnj} são trocados pelos dados do fluxo
  papel           text check (papel in ('advogado','assistente','controladoria')),   -- null quando abre sub-fluxo
  sub_fluxo       text,                             -- código de um modelo transversal
  depende_de      text[] not null default '{}',     -- códigos de etapas do mesmo modelo
  condicao        text,                             -- chave da decisão; '!' na frente = só quando a resposta for "não"
  prazo_dias      int not null default 1 check (prazo_dias between 0 and 60),   -- dias úteis a partir da liberação
  teto_antes_pf   int check (teto_antes_pf between 0 and 30),  -- nunca depois de PF − n dias úteis (null = sem teto)
  leva_pf         boolean not null default false,   -- manda o PF como prazo fatal da tarefa no Atlas
  checklist       text[] not null default '{}',
  orientacao      text,
  exige_evidencia text,                             -- texto do que precisa ficar anexado (comprovante etc.)
  unique (modelo_id, codigo),
  check ((papel is null) <> (sub_fluxo is null))
);
-- decisões (condições) que cada modelo pergunta
create table if not exists public.wf_decisoes_modelo (
  modelo_id bigint not null references public.wf_modelos(id),
  chave     text not null,
  pergunta  text not null,
  quem      text not null default 'advogado' check (quem in ('advogado','controladoria')),
  apos      text,          -- código da etapa: a pergunta aparece quando ela termina (null = já na triagem)
  primary key (modelo_id, chave)
);

-- ---------------------------------------------------------------- instâncias
create table if not exists public.wf_instancias (
  id                        bigint generated always as identity primary key,
  modelo_id                 bigint not null references public.wf_modelos(id),
  pai_instancia_id          bigint references public.wf_instancias(id),
  pai_tarefa_id             bigint,                -- etapa do pai que abriu este fluxo
  status                    text not null default 'ativo' check (status in ('ativo','concluido','cancelado')),
  origem_tipo               text not null default 'manual' check (origem_tipo in ('atlas_intimacao','cnj','webjur','manual')),
  origem_id                 text,
  cnj                       text,
  cliente                   text,
  atlas_lawsuit_id          uuid,
  atlas_client_id           uuid,
  equipe_id                 bigint references public.equipes(id),
  advogado_colaborador_id   bigint references public.colaboradores(id),
  natureza                  text,
  providencia               text,
  modalidade_intimacao      text,
  data_recebimento          date,
  data_ciencia              date,
  prazo_legal_dias          int,
  pf                        date,
  link_intimacao            text,
  dados                     jsonb not null default '{}',   -- motivo da comunicação, finalidade dos documentos, tipo da peça…
  decisoes                  jsonb not null default '{}',   -- {"precisa_peca": true, ...}
  criado_por                uuid,
  criado_em                 timestamptz not null default now(),
  concluido_em              timestamptz,
  cancelado_motivo          text
);
create index if not exists wf_instancias_status_idx on public.wf_instancias (status, criado_em desc);
create index if not exists wf_instancias_pai_idx on public.wf_instancias (pai_instancia_id);
-- Regra 05 (duplicidade): a mesma intimação não abre dois fluxos-mestre ativos
create unique index if not exists wf_instancias_origem_unica on public.wf_instancias (origem_tipo, origem_id)
  where pai_instancia_id is null and status = 'ativo' and origem_id is not null;

create table if not exists public.wf_tarefas (
  id                bigint generated always as identity primary key,
  instancia_id      bigint not null references public.wf_instancias(id),
  etapa_modelo_id   bigint not null references public.wf_etapas_modelo(id),
  status            text not null default 'aguardando' check (status in
                      ('aguardando','aguardando_decisao','liberada','criando','criada','verificar','sem_responsavel',
                       'em_subfluxo','concluida','dispensada','cancelada')),
  titulo            text not null,
  papel             text,
  colaborador_id    bigint references public.colaboradores(id),
  liberada_em       timestamptz,
  prazo             date,
  atlas_task_id     uuid unique,
  atlas_app_url     text,
  tentativas        int not null default 0,
  criando_em        timestamptz,
  ultimo_erro       text,
  filho_instancia_id bigint references public.wf_instancias(id),
  concluida_em      timestamptz,
  concluida_por     text,                -- 'atlas' | 'painel' | 'subfluxo'
  nota              text,
  unique (instancia_id, etapa_modelo_id)
);
create index if not exists wf_tarefas_status_idx on public.wf_tarefas (status);

create table if not exists public.wf_eventos (
  id           bigint generated always as identity primary key,
  instancia_id bigint not null references public.wf_instancias(id),
  tarefa_id    bigint references public.wf_tarefas(id),
  tipo         text not null,
  detalhe      jsonb not null default '{}',
  usuario      uuid,
  ocorrido_em  timestamptz not null default now()
);
create index if not exists wf_eventos_inst_idx on public.wf_eventos (instancia_id, ocorrido_em);
drop trigger if exists wf_eventos_imutavel on public.wf_eventos;
create trigger wf_eventos_imutavel before update or delete on public.wf_eventos
  for each row execute function public.tg_bloqueia_alteracao();
drop trigger if exists wf_eventos_sem_truncate on public.wf_eventos;
create trigger wf_eventos_sem_truncate before truncate on public.wf_eventos
  for each statement execute function public.tg_bloqueia_alteracao();

-- histórico dos ciclos (leitura das conclusões + criação no Atlas)
create table if not exists public.wf_ciclos (
  id          bigint generated always as identity primary key,
  iniciado_em timestamptz not null,
  terminado_em timestamptz not null default now(),
  origem      text not null default 'painel',
  resultado   jsonb not null default '{}'
);
drop trigger if exists wf_ciclos_imutavel on public.wf_ciclos;
create trigger wf_ciclos_imutavel before update or delete on public.wf_ciclos
  for each row execute function public.tg_bloqueia_alteracao();

do $$ declare t text; begin
  foreach t in array array['wf_modelos','wf_etapas_modelo','wf_decisoes_modelo','wf_instancias','wf_tarefas','wf_eventos','wf_ciclos'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
  end loop;
end $$;
drop trigger if exists wf_etapas_modelo_auditoria on public.wf_etapas_modelo;
create trigger wf_etapas_modelo_auditoria after insert or update or delete on public.wf_etapas_modelo
  for each row execute function public.tg_auditar_configuracao();

-- ---------------------------------------------------------------- modelos da fase 1
insert into public.wf_modelos (codigo, nome, tipo, descricao) values
 ('MESTRE', 'Tratamento de intimações – cível', 'mestre',
  'Workflow-mestre: toda intimação é analisada, classificada, distribuída e encaminhada. A triagem (identificar processo e cliente, classificar, cadastrar o PF e distribuir) é feita pela controladoria no painel; o fluxo começa na análise do advogado.'),
 ('COMUNICACAO', 'Comunicação com o cliente', 'transversal', 'Rotina transversal 4.1.'),
 ('DOCUMENTOS', 'Solicitação de documentos', 'transversal', 'Rotina transversal 4.2.'),
 ('PROTOCOLO', 'Protocolo operacional', 'transversal', 'Rotina transversal 4.5.')
on conflict (codigo) do nothing;

do $$
declare m bigint; c bigint; d bigint; p bigint;
begin
  if exists (select 1 from wf_etapas_modelo) then return; end if;
  perform set_config('controladoria.motivo', 'Modelos da fase 1 dos workflows (0061)', true);
  select id into m from wf_modelos where codigo = 'MESTRE';
  select id into c from wf_modelos where codigo = 'COMUNICACAO';
  select id into d from wf_modelos where codigo = 'DOCUMENTOS';
  select id into p from wf_modelos where codigo = 'PROTOCOLO';

  insert into wf_etapas_modelo (modelo_id, codigo, ordem, titulo, papel, sub_fluxo, depende_de, condicao, prazo_dias, teto_antes_pf, leva_pf, checklist, orientacao, exige_evidencia) values
  (m, 'analise', 10, 'ANALISAR INTIMAÇÃO E DEFINIR PROVIDÊNCIA – {providencia} – {cnj}', 'advogado', null, '{}', null, 1, 5, false,
   array['Ler a intimação e o processo','Confirmar a providência e o prazo cadastrados pela controladoria',
         'Decidir: precisa de peça? de documentos ou informações do cliente? de comunicação ao cliente?',
         'Registrar as decisões no painel da controladoria (Workflows) ao concluir'],
   'As próximas etapas só são criadas depois que as decisões forem registradas no painel. O PF continua correndo.', null),
  (m, 'documentos', 20, 'Solicitação de documentos', null, 'DOCUMENTOS', array['analise'], 'precisa_documentos', 0, null, false, '{}', null, null),
  (m, 'comunicacao', 30, 'Comunicação ao cliente', null, 'COMUNICACAO', array['analise'], 'precisa_comunicacao', 0, null, false, '{}', null, null),
  (m, 'peca', 40, 'ELABORAR E REVISAR PEÇA – {providencia} – {cnj}', 'advogado', null, array['analise'], 'precisa_peca', 3, 3, true,
   array['Elaborar a peça','Conferir fundamentos, pedidos e documentos','Revisar e validar','Anexar a peça validada e liberar para protocolo'],
   'Corre em paralelo à busca de documentos: a falta de resposta do cliente não congela o PF. Entrega até o D-4.', 'Peça validada anexada'),
  (m, 'protocolo', 50, 'Protocolo', null, 'PROTOCOLO', array['peca'], 'precisa_peca', 0, null, false, '{}', null, null),
  (m, 'ciencia', 60, 'REGISTRAR CIÊNCIA E CLASSIFICAR ANDAMENTO – {cnj}', 'controladoria', null, array['analise'], '!precisa_peca', 1, null, false,
   array['Registrar a ciência da intimação','Classificar o andamento','Criar monitoramento, se necessário'],
   'Intimação sem providência processual imediata (validada pelo advogado).', null),

  (c, 'comunicar', 10, 'COMUNICAR CLIENTE – {motivo} – {cnj}', 'assistente', null, '{}', null, 1, 4, false,
   array['Receber do advogado a orientação e o conteúdo','Conferir destinatário e canal','Enviar a comunicação',
         'Registrar o envio e o conteúdo','Acompanhar a resposta, se houver','Encaminhar a resposta ao advogado'],
   'Se envolver orientação jurídica, o texto precisa da validação do advogado antes do envio. Cliente sem resposta: registrar as tentativas e avisar o advogado.', 'Registro do envio'),
  (c, 'resposta', 20, 'ANALISAR RESPOSTA DO CLIENTE – {motivo} – {cnj}', 'advogado', null, array['comunicar'], 'aguarda_resposta', 1, 4, false,
   array['Ler a resposta do cliente','Definir a providência decorrente'], null, null),

  (d, 'solicitar', 10, 'SOLICITAR DOCUMENTOS – {finalidade} – {cnj}', 'assistente', null, '{}', null, 2, 5, false,
   array['Receber do advogado a relação de documentos','Encaminhar a solicitação detalhada ao cliente','Acompanhar e cobrar a resposta',
         'Conferir se o envio foi integral','Encaminhar os documentos ao advogado'],
   'Sem resposta do cliente: registrar as tentativas e escalar. A pendência não suspende o prazo judicial.', 'Documentos recebidos ou registro das tentativas'),
  (d, 'validar', 20, 'VALIDAR DOCUMENTOS RECEBIDOS – {finalidade} – {cnj}', 'advogado', null, array['solicitar'], null, 1, 4, false,
   array['Conferir adequação e integridade','Pedir complementação ou avaliar alternativa jurídica, se faltar algo'], null, null),

  (p, 'protocolar', 10, 'PROTOCOLAR – {providencia} – {cnj}', 'controladoria', null, '{}', null, 1, 1, true,
   array['Receber a peça validada pelo advogado','Conferir processo e documentos anexos','Realizar o protocolo',
         'Anexar o comprovante','Conferir o registro e a atualização do processo','Comunicar falha ou inconsistência, se houver'],
   'Regra de segurança: sem peça validada pelo advogado, não protocolar (salvo exceção autorizada e documentada).', 'Comprovante de protocolo');

  insert into wf_decisoes_modelo (modelo_id, chave, pergunta, quem, apos) values
  (m, 'precisa_peca', 'Precisa elaborar e protocolar peça?', 'advogado', 'analise'),
  (m, 'precisa_documentos', 'Precisa de documentos ou informações do cliente?', 'advogado', 'analise'),
  (m, 'precisa_comunicacao', 'Precisa comunicar o cliente?', 'advogado', 'analise'),
  (c, 'aguarda_resposta', 'A comunicação depende de resposta do cliente?', 'advogado', 'comunicar');
end $$;

-- ---------------------------------------------------------------- auxiliares internos
create or replace function public._wf_evento(p_inst bigint, p_tarefa bigint, p_tipo text, p_detalhe jsonb)
returns void language sql security definer set search_path = public as $$
  insert into wf_eventos (instancia_id, tarefa_id, tipo, detalhe, usuario) values (p_inst, p_tarefa, p_tipo, coalesce(p_detalhe, '{}'), auth.uid())
$$;

-- quem vê o fluxo: controladoria e diretoria; o advogado, a assistente e o líder da equipe (meus_colaboradores)
create or replace function public._wf_pode_ver(p_inst bigint) returns boolean
language sql stable security definer set search_path = public as $$
  select public.pode_ler_tudo() or exists (
    select 1 from wf_instancias i
     where i.id = coalesce((select coalesce(r.pai_instancia_id, r.id) from wf_instancias r where r.id = p_inst), p_inst)
       and (i.advogado_colaborador_id = any(public.meus_colaboradores())
            or (select colaborador_id from equipes_assistentes where equipe_id = i.equipe_id) = any(public.meus_colaboradores())
            or exists (select 1 from lideres_equipes le where le.user_id = auth.uid() and le.equipe_id = i.equipe_id)))
$$;

-- quem decide: controladoria; o advogado do fluxo; o líder da equipe
create or replace function public._wf_pode_decidir(p_inst bigint) returns boolean
language sql stable security definer set search_path = public as $$
  select public.is_admin() or exists (
    select 1 from wf_instancias i
     where i.id = coalesce((select coalesce(r.pai_instancia_id, r.id) from wf_instancias r where r.id = p_inst), p_inst)
       and ((i.advogado_colaborador_id is not null and i.advogado_colaborador_id = (select colaborador_id from perfis where user_id = auth.uid()))
            or exists (select 1 from lideres_equipes le join perfis pf on pf.user_id = le.user_id and pf.papel = 'lider'
                        where le.user_id = auth.uid() and le.equipe_id = i.equipe_id)))
$$;

-- fluxo raiz (mestre) de qualquer fluxo
create or replace function public._wf_raiz(p_inst bigint) returns bigint
language sql stable security definer set search_path = public as $$
  select coalesce(pai_instancia_id, id) from wf_instancias where id = p_inst
$$;

-- prazo da etapa: n dias úteis a partir de hoje, nunca depois de PF − teto; nunca antes de hoje
create or replace function public._wf_prazo(p_dias int, p_teto int, p_pf date) returns date
language plpgsql stable set search_path = public as $$
declare v date := case when p_dias > 0 then somar_dias_uteis(hoje_brasilia(), p_dias) else hoje_brasilia() end; v_teto date;
begin
  if p_pf is not null and p_teto is not null then
    v_teto := somar_dias_uteis(p_pf, -p_teto);
    if v_teto < v then v := v_teto; end if;
  end if;
  if v < hoje_brasilia() then v := hoje_brasilia(); end if;
  return v;
end $$;

create or replace function public._wf_texto(p_modelo text, p_inst wf_instancias) returns text
language sql stable set search_path = public as $$
  select replace(replace(replace(replace(p_modelo,
    '{providencia}', coalesce(nullif(p_inst.providencia, ''), coalesce(p_inst.natureza, 'PROVIDÊNCIA'))),
    '{motivo}', coalesce(nullif(p_inst.dados->>'motivo', ''), coalesce(p_inst.providencia, 'ANDAMENTO'))),
    '{finalidade}', coalesce(nullif(p_inst.dados->>'finalidade', ''), coalesce(p_inst.providencia, 'PROCESSO'))),
    '{cnj}', coalesce(p_inst.cnj, 'SEM PROCESSO'))
$$;

-- responsável pelo papel: (colaborador, usuário do Atlas, e-mail do Atlas, problema)
create or replace function public._wf_responsavel(p_inst bigint, p_papel text,
  out colaborador_id bigint, out atlas_user uuid, out email text, out problema text)
language plpgsql stable security definer set search_path = public as $$
declare i wf_instancias;
begin
  select * into i from wf_instancias where id = _wf_raiz(p_inst);
  if p_papel = 'advogado' then
    colaborador_id := i.advogado_colaborador_id;
    if colaborador_id is null then problema := 'Fluxo sem advogado responsável'; return; end if;
  elsif p_papel = 'assistente' then
    select ea.colaborador_id into colaborador_id from equipes_assistentes ea where ea.equipe_id = i.equipe_id;
    if colaborador_id is null then
      problema := case when i.equipe_id is null then 'Fluxo sem equipe: não há como saber a assistente'
                       else 'Equipe ' || (select nome from equipes where id = i.equipe_id) || ' sem assistente cadastrada' end;
      return;
    end if;
  elsif p_papel = 'controladoria' then
    email := nullif(btrim((select valor #>> '{}' from parametros where chave = 'wf_controladoria_email')), '');
    if email is null then problema := 'Parâmetro wf_controladoria_email vazio'; end if;
    return;
  else
    problema := 'Papel desconhecido: ' || coalesce(p_papel, '(vazio)'); return;
  end if;
  select c.atlas_user_id into atlas_user from colaboradores c where c.id = colaborador_id;
  if atlas_user is null then
    problema := (select nome_advbox from colaboradores where id = colaborador_id) || ' não tem usuário do Atlas ligado';
  end if;
end $$;

-- cria um fluxo e as etapas dele (sem checar permissão: quem chama já checou)
create or replace function public._wf_criar_instancia(p_modelo text, p_pai_inst bigint, p_pai_tarefa bigint, p_campos jsonb)
returns bigint language plpgsql security definer set search_path = public as $$
declare m wf_modelos; v_id bigint; i wf_instancias; e record;
begin
  select * into m from wf_modelos where codigo = p_modelo and ativo;
  if m.id is null then raise exception 'Modelo de workflow % inexistente ou inativo', p_modelo; end if;
  insert into wf_instancias (modelo_id, pai_instancia_id, pai_tarefa_id, origem_tipo, origem_id, cnj, cliente, atlas_lawsuit_id,
      atlas_client_id, equipe_id, advogado_colaborador_id, natureza, providencia, modalidade_intimacao, data_recebimento,
      data_ciencia, prazo_legal_dias, pf, link_intimacao, dados, decisoes, criado_por)
  values (m.id, p_pai_inst, p_pai_tarefa, coalesce(p_campos->>'origem_tipo', 'manual'),
      nullif(p_campos->>'origem_id', ''), nullif(p_campos->>'cnj', ''), nullif(p_campos->>'cliente', ''),
      nullif(p_campos->>'atlas_lawsuit_id', '')::uuid, nullif(p_campos->>'atlas_client_id', '')::uuid,
      nullif(p_campos->>'equipe_id', '')::bigint, nullif(p_campos->>'advogado_colaborador_id', '')::bigint,
      nullif(p_campos->>'natureza', ''), nullif(p_campos->>'providencia', ''), nullif(p_campos->>'modalidade_intimacao', ''),
      nullif(p_campos->>'data_recebimento', '')::date, nullif(p_campos->>'data_ciencia', '')::date,
      nullif(p_campos->>'prazo_legal_dias', '')::int, nullif(p_campos->>'pf', '')::date, nullif(p_campos->>'link_intimacao', ''),
      coalesce(p_campos->'dados', '{}'), coalesce(p_campos->'decisoes', '{}'), auth.uid())
  returning * into i;
  for e in select * from wf_etapas_modelo where modelo_id = m.id order by ordem loop
    insert into wf_tarefas (instancia_id, etapa_modelo_id, titulo, papel)
    values (i.id, e.id, left(_wf_texto(coalesce(e.titulo, ''), i), 500), e.papel);
  end loop;
  perform _wf_evento(i.id, p_pai_tarefa, 'fluxo_iniciado', jsonb_build_object('modelo', p_modelo, 'pai', p_pai_inst));
  return i.id;
end $$;

-- motor: libera, dispensa, abre sub-fluxos e encerra. Idempotente; chamado depois de qualquer mudança.
create or replace function public._wf_avancar(p_inst bigint) returns void
language plpgsql security definer set search_path = public as $$
declare i wf_instancias; t record; v_deps_ok boolean; v_cond text; v_neg boolean; v_resp jsonb; v_r record;
        v_filho bigint; v_mudou boolean := true; v_voltas int := 0; v_pai record;
begin
  select * into i from wf_instancias where id = p_inst for update;
  if i.id is null or i.status <> 'ativo' then return; end if;
  while v_mudou and v_voltas < 20 loop
    v_mudou := false; v_voltas := v_voltas + 1;
    for t in select wt.*, em.codigo, em.depende_de, em.condicao, em.sub_fluxo, em.prazo_dias, em.teto_antes_pf
               from wf_tarefas wt join wf_etapas_modelo em on em.id = wt.etapa_modelo_id
              where wt.instancia_id = i.id and wt.status in ('aguardando','aguardando_decisao','sem_responsavel')
              order by em.ordem loop
      -- dependências: todas concluídas ou dispensadas
      select coalesce(bool_and(x.status in ('concluida','dispensada')), true) into v_deps_ok
        from wf_tarefas x join wf_etapas_modelo xm on xm.id = x.etapa_modelo_id
       where x.instancia_id = i.id and xm.codigo = any(t.depende_de);
      if not v_deps_ok then continue; end if;
      -- condição (SE/ENTÃO)
      if t.condicao is not null then
        v_neg := left(t.condicao, 1) = '!'; v_cond := ltrim(t.condicao, '!');
        v_resp := (select decisoes from wf_instancias where id = i.id) -> v_cond;
        if v_resp is null or jsonb_typeof(v_resp) <> 'boolean' then
          if t.status <> 'aguardando_decisao' then
            update wf_tarefas set status = 'aguardando_decisao' where id = t.id;
          end if;
          continue;
        end if;
        if (v_resp::boolean) = v_neg then
          update wf_tarefas set status = 'dispensada', concluida_em = now(),
                 nota = 'Dispensada pela decisão: ' || coalesce((select pergunta from wf_decisoes_modelo where modelo_id = i.modelo_id and chave = v_cond), v_cond)
                        || ' ' || case when v_resp::boolean then 'Sim' else 'Não' end
           where id = t.id;
          perform _wf_evento(i.id, t.id, 'etapa_dispensada', jsonb_build_object('condicao', t.condicao, 'resposta', v_resp));
          v_mudou := true; continue;
        end if;
      end if;
      -- sub-fluxo: abre o filho com os dados do pai
      if t.sub_fluxo is not null then
        v_filho := _wf_criar_instancia(t.sub_fluxo, i.id, t.id, jsonb_build_object(
          'cnj', i.cnj, 'cliente', i.cliente, 'atlas_lawsuit_id', i.atlas_lawsuit_id, 'atlas_client_id', i.atlas_client_id,
          'equipe_id', i.equipe_id, 'advogado_colaborador_id', i.advogado_colaborador_id, 'natureza', i.natureza,
          'providencia', i.providencia, 'pf', i.pf, 'link_intimacao', i.link_intimacao, 'dados', i.dados,
          'decisoes', coalesce(i.dados->'decisoes_filhos'->t.sub_fluxo, '{}')));
        update wf_tarefas set status = 'em_subfluxo', filho_instancia_id = v_filho, liberada_em = now() where id = t.id;
        perform _wf_avancar(v_filho);
        v_mudou := true; continue;
      end if;
      -- responsável e prazo
      select * into v_r from _wf_responsavel(i.id, t.papel);
      if v_r.problema is not null then
        if t.status <> 'sem_responsavel' or coalesce(t.ultimo_erro, '') <> v_r.problema then
          update wf_tarefas set status = 'sem_responsavel', ultimo_erro = v_r.problema, colaborador_id = v_r.colaborador_id where id = t.id;
          perform _wf_evento(i.id, t.id, 'sem_responsavel', jsonb_build_object('problema', v_r.problema));
        end if;
        continue;
      end if;
      update wf_tarefas set status = 'liberada', liberada_em = now(), colaborador_id = v_r.colaborador_id, ultimo_erro = null,
             prazo = _wf_prazo(t.prazo_dias, t.teto_antes_pf, i.pf)
       where id = t.id;
      perform _wf_evento(i.id, t.id, 'etapa_liberada', jsonb_build_object('papel', t.papel, 'colaborador_id', v_r.colaborador_id));
      v_mudou := true;
    end loop;
  end loop;
  -- encerramento: todas as etapas concluídas ou dispensadas
  if not exists (select 1 from wf_tarefas where instancia_id = i.id and status not in ('concluida','dispensada','cancelada')) then
    update wf_instancias set status = 'concluido', concluido_em = now() where id = i.id;
    perform _wf_evento(i.id, null, 'fluxo_concluido', '{}');
    if i.pai_tarefa_id is not null then
      update wf_tarefas set status = 'concluida', concluida_em = now(), concluida_por = 'subfluxo' where id = i.pai_tarefa_id and status = 'em_subfluxo';
      perform _wf_evento(i.pai_instancia_id, i.pai_tarefa_id, 'etapa_concluida', jsonb_build_object('via', 'subfluxo', 'filho', i.id));
      perform _wf_avancar(i.pai_instancia_id);
    end if;
  end if;
end $$;

create or replace function public._wf_concluir_tarefa(p_tarefa bigint, p_via text, p_nota text) returns boolean
language plpgsql security definer set search_path = public as $$
declare t wf_tarefas;
begin
  select * into t from wf_tarefas where id = p_tarefa for update;
  if t.id is null or t.status in ('concluida','dispensada','cancelada','em_subfluxo') then return false; end if;
  update wf_tarefas set status = 'concluida', concluida_em = now(), concluida_por = p_via, nota = coalesce(p_nota, nota) where id = t.id;
  perform _wf_evento(t.instancia_id, t.id, 'etapa_concluida', jsonb_build_object('via', p_via, 'nota', p_nota));
  perform _wf_avancar(t.instancia_id);
  return true;
end $$;

-- ---------------------------------------------------------------- triagem (controladoria)
-- dados para pré-preencher a triagem a partir de uma intimação (Atlas, CNJ ou Webjur)
create or replace function public.wf_triagem_dados(p_origem_tipo text, p_origem_id text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r jsonb := '{}'; v_cnj text; v_cli text; v_cod text;
begin
  if not is_admin() then raise exception 'Somente a controladoria faz a triagem' using errcode = '42501'; end if;
  if p_origem_tipo = 'atlas_intimacao' then
    select jsonb_build_object('cnj', coalesce(a.cnj, a.process_number), 'cliente', a.client_name, 'atlas_lawsuit_id', a.lawsuit_id,
             'atlas_client_id', a.client_id, 'pf', a.deadline_fatal, 'data_ciencia', coalesce(a.publication_date, a.available_date),
             'natureza', a.inferred_type, 'link_intimacao', a.app_url, 'resumo', a.resumo)
      into r from atlas_intimacoes a where a.id::text = p_origem_id;
  elsif p_origem_tipo = 'cnj' then
    select jsonb_build_object('cnj', c.cnj, 'data_ciencia', c.data_disponibilizacao, 'natureza', c.tipo_comunicacao,
             'link_intimacao', c.link, 'resumo', left(c.texto, 600))
      into r from cnj_comunicacoes c where c.id::text = p_origem_id;
  elsif p_origem_tipo = 'webjur' then
    select jsonb_build_object('cnj', p.cnj, 'data_ciencia', coalesce(p.data_publicacao, p.data_disponibilizacao),
             'link_intimacao', p.url_origem, 'resumo', left(coalesce(p.resumo, p.teor), 600))
      into r from publicacoes p where p.id::text = p_origem_id;
  end if;
  if r is null then raise exception 'Intimação % (%) não encontrada', p_origem_id, p_origem_tipo; end if;
  v_cnj := r->>'cnj';
  -- processo do Atlas e cliente (carteira do CNJ / cadastro no Atlas)
  if r->>'atlas_lawsuit_id' is null and v_cnj is not null then
    r := r || jsonb_strip_nulls(jsonb_build_object('atlas_lawsuit_id',
           coalesce((select atlas_lawsuit_id from cnj_carteira where cnj = v_cnj and atlas_lawsuit_id ~ '^[0-9a-f-]{36}$' limit 1),
                    (select atlas_lawsuit_id from atlas_cadastro where cnj = v_cnj and atlas_lawsuit_id ~ '^[0-9a-f-]{36}$' limit 1))));
  end if;
  if r->>'atlas_client_id' is null and v_cnj is not null then
    r := r || jsonb_strip_nulls(jsonb_build_object('atlas_client_id', (select atlas_client_id from atlas_cadastro where cnj = v_cnj limit 1)));
  end if;
  v_cli := coalesce(r->>'cliente', (select atlas_cliente_nome from atlas_cadastro where cnj = v_cnj limit 1),
                    (select cliente from cnj_carteira where cnj = v_cnj limit 1));
  if v_cli is not null then r := r || jsonb_build_object('cliente', v_cli); end if;
  -- equipe pela letra do código do cliente (equipes_por_letra, confirmado em 16/11/2026)
  v_cod := coalesce((select codigo from atlas_clientes where id = (r->>'atlas_client_id')::uuid), _codigo_cliente(split_part(v_cli, ';', 1)));
  r := r || jsonb_strip_nulls(jsonb_build_object('equipe_id', (select e.id from equipes e
          where e.nome = (select valor ->> left(v_cod, 1) from parametros where chave = 'equipes_por_letra'))));
  r := r || jsonb_build_object('fluxo_ativo', (select id from wf_instancias where origem_tipo = p_origem_tipo and origem_id = p_origem_id
                                                and pai_instancia_id is null and status = 'ativo'));
  return jsonb_build_object('origem_tipo', p_origem_tipo, 'origem_id', p_origem_id) || r;
end $$;

-- inicia o workflow-mestre (campos obrigatórios da seção 1.2 da especificação)
create or replace function public.wf_iniciar(p_campos jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_id bigint; v_falta text[] := '{}'; v_tem_prazo boolean := coalesce((p_campos->>'tem_prazo')::boolean, true);
        v_dec jsonb := coalesce(p_campos->'decisoes', '{}'); k text;
begin
  if not is_admin() then raise exception 'Somente a controladoria faz a triagem' using errcode = '42501'; end if;
  if coalesce(btrim(p_campos->>'cnj'), '') = '' then v_falta := array_append(v_falta, 'número do processo'); end if;
  if coalesce(btrim(p_campos->>'cliente'), '') = '' then v_falta := array_append(v_falta, 'cliente'); end if;
  if coalesce(btrim(p_campos->>'origem_tipo'), '') = '' then v_falta := array_append(v_falta, 'origem da intimação'); end if;
  if coalesce(p_campos->>'data_recebimento', '') = '' then v_falta := array_append(v_falta, 'data de recebimento'); end if;
  if coalesce(p_campos->>'data_ciencia', '') = '' then v_falta := array_append(v_falta, 'data da publicação ou ciência'); end if;
  if coalesce(btrim(p_campos->>'modalidade_intimacao'), '') = '' then v_falta := array_append(v_falta, 'modalidade da intimação'); end if;
  if coalesce(btrim(p_campos->>'natureza'), '') = '' then v_falta := array_append(v_falta, 'natureza da intimação'); end if;
  if coalesce(btrim(p_campos->>'providencia'), '') = '' then v_falta := array_append(v_falta, 'providência jurídica'); end if;
  if coalesce(p_campos->>'advogado_colaborador_id', '') = '' then v_falta := array_append(v_falta, 'advogado responsável'); end if;
  if coalesce(p_campos->>'equipe_id', '') = '' then v_falta := array_append(v_falta, 'equipe'); end if;
  -- Regra 04: com prazo judicial, a triagem não termina sem PF validado
  if v_tem_prazo and coalesce(p_campos->>'pf', '') = '' then v_falta := array_append(v_falta, 'prazo fatal (PF)'); end if;
  if array_length(v_falta, 1) > 0 then raise exception 'Triagem incompleta. Falta: %', array_to_string(v_falta, ', '); end if;
  if v_tem_prazo and (p_campos->>'pf')::date < hoje_brasilia() then raise exception 'O PF informado (%) já passou', to_char((p_campos->>'pf')::date, 'DD/MM/YYYY'); end if;
  if not exists (select 1 from colaboradores where id = (p_campos->>'advogado_colaborador_id')::bigint) then raise exception 'Advogado inexistente'; end if;
  for k in select jsonb_object_keys(v_dec) loop
    if k not in (select chave from wf_decisoes_modelo d join wf_modelos m on m.id = d.modelo_id where m.codigo = 'MESTRE')
       or jsonb_typeof(v_dec->k) <> 'boolean' then raise exception 'Decisão inválida: %', k; end if;
  end loop;
  -- Regra 05: duplicidade
  if nullif(p_campos->>'origem_id', '') is not null and exists (select 1 from wf_instancias where origem_tipo = p_campos->>'origem_tipo'
       and origem_id = p_campos->>'origem_id' and pai_instancia_id is null and status = 'ativo') then
    raise exception 'Esta intimação já tem um fluxo ativo (#%): confira antes de abrir outro',
      (select id from wf_instancias where origem_tipo = p_campos->>'origem_tipo' and origem_id = p_campos->>'origem_id'
          and pai_instancia_id is null and status = 'ativo');
  end if;
  v_id := _wf_criar_instancia('MESTRE', null, null, p_campos || jsonb_build_object('pf', case when v_tem_prazo then p_campos->>'pf' end));
  perform _wf_evento(v_id, null, 'triagem', jsonb_build_object('campos', p_campos));
  perform _wf_avancar(v_id);
  return wf_detalhe(v_id);
end $$;

-- respostas às decisões (SE/ENTÃO). Só preenche o que ainda está vazio, a não ser que a controladoria corrija.
create or replace function public.wf_decidir(p_instancia bigint, p_respostas jsonb, p_nota text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare i wf_instancias; k text; v_ant jsonb;
begin
  if not _wf_pode_decidir(p_instancia) then raise exception 'Somente o advogado do fluxo, o líder da equipe ou a controladoria decidem' using errcode = '42501'; end if;
  select * into i from wf_instancias where id = p_instancia for update;
  if i.id is null then raise exception 'Fluxo % inexistente', p_instancia; end if;
  if i.status <> 'ativo' then raise exception 'Fluxo % não está ativo', p_instancia; end if;
  if jsonb_typeof(p_respostas) <> 'object' then raise exception 'Respostas inválidas'; end if;
  for k in select jsonb_object_keys(p_respostas) loop
    if not exists (select 1 from wf_decisoes_modelo where modelo_id = i.modelo_id and chave = k) then raise exception 'Decisão desconhecida neste fluxo: %', k; end if;
    if jsonb_typeof(p_respostas->k) <> 'boolean' then raise exception 'A resposta de % deve ser sim ou não', k; end if;
    v_ant := i.decisoes -> k;
    if v_ant is not null and v_ant <> p_respostas->k then
      if not is_admin() then raise exception 'A decisão "%" já foi registrada; só a controladoria corrige', k; end if;
      if exists (select 1 from wf_tarefas wt join wf_etapas_modelo em on em.id = wt.etapa_modelo_id
                  where wt.instancia_id = i.id and ltrim(em.condicao, '!') = k
                    and wt.status not in ('aguardando','aguardando_decisao','dispensada')) then
        raise exception 'A decisão "%" já gerou etapas: cancele ou dispense as etapas antes de mudar', k;
      end if;
      update wf_tarefas wt set status = 'aguardando', nota = null, concluida_em = null from wf_etapas_modelo em
       where em.id = wt.etapa_modelo_id and wt.instancia_id = i.id and ltrim(em.condicao, '!') = k and wt.status = 'dispensada';
    end if;
  end loop;
  update wf_instancias set decisoes = decisoes || p_respostas where id = i.id;
  perform _wf_evento(i.id, null, 'decisao', jsonb_build_object('respostas', p_respostas, 'nota', p_nota));
  perform _wf_avancar(i.id);
  return wf_detalhe(_wf_raiz(i.id));
end $$;

-- controladoria: conclui uma etapa pelo painel (feita fora do Atlas) ou a dispensa, sempre com justificativa
create or replace function public.wf_etapa_manual(p_tarefa bigint, p_acao text, p_nota text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare t wf_tarefas;
begin
  if not is_admin() then raise exception 'Somente a controladoria' using errcode = '42501'; end if;
  if length(btrim(coalesce(p_nota, ''))) < 15 then raise exception 'Informe a justificativa (mínimo de 15 caracteres)'; end if;
  select * into t from wf_tarefas where id = p_tarefa for update;
  if t.id is null then raise exception 'Etapa % inexistente', p_tarefa; end if;
  if (select status from wf_instancias where id = t.instancia_id) <> 'ativo' then raise exception 'Fluxo não está ativo'; end if;
  if p_acao = 'concluir' then
    if t.status in ('concluida','dispensada','cancelada') then raise exception 'Etapa já encerrada (%)', t.status; end if;
    if t.status = 'em_subfluxo' then raise exception 'Esta etapa termina quando o fluxo filho (#%) terminar', t.filho_instancia_id; end if;
    perform _wf_concluir_tarefa(t.id, 'painel', btrim(p_nota));
  elsif p_acao = 'dispensar' then
    if t.status in ('concluida','dispensada','cancelada') then raise exception 'Etapa já encerrada (%)', t.status; end if;
    if t.status = 'em_subfluxo' then
      perform wf_cancelar(t.filho_instancia_id, 'Etapa dispensada no fluxo pai: ' || btrim(p_nota));
    end if;
    update wf_tarefas set status = 'dispensada', concluida_em = now(), concluida_por = 'painel', nota = btrim(p_nota) where id = t.id;
    perform _wf_evento(t.instancia_id, t.id, 'etapa_dispensada', jsonb_build_object('nota', btrim(p_nota), 'atlas_task_id', t.atlas_task_id));
    perform _wf_avancar(t.instancia_id);
  elsif p_acao = 'recriar' then
    if t.status not in ('verificar','sem_responsavel') then raise exception 'Só etapas em "verificar" ou "sem responsável" são reenviadas'; end if;
    update wf_tarefas set status = case when t.status = 'verificar' then 'liberada' else 'aguardando' end, ultimo_erro = null where id = t.id;
    perform _wf_evento(t.instancia_id, t.id, 'etapa_reenviada', jsonb_build_object('nota', btrim(p_nota)));
    perform _wf_avancar(t.instancia_id);
  else
    raise exception 'Ação desconhecida: %', p_acao;
  end if;
  return wf_detalhe(_wf_raiz(t.instancia_id));
end $$;

create or replace function public.wf_cancelar(p_instancia bigint, p_motivo text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare i wf_instancias; f bigint;
begin
  if not is_admin() then raise exception 'Somente a controladoria' using errcode = '42501'; end if;
  if length(btrim(coalesce(p_motivo, ''))) < 15 then raise exception 'Informe o motivo (mínimo de 15 caracteres)'; end if;
  select * into i from wf_instancias where id = p_instancia for update;
  if i.id is null then raise exception 'Fluxo % inexistente', p_instancia; end if;
  if i.status <> 'ativo' then raise exception 'Fluxo % não está ativo', p_instancia; end if;
  for f in select filho_instancia_id from wf_tarefas where instancia_id = i.id and status = 'em_subfluxo' and filho_instancia_id is not null loop
    perform wf_cancelar(f, p_motivo);
  end loop;
  update wf_tarefas set status = 'cancelada', nota = btrim(p_motivo)
   where instancia_id = i.id and status not in ('concluida','dispensada','cancelada');
  update wf_instancias set status = 'cancelado', cancelado_motivo = btrim(p_motivo), concluido_em = now() where id = i.id;
  perform _wf_evento(i.id, null, 'fluxo_cancelado', jsonb_build_object('motivo', btrim(p_motivo),
    'tarefas_no_atlas', (select coalesce(jsonb_agg(atlas_task_id), '[]') from wf_tarefas where instancia_id = i.id and atlas_task_id is not null)));
  return jsonb_build_object('id', i.id, 'status', 'cancelado',
    'aviso', 'Tarefas já criadas no Atlas não são apagadas (a API do Atlas não exclui tarefas): conclua ou exclua lá, se for o caso.');
end $$;

-- ---------------------------------------------------------------- criação no Atlas (Edge Function)
create or replace function public.wf_para_criar(p_limite int default 20) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r jsonb := '[]'; t record; i wf_instancias; v_r record; v_desc text; v_pri text; v_raiz wf_instancias;
begin
  if not is_admin() then raise exception 'Somente a controladoria' using errcode = '42501'; end if;
  -- criação interrompida (função caiu no meio): pode ter criado no Atlas, então vai para conferência
  update wf_tarefas set status = 'verificar', ultimo_erro = 'Criação interrompida sem resposta do Atlas: confira se a tarefa existe lá antes de reenviar'
   where status = 'criando' and criando_em < now() - interval '15 minutes';
  if not coalesce((select (valor #>> '{}')::boolean from parametros where chave = 'wf_criar_no_atlas'), false) then
    return jsonb_build_object('ligado', false, 'tarefas', '[]'::jsonb);
  end if;
  for t in select wt.*, em.checklist, em.orientacao, em.exige_evidencia, em.leva_pf
             from wf_tarefas wt join wf_etapas_modelo em on em.id = wt.etapa_modelo_id
             join wf_instancias wi on wi.id = wt.instancia_id and wi.status = 'ativo'
            where wt.status = 'liberada' order by wt.prazo, wt.id limit greatest(least(coalesce(p_limite, 20), 50), 1)
            for update of wt skip locked loop
    select * into i from wf_instancias where id = t.instancia_id;
    select * into v_raiz from wf_instancias where id = _wf_raiz(i.id);
    select * into v_r from _wf_responsavel(i.id, t.papel);
    if v_r.problema is not null then
      update wf_tarefas set status = 'sem_responsavel', ultimo_erro = v_r.problema where id = t.id;
      continue;
    end if;
    v_pri := case when i.pf is not null and dias_uteis_entre(hoje_brasilia(), i.pf) <= 5 then 'urgent' else 'normal' end;
    v_desc := 'Workflow da controladoria — fluxo #' || v_raiz.id || coalesce(' / ' || (select nome from wf_modelos where id = i.modelo_id), '')
      || E'\nProcesso: ' || coalesce(i.cnj, '—') || ' | Cliente: ' || coalesce(i.cliente, '—')
      || E'\nProvidência: ' || coalesce(i.providencia, '—') || ' | Natureza: ' || coalesce(i.natureza, '—')
      || case when i.pf is not null then E'\nPF: ' || to_char(i.pf, 'DD/MM/YYYY') || ' | D-4: ' || to_char(calcular_d4(i.pf), 'DD/MM/YYYY') else E'\nSem prazo judicial' end
      || coalesce(E'\nIntimação: ' || i.link_intimacao, '')
      || coalesce(E'\nMotivo: ' || nullif(i.dados->>'motivo', ''), '') || coalesce(E'\nFinalidade: ' || nullif(i.dados->>'finalidade', ''), '')
      || case when cardinality(t.checklist) > 0 then E'\n\nChecklist:\n' || (select string_agg('[ ] ' || x, E'\n') from unnest(t.checklist) x) else '' end
      || coalesce(E'\n\nOrientação: ' || t.orientacao, '')
      || coalesce(E'\nEvidência obrigatória: ' || t.exige_evidencia, '')
      || E'\n\nPrazo desta etapa: ' || to_char(t.prazo, 'DD/MM/YYYY') || '. O PF continua valendo mesmo com pendência do cliente.';
    update wf_tarefas set status = 'criando', tentativas = tentativas + 1, criando_em = now() where id = t.id;
    r := r || jsonb_build_object('id', t.id, 'tentativa', t.tentativas + 1,
      'idempotencia', 'controladoria-wf-' || t.id || '-' || (t.tentativas + 1),
      'payload', jsonb_strip_nulls(jsonb_build_object(
        'title', left(t.titulo, 500), 'description', left(v_desc, 10000), 'priority', v_pri,
        'dueDate', t.prazo, 'fatalDate', case when t.leva_pf then i.pf end,
        'lawsuitId', i.atlas_lawsuit_id, 'clientId', i.atlas_client_id,
        'assigneeUserId', v_r.atlas_user, 'assigneeEmail', case when v_r.atlas_user is null then v_r.email end)));
  end loop;
  return jsonb_build_object('ligado', true, 'tarefas', r);
end $$;

create or replace function public.wf_confirmar_criacao(p_tarefa bigint, p_tentativa int, p_resposta jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_task uuid; t wf_tarefas;
begin
  if not is_admin() then raise exception 'Somente a controladoria' using errcode = '42501'; end if;
  begin v_task := (p_resposta->>'taskId')::uuid; exception when others then v_task := null; end;
  if v_task is null then raise exception 'Resposta do Atlas sem taskId'; end if;
  select * into t from wf_tarefas where id = p_tarefa for update;
  if t.status not in ('criando','verificar') then return jsonb_build_object('id', p_tarefa, 'status', t.status); end if;
  update wf_tarefas set status = 'criada', atlas_task_id = v_task, atlas_app_url = p_resposta->>'appUrl', ultimo_erro = null where id = t.id;
  perform _wf_evento(t.instancia_id, t.id, 'criada_no_atlas', jsonb_build_object('atlas_task_id', v_task, 'tentativa', p_tentativa,
    'avisos', p_resposta->'warnings'));
  return jsonb_build_object('id', t.id, 'status', 'criada', 'atlas_task_id', v_task);
end $$;

-- erro devolvido antes de gravar = certeza de que não criou: volta a "liberada". Falha de rede = "verificar" (pode ter criado).
create or replace function public.wf_falha_criacao(p_tarefa bigint, p_erro text, p_code text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare t wf_tarefas; v_certeza boolean := coalesce(p_code, '') in ('validation_error','permission_denied','not_found','read_only_key',
  'invalid_api_key','missing_api_key','api_not_in_plan','tenant_inactive','invalid_request','unknown_action','sem_chave',
  'no_active_admin','rate_limited','idempotency_conflict');
begin
  if not is_admin() then raise exception 'Somente a controladoria' using errcode = '42501'; end if;
  select * into t from wf_tarefas where id = p_tarefa for update;
  if t.status <> 'criando' then return jsonb_build_object('id', p_tarefa, 'status', t.status); end if;
  update wf_tarefas set status = case when v_certeza and t.tentativas < 5 then 'liberada' else 'verificar' end,
         ultimo_erro = 'Atlas: ' || coalesce(p_erro, '(sem mensagem)') where id = t.id;
  perform _wf_evento(t.instancia_id, t.id, 'falha_atlas', jsonb_build_object('erro', p_erro, 'code', p_code, 'certeza_nao_criou', v_certeza));
  return jsonb_build_object('id', t.id, 'status', (select status from wf_tarefas where id = t.id));
end $$;

-- tarefas que o ciclo precisa acompanhar no Atlas e desde quando ler
create or replace function public.wf_acompanhar() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Somente a controladoria' using errcode = '42501'; end if;
  return jsonb_build_object(
    -- 10 min de folga: relê o fim do ciclo anterior (conclusões gravadas durante a leitura)
    'desde', coalesce((select max(iniciado_em) - interval '10 minutes' from wf_ciclos where resultado ? 'leitura_ok'),
                      (select min(wi.criado_em) from wf_tarefas wt join wf_instancias wi on wi.id = wt.instancia_id where wt.status = 'criada')),
    'abertas', (select count(*) from wf_tarefas where status = 'criada'));
end $$;

-- conclusões lidas no Atlas (list_tasks): [{id, status, updated_at}]. Também serve para o "Sincronizar" completo.
create or replace function public.wf_registrar_atlas(p_itens jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare x jsonb; v_t wf_tarefas; n int := 0;
begin
  if not is_admin() then raise exception 'Somente a controladoria' using errcode = '42501'; end if;
  for x in select * from jsonb_array_elements(coalesce(p_itens, '[]')) loop
    if x->>'status' <> 'done' then continue; end if;
    select * into v_t from wf_tarefas where atlas_task_id::text = x->>'id' and status = 'criada';
    if v_t.id is null then continue; end if;
    if _wf_concluir_tarefa(v_t.id, 'atlas', null) then n := n + 1; end if;
  end loop;
  return jsonb_build_object('concluidas', n);
end $$;

-- registro do ciclo (Edge Function, no fim de cada ciclo)
create or replace function public.wf_registrar_ciclo(p_inicio timestamptz, p_origem text, p_resultado jsonb) returns bigint
language plpgsql security definer set search_path = public as $$
declare v bigint;
begin
  if not is_admin() then raise exception 'Somente a controladoria' using errcode = '42501'; end if;
  insert into wf_ciclos (iniciado_em, origem, resultado) values (p_inicio, case when _eh_servico() then 'agendamento' else coalesce(p_origem, 'painel') end,
    coalesce(p_resultado, '{}')) returning id into v;
  return v;
end $$;

-- ---------------------------------------------------------------- leitura (painel)
create or replace function public.wf_detalhe(p_id bigint) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare i wf_instancias;
begin
  -- permissão antes da existência: quem não participa não descobre quais fluxos existem
  if not _wf_pode_ver(p_id) then
    raise exception 'Somente quem participa do fluxo, o líder da equipe, a controladoria e a diretoria veem este fluxo' using errcode = '42501';
  end if;
  select * into i from wf_instancias where id = p_id;
  if i.id is null then raise exception 'Fluxo % inexistente', p_id; end if;
  return to_jsonb(i) || jsonb_build_object(
    'modelo', (select codigo from wf_modelos where id = i.modelo_id),
    'modelo_nome', (select nome from wf_modelos where id = i.modelo_id),
    'advogado', (select nome_advbox from colaboradores where id = i.advogado_colaborador_id),
    'equipe', (select nome from equipes where id = i.equipe_id),
    'd4', case when i.pf is not null then calcular_d4(i.pf) end,
    'pode_decidir', _wf_pode_decidir(i.id), 'admin', is_admin(),
    'perguntas', coalesce((select jsonb_agg(jsonb_build_object('chave', d.chave, 'pergunta', d.pergunta, 'quem', d.quem, 'apos', d.apos,
        'resposta', i.decisoes -> d.chave,
        'pendente', (i.decisoes -> d.chave) is null and exists (select 1 from wf_tarefas wt join wf_etapas_modelo em on em.id = wt.etapa_modelo_id
                     where wt.instancia_id = i.id and ltrim(em.condicao, '!') = d.chave and wt.status = 'aguardando_decisao'))
        order by d.chave) from wf_decisoes_modelo d where d.modelo_id = i.modelo_id), '[]'),
    'etapas', coalesce((select jsonb_agg(jsonb_build_object('id', wt.id, 'codigo', em.codigo, 'ordem', em.ordem, 'titulo', wt.titulo,
        'papel', wt.papel, 'status', wt.status, 'responsavel', c.nome_advbox, 'prazo', wt.prazo, 'liberada_em', wt.liberada_em,
        'concluida_em', wt.concluida_em, 'concluida_por', wt.concluida_por, 'atlas_task_id', wt.atlas_task_id, 'atlas_app_url', wt.atlas_app_url,
        'erro', wt.ultimo_erro, 'nota', wt.nota, 'condicao', em.condicao, 'depende_de', em.depende_de, 'sub_fluxo', em.sub_fluxo,
        'exige_evidencia', em.exige_evidencia,
        'filho', case when wt.filho_instancia_id is not null then wf_detalhe(wt.filho_instancia_id) end)
        order by em.ordem) from wf_tarefas wt join wf_etapas_modelo em on em.id = wt.etapa_modelo_id
        left join colaboradores c on c.id = wt.colaborador_id where wt.instancia_id = i.id), '[]'),
    'eventos', case when i.pai_instancia_id is null then coalesce((select jsonb_agg(jsonb_build_object('tipo', e.tipo, 'em', e.ocorrido_em,
        'detalhe', e.detalhe, 'fluxo', e.instancia_id, 'usuario', u.email) order by e.ocorrido_em desc)
        from wf_eventos e left join auth.users u on u.id = e.usuario
        where e.instancia_id = i.id or e.instancia_id in (select id from wf_instancias where pai_instancia_id = i.id)), '[]') end);
end $$;

-- lista dos fluxos-mestre visíveis para quem está logado
create or replace function public.wf_listar(p_status text default 'ativo', p_busca text default null, p_limite int default 200) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_meus bigint[] := public.meus_colaboradores(); v_tudo boolean := public.pode_ler_tudo();
begin
  if public.meu_papel() is null then raise exception 'Usuário sem perfil na controladoria' using errcode = '42501'; end if;
  return jsonb_build_object(
    'ligado', coalesce((select (valor #>> '{}')::boolean from parametros where chave = 'wf_criar_no_atlas'), false),
    'ultimo_ciclo', (select jsonb_build_object('em', terminado_em, 'origem', origem, 'resultado', resultado) from wf_ciclos order by id desc limit 1),
    'contagem', (select jsonb_build_object(
        'ativos', count(*) filter (where i.status = 'ativo'),
        'aguardando_decisao', count(*) filter (where i.status = 'ativo' and exists (select 1 from wf_tarefas x join wf_instancias xi on xi.id = x.instancia_id
            where (xi.id = i.id or xi.pai_instancia_id = i.id) and x.status = 'aguardando_decisao')),
        'com_problema', count(*) filter (where i.status = 'ativo' and exists (select 1 from wf_tarefas x join wf_instancias xi on xi.id = x.instancia_id
            where (xi.id = i.id or xi.pai_instancia_id = i.id) and x.status in ('sem_responsavel','verificar'))),
        'para_criar', (select count(*) from wf_tarefas x join wf_instancias xi on xi.id = x.instancia_id and xi.status = 'ativo' where x.status = 'liberada'))
      from wf_instancias i where i.pai_instancia_id is null
       and (v_tudo or i.advogado_colaborador_id = any(v_meus) or (select colaborador_id from equipes_assistentes where equipe_id = i.equipe_id) = any(v_meus)
            or exists (select 1 from lideres_equipes le where le.user_id = auth.uid() and le.equipe_id = i.equipe_id))),
    'itens', coalesce((select jsonb_agg(x order by x->>'criado_em' desc) from (
      select jsonb_build_object('id', i.id, 'status', i.status, 'cnj', i.cnj, 'cliente', i.cliente, 'providencia', i.providencia,
               'natureza', i.natureza, 'pf', i.pf, 'equipe', e.nome, 'advogado', c.nome_advbox, 'criado_em', i.criado_em,
               'concluido_em', i.concluido_em,
               'etapas', (select jsonb_agg(jsonb_build_object('titulo', x.titulo, 'status', x.status, 'prazo', x.prazo,
                              'responsavel', cc.nome_advbox, 'fluxo', xi.id) order by xi.id, em.ordem)
                            from wf_tarefas x join wf_instancias xi on xi.id = x.instancia_id join wf_etapas_modelo em on em.id = x.etapa_modelo_id
                            left join colaboradores cc on cc.id = x.colaborador_id
                           where (xi.id = i.id or xi.pai_instancia_id = i.id) and x.status not in ('concluida','dispensada','cancelada','em_subfluxo'))) x
        from wf_instancias i left join equipes e on e.id = i.equipe_id left join colaboradores c on c.id = i.advogado_colaborador_id
       where i.pai_instancia_id is null
         and (p_status is null or p_status = '' or i.status = p_status)
         and (v_tudo or i.advogado_colaborador_id = any(v_meus) or (select colaborador_id from equipes_assistentes where equipe_id = i.equipe_id) = any(v_meus)
              or exists (select 1 from lideres_equipes le where le.user_id = auth.uid() and le.equipe_id = i.equipe_id))
         and (p_busca is null or p_busca = '' or i.cnj ilike '%' || p_busca || '%' or i.cliente ilike '%' || p_busca || '%'
              or i.providencia ilike '%' || p_busca || '%')
       order by i.criado_em desc limit greatest(least(coalesce(p_limite, 200), 500), 1)) s), '[]'));
end $$;

-- ---------------------------------------------------------------- configuração (controladoria)
create or replace function public.wf_configuracao() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not pode_ler_tudo() then raise exception 'Somente a controladoria e a diretoria' using errcode = '42501'; end if;
  return jsonb_build_object(
    'equipes', coalesce((select jsonb_agg(jsonb_build_object('equipe_id', e.id, 'equipe', e.nome, 'colaborador_id', ea.colaborador_id,
        'assistente', c.nome_advbox, 'atlas_user_id', c.atlas_user_id,
        'atlas_nome', (select p.nome from atlas_produtividade p where p.user_id = c.atlas_user_id order by p.coleta desc limit 1)) order by e.nome)
        from equipes e left join equipes_assistentes ea on ea.equipe_id = e.id left join colaboradores c on c.id = ea.colaborador_id), '[]'),
    -- usuários do Atlas conhecidos pela API (produtividade e responsáveis das tarefas sincronizadas)
    'usuarios_atlas', coalesce((select jsonb_agg(jsonb_build_object('atlas_user_id', u.uid, 'nome', u.nome,
        'colaborador', (select nome_advbox from colaboradores where atlas_user_id = u.uid)) order by u.nome, u.uid) from (
          select distinct on (user_id) user_id uid, nome from atlas_produtividade where user_id is not null order by user_id, coleta desc) u), '[]'),
    'colaboradores', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'nome', nome_advbox, 'atlas_user_id', atlas_user_id) order by nome_advbox)
        from colaboradores), '[]'),
    'advogados', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'nome', nome_advbox) order by nome_advbox)
        from colaboradores where atlas_user_id is not null), '[]'),
    'equipes_lista', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'nome', nome) order by nome) from equipes), '[]'),
    'controladoria_email', (select valor #>> '{}' from parametros where chave = 'wf_controladoria_email'),
    'ligado', coalesce((select (valor #>> '{}')::boolean from parametros where chave = 'wf_criar_no_atlas'), false),
    'perguntas_mestre', coalesce((select jsonb_agg(jsonb_build_object('chave', chave, 'pergunta', pergunta) order by chave)
        from wf_decisoes_modelo d join wf_modelos m on m.id = d.modelo_id where m.codigo = 'MESTRE'), '[]'));
end $$;

-- assistente da equipe e, se preciso, o usuário do Atlas dela (casamento manual, com motivo)
create or replace function public.admin_definir_assistente(p_equipe bigint, p_colaborador bigint, p_atlas_user uuid, p_motivo text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_outro text;
begin
  if not is_admin() then raise exception 'Somente a controladoria' using errcode = '42501'; end if;
  perform _exigir_motivo(p_motivo);
  if not exists (select 1 from equipes where id = p_equipe) then raise exception 'Equipe inexistente'; end if;
  if p_colaborador is null then
    delete from equipes_assistentes where equipe_id = p_equipe;
  else
    if not exists (select 1 from colaboradores where id = p_colaborador) then raise exception 'Colaborador inexistente'; end if;
    if p_atlas_user is not null then
      select nome_advbox into v_outro from colaboradores where atlas_user_id = p_atlas_user and id <> p_colaborador;
      if v_outro is not null then raise exception 'Este usuário do Atlas já está ligado a %', v_outro; end if;
      update colaboradores set atlas_user_id = p_atlas_user where id = p_colaborador and atlas_user_id is distinct from p_atlas_user;
    end if;
    insert into equipes_assistentes (equipe_id, colaborador_id) values (p_equipe, p_colaborador)
    on conflict (equipe_id) do update set colaborador_id = excluded.colaborador_id, atualizado_em = now();
  end if;
  -- etapas paradas por falta de assistente voltam a tentar
  perform _wf_avancar(wi.id) from wf_instancias wi where wi.status = 'ativo'
     and exists (select 1 from wf_tarefas wt where wt.instancia_id = wi.id and wt.status = 'sem_responsavel');
  return wf_configuracao();
end $$;

-- ---------------------------------------------------------------- integração: ação nova na Edge Function
create or replace function public.atlas_conferir_acesso(p_acao text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if p_acao = 'executar_solicitacao' then
    if not (is_admin() or coalesce(public.meu_papel() = 'lider', false)) then raise exception 'Somente líderes e a controladoria' using errcode = '42501'; end if;
  elsif not is_admin() then raise exception 'Somente a controladoria usa a integração com o Atlas' using errcode = '42501';
  end if;
  if p_acao not in ('testar','sincronizar','criar_tarefa','executar_solicitacao','padronizar_descricoes','sincronizar_intimacoes',
                    'fim_expediente','workflows' /* 0061 */) then
    raise exception 'Ação desconhecida: %', p_acao;
  end if;
  return jsonb_build_object('ok', true, 'usuario', auth.uid());
end $$;

-- ---------------------------------------------------------------- permissões
revoke execute on function public._wf_evento(bigint, bigint, text, jsonb), public._wf_pode_ver(bigint), public._wf_pode_decidir(bigint),
  public._wf_raiz(bigint), public._wf_prazo(int, int, date), public._wf_texto(text, public.wf_instancias),
  public._wf_responsavel(bigint, text), public._wf_criar_instancia(text, bigint, bigint, jsonb), public._wf_avancar(bigint),
  public._wf_concluir_tarefa(bigint, text, text)
  from public, anon, authenticated;
revoke execute on function public.wf_triagem_dados(text, text), public.wf_iniciar(jsonb), public.wf_decidir(bigint, jsonb, text),
  public.wf_etapa_manual(bigint, text, text), public.wf_cancelar(bigint, text), public.wf_para_criar(int),
  public.wf_confirmar_criacao(bigint, int, jsonb), public.wf_falha_criacao(bigint, text, text), public.wf_acompanhar(),
  public.wf_registrar_atlas(jsonb), public.wf_registrar_ciclo(timestamptz, text, jsonb), public.wf_detalhe(bigint), public.wf_listar(text, text, int), public.wf_configuracao(),
  public.admin_definir_assistente(bigint, bigint, uuid, text), public.atlas_conferir_acesso(text)
  from public, anon;
grant execute on function public.wf_triagem_dados(text, text), public.wf_iniciar(jsonb), public.wf_decidir(bigint, jsonb, text),
  public.wf_etapa_manual(bigint, text, text), public.wf_cancelar(bigint, text), public.wf_para_criar(int),
  public.wf_confirmar_criacao(bigint, int, jsonb), public.wf_falha_criacao(bigint, text, text), public.wf_acompanhar(),
  public.wf_registrar_atlas(jsonb), public.wf_registrar_ciclo(timestamptz, text, jsonb), public.wf_detalhe(bigint), public.wf_listar(text, text, int), public.wf_configuracao(),
  public.admin_definir_assistente(bigint, bigint, uuid, text), public.atlas_conferir_acesso(text)
  to authenticated;

-- ---------------------------------------------------------------- agendamento: ciclo a cada 10 minutos (8h às 20h, dias úteis)
-- Nasce DESATIVADO, como o das 18:30 (0042): a controladoria liga depois do primeiro fluxo de teste.
do $$
declare v_url text; v_anon text; v_job bigint;
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') or not exists (select 1 from pg_extension where extname = 'pg_net') then
    raise notice '0061: pg_cron/pg_net indisponíveis neste banco; agendamento não criado.';
    return;
  end if;
  v_url := (select valor #>> '{}' from public.parametros where chave = 'fim_expediente_url');
  v_anon := (select valor #>> '{}' from public.parametros where chave = 'fim_expediente_chave_publica');
  if v_url is null or v_anon is null then raise notice '0061: endereço da função ausente; agendamento não criado.'; return; end if;
  perform cron.unschedule(jobid) from cron.job where jobname = 'controladoria_workflows';
  select cron.schedule('controladoria_workflows', '*/10 11-23 * * 1-5', format($c$
    select net.http_post(url := %L,
      headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || %L,
                                    'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'atlas_cron_secret')),
      body := '{"acao":"workflows"}'::jsonb, timeout_milliseconds := 120000)
  $c$, v_url, v_anon)) into v_job;
  perform cron.alter_job(v_job, active := false);
end $$;
