-- =====================================================================
-- 0053 — Leitura das audiências: o verbo de designação tem de estar na MESMA FRASE (releitura real de 14/11/2026)
-- Achado (E27, 2ª parte): "...bem como a redesignação da audiência de conciliação. Considerando que a audiência
-- anteriormente designada restou prejudicada..." — o "designada" da frase seguinte fazia a 1ª menção valer como
-- audiência designada. A janela perto da palavra agora para no ponto final (ou ponto e vírgula) antes e depois.
-- Trecho-âncora em _audiencia_extrair (padrão das 0033/0034), idempotente; depois relê as audiências.
-- =====================================================================
do $$
declare d text;
  a1 constant text := $a$    perto := substr(t, greatest(1, pos - 60), least(pos - 1, 60)) || substr(t, pos, 90);$a$;
begin
  d := pg_get_functiondef('public._audiencia_extrair(text, date)'::regprocedure);
  if position('-- 0053' in d) > 0 then return; end if;
  if position(a1 in d) = 0 then raise exception '0053: âncora do _audiencia_extrair não encontrada'; end if;
  d := replace(d, a1, $n$    perto := regexp_replace(substr(t, greatest(1, pos - 60), least(pos - 1, 60)), '^.*[.;] ', '')   -- 0053: mesma frase
             || coalesce(substring(substr(t, pos, 90) from '^[^.;]*'), '');$n$);
  execute d;
end $$;

select public._audiencias_reler();
