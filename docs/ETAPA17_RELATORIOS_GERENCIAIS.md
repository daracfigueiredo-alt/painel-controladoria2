# Etapa 17 — Relatórios gerenciais com gráficos de pizza (16/11/2026)

**Pedido da controladoria:** relatórios gerenciais de cada menu, com gráficos de pizza para visualizar e acompanhar melhor.

## Como funciona

- Em cada área do menu aparece, logo abaixo do título, o bloco recolhível **"Relatório gerencial"**. Ele só carrega quando é aberto, para não pesar a tela.
- **Quem vê:** controladoria e diretoria. Peticionador e líder não veem o bloco, e o banco também recusa (`relatorio_gerencial` começa com `pode_ler_tudo()`).
- **Período:** começa nos últimos 30 dias. Há atalhos de 7, 30 e 90 dias e um limite de 400 dias.
  - Cada gráfico mostra uma etiqueta:
    - **"Situação atual"** é o retrato de agora e não muda com as datas;
    - **"No período"** segue as datas escolhidas.
- **Pizzas:**
  - até 6 fatias; o resto vira "Outros (n)", em cinza, e a legenda mostra quem está ali;
  - legenda com a quantidade e o %;
  - "Ver tabela" mostra todos os itens;
  - passar o mouse (ou o teclado) sobre uma fatia mostra o item, a quantidade e o %;
  - cada pizza tem uma descrição para leitor de tela.
- **Cores:** paleta categórica fixa (azul, laranja, verde, amarelo, rosa, verde-escuro), validada para daltonismo no modo claro e no escuro.
  - No modo claro, três cores ficam abaixo de 3:1 de contraste com o fundo branco. Por isso a legenda com números e a tabela estão sempre presentes.
- **Imprimir / PDF:** imprime só o relatório, sem o menu nem a área, com o cabeçalho "área — período — gerado em". Use "Salvar como PDF" na janela de impressão.

## O que cada menu mostra

| Menu | Indicadores | Pizzas |
|---|---|---|
| Painel da diretoria e Visão geral | Tarefas abertas; concluídas no período; prazos em risco alto/crítico; inconsistências abertas; audiências nos próximos 7 dias | Tarefas por situação; abertas por responsável; prazos em risco por grupo; inconsistências abertas por tipo |
| Indicadores por colaborador | Colaboradores com tarefas abertas; concluídas no período | Abertas por colaborador; concluídas por colaborador (período); risco alto/crítico por colaborador |
| Prazos em risco | Prazos em risco; críticos | Por gravidade; grupo de risco; categoria; conferência |
| Reagendamentos | No período; sem justificativa | Classificação; natureza; com/sem justificativa; responsável (todas no período) |
| Tratativa | Abertas sem início; horas médias até o início ("—" quando não há dado, 0057) | Situação da tratativa; abertas sem início por responsável |
| Audiências | No período; sem data; sem advogado | Situação; tipo; modalidade; pendências; equipe; resultados registrados (período) |
| Minha pauta | Tarefas abertas; vencidas | Abertas por vencimento (vencidas, hoje, 7 dias, depois); por responsável |
| Solicitações | No período; aguardando decisão | Situação; tipo; quem pediu |
| Sincronização com o Atlas | Sincronizações e erros no período | Registros por nível e por operação; tarefas do Atlas por situação |
| Cadastro de processos no Atlas | Cadastrados pelo robô; cadastrados no período; cliente não encontrado | Processos por situação; cadastrados por tipo; como o cliente foi encontrado |
| Intimações CNJ | Comunicações no período; processos na carteira | Tribunal; tipo de comunicação; capturadas também pela Webjur; pela OAB × varredura |
| Publicações Webjur | Publicações e processos diferentes no período | Tribunal; com/sem identificador do CNJ; número do processo |
| Double check de intimações | Abertas; apontadas e tratadas no período | Abertas por tipo; por gravidade; apontadas no período por situação |
| Tarefas de análise | Total | Situação; tipo; exigem cadastro |
| Importação do Excel | Importações no período | Situação; origem (Atlas × Excel); linhas por resultado |
| Double check ADVBOX | Alertas | Situação da conferência; categoria; gravidade |
| Histórico de auditoria | Alterações no período | Por tabela; por operação |
| Configurações | Usuários com perfil; parâmetros a confirmar | Usuários por perfil; parâmetros por sistema; confirmados × a confirmar |

## Banco real (16/11/2026, depois da 0056 e da 0057)

- Todas as 18 consultas responderam; a mais lenta foi Prazos em risco (2,4 s), as demais ficaram abaixo de 1,4 s.
- **Alguns números do dia:**
  - 349 tarefas abertas, das quais 211 estão "sem responsável (Atlas)";
  - 360 prazos em risco, 348 deles por ausência de evidência;
  - 172 inconsistências abertas, das quais 159 são captura divergente CNJ × Webjur;
  - 430 comunicações do CNJ em 30 dias: 291 também capturadas pela Webjur e 139 não;
  - cadastro no Atlas: 618 cadastrados, 674 com cliente não encontrado e 29 para revisar.
- **0057:** a média de horas da Tratativa mostrava 0 quando ninguém tinha iniciado tratativa no período; agora mostra "—".

## Testes

| Suíte | Verificações |
|---|---|
| `tests/test_etapa17.py`: as 19 áreas bem formadas, números iguais à contagem direta no banco, período (antigo, vazio, invertido, acima de 400 dias), retrato atual que não muda com as datas, área inválida e tentativa de injeção, permissões (diretoria lê; peticionador, líder, sem perfil e anônimo não), funções internas fechadas, média sem dado | 52 |
| `tests/e2e/testar_relatorios.js`: posição abaixo do título, pizzas × banco (fatias, legenda, total, %), rótulos em português, contorno de 2 px, cores no claro e no escuro, dica, tabela, "Outros", atalho de período, erro de período, as 19 áreas, impressão só do relatório, diretoria × peticionador, celular sem rolagem lateral, console sem erros | 28 |

## Para manter

- **Menu novo:** acrescentar um `when` em `relatorio_gerencial` (sempre numa migração nova) e o id da área em `AREAS_COM_RELATORIO` (`painel/js/relatorios.js`).
- **Rótulos:** os códigos do banco viram texto pelo dicionário de `relatorios.js` e pelo `Comum.ROTULOS`, que já é usado nas outras telas.
