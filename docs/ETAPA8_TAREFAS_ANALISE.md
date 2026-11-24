# Etapa 8 — Tarefas de análise (10/11/2026)

## Decisões da controladoria
- **Tipo:** "ANÁLISE DO CASO (50 pts)" (id 8849391 no ADVBOX).
  - O ADVBOX move o processo para **NEGOCIAÇÃO / ANÁLISE DO CASO** ao criar essa tarefa. Não há opção de não mover.
  - O tipo foi mantido mesmo assim, por decisão de 10/11/2026.
- **Responsável:** Mayra (usuário 296462 no ADVBOX).
- **Data:** data da conferência.
- **Prazo fatal:** data + 1 dia útil.
- **Processo não cadastrado:** a controladoria cadastra no ADVBOX antes. Sem cadastro, nada é enviado e a tarefa fica bloqueada no painel.
- **Criação:** a extensão cria sozinha depois da aprovação no painel.

## Fluxo
`preparada` → (painel, área 9) `aprovada` → (extensão) `criacao_em_andamento` → `criada`

| Situação | O que acontece |
|---|---|
| Nada foi enviado: processo não achado, mais de um cadastro para o CNJ, formulário divergente | Volta a `aprovada` com **bloqueio**. A controladoria resolve no painel (cadastra o processo, ou escolhe o processo entre os encontrados) e libera nova tentativa. |
| Enviado sem confirmação, ou criação interrompida há mais de 10 min | Vai para `verificar_no_advbox` e nunca é recriada sozinha. No painel: "Foi criada: registrar o ID" ou "Não foi criada". |
| Conferência da publicação revista para "encontrada" | A aprovação ou a criação é recusada. |

## Como a extensão cria
- **Quando começa:** só com a aba do ADVBOX visível, sem janela aberta e sem uso há 20 s. Também pelo botão "Criar as aprovadas agora" no ícone da extensão. Há a opção "Pausar".
- **Formulário:** a extensão abre o formulário normal "Nova tarefa" com o responsável já indicado (`posts/create?responsible=296462`) e preenche:
  - o processo, buscando pelo CNJ;
  - o tipo exato;
  - as datas;
  - a descrição com o teor.
- **Conferência antes de enviar:** confere campo a campo antes de clicar em "Criar nova tarefa".
- **Conferência depois:** lê a tarefa aberta (ID novo no endereço `?t=`). Confere o título, a data de criação dos últimos 10 minutos e o ID diferente do anterior. Depois fecha a janela.

## Homologação no ADVBOX real (caso TESTE 1.0)
| Tarefa | Resultado |
|---|---|
| 297747789 | Criada à mão, para capturar o formulário. |
| 297813142 | Criada pela extensão 0.4.0. A conferência final leu o título junto com o painel da controladoria e mandou para "verificar" (comportamento seguro). Corrigido na 0.4.1. Registrada pelo painel. |
| 297817836 | Criada **e confirmada** sozinha pela extensão 0.4.1 em cerca de 15 s: processo 19368297, "Análise do Caso", 10/11, prazo fatal 11/11. A janela ficou aberta; a 0.4.2 fecha pelo botão X real. |

As três são de teste e podem ser excluídas.

## Testes
- Banco: `tests/test_etapa8.py`.
- Regras da extensão: `extensao/tests/testar_criacao.js`.
- Painel ponta a ponta: `tests/e2e/testar_analise.js`.

## Primeira criação real (10/11/2026, extensão 0.4.3)
- **Ajuste antes da criação:** o ADVBOX lista o mesmo processo uma vez por parte vinculada, sempre com o mesmo ID. A partir da 0.4.3 isso conta como um único processo e vale a primeira linha, como pediu a controladoria. Só IDs diferentes bloqueiam.
- **Resultado:** 6 tarefas criadas e confirmadas sozinhas, entre 16:12 e 16:14, cerca de 25 s cada. Em todas, a tela conferida mostrou o CNJ esperado, o título "Análise do Caso", a data 10/11 e o prazo fatal 11/11.

| # | CNJ | Tarefa no ADVBOX | Processo no ADVBOX |
|---|---|---|---|
| 1 | 0705506-69.2024.8.01.0001 | 297864857 | 14403664 |
| 2 | 6017473-77.2026.4.06.0000 | 297865284 | 19414964 |
| 3 | 2849615-44.2026.8.13.0000 | 297865598 | 19388674 |
| 10 | 0144561-91.2026.8.16.0000 | 297865871 | 19415627 |
| 11 | 2851534-68.2026.8.13.0000 | 297866229 | 19415104 |
| 12 | 4164419-61.2026.8.26.0000 | 297866562 | 19415458 |

- **Rejeitadas pela controladoria:** #4 e #6 (publicação ou processo de outro escritório).
