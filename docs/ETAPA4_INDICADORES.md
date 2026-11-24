# Etapa 4 — Dashboards e indicadores (06/11/2026)

Foram entregues cinco áreas do painel: Visão geral, Indicadores por colaborador, Prazos em risco, Reagendamentos e Tratativa. Elas usam a migração `0011_indicadores.sql`, que é aditiva.

## Princípio: definição única e reprodutível

Cada indicador é definido **uma vez**, em `indicadores_registros()`. Essa função devolve os registros que compõem o número e explica por que cada um entrou. A partir dela:

- os cartões (`indicadores_resumo`), o quadro por colaborador (`indicadores_por_colaborador`) e o gráfico diário (`indicadores_concluidas_por_dia`) apenas **contam** esses registros;
- o detalhamento (`indicadores_detalhe`) devolve **esses mesmos registros**.

Os testes conferem que o número do cartão é igual à soma do detalhamento, à soma por colaborador e à soma das barras do gráfico.

Tudo roda com a permissão de quem consulta: o colaborador vê apenas as próprias tarefas.

## Indicadores (§12 e §13)

| Indicador | Tipo | Definição |
|---|---|---|
| Pendentes | posição atual | Linhas pendentes da exportação mais recente |
| Vencidas | posição atual | Pendentes com o **PF da Tarefa (ADVBOX)** já passado |
| PF Judicial vencido — conferir | posição atual | Pendentes com o **PF Judicial anotado** já passado. É **pendência de conferência**, não perda de prazo presumida (§7.4) |
| Vencem hoje | posição atual | PF da Tarefa ou PF Judicial igual a hoje |
| Críticas em D-4 | posição atual | D-4 atingido e PF Judicial ainda não vencido |
| Abertas sem início | posição atual | Pendentes sem "Iniciar tratativa" |
| Sem início há +24 h | posição atual | Abertura lida na tela pela extensão há mais de 24 h, sem início. Sem a extensão, o valor é sempre 0 |
| Concluídas | período | Eventos de conclusão no período. O responsável atribuído é o Destinatário, porque o Excel não informa quem concluiu |
| Protocolos realizados | período | Conclusões de tarefas "PROTOCOLO" (regra confirmada em 24/10/2026) |
| Distribuições realizadas | período | Conclusões de tarefas "DISTRIBUIÇÃO - NOVO PROCESSO" (regra confirmada em 24/10/2026) |
| Solicitações de reagendamento | período | Pedidos identificados pelo texto. **Não** contam como alteração |
| Reagendamentos efetivados | período | Data da agenda efetivamente alterada entre duas importações |
| Tempo médio abertura → início | por colaborador | Só tarefas com abertura lida e início registrado, informando quantas entraram na média (n) |
| Tempo médio início → conclusão | por colaborador | Só tarefas com início registrado e conclusão |

Os cartões de **posição atual** usam a fotografia da última importação. Os cartões de **período** usam os filtros de data. Os filtros disponíveis são período, equipe e colaborador; os dois últimos aparecem só para o administrador.

O painel avisa em destaque quando:

- a exportação é de dias anteriores a hoje;
- há exportação com número "redondo" de linhas, sinal de que as conclusões podem estar incompletas (o diagnóstico já havia apontado o limite de 50 linhas);
- a extensão ainda não registrou início nem abertura de nenhuma tarefa.

## Prazos em risco (§11)

A tela usa `v_prazos_risco`. Ela reúne os alertas de `v_alertas` e acrescenta:

- **criticidade** (crítica, alta ou média), exibida com ícone e rótulo, nunca só pela cor;
- **data de referência**;
- **situação da conferência**.

Há duas categorias novas:

- **Reagendamentos sucessivos:** a data da agenda foi alterada duas vezes ou mais. O limite fica no parâmetro `reagendamentos_sucessivos_limite` e é **provisório**.
- **Protocolo ou distribuição sem evidência:** tarefa de protocolo ou distribuição pendente com o PF da Tarefa vencido.

Os filtros são categoria, criticidade, situação da conferência, grupo de risco, equipe, colaborador, período (sobre a data de referência) e processo (o número CNJ é buscado sem considerar a pontuação).

O administrador registra a conferência na própria linha. O registro passa por `admin_conferir_alerta`, exige nota de no mínimo 10 caracteres e fica auditado.

**Pendente de definição:** "tarefas de monitoramento concluídas sem evidência da providência correspondente" (§11). O escritório precisa dizer quais tipos de tarefa são de monitoramento e qual evento comprova a providência de cada uma. Até lá, esse alerta não é calculado.

## Reagendamentos (§22)

A tela usa `v_reagendamentos`, que separa a natureza de cada evento:

- **solicitação**: texto na tarefa;
- **anotação de realocação**;
- **efetivação**: alteração observada entre importações;
- **tentativa pela extensão**.

Cada evento mostra o texto original, o autor, as datas e a evidência, além de marcações de "sem justificativa", "impacta prazo" e "data alterada depois" (esta última para solicitações).

**Aprovação e rejeição não são identificáveis** na exportação do ADVBOX. A tela informa isso, em vez de presumir.

## Tratativa (§8.3)

A tela usa `v_tratativa` e classifica cada tarefa em uma destas situações:

- pendente sem início;
- iniciada e não concluída;
- concluída com início;
- concluída sem início (inconsistência);
- concluída antes do monitoramento.

A inconsistência só é apontada para conclusões **posteriores** à data definida no parâmetro `tratativa_monitorada_desde`. Esse parâmetro deve ser preenchido quando a extensão entrar em uso real. Antes disso não havia como registrar o início, e o sistema não trata a falta dele como falha.

A tela também mostra os eventos das travas e, para o administrador, os vínculos de tarefa a refazer.

## Limite de linhas

O Supabase devolve no máximo 1.000 linhas por consulta. As listagens usam funções que filtram no próprio banco e devolvem o **total exato** e até 500 linhas por vez (`prazos_risco_listar`, `reagendamentos_listar`, `tratativa_listar`, `indicadores_detalhe`).

Na base real há 2.355 alertas. A tela mostra "Mostrando 500 de 2.355", sem cortar o total em silêncio.

## Gráficos

Os gráficos são desenhados em SVG, sem biblioteca externa, e seguem as cores validadas para daltonismo e contraste, nos modos claro e escuro.

- **Gráfico 1 — concluídas por dia:** uma série; um ponto por dia do período, inclusive os dias com 0 conclusões, que são contagem real e não estimativa.
- **Gráfico 2 — concluídas no período e pendentes por colaborador:** barras horizontais agrupadas, num mesmo eixo de quantidade de tarefas, com legenda e valores nas barras.

Os dois gráficos mostram o valor ao passar o mouse e têm alternativa em tabela.

## Testes

| Bateria | Resultado |
|---|---|
| `tests/test_etapa4.py`: respostas conhecidas, reprodutibilidade, filtros, RLS, listagens | 41/41 |
| `tests/e2e/testar_indicadores.js`: tela = banco = detalhamento, gráficos, filtros, conferência, colaborador, celular, console limpo | 31/31 |
| Regressão: banco, Etapa 2, calendário, auditoria, importação ponta a ponta, extensão | 64, 64, 13, 8, 40 e 29 — todos OK |

As telas também foram conferidas visualmente com a base real de 24/10/2026, mas essas capturas não fazem parte do pacote, porque contêm nomes e processos reais.

Nessa conferência apareceram três problemas, já corrigidos:

- a ordenação numérica do quadro por colaborador falhava, porque o servidor de teste devolvia números como texto;
- nomes longos eram cortados no gráfico;
- ao sair do sistema, a tela ainda tentava buscar indicadores, e o banco recusava corretamente essas chamadas.

## Parâmetros provisórios desta etapa

| Parâmetro | Valor | Confirmar |
|---|---|---|
| `reagendamentos_sucessivos_limite` | 2 | A partir de quantas alterações a tarefa deve ser destacada |
| `tratativa_monitorada_desde` | não definido | Data de início do uso real da extensão |
| `alerta_dias_uteis_proximo` (fase 1) | 2 | Janela de "prazo próximo" |
