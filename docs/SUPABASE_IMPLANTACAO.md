# Criação do Supabase de homologação — passo a passo (07/11/2026)

## Situação em 07/11/2026 (feito pelo assistente, via conector do Supabase)

- Projeto **controladoria-homologacao** (`impoejdocxuihficjvxm`, São Paulo): `https://impoejdocxuihficjvxm.supabase.co`.
- Migrações **0001 a 0019** aplicadas sem erro, uma por vez e na ordem.
  - Duas diferenças de texto em relação aos arquivos, com o mesmo resultado final: os comentários longos foram encurtados; a 0016 foi aplicada sem a versão de `double_check_executar`, porque a 0017 a recria por inteiro.
- Conferência no banco remoto:
  - 22 tabelas, **todas com RLS**;
  - 110 dias do calendário e 30 parâmetros;
  - fonte principal e área "Intimações" confirmadas;
  - o papel `anon` não lê tabelas nem executa a importação;
  - 0 usuários.
- **Security Advisor**, tratado na 0019:
  - `search_path` foi fixado em 32 funções;
  - `montar_observacoes_analise` devolvia o teor de qualquer publicação a qualquer usuário logado e passou a ser só interna, assim como `tarefa_canonica`.
- **Avisos mantidos de propósito:**
  - `v_lote_atual` sem `security_invoker`: expõe só número e horário do lote, para o colaborador ver a data de atualização;
  - funções SECURITY DEFINER executáveis por `authenticated`: cada uma confere o perfil antes de agir.
- `painel/js/config.js` e `extensao/config.js` foram preenchidos com a URL e a **chave publicável** (`sb_publishable_...`). A chave secreta não está em nenhum arquivo.
- Testes locais com a 0019: 290/290 OK.

**Concluído em 07/11/2026 (noite):**
- Usuários: mayra.gomes.oecadv@gmail.com (admin) e controladoria.oecadv@gmail.com (colaboradora de teste, ligada a ALICE PACHECO FENOS). O cadastro público foi desligado.
- Primeira importação real: lote 5 com 4 arquivos e 3.568 linhas válidas. São 662 pendentes (agenda a partir de 26/10, decisão da controladoria) e 2.906 concluídas (01/10 a 30/11, em 3 planilhas por causa do limite de 1.000 linhas do ADVBOX). Nenhuma linha rejeitada.
- **0020:** WHERE explícito nos UPDATE. A extensão pg-safeupdate do Supabase recusou a primeira importação.
- **0021 e 0022:** desempenho. Os indicadores passaram de ~13 s para ~3 s, com resultados idênticos (conferidos por hash), e o limite de tempo de "authenticated" passou a 30 s.
- O painel roda no Windows com `iniciar_painel.bat`, um servidor local em PowerShell que não precisa de Python.
- Teste de acesso conferido pela controladoria: a colaboradora vê só as próprias tarefas e alertas, sem as áreas de administrador.

Este roteiro cria o **projeto de homologação**. O projeto de produção segue os mesmos passos depois, num projeto separado.

Os nomes de menu foram conferidos na documentação do Supabase em 07/11/2026 (API Keys). A interface do Supabase muda com frequência: se um nome estiver diferente, procure o equivalente.

## 1. Conta e organização

1. Crie a conta em supabase.com com um **e-mail do escritório** (de preferência, um e-mail da controladoria, não pessoal).
2. Ative a **autenticação em dois fatores** na conta.
3. Crie uma **organização** com o nome do escritório.

O plano **Free** serve para homologação, com uma ressalva: projetos gratuitos são **pausados após dias sem uso**. Para produção, avalie o plano pago.

## 2. Projeto

1. **New project**.
2. **Nome:** `controladoria-homologacao`.
3. **Database password:** crie uma senha forte e guarde no gerenciador de senhas do escritório. Ela não vai para o painel nem para a extensão.
4. **Região:** *South America (São Paulo)*.
5. Aguarde o projeto ficar pronto.

## 3. Banco: aplicar as migrações

1. Abra **SQL Editor** e crie uma consulta nova.
2. Execute, **um arquivo por vez e na ordem**, o conteúdo de `supabase/migrations/`:

   | Arquivos | Etapas |
   |---|---|
   | `0001` a `0006` | Originais |
   | `0007` e `0008` | Etapa 2 |
   | `0009` | Calendário 2026 |
   | `0010` | Importação |
   | `0011` | Indicadores |
   | `0012` | Extensão |
   | `0013` a `0015` | Webjur |
   | `0016` a `0018` | Double check |
   | `0019` | Endurecimento (Security Advisor) |

3. Cada execução deve terminar sem erro. **Se der erro, pare** e me envie a mensagem: não pule o arquivo.
4. **Não execute** `tests/00_stub_supabase_local.sql`. Ele só imita o Supabase no banco local de testes.
5. Para conferir, em **Table Editor** devem aparecer, entre outras, as tabelas `tarefas`, `publicacoes`, `webjur_remessas`, `advbox_intimacoes` e `parametros`. Todas devem estar com **RLS ativado**: o Supabase avisa quando não está.

Também dá para usar o Supabase CLI (`supabase link` e `supabase db push`). O caminho acima não exige instalar nada.

## 4. Autenticação

1. Em **Authentication → Sign In / Providers**:
   - mantenha **Email** ativo;
   - **desligue "Allow new users to sign up"**: só a controladoria cria usuários.
2. Em **Authentication → Users → Add user → Create new user**, crie os usuários com e-mail e senha, marcando **Auto Confirm User**:
   - Mayra (administradora);
   - por enquanto, **um** colaborador de teste.
3. Em **Authentication → URL Configuration**, deixe o **Site URL** como o endereço onde o painel vai rodar. No teste local, `http://localhost:8080`.

## 5. Perfis (quem é administrador e quem é colaborador)

O cadastro de colaboradores é feito pela **importação do Excel** do ADVBOX. Por isso, o perfil de colaborador só pode ser ligado depois da primeira importação.

No **SQL Editor**, execute (troque os e-mails):

```sql
-- administradora
insert into public.perfis (user_id, papel)
select id, 'admin' from auth.users where email = 'EMAIL-DA-MAYRA';

-- colaborador (depois da primeira importação do Excel, que cadastra os colaboradores)
insert into public.perfis (user_id, papel, colaborador_id)
select u.id, 'colaborador', c.id
  from auth.users u, public.colaboradores c
 where u.email = 'EMAIL-DO-COLABORADOR' and c.nome_advbox = 'NOME EXATO COMO NO ADVBOX';
```

Usuário sem perfil entra no painel, mas não vê dados: o banco recusa tudo.

## 6. Chaves: o que pode e o que não pode sair do Supabase

Em **Settings → API Keys** (ou no botão **Connect**), copie:

- a **Project URL** (`https://xxxx.supabase.co`);
- a **chave publicável** (`sb_publishable_...`). A chave legada `anon` também funciona, mas o Supabase anunciou que as chaves legadas serão descontinuadas até o fim de 2026.

**Nunca** use a chave **secreta** (`sb_secret_...`) nem a `service_role` no painel ou na extensão. Elas ignoram o RLS e dariam acesso total a quem abrisse o código.

## 7. Painel

1. Em `painel/js/config.js`, preencha `SUPABASE_URL` com a Project URL e `SUPABASE_ANON_KEY` com a chave publicável.
2. **Teste local:** na pasta `painel`, rode `python3 -m http.server 8080` e abra `http://localhost:8080`.
3. Entre com o usuário administrador e importe um Excel do ADVBOX (área 6).
4. Depois da importação, faça o passo 5 para o colaborador.

A política de segurança do painel já permite conexão só com `https://*.supabase.co`.

## 8. Extensão

1. Em `extensao/config.js`, preencha a mesma URL e a mesma chave publicável.
2. No Chrome, abra `chrome://extensions`, ative o **Modo do desenvolvedor**, clique em **Carregar sem compactação** e selecione a pasta `extensao`.
3. Clique no ícone e entre com o usuário administrador.

## 9. Conferências de segurança antes de usar

- [ ] Logado como **colaborador**, o painel não mostra as áreas de administrador nem publicações.
- [ ] Sem login, a URL `https://xxxx.supabase.co/rest/v1/tarefas` com a chave publicável devolve lista vazia ou recusa, **nunca dados**.
- [ ] O cadastro público de usuários está desligado.
- [ ] A chave secreta não aparece em nenhum arquivo do painel ou da extensão.

## 10. Depois disso (Etapa 10, homologação)

1. Teste das travas da extensão numa **tarefa de teste** autorizada no ADVBOX.
2. Primeira varredura real de "Intimações recebidas" e o double check de um dia completo.
3. Importação diária da planilha do portal Webjur.
