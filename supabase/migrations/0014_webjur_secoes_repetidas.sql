-- =====================================================================
-- 0014 — Etapa 6, ajustes após os e-mails reais da controladoria (06/11/2026)
--
-- Os e-mails da assinatura do escritório (OAB/MG 176.787) trouxeram o mesmo diário e
-- a mesma data em duas seções (DJ Minas Gerais 04/11/2026: 25 e 4 publicações).
-- A recontagem da 0013 somava as duas e marcaria a remessa como divergente sem motivo.
-- Agora, quando o leitor informa a ordem da seção (secao_ordem), a recontagem e o
-- identificador da coleta usam a ordem. Sem a ordem, o comportamento da 0013 continua.
-- Nada é apagado.
-- =====================================================================
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
    r := _pub_registrar(p, p_origem, p_arquivo_sha256 || '#' || coalesce(p->>'secao_ordem', p->>'secao', '') || '#' ||
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

revoke execute on function public.pub_registrar_remessa(text, text, jsonb, jsonb, text) from public, anon;
grant execute on function public.pub_registrar_remessa(text, text, jsonb, jsonb, text) to authenticated;
