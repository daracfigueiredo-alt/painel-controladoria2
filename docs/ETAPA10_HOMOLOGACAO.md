# Etapa 10 — Relatório de homologação (10/11/2026)

**Ambiente:**
- **Banco:** Supabase `controladoria-homologacao` (São Paulo), migrações 0001 a 0034.
- **Painel:** local (`iniciar_painel.bat`).
- **Extensão:** 0.4.3 no Chrome da controladoria.
- **Sistemas:** ADVBOX e portal Webjur reais.
- **Período dos testes reais:** 07/11/2026 a 10/11/2026.

**Regra deste relatório (Prompt Mestre, parte X):** os testes **reais** (no ADVBOX, na Webjur e no Supabase de homologação) estão separados dos testes **automatizados**, que usam banco local e páginas simuladas com dados fictícios. Nenhum teste simulado é apresentado como real.

## 1. Resumo

| | Quantidade | Aprovados | Reprovados |
|---|---|---|---|
| Testes **reais** (ADVBOX, Webjur e Supabase de homologação) | 21 | 21, sendo 10 após correção | 0 em aberto |
| Verificações **automatizadas** (21 suítes) | 651 | 651 | 0 |
| Erros encontrados nos testes reais e corrigidos | 21 | — | — |
| Itens ainda não testados no ambiente real | 5 | — | — |

**Situação:** o sistema atende os critérios de aceite do §28 no ambiente de homologação, com as limitações da seção 6. As regras provisórias foram confirmadas em 10/11/2026 (seção 7). As importações sucessivas (R21) foram aprovadas após a correção E20. Faltam os testes reais da seção 5 antes da produção.

## 2. Testes reais realizados

| # | Teste | Data | Evidência (banco de homologação) | Resultado |
|---|---|---|---|---|
| R1 | Implantação do banco: migrações em ordem, RLS em todas as tabelas, cadastro público desligado | 07/11, atualizado em 10/11 | 0001–0034 aplicadas; 22 tabelas, todas com RLS (tabela `auditoria_configuracao` incluída) | Aprovado |
| R2 | API real sem login, só com a chave publicável | 10/11 | 12 tabelas e visões: **401**. 5 funções: **401**. Cadastro de usuário: **422** (`signup_disabled`) | Aprovado |
| R3 | Colaborador vê só as próprias tarefas e alertas, sem as áreas de administrador | 07/11 | Conferido pela controladoria com a conta de teste (ALICE PACHECO FENOS) | Aprovado |
| R4 | Importação real do Excel do ADVBOX | 07/11 | Lote 5: 4 arquivos, 3.571 linhas, 0 rejeitadas, 3 duplicadas descartadas, 87 ambíguas sem vínculo, 3.481 tarefas novas | Aprovado após correção (E1) |
| R5 | Indicadores com dados reais: consistência e reprodutibilidade | 07/11 e 10/11 | Mesma consulta 2 vezes, resultado idêntico. Visão de tarefas idêntica (hash) antes e depois da correção. 662 pendentes = 662 linhas pendentes importadas | Aprovado após correção (E2, E16) |
| R6 | Extensão identifica a tarefa aberta e registra a data de criação e a tela | 07/11 a 10/11 | 15 tarefas com data de criação lida no ADVBOX; 13 com retrato da tela | Aprovado após correção (E3, E4) |
| R7 | Trava de conclusão sem início da tratativa | 07/11 | Tarefa 296818574: conclusão **bloqueada** às 21:47; após o início, às 21:56, conclusão **permitida** | Aprovado |
| R8 | Registro do início da tratativa | 07/11 e 10/11 | Tarefas 296818574 e 296831568 | Aprovado |
| R9 | Realocação e encaminhamento | 08/11 e 10/11 | Sem justificativa: "violação detectada" (modo observar). Com justificativa: "permitida após validação", inclusive o encaminhamento ao PROTOCOLO | Aprovado (modo observar) |
| R10 | Alteração do prazo fatal | 10/11 | Tarefa 296831568: alteração com justificativa registrada como "permitida após validação" | Aprovado (modo observar) |
| R11 | "Editar tarefa" no ADVBOX recria a tarefa com outro ID | 10/11 | 2 reedições ligadas à tarefa original; tratativa e histórico preservados | Aprovado após correção (E5, E6) |
| R12 | Varredura de "Intimações recebidas" no ADVBOX | 10/11 | 77 intimações lidas de 77 (07/11 a 10/11). A 1ª varredura saiu como incompleta por erro de leitura do filtro | Aprovado após correção (E7) |
| R13 | Importação do CSV do portal Webjur (fonte principal) | 10/11 | 1 remessa: 51 publicações, 51 declaradas pela Webjur, situação "completa" | Aprovado |
| R14 | Double check Webjur × ADVBOX de um dia real (09/11) | 10/11 | 39 encontradas; 6 processos não cadastrados; 2 ausentes no ADVBOX; 4 duplicidades Webjur (DJEN e DJe) | Aprovado após correção (E8, E9, E10) |
| R15 | Tarefas de análise: preparo, aprovação, criação automática no ADVBOX, sem duplicidade | 10/11 | **6 tarefas reais criadas** pela extensão: 297864857, 297865284, 297865598, 297865871, 297866229, 297866562. Tipo "ANÁLISE DO CASO (50 pts)", responsável Mayra, data 10/11, prazo fatal 11/11, teor integral na descrição. 2 rejeitadas pela controladoria (outro escritório). 2 testes no TESTE 1.0. Nenhum ID repetido e nenhuma duplicidade por publicação | Aprovado após correção (E11, E12, E13, E14) |
| R16 | Processo cadastrado depois da conferência: confirmação pela extensão | 10/11 | 5 tarefas com "cadastro confirmado"; processos ligados ao ID do ADVBOX | Aprovado após correção (E14) |
| R17 | Verificação de integridade no banco real | 10/11 | 0 erros. Informativos: 87 linhas ambíguas e 16 parâmetros provisórios. Alerta: 2 erros de integração já tratados | Aprovado após correção (E15) |
| R18 | Histórico de auditoria e configurações no painel, com dados reais | 10/11 | 1.083 registros na linha do tempo (368 marcados como recuperados de texto anterior à implantação); 2 contas; 38 parâmetros; 110 dias de calendário | Aprovado |
| R19 | Funções protegidas: chamadas reais como colaborador e como usuário sem perfil | 10/11 | As de administrador recusaram os dois; as da extensão recusaram o usuário sem perfil | Aprovado |
| R20 | Trava de realocação em modo bloquear: mudar a data sem justificativa | 10/11 | Tarefa de teste 297817836 (TESTE 1.0): o ADVBOX exibiu "Alteração bloqueada pela controladoria"; a tarefa manteve o ID e a data 10/11; evento "bloqueio efetivo" às 18:17 | Aprovado |
| R21 | **Importações sucessivas** (antigo P1): 2ª exportação do ADVBOX comparada com a de 07/11 | 10/11 | Lote 6: importação 9 (686 pendentes) e importação 10 (282 concluídas de 08/11 a 10/11, 279 conclusões registradas). Após a correção: 391 tarefas reconhecidas como já conhecidas, 269 novas, 168 encaminhamentos ligados à tarefa de 07/11. Comparação entre os dias: 215 mudanças de data na agenda, 111 trocas de responsável, 26 mudanças de prazo fatal (352 no total). Integridade sem erros | Aprovado após correção (E19, E20) |

Desde 10/11 (migração 0029), 18 tabelas recusam TRUNCATE e o log de integração só é gravado pelo próprio banco.

## 3. Erros encontrados nos testes reais e correções

| # | Erro observado no ambiente real | Correção |
|---|---|---|
| E1 | A importação foi recusada pelo Supabase: "UPDATE requires a WHERE clause" (extensão pg-safeupdate) | Migração 0020 |
| E2 | Indicadores cancelados por tempo (cerca de 10 s, contra o limite de 8 s) | Migrações 0021 e 0022: de cerca de 13 s para 3 s, resultado idêntico |
| E3 | Painel da controladoria não aparecia na janela da tarefa (janela fixa do ADVBOX) | Extensão 0.3.3 |
| E4 | Clique no painel da controladoria fechava a janela da tarefa | Extensão 0.3.4 |
| E5 | "Editar tarefa" exclui e recria a tarefa com novo ID; a tratativa se perdia | Migração 0023 e extensão 0.3.5 |
| E6 | Registro em dobro ao clicar nos botões do calendário | Extensão 0.3.5 |
| E7 | Varredura dada como incompleta por causa do texto "Selecione" no filtro de responsável | Extensão 0.3.6 |
| E8 | A mesma publicação aparece no DJEN e no DJe e era contada duas vezes | Migração 0024 (situação "duplicidade Webjur") |
| E9 | Publicação com uma única intimação candidata ficava inconclusiva | Migração 0024 (regra da candidata única, semelhança ≥ 0,9) |
| E10 | Erro "record a is not assigned yet" ao confirmar ausência no painel | Migração 0025 |
| E11 | Conferência final leu o título junto com o painel da controladoria (tarefa 297813142 foi para "verificar no ADVBOX", sem recriar) | Extensão 0.4.1 |
| E12 | Janela da tarefa criada ficava aberta e travava a fila | Extensão 0.4.2 |
| E13 | O ADVBOX lista o mesmo processo uma vez por parte; a extensão bloqueou 4 tarefas como "ambíguas" | Extensão 0.4.3: mesmo ID de processo = um só processo |
| E14 | Lista não mostrava que o processo foi cadastrado depois da conferência | Migração 0028 |
| E15 | Integridade: contagens limitadas a 20 e linhas ambíguas tratadas como falha | Migração 0030 |
| E16 | Indicadores voltaram a estourar 30 s (erro 500 na Visão geral). O planejador recalculava o CNJ por par linha × processo | Migração 0031: cerca de 5,5 s, resultado idêntico (hash) |
| E17 | Arquivo antigo entregue na pasta da extensão (cópia reaproveitada) | Procedimento: cada entrega em caminho novo e conferida byte a byte |
| E18 | Security Advisor: funções sem `search_path` e funções internas expostas | Migração 0019 |
| E19 | "Detalhar" a 2ª importação no painel: "canceling statement due to statement timeout" | Migração 0032: de mais de 30 s para 0,9 s, totais idênticos nas 5 importações |
| E20 | 301 tarefas pendentes em 07/11 "sumiram" em 10/11 e reapareceram como novas. O Remetente fazia parte da chave da tarefa e muda quando a tarefa é encaminhada no ADVBOX | Migração 0033: vínculo sem o Remetente quando o par é único; reparo do lote 6 (168 tarefas unificadas na de 07/11, com evento de unificação) |
| E21 | Double check de 10/11 (38 publicações): "canceling statement due to statement timeout". A comparação de teores era quadrática (36 s para 37 pares) | Migração 0034: interseção de conjuntos; 1 s, resultado idêntico (hash) |

Duas decisões da controladoria corrigiram aprovações: a 0026 fixou data, prazo fatal e cadastro prévio; e as tarefas #4 e #6 foram retidas por terem nota contraditória e depois rejeitadas.

## 4. Testes automatizados (dados fictícios, banco local, páginas simuladas)

| Suíte | Verificações | Resultado |
|---|---|---|
| Banco: `run_tests.py` | 64 | 64 OK |
| Banco: `test_etapa2.py` | 64 | 64 OK |
| Banco: `test_calendario.py` | 13 | 13 OK |
| Banco: `test_etapa4.py` (indicadores) | 41 | 41 OK |
| Banco: `test_etapa5.py` (extensão no banco) | 13 | 13 OK |
| Banco: `test_etapa6.py` (Webjur) | 54 | 54 OK |
| Banco: `test_etapa7.py` (double check) | 41 | 41 OK |
| Banco: `test_etapa8.py` (tarefas de análise) | 36 | 36 OK |
| Banco: `test_etapa9.py` (auditoria e segurança) | 36 | 36 OK |
| Banco: `test_etapa10.py` (importações sucessivas e encaminhamento) | 14 | 14 OK |
| Banco: `auditoria_hipoteses.py` | 8 | 8 conformes |
| Leitor Webjur: `testar_leitor.js` | 40 | 40 OK |
| Extensão: `testar_extensao.js` | 56 | 56 OK |
| Extensão: `testar_intimacoes.js` | 22 | 22 OK |
| Extensão: `testar_criacao.js` | 24 | 24 OK |
| Painel ponta a ponta: `testar_painel.js` | 24 | 24 OK |
| Painel ponta a ponta: `testar_indicadores.js` | 31 | 31 OK |
| Painel ponta a ponta: `testar_publicacoes.js` | 26 | 26 OK |
| Painel ponta a ponta: `testar_doublecheck.js` | 16 | 16 OK |
| Painel ponta a ponta: `testar_analise.js` | 13 | 13 OK |
| Painel ponta a ponta: `testar_auditoria.js` | 15 | 15 OK |
| **Total** | **651** | **651 OK, 0 reprovados** |

## 5. Ainda não testado no ambiente real (só em teste automatizado)

| # | Item (§26) | Por que falta | O que é preciso |
|---|---|---|---|
| P2 | **Segundo ciclo diário** completo: Webjur do dia, varredura, double check e tarefas | Só o dia 09/11 foi conferido | Repetir a rotina com as publicações de 10/11 ou 11/11 |
| P3 | Extensão **sem internet**: fila local e reenvio | Testado em página simulada | Desligar a rede por alguns minutos com uma tarefa de teste aberta |
| P4 | Extensão **sem login** | Testado em página simulada | Sair da extensão e abrir uma tarefa de teste: deve avisar e não registrar |
| P5 | Extensão usada por um **colaborador** no ADVBOX (não administradora) | Só a administradora usou a extensão | Instalar no Chrome da conta de teste e repetir R6–R8 |
| P6 | E-mail diário da Webjur como **contingência** | Leitor testado com e-mails fictícios | Importar um e-mail real no painel |

## 6. Limitações técnicas conhecidas
1. **As travas atuam só na tela, com a extensão ativa.** Alterações feitas por outro caminho (outro navegador, aplicativo ou integração do ADVBOX) não são bloqueadas. São percebidas na comparação entre importações (R21).
2. **Realocação e prazo fatal em modo "bloquear" desde 10/11/2026** (decisão da controladoria, seção 7). Os testes R9 e R10 foram feitos antes, em modo "observar"; o R20 confirmou o bloqueio.
3. **O Excel do ADVBOX limita cada arquivo a 1.000 linhas.** A base exige vários arquivos, e o painel avisa quando um arquivo tem exatamente um tamanho de corte.
4. **87 linhas ambíguas ficam sem vínculo.** São linhas do Excel que valem para mais de uma tarefa; a extensão resolve quando a tarefa é aberta no ADVBOX.
5. **A tarefa "ANÁLISE DO CASO" move o processo para NEGOCIAÇÃO / ANÁLISE DO CASO.** É comportamento do ADVBOX, aceito pela controladoria em 10/11/2026.
6. **Tarefa sem o botão Concluir não é monitorada.** Quando a usuária não é a responsável, o ADVBOX não mostra o botão Concluir, e a extensão não abre o painel nem monitora a tarefa (visto em 10/11 na tarefa 297675482, encaminhada ao PROTOCOLO).
7. **O painel roda no computador da controladoria.** Ele usa `iniciar_painel.bat`, e a hospedagem para produção ainda não foi definida.
8. **Plano gratuito do Supabase.** O projeto é pausado após dias sem uso. Para produção, avaliar o plano pago e um projeto separado.
9. **Proteção contra senhas vazadas desligada** (aviso do Supabase). É configuração do Supabase Auth.
10. **Tempo da Visão geral:** cerca de 5 a 6 s no plano gratuito, dentro do limite de 30 s.
11. **Encaminhamento com dados repetidos não é ligado automaticamente.** Das 301 tarefas de 07/11 ausentes em 10/11, 168 foram ligadas (par único). Ficaram 133: 81 têm mais de uma tarefa equivalente (mesmo processo, compromisso e observação) e não são ligadas para não unir tarefas erradas; 52 não têm nenhuma correspondente no arquivo de 10/11 (excluídas, concluídas fora do período exportado ou com a observação alterada). Essas ficam como tarefas separadas, e a mudança entre os dois dias não é comparada para elas.

## 7. Pendências de validação (Prompt Mestre, parte XII)

**Já confirmadas pela controladoria:**
1. Contagem do D-4 e do D-7.
2. Fonte do PF Judicial.
3. Evidência de entrega em D-4: a conclusão da tarefa.
4. Protocolos e distribuições.
5. Regra de alteração do prazo fatal.
6. Periodicidade da exportação do Excel.
7. Fonte principal da Webjur: o portal.
8. Área do ADVBOX para conferência: Intimações.
9. Data da tarefa de análise.
10. Processo não cadastrado.

**Os 16 parâmetros provisórios foram confirmados pela controladoria em 10/11/2026**, às 18:15, com motivo registrado no histórico de auditoria. Restam 0 provisórios.

| Decisão de 10/11/2026 | Valor |
|---|---|
| Início do monitoramento da tratativa (`tratativa_monitorada_desde`) | 07/11/2026 21:47, primeiro registro real da extensão |
| Trava de conclusão sem início | bloquear (testado em R7) |
| Travas de realocação e de prazo fatal | bloquear (realocação testada em R20) |
| Justificativa mínima | 15 caracteres |
| Alerta de tarefa próxima | 2 dias úteis antes |
| Reagendamentos sucessivos | a partir de 2 |
| 9 limiares do double check | valores atuais, calibrados com pares reais em 07/11; revisar depois de P2 |

## 8. Próximos passos para a produção
1. Fazer o teste P2 (segundo ciclo diário) e os testes P3 a P6 da extensão e do e-mail.
2. Rever os limiares do double check depois do segundo ciclo diário (P2).
3. Criar o projeto de produção no Supabase, separado do de homologação, seguindo `docs/SUPABASE_IMPLANTACAO.md`, e definir onde o painel vai rodar.
4. Ligar a proteção contra senhas vazadas e criar as contas dos colaboradores.
