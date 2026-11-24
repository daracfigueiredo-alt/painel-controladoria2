-- =====================================================================
-- 0056 — Relatórios gerenciais de cada menu, com gráficos de pizza (pedido da controladoria, 16/11/2026)
-- Uma função só: relatorio_gerencial(área, início, fim) devolve os indicadores e as distribuições
-- (fatias) do menu escolhido. O painel desenha as pizzas e permite imprimir/salvar em PDF.
-- Acesso: controladoria e diretoria (relatório gerencial).
-- "Situação atual" = retrato de agora; "no período" = filtrado pelas datas escolhidas.
-- =====================================================================

-- distribuição (interna): p_sql devolve (rótulo, quantidade); só textos fixos desta migração + datas por format %L
create or replace function public._rg_pizza(p_titulo text, p_base text, p_sql text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r jsonb;
begin
  execute 'select coalesce(jsonb_agg(jsonb_build_object(''rotulo'', coalesce(x.r::text, ''(não informado)''), ''valor'', x.n) order by x.n desc, x.r), ''[]'')
             from (' || p_sql || ') x(r, n) where x.n > 0' into r;
  return jsonb_build_object('titulo', p_titulo, 'base', p_base, 'itens', r,
                            'total', (select coalesce(sum((i->>'valor')::numeric), 0) from jsonb_array_elements(r) i));
end $$;

create or replace function public._rg_num(p_sql text) returns bigint
language plpgsql stable security definer set search_path = public as $$
declare n bigint;
begin execute p_sql into n; return coalesce(n, 0); end $$;

revoke execute on function public._rg_pizza(text, text, text), public._rg_num(text) from public, anon, authenticated;

create or replace function public.relatorio_gerencial(p_area text, p_inicio date default null, p_fim date default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  ini date := coalesce(p_inicio, hoje_brasilia() - 30);
  fim date := coalesce(p_fim, hoje_brasilia());
  a text := ini::text; b text := fim::text;   -- datas (vão por format %L)
  pz jsonb := '[]'; kp jsonb := '[]';
  P constant text := 'no período'; S constant text := 'situação atual';
  t_resp constant text := 'coalesce(responsavel, ''(sem responsável)'')';
begin
  if not pode_ler_tudo() then raise exception 'Somente a controladoria e a diretoria' using errcode = '42501'; end if;
  if fim < ini then raise exception 'O fim do período é anterior ao início'; end if;
  if fim - ini > 400 then raise exception 'Período máximo de 400 dias'; end if;

  case p_area
  when 'diretoria', 'visao-geral' then
    kp := jsonb_build_array(
      jsonb_build_object('rotulo', 'Tarefas abertas', 'valor', _rg_num('select count(*) from v_tarefas_atuais where situacao <> ''concluida''')),
      jsonb_build_object('rotulo', 'Concluídas no período', 'valor', _rg_num(format('select count(*) from v_tarefas_atuais where data_conclusao between %L and %L', a, b))),
      jsonb_build_object('rotulo', 'Prazos em risco (alta ou crítica)', 'valor', _rg_num('select count(*) from v_prazos_risco where gravidade <= 2')),
      jsonb_build_object('rotulo', 'Inconsistências abertas', 'valor', _rg_num('select count(*) from inconsistencias where situacao = ''aberta''')),
      jsonb_build_object('rotulo', 'Audiências nos próximos 7 dias', 'valor', _rg_num('select count(*) from audiencias where situacao = ''agendada'' and data between hoje_brasilia() and hoje_brasilia() + 7')));
    pz := jsonb_build_array(
      _rg_pizza('Tarefas por situação', S, 'select situacao, count(*) from v_tarefas_atuais group by 1'),
      _rg_pizza('Tarefas abertas por responsável', S, 'select ' || t_resp || ', count(*) from v_tarefas_atuais where situacao <> ''concluida'' group by 1'),
      _rg_pizza('Prazos em risco por grupo', S, 'select grupo_risco, count(*) from v_prazos_risco group by 1'),
      _rg_pizza('Inconsistências abertas por tipo', S, 'select tipo, count(*) from inconsistencias where situacao = ''aberta'' group by 1'));
  when 'colaboradores' then
    kp := jsonb_build_array(
      jsonb_build_object('rotulo', 'Colaboradores com tarefas abertas', 'valor', _rg_num('select count(distinct responsavel_id) from v_tarefas_atuais where situacao <> ''concluida''')),
      jsonb_build_object('rotulo', 'Concluídas no período', 'valor', _rg_num(format('select count(*) from v_tarefas_atuais where data_conclusao between %L and %L', a, b))));
    pz := jsonb_build_array(
      _rg_pizza('Tarefas abertas por colaborador', S, 'select ' || t_resp || ', count(*) from v_tarefas_atuais where situacao <> ''concluida'' group by 1'),
      _rg_pizza('Concluídas por colaborador', P, format('select ' || t_resp || ', count(*) from v_tarefas_atuais where data_conclusao between %L and %L group by 1', a, b)),
      _rg_pizza('Prazos em risco alto ou crítico por colaborador', S, 'select ' || t_resp || ', count(*) from v_prazos_risco where gravidade <= 2 group by 1'));
  when 'prazos' then
    kp := jsonb_build_array(
      jsonb_build_object('rotulo', 'Prazos em risco', 'valor', _rg_num('select count(*) from v_prazos_risco')),
      jsonb_build_object('rotulo', 'Críticos', 'valor', _rg_num('select count(*) from v_prazos_risco where gravidade = 1')));
    pz := jsonb_build_array(
      _rg_pizza('Por gravidade', S, 'select case gravidade when 1 then ''Crítica'' when 2 then ''Alta'' else ''Média'' end, count(*) from v_prazos_risco group by 1'),
      _rg_pizza('Por grupo de risco', S, 'select grupo_risco, count(*) from v_prazos_risco group by 1'),
      _rg_pizza('Por categoria', S, 'select categoria, count(*) from v_prazos_risco group by 1'),
      _rg_pizza('Por conferência', S, 'select situacao_conferencia, count(*) from v_prazos_risco group by 1'));
  when 'reagendamentos' then
    kp := jsonb_build_array(
      jsonb_build_object('rotulo', 'Reagendamentos no período', 'valor', _rg_num(format('select count(*) from v_reagendamentos where data_referencia between %L and %L', a, b))),
      jsonb_build_object('rotulo', 'Sem justificativa', 'valor', _rg_num(format('select count(*) from v_reagendamentos where data_referencia between %L and %L and sem_justificativa', a, b))));
    pz := jsonb_build_array(
      _rg_pizza('Por classificação', P, format('select classificacao, count(*) from v_reagendamentos where data_referencia between %L and %L group by 1', a, b)),
      _rg_pizza('Por natureza', P, format('select natureza, count(*) from v_reagendamentos where data_referencia between %L and %L group by 1', a, b)),
      _rg_pizza('Com e sem justificativa', P, format('select case when sem_justificativa then ''Sem justificativa'' else ''Com justificativa'' end, count(*) from v_reagendamentos where data_referencia between %L and %L group by 1', a, b)),
      _rg_pizza('Por responsável', P, format('select ' || t_resp || ', count(*) from v_reagendamentos where data_referencia between %L and %L group by 1', a, b)));
  when 'tratativa' then
    kp := jsonb_build_array(
      jsonb_build_object('rotulo', 'Abertas sem início de tratativa', 'valor', _rg_num('select count(*) from v_tratativa where situacao <> ''concluida'' and inicio_tratativa_em is null')),
      jsonb_build_object('rotulo', 'Horas médias até o início (período)', 'valor', _rg_num(format('select round(avg(horas_abertura_inicio)) from v_tratativa where inicio_tratativa_em::date between %L and %L', a, b))));
    pz := jsonb_build_array(
      _rg_pizza('Por situação da tratativa', S, 'select status_tratativa, count(*) from v_tratativa group by 1'),
      _rg_pizza('Abertas sem início, por responsável', S, 'select ' || t_resp || ', count(*) from v_tratativa where situacao <> ''concluida'' and inicio_tratativa_em is null group by 1'));
  when 'audiencias' then
    kp := jsonb_build_array(
      jsonb_build_object('rotulo', 'Audiências no período', 'valor', _rg_num(format('select count(*) from audiencias where situacao <> ''descartada'' and data between %L and %L', a, b))),
      jsonb_build_object('rotulo', 'Sem data na intimação', 'valor', _rg_num('select count(*) from audiencias where situacao = ''agendada'' and data is null')),
      jsonb_build_object('rotulo', 'Sem advogado', 'valor', _rg_num('select count(*) from audiencias a where ''sem_advogado'' = any(_audiencia_pendencias(a))')));
    pz := jsonb_build_array(
      _rg_pizza('Por situação', S, 'select situacao, count(*) from audiencias where situacao <> ''descartada'' group by 1'),
      _rg_pizza('Por tipo', S, 'select coalesce(tipo, ''Tipo não informado''), count(*) from audiencias where situacao <> ''descartada'' group by 1'),
      _rg_pizza('Por modalidade', S, 'select coalesce(modalidade, ''não informada''), count(*) from audiencias where situacao <> ''descartada'' group by 1'),
      _rg_pizza('Pendências', S, 'select p, count(*) from audiencias a cross join lateral unnest(_audiencia_pendencias(a)) p group by 1'),
      _rg_pizza('Por equipe', S, 'select coalesce(_audiencia_cliente_equipe(cnj)->>''equipe'', ''Sem equipe''), count(*) from audiencias where situacao <> ''descartada'' group by 1'),
      _rg_pizza('Resultados registrados', P, format('select resultado, count(*) from audiencias where resultado is not null and data between %L and %L group by 1', a, b)));
  when 'minha-pauta' then
    kp := jsonb_build_array(
      jsonb_build_object('rotulo', 'Tarefas abertas', 'valor', _rg_num('select count(*) from v_tarefas_atuais where situacao <> ''concluida''')),
      jsonb_build_object('rotulo', 'Vencidas', 'valor', _rg_num('select count(*) from v_tarefas_atuais where situacao <> ''concluida'' and coalesce(pf_tarefa, d7_data_agenda) < hoje_brasilia()')));
    pz := jsonb_build_array(
      _rg_pizza('Tarefas abertas por vencimento', S, 'select case when v is null then ''Sem data'' when v < hoje_brasilia() then ''Vencidas'' when v = hoje_brasilia() then ''Hoje''
                   when v <= hoje_brasilia() + 7 then ''Próximos 7 dias'' else ''Depois de 7 dias'' end, count(*)
              from (select coalesce(pf_tarefa, d7_data_agenda) v from v_tarefas_atuais where situacao <> ''concluida'') x group by 1'),
      _rg_pizza('Tarefas abertas por responsável', S, 'select ' || t_resp || ', count(*) from v_tarefas_atuais where situacao <> ''concluida'' group by 1'));
  when 'solicitacoes' then
    kp := jsonb_build_array(jsonb_build_object('rotulo', 'Solicitações no período', 'valor', _rg_num(format('select count(*) from solicitacoes where criada_em::date between %L and %L', a, b))),
      jsonb_build_object('rotulo', 'Aguardando decisão', 'valor', _rg_num('select count(*) from solicitacoes where decidido_em is null')));
    pz := jsonb_build_array(
      _rg_pizza('Por situação', P, format('select status, count(*) from solicitacoes where criada_em::date between %L and %L group by 1', a, b)),
      _rg_pizza('Por tipo', P, format('select tipo, count(*) from solicitacoes where criada_em::date between %L and %L group by 1', a, b)),
      _rg_pizza('Por quem pediu', P, format('select solicitante_papel, count(*) from solicitacoes where criada_em::date between %L and %L group by 1', a, b)));
  when 'atlas' then
    kp := jsonb_build_array(
      jsonb_build_object('rotulo', 'Sincronizações no período', 'valor', _rg_num(format('select count(*) from importacoes where nome_arquivo like ''Atlas%%'' and importado_em::date between %L and %L', a, b))),
      jsonb_build_object('rotulo', 'Erros da integração no período', 'valor', _rg_num(format('select count(*) from log_integracao where origem = ''atlas_api'' and nivel = ''erro'' and ocorrido_em::date between %L and %L', a, b))));
    pz := jsonb_build_array(
      _rg_pizza('Registros da integração por nível', P, format('select nivel, count(*) from log_integracao where origem = ''atlas_api'' and ocorrido_em::date between %L and %L group by 1', a, b)),
      _rg_pizza('Registros da integração por operação', P, format('select operacao, count(*) from log_integracao where origem = ''atlas_api'' and ocorrido_em::date between %L and %L group by 1', a, b)),
      _rg_pizza('Tarefas do Atlas por situação', S, 'select situacao, count(*) from v_tarefas_atuais where advbox_id like ''AT:%%'' group by 1'));
  when 'cadastro-atlas' then
    kp := jsonb_build_array(
      jsonb_build_object('rotulo', 'Cadastrados pelo robô', 'valor', _rg_num('select count(*) from atlas_cadastro where situacao = ''cadastrado''')),
      jsonb_build_object('rotulo', 'Cadastrados no período', 'valor', _rg_num(format('select count(*) from atlas_cadastro where cadastrado_em::date between %L and %L', a, b))),
      jsonb_build_object('rotulo', 'Cliente não encontrado', 'valor', _rg_num('select count(*) from atlas_cadastro where situacao = ''sem_cliente''')));
    pz := jsonb_build_array(
      _rg_pizza('Processos por situação', S, 'select situacao, count(*) from atlas_cadastro group by 1'),
      _rg_pizza('Cadastrados por tipo no Atlas', S, 'select tipo_atlas, count(*) from atlas_cadastro where situacao = ''cadastrado'' group by 1'),
      _rg_pizza('Como o cliente foi encontrado', S, 'select casado_por, count(*) from atlas_cadastro where situacao in (''previa'',''aprovado'',''cadastrado'') group by 1'));
  when 'intimacoes-cnj' then
    kp := jsonb_build_array(
      jsonb_build_object('rotulo', 'Comunicações no período', 'valor', _rg_num(format('select count(*) from cnj_comunicacoes where data_disponibilizacao between %L and %L', a, b))),
      jsonb_build_object('rotulo', 'Processos na carteira', 'valor', _rg_num('select count(*) from cnj_carteira where ativo')));
    pz := jsonb_build_array(
      _rg_pizza('Por tribunal', P, format('select sigla_tribunal, count(*) from cnj_comunicacoes where data_disponibilizacao between %L and %L group by 1', a, b)),
      _rg_pizza('Por tipo de comunicação', P, format('select tipo_comunicacao, count(*) from cnj_comunicacoes where data_disponibilizacao between %L and %L group by 1', a, b)),
      _rg_pizza('Capturadas também pela Webjur', P, format('select case when exists (select 1 from publicacoes p where p.id_documento = c.id::text
                     or (p.cnj = c.cnj and p.data_disponibilizacao = c.data_disponibilizacao)) then ''Sim'' else ''Não'' end, count(*)
              from cnj_comunicacoes c where c.data_disponibilizacao between %L and %L group by 1', a, b)),
      _rg_pizza('Como foram encontradas', P, format('select case when exists (select 1 from unnest(encontrada_por) e where e like ''oab:%%'') then ''Pela OAB'' else ''Pela varredura dos processos'' end, count(*) from cnj_comunicacoes where data_disponibilizacao between %L and %L group by 1', a, b)));
  when 'publicacoes' then
    kp := jsonb_build_array(
      jsonb_build_object('rotulo', 'Publicações no período', 'valor', _rg_num(format('select count(*) from publicacoes where data_disponibilizacao between %L and %L', a, b))),
      jsonb_build_object('rotulo', 'Processos diferentes', 'valor', _rg_num(format('select count(distinct cnj) from publicacoes where data_disponibilizacao between %L and %L', a, b))));
    pz := jsonb_build_array(
      _rg_pizza('Por tribunal', P, format('select tribunal, count(*) from publicacoes where data_disponibilizacao between %L and %L group by 1', a, b)),
      _rg_pizza('Com identificador do CNJ', P, format('select case when id_documento is not null then ''Com identificador'' else ''Sem identificador (diário estadual)'' end, count(*) from publicacoes where data_disponibilizacao between %L and %L group by 1', a, b)),
      _rg_pizza('Número do processo', P, format('select case when cnj_digito_valido then ''Válido'' when cnj is null then ''Sem número'' else ''Inválido'' end, count(*) from publicacoes where data_disponibilizacao between %L and %L group by 1', a, b)));
  when 'inconsistencias' then
    kp := jsonb_build_array(
      jsonb_build_object('rotulo', 'Abertas', 'valor', _rg_num('select count(*) from inconsistencias where situacao = ''aberta''')),
      jsonb_build_object('rotulo', 'Apontadas no período', 'valor', _rg_num(format('select count(*) from inconsistencias where primeira_vez_em::date between %L and %L', a, b))),
      jsonb_build_object('rotulo', 'Regularizadas ou justificadas no período', 'valor', _rg_num(format('select count(*) from inconsistencias where situacao <> ''aberta'' and tratada_em::date between %L and %L', a, b))));
    pz := jsonb_build_array(
      _rg_pizza('Abertas por tipo', S, 'select tipo, count(*) from inconsistencias where situacao = ''aberta'' group by 1'),
      _rg_pizza('Abertas por gravidade', S, 'select case gravidade when 1 then ''Alta'' when 2 then ''Média'' else ''Baixa'' end, count(*) from inconsistencias where situacao = ''aberta'' group by 1'),
      _rg_pizza('Apontadas no período, por situação', P, format('select situacao, count(*) from inconsistencias where primeira_vez_em::date between %L and %L group by 1', a, b)));
  when 'analise' then
    kp := jsonb_build_array(jsonb_build_object('rotulo', 'Tarefas de análise', 'valor', _rg_num('select count(*) from tarefas_analise where not coalesce(teste, false)')));
    pz := jsonb_build_array(
      _rg_pizza('Por situação', S, 'select status, count(*) from tarefas_analise where not coalesce(teste, false) group by 1'),
      _rg_pizza('Por tipo', S, 'select tipo, count(*) from tarefas_analise where not coalesce(teste, false) group by 1'),
      _rg_pizza('Exigem cadastro do processo', S, 'select case when requer_cadastro then ''Sim'' else ''Não'' end, count(*) from tarefas_analise where not coalesce(teste, false) group by 1'));
  when 'importacao' then
    kp := jsonb_build_array(jsonb_build_object('rotulo', 'Importações no período', 'valor', _rg_num(format('select count(*) from importacoes where importado_em::date between %L and %L', a, b))));
    pz := jsonb_build_array(
      _rg_pizza('Importações por situação', P, format('select status, count(*) from importacoes where importado_em::date between %L and %L group by 1', a, b)),
      _rg_pizza('Importações por origem', P, format('select case when nome_arquivo like ''Atlas%%'' then ''Atlas (API)'' else ''Excel do ADVBOX'' end, count(*) from importacoes where importado_em::date between %L and %L group by 1', a, b)),
      _rg_pizza('Linhas importadas por resultado', P, format('select r, sum(n) from importacoes i cross join lateral (values (''Válidas'', i.linhas_validas), (''Rejeitadas'', i.linhas_rejeitadas), (''Duplicadas'', i.linhas_duplicadas), (''Ambíguas'', i.linhas_ambiguas)) v(r, n)
              where i.importado_em::date between %L and %L group by 1', a, b)));
  when 'double-check' then
    kp := jsonb_build_array(jsonb_build_object('rotulo', 'Alertas', 'valor', _rg_num('select count(*) from v_alertas_conferencia')));
    pz := jsonb_build_array(
      _rg_pizza('Por situação da conferência', S, 'select situacao_conferencia, count(*) from v_alertas_conferencia group by 1'),
      _rg_pizza('Por categoria', S, 'select categoria, count(*) from v_alertas_conferencia group by 1'),
      _rg_pizza('Por gravidade', S, 'select case gravidade when 1 then ''Crítica'' when 2 then ''Alta'' else ''Média'' end, count(*) from v_alertas_conferencia group by 1'));
  when 'auditoria' then
    kp := jsonb_build_array(jsonb_build_object('rotulo', 'Alterações no período', 'valor', _rg_num(format('select count(*) from auditoria_configuracao where ocorrido_em::date between %L and %L', a, b))));
    pz := jsonb_build_array(
      _rg_pizza('Por tabela', P, format('select tabela, count(*) from auditoria_configuracao where ocorrido_em::date between %L and %L group by 1', a, b)),
      _rg_pizza('Por operação', P, format('select operacao, count(*) from auditoria_configuracao where ocorrido_em::date between %L and %L group by 1', a, b)));
  when 'configuracoes' then
    kp := jsonb_build_array(
      jsonb_build_object('rotulo', 'Usuários com perfil', 'valor', _rg_num('select count(*) from perfis')),
      jsonb_build_object('rotulo', 'Parâmetros a confirmar', 'valor', _rg_num('select count(*) from parametros where not confirmado')));
    pz := jsonb_build_array(
      _rg_pizza('Usuários por perfil', S, 'select papel, count(*) from perfis group by 1'),
      _rg_pizza('Parâmetros por sistema', S, 'select case when chave like ''atlas%%'' or chave like ''equipes%%'' then ''Atlas''
                   when chave like ''cnj%%'' then ''CNJ'' when chave like ''pub%%'' or chave like ''webjur%%'' then ''Webjur''
                   when chave like ''audiencias%%'' then ''Audiências'' when chave like ''advbox%%'' or chave like ''extensao%%'' then ''ADVBOX'' else ''Geral'' end, count(*) from parametros group by 1'),
      _rg_pizza('Parâmetros confirmados', S, 'select case when confirmado then ''Confirmados'' else ''A confirmar'' end, count(*) from parametros group by 1'));
  else
    raise exception 'Área sem relatório gerencial: %', p_area;
  end case;
  return jsonb_build_object('area', p_area, 'periodo', jsonb_build_object('de', ini, 'ate', fim), 'gerado_em', now(),
                            'indicadores', kp, 'graficos', pz);
end $$;
revoke execute on function public.relatorio_gerencial(text, date, date) from public, anon;
grant execute on function public.relatorio_gerencial(text, date, date) to authenticated;
