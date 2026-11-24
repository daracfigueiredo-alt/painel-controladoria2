# Diagnóstico da exportação do ADVBOX e decisões pendentes

Arquivo analisado: `Advbox-2026-10-24_0717524.xlsx`, aba "Dados", 878 linhas e 17 colunas.
Análise feita em 24/10/2026. Nenhum dado foi alterado.

## 1. O que o Excel traz (e o que não traz)

| Coluna do ADVBOX | Preenchimento | Uso no sistema |
|---|---|---|
| Data | 878/878 | **D-7**: data da agenda, valor de origem |
| Prazo fatal | 675/878 | **PF da Tarefa** |
| Data Conclusão | 31/878 | Conclusão (dd/mm/aaaa hh:mm) |
| Destinatário | 878/878 | Responsável atual |
| Remetente | 878/878 | Quem enviou ou criou a tarefa |
| Compromisso | 806/878 | Tipo da tarefa (72 linhas estão em branco) |
| Processo (CNJ) | 677/878 | Processo; o tribunal (J.TR) é extraído do número |
| Observações | 878/878 | Histórico em texto (veja o item 2) |
| Protocolo | **0/878** | Vazia: não serve como evidência de protocolo |
| Hora / Término / Local | 12, 31 e 72 linhas | Informativos |

**O Excel não traz:**

- identificador da tarefa no ADVBOX;
- data de criação (abertura);
- status da tarefa (só a conclusão);
- quem concluiu;
- histórico estruturado de alterações;
- campo próprio para o PF Judicial ou para o D-4.

## 2. O que existe no texto de Observações

- **655 encaminhamentos automáticos** no formato "@x encaminhou para @y em dd/mm/aaaa hh:mm:ss". São gravados como histórico recuperado, com data e hora ao segundo.
- **PF Judicial anotado** ("PF: 27/10", "Prazo Fatal: 27/10"): aparece em 239 linhas e é a única fonte identificável do PF Judicial. Em 16 linhas ele difere do campo Prazo fatal.
- **D-4 anotado** ("D-4: 22/10"): aparece em 169 linhas.
- **631 anotações de realocação** ("MG - dd/mm - Tarefa realocada…").
- **299 possíveis pedidos de reagendamento** ("favor reagendar", "gentileza realocar"…). Foram classificados como *potenciais*. Um pedido nunca conta como reagendamento efetivado.
- Datas sem ano ("27/10"): o sistema adota o ano mais próximo da data de referência e guarda o texto original junto.

## 3. Regra de D-4: os exemplos do escritório contrariam a leitura literal

| PF | D-4 informado pelo escritório | PF − 3 dias úteis | PF − 4 dias úteis |
|---|---|---|---|
| 27/10/2026 (ter) | 22/10 | **22/10** ✔ | 21/10 ✘ |
| 26/10/2026 (seg) | 21/10 | **21/10** ✔ | 20/10 ✘ |

Os exemplos só fecham quando **o próprio dia do PF conta como o 1º dos 4 dias**, ou seja, PF menos 3 dias úteis. As anotações reais confirmam essa prática: das 168 linhas com D-4 e PF, 138 seguem PF − 3 dias úteis, 19 seguem PF − 4 e 11 não seguem nenhuma das duas.

A coluna Data também segue essa contagem: em 111 linhas ela fica exatamente 6 dias úteis antes do PF (o "D-7" na mesma convenção).

**O sistema está configurado provisoriamente com PF − 3 dias úteis.** O parâmetro está marcado como não confirmado e as divergências aparecem como alerta. Os exemplos não foram alterados.

## 4. Identificação das tarefas (sem ID no Excel)

A chave estável combina os campos que não mudam numa realocação: compromisso, remetente, partes, processo, tipo de ação e o primeiro parágrafo original de Observações. Resultado no arquivo real:

- 637 linhas: chave única. Dá para acompanhá-las entre importações com segurança razoável.
- 226 linhas: textos repetidos, como tarefas recorrentes e parcelas. A chave inclui as datas, então **numa realocação elas aparecem como tarefa nova**.
- 15 linhas: idênticas a outras em tudo. Ficam **sem vínculo** (o sistema prefere não fundir a fundir errado).

A solução definitiva é a extensão gravar o ID real da tarefa no ADVBOX (campo `tarefas.advbox_id`). Ainda falta confirmar na tela se esse ID aparece.

## 5. Primeira leitura dos alertas (base de 24/10/2026)

| Grupo | Condição | Tarefas |
|---|---|---|
| Processual | PF Judicial anotado vencido sem conclusão | 16 |
| Processual | PF Judicial nos próximos 2 dias úteis | 41 |
| Processual | PF Judicial não confirmado (tem PF da Tarefa, sem anotação) | 419 |
| Operacional interno | D-4 passou sem entrega confirmada | 71 |
| Operacional interno | PF da Tarefa vencido | 213 |
| Inconsistência | Data da agenda posterior ao PF da Tarefa | 117 |
| Inconsistência | D-4 anotado diferente da regra | 25 |
| Inconsistência | PF da Tarefa ≠ PF Judicial anotado | 16 |
| Ausência de evidência | Data da agenda atingida sem início registrado | 248 (a extensão ainda não existe) |

Os 16 casos de PF Judicial vencido precisam de conferência humana. A providência pode ter sido cumprida em outra tarefa da mesma pasta (o protocolo, por exemplo). O sistema não conclui que houve perda de prazo.

## 6. Decisões confirmadas em 24/10/2026

1. **D-4 = PF Judicial − 3 dias úteis**, com o dia do PF contado como o 1º. O D-7 segue a mesma contagem (PF − 6 dias úteis, usado só para conferência).
2. **PF Judicial**: a fonte oficial é a anotação "PF: dd/mm" em Observações.
3. **Entrega em D-4**: comprovada somente pela conclusão da tarefa.
4. **Protocolos e distribuições**: contam pela conclusão das tarefas "PROTOCOLO" e "DISTRIBUIÇÃO - NOVO PROCESSO".
5. **Prazo fatal**: só pode ser alterado em prazo **não judicial**, com autorização da controladoria. Em tarefa com PF Judicial, qualquer mudança do PF da Tarefa é registrada como `violacao_detectada` e aparece em Prazos em risco.
6. **Exportação**: diária, pelo menu Atividades, com tarefas pendentes a partir de 01/10/2026.

### Ainda em aberto

- Calendário de feriados por tribunal (estaduais, municipais, recesso, art. 220 do CPC).
- Quantos dias úteis antes de um marco a tarefa passa a ser "próxima" (provisório: 2).
- **Exportação de concluídas** (aprovada; exemplo `Advbox-2026-10-24_0443625.xlsx`):
  - Tem as mesmas 17 colunas e Data Conclusão preenchida em 50 de 50 linhas.
  - Entra no mesmo lote das pendentes. Nenhuma conclusão se repete entre os dois arquivos (31 + 50 = 81 conclusões distintas).
  - Segundo exemplo de concluídas (`Advbox-2026-10-24_0687502.xlsx`): de novo **exatamente 50 linhas**, com conclusões entre 01/10 e 13/10. Há 5 linhas em comum com o primeiro arquivo, que o sistema ignorou como repetidas. O total no lote ficou em 126 conclusões distintas.
  - Dois arquivos com exatamente 50 linhas indicam que a exportação de concluídas está limitada a 50 linhas. A tela não foi verificada.
  - **Ponto de atenção:** o primeiro arquivo tem exatamente 50 linhas, com conclusões entre 04/09 e 08/10/2026. O painel do ADVBOX mostra cerca de 590 tarefas resolvidas no mês. É preciso confirmar se a exportação foi limitada (por página, filtro ou responsável) antes de usar os números de conclusão.

## 7. Inspeção da interface do ADVBOX (somente leitura, 24/10/2026)

- **A lista de Atividades mostra o ID real de cada tarefa** (`posts/{id}`) e do processo (`lawsuits/{id}`). A extensão pode associar o ID às linhas do Excel, o que resolve a identificação do item 4.
- **A janela da tarefa mostra "Criado por" com data e hora**, que não existe no Excel. A extensão pode capturar a data de abertura.
- Também aparecem na janela: Situação, Data do evento, Prazo fatal, Responsável, Partes, Processo e o histórico completo.
- O endereço `posts/{id}/edit` aberto diretamente não funciona. A tarefa só abre pela própria lista.
- **Concluir** é um link (`a.button.toggle` com `data-id` da tarefa), tratado por um evento de clique registrado no `body` da página (jQuery, `.task-container .toggle`).
- **Atribuir tarefa / encaminhar / realocar** é um formulário (POST `/posts`) com os campos `user`, `tasks_id`, `comments`, `date`, `date_deadline`, tratado por um evento de envio também no `body` (`.task-container form`).
- **Editar** abre outro formulário (`posts/create`), que ainda não foi inspecionado.
- **Viabilidade técnica das travas (hipótese, NÃO testada):** os dois controles acima são tratados no `body`. Uma extensão que escute antes, na fase de captura, consegue em tese validar e impedir o clique em Concluir e o envio do formulário. Isso só vale no navegador com a extensão instalada e ativa, e deixa de valer se o ADVBOX mudar a tela. Só depois de testar com a extensão instalada será possível classificar cada trava como "bloqueio na interface" ou "apenas detecção".
