# Etapa 13 — Triagem diária dos e-mails da Webjur (12/11/2026)

**Pedido da controladoria (12/11/2026):** os e-mails diários da Webjur chegam em controladoria.oecadv@gmail.com. A triagem deve ser feita todo dia, direto nessa caixa.

**Escolha da controladoria:** um script na própria conta da controladoria (Google Apps Script). A opção descartada era encaminhar os e-mails para a caixa da Mayra.

## Como funciona

1. **O script** (`integracoes/apps_script/triagem_webjur.gs`) roda na conta da controladoria todo dia, às 13h e às 17h, horário de Brasília.
   - O e-mail da Webjur chega por volta de 12h40. A execução das 17h pega os que atrasarem.
   - Ele procura os e-mails de `webjur@webjur.com.br` dos últimos 10 dias que ainda não foram tratados e envia cada um ao sistema.
2. **A Edge Function `webjur-email`** lê o e-mail com o mesmo leitor do painel (`webjur_email.js`). Depois:
   - confere a contagem declarada pela Webjur;
   - registra a remessa por `pub_registrar_remessa`, com origem `webjur_gmail`.

   O hash é o mesmo do painel. Um e-mail que já foi importado à mão é reconhecido e não é duplicado.
3. **No Gmail da controladoria**, o script marca cada conversa:
   - **Controladoria/Webjur importado:** registrado, ou já estava registrado.
   - **Controladoria/Webjur conferir:** a contagem diverge da declarada pela Webjur, ou o e-mail não foi reconhecido. Esse e-mail **não** é registrado sozinho, porque no painel essa situação exige confirmação. O aviso vai para o log de integração. Nesse caso, confira no portal da Webjur e importe a Planilha no painel.
   - **Erro de conexão:** a conversa fica sem marca e é reenviada na execução seguinte.
4. **A rotina das 18:30** (0042) roda depois e já encontra as publicações do dia para o double check.

**O script só lê os e-mails e coloca as duas marcas.** Ele não apaga, não move, não responde e não encaminha nada.

## Segurança

- O script só fala com o sistema usando um segredo próprio:
  - `WEBJUR_EMAIL_SECRET`, guardado como segredo da função;
  - `WEBJUR_SECRET`, guardado nas propriedades do script.

  Os dois têm o mesmo valor, criado e guardado pela controladoria. O Claude nunca vê esse valor.
- A chave que vai escrita no script é a **pública** do projeto, a mesma do painel. Ela só passa pela portaria da função.
- A função recusa:
  - qualquer chamada sem o segredo, informando o motivo sem mostrar o valor;
  - mais de 20 e-mails por chamada.

## Passo a passo da instalação (controladoria)

1. **Gerar o segredo.** No Supabase, abra o SQL Editor e rode:

   ```sql
   select encode(extensions.gen_random_bytes(32), 'hex');
   ```

   Copie o resultado, que tem 64 letras e números.
2. **Guardar o segredo na função.** Em Edge Functions › Secrets › Add new secret:
   - Name: `WEBJUR_EMAIL_SECRET`;
   - Value: o valor copiado.

   Depois, clique em Save.
3. **Criar o script.** Entre em https://script.google.com **com a conta controladoria.oecadv@gmail.com**.
   - Clique em Novo projeto e dê o nome "Triagem Webjur".
   - Apague o conteúdo e cole o arquivo `integracoes/apps_script/triagem_webjur.gs`.
   - Clique em Salvar.
4. **Guardar o segredo no script.** Clique na engrenagem (Configurações do projeto) › Propriedades do script › Adicionar propriedade:
   - Propriedade: `WEBJUR_SECRET`;
   - Valor: o mesmo valor do passo 1.

   Depois, clique em Salvar.
5. **Testar.** No editor, escolha a função `testarConexao` e clique em Executar.
   - O Google pede autorização. Como o script é da própria conta, o aviso "app não verificado" é esperado: clique em Avançado › Acessar Triagem Webjur.
   - O registro de execução deve mostrar "Conexão com o sistema da controladoria funcionando."
6. **Agendar.** Escolha a função `instalarAgendamento` e clique em Executar.
7. **Opcional:** escolha a função `triagemWebjur` e clique em Executar. Isso importa já os e-mails dos últimos 10 dias.

## Testes

| Suíte | Verificações |
|---|---|
| `tests/webjur/testar_funcao_email.ts` (Deno): leitor idêntico ao do painel, hash igual ao do painel, já importado, contagem divergente não registrada, e-mail estranho, encaminhamento com vários e-mails | 13 |
| `tests/webjur/testar_script_gmail.js` (Node, Gmail simulado): busca, só o remetente da Webjur, marcas e reenvio após erro | 4 |

**Conferência com um e-mail real**, sem gravar nada no banco:
- E-mail: "Public 40. UFs 29.", de 05/11/2026, anexado ao e-mail "Publicações." de 06/11.
- Resultado: 40 publicações lidas, contagem conferida, pronto para registrar.

**Teste real da função publicada (12/11/2026):** a chamada sem o segredo foi recusada com o motivo "segredo WEBJUR_EMAIL_SECRET não configurado na função", que é o esperado antes da instalação.

## Instalação real (12/11/2026, 21:15–21:33)

A controladoria fez os passos 1 a 4 e autorizou o script. O Claude fez os passos 5 a 7 no editor do Apps Script, na conta controladoria.oecadv@gmail.com.

**Erro E22 — segredos diferentes.** O script tinha um valor de 54 caracteres, com caracteres fora do formato. A função tinha o valor correto, de 64 caracteres hexadecimais.

O diagnóstico foi feito sem expor nenhum valor:
- a função passou a devolver, ao recusar, o tamanho e os 6 primeiros caracteres do SHA-256 de cada lado (versão 4);
- o script ganhou a função `diagnosticoSegredo`, que faz o mesmo do lado dele.

A controladoria gerou um valor novo e gravou nos dois lugares. Depois disso, os resumos bateram: 64 caracteres, resumo `7150d6`.

**Resultado:**
- `testarConexao`: "Conexão com o sistema da controladoria funcionando."
- `instalarAgendamento`: agendamento criado para todo dia às 13h e às 17h.
- `triagemWebjur` (últimos 10 dias): 11 e-mails enviados, 10 importados, 1 para conferir.
  - Foram registradas 10 remessas completas, de 03/11 a 12/11. Elas somam 380 publicações: 285 novas e 95 que já estavam registradas pela Planilha do portal (sem duplicar). Nenhuma foi rejeitada.
  - O e-mail para conferir é a cobrança da Webjur ("BOLETO AUTOMÁTICO"). Ele não é e-mail de publicações e corretamente não foi registrado. Ficou com a marca "Webjur conferir".
- **Ajuste (12/11/2026, 22:27, a pedido da controladoria):** a busca do script passou a ignorar as cobranças da Webjur (assunto com boleto, fatura, cobrança ou nota fiscal). A execução de conferência não teve nada pendente (0 enviados, 0 erros). O boleto de 12/11 continua com a marca "Webjur conferir", que pode ser retirada no Gmail.
