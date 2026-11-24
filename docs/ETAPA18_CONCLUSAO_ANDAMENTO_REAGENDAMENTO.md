# Etapa 18 — Conclusão com justificativa, "em andamento" como início e reagendamento pelo peticionador (17/11/2026)

**Pergunta da controladoria (16/11/2026):** a API do Atlas permite
1. travar a conclusão dos prazos sem justificativa?
2. identificar as tarefas em andamento?
3. solicitar o reagendamento pelo sistema?

## O que a documentação da API do Atlas diz (lida em 16/11/2026, só leitura)

| Pergunta | Resposta da API | Como ficou no sistema |
|---|---|---|
| Travar a conclusão sem justificativa | **Não.** A API não barra a conclusão antes de ela acontecer. O aviso automático "tarefa concluída" (`TASK_COMPLETED`) chega depois do fato. Tarefa concluída não reabre pela API (`task_reopen_not_supported`). | A trava fica na **extensão 0.7.0**, como as outras travas. A rede de segurança fica no **double check das 18:30**. |
| Identificar tarefas em andamento | **Sim.** `list_tasks` traz a situação: a fazer (`todo`), em andamento (`doing`) ou concluída (`done`). | "Em andamento" passa a contar como **início da tratativa**. |
| Solicitar o reagendamento | **Em parte.** Não existe "pedido de reagendamento" no Atlas. `edit_task` muda a data direto (permissões "Editar Tarefas" e "Comentar Tarefas"). | O pedido e a aprovação ficam no **painel**. Depois de aprovado, o sistema muda a data no Atlas por `edit_task` e comenta com a justificativa. |

**Conferido no banco real em 16/11/2026:** 348 tarefas abertas "a fazer", 1 "em andamento" e 181 concluídas. Nenhuma tinha início de tratativa registrado.

## Decisões da controladoria (17/11/2026, 00:24)

1. **Justificativa obrigatória na conclusão:** sim, com a rede de segurança.
2. **"Em andamento" no Atlas:** conta como **início da tratativa**.
3. **Reagendamento:** o **peticionador** pede pelo painel.
   - Até o D-4, quem aprova é o **líder** da equipe.
   - Depois do D-4, só com autorização da **controladoria**.

## Como funciona

### 1) Conclusão com justificativa (migrações 0058 e 0059, extensão 0.7.0)

- **Extensão:**
  - ao **Concluir** ou **Dar baixa na minha parte**, a extensão confere primeiro o início da tratativa (regra de antes);
  - depois pede a **justificativa** (mínimo de 15 caracteres), num diálogo próprio ("Concluir com justificativa" / "Cancelar conclusão");
  - sem justificativa, a gravação **não sai do navegador**;
  - vale também para os líderes.
- **Servidor:** conclusão registrada como permitida, mas sem justificativa (por exemplo, por uma extensão antiga), é **reclassificada como violação** (`motivo_servidor`).
- **Rede de segurança:**
  - a sincronização com o Atlas traz cada conclusão com dia e hora;
  - o double check das 18:30 aponta a inconsistência **"Conclusão sem justificativa"** (gravidade média) para a conclusão sem justificativa registrada;
  - isso pega a conclusão feita no celular, em outro navegador ou com a extensão desatualizada;
  - quando a justificativa é registrada, a inconsistência se regulariza sozinha. A controladoria também pode marcá-la como justificada no painel.
- **Por que não o aviso automático do Atlas:** a sincronização já traz toda conclusão, então o resultado é o mesmo sem abrir um endereço público para receber avisos.
- **Parâmetros:**

| Parâmetro | Valor | Para que serve |
|---|---|---|
| `atlas_conclusao_exige_justificativa` | true | Liga ou desliga a regra (extensão, servidor e double check) |
| `atlas_conclusao_justificativa_desde` | 2026-11-18 (**a confirmar**) | A partir deste dia o double check aponta. É o prazo para a equipe recarregar a extensão |

- **0059 (reforço):** a rede de segurança lê o ID do Atlas do cadastro da tarefa, e não da visão de tarefas. Assim, a regra não depende de quem roda a conferência.

### 2) "Em andamento" = início da tratativa

- **Sincronização:**
  - toda sincronização (botão ou rotina das 18:30) registra o início das tarefas "em andamento" que ainda não têm início;
  - o evento é `inicio_tratativa`, com origem sistema, o responsável da tarefa e a hora da sincronização;
  - não repete.
- **Extensão:** quando a pessoa muda a tarefa para "em andamento" no Atlas, o início é registrado na hora.
- **Parâmetro:** `atlas_em_andamento_inicia_tratativa` (true).
- **No banco real, em transação desfeita:** a única tarefa em andamento ganharia o início. Na próxima sincronização isso acontece de verdade.

### 3) Reagendamento pedido pelo peticionador

- **Onde pedir:**
  - **Minha pauta:** cartão da tarefa › "Pedir reagendamento";
  - ou **Solicitações e reagendamentos** › "Pedir reagendamento".
- **O pedido:**
  - só nas tarefas do Atlas do próprio peticionador;
  - informa a nova data e a justificativa (mínimo de 15 caracteres);
  - a nova data não pode ser no passado, igual à atual ou depois do prazo fatal;
  - só um pedido aberto por tarefa.
- **Quem decide:**
  - **até o D-4:** o líder da equipe (ou a controladoria);
  - **depois do D-4:** só a controladoria. "Depois do D-4" é quando a nova data cai depois do D-4 ou quando o pedido é feito com o D-4 já vencido;
  - **tarefa com entrega após o D-4 autorizada (exceção de D-4):** decide o líder;
  - **tarefa sem prazo fatal (sem D-4):** decide o líder.
- **Sobe para a controladoria:**
  - o pedido que passa do D-4 sem decisão do líder (no double check das 18:30);
  - a aprovação do líder feita depois do D-4.
- **Depois de aprovado:**
  - o painel executa na hora no Atlas: troca só a data (`edit_task`) e comenta com a justificativa;
  - o líder também pode executar (antes, só quem tinha pedido);
  - quem decide pode clicar em "Analisar a pauta" e ver a carga do advogado no dia novo.
- **Cancelar:** o peticionador cancela o próprio pedido enquanto ele não for executado.
- **Contas dos líderes:** ainda não existem. Até elas serem criadas, a controladoria decide também os pedidos "Aguardando o líder".

## Aplicação no banco de homologação (17/11/2026)

- 0058 e 0059 aplicadas.
- Edge Function `atlas-sync` publicada (versão 9). A única mudança é registrar o "em andamento" depois de gravar o lote.
- **Conferência no banco real** (tudo dentro de uma transação desfeita, nada gravado):
  - double check em 0,25 s a 1 s;
  - nenhuma tarefa do Atlas foi concluída depois de 04/11/2026. Por isso, hoje o double check não aponta nada;
  - simulando a regra desde setembro, apontaria 112 conclusões sem justificativa entre 28/10 e 04/11. Elas são anteriores à regra, e é para isso que existe o parâmetro "desde";
  - a extensão recebe `conclusao_exige_justificativa = true` nas tarefas do Atlas.

## Testes

| Suíte | Verificações |
|---|---|
| `tests/test_etapa18.py`: parâmetros, "em andamento" (registro, sem repetir, permissão, regra desligada), justificativa (servidor, reclassificação, double check antes e depois do "desde", regularização, rotina com chave de serviço), reagendamento (quem pode pedir, validações, regra do D-4, exceção de D-4, decisões por perfil e equipe, líder depois do D-4, subida automática, visibilidade, execução pelo líder) | 56 |
| `extensao/tests/testar_atlas.js`: 15 verificações novas (justificativa na conclusão e na baixa, diálogo próprio, cancelar, "em andamento" registra o início, reabertura não conta) | 60 |
| `tests/atlas/testar_edge.js`: "em andamento" na sincronização (77 no simulador), segunda sincronização sem repetir, pedido do peticionador aprovado e executado pelo líder no Atlas simulado | 26 |
| `tests/e2e/testar_reagendamento.js`: pedido pela Minha pauta (aviso de quem decide, justificativa curta recusada), lista do peticionador, análise da pauta e aprovação pelo líder | 11 |

- **Bateria completa:** 1.309 verificações em 41 suítes, todas passando em 17/11/2026.
- **Erros que os testes acharam antes do banco real:**
  - o líder conseguia executar no Atlas, mas o registro do resultado ainda exigia ser o autor do pedido;
  - `solicitacao_decidir` conferia o motivo antes do perfil (apontado pela auditoria de segurança da etapa 9).

## O que a controladoria precisa fazer

1. **Equipe:** cada pessoa recarrega a extensão 0.7.0 no Chrome.
   - Abrir `chrome://extensions` e clicar em **Recarregar**.
   - Os arquivos novos da pasta `extensao` já estão na pasta da controladoria.
2. **Confirmar o dia de início da cobrança no double check** (`atlas_conclusao_justificativa_desde`, hoje 18/11/2026). Ele fica em Configurações.
3. **Permissões da chave do Atlas:** o reagendamento precisa de "Editar Tarefas" e "Comentar Tarefas" na chave usada pelo sistema.
   - O botão **Testar conexão** (Sincronização com o Atlas) mostra as permissões.
   - O comentário só sai se a chave tiver um autor escolhido. Sem autor, a data muda do mesmo jeito, e o comentário é registrado como não feito.
4. **Contas dos líderes:** quando forem criadas, os pedidos "Aguardando o líder" passam a ser decididos por eles.
