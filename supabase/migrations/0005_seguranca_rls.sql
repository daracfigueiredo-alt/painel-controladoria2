-- =====================================================================
-- 0005 — Segurança: RLS, privilégios mínimos
-- Escrita direta nas tabelas é proibida para anon/authenticated.
-- Gravação só por funções SECURITY DEFINER que validam o perfil.
-- A chave service_role nunca vai para o navegador nem para a extensão.
-- =====================================================================

do $$ declare t text;
begin
  foreach t in array array['parametros','colaboradores','perfis','calendario_dias_nao_uteis','lotes_importacao',
                           'importacoes','linhas_importadas','tarefas','eventos'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
    execute format('grant select on public.%I to authenticated', t);
  end loop;
end $$;

create policy parametros_leitura   on public.parametros  for select to authenticated using (true);
create policy calendario_leitura   on public.calendario_dias_nao_uteis for select to authenticated using (true);
create policy colaboradores_leitura on public.colaboradores for select to authenticated using (true);
create policy perfis_leitura       on public.perfis for select to authenticated
  using (user_id = auth.uid() or public.is_admin());
create policy lotes_admin          on public.lotes_importacao for select to authenticated using (public.is_admin());
create policy importacoes_admin    on public.importacoes for select to authenticated using (public.is_admin());
create policy linhas_leitura       on public.linhas_importadas for select to authenticated
  using (public.is_admin() or responsavel_id = public.meu_colaborador_id());
create policy tarefas_leitura      on public.tarefas for select to authenticated
  using (public.is_admin() or exists (select 1 from public.linhas_importadas l
           where l.tarefa_id = tarefas.id and l.responsavel_id = public.meu_colaborador_id()));
create policy eventos_leitura      on public.eventos for select to authenticated
  using (public.is_admin() or colaborador_id = public.meu_colaborador_id()
         or exists (select 1 from public.linhas_importadas l
                     where l.id = eventos.linha_id and l.responsavel_id = public.meu_colaborador_id()));

-- views
grant select on public.v_lote_atual, public.v_tarefas_atuais, public.v_alertas,
                public.v_alteracoes_sem_justificativa to authenticated;
revoke all on public.v_lote_atual, public.v_tarefas_atuais, public.v_alertas,
              public.v_alteracoes_sem_justificativa from anon;

-- funções: interna não pode ser chamada diretamente
revoke execute on all functions in schema public from public, anon;
grant execute on all functions in schema public to authenticated;
revoke execute on function public._gerar_eventos_importacao(bigint, timestamptz) from authenticated;
