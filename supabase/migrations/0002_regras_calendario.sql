-- =====================================================================
-- 0002 — Parâmetros, calendário e regras centrais de datas
-- Toda regra de data do sistema passa por ESTAS funções. Nenhuma tela
-- ou consulta deve recalcular D-4/D-7 por conta própria.
-- =====================================================================

insert into public.parametros (chave, valor, confirmado, descricao) values
 ('d4_dias_uteis_antes_pf', '3', true,
  'D-4: quantos dias úteis subtrair do PF Judicial. Os exemplos do escritório (PF 27/10 -> 22/10; PF 26/10 -> 21/10) '
  'só fecham contando o próprio dia do PF como 1º dia, ou seja, PF menos 3 dias úteis. '
  'A leitura literal "4 dias úteis antes" daria 21/10 e 20/10. CONFIRMADO pelo escritório em 24/10/2026.'),
 ('d7_dias_uteis_antes_pf', '6', true,
  'D-7 (primeira data na agenda, prazos de 15 dias): mesma convenção de contagem do D-4 (PF menos 6 dias úteis). '
  'Usado SOMENTE para conferência; o valor de origem é a coluna Data do Excel. CONFIRMADO em 24/10/2026.'),
 ('alerta_dias_uteis_proximo', '2', false,
  'Quantos dias úteis antes de um marco a tarefa passa a ser "próxima". PENDENTE DE DEFINIÇÃO.'),
 ('periodicidade_importacao_horas', '24', true,
  'Exportação diária (Atividades > Pendentes a partir de 01/10/2026). Após 24 h sem importação o painel alerta desatualização.'),
 ('entrega_interna_criterio', '"data_conclusao"', true,
  'Evidência de entrega interna em D-4: somente a conclusão registrada da tarefa. CONFIRMADO em 24/10/2026.'),
 ('compromissos_protocolo', '["PROTOCOLO"]', true,
  'Compromissos cuja CONCLUSÃO conta como protocolo realizado (a coluna Protocolo veio vazia em 100% das linhas). CONFIRMADO em 24/10/2026.'),
 ('compromissos_distribuicao', '["DISTRIBUIÇÃO - NOVO PROCESSO"]', true,
  'Compromissos cuja CONCLUSÃO conta como distribuição realizada. CONFIRMADO em 24/10/2026.'),
 ('pf_judicial_fonte', '"anotacao_observacoes"', true,
  'Fonte oficial do PF Judicial: anotação "PF: dd/mm" em Observações. CONFIRMADO em 24/10/2026.'),
 ('alteracao_pf_regra', '"somente_prazo_nao_judicial_com_autorizacao_controladoria"', true,
  'PF só pode ser alterado em prazos não judiciais, com autorização da controladoria. CONFIRMADO em 24/10/2026.'),
 ('fuso_horario', '"America/Sao_Paulo"', true, 'Fuso de apresentação e de interpretação das datas do Excel.');

create or replace function public.param_int(p_chave text) returns int
language sql stable as $$ select (valor #>> '{}')::int from public.parametros where chave = p_chave $$;

create or replace function public.hoje_brasilia() returns date
language sql stable as $$ select (now() at time zone 'America/Sao_Paulo')::date $$;

-- ---------------------------------------------------------------------
-- Feriados nacionais 2026–2027 (somente os fixados em lei federal)
-- Lei 662/1949 (red. Lei 10.607/2002), Lei 6.802/1980, Lei 14.759/2023.
-- NÃO incluídos de propósito (dependem de tribunal/ato local e devem ser
-- cadastrados por tribunal): Carnaval, Quarta de Cinzas, Semana Santa/
-- Sexta-feira Santa, Corpus Christi, 28/10, 08/12, recesso de fim de ano
-- e a suspensão de prazos do art. 220 do CPC (20/12 a 20/01).
-- ---------------------------------------------------------------------
insert into public.calendario_dias_nao_uteis (data, abrangencia, tipo, descricao, fundamento)
select d::date, 'nacional', 'feriado', descr, fund from (values
 ('2026-01-01','Confraternização Universal','Lei 662/1949'),
 ('2026-04-21','Tiradentes','Lei 662/1949'),
 ('2026-05-01','Dia do Trabalho','Lei 662/1949'),
 ('2026-09-07','Independência do Brasil','Lei 662/1949'),
 ('2026-10-12','Nossa Senhora Aparecida','Lei 6.802/1980'),
 ('2026-11-02','Finados','Lei 662/1949'),
 ('2026-11-15','Proclamação da República','Lei 662/1949'),
 ('2026-11-20','Dia Nacional de Zumbi e da Consciência Negra','Lei 14.759/2023'),
 ('2026-12-25','Natal','Lei 662/1949'),
 ('2027-01-01','Confraternização Universal','Lei 662/1949'),
 ('2027-04-21','Tiradentes','Lei 662/1949'),
 ('2027-05-01','Dia do Trabalho','Lei 662/1949'),
 ('2027-09-07','Independência do Brasil','Lei 662/1949'),
 ('2027-10-12','Nossa Senhora Aparecida','Lei 6.802/1980'),
 ('2027-11-02','Finados','Lei 662/1949'),
 ('2027-11-15','Proclamação da República','Lei 662/1949'),
 ('2027-11-20','Dia Nacional de Zumbi e da Consciência Negra','Lei 14.759/2023'),
 ('2027-12-25','Natal','Lei 662/1949')
) v(d, descr, fund);

-- Dia útil = seg–sex, sem feriado/recesso/suspensão nacional nem do tribunal.
create or replace function public.e_dia_util(p_data date, p_tribunal text default null)
returns boolean language sql stable as $$
  select extract(isodow from p_data) < 6
     and not exists (
       select 1 from public.calendario_dias_nao_uteis c
        where c.data = p_data
          and c.tipo in ('feriado','recesso','suspensao')
          and (c.abrangencia = 'nacional'
               or (c.abrangencia = 'tribunal' and c.tribunal_cnj = p_tribunal)))
$$;

-- Soma (n>0) ou subtrai (n<0) dias úteis. n = 0 devolve a própria data.
create or replace function public.somar_dias_uteis(p_data date, p_n int, p_tribunal text default null)
returns date language plpgsql stable as $$
declare d date := p_data; passo int := sign(p_n); faltam int := abs(p_n);
begin
  if p_data is null or p_n is null then return null; end if;
  while faltam > 0 loop
    d := d + passo;
    if public.e_dia_util(d, p_tribunal) then faltam := faltam - 1; end if;
  end loop;
  return d;
end $$;

-- Dias úteis entre duas datas (exclui a inicial, inclui a final). Negativo se b < a.
create or replace function public.dias_uteis_entre(a date, b date, p_tribunal text default null)
returns int language sql stable as $$
  select case when a is null or b is null then null
              when b >= a then (select count(*)::int from generate_series(a + 1, b, interval '1 day') g
                                 where public.e_dia_util(g::date, p_tribunal))
              else -(select count(*)::int from generate_series(b + 1, a, interval '1 day') g
                      where public.e_dia_util(g::date, p_tribunal)) end
$$;

-- REGRA CENTRAL D-4 (marco interno de entrega). Base: PF JUDICIAL.
create or replace function public.calcular_d4(p_pf_judicial date, p_tribunal text default null)
returns date language sql stable as $$
  select public.somar_dias_uteis(p_pf_judicial, -public.param_int('d4_dias_uteis_antes_pf'), p_tribunal)
$$;

-- Referência de conferência para D-7 (não substitui a data da agenda).
create or replace function public.calcular_d7_conferencia(p_pf_judicial date, p_tribunal text default null)
returns date language sql stable as $$
  select public.somar_dias_uteis(p_pf_judicial, -public.param_int('d7_dias_uteis_antes_pf'), p_tribunal)
$$;

-- ---------------------------------------------------------------------
-- Auxiliares de interpretação do Excel
-- ---------------------------------------------------------------------
create or replace function public.parse_data_br(p text) returns date
language plpgsql immutable as $$
begin
  if p is null or btrim(p) = '' then return null; end if;
  if btrim(p) !~ '^\d{2}/\d{2}/\d{4}$' then raise exception 'formato'; end if;
  return to_date(btrim(p), 'DD/MM/YYYY');   -- to_date valida dia/mês (erro em 31/02)
end $$;

-- "dd/mm" ou "dd/mm/aa(aa)" -> data. Sem ano: escolhe o ano que deixa a
-- data mais próxima da referência (documentado; o texto original é guardado).
create or replace function public.data_anotada(p text, p_ref date) returns date
language plpgsql immutable as $$
declare dd int; mm int; yy int; partes text[]; c date; melhor date;
begin
  if p is null then return null; end if;
  partes := string_to_array(p, '/');
  dd := partes[1]::int; mm := partes[2]::int;
  if array_length(partes,1) = 3 then
    yy := partes[3]::int; if yy < 100 then yy := 2000 + yy; end if;
    return make_date(yy, mm, dd);
  end if;
  if p_ref is null then return null; end if;
  foreach yy in array array[extract(year from p_ref)::int - 1, extract(year from p_ref)::int, extract(year from p_ref)::int + 1] loop
    begin
      c := make_date(yy, mm, dd);
      if melhor is null or abs(c - p_ref) < abs(melhor - p_ref) then melhor := c; end if;
    exception when others then null;
    end;
  end loop;
  return melhor;
exception when others then return null;
end $$;

create or replace function public.tribunal_do_cnj(p text) returns text
language sql immutable as $$
  select (regexp_match(btrim(coalesce(p,'')), '^\d{7}-\d{2}\.\d{4}\.(\d\.\d{2})\.\d{4}$'))[1]
$$;

-- Parágrafos de Observações sem as linhas automáticas de encaminhamento.
create or replace function public.paragrafos_obs(p text)
returns table (ordem int, texto text) language sql immutable as $$
  select (row_number() over (order by o))::int, btrim(t)
    from regexp_split_to_table(coalesce(p,''), '\n\s*\n') with ordinality s(t, o)
   where btrim(t) <> ''
     and btrim(t) !~ '^@\S+ encaminhou para @\S+ em \d{2}/\d{2}/\d{4} \d{2}:\d{2}:\d{2}$'
$$;

-- Chave estável: campos que NÃO mudam na realocação (data, PF e
-- responsável mudam) + o 1º parágrafo original de Observações.
create or replace function public.chave_estavel(
  p_compromisso text, p_remetente text, p_partes text, p_processo text, p_tipo text, p_obs text)
returns text language sql immutable as $$
  select md5(concat_ws('|',
    upper(btrim(coalesce(p_compromisso,''))), upper(btrim(coalesce(p_remetente,''))),
    upper(btrim(coalesce(p_partes,''))), btrim(coalesce(p_processo,'')),
    upper(btrim(coalesce(p_tipo,''))),
    coalesce((select regexp_replace(texto, '\s+', ' ', 'g') from public.paragrafos_obs(p_obs) where ordem = 1), '')))
$$;

-- Última ocorrência de um padrão (captura 1) no texto.
create or replace function public.ultima_captura(p text, p_regex text) returns text
language sql immutable as $$
  select m[1] from regexp_matches(coalesce(p,''), p_regex, 'gi') with ordinality r(m, o)
   order by o desc limit 1
$$;
