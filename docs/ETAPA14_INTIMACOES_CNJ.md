# Etapa 14 — Intimações do CNJ e double check sem o módulo do Atlas (12/11/2026)

**Decisão da controladoria (12/11/2026):** o escritório não vai contratar o módulo de intimações do Atlas, mas o double check continua necessário. As intimações passam a ser capturadas direto no CNJ, pela API pública de comunicações do Diário de Justiça Eletrônico Nacional (DJEN).

**Confirmações da controladoria:**
- OAB monitorada: OAB/MG 176.787 (Pablo);
- varredura por processo **diária**, porque há processos de interesse do escritório em que o Pablo não está cadastrado nos autos;
- permissão "Ler Processos" ligada na chave do Atlas.

## Fonte

- **API:** `GET https://comunicaapi.pje.jus.br/api/v1/comunicacao`, pública. Aceita os filtros `numeroOab`/`ufOab` ou `numeroProcesso`, `dataDisponibilizacaoInicio`/`Fim`, `itensPorPagina` (até 100) e `pagina`.
- **Teste real em 12/11/2026, chamando a partir do Supabase (São Paulo):**
  - por OAB, 33 comunicações disponibilizadas em 11/11;
  - por processo, 11 comunicações;
  - uma vez a API respondeu "O sistema está muito ocupado".
- **Campos usados:** id, tribunal, órgão, classe, tipo de comunicação e de documento, data de disponibilização, texto integral, link da certidão, destinatários e advogados.
- **Ligação exata com a Webjur:** o "Identificador do documento" da Webjur é o **id da comunicação no CNJ**.
- **Limite:** diários estaduais próprios, fora do DJEN, não aparecem nesta fonte. Por isso a Webjur continua necessária. Exemplo: "FBH BELO HORIZONTE" do DJ de Minas.

## Como funciona

| Rotina (Brasília) | O que faz |
|---|---|
| 23:45 | **Carteira:** processos do Atlas (`list_lawsuits`) mais os processos já conhecidos pelo sistema |
| 00:00 a 06:58, a cada 2 min | **Varredura por processo:** 12 processos por execução, cobrindo os últimos 7 dias. A capacidade é de cerca de 2.500 processos por noite. O que falhar volta para a fila depois de 20 minutos |
| 06:20 e 17:20 | **Consulta por OAB** (últimos 3 dias) |
| 18:30 | **Double check** (rotina do fim do expediente, 0042) |

- **Edge Function:** `cnj-captura`. Autorização pelo segredo do agendamento ou pela controladoria logada no painel.
- **Instabilidade da API:** cada consulta é repetida até 4 vezes, com espera crescente.
- **Tabelas:**
  - `cnj_comunicacoes`;
  - `cnj_carteira`, com a fila diária;
  - `cnj_execucoes`, histórico imutável.
- **Parâmetros:** `cnj_oabs`, `cnj_janela_dias`, `cnj_lote_processos` (12), `cnj_captura_url` e `atlas_modulo_intimacoes` (false).

## Double check (novo tipo "Captura divergente CNJ × Webjur")

1. **Comunicação do CNJ não capturada pela Webjur** (gravidade alta). Só conta quando:
   - a comunicação é do dia anterior em diante;
   - não há publicação com o mesmo identificador;
   - não há publicação do mesmo processo e data que não pertença a outra comunicação.

   Listas de distribuição ficam de fora.
2. **Publicação da Webjur no DJEN que o CNJ não mostra** (gravidade média). Só vale para processo já varrido depois da publicação. Pode indicar comunicação cancelada.
3. **Pendências:**
   - varredura do dia incompleta;
   - consulta por OAB que não rodou no dia.
4. **A cobrança "intimações do Atlas não sincronizadas" foi desligada**, porque o módulo não foi contratado.

Os itens corrigidos saem sozinhos na execução seguinte, como antes.

## Painel

- **Publicações e intimações › Intimações CNJ:**
  - indicadores: comunicações no período, sem captura da Webjur, processos na carteira, consultados hoje;
  - filtros por período, por situação ("sem captura da Webjur") e por busca;
  - texto integral e link da certidão;
  - botões da controladoria: consultar pela OAB, consultar 20 processos da fila, atualizar a carteira.
- **Double check de intimações:** passou para o grupo Publicações e intimações. O botão "Sincronizar intimações do Atlas" foi trocado por "Consultar o CNJ pela OAB".
- **Acesso:** controladoria e diretoria leem. Só a controladoria consulta.

## Aplicação e teste real (12/11/2026, 22:50–23:00)

- **No banco de homologação:** 0044 a 0047 aplicadas; Edge Function `cnj-captura` publicada (versão 2); três agendamentos ligados, além do das 18:30:
  - `controladoria_cnj_carteira`;
  - `controladoria_cnj_lote`;
  - `controladoria_cnj_oab`.
- **Carteira:** 14 páginas de processos do Atlas, com **1.320 processos**. Somados aos já conhecidos, são **1.820 processos** na varredura diária.
- **Consulta por OAB (09 a 12/11):** 160 comunicações. Conferência com a Webjur pelo identificador exato:
  - 09/11: 46 de 47;
  - 10/11: 33 de 34;
  - 11/11: 29 de 33, sendo 1 delas lista de distribuição;
  - 12/11: 22 de 46, porque a Webjur de 12/11 só chega em 13/11.
- **Varredura por processo:**
  - 1º lote: 24 processos consultados, e então a função parou por limite de recursos (E23);
  - depois do ajuste: 12 de 12 consultados e **5 comunicações que a busca por OAB não pegou**.
- **Double check real:**
  - 249 publicações da Webjur conferidas;
  - **10 comunicações do CNJ não capturadas pela Webjur, entre 06/11 e 11/11**, em TJPR, TJGO, TJSP, TRF3 e TJMG;
  - 9 publicações duplicadas, todas sem identificador, a mesma publicação vinda da Planilha do portal e do e-mail;
  - pendências: varredura incompleta (36 de 1.820, normal antes da 1ª madrugada) e 2 publicações sem número de processo.
  - Tempo: 0,2 s.

**Achados e correções:**
- **E23:** a varredura com 40 processos por execução esgotou os recursos da Edge Function (`WORKER_RESOURCE_LIMIT`) depois de 24 consultas. Mudanças:
  - 12 processos por execução;
  - limite de 50 s por execução;
  - pausa de 0,8 s entre consultas;
  - agendamento a cada 2 minutos.
- **E24 (0046):** a guarda da 0043 deixava de fora da conferência as publicações da Webjur quando não havia intimações do Atlas sincronizadas. Por isso a 1ª conferência mostrou "0 publicações conferidas". Sem o módulo, as publicações voltam à conferência. A comparação com intimações do Atlas só roda se houver sincronização.
- **E25 (0047):** publicações com o mesmo texto, processo e data, mas **identificadores diferentes**, eram apontadas como duplicadas. Elas são comunicações distintas (uma para cada parte) e deixaram de ser apontadas.

## Limite conhecido: CNJ × tarefas do Atlas

As tarefas que a API do Atlas devolve **não trazem o número do processo**. Na base atual, nenhuma das 530 tarefas tem o processo preenchido, e a busca no texto da descrição achou o número em apenas 1. Por isso, a comparação "intimação sem tarefa no Atlas" ainda não é feita.

O diagnóstico de 12/11 (ação `diagnostico`, que mostra só os nomes dos campos) indica que `list_tasks` tem os campos `lawsuit_id` e `lawsuit_number`. Mesmo assim, eles vêm vazios nas tarefas atuais: as tarefas não estão vinculadas a processos no Atlas.

Se a equipe passar a vincular a tarefa ao processo no Atlas, a comparação "intimação do CNJ sem tarefa no Atlas" pode ser ligada. A sincronização já recebe esses campos.

## Testes

| Suíte | Verificações |
|---|---|
| `tests/test_etapa14.py`: carteira, fila, registro, painel, double check CNJ × Webjur (0044, 0046, 0047), permissões | 43 |
| `tests/cnj/testar_captura.ts` (Deno, API simulada): repetição quando a API está ocupada, paginação, lote, limite de tempo, OAB, carteira sem permissão | 14 |
| `tests/e2e/testar_cnj.js`: tela de Intimações CNJ e double check, para controladoria, diretoria e peticionador | 15 |

## 16/11/2026 — Módulo de intimações do Atlas ativado (0054)

A controladoria ativou o módulo de intimações no Atlas. Em consequência:
- o parâmetro `atlas_modulo_intimacoes` passou a `true`;
- o botão "Sincronizar intimações do Atlas" voltou ao Double check de intimações, ao lado de "Consultar o CNJ pela OAB";
- a captura do CNJ continua.

O double check fica em três pontas:
- **CNJ × Webjur:** captura;
- **Webjur × Atlas:** cadastro;
- **audiências:** pendências.

**Teste real (16/11/2026, 10:57, rotina do fim do expediente rodada à mão):**
- **Tarefas:** 529, com 1 nova.
- **Intimações do Atlas:** **0**. A chamada foi aceita, o que indica módulo ativo e permissão ligada, mas o Atlas ainda não tinha intimação capturada logo depois da ativação.
- **Efeito enquanto o Atlas não tiver nenhuma intimação:**
  - o double check aponta "intimações do Atlas não sincronizadas hoje";
  - deixa de conferir as publicações da Webjur (regra da 0043/0046: com o módulo ligado, a conferência espera a 1ª sincronização).

  Isso se resolve sozinho na 1ª sincronização com intimações.
- **Varredura por processo:** 159 comunicações do CNJ não capturadas pela Webjur entre 06/11 e 13/11 (de 23 a 32 por dia). Com a varredura noturna de toda a carteira (mais 618 processos cadastrados no Atlas em 14/11), o CNJ passou a trazer comunicações de processos fora da OAB monitorada pela Webjur.
