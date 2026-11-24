-- =====================================================================
-- 0049 — Equipes e líderes (informado pela controladoria em 14/11/2026) e data de distribuição ausente
--   * Prime = Brenda Martins; Gold = Raquel Guerra; Celeste = Guilherme Ladeia; Êxitos = Pedro Frejah;
--     Delta = Ana Clara; Negociações = Leandro Santana (nova equipe).
--   * Bárbara Castro é da diretoria (sai da lista de líderes).
--   * A ligação líder × equipe (lideres_equipes) depende da conta de cada líder no painel; até lá,
--     a divisão fica registrada no parâmetro equipes_lideres.
--   * Cadastro no Atlas: sem a "Data do requerimento" no ADVBOX, o Atlas grava a data do cadastro como
--     distribuição; as notas passam a avisar.
-- =====================================================================
do $$ begin
  perform set_config('controladoria.motivo', 'Equipes e líderes informados pela controladoria em 14/11/2026', true);
  insert into public.equipes (nome) values ('Negociações') on conflict (nome) do nothing;
  update public.parametros
     set valor = '["Brenda Martins","Pedro Frejah","Raquel Guerra","Guilherme Ladeia","Ana Clara","Leandro Santana"]'::jsonb,
         atualizado_em = now()
   where chave = 'atlas_lideres';
end $$;

insert into public.parametros (chave, valor, confirmado, descricao) values
 ('equipes_lideres', '{"Prime":"Brenda Martins","Gold":"Raquel Guerra","Celeste":"Guilherme Ladeia","Êxitos":"Pedro Frejah","Delta":"Ana Clara","Negociações":"Leandro Santana"}', true,
  'Líder de cada equipe, informado pela controladoria em 14/11/2026. Ao criar a conta do líder, ligar a equipe em Configurações › Usuários.')
on conflict (chave) do nothing;

-- notas do cadastro no Atlas: avisa quando o ADVBOX não tem a data do requerimento
do $$
declare d text;
  a1 constant text := $a$       'Processo originário: ' || a.processo_originario,$a$;
begin
  d := pg_get_functiondef('public._atlas_cadastro_preparar(text[])'::regprocedure);
  if position('-- 0049' in d) > 0 then return; end if;
  if position(a1 in d) = 0 then raise exception '0049: âncora do _atlas_cadastro_preparar não encontrada'; end if;
  d := replace(d, a1, $n$       case when a.data_requerimento is null and a.origem = 'advbox' then   -- 0049
         'Data de distribuição não informada no ADVBOX (o Atlas registra a data do cadastro): conferir.' end,
$n$ || a1);
  execute d;
end $$;
