# Backup e reconstrução do sistema da controladoria (18/11/2026)

Este roteiro serve para reconstruir **tudo do zero** — banco, funções, agendamentos, painel e extensão — se algo acontecer com o projeto Supabase, com o computador ou com a pasta.

## O que compõe o backup

| Peça | O que contém | Como gerar |
|---|---|---|
| `codigo_controladoria_AAAA-MM-DD.bundle` | O código com **todo o histórico** (git): migrações, funções, painel, extensão, testes, documentação | Gerado pelo Claude (pasta `_backup`) |
| `codigo_controladoria_AAAA-MM-DD.zip` | Cópia simples da pasta, para abrir sem git | Gerado pelo Claude (pasta `_backup`) |
| `backup_dados_controladoria_AAAA-MM-DD_HHhMM.json` | **Os dados do banco**: todas as tabelas (tarefas, eventos, importações, intimações, audiências, parâmetros, perfis, auditoria…) e as contas (só e-mail e ID) | Painel › Configurações › **Baixar backup dos dados** (só a controladoria) |
| `SHA256SUMS.txt` | Impressão digital de cada arquivo, para conferir que nada se corrompeu | Gerado com o backup do código |

**O que NÃO entra em backup nenhum** (por segurança, fica só com a controladoria):

- senhas das contas;
- a chave da API do Atlas (`ATLAS_API_KEY`);
- os segredos `CRON_SECRET` e `WEBJUR_EMAIL_SECRET` (e o `atlas_cron_secret` do Vault, que tem o mesmo valor do `CRON_SECRET`);
- a chave secreta e a `service_role` do Supabase.

Guarde esses valores num cofre de senhas. Se forem perdidos, gere novos (passo 6).

**Onde guardar:**
- a pasta `_backup` fica dentro da pasta da controladoria, que o OneDrive sincroniza;
- faça também **uma cópia fora**: outro drive, pen drive ou Google Drive do escritório;
- recomendação: baixar o backup dos dados toda semana e depois de cada mudança grande.

**Conferir um arquivo:** no PowerShell, `Get-FileHash <arquivo> -Algorithm SHA256`. O resultado deve ser igual ao do `SHA256SUMS.txt`. Para o backup dos dados, deve ser igual ao código que o painel mostra ao terminar.

## Reconstrução passo a passo

### 1. Código

```
git clone codigo_controladoria_AAAA-MM-DD.bundle controladoria
```

Sem git: descompacte o `.zip`.

O `CLAUDE.md` da pasta resume todo o contexto. Se for usar o Claude Code, ele lê esse arquivo sozinho.

### 2. Projeto Supabase novo

1. Em supabase.com, crie o projeto (região **São Paulo**). Anote:
   - o **id do projeto** (20 letras, aparece na URL);
   - a senha do banco (você mesma digita; não fica em arquivo).
2. **Authentication › Providers › Email:** desligue o **cadastro público** ("Allow new users to sign up").
3. **Authentication:** ligue a proteção contra senhas vazadas.
4. **Database › Extensions:** confira se `pg_cron` e `pg_net` estão disponíveis. As migrações as ligam.

### 3. Banco: migrações (todas, em ordem)

No PowerShell, dentro da pasta `controladoria`:

```powershell
$env:CONEXAO = "postgresql://postgres:<SENHA>@db.<ID>.supabase.co:5432/postgres"
Get-ChildItem supabase\migrations\*.sql | Sort-Object Name | ForEach-Object {
  Write-Host $_.Name; psql $env:CONEXAO -v ON_ERROR_STOP=1 -q -f $_.FullName; if ($LASTEXITCODE -ne 0) { throw "Parou em $($_.Name)" } }
```

- **De onde vem a conexão:** a string de conexão está em Settings › Database › Connection string. Troque `<SENHA>` e `<ID>`.
- **Precisa do psql:** se ainda não estiver instalado, ele vem no instalador do PostgreSQL.
- **Avisos esperados:** mensagens como "agendamento não criado" são normais nesse momento. Os agendamentos são criados no passo 5.

### 4. Dados

1. **Contas:** em Authentication › Users, crie as contas com **os mesmos e-mails** do backup. A lista está no `conferencia.txt`, gerado no item 2. Cada pessoa define a própria senha.
2. **Gerar os arquivos de restauração:**
   ```
   python integracoes\backup\restaurar_dados.py backup_dados_controladoria_AAAA-MM-DD_HHhMM.json restauracao
   ```
   Isso gera, na pasta `restauracao`: `1_restaurar_dados.sql`, `2_remapear_usuarios.sql` e `conferencia.txt`.
3. **Gravar os dados:**
   ```
   psql $env:CONEXAO -f restauracao\1_restaurar_dados.sql
   ```
   - Roda numa transação só: ou grava tudo, ou nada.
   - No fim, confere a quantidade de linhas de cada tabela e mostra "Restauração concluída".
4. **Ligar as contas novas aos dados:**
   ```
   psql $env:CONEXAO -f restauracao\2_remapear_usuarios.sql
   ```
   - O script troca o ID antigo de cada conta pelo novo, procurando pelo e-mail.
   - Se faltar alguma conta, ele para e diz qual.

### 5. Segredos e agendamentos

1. **Vault:** em Project Settings › Vault, crie o segredo `atlas_cron_secret`, com um valor longo e aleatório. Guarde-o: é o mesmo valor do `CRON_SECRET` do item 6.
2. **Apontar o banco para o projeto novo e recriar os 7 agendamentos:**
   ```
   psql $env:CONEXAO -v ref=<ID> -v chave_anon=<chave anon> -f integracoes\backup\3_apontar_novo_projeto.sql
   ```
   - A chave anon é a legada, que começa com `eyJ`, em Settings › API.
   - Os agendamentos recriados, todos ativos como em 18/11/2026:

| Agendamento | Quando |
|---|---|
| fim do expediente | 18:30, dias úteis |
| carteira do CNJ | 23:45 |
| lotes do CNJ | a cada 2 min, das 0h às 6h |
| OAB no CNJ | 6:20 e 17:20 |
| cadastro no Atlas | a cada minuto, só com processos aprovados |
| clientes do Atlas | 23:40 |
| audiências | a cada hora |

### 6. Edge Functions e seus segredos

1. Com o **Supabase CLI**, na pasta `controladoria`:
   ```
   supabase login
   supabase functions deploy atlas-sync --project-ref <ID>
   supabase functions deploy webjur-email --project-ref <ID>
   supabase functions deploy cnj-captura --project-ref <ID>
   supabase functions deploy atlas-cadastro --project-ref <ID>
   ```
   Todas ficam com a verificação de login (JWT) ligada, que é o padrão.
2. Em **Edge Functions › Secrets**, crie:

| Segredo | Valor |
|---|---|
| `ATLAS_API_KEY` | A chave da API do Atlas. Se perdida: Atlas › Configurações › Integrações › API do Atlas › **Nova chave** |
| `CRON_SECRET` | O **mesmo** valor do `atlas_cron_secret` do Vault |
| `WEBJUR_EMAIL_SECRET` | O segredo do e-mail da Webjur (o mesmo do script do Gmail) |

- **Opcionais:** `ATLAS_API_URL`, `CNJ_API_URL`, `ATLAS_PAUSA_MS` e `CNJ_PAUSA_MS`. Sem eles valem os padrões do código.
- **Permissões da chave do Atlas:** listar tarefas, criar, concluir, editar e comentar tarefas; consultar clientes e processos; gravar processos; listar prazos e intimações. Depois do passo 7, o botão **Testar conexão** do painel mostra as permissões ligadas.

### 7. Painel

1. Em `painel\js\config.js`, troque a URL e a **chave publicável** pelas do projeto novo. Elas estão em Settings › API.
2. Abra com `iniciar_painel.bat` e entre com a conta da controladoria.
3. Em **Sincronização com o Atlas**, clique em **Testar conexão** e depois em **Sincronizar**.

### 8. Extensão

1. Em `extensao\config.js`, troque a mesma URL e a mesma chave publicável.
2. Abra `chrome://extensions` › **Modo do desenvolvedor** › **Carregar sem compactação** › escolha a pasta `extensao`. Cada pessoa da equipe faz isso.
3. Entre com a conta do sistema da controladoria (não é a conta do Atlas).

### 9. E-mail da Webjur (Apps Script)

1. Na conta controladoria.oecadv@gmail.com, abra o projeto do Apps Script.
2. Em `URL_FUNCAO`, troque o endereço pelo do projeto novo: `https://<ID>.supabase.co/functions/v1/webjur-email`.
3. Confira a propriedade `WEBJUR_SECRET`.

O script está em `integracoes\apps_script\triagem_webjur.gs`.

### 10. Conferência final

- [ ] O painel abre e mostra as tarefas.
- [ ] "Testar conexão" com o Atlas está ok.
- [ ] Uma sincronização foi feita sem erro.
- [ ] As Configurações mostram os parâmetros e os perfis. A quantidade bate com o `conferencia.txt`.
- [ ] No dia seguinte, o Log de integração mostra a rotina das 18:30 e a captura do CNJ.
- [ ] A extensão abre o painel lateral numa tarefa do Atlas.
- [ ] Opcional: com PostgreSQL local, rode a bateria de testes, que usa só dados fictícios (ver `CLAUDE.md`).

## Testes do backup (18/11/2026)

- **`tests/e2e/testar_backup.js`**, com 23 verificações, faz o ciclo inteiro com dados fictícios:
  - baixa o backup pela tela e confere a impressão digital;
  - cria um banco novo só com as migrações;
  - restaura e compara **tabela por tabela** (quantidade e conteúdo) com o banco de origem;
  - restaura de novo, com o mesmo resultado;
  - recria as contas com outros IDs e confere que nenhum ID antigo sobra;
  - confere que o histórico continua imutável e que os contadores de ID foram acertados;
  - confere as permissões: peticionador, líder, rotina e anônimo não baixam o backup.
- **Erro encontrado pelo teste e corrigido antes do banco real:** nos campos JSON, o valor "null" do JSON e o campo vazio ficavam iguais no arquivo, e a restauração falhava no parâmetro `tratativa_monitorada_desde`. O backup agora marca os campos realmente vazios.
- **Banco real (18/11/2026, só leitura):**
  - 46 tabelas e 37.455 linhas;
  - a página mais pesada (histórico de importações) leva 1,3 s;
  - o backup completo leva cerca de 1 minuto e gera um arquivo de uns 25 MB.
- **O que não pôde ser testado aqui:** a recriação dos agendamentos do passo 5. O banco de teste não tem o `pg_cron`. O script repete o código das migrações 0042, 0045, 0048, 0050 e 0051, que já rodou no banco real. A troca dos endereços foi testada.
