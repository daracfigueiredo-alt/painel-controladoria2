-- =====================================================================
-- 0021 — Desempenho (07/11/2026). Mesmos resultados, menos trabalho.
-- Com a primeira base real (3.568 linhas), os indicadores levaram ~10 s e o
-- Supabase cancelou a consulta (limite de 8 s para usuários logados).
-- Onde estava o tempo (medido no banco de homologação):
--   * dias úteis contados dia a dia, com uma consulta ao calendário por dia
--     (datas distantes = centenas de consultas por tarefa): ~6 s;
--   * dados da tratativa buscados tarefa a tarefa (função por linha): ~3 s;
--   * número do processo e 1ª atribuição por subconsulta linha a linha.
-- Mudanças (nada é apagado; regras D-4/D-7 e calendário inalterados):
--   1. dias_uteis_entre: dias de semana por conta aritmética, menos os dias não
--      úteis do calendário no intervalo (uma consulta);
--   2. somar_dias_uteis: uma consulta em vez de um laço com consulta por dia;
--   3. tratativas_visiveis(): os dados de tratativa de todas as tarefas de uma vez,
--      com a mesma regra de acesso de tratativa_da_tarefa (0007);
--   4. v_tarefas_atuais usa (3) e junções no lugar das subconsultas por linha;
--   5. índice em eventos(linha_id);
--   6. limite de tempo das consultas de usuários logados: 30 s (era 8 s).
-- =====================================================================

-- ---------------------------------------------------------------- 1 e 2. dias úteis
-- dias de segunda a sexta em (a, b], com a <= b
create or replace function public._dias_semana(a date, b date) returns int
language sql immutable set search_path = public as $$
  select ((b - a) / 7) * 5
       + (select count(*)::int from generate_series(1, (b - a) % 7) k
           where extract(isodow from a + ((b - a) / 7) * 7 + k) < 6)
$$;

-- dias não úteis (segunda a sexta) do calendário em (a, b], com a <= b; mesmo critério de e_dia_util
create or replace function public._nao_uteis_entre(a date, b date, p_tribunal text, p_foro text) returns int
language sql stable set search_path = public as $$
  select count(distinct c.data)::int from public.calendario_dias_nao_uteis c
   where c.data > a and c.data <= b and extract(isodow from c.data) < 6
     and c.tipo in ('feriado','recesso','suspensao')
     and (c.abrangencia = 'nacional'
          or (c.abrangencia = 'tribunal' and c.tribunal_cnj = p_tribunal)
          or (c.abrangencia = 'foro' and c.tribunal_cnj = p_tribunal and c.foro_cnj = p_foro))
$$;

create or replace function public.dias_uteis_entre(a date, b date, p_tribunal text, p_foro text)
returns int language sql stable set search_path = public as $$
  select case when a is null or b is null then null
              when b >= a then public._dias_semana(a, b) - public._nao_uteis_entre(a, b, p_tribunal, p_foro)
              else -(public._dias_semana(b, a) - public._nao_uteis_entre(b, a, p_tribunal, p_foro)) end
$$;

-- Janela de busca: |n| * 2 + 120 dias corridos (cobre recessos e suspensões longas);
-- se não achar (não deve acontecer), cai no cálculo dia a dia.
create or replace function public._somar_dias_uteis_lento(p_data date, p_n int, p_tribunal text, p_foro text)
returns date language plpgsql stable set search_path = public as $$
declare d date := p_data; passo int := sign(p_n); faltam int := abs(p_n);
begin
  if p_data is null or p_n is null then return null; end if;
  while faltam > 0 loop
    d := d + passo;
    if public.e_dia_util(d, p_tribunal, p_foro) then faltam := faltam - 1; end if;
  end loop;
  return d;
end $$;

create or replace function public.somar_dias_uteis(p_data date, p_n int, p_tribunal text, p_foro text)
returns date language sql stable set search_path = public as $$
  select case when p_data is null or p_n is null then null
              when p_n = 0 then p_data
              else coalesce(
                (select d from (
                   select p_data + sign(p_n)::int * k as d, k
                     from generate_series(1, abs(p_n) * 2 + 120) k) s
                  where extract(isodow from s.d) < 6
                    and not exists (select 1 from public.calendario_dias_nao_uteis c
                                     where c.data = s.d and c.tipo in ('feriado','recesso','suspensao')
                                       and (c.abrangencia = 'nacional'
                                            or (c.abrangencia = 'tribunal' and c.tribunal_cnj = p_tribunal)
                                            or (c.abrangencia = 'foro' and c.tribunal_cnj = p_tribunal and c.foro_cnj = p_foro)))
                  order by s.k offset abs(p_n) - 1 limit 1),
                public._somar_dias_uteis_lento(p_data, p_n, p_tribunal, p_foro)) end
$$;

-- ---------------------------------------------------------------- 3. tratativa de todas as tarefas
-- Mesma regra de tratativa_da_tarefa(): admin vê todas; colaborador vê as do grupo em que
-- é responsável por alguma linha ou em que ele registrou o início.
create or replace function public.tratativas_visiveis()
returns table (tarefa_id bigint, tarefa_principal bigint, advbox_id text, abertura_em timestamptz,
               inicio_em timestamptz, inicio_por text, inicio_colaborador_id bigint)
language sql stable security definer set search_path = public as $$
  with grp as (select t.id, coalesce(t.unificada_em, t.id) as pr from tarefas t),
  ini as (select distinct on (g.pr) g.pr, e.ocorrido_em, e.colaborador_id, c.nome_advbox
            from eventos e join grp g on g.id = e.tarefa_id left join colaboradores c on c.id = e.colaborador_id
           where e.tipo = 'inicio_tratativa'
           order by g.pr, e.ocorrido_em),
  eu as (select public.is_admin() as adm, public.meu_colaborador_id() as me),
  meus as (select distinct g.pr from linhas_importadas l join grp g on g.id = l.tarefa_id, eu
            where not eu.adm and l.responsavel_id = eu.me)
  select g.id, g.pr, p.advbox_id, p.criada_em_advbox, i.ocorrido_em, i.nome_advbox, i.colaborador_id
    from grp g join tarefas p on p.id = g.pr left join ini i on i.pr = g.pr cross join eu
   where eu.adm or i.colaborador_id = eu.me or g.pr in (select pr from meus)
$$;

-- ---------------------------------------------------------------- 5. índice
create index if not exists eventos_linha_idx on public.eventos (linha_id);

-- ---------------------------------------------------------------- 4. visão (mesmas colunas, mesma ordem)
create or replace view public.v_tarefas_atuais with (security_invoker = true) as
with base as (
  select l.*, public.hoje_brasilia() as hoje, public.foro_do_cnj(l.processo_cnj) as foro
    from public.linhas_importadas l
   where l.situacao = 'valida' and l.lote_id = (select lote_id from public.v_lote_atual)
),
enc as (select e.tarefa_id, e.linha_id, e.ocorrido_em from public.eventos e where e.tipo = 'encaminhamento'),
enc_t as (select tarefa_id, min(ocorrido_em) m from enc where tarefa_id is not null group by tarefa_id),
enc_l as (select linha_id, min(ocorrido_em) m from enc where linha_id is not null group by linha_id),
tr as (select * from public.tratativas_visiveis()),
calc as (
  select b.*,
         public.calcular_d4(b.pf_judicial_anotado, b.tribunal_cnj, b.foro) as d4_r,
         coalesce(b.d4_anotado, public.calcular_d4(b.pf_judicial_anotado, b.tribunal_cnj, b.foro)) as d4_f
    from base b
)
select b.id as linha_id, b.tarefa_id, b.metodo_vinculo, b.importacao_id, b.lote_id, b.numero_linha,
       b.prioridade, b.compromisso, b.processo_cnj, b.tribunal_cnj, b.partes, b.tipo_acao, b.local,
       b.responsavel_id, cr.nome_advbox as responsavel, cm.nome_advbox as remetente,
       b.observacoes,
       b.data_agenda                                   as d7_data_agenda,
       public.calcular_d7_conferencia(b.pf_judicial_anotado, b.tribunal_cnj, b.foro) as d7_conferencia,
       b.d4_anotado,
       b.d4_r                                          as d4_regra,
       b.d4_f                                          as d4,
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
       public.dias_uteis_entre(b.hoje, b.d4_f, b.tribunal_cnj, b.foro)                as du_ate_d4,
       public.dias_uteis_entre(b.hoje, b.pf_judicial_anotado, b.tribunal_cnj, b.foro) as du_ate_pf_judicial,
       public.dias_uteis_entre(b.hoje, b.pf_tarefa, b.tribunal_cnj, b.foro)           as du_ate_pf_tarefa,
       tr.inicio_em                                    as inicio_tratativa_em,
       tr.abertura_em                                  as abertura_em,
       least(et.m, el.m)                               as primeira_atribuicao_observada_em,
       (select ultima_importacao_em from public.v_lote_atual) as dados_atualizados_em,
       tr.tarefa_principal                             as tarefa_principal_id,
       tr.advbox_id,
       tr.inicio_por,
       b.foro                                          as foro_cnj,
       pr.id                                           as processo_id,
       cr.equipe_id
  from calc b
  left join public.colaboradores cr on cr.id = b.responsavel_id
  left join public.colaboradores cm on cm.id = b.remetente_id
  left join tr on tr.tarefa_id = b.tarefa_id
  left join enc_t et on et.tarefa_id = b.tarefa_id
  left join enc_l el on el.linha_id = b.id
  left join public.processos pr on pr.cnj = public.normalizar_cnj(b.processo_cnj);

-- ---------------------------------------------------------------- privilégios
revoke execute on function public.tratativas_visiveis() from public, anon;
grant execute on function public.tratativas_visiveis() to authenticated;
revoke execute on function public._dias_semana(date, date), public._nao_uteis_entre(date, date, text, text),
                           public._somar_dias_uteis_lento(date, int, text, text) from public, anon;
grant execute on function public._dias_semana(date, date), public._nao_uteis_entre(date, date, text, text),
                          public._somar_dias_uteis_lento(date, int, text, text) to authenticated;
grant select on public.v_tarefas_atuais to authenticated;
revoke all on public.v_tarefas_atuais from anon;

-- ---------------------------------------------------------------- 6. limite de tempo
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'alter role authenticated set statement_timeout = ''30s''';
  end if;
end $$;
