# Etapa 20 — Senha definida pela controladoria (26/11/2026)

Decisão da controladoria em 26/11/2026: **as pessoas não criam a própria senha.** A controladoria cria a conta
já com uma senha e pode trocá-la quando precisar.

## Criar a conta (Supabase)

Authentication › Users › **Add user › Create new user**:
- e-mail da pessoa;
- senha (mínimo 8 caracteres);
- marcar **Auto Confirm User**.

Não usar "Send invitation": o painel não tem tela para a pessoa criar a senha pelo link do convite.
Se o e-mail estiver na lista de acessos previstos (0061), o perfil e a equipe entram sozinhos.

## Trocar a senha (painel)

Configurações administrativas › Usuários e perfis › coluna **Senha › Definir senha**: nova senha, repetir a senha
e motivo. Passe a senha à pessoa por um canal seguro.

Como funciona:
- O painel chama a Edge Function **`admin-senha`** com o login da controladoria.
- A função chama `admin_registrar_alteracao_senha` (migração 0062) com esse login: só a controladoria passa,
  o motivo é obrigatório e o pedido fica no histórico (evento `cadastro_administrativo`, operação `alterar_senha`).
  **A senha nunca é gravada no banco.**
- Só depois a função troca a senha pela API de administração do Supabase. A chave de serviço fica só dentro do
  Supabase (variável automática `SUPABASE_SERVICE_ROLE_KEY`), nunca no painel.

## Para colocar no ar

1. SQL Editor: aplicar `supabase/migrations/0062_senha_pela_controladoria.sql`.
2. Edge Functions › **Deploy a new function** › nome `admin-senha` › colar `supabase/functions/admin-senha/index.ts`
   › Deploy. Deixar **Verify JWT** ligado, como nas outras funções.
3. O painel (Vercel) atualiza sozinho quando a alteração chega na `main`.

## Testes (automatizados, dados fictícios)

- `tests/test_etapa20.py` — 15 verificações: só a controladoria registra; peticionador, líder, diretoria, conta sem
  perfil, sem login e chave de serviço são recusados; motivo obrigatório; nenhuma senha no histórico.
- `tests/admin/testar_senha.mjs` — 21 verificações da Edge Function (Supabase simulado):
  `node --experimental-strip-types tests/admin/testar_senha.mjs` (ou `deno run`).
- `tests/e2e/testar_senha.js` — 11 verificações da tela (banco do `test_etapa20.py` com `MANTER=1`; a função é simulada).

Nenhum teste real ainda: falta publicar a função e aplicar a migração no Supabase.
