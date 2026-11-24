# Etapa 11 — Atlas Gestor como sistema principal (11/11/2026)

**Decisão da coordenação:**
- O Atlas Gestor (gestor.atlasjus.com) passa a ser o sistema de gestão principal.
- As tarefas da equipe passam a ser as do Atlas. O ADVBOX fica como histórico.
- Todas as funcionalidades da controladoria continuam.
- **Única mudança de regra:** os líderes podem alterar as tarefas sem bloqueio. São eles Brenda Martins, Pedro Frejah, Raquel Guerra, Guilherme Ladeia e Ana Clara.

**Decisões tomadas com a controladoria em 11/11/2026:**
- **Painel:** continua próprio (o Atlas não permite telas de terceiros) e é ligado ao Atlas pela API.
- **Tarefas:** vêm do Atlas.
- **Travas:** a extensão passa a atuar também na tela do Atlas.

## Como funciona

| Parte | O que faz | Onde está |
|---|---|---|
| Sincronização | O botão **Sincronizar com o Atlas** (área "Tarefas: Atlas e Excel" do painel) lê no Atlas as tarefas abertas e as concluídas nos últimos 90 dias (`list_tasks`) e grava uma **fotografia** da base, exatamente como a importação do Excel. Indicadores, D-4/D-7, reagendamentos, trocas de responsável e de prazo fatal continuam iguais. | Edge Function `atlas-sync` + migração 0035 |
| Identificação | Cada tarefa é identificada pelo **ID do Atlas**: não há mais chave por texto, Remetente que muda nem linha ambígua. | 0035 (`AT:<uuid>`) |
| Pessoas | Os usuários do Atlas são casados com os colaboradores já cadastrados pelo nome (sem acento e sem maiúsculas). Quem não existe é criado. | `atlas_mapear_usuarios` |
| Prazos | **Confirmado em 11/11/2026:** o prazo fatal do Atlas é o **PF Judicial** (vale outro "PF: dd/mm" anotado na descrição, se houver). O **D-4** é a data em que o advogado entrega a tarefa (PF menos 3 dias úteis). O **D-7** é a primeira data em que a tarefa aparece na agenda do colaborador (o vencimento no Atlas). | `mapear.js` |
| Exceção de D-4 | Exceções podem ser entregues depois do D-4. Quem marca é o **líder ou a controladoria**, com justificativa, pelo botão "Autorizar entrega após o D-4" na janela da tarefa no Atlas ou "Autorizar após o D-4" em Prazos em risco. A tarefa sai dos alertas de D-4 e de "Críticas em D-4"; o PF Judicial continua valendo. A exceção pode ser retirada, também com justificativa. Tudo fica no histórico (evento "Exceção de D-4"). | migração 0037 |
| Travas no Atlas | A extensão 0.5.2 segura a gravação no próprio navegador antes de ela sair para o Atlas. Isso vale para o botão Concluir, o formulário Editar, o arrasto no quadro e a baixa de um responsável. Conclusão sem início é bloqueada. Mudança de vencimento ou de responsável pede justificativa (mínimo de 15 caracteres). Mudança do prazo fatal segue a regra de antes. Alteração bloqueada **não chega ao Atlas**. | `extensao/atlas_ponte.js`, `atlas_content.js`, `lib/atlas_regras.js` |
| Início da tratativa | Painel "Iniciar tratativa" dentro da janela da tarefa do Atlas. | `atlas_content.js` |
| Líderes | Papel **Líder** no painel (Configurações › Usuários). Realocação e prazo fatal passam sem bloqueio e ficam registrados como "exceção autorizada". A trava de conclusão sem início continua valendo para eles. | 0035 |
| Tarefas de análise | São criadas **direto pela API do Atlas** (`create_task`), com chave de idempotência (não duplica). Botão "Criar no Atlas" na área de análise. Erro de validação ou de permissão do Atlas devolve a tarefa para "aprovada"; falha de rede leva a "verificar". | `atlas-sync` + 0035 |
| Segurança | A chave da API do Atlas fica **só** como segredo da Edge Function (`ATLAS_API_KEY`), nunca no painel nem na extensão. A função só age para a administradora logada: o banco confere antes de qualquer chamada ao Atlas. | `atlas_conferir_acesso` |

## O que a controladoria precisa fazer

1. **Gerar a chave do Atlas.** No Atlas, em Configurações › Integrações › API do Atlas › Nova chave:
   - autora: Mayra;
   - acesso: completo;
   - permissões: só **Listar Tarefas**, **Listar Prazos e Intimações**, **Consultar Processos** e **Criar Tarefas**.
2. **Guardar a chave no Supabase.** No projeto `controladoria-homologacao`, vá em Edge Functions › Secrets (Segredos) › Add new secret:
   - nome: `ATLAS_API_KEY`;
   - valor: a chave.
   - Ninguém da controladoria nem o Claude digita a chave em outro lugar.
3. **Testar a conexão.** No painel, área "Tarefas: Atlas e Excel": **Testar conexão** e depois **Sincronizar com o Atlas**.
4. **Atualizar a extensão.** Recarregar a extensão 0.5.2 no Chrome (chrome://extensions › Recarregar). Ela passa a atuar também no gestor.atlasjus.com.
5. **Dar acesso aos líderes.** Criar as contas no Supabase (Authentication › Users) e definir o papel **Líder** no painel, ligado ao nome de cada um.

## Testes

Todos com dados fictícios, banco local, simulador da API do Atlas e página simulada.

| Suíte | Verificações |
|---|---|
| `tests/test_etapa11.py`: banco (usuários, sincronizações sucessivas, eventos, líderes, tarefas de análise) | 39 |
| `tests/test_etapa12.py`: exceção de D-4 (permissões, alertas, indicador, visão do colaborador, retirada) | 27 |
| `tests/atlas/testar_edge.js`: Edge Function ponta a ponta (login, permissão, paginação, limite de chamadas, lote, criação sem duplicar) | 10 |
| `extensao/tests/testar_atlas.js`: regras e página simulada do Atlas (gravação bloqueada não sai do navegador, baixa, justificativa, líder, exceção de D-4) | 39 |
| Bateria completa (25 suítes) | 762, todas OK |

## Teste real A1 — primeira sincronização (11/11/2026, 15:31)

**Tentativa 1:** o Atlas recusou com `permission_denied: read_tasks`, porque a permissão "Listar Tarefas" vem desligada por padrão. A controladoria ligou as permissões no Atlas.

**Tentativa 2, aprovada após correção:**
- **Volume:** 527 tarefas em 12 s (346 abertas e 181 concluídas nos últimos 90 dias), 0 rejeitadas, lote #7.
- **Vínculo:** as 527 foram ligadas pelo ID do Atlas, e as 181 conclusões foram registradas.
- **Base atual:** os indicadores leem a base em 0,5 s, e a verificação de integridade não apontou erros.
- **Retrato da base:**
  - 211 tarefas estão sem responsável no Atlas;
  - nenhuma tem número de processo, porque são tarefas de atendimento;
  - só 6 têm prazo fatal, e só essas têm D-4 calculado.
- **E22 — resumo errado:** o resumo da sincronização disse "0 novas, 527 já conhecidas"; o certo é **527 novas**. A 0035 criava as tarefas antes de contar as já conhecidas, mas os dados gravados estavam certos.
  - A migração **0036** corrigiu isso.
  - O registro da importação 11 não foi alterado, porque importação encerrada é imutável.

## Teste real A3 — travas na tela do Atlas (11/11/2026, 15:40–15:50, tarefa de teste "Agravo de instrumento — elaborar ou regularizar")

| Passo | Resultado |
|---|---|
| Abrir a tarefa: painel "Iniciar tratativa" | Aprovado |
| "Concluir" sem início | Aprovado: bloqueado ("bloqueio efetivo" às 15:42, 15:46 e 15:47) |
| "Dar baixa na minha parte" sem início | **Falhou (E23)**: a baixa passou. O Atlas grava a baixa por uma rotina própria (`complete_task_assignee_tx`), que a extensão não vigiava. Corrigido na **extensão 0.5.1** (ver reteste abaixo) |
| Mudar vencimento e prazo fatal | Aprovado: pediu justificativa e registrou as duas alterações às 15:46 |
| "Iniciar tratativa" | Aprovado: registrado às 15:47 |

**Reteste com a extensão 0.5.1 (11/11/2026, tarefa de teste "Agravo de petição"): aprovado.** Eventos conferidos no banco:

| Hora | Ação | Resultado |
|---|---|---|
| 15:58:25 | "Dar baixa na minha parte" sem início | Bloqueado ("bloqueio efetivo", baixa parcial) |
| 15:58:31 | "Concluir" sem início | Bloqueado ("bloqueio efetivo") |
| 15:58:49 | "Iniciar tratativa" | Registrado |
| 15:59:12 | "Concluir" depois do início | Permitido ("permitida após validação") |

**Ainda não testado no Atlas real:**
- **A2:** criar uma tarefa de análise de teste pela API ("Criar no Atlas").
- **A4:** líder alterando tarefa (depende das contas dos líderes com o papel Líder).

## Limitações conhecidas

- **Tarefas atuais do Atlas:** em 11/11/2026 o Atlas tinha cerca de 345 tarefas a fazer e 181 concluídas, a maioria de atendimento (ex.: "Reunião Inicial com"). As tarefas jurídicas do ADVBOX (cerca de 3.500) **não estão no Atlas**. Os indicadores passam a refletir o Atlas a partir da primeira sincronização.
- **Double check:** continua comparando a Webjur com a varredura do ADVBOX. As intimações do Atlas (`list_deadlines`) só trazem um resumo de até 500 caracteres, não o teor. A comparação Webjur × Atlas precisa de outra regra, por número do processo e data, calibrada com dados reais depois da chave.
- **Duração da sincronização:** a Edge Function tem limite de cerca de 150 s por chamada, o que comporta alguns milhares de tarefas por sincronização.
- **Alcance das travas:** como no ADVBOX, só funcionam no navegador com a extensão. Alterações feitas por outro caminho aparecem na sincronização seguinte.
