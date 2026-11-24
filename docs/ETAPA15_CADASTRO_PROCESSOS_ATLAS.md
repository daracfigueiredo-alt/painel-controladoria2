# Etapa 15 — Robô de cadastro de processos no Atlas (14/11/2026)

**Pedido da controladoria (13/11/2026):** um robô que cadastre em massa os processos que não estão no Atlas, a partir da capa do processo. Os processos do ADVBOX também precisam estar no Atlas.

**Decisões da controladoria (14/11/2026):**
- leitura da documentação da API do Atlas autorizada;
- permissões **Gravar Processos** e **Consultar Clientes** ligadas na chave do Atlas;
- exportação de processos do ADVBOX gerada (`Base de processos 14.11.2026.xlsx`);
- cliente não encontrado no Atlas: **só listar**, o robô não cria cliente;
- processos **encerrados** no ADVBOX também são cadastrados;
- equipes do escritório: **Prime, Gold, Celeste, Delta e Êxitos**.

## O que a API do Atlas permite (documentação lida em 14/11/2026)

- **`create_lawsuit`:**
  - exige a permissão Gravar Processos, uma chave completa e o header `Idempotency-Key`;
  - campos: `clientId` (obrigatório, cliente que já existe no Atlas e fora da lixeira), `processNumber` (dígitos), `type` (lista fechada da tela), `causeValue`, `protocolDate`, `authors`, `defendants`, `notes` (até 2.000 caracteres), `relatedLawsuitId`, `contractId`;
  - **não há exclusão pela API**: o que é cadastrado fica no Atlas.
- **Tipos aceitos:** Ação Monitória; Ação de Cobrança; Busca e Apreensão (Veículos); Cumprimento de Sentença; Embargos à Execução; Execução Fiscal; Execução de Título Extrajudicial; Exibição de Documentos; Falência / Recuperação Judicial; Outros; Procedimento Comum Cível; Revisional de Contrato; Execução.
- **O que o Atlas completa sozinho:** tribunal, vara, classe, assunto e andamentos, pelo DataJud (`last_datajud_sync_at`).
- **Clientes:**
  - `list_clients` devolve nome, CPF/CNPJ (`doc_id`) e situação;
  - `create_client` existe, mas a controladoria decidiu não usar.
- **Importação por planilha:** a documentação cita uma "importação em lote" na tela do Atlas. Não foi usada, porque a API resolve.

## De onde vem cada dado

| Campo no Atlas | Origem |
|---|---|
| Cliente (`clientId`) | Cliente do ADVBOX casado com um cliente do Atlas, nesta ordem de força: CPF/CNPJ (que o ADVBOX traz entre parênteses no nome), código do cliente ("C362", "P662", "E091") e nome sem acentos. Mais de um possível = **revisar**; nenhum = **cliente não encontrado** |
| Número | "Número do processo" do ADVBOX (só CNJ com dígito verificador válido) |
| Tipo | "Tipo de ação" do ADVBOX convertido para a lista do Atlas. O que não tem correspondente vira **Outros**: agravo, superendividamento, assessoria, trabalhista |
| Valor da causa | "Expectiva/Valor da causa (R$)" |
| Data | "Data do requerimento" |
| Autores / réus | O polo do cliente vem pelo tipo de ação, porque a carteira é bancária: revisional, embargos e superendividamento = cliente autor; execução, monitória, busca e apreensão e cobrança = cliente réu. Sem regra segura (agravo, por exemplo), autores e réus ficam vazios e as partes vão para as notas |
| Notas | "Cadastrado pela controladoria a partir do ADVBOX em dd/mm/aaaa", tipo e fase no ADVBOX, juízo, processo originário, responsável no ADVBOX e, se for o caso, "Encerrado no ADVBOX em …" |

## Como funciona

1. **Importar:** na área Atlas Gestor › Cadastro de processos no Atlas, a controladoria importa a exportação de processos do ADVBOX.
   - A planilha é lida no navegador; o banco valida tudo de novo (`atlas_cadastro_importar`).
   - Linhas do mesmo processo são juntadas.
   - Processo que já está no Atlas sai da lista.
   - Processos da Webjur/CNJ fora do Atlas e fora da planilha entram como "cliente não encontrado".
2. **Clientes do Atlas:** lidos pela Edge Function `atlas-cadastro` (ação `clientes`), todo dia às 23:40 ou pelo botão. A cada leitura, a prévia é refeita.
3. **Conferir:**
   - **Prévia:** mostra exatamente o que vai para o Atlas (tipo, valor, autores, réus e notas).
   - **Revisar o cliente:** a controladoria escolhe o cliente certo (busca por nome, código ou CPF/CNPJ). A escolha dela não é desfeita pelas leituras seguintes.
   - **Cliente não encontrado:** lista e CSV.
4. **Aprovar:** marcados, ou todos da prévia (com confirmação). Pode tirar da fila antes do envio.
5. **Cadastrar:** o agendamento `controladoria_atlas_cadastro` roda a cada 2 minutos, só quando há aprovados, 15 por vez (parâmetro `atlas_cadastro_lote`). Também há o botão "Cadastrar 5 agora". Para cada processo:
   - `list_lawsuits` pelo número: se já existir, marca "já estava no Atlas" e não cria;
   - `create_lawsuit` com `Idempotency-Key` = `ctrl-cadastro-<número>-<cliente>-t<tentativa>`;
   - erro de validação = **erro** (com o campo recusado pelo Atlas);
   - falha temporária = volta para a fila (até 3 tentativas);
   - limite por minuto (429) = espera o `Retry-After`;
   - permissão recusada = para o lote inteiro.
6. **Depois do cadastro:** o processo entra na carteira do CNJ como processo do Atlas (varredura diária das intimações).

**Histórico:** importações, leituras de clientes, aprovações, cadastros e erros ficam em `atlas_cadastro_eventos`, que é imutável.

**Acesso:**
- controladoria: importa, escolhe cliente, aprova e cadastra;
- diretoria: só lê;
- peticionador e líder: sem acesso.

## Testes

| Suíte | Verificações |
|---|---|
| `tests/test_etapa15.py`: equipes, conversões, importação, casamento de cliente, autores/réus, notas, escolha manual, aprovação, fila, resultados, reimportação, histórico, permissões | 57 |
| `tests/atlas/testar_cadastro.ts` (Deno, Atlas simulado): conferência antes de criar, Idempotency-Key, já existente, validação × falha temporária, permissão recusada, 429, tempo máximo, clientes paginados, fila vazia | 16 |
| `tests/e2e/testar_cadastro_atlas.js` (planilha fictícia): importar, prévia, não encontrados com CSV, escolher cliente, aprovar marcados, confirmação do "aprovar todos", diretoria e peticionador | 21 |

**Desempenho local com a planilha real** (3.053 linhas, 2.364 processos): importação em 1,1 s; casamento com 500 clientes em 0,3 s.

**Mudança no simulador local** (`tests/e2e/servidor_local.js`): lista JSON em parâmetro do tipo array (`text[]`) passou a virar array do Postgres, como faz o PostgREST.

## Observação sobre a bateria (14/11/2026, sábado)

Bateria completa: 1.078 verificações em 35 suítes. A `tests/test_etapa12.py` deu 22/27 porque 5 verificações esperam um "D-4 hoje", que não existe em fim de semana; ela dá o mesmo resultado sem a 0048. O teste da Edge Function do Atlas (`tests/atlas/testar_edge.js`) passou a escolher a própria equipe pelo nome, já que a 0048 cadastra as cinco equipes do escritório.

## Aplicação e teste real

- **14/11/2026, 21:00:**
  - 0048 aplicada no banco de homologação;
  - Edge Function `atlas-cadastro` publicada (versão 1);
  - agendamentos `controladoria_atlas_cadastro` (a cada 2 min, só com aprovados) e `controladoria_atlas_clientes` (23:40) criados.
- **Leitura real dos clientes do Atlas:**
  - 500 clientes em 5 páginas, todos com CPF/CNPJ e 488 com código no nome;
  - **32 CPF/CNPJ aparecem em mais de uma ficha do Atlas** (clientes duplicados lá). Esses processos caem em "revisar o cliente".
- **Importação real (14/11/2026, 21:32, feita no painel):**
  - 3.053 linhas, das quais 2.389 têm número de processo válido;
  - 2.364 processos e mais 33 processos da Webjur/CNJ que estão fora do Atlas e fora da planilha.
- **Resultado da importação:**

| Situação | Processos |
|---|---|
| Já estavam no Atlas | 1.076 |
| Prévia | 618 |
| Revisar o cliente | 29 |
| Cliente não encontrado | 674 |

  - **Prévia (618), por critério de casamento do cliente:**
    - 301 por CPF/CNPJ e código;
    - 77 por CPF/CNPJ, código e nome;
    - 32 só por CPF/CNPJ;
    - 183 só pelo código do cliente;
    - 9 por código e nome;
    - 16 só pelo nome (marcados para conferir).
  - **Ponto de atenção — casamento só pelo código do cliente:** no Atlas, a ficha às vezes reúne pessoa física e jurídica com outro CPF/CNPJ. Por exemplo, G420 no ADVBOX = posto e sócio; no Atlas = uma ficha só. Vale uma conferência por amostra antes de aprovar.
  - **Sem dados no ADVBOX (dos 1.288 processos fora do Atlas):** só 362 têm "Data do requerimento" e só 203 têm valor da causa. Sem a data, o Atlas registra a data do cadastro como distribuição. Desde a 0049, as notas avisam isso.
- **Teste real com 2 processos (autorizado pela controladoria em 14/11/2026):** aprovados no painel e cadastrados pelo agendamento, às 21:34 e 21:36:
  - 4001479-08.2026.8.26.0629 (Embargos à Execução, cliente casado por CPF/CNPJ e código);
  - 5001493-02.2026.8.13.0349 (Embargos à Execução, cliente casado por CPF/CNPJ e código);
  - os dois sem erro, com o id do Atlas gravado.
- **0049 (14/11/2026):**
  - equipe **Negociações** (líder Leandro Santana);
  - Bárbara Castro passa para a diretoria e sai da lista de líderes;
  - líder de cada equipe registrado no parâmetro `equipes_lideres`: Prime = Brenda Martins, Gold = Raquel Guerra, Celeste = Guilherme Ladeia, Êxitos = Pedro Frejah, Delta = Ana Clara, Negociações = Leandro Santana;
  - a ligação no painel depende das contas dos líderes, que ainda não existem.
- **Lote aprovado pela controladoria (14/11/2026, 21:44):**
  - antes da aprovação, a prévia foi refeita com "Atualizar clientes do Atlas" (notas com o aviso da 0049);
  - 616 processos aprovados de uma vez no painel, com a confirmação.
- **E26 (0050):** a 1ª execução do lote cadastrou 9 de 15 processos. Cada processo leva cerca de 5 s (conferência, cadastro e pausas), e a função para em 45 s. Os 6 restantes voltaram para a fila, mas **contando como tentativa**: depois de 3 adiamentos virariam "erro" sem nunca terem chegado ao Atlas. Correção:
  - resultado novo `adiado`, que volta para a fila sem gastar tentativa;
  - lote de 9 por execução;
  - agendamento a cada minuto (cerca de 18 chamadas por minuto ao Atlas; o limite é 60);
  - função `atlas-cadastro` na versão 2.
- **Depois da correção:** 9 de 9 por execução, sem erro.
- **Fim do lote (14/11/2026, 22:55):**
  - **618 processos cadastrados no Atlas:** os 2 de teste e os 616 aprovados;
  - **0 erros**;
  - **0 já existentes** (a conferência pelo número antes de cada cadastro não achou nenhum);
  - 71 execuções do agendamento;
  - continuam fora: 29 em "Revisar o cliente" e 674 em "Cliente não encontrado".
- **Pendente:**
  - a controladoria conferir os 2 processos no Atlas;
  - aprovar o lote;
  - resolver os 29 casos de "revisar";
  - tratar os 674 não encontrados (cadastrar o cliente no Atlas e "Atualizar clientes do Atlas").
