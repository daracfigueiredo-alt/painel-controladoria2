# Etapa 12 — Pedidos da Dra. Mariana (11/11/2026)

Pedido: usar o AtlasJus como sistema central, com a controladoria integrada a ele. O painel e a extensão passam a atender os itens 3 a 6 do pedido. A proposta do item 7 (custos, etapas e perguntas ao suporte) está em documento separado.

Base técnica: a API do Atlas (Configurações › Integrações › API do Atlas › Documentação), lida em 11/11/2026. Ela oferece:
- `edit_task` (data, prazo fatal, responsável, descrição);
- `add_task_comment`;
- `list_deadlines` (intimações com CNJ, disponibilização, prazo calculado, duplicatas e tarefas geradas);
- `get_productivity`.

Tudo o que foi feito usa essas ações. Nada é lido pela sessão do usuário no Atlas.

## O que foi entregue

| Item | O que faz | Onde |
|---|---|---|
| **6. Acessos** | Quatro perfis, descritos abaixo. | 0038; painel (menu por perfil); Configurações › Usuários |
| **5. Modalidades** | Cada modalidade de tarefa jurídica tem checklist obrigatório, links do material de treinamento e da conferência no NotebookLM, orientações e pontos de complexidade. Também exige anexar a **peça** e o **parecer de autoavaliação**, guardados no Storage com hash. A conclusão no Atlas fica **travada** enquanto houver pendência. A descrição da tarefa no Atlas é **preservada** e recebe um bloco da controladoria (prazos, orientações, checklist, links), atualizado sem duplicar. | 0039, 0043; painel (Minha pauta; Configurações › Modalidades; Tarefas › Padronizar descrições); extensão 0.6.0 (bloco "Execução" na janela da tarefa) |
| **4. Planejamento** | Detalhado abaixo. | 0040, 0043; painel (Solicitações e reagendamentos; Configurações › Capacidade); Edge Function `executar_solicitacao` |
| **3. Double check** | Detalhado abaixo. | 0041, 0042, 0043; painel (Relatório diário de inconsistências); Edge Function `sincronizar_intimacoes` e `fim_expediente` |

**Item 6 — os quatro perfis:**
- **Diretoria:** vê tudo e não altera nada. Tem o painel próprio, com pendências, solicitações, exceções de D-4 e a produtividade do Atlas.
- **Controladoria:** como antes.
- **Líder:** vê as tarefas das **equipes que acompanha** e faz solicitações.
- **Peticionador:** entra na **Minha pauta**.

**Item 4 — planejamento das solicitações.** O líder pede uma tarefa nova ou um reagendamento. Antes de enviar, o sistema analisa a pauta do advogado:
- pontos por dia contra a capacidade diária;
- D-4, PF Judicial, prioridade e complexidade.

Depois sugere o que remanejar e para quando, com a justificativa escrita.

Critérios de segurança: nunca sugere tarefa urgente, D-4 já atingido, PF Judicial próximo nem nova data depois do D-4 ou do prazo fatal.

Aprovação:
- quando envolve **PF Judicial** ou passa do D-4, vai para a **controladoria aprovar**;
- prazo interno é aprovado pelo líder.

A execução no Atlas é feita pela API: cria a tarefa, muda a data e anota "Tarefa realocada" com a justificativa. Tudo fica registrado e aparece em Reagendamentos.

**Item 3 — double check Webjur × Atlas.** Compara as publicações da Webjur com as intimações e tarefas do Atlas. Aponta:
- intimação não cadastrada;
- divergência de data e intimação sem cliente;
- prazo não lançado e prazo lançado errado (fatal da tarefa diferente do calculado);
- duplicadas (Webjur e Atlas);
- pendências: revisão do Atlas, intimação não lida no fim do dia, Webjur do dia não importada, Atlas não sincronizado.

Relatório diário:
- O que for corrigido no Atlas sai sozinho na execução seguinte.
- A controladoria pode justificar o que não precisa de correção.
- O relatório exporta CSV.

Rotina automática **às 18:30 dos dias úteis**: sincroniza tarefas, intimações e produtividade e roda a conferência. Ela só **lê** o Atlas.

## Testes (dados fictícios, banco local, simuladores do Atlas e da tela)

| Suíte | Verificações |
|---|---|
| `tests/test_etapa13.py`: perfis, modalidades e anexos, planejamento e solicitações, double check e relatório, diretoria, rotina com chave de serviço | 83 |
| `tests/e2e/testar_gestao.js`: telas da diretoria, Minha pauta (checklist, envio e download de anexo), solicitação do líder com análise, relatório (rodar e exportar), configurações | 24 |
| `tests/atlas/testar_edge.js`: Edge Function, agora com as ações novas (descrição padrão, intimações, fim do expediente pelo agendamento, solicitação executada pelo líder) | 22 |
| `extensao/tests/testar_atlas.js`: extensão no Atlas, agora com bloco de execução, checklist, anexo e trava por pendência | 45 |
| Bateria completa (27 suítes) | 892, todas OK |

## Aplicado no banco de homologação (11/11/2026)

- 0038 a 0043 estão aplicadas (a 0042 em 11/11, à tarde, com o job desligado).
- O bucket privado `pecas` e as políticas do Storage foram criados.
- A Edge Function `atlas-sync` está na versão 5.

**Medição no banco real:**
- "Minha pauta" da controladoria (346 tarefas): 14,7 s antes da 0043 e 1,0 s depois.
- Double check: 0,1 s.

**Achado na homologação:** a 1ª conferência, antes de sincronizar as intimações do Atlas, marcou todas as publicações como "não cadastradas" (89).
- A 0043 corrigiu isso: sem intimações sincronizadas, a conferência não compara nada e só aponta a pendência.
- As 89 ficaram "regularizadas" automaticamente na execução seguinte.

## Pendências que dependem de confirmação da controladoria

1. **Permissões novas da chave do Atlas.** Em Integrações › API do Atlas › Permissões:
   - **Editar Tarefas** (reagendar e padronizar descrições);
   - **Comentar Tarefas** (registrar a justificativa como comentário; exige chave com autor);
   - **Ler Produtividade** (painel da diretoria).
   - **Listar Prazos e Intimações** já foi ligada.
2. **Agendamento das 18:30 — criado em 11/11/2026, desligado.** O segredo foi guardado pela controladoria (função e Vault) e a 0042 foi aplicada (job `controladoria_fim_expediente`, `30 21 * * 1-5` UTC). Teste real disparado à mão pelo banco, às 17:4x:
   - 1ª chamada: recusada ("Agendamento não autorizado"). A função passou a ignorar espaço/quebra de linha colados junto com o valor e a dizer o motivo da recusa, sem mostrar o segredo (versão 5).
   - 2ª chamada: autorizada. Tarefas sincronizadas (529: 347 abertas e 182 concluídas recentes, nenhuma rejeitada); produtividade lida (42 membros); double check rodou.
   - **Intimações: o Atlas respondeu "The intimacoes module is not active for this tenant" (`addon_not_active`).** O módulo de intimações não está contratado/ativo no Atlas do escritório, então a conferência Webjur × Atlas ainda não tem com o que comparar e só aponta a pendência. Ponto para o suporte do Atlas.
   - **Ligado pela controladoria em 11/11/2026, 18:17.** Primeira execução automática: 11/11, 18:30.
3. **Modalidades.** O modelo inicial tem 8 modalidades **inativas**. A controladoria revisa os textos, preenche os links (treinamento e NotebookLM) e liga cada uma.
4. **Capacidade diária.** O padrão provisório é 6 pontos por dia, com pontos por modalidade de 1 a 4. Pode ser ajustada por advogado.
5. **Equipes dos líderes.** Cadastrar as contas dos líderes e da diretoria e marcar as equipes de cada líder.
   - Definido pela controladoria em 11/11/2026:
     - **Líderes:** Brenda Martins, Pedro Frejah, Raquel Guerra, Guilherme Ladeia, Ana Clara, Leandro Santana e Bárbara Castro. Fica registrado no parâmetro `atlas_lideres`.
     - **Diretoria:** Mariana Camilo e Ana Flávia Cailux. O perfil de diretoria não precisa de nome ligado.
   - Ainda não existe nenhuma equipe cadastrada. Sem equipe, o líder só vê as próprias tarefas.
6. **Webjur diária.** O CSV da DW continua sendo baixado no portal e importado no painel. Se a Webjur oferecer envio automático ou API, a importação pode ficar automática. É um ponto para o Gabriel avaliar.
