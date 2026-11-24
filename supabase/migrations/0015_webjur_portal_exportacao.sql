-- =====================================================================
-- 0015 — Etapa 6: exportação do portal Webjur (CSV) como fonte
--
-- Base: exportação real do portal de 06/11/2026, consulta por disponibilização em
-- 05/11/2026, com 39 publicações. Comparada com o e-mail da mesma data: 39 = 39.
--   35 foram casadas pelo "Identificador do documento";
--   4 (diários estaduais de MG, sem identificador) foram casadas pelo conteúdo,
--     que vem formatado de jeito diferente nas duas fontes.
--
-- Muda (nada é apagado):
--   1. teor_solto(): teor sem acentos, pontuação, espaços e caixa, só para comparar fontes.
--   2. _pub_registrar: (0) o código da publicação na fonte (coleta já existente);
--      (b) códigos diferentes do portal com o mesmo conteúdo = publicações distintas; e
--      (c) a correspondência aproximada entre fontes diferentes, com as travas descritas.
--   3. pub_registrar_remessa: aceita id_origem por publicação (código Webjur do portal).
-- =====================================================================
create or replace function public.teor_solto(p text) returns text
language sql immutable as $$
  select regexp_replace(lower(translate(coalesce(p, ''),
    'ÁÀÂÃÄáàâãäÉÈÊËéèêëÍÌÎÏíìîïÓÒÔÕÖóòôõöÚÙÛÜúùûüÇçÑñºª',
    'AAAAAaaaaaEEEEeeeeIIIIiiiiOOOOOoooooUUUUuuuuCcNnoa')), '[^a-z0-9]', '', 'g')
$$;

create or replace function public._pub_registrar(p_pub jsonb, p_origem text, p_id_origem text, p_remessa bigint)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_cnj text; v_teor text; v_dpub date; v_ddisp date; v_chave text; v_id bigint; v_proc bigint;
        v_doc text; v_doc_exist text; v_hash_exist text; v_por text := 'nova'; v_solto text;
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

  -- 0) a mesma publicação já recebida desta fonte com o mesmo código (ex.: código Webjur do portal)
  if p_id_origem is not null then
    select k.publicacao_id, p.teor_hash into v_id, v_hash_exist
      from publicacoes_coletas k join publicacoes p on p.id = k.publicacao_id
     where k.origem = p_origem and k.id_origem = p_id_origem;
    if v_id is not null then
      v_por := 'codigo_da_fonte';
      v_teor_div := v_hash_exist <> md5(normalizar_teor(v_teor));
    end if;
  end if;
  if v_id is null and v_doc is not null then
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
    elsif v_id is not null and p_origem = 'webjur_portal' and p_id_origem is not null
          and exists (select 1 from publicacoes_coletas k where k.publicacao_id = v_id and k.origem = 'webjur_portal'
                                                           and k.id_origem <> p_id_origem) then
      -- 0015: o portal dá um código por publicação. Mesmo CNJ, data e teor com códigos
      -- diferentes no portal = publicações distintas (ex.: intimações iguais para partes diferentes).
      v_id := null;
      v_chave := md5(v_chave || '|cod:' || p_id_origem);
    elsif v_id is not null then
      v_por := 'conteudo';
    end if;
  end if;
  -- c) 0015: entre FONTES DIFERENTES, sem identificador comum. O e-mail e a exportação do portal
  --    formatam o mesmo teor de jeitos distintos (quebras de linha, tipo repetido no início).
  --    Mesmo CNJ + mesma disponibilização + teor equivalente sem acentos/pontuação/espaços
  --    (igual, um terminando com o outro, ou o trecho 41–400 de um contido no outro, com
  --    tamanhos parecidos). Só casa com publicação que ainda NÃO tem coleta desta mesma origem
  --    (duas publicações da mesma fonte nunca se fundem por aproximação).
  if v_id is null and v_cnj is not null and v_ddisp is not null then
    v_solto := teor_solto(v_teor);
    select p.id into v_id
      from publicacoes p
     where p.cnj = v_cnj and p.data_disponibilizacao = v_ddisp
       and (v_doc is null or p.id_documento is null)
       and not exists (select 1 from publicacoes_coletas k where k.publicacao_id = p.id and k.origem = p_origem)
       and length(v_solto) >= 60
       and length(teor_solto(p.teor)) between length(v_solto) * 0.8 and length(v_solto) * 1.25
       and (teor_solto(p.teor) = v_solto
            or right(teor_solto(p.teor), length(v_solto)) = v_solto
            or right(v_solto, length(teor_solto(p.teor))) = teor_solto(p.teor)
            or position(substr(v_solto, 41, 360) in teor_solto(p.teor)) > 0)
     order by p.id limit 1;
    if v_id is not null then
      v_por := 'conteudo_aproximado';
      perform registrar_log_integracao(case when p_origem = 'manual' then 'sistema' else p_origem end, 'info', 'pub_registrar',
        'Publicação reconhecida por conteúdo equivalente vindo de outra fonte (sem identificador comum).',
        jsonb_build_object('publicacao_id', v_id, 'id_origem', p_id_origem, 'remessa_id', p_remessa));
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
  -- 0014: o mesmo diário e data podem vir em duas seções do mesmo e-mail; quando o leitor
  -- informa a ordem da seção, a recontagem é feita por ela.
  select jsonb_agg(jsonb_build_object('ordem', s->'ordem', 'caderno', s->>'caderno', 'data', s->>'data', 'declarado', (s->>'declarado')::int,
           'lidas_servidor', (select count(*) from jsonb_array_elements(p_publicacoes) x
                               where case when s ? 'ordem' then x->>'secao_ordem' = s->>'ordem'
                                          else x->>'secao' = s->>'caderno' and x->>'secao_data' = s->>'data' end))
           order by o),
         sum((s->>'declarado')::int)
    into v_secoes, v_decl
    from jsonb_array_elements(p_remessa->'secoes') with ordinality as t(s, o);
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
    -- 0015: quando a fonte tem código próprio da publicação (portal: "CÓDIGO WEBJUR"), ele é o id da coleta;
    -- o mesmo código em outra exportação é reconhecido como a mesma publicação.
    r := _pub_registrar(p, p_origem, coalesce(nullif(btrim(p->>'id_origem'), ''),
                                     p_arquivo_sha256 || '#' || coalesce(p->>'secao_ordem', p->>'secao', '') || '#' ||
                                     coalesce(p->>'secao_data','') || '#' || coalesce(p->>'seq', v_i::text)), v_rem);
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


revoke execute on function public._pub_registrar(jsonb, text, text, bigint) from public, anon, authenticated;
revoke execute on function public.pub_registrar_remessa(text, text, jsonb, jsonb, text) from public, anon;
grant execute on function public.pub_registrar_remessa(text, text, jsonb, jsonb, text) to authenticated;

-- Fonte principal: portal (exportação "Planilha"), e-mail como contingência — conforme a regra do
-- Prompt Mestre ("se o portal for mais confiável, usar como principal e manter o e-mail como contingência")
-- e a comparação de 06/11/2026. Fica NÃO confirmado até a confirmação da controladoria.
update public.parametros
   set valor = '"portal_exportacao_planilha"',
       descricao = 'Fonte principal das publicações Webjur: exportação "Planilha" (CSV) do portal, importada no painel. '
                || 'Contingência e segunda contagem: e-mail diário (controladoria.oecadv@gmail.com). '
                || 'Base: comparação de 06/11/2026 (05/11: 39 no portal = 39 disponibilizadas no e-mail; 35 casadas pelo identificador do documento, 4 pelo conteúdo).'
 where chave = 'webjur_fonte_principal' and confirmado = false;
