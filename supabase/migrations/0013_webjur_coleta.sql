-- =====================================================================
-- 0013 — Etapa 6: coleta das publicações Webjur
--
-- Base: inspeção de 06/11/2026 (somente leitura) do e-mail diário da Webjur
-- (4 e-mails reais, set/2026) e da página de acesso do portal
-- (historico.webjur.com.br, que exige OAB + senha e NÃO foi acessado por dentro).
--
-- O que muda (nada é apagado; 0008 continua valendo):
--   1. publicacoes.id_documento: o "Identificador do documento" que a Webjur traz
--      em cada publicação. Quando existe, é a identificação mais forte: a mesma
--      publicação vista em duas fontes é reconhecida por ele, e duas publicações
--      com o mesmo CNJ, a mesma data e o mesmo teor NÃO se fundem se os
--      identificadores forem diferentes.
--   2. Nova origem 'webjur_email' (e-mail salvo e importado no painel). A origem
--      'webjur_gmail' fica reservada para uma leitura automática da caixa, que hoje
--      não existe: os e-mails da Webjur não chegam à caixa da controladoria.
--   3. webjur_remessas: cada e-mail importado, com o hash do arquivo (o mesmo
--      arquivo nunca entra duas vezes) e a conferência de completude contra os
--      totais que a própria Webjur declara.
--   4. Cada coleta guarda o registro bruto recebido daquela fonte (auditoria).
--   5. pub_registrar_remessa, pub_listar, pub_detalhe e a visão v_webjur_remessas.
-- =====================================================================

-- ---------------------------------------------------------------- 1. identificador do documento
alter table public.publicacoes add column if not exists id_documento text;
create unique index if not exists publicacoes_id_documento_uq on public.publicacoes (id_documento) where id_documento is not null;
comment on column public.publicacoes.id_documento is
  'Identificador do documento informado pela Webjur na publicação (e-mail: "Identificador do documento: N").';

-- ---------------------------------------------------------------- 2. origens
alter table public.publicacoes_coletas drop constraint if exists publicacoes_coletas_origem_check;
alter table public.publicacoes_coletas add constraint publicacoes_coletas_origem_check
  check (origem in ('webjur_portal','webjur_gmail','webjur_email','manual'));
alter table public.eventos drop constraint if exists eventos_origem_check;
alter table public.eventos add constraint eventos_origem_check check (origem in (
  'excel_campo','excel_observacoes','comparacao_importacoes','extensao','sistema','administrativo',
  'webjur_portal','webjur_gmail','webjur_email','manual'));
alter table public.log_integracao drop constraint if exists log_integracao_origem_check;
alter table public.log_integracao add constraint log_integracao_origem_check
  check (origem in ('advbox_extensao','webjur_portal','webjur_gmail','webjur_email','importacao_excel','sistema'));

-- ---------------------------------------------------------------- 3. remessas
create table public.webjur_remessas (
  id               bigint generated always as identity primary key,
  origem           text not null check (origem in ('webjur_email','webjur_gmail','webjur_portal')),
  formato          text not null,                      -- versão do leitor (ex.: webjur_email_v1)
  arquivo_nome     text,
  arquivo_sha256   text not null unique check (arquivo_sha256 ~ '^[0-9a-f]{64}$'),
  recebido_em      timestamptz,                         -- envio pela Webjur, quando o arquivo informa
  chave_cliente    text,                                -- "Public 8. UFs 28. (...)"
  cliente          text,
  secoes           jsonb not null,                      -- [{caderno, data, declarado, lidas_servidor}]
  total_declarado  int not null,
  total_enviado    int not null,
  situacao         text not null check (situacao in ('completa','divergente')),
  divergencias     jsonb not null default '[]',
  avisos_leitor    jsonb not null default '[]',
  importada_em     timestamptz not null default now(),
  importada_por    uuid
);
create trigger webjur_remessas_imutavel before update or delete on public.webjur_remessas
  for each row execute function public.tg_bloqueia_alteracao();

-- ---------------------------------------------------------------- 4. coleta com o registro bruto
alter table public.publicacoes_coletas add column if not exists conteudo_original jsonb;
alter table public.publicacoes_coletas add column if not exists remessa_id bigint references public.webjur_remessas(id);
create index if not exists publicacoes_coletas_remessa on public.publicacoes_coletas (remessa_id);
create index if not exists publicacoes_coletas_pub on public.publicacoes_coletas (publicacao_id);

-- ---------------------------------------------------------------- 5. registro de uma publicação
-- Ordem de identificação:
--   a) id_documento igual            -> mesma publicação (mesmo se o teor veio diferente: marcado);
--   b) CNJ + data + teor iguais      -> mesma publicação, salvo se as duas tiverem
--                                       id_documento e eles forem diferentes;
--   c) nenhum dos dois               -> publicação nova.
create or replace function public._pub_registrar(p_pub jsonb, p_origem text, p_id_origem text, p_remessa bigint)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_cnj text; v_teor text; v_dpub date; v_ddisp date; v_chave text; v_id bigint; v_proc bigint;
        v_doc text; v_doc_exist text; v_hash_exist text; v_por text := 'nova';
        v_nova boolean := false; v_coleta boolean; v_teor_div boolean := false;
begin
  if p_origem not in ('webjur_portal','webjur_gmail','webjur_email','manual') then raise exception 'Origem inválida: %', p_origem; end if;
  v_teor := p_pub->>'teor';
  if nullif(btrim(coalesce(v_teor,'')),'') is null then
    perform registrar_log_integracao(case when p_origem = 'manual' then 'sistema' else p_origem end, 'erro', 'pub_registrar',
      'Publicação sem teor; não registrada.', jsonb_build_object('id_origem', p_id_origem, 'remessa_id', p_remessa, 'recebido', p_pub));
    return jsonb_build_object('status','rejeitada','motivo','teor_ausente');
  end if;
  begin
    v_dpub  := coalesce(_dt_tela(p_pub->>'data_publicacao'), (nullif(p_pub->>'data_publicacao',''))::date);
    v_ddisp := coalesce(_dt_tela(p_pub->>'data_disponibilizacao'), (nullif(p_pub->>'data_disponibilizacao',''))::date);
  exception when others then
    perform registrar_log_integracao(case when p_origem = 'manual' then 'sistema' else p_origem end, 'erro', 'pub_registrar',
      'Data inválida na publicação.', jsonb_build_object('id_origem', p_id_origem, 'remessa_id', p_remessa, 'recebido', p_pub));
    return jsonb_build_object('status','rejeitada','motivo','data_invalida');
  end;
  v_cnj := normalizar_cnj(p_pub->>'cnj');
  v_doc := nullif(btrim(coalesce(p_pub->>'id_documento','')),'');
  v_chave := md5(coalesce(v_cnj, 'sem_cnj:' || coalesce(p_pub->>'cnj','')) || '|' ||
                 coalesce(v_dpub::text, v_ddisp::text, '') || '|' || md5(normalizar_teor(v_teor)));

  if v_doc is not null then
    select id, teor_hash into v_id, v_hash_exist from publicacoes where id_documento = v_doc;
    if v_id is not null then
      v_por := 'id_documento';
      v_teor_div := v_hash_exist <> md5(normalizar_teor(v_teor));
    end if;
  end if;
  if v_id is null then
    select id, id_documento into v_id, v_doc_exist from publicacoes where chave_dedupe = v_chave;
    if v_id is not null and v_doc is not null and v_doc_exist is not null and v_doc_exist <> v_doc then
      v_id := null;                                   -- documentos diferentes na fonte: publicações distintas
      v_chave := md5(v_chave || '|doc:' || v_doc);
    elsif v_id is not null then
      v_por := 'conteudo';
    end if;
  end if;

  if v_id is null then
    if v_cnj is not null then
      insert into processos (cnj, cnj_digito_valido, origem) values (v_cnj, cnj_digito_valido(v_cnj), 'webjur')
      on conflict (cnj) do nothing;
      select id into v_proc from processos where cnj = v_cnj;
    end if;
    insert into publicacoes (fornecedor, cnj_original, cnj, cnj_digito_valido, processo_id, data_disponibilizacao,
                             data_publicacao, tribunal, orgao_julgador, teor, teor_hash, resumo, url_origem,
                             conteudo_original, chave_dedupe, registrada_por, id_documento)
    values ('webjur', p_pub->>'cnj', v_cnj, cnj_digito_valido(v_cnj), v_proc, v_ddisp, v_dpub,
            nullif(btrim(p_pub->>'tribunal'),''), nullif(btrim(p_pub->>'orgao_julgador'),''), v_teor,
            md5(normalizar_teor(v_teor)), nullif(btrim(p_pub->>'resumo'),''), nullif(btrim(p_pub->>'url_origem'),''),
            p_pub, v_chave, auth.uid(), v_doc)
    returning id into v_id;
    v_nova := true;
    insert into eventos (chave_dedupe, tipo, ocorrido_em, precisao_ocorrido, origem, historico_recuperado, classificacao, evidencia)
    values ('pub:'||v_id, 'publicacao_recebida', now(), 'segundo', p_origem, false, 'confirmado',
            jsonb_build_object('publicacao_id',v_id,'cnj',v_cnj,'data_publicacao',v_dpub,'usuario',auth.uid()));
  end if;

  if v_teor_div then
    perform registrar_log_integracao(case when p_origem = 'manual' then 'sistema' else p_origem end, 'aviso', 'pub_registrar',
      'Mesmo identificador de documento com teor diferente do já registrado; o original foi mantido e a nova versão está na coleta.',
      jsonb_build_object('publicacao_id', v_id, 'id_documento', v_doc, 'id_origem', p_id_origem, 'remessa_id', p_remessa));
  end if;

  insert into publicacoes_coletas (publicacao_id, origem, id_origem, recebido_em, coletado_por, conteudo_original, remessa_id)
  values (v_id, p_origem, p_id_origem, (nullif(p_pub->>'recebido_em',''))::timestamptz, auth.uid(), p_pub, p_remessa)
  on conflict (origem, id_origem) do nothing;
  v_coleta := found;

  return jsonb_build_object('status', case when v_nova then 'nova' else 'ja_registrada' end,
                            'identificada_por', v_por, 'teor_divergente', v_teor_div,
                            'publicacao_id', v_id, 'cnj', v_cnj, 'cnj_digito_valido', cnj_digito_valido(v_cnj),
                            'coleta_nova', v_coleta);
end $$;

-- Mesma assinatura da 0008: quem já chamava continua funcionando.
create or replace function public.pub_registrar(p_pub jsonb, p_origem text, p_id_origem text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Somente a controladoria registra publicações' using errcode = '42501'; end if;
  return _pub_registrar(p_pub, p_origem, p_id_origem, null);
end $$;

-- ---------------------------------------------------------------- 6. registro de uma remessa (um e-mail)
-- p_remessa: {formato, recebido_em, chave_cliente, cliente, secoes:[{caderno,data,declarado}], avisos:[...]}
-- p_publicacoes: [{... campos de pub_registrar ..., secao, secao_data, seq}]
-- O servidor reconta as publicações por seção e compara com o total que a Webjur declara.
create or replace function public.pub_registrar_remessa(p_arquivo_nome text, p_arquivo_sha256 text, p_remessa jsonb,
                                                        p_publicacoes jsonb, p_origem text default 'webjur_email')
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_rem bigint; v_secoes jsonb; v_decl int; v_env int; v_div jsonb := '[]'; v_sit text;
        v_res jsonb := '[]'; r jsonb; p jsonb; v_i int := 0;
begin
  if not is_admin() then raise exception 'Somente a controladoria registra publicações' using errcode = '42501'; end if;
  if p_origem not in ('webjur_email','webjur_gmail','webjur_portal') then raise exception 'Origem inválida: %', p_origem; end if;
  if p_arquivo_sha256 is null or p_arquivo_sha256 !~ '^[0-9a-f]{64}$' then raise exception 'Hash do arquivo inválido'; end if;
  if jsonb_typeof(p_publicacoes) <> 'array' then raise exception 'p_publicacoes deve ser uma lista'; end if;
  if jsonb_array_length(p_publicacoes) > 500 then raise exception 'Mais de 500 publicações em uma remessa: divida o arquivo'; end if;
  if jsonb_typeof(p_remessa->'secoes') is distinct from 'array' or jsonb_array_length(p_remessa->'secoes') = 0 then
    raise exception 'Remessa sem as seções "Leitura DJ": o arquivo não foi reconhecido como e-mail da Webjur';
  end if;

  select id into v_rem from webjur_remessas where arquivo_sha256 = p_arquivo_sha256;
  if v_rem is not null then
    return jsonb_build_object('status','ja_importada','remessa_id', v_rem);
  end if;

  -- recontagem no servidor
  select jsonb_agg(jsonb_build_object('caderno', s->>'caderno', 'data', s->>'data', 'declarado', (s->>'declarado')::int,
           'lidas_servidor', (select count(*) from jsonb_array_elements(p_publicacoes) x
                               where x->>'secao' = s->>'caderno' and x->>'secao_data' = s->>'data'))),
         sum((s->>'declarado')::int)
    into v_secoes, v_decl
    from jsonb_array_elements(p_remessa->'secoes') s;
  v_env := jsonb_array_length(p_publicacoes);
  select coalesce(jsonb_agg(jsonb_build_object('caderno', x->>'caderno', 'data', x->>'data',
                                               'declarado', (x->>'declarado')::int, 'recebidas', (x->>'lidas_servidor')::int)), '[]')
    into v_div from jsonb_array_elements(v_secoes) x where (x->>'declarado')::int <> (x->>'lidas_servidor')::int;
  if v_env <> v_decl then
    v_div := v_div || jsonb_build_array(jsonb_build_object('total_declarado', v_decl, 'total_recebido', v_env));
  end if;
  v_sit := case when jsonb_array_length(v_div) = 0 then 'completa' else 'divergente' end;

  insert into webjur_remessas (origem, formato, arquivo_nome, arquivo_sha256, recebido_em, chave_cliente, cliente,
                               secoes, total_declarado, total_enviado, situacao, divergencias, avisos_leitor, importada_por)
  values (p_origem, coalesce(p_remessa->>'formato','desconhecido'), p_arquivo_nome, p_arquivo_sha256,
          (nullif(p_remessa->>'recebido_em',''))::timestamptz, p_remessa->>'chave_cliente', p_remessa->>'cliente',
          v_secoes, v_decl, v_env, v_sit, v_div, coalesce(p_remessa->'avisos','[]'), auth.uid())
  returning id into v_rem;

  for p in select * from jsonb_array_elements(p_publicacoes) loop
    v_i := v_i + 1;
    r := _pub_registrar(p, p_origem, p_arquivo_sha256 || '#' || coalesce(p->>'secao','') || '#' ||
                                     coalesce(p->>'secao_data','') || '#' || coalesce(p->>'seq', v_i::text), v_rem);
    v_res := v_res || jsonb_build_array(r || jsonb_build_object('seq', p->'seq', 'secao', p->'secao'));
  end loop;

  if v_sit = 'divergente' then
    perform registrar_log_integracao(p_origem, 'aviso', 'pub_registrar_remessa',
      'Remessa com número de publicações diferente do declarado pela Webjur: conferir no portal.',
      jsonb_build_object('remessa_id', v_rem, 'arquivo', p_arquivo_nome, 'divergencias', v_div));
  end if;

  return jsonb_build_object('status','importada', 'remessa_id', v_rem, 'situacao', v_sit, 'divergencias', v_div,
    'total_declarado', v_decl, 'total_recebido', v_env,
    'novas',          (select count(*) from jsonb_array_elements(v_res) x where x->>'status' = 'nova'),
    'ja_registradas', (select count(*) from jsonb_array_elements(v_res) x where x->>'status' = 'ja_registrada'),
    'rejeitadas',     (select count(*) from jsonb_array_elements(v_res) x where x->>'status' = 'rejeitada'),
    'resultados', v_res);
end $$;

-- ---------------------------------------------------------------- 7. visões
create or replace view public.v_publicacoes with (security_invoker = true) as
select p.id, p.cnj, p.cnj_original, p.cnj_digito_valido, p.processo_id, p.data_disponibilizacao, p.data_publicacao,
       p.tribunal, p.orgao_julgador, p.teor, p.resumo, p.url_origem, p.registrada_em,
       (p.registrada_em at time zone 'America/Sao_Paulo')::date as dia_coleta,
       (select string_agg(distinct k.origem, ',') from public.publicacoes_coletas k where k.publicacao_id = p.id) as origens,
       c.situacao as situacao_conferencia, c.area_conferida, c.realizada_em as conferida_em, c.evidencia as evidencia_conferencia,
       (select count(*) from public.conferencias_publicacao x where x.publicacao_id = p.id) as n_conferencias,
       t.id as tarefa_analise_id, t.status as tarefa_analise_status, t.requer_cadastro, t.advbox_tarefa_id,
       -- 0013 (colunas novas sempre no fim)
       p.id_documento,
       p.conteudo_original->>'jornal' as jornal,
       coalesce(p.conteudo_original->'alertas', '[]'::jsonb) as alertas_leitura,
       (select count(*) from public.publicacoes_coletas k where k.publicacao_id = p.id) as n_coletas
  from public.publicacoes p
  left join lateral (select * from public.conferencias_publicacao x where x.publicacao_id = p.id
                      order by x.realizada_em desc, x.id desc limit 1) c on true
  left join public.tarefas_analise t on t.publicacao_id = p.id;

create or replace view public.v_webjur_remessas with (security_invoker = true) as
select r.id, r.origem, r.formato, r.arquivo_nome, r.recebido_em, r.chave_cliente, r.cliente, r.total_declarado,
       r.total_enviado, r.situacao, r.divergencias, r.avisos_leitor, r.importada_em, r.importada_por, r.secoes,
       (select count(*) from public.publicacoes_coletas k where k.remessa_id = r.id) as coletas,
       (select count(*) from public.publicacoes_coletas k where k.remessa_id = r.id
          and not exists (select 1 from public.publicacoes_coletas e where e.publicacao_id = k.publicacao_id and e.id < k.id)) as novas,
       r.total_enviado - (select count(*) from public.publicacoes_coletas k where k.remessa_id = r.id) as rejeitadas
  from public.webjur_remessas r;

-- ---------------------------------------------------------------- 8. consultas do painel
-- Data de referência: disponibilização (se ausente, publicação; se ausente, dia da coleta).
create or replace function public.pub_listar(p_inicio date, p_fim date, p_busca text default null,
                                             p_situacao text default null, p_origem text default null, p_limite int default 500)
returns jsonb language sql stable security invoker set search_path = public as $$
  with base as (
    select v.*, coalesce(v.data_disponibilizacao, v.data_publicacao, v.dia_coleta) as data_ref
      from v_publicacoes v
     where coalesce(v.data_disponibilizacao, v.data_publicacao, v.dia_coleta) between p_inicio and p_fim
       and (p_busca is null or btrim(p_busca) = ''
            or (length(regexp_replace(p_busca, '\D', '', 'g')) >= 7
                and regexp_replace(coalesce(v.cnj, v.cnj_original, ''), '\D', '', 'g') like '%' || regexp_replace(p_busca, '\D', '', 'g') || '%')
            or v.tribunal ilike '%' || btrim(p_busca) || '%' or v.orgao_julgador ilike '%' || btrim(p_busca) || '%'
            or v.id_documento = btrim(p_busca))
       and (p_situacao is null or p_situacao = ''
            or (p_situacao = 'sem_conferencia' and v.situacao_conferencia is null)
            or (p_situacao = 'com_alerta' and jsonb_array_length(v.alertas_leitura) > 0)
            or v.situacao_conferencia = p_situacao)
       and (p_origem is null or p_origem = '' or v.origens like '%' || p_origem || '%')
  )
  select jsonb_build_object(
    'total', (select count(*) from base),
    'por_situacao', (select coalesce(jsonb_object_agg(s, n), '{}') from
                      (select coalesce(situacao_conferencia, 'sem_conferencia') s, count(*) n from base group by 1) x),
    'linhas', coalesce((select jsonb_agg(to_jsonb(l) order by l.data_ref desc, l.id desc) from
      (select id, cnj, cnj_original, cnj_digito_valido, data_disponibilizacao, data_publicacao, tribunal, orgao_julgador,
              left(teor, 280) as teor_inicio, url_origem, id_documento, jornal, origens, n_coletas, dia_coleta, data_ref,
              situacao_conferencia, tarefa_analise_status, alertas_leitura, processo_id, registrada_em
         from base order by data_ref desc, id desc limit least(greatest(coalesce(p_limite, 500), 1), 500)) l), '[]'));
$$;

create or replace function public.pub_detalhe(p_id bigint)
returns jsonb language sql stable security invoker set search_path = public as $$
  select jsonb_build_object(
    'publicacao', (select to_jsonb(v) from v_publicacoes v where v.id = p_id),
    'conteudo_original', (select p.conteudo_original from publicacoes p where p.id = p_id),
    'coletas', coalesce((select jsonb_agg(jsonb_build_object('id', k.id, 'origem', k.origem, 'id_origem', k.id_origem,
                 'recebido_em', k.recebido_em, 'coletado_em', k.coletado_em, 'remessa_id', k.remessa_id,
                 'arquivo', r.arquivo_nome, 'situacao_remessa', r.situacao,
                 'teor_igual', md5(normalizar_teor(k.conteudo_original->>'teor')) = (select teor_hash from publicacoes where id = p_id))
                 order by k.id)
               from publicacoes_coletas k left join webjur_remessas r on r.id = k.remessa_id where k.publicacao_id = p_id), '[]'),
    'conferencias', coalesce((select jsonb_agg(to_jsonb(c) order by c.realizada_em, c.id)
               from conferencias_publicacao c where c.publicacao_id = p_id), '[]'));
$$;

-- ---------------------------------------------------------------- 9. segurança
alter table public.webjur_remessas enable row level security;
revoke all on public.webjur_remessas from anon, authenticated;
grant select on public.webjur_remessas to authenticated;
create policy remessas_admin on public.webjur_remessas for select to authenticated using (public.is_admin());

grant select on public.v_publicacoes, public.v_webjur_remessas to authenticated;
revoke all on public.v_publicacoes, public.v_webjur_remessas from anon;

revoke execute on function public._pub_registrar(jsonb, text, text, bigint) from public, anon, authenticated;
revoke execute on function public.pub_registrar_remessa(text, text, jsonb, jsonb, text) from public, anon;
revoke execute on function public.pub_listar(date, date, text, text, text, int) from public, anon;
revoke execute on function public.pub_detalhe(bigint) from public, anon;
grant execute on function public.pub_registrar_remessa(text, text, jsonb, jsonb, text),
                          public.pub_listar(date, date, text, text, text, int),
                          public.pub_detalhe(bigint) to authenticated;

-- Fonte principal: continua NÃO confirmada. Valor provisório até a inspeção do portal.
update public.parametros
   set valor = '"email_importado_provisorio"',
       descricao = 'Fonte principal das publicações Webjur. PROVISÓRIO (Etapa 6, 06/11/2026): e-mail diário salvo e importado no painel. '
                || 'O portal (historico.webjur.com.br) exige login com OAB e senha e ainda não foi inspecionado; '
                || 'o e-mail não chega à caixa da controladoria. Rever após a inspeção do portal.'
 where chave = 'webjur_fonte_principal' and confirmado = false;
