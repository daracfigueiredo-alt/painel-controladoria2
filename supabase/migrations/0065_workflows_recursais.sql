-- =====================================================================
-- 0063 — Workflows de prazos recursais (controladoria, 27/11/2026). Aditiva sobre a 0061.
-- Especificação: "Workflows de prazos recursais – Atlas" (versão revisada: comunicação ao cliente pela
-- ASSISTENTE DA EQUIPE; protocolo pela controladoria; fiscalização do protocolo pelo advogado autor).
-- Decisões da controladoria (27/11/2026): implantar tudo de uma vez; dispensa aprovada pelo LÍDER DA EQUIPE;
-- o sistema SUGERE o PF (data da intimação + prazo legal em dias úteis, calendário do tribunal) e a
-- controladoria CONFIRMA.
--
-- Motor (o que muda na 0061):
--   * condições compostas: termos separados por '&'; 'chave' (sim), '!chave' (não), 'chave∋VALOR'
--     (escolha múltipla contém VALOR). Um termo falso dispensa na hora; termo sem resposta espera.
--   * decisão de escolha múltipla (tipo 'multipla', com opcoes) — ex.: quais recursos interpor
--     (REsp e RE juntos, por exemplo). Decisão do LÍDER (quem = 'lider'): só o líder da equipe ou a
--     controladoria respondem (o advogado não aprova a própria dispensa).
--   * papel 'lider' (líder da equipe do fluxo) como responsável de etapa.
--   * PF a confirmar: fluxo filho de recurso nasce com o PF SUGERIDO (data da intimação do pai + prazo do
--     modelo, em dobro se marcado); as etapas que dependem do PF (peça e protocolo) ficam "PF a confirmar"
--     até a controladoria confirmar no painel. Análise e comunicação não esperam.
--   * perguntas aparecem assim que a etapa a que se referem é liberada (o advogado pode decidir antes de
--     concluir a tarefa no Atlas; as etapas seguintes continuam esperando a conclusão).
--   * fluxos filhos recebem via_fluxo_pai = sim e interpor = sim (a análise e a comunicação já foram feitas
--     no fluxo da decisão); recurso aberto direto pela triagem (ex.: contrarrazões) começa pela análise.
-- =====================================================================

-- ---------------------------------------------------------------- estrutura
alter table public.wf_modelos add column if not exists prazo_legal_dias int check (prazo_legal_dias between 1 and 60);
alter table public.wf_modelos add column if not exists nome_peca text;
alter table public.wf_modelos add column if not exists ordem int not null default 100;

alter table public.wf_decisoes_modelo add column if not exists tipo text not null default 'booleana';
alter table public.wf_decisoes_modelo add column if not exists opcoes jsonb;
alter table public.wf_decisoes_modelo drop constraint if exists wf_decisoes_modelo_tipo_check;
alter table public.wf_decisoes_modelo add constraint wf_decisoes_modelo_tipo_check check (tipo in ('booleana','multipla'));
alter table public.wf_decisoes_modelo drop constraint if exists wf_decisoes_modelo_quem_check;
alter table public.wf_decisoes_modelo add constraint wf_decisoes_modelo_quem_check check (quem in ('advogado','controladoria','lider'));

alter table public.wf_etapas_modelo drop constraint if exists wf_etapas_modelo_papel_check;
alter table public.wf_etapas_modelo add constraint wf_etapas_modelo_papel_check check (papel in ('advogado','assistente','controladoria','lider'));

alter table public.wf_tarefas drop constraint if exists wf_tarefas_status_check;
alter table public.wf_tarefas add constraint wf_tarefas_status_check check (status in
  ('aguardando','aguardando_decisao','aguardando_pf','liberada','criando','criada','verificar','sem_responsavel',
   'em_subfluxo','concluida','dispensada','cancelada'));

alter table public.wf_instancias add column if not exists prazo_em_dobro boolean not null default false;
alter table public.wf_instancias add column if not exists pf_confirmado boolean not null default true;
alter table public.wf_instancias add column if not exists pf_sugerido date;
alter table public.wf_instancias add column if not exists raiz_id bigint references public.wf_instancias(id);
update public.wf_instancias w set raiz_id = coalesce(w.pai_instancia_id, w.id) where w.raiz_id is null;
create index if not exists wf_instancias_raiz_idx on public.wf_instancias (raiz_id);

update public.wf_modelos set ordem = 10 where codigo = 'MESTRE';

-- ---------------------------------------------------------------- condições
-- 'sim' | 'nao' | 'pendente'. Um termo falso decide 'nao' mesmo com outros sem resposta.
create or replace function public._wf_cond_avaliar(p_cond text, p_dec jsonb) returns text
language plpgsql immutable set search_path = public as $$
declare termo text; k text; v jsonb; r text := 'sim'; neg boolean; val text;
begin
  if p_cond is null or btrim(p_cond) = '' then return 'sim'; end if;
  foreach termo in array string_to_array(p_cond, '&') loop
    termo := btrim(termo);
    if position('∋' in termo) > 0 then
      k := split_part(termo, '∋', 1); val := split_part(termo, '∋', 2);
      v := p_dec -> k;
      if v is null or jsonb_typeof(v) <> 'array' then r := 'pendente';
      elsif not (v ? val) then return 'nao';
      end if;
    else
      neg := left(termo, 1) = '!'; k := ltrim(termo, '!');
      v := p_dec -> k;
      if v is null or jsonb_typeof(v) <> 'boolean' then r := 'pendente';
      elsif (v::boolean) = neg then return 'nao';
      end if;
    end if;
  end loop;
  return r;
end $$;

create or replace function public._wf_cond_chaves(p_cond text) returns text[]
language sql immutable set search_path = public as $$
  select coalesce(array_agg(distinct split_part(ltrim(btrim(t), '!'), '∋', 1)), '{}')
    from unnest(string_to_array(coalesce(p_cond, ''), '&')) t where btrim(t) <> ''
$$;

-- PF sugerido: n dias úteis (em dobro, se for o caso) contados da data da intimação, calendário do tribunal do processo
create or replace function public._wf_pf_sugerido(p_data date, p_dias int, p_dobro boolean, p_cnj text) returns date
language sql stable set search_path = public as $$
  select case when p_data is null or p_dias is null then null
              else somar_dias_uteis(p_data, p_dias * case when coalesce(p_dobro, false) then 2 else 1 end, tribunal_do_cnj(p_cnj)) end
$$;

-- ---------------------------------------------------------------- responsável (com líder)
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
  elsif p_papel = 'lider' then
    select pf.colaborador_id into colaborador_id from lideres_equipes le join perfis pf on pf.user_id = le.user_id and pf.papel = 'lider'
     where le.equipe_id = i.equipe_id and pf.colaborador_id is not null order by le.id limit 1;
    if colaborador_id is null then
      problema := case when i.equipe_id is null then 'Fluxo sem equipe: não há como saber o líder'
                       else 'Equipe ' || (select nome from equipes where id = i.equipe_id) || ' sem líder com conta no painel' end;
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

-- títulos: {peca} = peça/recurso do fluxo (ou do fluxo pai, nas rotinas de comunicação e dispensa)
create or replace function public._wf_texto(p_modelo text, p_inst wf_instancias) returns text
language sql stable set search_path = public as $$
  select replace(replace(replace(replace(replace(p_modelo,
    '{providencia}', coalesce(nullif(p_inst.providencia, ''), coalesce(p_inst.natureza, 'PROVIDÊNCIA'))),
    '{motivo}', coalesce(nullif(p_inst.dados->>'motivo', ''), coalesce(p_inst.providencia, 'ANDAMENTO'))),
    '{finalidade}', coalesce(nullif(p_inst.dados->>'finalidade', ''), coalesce(p_inst.providencia, 'PROCESSO'))),
    '{peca}', coalesce((select nome_peca from wf_modelos where id = p_inst.modelo_id), nullif(p_inst.dados->>'peca', ''), 'DECISÃO')),
    '{cnj}', coalesce(p_inst.cnj, 'SEM PROCESSO'))
$$;

-- cria um fluxo e as etapas dele (sem checar permissão: quem chama já checou)
create or replace function public._wf_criar_instancia(p_modelo text, p_pai_inst bigint, p_pai_tarefa bigint, p_campos jsonb)
returns bigint language plpgsql security definer set search_path = public as $$
declare m wf_modelos; i wf_instancias; e record;
begin
  select * into m from wf_modelos where codigo = p_modelo and ativo;
  if m.id is null then raise exception 'Modelo de workflow % inexistente ou inativo', p_modelo; end if;
  insert into wf_instancias (modelo_id, pai_instancia_id, pai_tarefa_id, origem_tipo, origem_id, cnj, cliente, atlas_lawsuit_id,
      atlas_client_id, equipe_id, advogado_colaborador_id, natureza, providencia, modalidade_intimacao, data_recebimento,
      data_ciencia, prazo_legal_dias, pf, link_intimacao, dados, decisoes, criado_por, prazo_em_dobro, pf_confirmado, pf_sugerido)
  values (m.id, p_pai_inst, p_pai_tarefa, coalesce(p_campos->>'origem_tipo', 'manual'),
      nullif(p_campos->>'origem_id', ''), nullif(p_campos->>'cnj', ''), nullif(p_campos->>'cliente', ''),
      nullif(p_campos->>'atlas_lawsuit_id', '')::uuid, nullif(p_campos->>'atlas_client_id', '')::uuid,
      nullif(p_campos->>'equipe_id', '')::bigint, nullif(p_campos->>'advogado_colaborador_id', '')::bigint,
      nullif(p_campos->>'natureza', ''), nullif(p_campos->>'providencia', ''), nullif(p_campos->>'modalidade_intimacao', ''),
      nullif(p_campos->>'data_recebimento', '')::date, nullif(p_campos->>'data_ciencia', '')::date,
      coalesce(nullif(p_campos->>'prazo_legal_dias', '')::int, m.prazo_legal_dias), nullif(p_campos->>'pf', '')::date,
      nullif(p_campos->>'link_intimacao', ''),
      coalesce(p_campos->'dados', '{}'), coalesce(p_campos->'decisoes', '{}'), auth.uid(),
      coalesce((p_campos->>'prazo_em_dobro')::boolean, false), coalesce((p_campos->>'pf_confirmado')::boolean, true),
      nullif(p_campos->>'pf_sugerido', '')::date)
  returning * into i;
  update wf_instancias set raiz_id = coalesce((select raiz_id from wf_instancias where id = p_pai_inst), i.id) where id = i.id;
  for e in select * from wf_etapas_modelo where modelo_id = m.id order by ordem loop
    insert into wf_tarefas (instancia_id, etapa_modelo_id, titulo, papel)
    values (i.id, e.id, left(_wf_texto(coalesce(e.titulo, ''), i), 500), e.papel);
  end loop;
  perform _wf_evento(i.id, p_pai_tarefa, 'fluxo_iniciado', jsonb_build_object('modelo', p_modelo, 'pai', p_pai_inst,
    'pf', i.pf, 'pf_confirmado', i.pf_confirmado));
  return i.id;
end $$;

-- motor: libera, dispensa, abre sub-fluxos e encerra. Idempotente; chamado depois de qualquer mudança.
create or replace function public._wf_avancar(p_inst bigint) returns void
language plpgsql security definer set search_path = public as $$
declare i wf_instancias; t record; v_deps_ok boolean; v_av text; v_r record; v_filho bigint; v_fm wf_modelos;
        v_mudou boolean := true; v_voltas int := 0; v_dec jsonb; v_pf date; v_nota text;
begin
  select * into i from wf_instancias where id = p_inst for update;
  if i.id is null or i.status <> 'ativo' then return; end if;
  while v_mudou and v_voltas < 20 loop
    v_mudou := false; v_voltas := v_voltas + 1;
    for t in select wt.*, em.codigo, em.depende_de, em.condicao, em.sub_fluxo, em.prazo_dias, em.teto_antes_pf, em.leva_pf
               from wf_tarefas wt join wf_etapas_modelo em on em.id = wt.etapa_modelo_id
              where wt.instancia_id = i.id and wt.status in ('aguardando','aguardando_decisao','aguardando_pf','sem_responsavel')
              order by em.ordem loop
      -- dependências: todas concluídas ou dispensadas
      select coalesce(bool_and(x.status in ('concluida','dispensada')), true) into v_deps_ok
        from wf_tarefas x join wf_etapas_modelo xm on xm.id = x.etapa_modelo_id
       where x.instancia_id = i.id and xm.codigo = any(t.depende_de);
      if not v_deps_ok then continue; end if;
      -- condição (SE/ENTÃO)
      v_dec := (select decisoes from wf_instancias where id = i.id);
      v_av := _wf_cond_avaliar(t.condicao, v_dec);
      if v_av = 'pendente' then
        if t.status <> 'aguardando_decisao' then update wf_tarefas set status = 'aguardando_decisao' where id = t.id; end if;
        continue;
      end if;
      if v_av = 'nao' then
        select string_agg(coalesce(d.pergunta, k) || ' ' ||
                 case when jsonb_typeof(v_dec->k) = 'boolean' then case when (v_dec->>k)::boolean then 'Sim' else 'Não' end
                      else coalesce((select string_agg(coalesce((select o->>'rotulo' from jsonb_array_elements(d.opcoes) o where o->>'valor' = x), x), ', ')
                                      from jsonb_array_elements_text(v_dec->k) x), '—') end, '; ')
          into v_nota
          from unnest(_wf_cond_chaves(t.condicao)) k left join wf_decisoes_modelo d on d.modelo_id = i.modelo_id and d.chave = k
         where v_dec ? k and k <> 'via_fluxo_pai';
        update wf_tarefas set status = 'dispensada', concluida_em = now(),
               nota = case when 'via_fluxo_pai' = any(_wf_cond_chaves(t.condicao)) and coalesce((v_dec->>'via_fluxo_pai')::boolean, false)
                           then 'Não se aplica: feita no fluxo da decisão'
                           else 'Dispensada pela decisão' || coalesce(': ' || v_nota, '') end
         where id = t.id;
        perform _wf_evento(i.id, t.id, 'etapa_dispensada', jsonb_build_object('condicao', t.condicao));
        v_mudou := true; continue;
      end if;
      -- sub-fluxo: abre o filho com os dados do pai
      if t.sub_fluxo is not null then
        select * into v_fm from wf_modelos where codigo = t.sub_fluxo;
        -- PF do filho: recurso com prazo próprio -> sugerido a partir da intimação, a confirmar; senão herda o do pai
        v_pf := case when v_fm.prazo_legal_dias is not null and i.data_ciencia is not null
                     then _wf_pf_sugerido(i.data_ciencia, v_fm.prazo_legal_dias, i.prazo_em_dobro, i.cnj) end;
        v_filho := _wf_criar_instancia(t.sub_fluxo, i.id, t.id, jsonb_build_object(
          'cnj', i.cnj, 'cliente', i.cliente, 'atlas_lawsuit_id', i.atlas_lawsuit_id, 'atlas_client_id', i.atlas_client_id,
          'equipe_id', i.equipe_id, 'advogado_colaborador_id', i.advogado_colaborador_id, 'natureza', i.natureza,
          'providencia', coalesce(v_fm.nome_peca, i.providencia), 'link_intimacao', i.link_intimacao,
          'data_recebimento', i.data_recebimento, 'data_ciencia', i.data_ciencia, 'prazo_em_dobro', i.prazo_em_dobro,
          'pf', coalesce(v_pf, i.pf), 'pf_sugerido', v_pf,
          'pf_confirmado', case when v_pf is not null then (i.pf_confirmado and v_pf = i.pf) else i.pf_confirmado end,
          'dados', i.dados || jsonb_build_object('peca', coalesce((select nome_peca from wf_modelos where id = i.modelo_id), i.dados->>'peca')),
          'decisoes', coalesce(i.dados->'decisoes_filhos'->t.sub_fluxo, '{}') || '{"via_fluxo_pai": true, "interpor": true}'::jsonb));
        update wf_tarefas set status = 'em_subfluxo', filho_instancia_id = v_filho, liberada_em = now() where id = t.id;
        perform _wf_avancar(v_filho);
        v_mudou := true; continue;
      end if;
      -- PF a confirmar: peça e protocolo (etapas que usam o PF) esperam a controladoria
      if not i.pf_confirmado and (t.leva_pf or t.teto_antes_pf is not null) then
        if t.status <> 'aguardando_pf' then
          update wf_tarefas set status = 'aguardando_pf' where id = t.id;
          perform _wf_evento(i.id, t.id, 'aguardando_pf', jsonb_build_object('pf_sugerido', i.pf_sugerido));
        end if;
        continue;
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

-- quem decide cada pergunta: decisão do LÍDER só o líder da equipe do fluxo ou a controladoria
create or replace function public._wf_eh_lider_do_fluxo(p_inst bigint) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from wf_instancias i join lideres_equipes le on le.equipe_id = i.equipe_id
                   join perfis pf on pf.user_id = le.user_id and pf.papel = 'lider'
                  where i.id = _wf_raiz(p_inst) and le.user_id = auth.uid())
$$;

-- ---------------------------------------------------------------- PF
create or replace function public.wf_sugerir_pf(p_modelo text, p_data_intimacao date, p_dobro boolean, p_cnj text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare m wf_modelos; v_pf date;
begin
  if not is_admin() then raise exception 'Somente a controladoria' using errcode = '42501'; end if;
  select * into m from wf_modelos where codigo = p_modelo;
  if m.id is null then raise exception 'Modelo % inexistente', p_modelo; end if;
  if m.prazo_legal_dias is null then return jsonb_build_object('pf', null, 'mensagem', 'Este fluxo não tem prazo legal padrão: informe o PF.'); end if;
  if p_data_intimacao is null then raise exception 'Informe a data da intimação'; end if;
  v_pf := _wf_pf_sugerido(p_data_intimacao, m.prazo_legal_dias, p_dobro, p_cnj);
  return jsonb_build_object('pf', v_pf, 'dias', m.prazo_legal_dias * case when coalesce(p_dobro, false) then 2 else 1 end,
    'tribunal', tribunal_do_cnj(p_cnj), 'inicio_contagem', somar_dias_uteis(p_data_intimacao, 1, tribunal_do_cnj(p_cnj)),
    'd4', calcular_d4(v_pf, tribunal_do_cnj(p_cnj)),
    'aviso', 'Sugestão pela regra geral do CPC (dias úteis, feriados do tribunal). Confira rito, forma de intimação, prazo em dobro e regras do tribunal antes de confirmar.');
end $$;

create or replace function public.wf_confirmar_pf(p_instancia bigint, p_pf date, p_motivo text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare i wf_instancias;
begin
  if not is_admin() then raise exception 'Somente a controladoria confirma o prazo' using errcode = '42501'; end if;
  select * into i from wf_instancias where id = p_instancia for update;
  if i.id is null then raise exception 'Fluxo % inexistente', p_instancia; end if;
  if i.status <> 'ativo' then raise exception 'Fluxo % não está ativo', p_instancia; end if;
  if p_pf is null then raise exception 'Informe o PF'; end if;
  if p_pf < hoje_brasilia() then raise exception 'O PF informado (%) já passou', to_char(p_pf, 'DD/MM/YYYY'); end if;
  if i.pf_confirmado and i.pf is distinct from p_pf then
    raise exception 'O PF deste fluxo já foi confirmado (%); alteração de PF segue a regra de reagendamento com justificativa', to_char(i.pf, 'DD/MM/YYYY');
  end if;
  if i.pf_sugerido is not null and p_pf <> i.pf_sugerido and length(btrim(coalesce(p_motivo, ''))) < 15 then
    raise exception 'PF diferente do sugerido (%): informe o motivo (mínimo de 15 caracteres)', to_char(i.pf_sugerido, 'DD/MM/YYYY');
  end if;
  update wf_instancias set pf = p_pf, pf_confirmado = true where id = i.id;
  perform _wf_evento(i.id, null, 'pf_confirmado', jsonb_build_object('pf', p_pf, 'sugerido', i.pf_sugerido, 'motivo', nullif(btrim(coalesce(p_motivo, '')), '')));
  perform _wf_avancar(i.id);
  return wf_detalhe(_wf_raiz(i.id));
end $$;

-- ---------------------------------------------------------------- triagem: qualquer fluxo de entrada
create or replace function public.wf_iniciar(p_campos jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_id bigint; v_falta text[] := '{}'; v_tem_prazo boolean := coalesce((p_campos->>'tem_prazo')::boolean, true);
        v_dec jsonb := coalesce(p_campos->'decisoes', '{}'); k text; m wf_modelos; d wf_decisoes_modelo; v_sug date;
begin
  if not is_admin() then raise exception 'Somente a controladoria faz a triagem' using errcode = '42501'; end if;
  select * into m from wf_modelos where codigo = coalesce(nullif(p_campos->>'modelo', ''), 'MESTRE') and ativo;
  if m.id is null or m.tipo not in ('mestre', 'especializado') then
    raise exception 'Fluxo de entrada inválido: %', coalesce(p_campos->>'modelo', '(vazio)');
  end if;
  if coalesce(btrim(p_campos->>'cnj'), '') = '' then v_falta := array_append(v_falta, 'número do processo'); end if;
  if coalesce(btrim(p_campos->>'cliente'), '') = '' then v_falta := array_append(v_falta, 'cliente'); end if;
  if coalesce(btrim(p_campos->>'origem_tipo'), '') = '' then v_falta := array_append(v_falta, 'origem da intimação'); end if;
  if coalesce(p_campos->>'data_recebimento', '') = '' then v_falta := array_append(v_falta, 'data de recebimento'); end if;
  if coalesce(p_campos->>'data_ciencia', '') = '' then v_falta := array_append(v_falta, 'data da publicação ou ciência'); end if;
  if coalesce(btrim(p_campos->>'modalidade_intimacao'), '') = '' then v_falta := array_append(v_falta, 'modalidade da intimação'); end if;
  if coalesce(btrim(p_campos->>'natureza'), '') = '' then v_falta := array_append(v_falta, 'natureza da intimação'); end if;
  if coalesce(btrim(p_campos->>'providencia'), '') = '' and m.nome_peca is null and m.codigo <> 'DECISAO' then v_falta := array_append(v_falta, 'providência jurídica'); end if;
  if coalesce(p_campos->>'advogado_colaborador_id', '') = '' then v_falta := array_append(v_falta, 'advogado responsável'); end if;
  if coalesce(p_campos->>'equipe_id', '') = '' then v_falta := array_append(v_falta, 'equipe'); end if;
  if m.codigo = 'DECISAO' and coalesce(btrim(p_campos->'dados'->>'tipo_decisao'), '') = '' then v_falta := array_append(v_falta, 'tipo de decisão'); end if;
  if m.codigo = 'DECISAO' and coalesce(btrim(p_campos->'dados'->>'resultado'), '') = '' then v_falta := array_append(v_falta, 'resultado da decisão'); end if;
  -- Regra 04: com prazo judicial, a triagem não termina sem PF validado
  if v_tem_prazo and coalesce(p_campos->>'pf', '') = '' then v_falta := array_append(v_falta, 'prazo fatal (PF)'); end if;
  if array_length(v_falta, 1) > 0 then raise exception 'Triagem incompleta. Falta: %', array_to_string(v_falta, ', '); end if;
  if v_tem_prazo and (p_campos->>'pf')::date < hoje_brasilia() then raise exception 'O PF informado (%) já passou', to_char((p_campos->>'pf')::date, 'DD/MM/YYYY'); end if;
  if not exists (select 1 from colaboradores where id = (p_campos->>'advogado_colaborador_id')::bigint) then raise exception 'Advogado inexistente'; end if;
  for k in select jsonb_object_keys(v_dec) loop
    select * into d from wf_decisoes_modelo where modelo_id = m.id and chave = k;
    if d.chave is null or d.quem = 'lider' then raise exception 'Decisão inválida: %', k; end if;
    if d.tipo = 'booleana' and jsonb_typeof(v_dec->k) <> 'boolean' then raise exception 'Decisão inválida: %', k; end if;
    if d.tipo = 'multipla' then raise exception 'A escolha "%" é feita pelo advogado depois da análise', d.pergunta; end if;
  end loop;
  -- Regra 05: duplicidade
  if nullif(p_campos->>'origem_id', '') is not null and exists (select 1 from wf_instancias where origem_tipo = p_campos->>'origem_tipo'
       and origem_id = p_campos->>'origem_id' and pai_instancia_id is null and status = 'ativo') then
    raise exception 'Esta intimação já tem um fluxo ativo (#%): confira antes de abrir outro',
      (select id from wf_instancias where origem_tipo = p_campos->>'origem_tipo' and origem_id = p_campos->>'origem_id'
          and pai_instancia_id is null and status = 'ativo');
  end if;
  v_sug := _wf_pf_sugerido(nullif(p_campos->>'data_ciencia', '')::date, m.prazo_legal_dias, (p_campos->>'prazo_em_dobro')::boolean, p_campos->>'cnj');
  v_id := _wf_criar_instancia(m.codigo, null, null, p_campos || jsonb_build_object(
    'pf', case when v_tem_prazo then p_campos->>'pf' end, 'pf_confirmado', true, 'pf_sugerido', v_sug,
    'providencia', coalesce(nullif(btrim(p_campos->>'providencia'), ''), m.nome_peca, 'ANALISAR DECISÃO'),
    'decisoes', v_dec || '{"via_fluxo_pai": false}'::jsonb));
  perform _wf_evento(v_id, null, 'triagem', jsonb_build_object('campos', p_campos, 'pf_sugerido', v_sug,
    'pf_diferente_do_sugerido', v_tem_prazo and v_sug is not null and v_sug <> (p_campos->>'pf')::date));
  perform _wf_avancar(v_id);
  return wf_detalhe(v_id);
end $$;

-- respostas às decisões (sim/não ou escolha múltipla). Só preenche o que está vazio, salvo correção da controladoria.
create or replace function public.wf_decidir(p_instancia bigint, p_respostas jsonb, p_nota text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare i wf_instancias; k text; v_ant jsonb; d wf_decisoes_modelo; x jsonb;
begin
  if not _wf_pode_decidir(p_instancia) then raise exception 'Somente o advogado do fluxo, o líder da equipe ou a controladoria decidem' using errcode = '42501'; end if;
  select * into i from wf_instancias where id = p_instancia for update;
  if i.id is null then raise exception 'Fluxo % inexistente', p_instancia; end if;
  if i.status <> 'ativo' then raise exception 'Fluxo % não está ativo', p_instancia; end if;
  if jsonb_typeof(p_respostas) <> 'object' or p_respostas = '{}'::jsonb then raise exception 'Respostas inválidas'; end if;
  for k in select jsonb_object_keys(p_respostas) loop
    select * into d from wf_decisoes_modelo where modelo_id = i.modelo_id and chave = k;
    if d.chave is null then raise exception 'Decisão desconhecida neste fluxo: %', k; end if;
    if d.quem = 'lider' and not (is_admin() or _wf_eh_lider_do_fluxo(i.id)) then
      raise exception 'Somente o líder da equipe ou a controladoria respondem: %', d.pergunta using errcode = '42501';
    end if;
    if d.tipo = 'booleana' and jsonb_typeof(p_respostas->k) <> 'boolean' then raise exception 'A resposta de % deve ser sim ou não', k; end if;
    if d.tipo = 'multipla' then
      if jsonb_typeof(p_respostas->k) <> 'array' or jsonb_array_length(p_respostas->k) = 0 then
        raise exception 'Escolha pelo menos uma opção em: %', d.pergunta;
      end if;
      for x in select * from jsonb_array_elements(p_respostas->k) loop
        if jsonb_typeof(x) <> 'string' or not exists (select 1 from jsonb_array_elements(d.opcoes) o where o->>'valor' = x #>> '{}') then
          raise exception 'Opção inválida em %: %', d.pergunta, x;
        end if;
      end loop;
    end if;
    v_ant := i.decisoes -> k;
    if v_ant is not null and v_ant <> p_respostas->k then
      if not is_admin() then raise exception 'A decisão "%" já foi registrada; só a controladoria corrige', k; end if;
      if exists (select 1 from wf_tarefas wt join wf_etapas_modelo em on em.id = wt.etapa_modelo_id
                  where wt.instancia_id = i.id and k = any(_wf_cond_chaves(em.condicao))
                    and wt.status not in ('aguardando','aguardando_decisao','aguardando_pf','dispensada')) then
        raise exception 'A decisão "%" já gerou etapas: cancele ou dispense as etapas antes de mudar', k;
      end if;
      update wf_tarefas wt set status = 'aguardando', nota = null, concluida_em = null from wf_etapas_modelo em
       where em.id = wt.etapa_modelo_id and wt.instancia_id = i.id and k = any(_wf_cond_chaves(em.condicao)) and wt.status = 'dispensada';
    end if;
  end loop;
  update wf_instancias set decisoes = decisoes || p_respostas where id = i.id;
  perform _wf_evento(i.id, null, 'decisao', jsonb_build_object('respostas', p_respostas, 'nota', p_nota));
  perform _wf_avancar(i.id);
  return wf_detalhe(_wf_raiz(i.id));
end $$;

-- ---------------------------------------------------------------- leitura (painel)
create or replace function public.wf_detalhe(p_id bigint) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare i wf_instancias; m wf_modelos;
begin
  -- permissão antes da existência: quem não participa não descobre quais fluxos existem
  if not _wf_pode_ver(p_id) then
    raise exception 'Somente quem participa do fluxo, o líder da equipe, a controladoria e a diretoria veem este fluxo' using errcode = '42501';
  end if;
  select * into i from wf_instancias where id = p_id;
  if i.id is null then raise exception 'Fluxo % inexistente', p_id; end if;
  select * into m from wf_modelos where id = i.modelo_id;
  return to_jsonb(i) || jsonb_build_object(
    'modelo', m.codigo, 'modelo_nome', m.nome, 'nome_peca', m.nome_peca, 'prazo_legal_modelo', m.prazo_legal_dias,
    'advogado', (select nome_advbox from colaboradores where id = i.advogado_colaborador_id),
    'equipe', (select nome from equipes where id = i.equipe_id),
    'd4', case when i.pf is not null then calcular_d4(i.pf, tribunal_do_cnj(i.cnj)) end,
    'pode_decidir', _wf_pode_decidir(i.id), 'admin', is_admin(), 'lider_do_fluxo', _wf_eh_lider_do_fluxo(i.id),
    'perguntas', coalesce((select jsonb_agg(jsonb_build_object('chave', d.chave, 'pergunta', d.pergunta, 'quem', d.quem, 'apos', d.apos,
        'tipo', d.tipo, 'opcoes', d.opcoes, 'resposta', i.decisoes -> d.chave,
        -- pendente: sem resposta e (uma etapa espera por ela, ou a etapa a que se refere já foi liberada)
        'pendente', (i.decisoes -> d.chave) is null
          -- ainda faz diferença: alguma etapa que depende dela não foi descartada por outra resposta
          and exists (select 1 from wf_tarefas wt join wf_etapas_modelo em on em.id = wt.etapa_modelo_id
                       where wt.instancia_id = i.id and d.chave = any(_wf_cond_chaves(em.condicao))
                         and wt.status not in ('dispensada','cancelada') and _wf_cond_avaliar(em.condicao, i.decisoes) <> 'nao')
          and (
            exists (select 1 from wf_tarefas wt join wf_etapas_modelo em on em.id = wt.etapa_modelo_id
                     where wt.instancia_id = i.id and d.chave = any(_wf_cond_chaves(em.condicao)) and wt.status = 'aguardando_decisao')
         or exists (select 1 from wf_tarefas wt join wf_etapas_modelo em on em.id = wt.etapa_modelo_id
                     where wt.instancia_id = i.id and em.codigo = d.apos and wt.status in ('liberada','criando','criada','verificar'))))
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
        where e.instancia_id in (select id from wf_instancias where raiz_id = i.id)), '[]') end);
end $$;

create or replace function public._wf_raiz(p_inst bigint) returns bigint
language sql stable security definer set search_path = public as $$
  select coalesce(raiz_id, pai_instancia_id, id) from wf_instancias where id = p_inst
$$;

-- quem vê / quem decide: pelo fluxo raiz (fluxos filhos e netos herdam)
create or replace function public._wf_pode_ver(p_inst bigint) returns boolean
language sql stable security definer set search_path = public as $$
  select public.pode_ler_tudo() or exists (
    select 1 from wf_instancias i
     where i.id = _wf_raiz(p_inst)
       and (i.advogado_colaborador_id = any(public.meus_colaboradores())
            or (select colaborador_id from equipes_assistentes where equipe_id = i.equipe_id) = any(public.meus_colaboradores())
            or exists (select 1 from lideres_equipes le where le.user_id = auth.uid() and le.equipe_id = i.equipe_id)))
$$;
create or replace function public._wf_pode_decidir(p_inst bigint) returns boolean
language sql stable security definer set search_path = public as $$
  select public.is_admin() or exists (
    select 1 from wf_instancias i
     where i.id = _wf_raiz(p_inst)
       and ((i.advogado_colaborador_id is not null and i.advogado_colaborador_id = (select colaborador_id from perfis where user_id = auth.uid()))
            or exists (select 1 from lideres_equipes le join perfis pf on pf.user_id = le.user_id and pf.papel = 'lider'
                        where le.user_id = auth.uid() and le.equipe_id = i.equipe_id)))
$$;

-- lista dos fluxos raiz visíveis para quem está logado (inclui netos: recurso aberto pela decisão abre comunicação/dispensa)
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
            where xi.raiz_id = i.id and x.status = 'aguardando_decisao')),
        'pf_a_confirmar', count(*) filter (where i.status = 'ativo' and exists (select 1 from wf_tarefas x join wf_instancias xi on xi.id = x.instancia_id
            where xi.raiz_id = i.id and x.status = 'aguardando_pf')),
        'com_problema', count(*) filter (where i.status = 'ativo' and exists (select 1 from wf_tarefas x join wf_instancias xi on xi.id = x.instancia_id
            where xi.raiz_id = i.id and x.status in ('sem_responsavel','verificar'))),
        'para_criar', (select count(*) from wf_tarefas x join wf_instancias xi on xi.id = x.instancia_id and xi.status = 'ativo' where x.status = 'liberada'))
      from wf_instancias i where i.pai_instancia_id is null
       and (v_tudo or i.advogado_colaborador_id = any(v_meus) or (select colaborador_id from equipes_assistentes where equipe_id = i.equipe_id) = any(v_meus)
            or exists (select 1 from lideres_equipes le where le.user_id = auth.uid() and le.equipe_id = i.equipe_id))),
    'itens', coalesce((select jsonb_agg(x order by x->>'criado_em' desc) from (
      select jsonb_build_object('id', i.id, 'status', i.status, 'cnj', i.cnj, 'cliente', i.cliente, 'providencia', i.providencia,
               'natureza', i.natureza, 'pf', i.pf, 'equipe', e.nome, 'advogado', c.nome_advbox, 'criado_em', i.criado_em,
               'concluido_em', i.concluido_em, 'modelo_nome', (select nome from wf_modelos where id = i.modelo_id),
               'etapas', (select jsonb_agg(jsonb_build_object('titulo', x.titulo, 'status', x.status, 'prazo', x.prazo,
                              'responsavel', cc.nome_advbox, 'fluxo', xi.id) order by xi.id, em.ordem)
                            from wf_tarefas x join wf_instancias xi on xi.id = x.instancia_id join wf_etapas_modelo em on em.id = x.etapa_modelo_id
                            left join colaboradores cc on cc.id = x.colaborador_id
                           where xi.raiz_id = i.id and x.status not in ('concluida','dispensada','cancelada','em_subfluxo'))) x
        from wf_instancias i left join equipes e on e.id = i.equipe_id left join colaboradores c on c.id = i.advogado_colaborador_id
       where i.pai_instancia_id is null
         and (p_status is null or p_status = '' or i.status = p_status)
         and (v_tudo or i.advogado_colaborador_id = any(v_meus) or (select colaborador_id from equipes_assistentes where equipe_id = i.equipe_id) = any(v_meus)
              or exists (select 1 from lideres_equipes le where le.user_id = auth.uid() and le.equipe_id = i.equipe_id))
         and (p_busca is null or p_busca = '' or i.cnj ilike '%' || p_busca || '%' or i.cliente ilike '%' || p_busca || '%'
              or i.providencia ilike '%' || p_busca || '%')
       order by i.criado_em desc limit greatest(least(coalesce(p_limite, 200), 500), 1)) s), '[]'));
end $$;

create or replace function public.wf_configuracao() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not pode_ler_tudo() then raise exception 'Somente a controladoria e a diretoria' using errcode = '42501'; end if;
  return jsonb_build_object(
    'equipes', coalesce((select jsonb_agg(jsonb_build_object('equipe_id', e.id, 'equipe', e.nome, 'colaborador_id', ea.colaborador_id,
        'assistente', c.nome_advbox, 'atlas_user_id', c.atlas_user_id,
        'atlas_nome', (select p.nome from atlas_produtividade p where p.user_id = c.atlas_user_id order by p.coleta desc limit 1),
        'lider', (select string_agg(cl.nome_advbox, ', ') from lideres_equipes le join perfis pf on pf.user_id = le.user_id and pf.papel = 'lider'
                   join colaboradores cl on cl.id = pf.colaborador_id where le.equipe_id = e.id)) order by e.nome)
        from equipes e left join equipes_assistentes ea on ea.equipe_id = e.id left join colaboradores c on c.id = ea.colaborador_id), '[]'),
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
        from wf_decisoes_modelo d join wf_modelos m on m.id = d.modelo_id where m.codigo = 'MESTRE'), '[]'),
    -- fluxos que a triagem pode abrir, com o prazo legal e as perguntas que podem ser respondidas já na triagem
    'modelos_entrada', coalesce((select jsonb_agg(jsonb_build_object('codigo', m.codigo, 'nome', m.nome, 'tipo', m.tipo,
        'prazo_legal_dias', m.prazo_legal_dias, 'nome_peca', m.nome_peca, 'descricao', m.descricao,
        'perguntas', coalesce((select jsonb_agg(jsonb_build_object('chave', d.chave, 'pergunta', d.pergunta) order by d.chave)
                                 from wf_decisoes_modelo d where d.modelo_id = m.id and d.tipo = 'booleana' and d.quem <> 'lider'
                                   and d.chave not in ('interpor', 'comunicar_interposicao', 'aguarda_resposta')), '[]'))
        order by m.ordem, m.nome) from wf_modelos m where m.ativo and m.tipo in ('mestre','especializado')), '[]'));
end $$;

-- ---------------------------------------------------------------- modelos recursais
insert into public.wf_modelos (codigo, nome, tipo, descricao, prazo_legal_dias, nome_peca, ordem) values
 ('DECISAO', 'Decisão judicial – comunicação ao cliente e análise recursal', 'mestre',
  'Regra geral: toda decisão (sentença, interlocutória, acórdão, monocrática) é comunicada ao cliente pela assistente da equipe, com orientação validada pelo advogado, e passa por análise de Embargos de Declaração e do recurso cabível. A ausência de resposta do cliente não suspende o prazo.',
  5, null, 20),
 ('COMUNICACAO_DECISAO', 'Comunicação ao cliente – decisão judicial', 'transversal',
  'Rotina transversal: advogado valida as informações jurídicas; assistente da equipe comunica, registra data, canal e conteúdo e acompanha o retorno.', null, null, 900),
 ('DISPENSA', 'Análise recursal – dispensa de interposição', 'transversal',
  'A não elaboração da peça não é dispensa: a não interposição precisa de justificativa do advogado e aprovação do líder da equipe.', null, null, 910),
 ('EMBARGOS_DECLARACAO', 'Embargos de Declaração', 'especializado', 'Arts. 1.022 a 1.026 do CPC. Interrompe o prazo dos demais recursos (art. 1.026).', 5, 'EMBARGOS DE DECLARAÇÃO', 30),
 ('APELACAO', 'Apelação', 'especializado', 'Arts. 1.003, § 5º, e 1.009 a 1.014 do CPC.', 15, 'APELAÇÃO', 31),
 ('AGRAVO_INSTRUMENTO', 'Agravo de Instrumento', 'especializado', 'Arts. 1.003, § 5º, e 1.015 a 1.020 do CPC.', 15, 'AGRAVO DE INSTRUMENTO', 32),
 ('AGRAVO_INTERNO', 'Agravo Interno', 'especializado', 'Art. 1.021 do CPC.', 15, 'AGRAVO INTERNO', 33),
 ('RECURSO_ESPECIAL', 'Recurso Especial', 'especializado', 'Arts. 1.003, § 5º, e 1.029 a 1.041 do CPC.', 15, 'RECURSO ESPECIAL', 34),
 ('RECURSO_EXTRAORDINARIO', 'Recurso Extraordinário', 'especializado', 'Arts. 1.003, § 5º, 1.029 a 1.041 e 1.035 do CPC.', 15, 'RECURSO EXTRAORDINÁRIO', 35),
 ('AGRAVO_RESP_RE', 'Agravo em Recurso Especial ou Extraordinário', 'especializado', 'Art. 1.042 do CPC (verificar art. 1.030, § 2º).', 15, 'AGRAVO EM RESP/RE (ART. 1.042)', 36),
 ('RECURSO_ORDINARIO', 'Recurso Ordinário', 'especializado', 'Art. 1.027 do CPC: só nas hipóteses legais.', 15, 'RECURSO ORDINÁRIO', 37),
 ('EMBARGOS_DIVERGENCIA', 'Embargos de Divergência', 'especializado', 'Arts. 1.043 e 1.044 do CPC e regimentos: só em tribunal superior.', 15, 'EMBARGOS DE DIVERGÊNCIA', 38),
 ('CONTRARRAZOES', 'Contrarrazões e contraminutas recursais', 'especializado',
  'Arts. 1.010, § 1º; 1.019, II; 1.021, § 2º; 1.023, § 2º; 1.030 e 1.042, § 3º, do CPC. Confirmar o prazo da modalidade.', 15, 'CONTRARRAZÕES / CONTRAMINUTA', 39),
 ('RECURSO_ADESIVO', 'Recurso Adesivo', 'especializado', 'Art. 997, §§ 1º e 2º, do CPC. Prazo das contrarrazões; subordinado ao recurso principal.', 15, 'RECURSO ADESIVO', 40)
on conflict (codigo) do nothing;

do $$
declare v_dec bigint; v_com bigint; v_dis bigint; r record; m bigint;
  opcoes jsonb := '[{"valor":"APELACAO","rotulo":"Apelação"},{"valor":"AGRAVO_INSTRUMENTO","rotulo":"Agravo de Instrumento"},
    {"valor":"AGRAVO_INTERNO","rotulo":"Agravo Interno"},{"valor":"RECURSO_ESPECIAL","rotulo":"Recurso Especial"},
    {"valor":"RECURSO_EXTRAORDINARIO","rotulo":"Recurso Extraordinário"},{"valor":"AGRAVO_RESP_RE","rotulo":"Agravo em REsp/RE (art. 1.042)"},
    {"valor":"RECURSO_ORDINARIO","rotulo":"Recurso Ordinário"},{"valor":"EMBARGOS_DIVERGENCIA","rotulo":"Embargos de Divergência"}]';
  o jsonb; n int := 0;
begin
  if exists (select 1 from wf_etapas_modelo e join wf_modelos w on w.id = e.modelo_id where w.codigo = 'DECISAO') then return; end if;
  perform set_config('controladoria.motivo', 'Modelos dos workflows recursais (0063)', true);
  select id into v_dec from wf_modelos where codigo = 'DECISAO';
  select id into v_com from wf_modelos where codigo = 'COMUNICACAO_DECISAO';
  select id into v_dis from wf_modelos where codigo = 'DISPENSA';

  -- ----- regra geral: decisão judicial
  insert into wf_etapas_modelo (modelo_id, codigo, ordem, titulo, papel, sub_fluxo, depende_de, condicao, prazo_dias, teto_antes_pf, leva_pf, checklist, orientacao, exige_evidencia) values
  (v_dec, 'analise', 10, 'ANALISAR DECISÃO, EMBARGOS E RECURSO CABÍVEL – {cnj}', 'advogado', null, '{}', null, 1, 2, false,
   array['Analisar o conteúdo, os efeitos e os capítulos da decisão',
         'Avaliar omissão, contradição, obscuridade ou erro material (Embargos de Declaração, art. 1.022)',
         'Definir os recursos cabíveis e a estratégia processual',
         'Registrar no painel da controladoria (Workflows): Embargos? recorrer? qual recurso?'],
   'A análise de Embargos de Declaração vale para toda decisão. Não recorrer exige justificativa e aprovação do líder (dispensa).', null),
  (v_dec, 'comunicacao', 20, 'Comunicação da decisão ao cliente', null, 'COMUNICACAO_DECISAO', '{}', null, 0, null, false, '{}', null, null),
  (v_dec, 'embargos', 30, 'Embargos de Declaração', null, 'EMBARGOS_DECLARACAO', array['analise'], 'embargos', 0, null, false, '{}', null, null),
  (v_dec, 'dispensa', 90, 'Dispensa de interposição', null, 'DISPENSA', array['analise'], '!embargos&!recorrer', 0, null, false, '{}', null, null);
  for o in select * from jsonb_array_elements(opcoes) loop
    n := n + 1;
    insert into wf_etapas_modelo (modelo_id, codigo, ordem, titulo, papel, sub_fluxo, depende_de, condicao, prazo_dias, teto_antes_pf, leva_pf)
    values (v_dec, 'rec_' || lower(o->>'valor'), 40 + n, o->>'rotulo', null, o->>'valor', array['analise'],
            'recorrer&recurso∋' || (o->>'valor'), 0, null, false);
  end loop;
  insert into wf_decisoes_modelo (modelo_id, chave, pergunta, quem, apos, tipo, opcoes) values
  (v_dec, 'embargos', 'Opor Embargos de Declaração?', 'advogado', 'analise', 'booleana', null),
  (v_dec, 'recorrer', 'Interpor outro recurso agora?', 'advogado', 'analise', 'booleana', null),
  (v_dec, 'recurso', 'Quais recursos?', 'advogado', 'analise', 'multipla', opcoes);

  -- ----- comunicação de decisão (assistente da equipe; advogado valida antes)
  insert into wf_etapas_modelo (modelo_id, codigo, ordem, titulo, papel, sub_fluxo, depende_de, condicao, prazo_dias, teto_antes_pf, leva_pf, checklist, orientacao, exige_evidencia) values
  (v_com, 'validar', 10, 'VALIDAR ORIENTAÇÃO PARA COMUNICAÇÃO AO CLIENTE – {peca} – {cnj}', 'advogado', null, '{}', null, 1, null, false,
   array['Validar as informações jurídicas que serão transmitidas (resultado, efeitos, próximos passos)',
         'Indicar se há documento, informação ou pagamento a pedir ao cliente'],
   'Decisão desfavorável ou parcialmente favorável com conteúdo técnico ou estratégico: a assistente só envia depois desta validação.', null),
  (v_com, 'comunicar', 20, 'COMUNICAR AO CLIENTE – {peca} – {cnj}', 'assistente', null, array['validar'], null, 1, null, false,
   array['Elaborar e encaminhar a comunicação conforme a orientação validada','Registrar data, canal e conteúdo',
         'Acompanhar o retorno do cliente','Registrar dúvidas, solicitações e documentos recebidos'],
   'O envio não significa que a providência do cliente foi cumprida. A falta de resposta não suspende o prazo judicial.', 'Registro do envio (data, canal e conteúdo)'),
  (v_com, 'retorno', 30, 'ORIENTAR SOBRE RETORNO DO CLIENTE – {peca} – {cnj}', 'advogado', null, array['comunicar'], 'aguarda_resposta', 1, null, false,
   array['Responder ou orientar sobre questões que demandem análise jurídica'], null, null);
  insert into wf_decisoes_modelo (modelo_id, chave, pergunta, quem, apos) values
  (v_com, 'aguarda_resposta', 'O cliente respondeu com dúvida ou pedido que exige análise jurídica?', 'advogado', 'comunicar');

  -- ----- dispensa de interposição (líder aprova)
  insert into wf_etapas_modelo (modelo_id, codigo, ordem, titulo, papel, sub_fluxo, depende_de, condicao, prazo_dias, teto_antes_pf, leva_pf, checklist, orientacao, exige_evidencia) values
  (v_dis, 'justificar', 10, 'REGISTRAR JUSTIFICATIVA DE NÃO RECORRER – {peca} – {cnj}', 'advogado', null, '{}', null, 1, null, false,
   array['Analisar a viabilidade e o interesse recursal','Registrar a justificativa jurídica da não interposição ao concluir'],
   'A ausência de elaboração da peça não é dispensa: a justificativa precisa ser expressa.', 'Justificativa jurídica'),
  (v_dis, 'aprovar', 20, 'APROVAR DISPENSA DE RECURSO – {peca} – {cnj}', 'lider', null, array['justificar'], null, 1, null, false,
   array['Avaliar a justificativa do advogado','Registrar a decisão no painel da controladoria (Workflows)'],
   'Só o líder da equipe (ou a controladoria) aprova.', null),
  (v_dis, 'comunicar', 30, 'COMUNICAR AO CLIENTE A NÃO INTERPOSIÇÃO – {peca} – {cnj}', 'assistente', null, array['aprovar'], 'dispensa_aprovada', 1, null, false,
   array['Comunicar a decisão e seus efeitos conforme a orientação jurídica','Registrar o envio e eventual manifestação do cliente'],
   null, 'Registro do envio'),
  (v_dis, 'registrar', 40, 'REGISTRAR DISPENSA E MONITORAR TRÂNSITO EM JULGADO – {cnj}', 'controladoria', null, array['comunicar'], 'dispensa_aprovada', 1, null, false,
   array['Registrar a aprovação e encerrar a tarefa recursal','Monitorar o trânsito em julgado ou a próxima movimentação'], null, null),
  (v_dis, 'reavaliar', 50, 'DISPENSA NÃO APROVADA: REAVALIAR RECURSO – {peca} – {cnj}', 'advogado', null, array['aprovar'], '!dispensa_aprovada', 1, null, false,
   array['Reavaliar o recurso cabível com a liderança','Se for recorrer, avisar a controladoria para abrir o fluxo do recurso'], null, null);
  insert into wf_decisoes_modelo (modelo_id, chave, pergunta, quem, apos) values
  (v_dis, 'dispensa_aprovada', 'A dispensa de recurso está aprovada?', 'lider', 'aprovar');

  -- ----- recursos (mesmo esqueleto: análise e comunicação só na entrada direta; peça; protocolo; fiscalização; registro)
  for r in select * from (values
    ('EMBARGOS_DECLARACAO', 2, 1, 0, false,
      array['Apontar a omissão, contradição, obscuridade ou erro material (art. 1.022)','Avaliar o prequestionamento, se pertinente','Elaborar e validar tecnicamente a peça'],
      'Prazo de 5 dias úteis. Opostos pela parte contrária com possível efeito modificativo: avaliar manifestação (art. 1.023, § 2º). O julgamento dos Embargos gera nova análise recursal (nova triagem da decisão).'),
    ('APELACAO', 8, 3, 1, true,
      array['Analisar os capítulos favoráveis e desfavoráveis','Elaborar a Apelação','Revisar e validar tecnicamente a peça'],
      'Sentença parcialmente favorável: analisar individualmente os capítulos desfavoráveis. Se a parte contrária recorrer, avaliar Recurso Adesivo.'),
    ('AGRAVO_INSTRUMENTO', 8, 3, 1, true,
      array['Validar o cabimento (art. 1.015 e jurisprudência)','Avaliar efeito suspensivo ou tutela recursal','Elaborar o Agravo e organizar os documentos obrigatórios','Revisar e validar tecnicamente a peça'],
      'Sem cabimento imediato: avaliar impugnação em preliminar de Apelação ou contrarrazões (art. 1.009, § 1º).'),
    ('AGRAVO_INTERNO', 8, 3, 1, false,
      array['Impugnar especificamente os fundamentos da decisão agravada (art. 1.021, § 1º)','Elaborar a peça','Revisar e validar tecnicamente o recurso'],
      null),
    ('RECURSO_ESPECIAL', 8, 3, 1, true,
      array['Verificar prequestionamento e requisitos de admissibilidade','Elaborar o Recurso Especial','Revisar e validar tecnicamente a peça'],
      'Inadmitido: abrir fluxo do recurso cabível (art. 1.030, § 2º, e art. 1.042).'),
    ('RECURSO_EXTRAORDINARIO', 8, 3, 1, true,
      array['Analisar a questão constitucional e o prequestionamento','Demonstrar expressamente a repercussão geral (art. 1.035)','Elaborar o Recurso Extraordinário','Revisar e validar tecnicamente a peça'],
      null),
    ('AGRAVO_RESP_RE', 8, 3, 1, false,
      array['Analisar os fundamentos da inadmissibilidade','Verificar se cabe o Agravo do art. 1.042 ou Agravo Interno (art. 1.030, § 2º)','Elaborar a peça impugnando os fundamentos','Revisar e validar tecnicamente o recurso'],
      'Inadmissão por repercussão geral ou repetitivo: verificar cabimento de Agravo Interno (art. 1.030, § 2º).'),
    ('RECURSO_ORDINARIO', 8, 3, 1, true,
      array['Confirmar a hipótese legal de cabimento (art. 1.027)','Elaborar e validar tecnicamente o Recurso Ordinário'],
      'Só nas hipóteses legais: não é recurso disponível em todo processo cível.'),
    ('EMBARGOS_DIVERGENCIA', 8, 3, 1, false,
      array['Confirmar o cabimento (arts. 1.043 e 1.044 e regimento)','Identificar a divergência e os acórdãos paradigmas','Elaborar e validar tecnicamente a peça'],
      'Só em tribunal superior, nas hipóteses legais.'),
    ('CONTRARRAZOES', 8, 3, 1, false,
      array['Analisar os fundamentos do recurso e os pontos a impugnar','Elaborar as contrarrazões ou contraminuta','Revisar e validar tecnicamente a peça'],
      'Confirmar o prazo da modalidade (contrarrazões, contraminuta, resposta a agravo interno ou a embargos).'),
    ('RECURSO_ADESIVO', 8, 3, 1, false,
      array['Confirmar sucumbência recíproca e interesse recursal','Confirmar o cabimento (art. 997, § 2º)','Elaborar o Recurso Adesivo','Validar tecnicamente a peça'],
      'Subordinado ao recurso independente: avaliar os efeitos de desistência ou inadmissão do recurso principal.')
  ) x(codigo, peca_dias, peca_teto, prot_teto, preparo, checklist, orientacao) loop
    select id into m from wf_modelos where codigo = r.codigo;
    insert into wf_etapas_modelo (modelo_id, codigo, ordem, titulo, papel, sub_fluxo, depende_de, condicao, prazo_dias, teto_antes_pf, leva_pf, checklist, orientacao, exige_evidencia) values
    (m, 'analise', 10, 'ANALISAR {peca} – CABIMENTO E ESTRATÉGIA – {cnj}', 'advogado', null, '{}', '!via_fluxo_pai', 1, r.peca_teto + 2, false,
     array['Analisar a decisão ou o recurso e os fundamentos','Avaliar vícios para Embargos de Declaração','Avaliar o cabimento e a estratégia',
           'Registrar no painel da controladoria se vai interpor/apresentar'], r.orientacao, null),
    (m, 'comunicacao', 20, 'Comunicação ao cliente', null, 'COMUNICACAO_DECISAO', '{}', '!via_fluxo_pai', 0, null, false, '{}', null, null),
    (m, 'peca', 30, 'ELABORAR E VALIDAR {peca} – {cnj}', 'advogado', null, array['analise'], 'interpor', r.peca_dias, r.peca_teto, true,
     r.checklist || array['Anexar a peça validada e liberar para protocolo'], r.orientacao, 'Peça validada anexada'),
    (m, 'protocolo', 40, 'CONFERIR REQUISITOS E PROTOCOLAR {peca} – {cnj}', 'controladoria', null, array['peca'], 'interpor', 1, r.prot_teto, true,
     array['Receber a peça validada pelo advogado','Conferir processo, documentos' || case when r.preparo then ', preparo' else '' end || ' e requisitos operacionais',
           'Realizar o protocolo','Anexar o comprovante'],
     'Protocolo exclusivo da controladoria. Sem validação técnica do advogado, não protocolar.', 'Comprovante de protocolo'),
    (m, 'fiscalizar', 50, 'FISCALIZAR PROTOCOLO – {peca} – {cnj}', 'advogado', null, array['protocolo'], 'interpor', 1, null, false,
     array['Conferir o protocolo e a regularidade do ato (peça, documentos, preparo, destinatário)'], 'Fiscalização obrigatória do advogado autor da peça.', null),
    (m, 'registro', 60, 'CONFERIR RECIBO, REGISTRAR PROTOCOLO E MONITORAR – {peca} – {cnj}', 'controladoria', null, array['fiscalizar'], 'interpor', 1, null, false,
     array['Conferir o recibo','Registrar a data do protocolo e atualizar o processo no Atlas','Monitorar o processamento e o julgamento'], null, 'Recibo do protocolo'),
    (m, 'comunicar_interposicao', 70, 'COMUNICAR AO CLIENTE A INTERPOSIÇÃO – {peca} – {cnj}', 'assistente', null, array['fiscalizar'], 'interpor&comunicar_interposicao', 1, null, false,
     array['Comunicar a interposição e os próximos passos, conforme orientação jurídica','Registrar o envio'], null, 'Registro do envio'),
    (m, 'dispensa', 80, 'Dispensa de interposição', null, 'DISPENSA', array['analise'], '!interpor', 0, null, false, '{}', null, null);
    insert into wf_decisoes_modelo (modelo_id, chave, pergunta, quem, apos) values
    (m, 'interpor', 'Vai interpor/apresentar: ' || (select nome from wf_modelos where id = m) || '?', 'advogado', 'analise'),
    (m, 'comunicar_interposicao', 'Comunicar ao cliente a interposição?', 'advogado', 'fiscalizar');
  end loop;

  -- contrarrazões: avaliar Recurso Adesivo (fluxo filho com a peça própria)
  select id into m from wf_modelos where codigo = 'CONTRARRAZOES';
  insert into wf_etapas_modelo (modelo_id, codigo, ordem, titulo, papel, sub_fluxo, depende_de, condicao, prazo_dias, teto_antes_pf, leva_pf)
  values (m, 'adesivo', 35, 'Recurso Adesivo', null, 'RECURSO_ADESIVO', array['analise'], 'interpor&adesivo', 0, null, false);
  insert into wf_decisoes_modelo (modelo_id, chave, pergunta, quem, apos) values
  (m, 'adesivo', 'Interpor Recurso Adesivo (sucumbência recíproca, art. 997)?', 'advogado', 'analise');
end $$;

-- ---------------------------------------------------------------- permissões
revoke execute on function public._wf_pode_ver(bigint), public._wf_pode_decidir(bigint), public._wf_cond_avaliar(text, jsonb), public._wf_cond_chaves(text), public._wf_pf_sugerido(date, int, boolean, text),
  public._wf_eh_lider_do_fluxo(bigint) from public, anon, authenticated;
revoke execute on function public._wf_responsavel(bigint, text), public._wf_texto(text, public.wf_instancias),
  public._wf_criar_instancia(text, bigint, bigint, jsonb), public._wf_avancar(bigint), public._wf_raiz(bigint) from public, anon, authenticated;
revoke execute on function public.wf_sugerir_pf(text, date, boolean, text), public.wf_confirmar_pf(bigint, date, text) from public, anon;
grant execute on function public.wf_sugerir_pf(text, date, boolean, text), public.wf_confirmar_pf(bigint, date, text) to authenticated;
