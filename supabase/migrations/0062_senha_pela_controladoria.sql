-- =====================================================================
-- 0062 — Senha definida pela controladoria (pedido da controladoria em 26/11/2026)
--   * As pessoas não criam a própria senha: a controladoria cria a conta com uma senha no Supabase
--     (Authentication › Users › Add user › Create new user, com "Auto Confirm User") e, quando
--     precisar, troca a senha pelo painel (Configurações › Usuários › Definir senha).
--   * A troca é feita pela Edge Function admin-senha (a chave de serviço fica só no Supabase).
--     Antes de trocar, a função chama admin_registrar_alteracao_senha com o login da controladoria:
--     confere o perfil, exige o motivo e registra o pedido no histórico (eventos). A senha nunca é gravada.
-- =====================================================================

create or replace function public.admin_registrar_alteracao_senha(p_user_id uuid, p_motivo text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_email text;
begin
  if not is_admin() or auth.uid() is null then raise exception 'Somente a controladoria' using errcode = '42501'; end if;
  select email into v_email from auth.users where id = p_user_id;
  if v_email is null then raise exception 'Usuário inexistente no Supabase Auth'; end if;
  perform _exigir_motivo(p_motivo);
  insert into eventos (chave_dedupe, tipo, ocorrido_em, precisao_ocorrido, origem, historico_recuperado, classificacao, evidencia)
  values ('adm:' || gen_random_uuid(), 'cadastro_administrativo', now(), 'segundo', 'administrativo', false, 'confirmado',
          jsonb_build_object('operacao', 'alterar_senha', 'conta', p_user_id, 'email', v_email,
                             'motivo', btrim(p_motivo), 'usuario', auth.uid()));
  return jsonb_build_object('user_id', p_user_id, 'email', v_email);
end $$;
revoke execute on function public.admin_registrar_alteracao_senha(uuid, text) from public, anon;
grant execute on function public.admin_registrar_alteracao_senha(uuid, text) to authenticated;
