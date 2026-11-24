-- =====================================================================
-- 0003 — Importação do Excel do ADVBOX (RPC transacional e idempotente)
--
-- O painel lê o .xlsx no navegador do administrador, calcula o SHA-256
-- do arquivo e envia as linhas (texto, como aparecem na planilha) para
-- public.importar_arquivo(). A função roda numa única transação: se algo
-- inesperado falhar, nada do arquivo é gravado e a base anterior fica intacta.
-- =====================================================================

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.perfis where user_id = auth.uid() and papel = 'admin')
$$;

create or replace function public.meu_colaborador_id() returns bigint
language sql stable security definer set search_path = public as $$
  select colaborador_id from public.perfis where user_id = auth.uid()
$$;

create or replace function public.importar_arquivo(
  p_nome_arquivo    text,
  p_hash_arquivo    text,
  p_linhas          jsonb,
  p_lote_id         bigint default null,      -- null = nova fotografia da base
  p_data_exportacao timestamptz default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  cab_esperado text[] := array['Prioridade','Data','Hora','Término','Hora Término','Prazo fatal',
    'Data Conclusão','Pontuação','Compromisso','Local','Remetente','Destinatário','Partes',
    'Processo (CNJ)','Protocolo','Tipo de ação','Observações'];
  v_lote bigint; v_imp bigint; v_existente bigint;
  r jsonb; n int; erros jsonb; situ text;
  v_data date; v_hora time; v_pf date; v_term timestamptz; v_concl timestamptz; v_pont int;
  v_rem bigint; v_dest bigint; v_obs text; v_cnj text; v_ref date;
  v_pfj_txt text; v_d4_txt text; v_pdias text; v_hash text;
  faltando text[];
  rejeitadas jsonb := '[]';
  tz text := 'America/Sao_Paulo';
  c_total int; c_val int; c_rej int; c_dup int; c_novas int; c_vinc int; c_amb int;
begin
  if not public.is_admin() then
    raise exception 'Somente administradores podem importar' using errcode = '42501';
  end if;
  if jsonb_typeof(p_linhas) <> 'array' then raise exception 'p_linhas deve ser um array'; end if;
  if jsonb_array_length(p_linhas) = 0 then raise exception 'Arquivo sem linhas de dados'; end if;
  if jsonb_array_length(p_linhas) > 1000 then
    raise exception 'Arquivo com % linhas; o limite por arquivo é 1.000', jsonb_array_length(p_linhas);
  end if;
  if p_hash_arquivo !~ '^[0-9a-f]{64}$' then raise exception 'hash do arquivo inválido (SHA-256 hex)'; end if;

  -- mesmo arquivo de novo: nada a fazer (idempotência)
  select id into v_existente from importacoes where hash_arquivo = p_hash_arquivo;
  if found then
    return jsonb_build_object('status','ja_importado','importacao_id',v_existente,
      'mensagem','Este arquivo já foi importado; nenhuma alteração foi feita.');
  end if;

  if p_lote_id is null then
    insert into lotes_importacao (criado_por, data_exportacao) values (auth.uid(), p_data_exportacao)
    returning id into v_lote;
  else
    select id into v_lote from lotes_importacao where id = p_lote_id;
    if not found then raise exception 'Lote % inexistente', p_lote_id; end if;
  end if;

  -- cabeçalho
  select array_agg(c) into faltando from unnest(cab_esperado) c where not (p_linhas->0 ? c);
  if faltando is not null then
    insert into importacoes (lote_id, nome_arquivo, hash_arquivo, importado_por, status, total_linhas, mensagem)
    values (v_lote, p_nome_arquivo, p_hash_arquivo, auth.uid(), 'rejeitada', jsonb_array_length(p_linhas),
            'Colunas ausentes: ' || array_to_string(faltando, ', '))
    returning id into v_imp;
    return jsonb_build_object('status','rejeitada','importacao_id',v_imp,'colunas_ausentes',to_jsonb(faltando));
  end if;

  insert into importacoes (lote_id, nome_arquivo, hash_arquivo, importado_por)
  values (v_lote, p_nome_arquivo, p_hash_arquivo, auth.uid()) returning id into v_imp;

  -- ------------------------------------------------------------ linhas
  for r, n in select e, o::int + 1 from jsonb_array_elements(p_linhas) with ordinality t(e, o) loop
    erros := '[]'; v_data := null; v_hora := null; v_pf := null; v_term := null; v_concl := null;
    v_pont := null; v_rem := null; v_dest := null;

    begin v_data := parse_data_br(r->>'Data');
    exception when others then erros := erros || jsonb_build_object('campo','Data','nivel','erro','mensagem','Data inválida: '||coalesce(r->>'Data','')); end;
    if v_data is null and erros = '[]' then
      erros := erros || jsonb_build_object('campo','Data','nivel','erro','mensagem','Data da agenda ausente');
    end if;

    begin
      if nullif(btrim(r->>'Hora'),'') is not null then
        if btrim(r->>'Hora') !~ '^\d{2}:\d{2}$' then raise exception 'x'; end if;
        v_hora := (r->>'Hora')::time;
      end if;
    exception when others then erros := erros || jsonb_build_object('campo','Hora','nivel','erro','mensagem','Hora inválida: '||(r->>'Hora')); end;

    begin v_pf := parse_data_br(r->>'Prazo fatal');
    exception when others then erros := erros || jsonb_build_object('campo','Prazo fatal','nivel','erro','mensagem','Prazo fatal inválido: '||(r->>'Prazo fatal')); end;

    begin
      if nullif(btrim(r->>'Término'),'') is not null then
        v_term := (parse_data_br(r->>'Término') + coalesce(nullif(btrim(r->>'Hora Término'),'')::time, '00:00'::time))
                  at time zone tz;
      end if;
    exception when others then erros := erros || jsonb_build_object('campo','Término','nivel','erro','mensagem','Término inválido'); end;

    begin
      if nullif(btrim(r->>'Data Conclusão'),'') is not null then
        if btrim(r->>'Data Conclusão') !~ '^\d{2}/\d{2}/\d{4} \d{2}:\d{2}$' then raise exception 'x'; end if;
        v_concl := to_timestamp(btrim(r->>'Data Conclusão'), 'DD/MM/YYYY HH24:MI')::timestamp at time zone tz;
      end if;
    exception when others then erros := erros || jsonb_build_object('campo','Data Conclusão','nivel','erro','mensagem','Data de conclusão inválida: '||(r->>'Data Conclusão')); end;

    begin v_pont := nullif(btrim(r->>'Pontuação'),'')::int;
    exception when others then erros := erros || jsonb_build_object('campo','Pontuação','nivel','aviso','mensagem','Pontuação não numérica (ignorada)'); end;

    if nullif(btrim(r->>'Destinatário'),'') is null then
      erros := erros || jsonb_build_object('campo','Destinatário','nivel','erro','mensagem','Responsável (Destinatário) ausente');
    end if;
    if nullif(btrim(r->>'Remetente'),'') is null then
      erros := erros || jsonb_build_object('campo','Remetente','nivel','erro','mensagem','Remetente ausente');
    end if;

    v_cnj := nullif(btrim(r->>'Processo (CNJ)'),'');
    if v_cnj is not null and tribunal_do_cnj(v_cnj) is null then
      erros := erros || jsonb_build_object('campo','Processo (CNJ)','nivel','aviso','mensagem','Número fora do padrão CNJ: '||v_cnj);
    end if;
    if nullif(btrim(r->>'Compromisso'),'') is null then
      erros := erros || jsonb_build_object('campo','Compromisso','nivel','aviso','mensagem','Compromisso (tipo da tarefa) em branco');
    end if;
    if v_pf is not null and v_data is not null and v_data > v_pf then
      erros := erros || jsonb_build_object('campo','Data','nivel','aviso','mensagem','Data da agenda posterior ao Prazo fatal da tarefa');
    end if;

    v_hash := md5(r::text);
    if exists (select 1 from jsonb_array_elements(erros) e where e->>'nivel' = 'erro') then
      situ := 'rejeitada';
      rejeitadas := rejeitadas || jsonb_build_object('linha', n, 'erros', erros);
    elsif exists (select 1 from linhas_importadas where lote_id = v_lote and hash_linha = v_hash and situacao = 'valida') then
      situ := 'duplicada';
    else
      situ := 'valida';
    end if;

    if situ <> 'rejeitada' then
      insert into colaboradores (nome_advbox) values (btrim(r->>'Remetente')) on conflict (nome_advbox) do nothing;
      insert into colaboradores (nome_advbox) values (btrim(r->>'Destinatário')) on conflict (nome_advbox) do nothing;
      select id into v_rem  from colaboradores where nome_advbox = btrim(r->>'Remetente');
      select id into v_dest from colaboradores where nome_advbox = btrim(r->>'Destinatário');
    end if;

    v_obs := r->>'Observações';
    v_ref := coalesce(v_pf, v_data);
    v_pfj_txt := ultima_captura(v_obs, '(?:^|[^a-z])(?:PF|Prazo[ \t]+Fatal)[ \t]*:?[ \t]*(\d{1,2}/\d{1,2}(?:/\d{2,4})?)');
    v_d4_txt  := ultima_captura(v_obs, 'D\s*-\s*4\s*:?\s*(\d{1,2}/\d{1,2}(?:/\d{2,4})?)');
    v_pdias   := ultima_captura(v_obs, 'Prazo\s+(\d{1,3})\s+dias');

    insert into linhas_importadas (
      importacao_id, lote_id, numero_linha, dados_brutos, hash_linha, situacao, erros,
      prioridade, data_agenda, hora_agenda, termino, pf_tarefa, data_conclusao, pontuacao,
      compromisso, local, remetente_id, responsavel_id, partes, processo_cnj, tribunal_cnj,
      protocolo, tipo_acao, observacoes,
      pf_judicial_anotado, pf_judicial_anotado_txt, d4_anotado, d4_anotado_txt, prazo_dias_anotado,
      chave_estavel)
    values (
      v_imp, v_lote, n, r, v_hash, situ, erros,
      nullif(btrim(r->>'Prioridade'),''), v_data, v_hora, v_term, v_pf, v_concl, v_pont,
      nullif(btrim(r->>'Compromisso'),''), nullif(btrim(r->>'Local'),''), v_rem, v_dest,
      nullif(btrim(r->>'Partes'),''), v_cnj, tribunal_do_cnj(v_cnj),
      nullif(btrim(r->>'Protocolo'),''), nullif(btrim(r->>'Tipo de ação'),''), v_obs,
      data_anotada(v_pfj_txt, v_ref), v_pfj_txt,
      data_anotada(v_d4_txt, coalesce(data_anotada(v_pfj_txt, v_ref), v_ref)), v_d4_txt,
      v_pdias::int,
      case when situ = 'rejeitada' then null else
        chave_estavel(r->>'Compromisso', r->>'Remetente', r->>'Partes', r->>'Processo (CNJ)', r->>'Tipo de ação', v_obs) end);
  end loop;

  -- ------------------------------------------------------------ vínculo com tarefas
  -- 1) chave estável única no lote  -> chave 'E:'
  -- 2) senão, chave de ocorrência (estável + datas + conclusão) única no lote -> 'O:'
  -- 3) senão -> ambígua: NÃO é vinculada (evita fundir tarefas diferentes)
  -- Linhas de outro arquivo do mesmo lote com a mesma chave tornam a nova linha ambígua.
  create temporary table _vinc on commit drop as
  select l.id,
         l.chave_estavel,
         (select count(*) from linhas_importadas x where x.lote_id = l.lote_id and x.situacao = 'valida'
             and x.chave_estavel = l.chave_estavel) as n_est,
         md5(l.chave_estavel || '|' || coalesce(l.data_agenda::text,'') || '|' || coalesce(l.pf_tarefa::text,'')
             || '|' || coalesce(l.data_conclusao::text,'') || '|' || coalesce(l.responsavel_id::text,'')) as chave_oc
    from linhas_importadas l where l.importacao_id = v_imp and l.situacao = 'valida';
  alter table _vinc add column n_oc int, add column chave text, add column metodo text;
  -- chave de ocorrência precisa ser única em TODO o lote (inclusive nos outros arquivos,
  -- ex.: pendentes x concluídas). Tarefas recorrentes de mesmo texto se distinguem por datas/conclusão.
  update _vinc v set n_oc = (select count(*) from _vinc w where w.chave_oc = v.chave_oc)
                         + (select count(*) from linhas_importadas x
                              where x.lote_id = v_lote and x.importacao_id <> v_imp and x.situacao = 'valida'
                                and x.chave_estavel = v.chave_estavel
                                and md5(x.chave_estavel || '|' || coalesce(x.data_agenda::text,'') || '|' || coalesce(x.pf_tarefa::text,'')
                                    || '|' || coalesce(x.data_conclusao::text,'') || '|' || coalesce(x.responsavel_id::text,'')) = v.chave_oc) where true;
  update _vinc set chave = 'E:' || chave_estavel, metodo = 'chave_estavel' where n_est = 1;
  update _vinc set chave = 'O:' || chave_oc, metodo = 'chave_ocorrencia' where n_est > 1 and n_oc = 1;
  update _vinc set metodo = 'ambigua' where chave is null;

  select count(*) into c_vinc from _vinc v join tarefas t on t.chave_identificacao = v.chave;
  insert into tarefas (chave_identificacao, metodo)
  select chave, metodo from _vinc where chave is not null on conflict (chave_identificacao) do nothing;

  update linhas_importadas l set tarefa_id = t.id, metodo_vinculo = v.metodo
    from _vinc v left join tarefas t on t.chave_identificacao = v.chave
   where l.id = v.id;
  update tarefas t set ultima_linha_id = l.id
    from linhas_importadas l where l.importacao_id = v_imp and l.tarefa_id = t.id;

  -- ------------------------------------------------------------ eventos
  perform public._gerar_eventos_importacao(v_imp, coalesce(p_data_exportacao, now()));

  select count(*), count(*) filter (where situacao='valida'), count(*) filter (where situacao='rejeitada'),
         count(*) filter (where situacao='duplicada'), count(*) filter (where metodo_vinculo='ambigua')
    into c_total, c_val, c_rej, c_dup, c_amb
    from linhas_importadas where importacao_id = v_imp;
  c_novas := c_val - c_amb - c_vinc;

  update importacoes set status = 'concluida', total_linhas = c_total, linhas_validas = c_val,
         linhas_rejeitadas = c_rej, linhas_duplicadas = c_dup, tarefas_novas = c_novas,
         tarefas_vinculadas = c_vinc, linhas_ambiguas = c_amb,
         mensagem = case when c_total in (25, 50, 100, 200, 500, 1000) then
           'Atenção: o arquivo tem exatamente ' || c_total || ' linhas. Confira se a lista não estava limitada '
           || '(itens por página) no momento da exportação.' end
   where id = v_imp;

  insert into eventos (chave_dedupe, tipo, ocorrido_em, precisao_ocorrido, origem, historico_recuperado,
                       classificacao, evidencia)
  values ('imp:'||v_imp, 'importacao', now(), 'segundo', 'sistema', false, 'confirmado',
          jsonb_build_object('importacao_id', v_imp, 'lote_id', v_lote, 'arquivo', p_nome_arquivo,
                             'usuario', auth.uid()));

  return jsonb_build_object('status','concluida','importacao_id',v_imp,'lote_id',v_lote,
    'total_linhas',c_total,'validas',c_val,'rejeitadas',c_rej,'duplicadas_no_lote',c_dup,
    'tarefas_novas',c_novas,'tarefas_ja_conhecidas',c_vinc,'ambiguas_nao_vinculadas',c_amb,
    'alerta_possivel_corte', c_total in (25, 50, 100, 200, 500, 1000),
    'erros_por_linha', rejeitadas);
end $$;

-- ---------------------------------------------------------------------
-- Eventos derivados de uma importação
-- ---------------------------------------------------------------------
create or replace function public._gerar_eventos_importacao(p_imp bigint, p_ref timestamptz)
returns void language plpgsql security definer set search_path = public as $$
declare tz text := 'America/Sao_Paulo';
begin
  create temporary table _l on commit drop as
  select l.*, coalesce('t'||l.tarefa_id, 'h'||l.hash_linha) as base
    from linhas_importadas l where l.importacao_id = p_imp and l.situacao = 'valida';

  -- 1) Encaminhamentos registrados automaticamente pelo ADVBOX em Observações
  insert into eventos (chave_dedupe, tarefa_id, linha_id, tipo, ocorrido_em, precisao_ocorrido,
                       colaborador_txt, valor_novo, origem, historico_recuperado, classificacao, evidencia)
  select md5('enc|'||l.base||'|'||x[1]||'|'||x[2]||'|'||x[3]), l.tarefa_id, l.id, 'encaminhamento',
         to_timestamp(x[3], 'DD/MM/YYYY HH24:MI:SS')::timestamp at time zone tz, 'segundo',
         '@'||x[1], jsonb_build_object('de','@'||x[1],'para','@'||x[2]),
         'excel_observacoes', true, 'confirmado',
         jsonb_build_object('texto', '@'||x[1]||' encaminhou para @'||x[2]||' em '||x[3])
    from _l l, regexp_matches(l.observacoes, '@(\S+) encaminhou para @(\S+) em (\d{2}/\d{2}/\d{4} \d{2}:\d{2}:\d{2})', 'g') x
  on conflict (chave_dedupe) do nothing;

  -- 2) Anotações de realocação ("MG - 23/10 - Tarefa realocada ...")
  insert into eventos (chave_dedupe, tarefa_id, linha_id, tipo, ocorrido_em, precisao_ocorrido,
                       colaborador_txt, justificativa, origem, historico_recuperado, classificacao, evidencia)
  select md5('realoc|'||l.base||'|'||p.texto), l.tarefa_id, l.id, 'anotacao_realocacao',
         (data_anotada(a[2], (p_ref at time zone tz)::date)::timestamp) at time zone tz, 'dia',
         upper(a[1]), nullif(btrim(regexp_replace(a[3], '^\s*[.:-]?\s*', '')), ''),
         'excel_observacoes', true, 'anotado', jsonb_build_object('texto', p.texto, 'data_txt', a[2])
    from _l l, paragrafos_obs(l.observacoes) p,
         lateral regexp_match(p.texto, '^\s*([A-Za-z]{1,4})\s*-\s*(\d{1,2}/\d{1,2}(?:/\d{2,4})?)\s*[-–]\s*tarefa\s+realocada([\s\S]*)$', 'i') a
   where a is not null
  on conflict (chave_dedupe) do nothing;

  -- 3) Pedidos de reagendamento (classificação POTENCIAL por regra de texto)
  insert into eventos (chave_dedupe, tarefa_id, linha_id, tipo, ocorrido_em, precisao_ocorrido,
                       colaborador_txt, valor_novo, justificativa, origem, historico_recuperado,
                       classificacao, evidencia)
  select md5('pedido|'||l.base||'|'||p.texto), l.tarefa_id, l.id, 'pedido_reagendamento',
         case when a is not null then (data_anotada(a[2], (p_ref at time zone tz)::date)::timestamp) at time zone tz end,
         case when a is not null then 'dia' else 'desconhecida' end,
         upper(a[1]),
         jsonb_build_object('nova_data_solicitada_txt',
           (regexp_match(p.texto, 'para\s+(?:o\s+)?(?:dia\s+)?(\d{1,2}/\d{1,2}(?:/\d{2,4})?)', 'i'))[1]),
         p.texto, 'excel_observacoes', true, 'potencial',
         jsonb_build_object('regra', 'verbo reagendar/realocar/remarcar no infinitivo ou imperativo', 'texto', p.texto)
    from _l l, paragrafos_obs(l.observacoes) p,
         lateral regexp_match(p.texto, '^\s*([A-Za-z]{1,4})\s*-\s*(\d{1,2}/\d{1,2}(?:/\d{2,4})?)', 'i') a
   where p.texto ~* '(reagendar|reagende|realocar|realoque|remarcar|remarque)'
     and p.texto !~* '^\s*[A-Za-z]{1,4}\s*-\s*[0-9/]+\s*[-–]\s*tarefa\s+realocada'
  on conflict (chave_dedupe) do nothing;

  -- 4) Conclusões (Data Conclusão). Responsável = Destinatário na exportação:
  --    o Excel não informa quem concluiu (limitação registrada na evidência).
  insert into eventos (chave_dedupe, tarefa_id, linha_id, tipo, ocorrido_em, precisao_ocorrido,
                       colaborador_id, origem, historico_recuperado, classificacao, evidencia)
  select md5('concl|'||coalesce('t'||l.tarefa_id, l.chave_estavel||'|'||l.data_agenda||'|'||coalesce(l.pf_tarefa::text,'')
              ||'|'||l.responsavel_id)||'|'||l.data_conclusao),
         l.tarefa_id, l.id, 'conclusao', l.data_conclusao, 'minuto', l.responsavel_id,
         'excel_campo', false, 'confirmado',
         jsonb_build_object('limitacao', 'Responsável atribuído = Destinatário na exportação; o Excel não identifica quem concluiu.')
    from _l l where l.data_conclusao is not null
  on conflict (chave_dedupe) do nothing;

  -- 5) Alterações observadas entre a importação anterior e esta (mesma tarefa)
  create temporary table _cmp on commit drop as
  select l.id, l.tarefa_id, l.data_agenda, l.pf_tarefa, l.responsavel_id, l.observacoes,
         coalesce(l.pf_judicial_anotado, a.pf_judicial_anotado) is not null as prazo_judicial,
         a.id as ant_id, a.data_agenda as ant_data, a.pf_tarefa as ant_pf, a.responsavel_id as ant_resp,
         a.observacoes as ant_obs,
         (select string_agg(p.texto, E'\n' order by p.ordem) from paragrafos_obs(l.observacoes) p
           where p.texto ~* 'tarefa\s+realocada'
             and not exists (select 1 from paragrafos_obs(a.observacoes) q where q.texto = p.texto)) as just_nova
    from _l l
    join lateral (select x.* from linhas_importadas x
                   where x.tarefa_id = l.tarefa_id and x.lote_id < l.lote_id and x.situacao = 'valida'
                   order by x.lote_id desc, x.id desc limit 1) a on true
   where l.tarefa_id is not null;

  insert into eventos (chave_dedupe, tarefa_id, linha_id, tipo, precisao_ocorrido, valor_anterior, valor_novo,
                       justificativa, origem, historico_recuperado, classificacao, estado_trava, evidencia)
  select md5('cmp|data|'||c.id), c.tarefa_id, c.id, 'alteracao_data_agenda', 'entre_importacoes',
         to_jsonb(c.ant_data), to_jsonb(c.data_agenda), c.just_nova, 'comparacao_importacoes', false, 'confirmado',
         'nao_monitorada', jsonb_build_object('linha_anterior', c.ant_id, 'linha_atual', c.id,
           'justificativa_encontrada', c.just_nova is not null)
    from _cmp c where c.data_agenda is distinct from c.ant_data
  on conflict (chave_dedupe) do nothing;

  insert into eventos (chave_dedupe, tarefa_id, linha_id, tipo, precisao_ocorrido, valor_anterior, valor_novo,
                       justificativa, origem, historico_recuperado, classificacao, estado_trava, evidencia)
  select md5('cmp|pf|'||c.id), c.tarefa_id, c.id, 'alteracao_pf_tarefa', 'entre_importacoes',
         to_jsonb(c.ant_pf), to_jsonb(c.pf_tarefa), c.just_nova, 'comparacao_importacoes', false, 'confirmado',
         -- Regra confirmada (24/10/2026): PF só pode mudar em prazo NÃO judicial, com autorização da
         -- controladoria. Em tarefa com PF Judicial, qualquer mudança do PF da Tarefa é violação.
         -- O Excel não registra autorização: sem anotação de realocação também é violação; com anotação,
         -- fica pendente de verificação (o autor da anotação precisa ser da controladoria).
         case when c.prazo_judicial then 'violacao_detectada'
              when c.just_nova is null then 'violacao_detectada'
              else 'nao_monitorada' end,
         jsonb_build_object('linha_anterior', c.ant_id, 'linha_atual', c.id,
           'justificativa_encontrada', c.just_nova is not null,
           'autorizacao_registrada', false,
           'prazo_judicial', c.prazo_judicial,
           'motivo', case when c.prazo_judicial then 'PF da Tarefa alterado em tarefa com PF Judicial (vedado)'
                          when c.just_nova is null then 'PF alterado sem justificativa nem autorização registradas'
                          else 'Prazo não judicial alterado com anotação; confirmar autorização da controladoria' end,
           'antecipacao', c.pf_tarefa < c.ant_pf)
    from _cmp c where c.pf_tarefa is distinct from c.ant_pf
  on conflict (chave_dedupe) do nothing;

  insert into eventos (chave_dedupe, tarefa_id, linha_id, tipo, precisao_ocorrido, valor_anterior, valor_novo,
                       justificativa, origem, historico_recuperado, classificacao, estado_trava, evidencia)
  select md5('cmp|resp|'||c.id), c.tarefa_id, c.id, 'alteracao_responsavel', 'entre_importacoes',
         to_jsonb(c.ant_resp), to_jsonb(c.responsavel_id), c.just_nova, 'comparacao_importacoes', false, 'confirmado',
         'nao_monitorada', jsonb_build_object('linha_anterior', c.ant_id, 'linha_atual', c.id,
           'justificativa_encontrada', c.just_nova is not null)
    from _cmp c where c.responsavel_id is distinct from c.ant_resp
  on conflict (chave_dedupe) do nothing;
end $$;
