# Migração do sistema da controladoria para GitHub + Vercel

Versão 2 (19/11/2026). Conferida contra o código real da pasta `Desktop\controladoria`.

## 0. O que a conferência do código mostrou

| Item | Situação | Ação |
|---|---|---|
| Painel (`painel/`) | 100% estático: HTML + JS + CSS, bibliotecas já embutidas em `vendor/`, caminhos relativos, sem etapa de build | **Sobe na Vercel como está** |
| Política de segurança (CSP) do `index.html` | Libera só o próprio site e `*.supabase.co` | Funciona na Vercel sem mudança |
| `iniciar_painel.bat` / `servidor_painel.ps1` | Só servem o painel em `localhost:8080` | Deixam de ser necessários (podem continuar para uso local) |
| Edge Functions | CORS já liberado (`*`) | Nenhuma mudança |
| Extensão do Chrome | Não aponta para o painel; fala direto com o Supabase | **Nenhuma mudança** |
| Login | Só e-mail e senha; não há "esqueci a senha" nem links por e-mail | Ajuste de URL no Supabase é opcional |
| Apps Script (Webjur) | Chama a Edge Function | Nenhuma mudança |
| Pasta do computador não é repositório git | O histórico está em arquivos *bundle* | Ver seção 5.1 |
| `.gitignore` antigo incompleto | Deixava passar `Base de processos 14.11.2026.xlsx` (dados reais) e `.pytest_cache/` | Corrigido neste pacote |
| Bundle de 150 MB em `_backup/` | O GitHub recusa arquivos acima de 100 MB | Ignorado pelo `.gitignore` |
| Supabase é o de homologação (`impoejdocxuihficjvxm`) | O `CLAUDE.md` diz que não existe projeto de produção; o banco já tem dados reais | Ver seção 1.1 |

## 1. O que é o sistema

| Peça | Onde roda | Pasta | Vai para a Vercel? |
|---|---|---|---|
| Banco (migrações 0001–0060, RLS, perfis, auditoria) | Supabase, São Paulo | `supabase/migrations/` | Não |
| Edge Functions `atlas-sync`, `atlas-cadastro`, `cnj-captura`, `webjur-email` | Supabase | `supabase/functions/` | Não |
| 7 agendamentos (pg_cron) + Vault | Supabase | migrações 0042, 0045, 0048, 0050, 0051 | Não |
| Painel | Hoje `localhost:8080` | `painel/` | **Sim** |
| Extensão (v0.7.0, Manifest V3) | Chrome de cada pessoa | `extensao/` | Não |
| Triagem Webjur | Apps Script da conta controladoria | `integracoes/apps_script/` | Não |
| Backup/restauração | Local | `integracoes/backup/` | Não |
| Testes (Python, Node/Playwright, Deno) | Local | `tests/`, `extensao/tests/` | Não |
| Documentação | — | `CLAUDE.md`, `README.md`, `docs/` | — |

**Decisão de arquitetura:** o backend já é o Supabase. A Vercel hospeda só o painel. Não reescrever backend na Vercel: os agendamentos rodam a cada 1–2 minutos, e os cron jobs da Vercel no plano gratuito são muito limitados.

### 1.1 Homologação × produção

O `CLAUDE.md` lista, como "antes da produção": criar um projeto Supabase separado para produção, definir onde o painel roda (é esta migração), ligar a proteção contra senhas vazadas e criar as contas dos colaboradores.

- **A — Assumir o projeto atual como produção:** mais simples, porque o banco já tem os dados reais. Ligar a proteção contra senhas vazadas, confirmar o cadastro público desligado e trocar o comentário "HOMOLOGAÇÃO" nos dois `config.js`.
- **B — Criar o projeto de produção:** seguir `RESTAURAR.md` (passos 2 a 6) e trocar a URL e a chave nos dois `config.js`. Dá para manter a homologação para testes, com um segundo painel na Vercel (branch `homologacao`).

## 2. Segredos — nunca vão para o GitHub

`ATLAS_API_KEY`, `CRON_SECRET` / `atlas_cron_secret`, `WEBJUR_EMAIL_SECRET`, chave secreta `sb_secret_...`, `service_role`, senha do banco / string de conexão.

**Pode ir:** a URL do Supabase e a chave `sb_publishable_...` dos `config.js` (públicas por natureza; quem protege é o login + RLS).

## 3. Dados que nunca vão para o GitHub (sigilo / LGPD)

- `Base de processos 14.11.2026.xlsx` e qualquer exportação real do ADVBOX/Webjur;
- `backup_dados_controladoria_*.json`;
- `_backup/` (bundles, zip, documentação do INPI);
- `restauracao/`;
- saídas reais em `tests/out/`.

As planilhas e CSVs de `tests/e2e/fixtures/` e `tests/webjur/fixtures/` são **fictícios** e podem ir.

## 4. `.gitignore`

Já corrigido neste pacote (ver o arquivo `.gitignore` na raiz). `/*.xlsx` bloqueia planilhas soltas na raiz sem bloquear as fictícias de `tests/`.

## 5. Passo a passo

### 5.1 Git

**Opção simples (histórico novo):** ver `LEIA_PRIMEIRO_GITHUB.md`.

**Opção com o histórico antigo** — na pasta original do computador (`Desktop\controladoria`), no PowerShell:

```
git bundle list-heads _backup\2026-11-18\codigo_controladoria_2026-11-18.bundle
git init -b main
git fetch _backup\2026-11-18\codigo_controladoria_2026-11-18.bundle <branch-que-apareceu-acima>
git reset FETCH_HEAD
git checkout -- tests/e2e/out
git status
```

Depois copie para a pasta o `.gitignore`, o `painel/vercel.json` e este arquivo, e confira o histórico antes de subir:
```
git log --all --name-only --format="" | Sort-Object -Unique | Select-String -Pattern "xlsx|json|csv|bundle|\.env"
git grep -n -I -E "sb_secret_|service_role\"?\s*[:=]|ATLAS_API_KEY\s*=|CRON_SECRET\s*=" $(git rev-list --all)
```
Se aparecer dado real ou segredo: limpar com `git filter-repo` **e trocar o segredo** antes do push.

### 5.2 GitHub
Repositório **privado**, sem README. `git remote add origin ...` e `git push -u origin main`.

### 5.3 Vercel
1. Add New › Project › importar o repositório.
2. **Framework Preset:** Other · **Root Directory:** `painel` · Build, Output e Install vazios.
3. Deploy. Cada `git push` na `main` publica sozinho; outras branches geram link de pré-visualização.
4. `painel/vercel.json` (já incluído) manda `no-store` (ninguém fica com JS antigo em cache) e cabeçalhos de segurança.

### 5.4 Supabase
1. Authentication › Providers › Email: **cadastro público desligado**.
2. Authentication: ligar a **proteção contra senhas vazadas**.
3. Authentication › URL Configuration: URL da Vercel em Site URL (opcional hoje).

### 5.5 Extensão
Nenhuma mudança. Na opção B, trocar URL e chave em `extensao/config.js` e cada pessoa recarrega em `chrome://extensions`.

### 5.6 Backend acompanhando o GitHub (opcional, depois)
A Vercel não aplica migrações nem publica Edge Functions. Se quiser: GitHub Actions com Supabase CLI ou a integração GitHub do Supabase. Recomendação: manter manual por enquanto — erro de migração atinge os dados reais.

## 6. Conferência
- [ ] Repositório **privado**, sem `.xlsx` real, sem `_backup/`, sem segredos.
- [ ] Painel abre na URL da Vercel; login funciona; menus por perfil corretos.
- [ ] Tarefas, intimações, audiências e relatórios carregam.
- [ ] Importação de planilha do ADVBOX funciona pelo navegador.
- [ ] "Testar conexão" com o Atlas ok.
- [ ] Um push de teste aparece publicado em ~1 minuto.
- [ ] Extensão continua abrindo o painel lateral no Atlas.

## 7. Prompt para o Claude Code (aberto na pasta)

> Leia o CLAUDE.md e o docs/MIGRACAO_GITHUB_VERCEL.md. Quero publicar só o painel (`painel/`) na Vercel com deploy automático a partir de um repositório privado no GitHub; o backend continua no Supabase. Parando para eu confirmar antes de qualquer push: (1) inicie o git (seção 5.1); (2) confirme que o `.gitignore` deixa fora planilhas reais, `_backup/`, bundles e caches; (3) verifique se há dados reais ou segredos no que vai ser enviado; (4) rode um servidor estático em `painel/` e confirme que o painel carrega sem erro no console; (5) faça o commit e me diga os cliques no GitHub, na Vercel e no Supabase. Não altere migrações, Edge Functions nem a extensão.
