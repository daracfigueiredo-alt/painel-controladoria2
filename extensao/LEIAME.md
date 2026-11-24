# Extensão da Controladoria para o ADVBOX — versão de teste 0.3.2

A versão 0.2.0 foi ajustada à **estrutura real do ADVBOX**, conferida em 06/11/2026 em uma tarefa da própria controladoria, só com leitura. O que mudou em relação à 0.1 está em `docs/ETAPA5_EXTENSAO.md`.


> **Atualização 0.7.0 (17/11/2026) — Atlas Gestor.** A extensão atua também no Atlas (desde a 0.5.0, ver `docs/ETAPA11_ATLAS.md`). Na 0.7.0:
> - **concluir ou "Dar baixa na minha parte"** pede uma **justificativa** (mínimo de 15 caracteres), depois de conferido o início da tratativa; sem justificativa, a conclusão não chega ao Atlas;
> - **mudar a tarefa para "em andamento"** registra na hora o **início da tratativa**;
> - para atualizar: `chrome://extensions` › **Recarregar** na extensão (cada pessoa da equipe). Conclusão feita sem a 0.7.0 aparece no double check como "Conclusão sem justificativa" a partir de 18/11/2026.
> Detalhes em `docs/ETAPA18_CONCLUSAO_ANDAMENTO_REAGENDAMENTO.md`.

## O que ela faz

### Leitura da janela da tarefa

Quando uma tarefa é aberta no ADVBOX, a extensão lê os dados visíveis:

- o ID real da tarefa, conferido em dois lugares: o botão "Concluir" e o `?t=` da URL;
- o título, a data do evento e o prazo fatal;
- "Criado por", com data e hora;
- o processo (só o número CNJ);
- as partes;
- os responsáveis;
- a anotação "PF:".

Depois consulta a controladoria. A cada reabertura da tarefa, a consulta é refeita.

### Painel e início da tratativa

A janela da tarefa ganha um painel com o botão **Iniciar tratativa**. O horário gravado é o do servidor, então não há como registrar um início com data retroativa.

### Travas

- **Trava 1 — conclusão sem início:** a extensão intercepta o clique antes de o ADVBOX processá-lo. Isso vale para:
  - o botão **Concluir** da janela;
  - o círculo **Resolvido** da lista de compromissos, que conclui sem abrir a tarefa.

  As intimações capturadas pelo ADVBOX (grupo "publication" da lista) ficam fora dessa trava.
- **Travas 2 e 3 — realocação e prazo fatal:** atuam no formulário **Editar tarefa**, que é onde data, prazo fatal e responsáveis mudam de verdade. A extensão acrescenta ao formulário o campo **"Justificativa (controladoria)"**. Esse texto vai só para a controladoria, nunca para o ADVBOX.
- **Encaminhar:** a operação é registrada, com campo de justificativa, mas **nunca bloqueada**. Ainda falta confirmar se encaminhar troca o responsável ou só notifica.
- **Atribuir tarefa:** cria uma tarefa **nova**, por isso não passa por nenhuma trava. A versão 0.1 tratava esse formulário como realocação, o que estava errado.

### Registro das tentativas

Cada tentativa fica registrada com um destes estados: `bloqueio_efetivo`, `permitida_apos_validacao`, `violacao_detectada` ou `nao_monitorada`. O banco confere o estado declarado pela extensão e reclassifica o que não se sustenta.

Os eventos que não puderem ser enviados ficam numa fila e são reenviados depois.

### Double check — tela "Intimações recebidas" (0.3.0, Etapa 7)

Na tela **Intimações recebidas** (`/publications`), quem está logado na extensão vê o botão **"Registrar as intimações desta tela"**. Ele faz o seguinte:

- lê as linhas exibidas;
- abre cada intimação **ainda não lida** pelo mesmo pedido que a tela faz em "Ver intimação" (GET, uma a cada 4 s; 84 intimações novas levam cerca de 6 minutos);
- para na primeira recusa do ADVBOX (em 07/11/2026, depois de ~20 janelas em 25 s, ele respondeu HTTP 413) e registra a varredura como incompleta;
- envia o lote à controladoria (`ext_registrar_varredura`, só administrador).

Ele **não clica, não filtra e não altera nada** no ADVBOX.

A varredura só serve para concluir que uma publicação **não** foi capturada quando está **completa**. Para isso:

- a tela precisa mostrar todas as intimações ("Registros por página" ≥ total do rodapé "1-N de M");
- a lista não pode estar filtrada por responsável;
- todas as janelas precisam ter sido lidas.

Uma varredura incompleta também é registrada, mas não conclui ausência.

**Antes de clicar:** escolha o período, **recarregue a página (F5)** e confira na lista se aparecem as datas esperadas. Ao final, a extensão mostra quantas intimações viu por data de publicação. Em 07/11/2026, uma lista "completa" lida logo depois de trocar o filtro não trazia as intimações de 03 a 06/11. Desde então, o banco também se recusa a concluir ausências em massa num dia em que quase nada bate (migração 0018). Detalhes em `docs/ETAPA7_DOUBLE_CHECK.md`.

## Limites (não são bloqueios do ADVBOX)

- **Onde funciona:** só neste navegador, com a extensão instalada, ativa e com login feito. Pelo celular, por outro navegador ou com a extensão desligada, nada é verificado. Por isso a importação diária continua apontando, depois do fato, conclusões sem início (`v_tratativa`) e alterações sem justificativa (`v_reagendamentos`).
- **Sem login ou sem conexão:** a extensão **não bloqueia**. Ela registra a operação como `nao_monitorada` e o painel avisa que a tarefa não está sendo monitorada.
- **Outros caminhos de conclusão:** arrastar a tarefa no Quadro (kanban) e as telas Agenda e Atividades ainda não foram conferidos. Essas telas carregam o conteúdo dinamicamente, e a extensão vigia o mesmo botão em qualquer página do ADVBOX.
- **Mudanças no ADVBOX:** se a tela mudar, a leitura ou a interceptação podem parar de funcionar. Cada trava precisa ser testada de novo após qualquer atualização do ADVBOX.
- **Modos iniciais** (tabela `parametros`):
  - conclusão: **bloquear**;
  - realocação e prazo fatal: **observar**. Nesses dois casos a extensão só registra, sem bloquear, até o teste com uma tarefa autorizada no ADVBOX real.

## Testes já feitos

**Testes automatizados com dados fictícios:** 53 de 53 aprovados (`tests/resultado_testes_extensao.txt`). Eles rodam numa **réplica** da estrutura real (`tests/advbox_real_ficticio.html`), com os handlers jQuery no documento, como no ADVBOX.

**Leitura na tela real (06/11/2026, 1 tarefa, sem gravar nada):** o leitor desta versão extraiu corretamente:

- o ID, igual no botão e na URL;
- o título ("Análise do Caso"), as datas, "Criado por", o CNJ, as partes e o responsável;
- os títulos das linhas da lista.

**Ainda não feito no ADVBOX real:** clicar de verdade em Concluir ou em Editar com a extensão instalada. Esse teste exige uma tarefa criada só para isso, com autorização.

## Instalação para teste (homologação)

1. Em `config.js`, preencha a URL do projeto Supabase de homologação e a chave **anon**.
2. No Chrome, abra `chrome://extensions`, ative o **Modo do desenvolvedor**, clique em **Carregar sem compactação** e selecione a pasta `extensao`.
3. Clique no ícone da extensão e entre com a conta da controladoria. É a conta do sistema da controladoria (Supabase), não a do ADVBOX.

## Roteiro de teste no ADVBOX real (com uma tarefa de teste autorizada)

1. **Painel:** abra a tarefa. O painel deve aparecer com "Tratativa ainda não iniciada".
2. **Conclusão bloqueada na janela:** clique em **Concluir** sem ter iniciado a tratativa. A tarefa deve continuar pendente, inclusive depois de recarregar a página.
3. **Conclusão bloqueada na lista:** feche a tarefa e clique no círculo **Resolvido** dela na lista. A tarefa também deve continuar pendente.
4. **Conclusão liberada:** abra de novo a tarefa, clique em **Iniciar tratativa** e depois em **Concluir**. A conclusão deve passar.
5. **Reabertura:** reabra a tarefa, se o ADVBOX permitir. Em **Editar tarefa**, altere a data e salve sem justificativa: no modo observar, a alteração passa e fica registrada como `violacao_detectada`. Repita com justificativa e confira o registro.
6. **Encaminhar:** encaminhe a tarefa e confira no ADVBOX se o responsável mudou. Isso fecha a dúvida sobre o significado de "Encaminhar".
7. **Conferência no painel:** abra a tela **Tratativa** do painel e veja os eventos das travas.
