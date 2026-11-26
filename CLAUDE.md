# CLAUDE.md — Controladoria Jurídica Oliveira e Camilo

Sistema de controladoria jurídica do escritório Oliveira e Camilo (carteira bancária). Responsável: Mayra (controladoria, administradora do sistema).
Este arquivo é lido pelo Claude Code ao abrir a pasta. Ele resume o contexto construído na fase de implantação e homologação (05/11 a 11/11/2026).

## Atenção: desde 11/11/2026 o sistema principal é o Atlas Gestor

As tarefas vêm do **Atlas Gestor** (gestor.atlasjus.com) pela API dele, e não mais do Excel do ADVBOX. O ADVBOX fica como histórico. Veja `docs/ETAPA11_ATLAS.md`.

- **Sincronização:** Edge Function `supabase/functions/atlas-sync` (Deno).
  - Lê `list_tasks` e grava um lote pela mesma `importar_arquivo`.
  - A chave do Atlas fica só no segredo `ATLAS_API_KEY`.
  - A API do Atlas é `POST https://tdhgpaurcjinhbandmvb.supabase.co/functions/v1/client-webhook`, com header `x-api-key` e corpo `{action, data}`. Limite de 60 chamadas por minuto. Paginação com `limit` (1–100) e `cursor`/`nextCursor`.
- **Identificação:** a tarefa do Atlas tem chave `AT:<uuid>`. O uuid fica em `tarefas.atlas_id` e também em `tarefas.advbox_id`, o "ID externo" que a extensão usa.
- **Extensão 0.7.0 no Atlas (0.6.0 + justificativa na conclusão e "em andamento" = início):**
  - `atlas_ponte.js` roda no mundo da página e envolve o `fetch` do app para segurar as gravações em `/rest/v1/tasks`, `/rest/v1/task_assignees` e `rpc/complete_task_assignee_tx` ("Dar baixa na minha parte") do Supabase do Atlas;
  - `atlas_content.js` decide e registra;
  - as regras puras ficam em `lib/atlas_regras.js`.
- **Líderes:** papel `lider` em `perfis`. Na extensão, os modos de realocação e de PF viram `lider_livre`, e o evento é gravado como `excecao_autorizada`.
- **Prazos (confirmado em 11/11/2026):** prazo fatal do Atlas = PF Judicial; D-4 = data de entrega do advogado (PF − 3 dias úteis); D-7 = primeira data da tarefa na agenda (vencimento no Atlas).
- **Exceção de D-4 (0037):** líder ou controladoria autoriza, com justificativa, a entrega depois do D-4 (janela da tarefa no Atlas ou Prazos em risco). Evento `excecao_d4` (append-only; retirar = novo evento). A tarefa sai dos alertas de D-4 e de "Críticas em D-4"; o PF Judicial continua valendo.
- **Tarefas de análise:** destino em `parametros.tarefa_analise_destino` (`atlas` ou `advbox`). No Atlas, são criadas por `create_task` com `Idempotency-Key`.
- **Pedidos da Dra. Mariana (0038–0043, `docs/ETAPA12_PEDIDOS_MARIANA.md`):** perfis diretoria/líder (equipes em `lideres_equipes`)/peticionador; `is_admin()` também vale para a chave de serviço (rotina agendada, `_eh_servico()`); modalidades com checklist e anexos (bucket `pecas`, pasta = id da tarefa) e trava de conclusão; descrição padrão no Atlas entre marcadores (`mapear.js` `semBloco`/`comBloco`); planejamento (`analisar_pauta`) e `solicitacoes`; double check Webjur × Atlas (`atlas_intimacoes`, `inconsistencias`, `relatorios_diarios`).
- **E-mail diário da Webjur (12/11/2026, `docs/ETAPA13_WEBJUR_EMAIL.md`):** script Apps Script na conta controladoria.oecadv@gmail.com (`integracoes/apps_script/triagem_webjur.gs`, 13h e 17h) envia os e-mails de webjur@webjur.com.br à Edge Function `webjur-email` (segredo `WEBJUR_EMAIL_SECRET`), que lê com a cópia de `painel/js/webjur_email.js` (manter idênticas) e registra por `pub_registrar_remessa` (origem `webjur_gmail`). Contagem divergente não é registrada sozinha.
- **Intimações do CNJ (12/11/2026, 0044–0047, `docs/ETAPA14_INTIMACOES_CNJ.md`):** em 12/11 o escritório não tinha o módulo de intimações do Atlas; **em 16/11 ele foi ativado (0054, `atlas_modulo_intimacoes` = true)** e o double check voltou a comparar Webjur × Atlas, mantendo o CNJ. A Edge Function `cnj-captura` consulta a API pública do DJEN (`comunicaapi.pje.jus.br`) por OAB (`cnj_oabs`) e varre todo dia a carteira (`cnj_carteira`: processos do Atlas via `list_lawsuits` + `processos`), gravando em `cnj_comunicacoes`. O "Identificador do documento" da Webjur = id da comunicação no CNJ. O double check usa `_dc_cnj` (tipo `captura_divergente`). Agendamentos `controladoria_cnj_*` (pg_cron).
- **Cadastro de processos no Atlas (14/11/2026, 0048, `docs/ETAPA15_CADASTRO_PROCESSOS_ATLAS.md`):** a controladoria importa a exportação de processos do ADVBOX; o banco casa cada processo com um cliente que já existe no Atlas (`atlas_clientes`, lidos por `list_clients`: CPF/CNPJ > código "C362" > nome) e monta a prévia (`atlas_cadastro`). Só o aprovado é enviado: a Edge Function `atlas-cadastro` confere `list_lawsuits` e cria com `create_lawsuit` + `Idempotency-Key`. Cliente não encontrado só é listado (o robô não cria cliente). Não há exclusão pela API do Atlas. Equipes e líderes (0049, `equipes_lideres`): Prime = Brenda Martins, Gold = Raquel Guerra, Celeste = Guilherme Ladeia, Êxitos = Pedro Frejah, Delta = Ana Clara, Negociações = Leandro Santana. Bárbara Castro é diretoria.
- **Relatórios gerenciais (16/11/2026, 0056–0057, `docs/ETAPA17_RELATORIOS_GERENCIAIS.md`):** `relatorio_gerencial(área, início, fim)` devolve indicadores e pizzas de cada menu (só controladoria e diretoria; `_rg_pizza`, `_rg_num` e `_rg_media` são internas, fechadas ao usuário). O painel (`painel/js/relatorios.js`) põe um bloco recolhível "Relatório gerencial" abaixo do título de cada área: até 6 fatias (o resto vira "Outros"), legenda com quantidade e %, tabela, dica ao passar o mouse, período e "Imprimir / PDF". Paleta categórica validada no claro e no escuro (`--cat-1`…`--cat-6` no CSS). Área nova no menu = incluir um `when` na função (nova migração) e o id em `AREAS_COM_RELATORIO`.
- **Conclusão, andamento e reagendamento (17/11/2026, 0058–0059, extensão 0.7.0, `docs/ETAPA18_CONCLUSAO_ANDAMENTO_REAGENDAMENTO.md`):** a API do Atlas não barra conclusão (nem reabre); a extensão 0.7.0 pede justificativa ao concluir/dar baixa (`ext_status_tarefa.conclusao_exige_justificativa`) e o servidor reclassifica a conclusão sem justificativa; rede de segurança no double check (`_dc_conclusoes`, tipo `conclusao_sem_justificativa`, a partir de `atlas_conclusao_justificativa_desde`). "Em andamento" (`doing`) no Atlas = início da tratativa (`atlas_registrar_em_andamento`, chamada pela `atlas-sync` v9; a extensão registra na hora). Peticionador pede reagendamento (`solicitacao_reagendamento_pedir`): até o D-4 decide o líder (status `aguardando_lider`), depois do D-4 só a controladoria; `_solicitacoes_escalar` sobe o que passa do D-4.
- **Audiências (14/11/2026, 0051–0053, `docs/ETAPA16_AUDIENCIAS.md`):** `_audiencia_extrair` lê o texto das intimações (`cnj_comunicacoes` e `publicacoes`) e grava `audiencias` (uma por processo + data + hora, várias fontes em `audiencia_fontes`); sem data na intimação = "sem data" até completar. Pendências (`_audiencia_pendencias`) no painel e no double check (`_dc_audiencias`, tipo `audiencia_pendente`). Equipe pela letra do código do cliente (`equipes_por_letra`, confirmada em 16/11; equipe "A" extinta). Pendência "sem tarefa no Atlas" desligada (`audiencias_cobrar_tarefa_atlas` = false, 0055) até a equipe usar o Atlas para audiências. Agendamento `controladoria_audiencias` (a cada hora). Releitura sem apagar: `_audiencias_reler` (situação `descartada`).
- **Acessos dos líderes e da diretoria (24/11/2026, 0061, `docs/ETAPA19_ACESSOS_LIDERES_DIRETORIA.md`):** `acessos_previstos` guarda e-mail, nome, papel e equipe dos 6 líderes e das 3 pessoas da diretoria; o gatilho `controladoria_acesso_previsto` em `auth.users` cria o perfil (e `lideres_equipes`) quando a conta aparece, sem nunca trocar perfil existente. As contas são criadas pela controladoria no Supabase (Create new user, com senha e Auto Confirm). `admin_aplicar_acessos_previstos()` mostra a situação e reaplica.
- **Senha definida pela controladoria (26/11/2026, 0062, `docs/ETAPA20_SENHA_PELA_CONTROLADORIA.md`):** as pessoas não criam a própria senha. Configurações › Usuários › "Definir senha" chama a Edge Function `admin-senha`, que confere o perfil e registra o pedido por `admin_registrar_alteracao_senha` (com o token de quem pediu; a senha não é gravada) e troca pela API de administração do Auth. Não usar "Send invitation": não há tela de criar senha pelo convite.
- **Nunca usar a sessão do usuário no Atlas** para ler dados por fora da API. Ler a interface só para entender a tela, sem salvar nada.

## Backup e reconstrução (18/11/2026, 0060, `docs/RESTAURAR.md`)

- **Código:** `git bundle` com todo o histórico + `.zip` da pasta + `SHA256SUMS.txt`, na pasta `_backup/AAAA-MM-DD/` (gerados pelo Claude; não versionados).
- **Dados:** painel › Configurações › "Baixar backup dos dados" (`backup_tabelas`, `backup_tabela`, `backup_usuarios`; só a controladoria com login, nunca a chave de serviço). Campos json/jsonb vazios vão em `__sql_nulos`. Restauração: `integracoes/backup/restaurar_dados.py` gera `1_restaurar_dados.sql` (transação única, sem gatilhos, confere as contagens) e `2_remapear_usuarios.sql` (troca IDs de conta pelo e-mail); `integracoes/backup/3_apontar_novo_projeto.sql` troca endereços e recria os 7 agendamentos. Teste: `tests/e2e/testar_backup.js` (ciclo completo, banco do `test_etapa18.py` com `MANTER=1`).
- **Fora do backup (ficam com a controladoria):** senhas, `ATLAS_API_KEY`, `CRON_SECRET` (= Vault `atlas_cron_secret`), `WEBJUR_EMAIL_SECRET`, chave secreta/service_role.

## O que é

- **Banco:** Supabase (PostgreSQL) com RLS em todas as tabelas. Toda a regra de negócio fica em funções SQL (`supabase/migrations/`).
- **Painel:** `painel/`, HTML/JS sem build. Roda local com `iniciar_painel.bat` (chama `servidor_painel.ps1`). O menu é agrupado por sistema (`GRUPOS` em `app.js`): Acompanhamento, Atlas Gestor, Publicações e intimações, ADVBOX (histórico) e Administração; os parâmetros nas Configurações têm filtro pelo mesmo critério.
- **Identidade visual (16/11/2026):** cores e logotipo do escritório. Grafite `#323232` e dourado; tokens no topo de `painel/css/painel.css` (`--grafite`, `--ouro`, `--ouro-texto`, `--ouro-gradiente`). Logotipo e ícones em `painel/img/` (gerados do PNG oficial). Títulos em Gloock (licença OFL, arquivos locais em `painel/fontes/`, porque a CSP só permite `'self'`). Contrastes de texto ≥ 4,5:1 no claro e no escuro. As cores de estado e a paleta dos gráficos não mudam.
- **Extensão Chrome (MV3):** `extensao/`, versão 0.4.3. Atua na tela do ADVBOX: início da tratativa, travas, leitura de "Intimações recebidas" e criação automática das tarefas de análise. Instruções em `extensao/LEIAME.md`.
- **Não existe API do ADVBOX.** Os dados entram por três caminhos:
  - exportação Excel do ADVBOX, importada no painel;
  - leitura da tela pela extensão;
  - publicações da Webjur (CSV do portal como fonte principal; e-mail diário como contingência).

## Documentos para ler primeiro

1. `docs/ETAPA10_HOMOLOGACAO.md` — situação atual:
   - testes reais R1–R21;
   - erros E1–E21 e as correções;
   - pendências P2–P6;
   - limitações;
   - parâmetros confirmados.
2. `docs/SUPABASE_IMPLANTACAO.md` — implantação do banco.
3. `docs/ETAPA2_BANCO.md` a `docs/ETAPA9_AUDITORIA_SEGURANCA.md` — cada módulo.
4. `docs/DIAGNOSTICO_EXCEL_E_DECISOES.md` — formato do Excel do ADVBOX e decisões de identificação das tarefas.

O `README.md` tem a estrutura geral, mas a tabela de etapas dele está desatualizada. Vale o `docs/ETAPA10_HOMOLOGACAO.md`.

## Ambiente

- **Supabase de homologação:**
  - projeto `controladoria-homologacao`, id `impoejdocxuihficjvxm`, São Paulo;
  - URL `https://impoejdocxuihficjvxm.supabase.co`;
  - a chave publicável está em `painel/js/config.js` e `extensao/config.js`.
- **Migrações:** 0001 a 0062 (a 0042 criou o agendamento das 18:30, ligado em 11/11; a 0045, os da captura do CNJ; a 0054 registrou o módulo de intimações do Atlas ativado em 16/11 — veja `docs/ETAPA14_INTIMACOES_CNJ.md`), todas aplicadas no banco de homologação (a 0062 e a função `admin-senha` em 26/11), em ordem numérica. Não existe projeto de produção ainda.
- **Edge Functions:** `atlas-sync` (11/11/2026), `webjur-email` e `cnj-captura` (12/11/2026) e `atlas-cadastro` (14/11/2026) e `admin-senha` (26/11/2026), todas com `verify_jwt` ligado.
- **Usuários:** login por e-mail e senha no Supabase Auth, com cadastro público desligado. Perfis em `perfis`:
  - `admin` = controladoria;
  - `colaborador` = vê só as próprias tarefas.

## Regras de segurança (decididas pela controladoria — não mudar sem ela pedir)

- **Senhas:**
  - nunca digitar senhas;
  - a Mayra faz login ela mesma no ADVBOX, na Webjur e no Supabase.
- **Chaves:**
  - nunca colocar a chave secreta (`sb_secret_...`) ou a `service_role` no painel ou na extensão;
  - no navegador, só a chave publicável.
- **ADVBOX:**
  - testes só em tarefas de teste ou no processo "TESTE 1.0";
  - não alterar tarefas reais sem autorização;
  - perguntar antes de qualquer ação que notifique colegas, como encaminhar ou criar tarefa para outra pessoa.
- **Relatórios:**
  - nunca apresentar teste simulado como teste real;
  - nos relatórios, testes reais e automatizados ficam separados.
- **Integrações e resultados:**
  - não inventar integrações nem resultados;
  - conferir antes de afirmar.

## Como mexer no banco

- **Toda mudança vira uma nova migração** numerada (`0035_...sql`). Migrações já aplicadas não são editadas.
- **Funções longas:** para mudar um trecho de uma função grande, use o padrão das migrações 0033 e 0034:
  - `pg_get_functiondef`, depois `replace` de um trecho-âncora único e depois `execute`;
  - um marcador em comentário torna a migração idempotente;
  - a migração aborta se a âncora não for encontrada.
- **Restrições do Supabase que já causaram erros reais:**
  - `pg-safeupdate`: todo `UPDATE` precisa de `WHERE`; use `where true` quando for intencional (E1);
  - **tempo limite de 30 s** para o papel `authenticated`. Erros E2, E16, E19 e E21 foram consultas que passaram disso. Antes de aplicar mudança em visão ou função pesada:
    - meça o tempo no banco real;
    - compare o resultado antes e depois (hash `md5` do resultado);
  - comparação de listas de palavras: use `intersect`, não `w = any(array)`, porque o segundo é quadrático (E21).
- **Funções SECURITY DEFINER:**
  - sempre `set search_path = public`;
  - sempre a checagem de perfil (`is_admin()` ou equivalente);
  - `revoke` de `public` e `anon`.
  - Funções internas (prefixo `_`) não ficam expostas a `authenticated`.
- **Auditoria:**
  - tabelas de auditoria e histórico são imutáveis (triggers de UPDATE/DELETE/TRUNCATE);
  - mudanças em `parametros`, `perfis`, `calendario`, `colaboradores` e `equipes` exigem motivo; ver `admin_definir_parametro` e `_exigir_motivo`, na 0029.
- **Testar como administradora no banco real** (somente leitura, desfeito no fim):
  ```sql
  begin; set local statement_timeout='55s';
  select set_config('request.jwt.claims', json_build_object('sub',(select user_id from perfis where papel='admin' limit 1),'role','authenticated')::text,true);
  set local role authenticated;
  -- consulta aqui
  rollback;
  ```

## Importação do Excel (pontos sensíveis)

- **Identificação das tarefas:** a chave estável (`chave_estavel`) usa compromisso, remetente, partes, processo, tipo de ação e o 1º parágrafo das Observações.
- **Remetente:** o ADVBOX troca o Remetente quando a tarefa é encaminhada. A 0033 liga a tarefa sem o Remetente quando há um único par possível. Pares ambíguos ficam separados de propósito.
- **"Editar tarefa":** no ADVBOX, recria a tarefa com outro ID. A 0023 liga a nova à original.
- **Linhas por processo:** o ADVBOX lista o mesmo processo uma vez por parte, todas com o mesmo ID de processo (lawsuit).
- **Linhas importadas são imutáveis.** Comparações entre importações ficam em `_gerar_eventos_importacao`.

## Testes automatizados

Usam dados fictícios num PostgreSQL 16 local. São 1.404 verificações em 46 suítes, todas passando em 26/11/2026 (a `test_etapa12.py` depende do dia: 5 verificações de "D-4 hoje" só fecham em dia útil). O teste da Edge Function (`tests/atlas/testar_edge.js`) precisa do Deno (variável `DENO`).

- **Banco:** `python tests/run_tests.py`, `tests/test_calendario.py`, `tests/test_etapa2.py`, `test_etapa4.py` a `test_etapa14.py` e `tests/auditoria_hipoteses.py`.
- **Extensão:** `node extensao/tests/testar_extensao.js`, `testar_intimacoes.js` e `testar_criacao.js` (precisam de `playwright`).
- **Captura do CNJ:** `deno run --allow-env tests/cnj/testar_captura.ts`.
- **Cadastro no Atlas:** `deno run --allow-env tests/atlas/testar_cadastro.ts`; a tela (`tests/e2e/testar_cadastro_atlas.js`) usa o banco do `test_etapa15.py` rodado com `MANTER=1`.
- **Leitor Webjur:** `node tests/webjur/testar_leitor.js`, `node tests/webjur/testar_script_gmail.js` e `deno run --allow-read --allow-env tests/webjur/testar_funcao_email.ts`.
- **Painel ponta a ponta:** `tests/e2e/testar_*.js`. Precisam de `npm install` em `tests/e2e` e de `playwright`.
- **Conexão local:** os scripts conectam em `psql -h /tmp -p 5433 -U postgres`, o socket do ambiente Linux onde foram escritos. No Windows, ajustar host e porta, de preferência por variável de ambiente.
- **Isolamento:** cada suíte cria e apaga o próprio banco local (`ctrl_*`). Nenhum teste automatizado toca o Supabase real.

## Situação da homologação (11/11/2026)

- **Testes reais:**
  - 21 aprovados (R1–R21);
  - 21 erros encontrados e corrigidos (E1–E21);
  - os 16 parâmetros provisórios foram confirmados pela controladoria em 10/11.
- **Travas:** conclusão sem início, realocação e prazo fatal estão todas em modo **bloquear**.
- **Pendentes:**
  - **P2** — segundo ciclo diário completo: CSV da Webjur do dia, varredura de "Intimações recebidas" cobrindo o dia da disponibilização e o seguinte, e double check. O double check de 10/11 foi corrigido (E21); faltava a varredura cobrindo 10/11–11/11;
  - **P3** — extensão sem internet;
  - **P4** — extensão sem login;
  - **P5** — extensão usada por colaborador;
  - **P6** — e-mail da Webjur como contingência. Nenhum e-mail da Webjur chegou ao Gmail até 10/11; a regra de encaminhamento pode não estar ativa.
- **Antes da produção:**
  - revisar os limiares do double check depois do P2;
  - criar um projeto Supabase separado para produção;
  - definir onde o painel vai rodar;
  - ligar a proteção contra senhas vazadas;
  - criar as contas dos colaboradores.

## Fatos do ADVBOX úteis para a extensão

- **Tarefa de análise:**
  - tipo "ANÁLISE DO CASO (50 pts)", id 8849391; ela move o processo para NEGOCIAÇÃO / ANÁLISE DO CASO, o que foi aceito;
  - usuária responsável: Mayra, id 296462.
- **Criar tarefa já com responsável:** `posts/create?responsible=296462` abre o formulário com o responsável preenchido.
- **Campos select2:** são acionados por eventos `mousedown`/`mouseup`.
- **Janela da tarefa:** fecha em `a.close.material-icons`; o `?t=ID` na URL traz o ID da tarefa criada.
- **Tarefa sem o botão "Concluir"** (a usuária não é a responsável): a extensão não abre o painel nem monitora.

## Histórico de versões (git)

O histórico completo (commits de 05/11 a 11/11/2026) veio no arquivo `historico_git.bundle`, porque a pasta `.git` não pôde ser gravada à distância. Se esta pasta ainda não for um repositório git, restaure assim, dentro dela:

```
git init -b master
git fetch historico_git.bundle master
git reset FETCH_HEAD
git checkout -- tests/e2e/out
git status
```

O `git checkout -- tests/e2e/out` repõe as capturas de tela dos testes exatamente como no histórico (na cópia para o computador elas foram recompactadas: imagem idêntica, bytes diferentes). Depois disso, o `git status` deve mostrar só arquivos não rastreados (caches de teste) e o `CLAUDE.md` como modificado, se ele tiver sido editado depois. Depois disso, o `historico_git.bundle` pode ser apagado; ele já está no `.gitignore`.

## Convenções

- Textos para a usuária e documentação em português do Brasil, sem jargão técnico desnecessário.
- Commits com mensagem em português descrevendo o achado real e a correção.
