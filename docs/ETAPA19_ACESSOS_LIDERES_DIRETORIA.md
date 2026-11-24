# Etapa 19 — Acessos dos líderes e da diretoria (24/11/2026)

Pedido da controladoria em 24/11/2026: criar os acessos do perfil **Líder** (um por equipe) e do perfil **Diretoria**.

## Quem recebe acesso

| Perfil | Equipe | Nome (como está no Atlas) | E-mail |
|---|---|---|---|
| Líder | Prime | Brenda Martins | brendamartinsoecadv@gmail.com |
| Líder | Gold | Raquel Guerra Duarte | raquelguerraoecadv@gmail.com |
| Líder | Celeste | Guilherme Tadeu Ladeia Santos | guilhermeladeiaoecadv@gmail.com |
| Líder | Êxitos | Pedro Frejah | pedrofrejahoecadv@gmail.com |
| Líder | Delta | Ana Clara Andrade Vieira | anaclaraandradeoecadv@gmail.com |
| Líder | Negociações | Leandro Henrique Santana | leandrosantanaoecadv@gmail.com |
| Diretoria | — | Mariana Camilo Silva | marianacamiloadv@gmail.com |
| Diretoria | — | Ana Flávia Reis Caillaux | anacaillauxoecadv@gmail.com |
| Diretoria | — | Bárbara de Castro Silva de Oliveira | barbaracastrooecadv@gmail.com |

Os e-mails foram conferidos com a controladoria em 24/11/2026 (a primeira lista tinha endereços com acento e
no formato `nome@oecadv.gmail.com`, que o Gmail não aceita).

## Como funciona (migração 0061)

- A lista acima fica em `acessos_previstos`.
- Quando uma conta com um desses e-mails é criada no Supabase, o banco cria o perfil sozinho:
  - **Líder:** papel `lider`, ligado à equipe (`lideres_equipes`) e ao colaborador de mesmo nome, se houver um só;
  - **Diretoria:** papel `diretoria`.
- Um perfil que já exista **nunca** é trocado (fica uma observação).
- Tudo vai para o histórico de configurações (`auditoria_configuracao`) com o motivo.
- Um erro nessa etapa nunca impede a criação da conta.

## O que a controladoria precisa fazer

O sistema não cria contas sozinho: criar conta no Supabase exige a chave secreta, que fica só com a controladoria.

1. **Aplicar a migração** `supabase/migrations/0061_acessos_lideres_diretoria.sql` no SQL Editor do Supabase.
2. **Criar as 9 contas:** Supabase › Authentication › Users › **Add user › Send invitation**, um e-mail por vez.
   Cada pessoa recebe o convite e define a própria senha (ninguém digita senha por ela).
3. **Conferir** no SQL Editor do Supabase:
   ```sql
   select email, nome, papel, equipe, aplicado_em, observacao from public.acessos_previstos order by papel desc, equipe;
   ```
   `aplicado_em` preenchido = acesso criado. Vazio = a conta ainda não existe (ou já tinha outro perfil: veja a observação).
   Logada no painel como controladoria, `admin_aplicar_acessos_previstos()` mostra o mesmo com a situação por extenso
   e reaplica o que estiver pendente.
4. **Ligar o colaborador** dos líderes que ficarem com a observação "Colaborador de mesmo nome não encontrado":
   painel › Configurações › Usuários. Sem esse vínculo, o líder já vê as tarefas da equipe dele; o vínculo serve
   para as tarefas em que ele mesmo é o responsável.

## Testes

`tests/test_etapa19.py` — 23 verificações (dados fictícios, banco local): conta criada antes e depois da migração,
e-mail em maiúsculas, equipe com acento, líder sem colaborador, perfil existente preservado, auditoria, permissões
(colaborador e diretoria não leem a lista nem chamam as funções) e recusa de e-mail inválido.

Nenhum teste real foi feito ainda: as contas não existem no Supabase de homologação.
