-- =====================================================================
-- 0052 — Leitura das audiências: ajustes do 1º teste real (14/11/2026, 23:15)
-- Achados nas intimações reais (E27):
--   * "para o dia 26 de Janeiro de 2.027, as 14h30" — ano com ponto: a data não era lida (audiência ficou "sem data");
--   * "determino a remessa ao CEJUSC para designação de nova data para audiência" e "intime-se acerca da nova data
--     designada" viraram audiência: o verbo de designação era procurado numa janela larga demais e "designação de"
--     contava como designação. Agora o verbo tem de estar colado à palavra (até 60 caracteres antes ou 90 depois) e
--     "designação" sozinha não conta.
-- As audiências lidas antes da correção são relidas (só as que ninguém mexeu ainda): a falsa vira "descartada" e a
-- que ganhou data é atualizada. Nada é apagado; tudo fica no histórico.
-- =====================================================================
alter table public.audiencias drop constraint if exists audiencias_situacao_check;
alter table public.audiencias add constraint audiencias_situacao_check
  check (situacao in ('agendada','redesignada','cancelada','realizada','nao_realizada','descartada'));
alter table public.audiencia_eventos drop constraint if exists audiencia_eventos_tipo_check;
alter table public.audiencia_eventos add constraint audiencia_eventos_tipo_check
  check (tipo in ('identificada','nova_fonte','designacao','confirmacao','correcao','resultado','redesignada','releitura'));

create or replace function public._audiencia_extrair(p_texto text, p_ref date default null) returns jsonb
language plpgsql immutable set search_path = public as $$
declare
  o text := regexp_replace(regexp_replace(coalesce(p_texto, ''), '<[^>]+>', ' ', 'g'), '\s+', ' ', 'g');   -- texto limpo
  t text := _texto_norm(p_texto);                                                                        -- mesmo tamanho, maiúsculo e sem acento
  meses constant text[] := array['JANEIRO','FEVEREIRO','MARCO','ABRIL','MAIO','JUNHO','JULHO','AGOSTO','SETEMBRO','OUTUBRO','NOVEMBRO','DEZEMBRO'];
  pos int := 0; p int; w text; perto text; depois text; m text[]; md text[]; v_data date; v_hora text;
  r jsonb := null; v_tipo text; v_mod text; v_link text; v_amplo text; v_ano int;
begin
  if t = '' or position('AUDIENCIA' in t) = 0 then return null; end if;
  loop
    p := position('AUDIENCIA' in substr(t, pos + 1));
    exit when p = 0;
    pos := pos + p;
    w := substr(t, greatest(1, pos - 140), least(pos - 1, 140)) || substr(t, pos, 380);
    depois := substr(t, pos, 380);
    perto := substr(t, greatest(1, pos - 60), least(pos - 1, 60)) || substr(t, pos, 90);   -- 0052: verbo colado à palavra
    if perto !~ '(RE)?DESIGN(O|A-SE|E-SE|ADA|ANDO)\M|FICA (RE)?MARCADA|\mMARCO\M|\mAGENDO\M|AGENDADA PARA'
       or substr(t, greatest(1, pos - 40), least(pos - 1, 40)) ~ 'DEIXO DE DESIGNAR( A)?|NAO (HA COMO )?DESIGN|DISPENSO( A)?|INTERESSE NA (REALIZACAO|DESIGNACAO)( DE| DA)?|EVENTUAL|RESULTADO INFRUTIFERO DA|ATA DE|CANCELO( A)?|RETIRO DE PAUTA( A)?|CONVENIENCIA DA|DIAS DA|ANTECEDENCIA (MINIMA )?DE|DESIGNACAO DE NOVA DATA PARA'
       or substr(t, pos, 70) ~ 'ANTERIORMENTE DESIGNADA|DESNECESSARIA|CANCELADA|SEM EFEITO|RESTOU PREJUDICADA|FOI REALIZADA|REALIZADA EM|INFRUTIFERA'
    then continue; end if;
    v_data := null; v_hora := null; md := null;
    m := regexp_match(depois, '(?:DIA|PARA|EM|DATA:?)\s*(\d{1,2})/(\d{1,2})/(\d\.?\d{3}|\d{2})\M(.{0,70})');
    if m is not null then
      v_ano := replace(m[3], '.', '')::int; if v_ano < 100 then v_ano := 2000 + v_ano; end if;
      begin v_data := make_date(v_ano, m[2]::int, m[1]::int); exception when others then v_data := null; end;
      md := array[m[4]];
    else   -- "26 de Janeiro de 2.027" (ano com ponto)
      m := regexp_match(depois, '(\d{1,2})O? DE (JANEIRO|FEVEREIRO|MARCO|ABRIL|MAIO|JUNHO|JULHO|AGOSTO|SETEMBRO|OUTUBRO|NOVEMBRO|DEZEMBRO) DE (\d\.?\d{3})(.{0,70})');
      if m is not null then
        begin v_data := make_date(replace(m[3], '.', '')::int, array_position(meses, m[2]), m[1]::int); exception when others then v_data := null; end;
        md := array[m[4]];
      end if;
    end if;
    if v_data is not null and p_ref is not null and v_data < p_ref then v_data := null; end if;   -- data do ato, não da audiência
    if v_data is not null then   -- hora logo depois da data: "às 08:23", "as 14h30", "às 9 horas"
      m := regexp_match(md[1], '(?:AS|A PARTIR DAS|HORARIO:?|HORA:?|,)\s*(\d{1,2})\s*(?::|H|HORAS?)\s*(\d{2})?');
      if m is not null and m[1]::int between 0 and 23 and coalesce(m[2], '00')::int < 60 then
        v_hora := lpad(m[1], 2, '0') || ':' || coalesce(m[2], '00');
      end if;
    end if;
    v_tipo := case
      when w ~ 'INSTRUCAO E JULGAMENTO|AUDIENCIA DE INSTRUCAO|AIJ\M' then 'Instrução e julgamento'
      when w ~ 'DEPOIMENTO PESSOAL|OITIVA|TESTEMUNH' then 'Instrução (depoimento/testemunhas)'
      when w ~ 'AUDIENCIA UNA|\mUNA\M' then 'Una'
      when w ~ 'MEDIACAO' then 'Mediação'
      when w ~ 'CONCILIA' then 'Conciliação'
      when w ~ 'JUSTIFICACAO' then 'Justificação'
      when w ~ 'SANEAMENTO' then 'Saneamento'
      when w ~ 'INICIAL' then 'Inicial'
      end;
    v_amplo := substr(t, greatest(1, pos - 300), 1200);
    v_mod := case
      when v_amplo ~ 'HIBRID' then 'híbrida'
      when v_amplo ~ 'VIDEOCONFERENCIA|TELEPRESENCIAL|VIRTUAL|REMOTA|TEAMS|ZOOM|GOOGLE MEET|WEBEX|ACESSO REMOTO' then 'virtual'
      when v_amplo ~ 'PRESENCIAL|COMPARECER (NA|AO|NO) (SALA|FORUM|ESTACAO|AUDITORIO|ENDERECO)|ESTACAO PASSIVA|SALA DE AUDIENCIAS' then 'presencial'
      end;
    select (regexp_match(u[1], '^(.*?)[.,;)]*$'))[1] into v_link
      from regexp_matches(coalesce(p_texto, ''), '(https?://[^\s"<>'']+)', 'g') u
     where u[1] ~* 'teams\.(microsoft|live)|zoom\.us|meet\.google|webex|jit\.si|whereby|videoconf|bit\.ly|tinyurl|link\.cnj|cnj\.jus\.br/.*(sala|video)'
     limit 1;
    r := jsonb_build_object('data', v_data, 'hora', v_hora, 'tipo', v_tipo, 'modalidade', v_mod, 'link', v_link,
                            'redesignacao', w ~ 'REDESIGN|NOVA AUDIENCIA|NOVA DATA', 'trecho', btrim(substr(o, greatest(1, pos - 140), 600)));
    exit when v_data is not null;   -- a 1ª designação com data vale; sem data, continua procurando uma com data
  end loop;
  return r;
end $$;
revoke execute on function public._audiencia_extrair(text, date) from public, anon, authenticated;

-- relê as audiências que ninguém mexeu (sem designação, correção ou resultado) com a leitura atual
create or replace function public._audiencias_reler() returns jsonb
language plpgsql security definer set search_path = public as $$
declare a record; x jsonb; melhor jsonb; v_chave text; n_desc int := 0; n_atual int := 0;
begin
  for a in select * from audiencias where situacao = 'agendada' and designado_em is null and corrigida_em is null and resultado is null loop
    melhor := null;
    for x in
      select _audiencia_extrair(coalesce(c.texto, p.teor), f.data_disponibilizacao)
        from audiencia_fontes f
        left join cnj_comunicacoes c on f.origem = 'cnj' and c.id = f.origem_id::bigint
        left join publicacoes p on f.origem = 'webjur' and p.id = f.origem_id::bigint
       where f.audiencia_id = a.id
    loop
      if x is not null and (melhor is null or (melhor->>'data' is null and x->>'data' is not null)) then melhor := x; end if;
    end loop;
    if melhor is null then
      update audiencias set situacao = 'descartada', atualizado_em = now() where id = a.id;
      update audiencia_fontes set achou = false where audiencia_id = a.id;
      insert into audiencia_eventos (audiencia_id, tipo, detalhe) values (a.id, 'releitura', jsonb_build_object('resultado', 'descartada',
        'motivo', 'A intimação não designa audiência (releitura 0052)'));
      n_desc := n_desc + 1;
    elsif melhor->>'data' is distinct from a.data::text or melhor->>'hora' is distinct from a.hora then
      v_chave := a.cnj || '|' || coalesce(melhor->>'data', 'sem-data:' || a.disponibilizada_em) || '|' || coalesce(melhor->>'hora', '');
      if not exists (select 1 from audiencias where chave = v_chave and id <> a.id) then
        update audiencias set chave = v_chave, data = (melhor->>'data')::date, hora = melhor->>'hora',
               tipo = coalesce(melhor->>'tipo', tipo), modalidade = coalesce(melhor->>'modalidade', modalidade),
               link = coalesce(melhor->>'link', link), trecho = melhor->>'trecho', atualizado_em = now()
         where id = a.id;
        insert into audiencia_eventos (audiencia_id, tipo, detalhe) values (a.id, 'releitura', jsonb_build_object('resultado', 'atualizada',
          'antes', jsonb_build_object('data', a.data, 'hora', a.hora), 'depois', melhor - 'trecho'));
        n_atual := n_atual + 1;
      end if;
    end if;
  end loop;
  return jsonb_build_object('descartadas', n_desc, 'atualizadas', n_atual);
end $$;
revoke execute on function public._audiencias_reler() from public, anon, authenticated;

-- descartada não aparece no painel nem cobra pendência
do $$
declare d text;
begin
  d := pg_get_functiondef('public.audiencias_painel(date, date, text, text, text)'::regprocedure);
  if position('-- 0052' in d) > 0 then return; end if;
  if position('       where (a.data between v_ini and v_fim' in d) = 0 then raise exception '0052: âncora do audiencias_painel não encontrada'; end if;
  d := replace(d, '       where (a.data between v_ini and v_fim', '       where a.situacao <> ''descartada''   -- 0052' || chr(10) || '         and (a.data between v_ini and v_fim');
  execute d;
end $$;

select public._audiencias_reler();
