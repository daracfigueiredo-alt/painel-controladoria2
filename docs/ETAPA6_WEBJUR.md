# Etapa 6 — Módulo Webjur (06/11/2026)

## 1. Comparação das fontes (inspeção somente leitura)

**Assinatura do escritório:** OAB/MG 176.787 (Pablo Henrique Oliveira Silva Ferreira). Ela é a única capturada pelo escritório, como a controladoria confirmou em 06/11/2026.

Os 4 e-mails "Fwd: Public N. UFs 28." de set/2026 são de outra assinatura: OAB/MG 183.947, encaminhados por terceiros. Eles servem só como **amostra de formato**.

Fontes conferidas em 06/11/2026:

- o e-mail "Publicações." enviado por controladoria.oecadv@gmail.com à caixa de Mayra, com 3 e-mails da Webjur no corpo e 16 e-mails `.eml` anexados;
- o portal, aberto pela própria usuária. Foram feitas só consultas: "Consultar" e "Visualizar tudo" para 05/11/2026. Nenhuma marcação, agenda, comentário, impressão ou exportação foi feita.

| Ponto | E-mail diário | Portal (historico.webjur.com.br) |
|---|---|---|
| Como chega | Automático em controladoria.oecadv@gmail.com | Login com OAB + senha (sessão aberta pela usuária) |
| Agrupamento | Por **leitura** do diário. Ex.: o e-mail de 05/11 trouxe no DJ Paraná uma publicação **disponibilizada em 04/11** | Por **data de disponibilização**, publicação ou envio (filtro "Data de envio") |
| Contagem de 05/11 | 40 (PR = 4, incluindo a de 04/11) | 39 por disponibilização (PR = 3). As duas fontes batem quando se usa a disponibilização |
| Campos | Datas, jornal, caderno, local, página, teor, link e "Identificador do documento" (este em ~90% das publicações) | Datas, jornal, **tribunal**, caderno, **vara**, título, **número do processo em campo próprio**, página, teor e **id interno** de cada publicação |
| Teor integral | Sim | **Truncado na lista** ("..."). O teor integral exige "Exibir conteúdo completo" (postback por publicação) |
| Exportação | — | Planilha, XML (CPJ / TOTVS), TXT, PDF e RTF, por publicação ou para todas. **Não testada** (gera download) |
| Ações com efeito na tela | — | Selecionar (estrela), agendar, comentar e marcar impressão alteram dados no portal. O sistema **não pode** clicar nelas |
| Confiabilidade | A própria Webjur avisa que o envio "não é infalível" e que pode haver e-mail de revisão | Indicado pela Webjur como referência |

**Exportações reais do portal** (06/11/2026, consulta por disponibilização em 05/11/2026, 39 publicações):

| Formato | Resultado |
|---|---|
| **Planilha (.csv)** | `;` sem aspas, Windows-1252, CRLF. Colunas: código Webjur, UF, datas de disponibilização e publicação, comentário, tribunal, página, nº do processo, local (órgão), cidade, tipo e **teor integral** (12º campo, sem nome no cabeçalho). Termina com "TOTAL DE PUBLICAÇÕES:;39;". Acentos íntegros. **Adotado** |
| XML 1 (CPJ) | **Acentos destruídos na própria exportação** (632 caracteres "�", embora o arquivo declare ISO-8859-1) e sem o código Webjur. **Não usado** |

**Comparação real, portal × e-mail (05/11/2026):** 39 publicações no portal e 39 disponibilizadas em 05/11 no e-mail.

- **Todas se correspondem**: 35 pelo "Identificador do documento" e 4 pelo conteúdo (diários estaduais de MG, sem identificador).
- O portal traz o órgão completo onde o e-mail traz uma sigla. Ex.: "TRIBUNAL DO JÚRI – 2º PRESIDENTE DA COMARCA DE BELO HORIZONTE" × "FBH BELO HORIZONTE".

**Decisão:** a **fonte principal é a exportação "Planilha" do portal**, importada no painel. O **e-mail é a contingência e a segunda contagem**. Isso segue a regra do Prompt Mestre para o caso de o portal ser mais confiável.

O parâmetro `webjur_fonte_principal` está como `portal_exportacao_planilha`, mas **não confirmado**: falta a confirmação da controladoria.

## 2. Leitor do e-mail (`painel/js/webjur_email.js`)

Roda no navegador; não usa rede nem biblioteca. Aceita `.eml` (MIME multipart, quoted-printable, base64, charset), `.html` e texto colado.

Dois formatos de bloco foram encontrados nos e-mails reais e ambos são lidos:

- **Diários estaduais (DJEN):** Caderno + Local ("DJEN - … - TJAL - 6ª Vara Cível") → tribunal TJAL, órgão "6ª Vara Cível";
- **Tribunais Superiores:** Tribunal + Vara/Seção ("DJEN - … - STJ" ou "Tribunal Regional Federal da 1ª Região - …").

O CNJ vem do cabeçalho "PROCESSO:" do teor. Se não houver cabeçalho e o teor citar mais de um CNJ, **nenhum é escolhido** e a publicação fica com o alerta `cnj_ambiguo`.

**Alertas por publicação:** sem CNJ, CNJ ambíguo, dígito do CNJ inválido, teor que cita vários CNJ, datas inválidas, sem identificador do documento, tribunal não identificado e teor vazio.

**Conferência de completude:** a contagem de cada diário é comparada com o total declarado pela Webjur no cabeçalho, no rodapé, no resumo e na chave "Public N. UFs M.". Quando a contagem diverge, o painel só registra depois de uma confirmação explícita, e a divergência fica gravada.

**Resultado nos e-mails reais** (guardados fora do git), em 5 arquivos com 7 e-mails e 122 publicações: todos completos e sem avisos de contagem.

Os e-mails do escritório (03, 04 e 05/11/2026; 12, 51 e 40 publicações) mostraram três situações que o leitor passou a tratar:

- **vários e-mails num só arquivo:** cada um vira uma remessa;
- **o mesmo diário e data em duas seções** (DJ Minas Gerais 04/11: 25 + 4): tratado na migração 0014;
- **diários estaduais próprios (DJE)**, sem "Local" DJEN. Ex.: caderno "TJMGFBH" e local "FBH BELO HORIZONTE": o tribunal vem da sigla do caderno.

Alertas restantes nos reais: 13 publicações sem identificador do documento, 11 com vários CNJ no teor, 1 com processo ambíguo (lista de distribuição do TJPR) e 2 com tribunal não identificado (TRF3 com a linha "Tribunal:" vazia).

**Resultado anterior, nos 4 e-mails de amostra** (set/2026):

- 19 publicações lidas em 4 e-mails, 19 declaradas e nenhum aviso;
- todas com CNJ válido e tribunal identificado;
- 1 sem identificador do documento: uma ata de distribuição do TRF1.

## 3. Banco (migração `0013_webjur_coleta.sql`)

| Item | O que faz |
|---|---|
| `publicacoes.id_documento` | Identificador da Webjur, único quando existe |
| Identificação | 1º pelo identificador; 2º por CNJ + data + teor. Mesmo CNJ, data e teor com **identificadores diferentes** = publicações distintas. Mesmo identificador com teor diferente = mesma publicação, original mantido, aviso no log e a nova versão guardada na coleta |
| `webjur_remessas` | Um registro por e-mail importado. Guarda o hash SHA-256 do arquivo (**o mesmo arquivo nunca entra duas vezes**), a chave, o cliente, as seções com o total declarado e o recontado pelo servidor, a situação (`completa`/`divergente`) e os avisos do leitor. É imutável |
| `publicacoes_coletas` | Ganha `conteudo_original` (registro bruto daquela fonte) e `remessa_id`. Nova origem `webjur_email` |
| `pub_registrar_remessa` | Só admin; até 500 publicações; recontagem no servidor; uma remessa divergente gera aviso no log de integração |
| `pub_registrar` | Mesma assinatura da 0008, agora com a identificação acima |
| `pub_listar` / `pub_detalhe` | Total exato + até 500 linhas; filtros: período, CNJ/tribunal/identificador, conferência, com alerta, origem. O detalhe traz teor, coletas (com "teor igual/diferente") e conferências |
| `v_publicacoes` | Colunas novas no fim: `id_documento`, `jornal`, `alertas_leitura`, `n_coletas` |
| **0014** `pub_registrar_remessa` | Quando o leitor informa a ordem da seção, a recontagem e o identificador da coleta usam a ordem. Assim duas seções do mesmo diário e data não geram divergência falsa. Sem a ordem, mantém o comportamento da 0013 |
| **0015** identificação entre fontes | (0) Código da publicação na fonte (código Webjur do portal): a mesma publicação em outra exportação é reconhecida. (b) Códigos Webjur diferentes com o mesmo CNJ, data e teor = publicações distintas. (c) **Entre fontes diferentes, sem identificador comum:** mesmo CNJ + mesma disponibilização + teor equivalente sem acentos, pontuação e espaços (igual, um terminando com o outro, ou o trecho 41–400 de um contido no outro, com tamanhos de 80% a 125%). Só casa com publicação que ainda não tem coleta da mesma origem, e cada caso fica no log de integração. `teor_solto()` |
| **0015** `pub_registrar_remessa` | Aceita o `id_origem` de cada publicação (código Webjur) |
| Remessa por e-mail | O hash da remessa é o do conteúdo da Webjur (a partir de "Cliente"), não o do arquivo. O mesmo e-mail que chega sozinho e depois dentro de um encaminhamento é reconhecido como já importado |

Campos de cada publicação:

- CNJ original e normalizado;
- disponibilização e publicação;
- tribunal, órgão julgador e fornecedor;
- teor integral e URL;
- horário da coleta e de envio, e origem;
- situação da conferência e vínculos (processo, tarefa de análise);
- conteúdo original na publicação e em cada coleta.

**Resumo:** não é preenchido, porque o e-mail não traz resumo e o sistema não inventa um.

## 4. Painel — área 7 "Publicações Webjur"

A importação aceita a **exportação do portal (.csv)** e o e-mail (.eml, .html ou texto colado). A prévia do portal mostra a contagem por UF e os códigos Webjur e confere o total do fim do arquivo. Leitor: `painel/js/webjur_portal.js`.


A área tem quatro partes:

1. **Importação** de arquivos ou de texto colado, com prévia: diários com publicação, publicações com alertas, conferência da contagem e botão de registro. Quando a contagem diverge, o botão só é liberado depois de confirmar.
2. **E-mails importados**: as últimas 30 remessas, com o número de novas e rejeitadas e a situação da contagem.
3. **Publicações registradas**, com filtros e total exato.
4. **Detalhe** com teor integral, dados do diário, link do documento (`rel=noopener`), coletas e conferências.

## 5. Testes

| Bateria | Resultado |
|---|---|
| Leitor (`tests/webjur/testar_leitor.js`): e-mails e exportações fictícios + 7 e-mails e 1 exportação reais | 40/40 |
| Banco (`tests/test_etapa6.py`), incluindo o real: 3 e-mails do escritório e depois a exportação de 05/11, com **0 novas e 39 já registradas (35 + 4)** | 54/54 |
| Painel ponta a ponta (`tests/e2e/testar_publicacoes.js`, Chromium, RLS real) | 26/26 |
| Regressão: banco 64, Etapa 2 64, calendário 13, auditoria 8, Etapa 4 41, Etapa 5 13, painel 40, indicadores 31, extensão 53 | sem falhas |

O teste do calendário reaplicava "a última migração" esperando a 0009. Agora ele aponta a 0009 pelo nome. Era um defeito do teste, revelado pela 0013.

Os e-mails fictícios (`tests/webjur/gerar_fixtures.py`) reproduzem a marcação real. Eles cobrem estes casos:

- duas publicações do mesmo processo e da mesma data com teores diferentes;
- uma publicação de Tribunal Superior sem identificador;
- um e-mail de revisão;
- mesmo conteúdo com identificadores diferentes;
- contagem divergente.

## 6. Pendências e limites

1. **Confirmar a fonte principal** (portal, exportação Planilha) para marcar o parâmetro como confirmado.
2. **Rotina diária:** no portal, consultar por **data de disponibilização** (ou de envio), "Exportar todas" → Planilha, e importar no painel. Exportações com períodos que se sobrepõem não duplicam nada: o código Webjur reconhece a publicação.
3. **Encaminhamento automático** de controladoria.oecadv@gmail.com para mayra.gomes.oecadv@gmail.com: a usuária vai criar a regra (06/11/2026). Enquanto não houver leitura automática, o e-mail é importado no painel quando servir de contingência.
4. **Correspondência por conteúdo:** é aproximada por natureza. Ela só atua entre fontes diferentes, sem identificador comum, com o mesmo CNJ e a mesma disponibilização, e fica no log. No caso real: 4 de 39.
5. **Pesquisa retroativa** (Word, set–out/2026): de outra assinatura e formato, não conferida.
6. **Data de referência do double check:** a **disponibilização**.
7. Testes com Supabase real continuam pendentes (homologação).
