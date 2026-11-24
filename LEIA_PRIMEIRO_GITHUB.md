# Pacote do sistema da controladoria para o GitHub (19/11/2026)

Este pacote é a pasta `controladoria` completa (código, banco, funções, extensão, integrações, testes e documentação), já preparada para um repositório **privado** no GitHub e para publicar o painel na Vercel.

## O que foi ajustado em relação à pasta do computador
- `.gitignore` corrigido: bloqueia planilhas reais na raiz, backups (`_backup/`, `*.bundle`, `backup_dados_*.json`), `restauracao/`, caches e segredos.
- `painel/vercel.json` criado (sem cache + cabeçalhos de segurança).
- Removido `tests/e2e/out/backup/` (arquivo de backup gerado pelos testes).
- **Não estão aqui** (de propósito): `Base de processos 14.11.2026.xlsx`, a pasta `_backup/` e os arquivos `.bundle`.

## Estrutura
| Pasta | O que é | Onde roda |
|---|---|---|
| `painel/` | Painel web (HTML/JS/CSS estático) | **Vercel** (Root Directory = `painel`) |
| `supabase/migrations/` | Banco: migrações 0001–0060 | Supabase |
| `supabase/functions/` | Edge Functions atlas-sync, atlas-cadastro, cnj-captura, webjur-email | Supabase |
| `extensao/` | Extensão do Chrome (ADVBOX + Atlas) | Chrome de cada pessoa |
| `integracoes/apps_script/` | Triagem do e-mail da Webjur | Apps Script da conta da controladoria |
| `integracoes/backup/` | Restauração de dados | Local |
| `tests/` | Testes automáticos (dados fictícios) | Local |
| `docs/` | Documentação de cada etapa | — |
| `CLAUDE.md` | Contexto completo para o Claude Code | — |

## Subir para o GitHub
1. Descompacte o .zip.
2. Crie um repositório **privado** no GitHub (sem README).
3. No PowerShell, dentro da pasta `controladoria`:
   ```
   git init -b main
   git add .
   git status
   git commit -m "Sistema da controladoria"
   git remote add origin https://github.com/<usuario>/<repositorio>.git
   git push -u origin main
   ```
   Confira no `git status` que nenhuma planilha real ou backup aparece.

(Este caminho começa um histórico novo. O histórico antigo continua guardado no `.bundle` da pasta `_backup` do computador. Se quiser levar o histórico antigo para o GitHub, use o passo 5.1 de `docs/MIGRACAO_GITHUB_VERCEL.md` na pasta original.)

## Vercel
Add New › Project › importar o repositório · Framework **Other** · Root Directory **`painel`** · campos de build vazios · Deploy. Cada push publica sozinho.

## Supabase (antes de passar o link à equipe)
- Cadastro público **desligado**.
- Proteção contra senhas vazadas **ligada**.

Detalhes completos: `docs/MIGRACAO_GITHUB_VERCEL.md`.
