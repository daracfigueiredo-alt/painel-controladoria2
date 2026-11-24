# Etapa 7 — Double check Webjur × ADVBOX (06/11/2026)

## 1. Inspeção do ADVBOX real (somente leitura)

A inspeção foi feita em 06/11/2026 no Chrome da controladoria, logado no ADVBOX. Foi só leitura:

- abri a tela "Intimações recebidas" do dia;
- li duas intimações pelo mesmo pedido GET que a tela faz ao clicar em "Ver intimação";
- abri a janela de um processo.

Nada foi marcado, encaminhado, vinculado ou alterado. Uma troca do filtro de período feita por script não recarregou a lista, e a página foi recarregada para voltar ao estado original. Depois disso a aba parou de responder às ferramentas do navegador.

| Ponto | Tela real |
|---|---|
| Onde ficam as intimações | Menu **Intimações → "Intimações recebidas"** (`/publications`). Na janela do processo há a aba **Intimações**, ao lado de Tarefas, Andamentos e Financeiro |
| Lista | Colunas: Processo (partes), Publicação (data de **publicação**), Tribunal, Número do processo, Responsável e Situação. Cada linha é um post (`posts/<id>/edit`). Quando há processo vinculado, a linha tem o link `lawsuits/<id>/edit` |
| Paginação | **No servidor**: o rodapé mostra "1-50 de 84" e só as 50 linhas existem na página. A varredura só fica completa se a tela mostrar todas ("Registros por página" ≥ total) |
| Filtro de período | Por data de **recebimento no ADVBOX**: Hoje, 3, 7 ou 30 dias, ou "De/Até". "Hoje" (06/11) trouxe publicações de 09/11 (disponibilizadas em 06/11) e de 04/11 |
| Linha "N/A" | Intimação capturada **sem processo vinculado**. A janela mostra "Nenhum processo vinculado / Cadastrar um novo processo". Na lista não há tribunal nem número, e o CNJ só aparece no teor ("Processo: …"). Eram 11 de 50 no dia |
| Janela da intimação | Teor integral, "Inteiro Teor" (link do tribunal), "Nome pesquisado" (Pablo Henrique de Oliveira Silva Ferreira), "Data da publicação", "Criado por" (órgão + data e hora da captura, ex.: 06/11/2026 01:21) e "Processo" |
| Repetições | 5 grupos com o mesmo CNJ e a mesma data em 50 linhas. Ex.: 4 intimações do mesmo processo do TJMG em 09/11 |

**Área de conferência (pendência 8 do Prompt Mestre), proposta:**

- usar as **Intimações** do ADVBOX: a lista "Intimações recebidas" e a aba Intimações do processo;
- **não** usar Andamentos (movimentações) como prova de captura, conforme o §17 do Prompt Mestre.

O parâmetro `advbox_area_conferencia` está como `intimacoes`, **não confirmado**.

## 2. Como funciona

1. **Publicações Webjur** (área 7): a exportação do portal, ou o e-mail, entra no banco.
2. **Varredura do ADVBOX** (extensão 0.3.0):
   - na tela "Intimações recebidas", o botão **"Registrar as intimações desta tela"** lê as linhas exibidas;
   - para cada intimação, faz o GET da janela (com intervalo de 250 ms) e envia tudo para `ext_registrar_varredura`;
   - a extensão nunca clica, filtra nem altera nada; o teste confere que ela só faz pedidos GET;
   - a varredura **só é completa** quando as linhas exibidas batem com o total do rodapé, todas as janelas foram lidas e o período De/Até foi lido. Se a lista estiver filtrada por responsável, a varredura também fica incompleta.
3. **Double check** (área 8): `double_check_executar(período de disponibilização)` compara as duas fontes e grava as conferências.

### Regra da comparação (`0016_double_check.sql`)

- **Grupo:** mesmo CNJ e mesma data de publicação. Se a Webjur não tiver a data de publicação, entram as intimações capturadas no dia da disponibilização.
- **Três medidas por par (publicação, intimação):**
  - *sobreposição:* palavras em comum ÷ palavras do texto menor;
  - *Jaccard:* palavras em comum ÷ palavras dos dois textos;
  - *distintiva:* sobreposição sem as palavras comuns a todos os textos **da mesma fonte** no grupo. Isso tira o cabeçalho de partes e advogados, que se repete em atos diferentes do mesmo processo.
- **Par aceito** quando:
  - sobreposição ≥ 0,85;
  - Jaccard ≥ 0,75;
  - distintiva ≥ 0,6, quando calculada;
  - a melhor intimação supera a segunda em pelo menos 0,1.
- **Ligação um a um:** os pares são ligados do mais forte para o mais fraco. Uma intimação nunca serve a duas publicações, nem é reaproveitada se já foi ligada em conferência anterior.
- **Resultado:**

  | Situação | Classificação |
  |---|---|
  | Ligada a intimação com processo vinculado | `encontrada_advbox` |
  | Ligada a intimação sem processo (N/A) | `processo_nao_cadastrado` (tarefa de análise "requer cadastro") |
  | Intimação livre parecida, mas sem segurança | `inconclusiva` (vai para conferência manual) |
  | Nenhuma candidata, e uma varredura **completa** cobre da disponibilização até o dia seguinte | `nao_encontrada_advbox` (tarefa de análise **preparada**, não criada) |
  | Fora disso | **aguardando**, sem gravar nada: falta de leitura não é ausência |

- **Execuções repetidas** não duplicam conferências nem tarefas.
- **Conferência manual** (`double_check_manual`, com nota obrigatória) nunca é desfeita pela execução automática.
- **Teor do ADVBOX:** o da primeira leitura é preservado. Leituras seguintes só atualizam a situação e o vínculo.
- **Relatório diário** (`double_check_diario`): por data de disponibilização, com os totais do §21. O % de ausentes considera só as conferidas de fato.

## 3. Painel — área 8 "Double check ADVBOX"

A área tem cinco partes:

- passo a passo da rotina;
- período de disponibilização, com o botão "Executar double check";
- relatório diário;
- lista de publicações com a situação, o link da intimação no ADVBOX (nova aba), a semelhança e a tarefa de análise;
- últimas varreduras, completas ou incompletas.

O botão **"Conferir"** abre um diálogo com o teor da Webjur e as intimações do mesmo CNJ, cada uma com teor e semelhança. Dele dá para registrar:

- "É esta publicação";
- "Não está no ADVBOX";
- "Processo não cadastrado";
- só a nota.

## 4. Testes

| Bateria | Resultado |
|---|---|
| Banco (`tests/test_etapa7.py`) | 36/36 |
| Extensão: leitura da tela de intimações, em réplica da estrutura real (`extensao/tests/testar_intimacoes.js`) | 20/20 |
| Painel ponta a ponta (`tests/e2e/testar_doublecheck.js`) | 16/16 |
| Regressão: banco 64, Etapa 2 64, calendário 13, auditoria 8, Etapa 4 41, Etapa 5 13, Etapa 6 54, leitor Webjur 40, publicações 26, indicadores 31, painel 40, extensão 53 | sem falhas |

Casos cobertos:

- duas intimações do mesmo processo e data, cada uma ligada à sua publicação;
- **dois atos na Webjur e só um capturado no ADVBOX**: o capturado é ligado ao ato certo, e o outro **não** é dado como encontrado;
- intimação "N/A";
- teor só parcialmente semelhante;
- varredura incompleta (paginada ou com erro de leitura);
- execução repetida;
- conferência manual;
- relatório;
- permissões.

Os testes revelaram dois problemas, que foram corrigidos antes da entrega:

- a primeira regra (só sobreposição ≥ 0,6) dava como "encontrada" uma publicação diferente do mesmo processo;
- `double_check_diario` devolvia um conjunto de linhas, cujo formato de resposta da API é ambíguo. Agora devolve uma lista JSON única.

## 5. Calibração com dados reais (07/11/2026)

A área de conferência (Intimações) foi confirmada pela controladoria. Ela também confirmou que as intimações tratadas continuam na lista. A tela mostrou isso: a lista de 30 dias trazia 345 intimações "Concluído" e 75 "Pendente".

**Amostra:** 21 intimações do ADVBOX, todas com publicação em 09/11 e capturadas em 06/11, comparadas com a exportação real do portal Webjur de 06/11. A leitura foi feita só pela tela, com o mesmo GET da janela da intimação.

| Situação real | Sobreposição / Jaccard do par correto | Pares errados do mesmo processo e data |
|---|---|---|
| DJEN, uma publicação por processo (13 casos) | 0,98–1,00 / 0,75–0,95 | — |
| DJE do TJMG, vários atos curtos no mesmo processo e data | 0,98 / 0,61–0,70 | 0,93–0,98 / 0,45–0,61. Só a *distintiva* separa (ex.: 1,00 × 0,50) |
| DJE do TJMG, 5 atos quase idênticos | — | A distintiva tem de 1 a 3 palavras e empata, então a publicação vai para conferência manual |
| Data de publicação | A "Data da publicação" do ADVBOX é igual à data de publicação da Webjur (28 de 29 processos do grupo de 09/11) | |

**Ajustes da migração 0017:**

| Regra | Valor |
|---|---|
| Jaccard mínimo sem distintiva calculada | 0,70 |
| Jaccard mínimo com distintiva calculada | 0,55 |
| Palavras próprias mínimas para a distintiva decidir | 2 |

**Ritmo de leitura:**

- Na primeira tentativa (0,25 s entre janelas), a sessão do ADVBOX caiu.
- Na segunda (1 s), o ADVBOX respondeu **HTTP 413** depois de cerca de 20 janelas.
- A extensão passou a:
  - abrir só as intimações cujo teor ainda não está no banco (`ext_intimacoes_conhecidas`);
  - esperar 4 s entre janelas, o que dá cerca de 6 minutos para 84 intimações novas;
  - parar na primeira recusa do ADVBOX, registrando a varredura como incompleta.

### Correção (07/11/2026, 19h): não houve falha de captura. O erro foi da minha verificação

Às 18h56, a lista "Intimações recebidas" que li ("1-420 de 420" em 30 dias e "1-84 de 84" em 7 dias) **não refletia o período escolhido**. Faltavam as intimações com publicação entre 03 e 06/11, que já existiam: os IDs delas são anteriores aos das que apareceram.

A leitura foi feita logo depois de trocar o filtro e o tamanho da página por automação. A causa exata não foi identificada.

**Nova leitura às 19h16** (7 dias, 187 de 187), comparada com a Webjur:

| Disponibilização → publicação | Mesmo CNJ e mesma data no ADVBOX | Mesmo CNJ, outra data | CNJ ausente da lista |
|---|---|---|---|
| 03/11 → 04/11 | 1 de 1 | 0 | 0 |
| 04/11 → 05/11 | 25 de 37 | 1 | 11 |
| 05/11 → 06/11 | 27 de 32 | 0 | 5 |
| 06/11 → 09/11 | 28 de 41 | 1 | 12 |
| 30/10 → 03/11 | 0 de 11 | 4 | 7 (fora da janela de 7 dias) |

Os casos restantes **não são conclusões**: são exatamente o que o double check completo precisa conferir.

**Lições aplicadas:**

- **Migração 0018 (trava de cobertura):** num dia com 5 ou mais publicações em que menos de 20% têm alguma intimação do mesmo CNJ no ADVBOX, o sistema **não conclui ausência**. Essas publicações ficam "aguardando", com o motivo, até uma nova varredura conferida.
- **Extensão:** ao final da varredura, mostra a contagem de intimações **por data de publicação**, para conferência visual. O LEIAME orienta a recarregar a página depois de escolher o filtro.

## 5. Pendências e limites

1. **Calibração:** feita com 21 pares reais (seção 5). Vale ampliar a amostra na homologação. Os limiares continuam como parâmetros não confirmados e podem ser ajustados sem mudar código.
2. **Teste real da extensão**, que depende do Supabase de homologação, como na Etapa 5.
3. **Área de conferência:** Intimações, **confirmada** (07/11/2026).
4. **Intimações tratadas:** **continuam na lista**, como a controladoria confirmou e a tela mostrou (345 "Concluído" em 30 dias). Mesmo assim, a varredura diária é a rotina recomendada.
6. **Suposta falha de captura entre 27/10 e 05/11:** **descartada**. Foi erro da leitura (seção 5, correção).
5. **Processo não cadastrado** (pendência 10): a tarefa fica preparada com "requer cadastro" e sem vínculo. A forma de criá-la sem processo vinculado é assunto da Etapa 8.

## Primeiro double check real — disponibilização 09/11/2026 (executado em 10/11/2026)

- Webjur: 51 publicações (planilha do portal, completa). ADVBOX: varredura nº 2, completa, 77 intimações recebidas de 07 a 10/11.
- Primeira rodada: 33 encontradas, 8 inconclusivas, 6 "não encontradas", 4 processo não cadastrado.
- A conferência manual mostrou: as 8 inconclusivas tinham uma única intimação do mesmo CNJ e data com 93–98% das palavras em comum (o cabeçalho "Intimação PROCESSO: … ||" da Webjur baixava o Jaccard); 4 das "não encontradas" eram o mesmo ato em dobro na Webjur (cópias idênticas, ou DJEN + caderno "Expediente" do DJe-MG, marcado "FINT").
- Regras aprovadas pela controladoria em 10/11/2026 (migração 0024): (1) única intimação do mesmo CNJ e data, 20+ palavras, sobreposição >= 0,9 = mesma publicação; (2) "duplicidade_webjur" quando outra publicação do mesmo CNJ e dia já foi encontrada e o texto é igual (>= 0,95) ou vem de outro caderno; não prepara tarefa e rejeita a tarefa preparada.
- Resultado final de 09/11: 39 encontradas, 6 processo não cadastrado, 4 duplicidades na Webjur, 2 ausentes a conferir (0705506-69.2024.8.01.0001, DJ AC; 5012778-32.2024.8.13.0035, DJe-MG Araguari).
- Correção da extensão 0.3.6: a opção vazia "Selecione" do filtro de responsável era lida como filtro e marcava a varredura como incompleta.
