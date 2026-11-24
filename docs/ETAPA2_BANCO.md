# Etapa 2 — Banco de dados (05/11/2026)

Migrações **aditivas** `0007` e `0008`. Nenhuma tabela foi recriada nem apagada; as funções antigas continuam aceitando as mesmas chamadas.
Tudo foi testado num PostgreSQL 16 **local**, porque o projeto Supabase de homologação ainda não existe (decisão de 05/11/2026).

## Decisões aplicadas (05/11/2026)

| Ponto | Decisão |
|---|---|
| Regras D-4, PF Judicial, entrega em D-4, protocolos/distribuições, prazo fatal, exportação | Vale a versão confirmada em 24/10/2026; parâmetros mantidos como `confirmado = true` |
| Colaborador inicia tratativa em tarefa de outro responsável | Permitido; o autor do início fica registrado |
| Ambiente | Banco local até a criação do Supabase de homologação |

## 0007 — correções da auditoria

| Achado | Correção | Teste |
|---|---|---|
| A1 Tarefa recorrente realocada perde o início | `advbox_id` é a identidade principal. Ao reabrir a tarefa na extensão, se ela não tem linha no lote atual e a tela corresponde a **uma única** linha ainda sem ID, os registros são unificados (`tarefas.unificada_em`) e um evento `unificacao_tarefa` é gravado. Antes da reabertura, a tarefa aparece em `v_tarefas_sem_linha_atual` (não some em silêncio). | H1, H1b |
| A2 Tarefa vista antes de aparecer no Excel duplica | Mesma unificação, feita automaticamente na importação, comparando a última tela vista (`tarefas.ultimo_snapshot`). | H2 |
| A3 Responsável não vê início feito por outra pessoa | Função `tratativa_da_tarefa()` com controle de acesso próprio; `v_tarefas_atuais` passa a usá-la. | H3 |
| A4 Estado da trava aceito como declarado | `ext_registrar_evento` reclassifica "permitida" sem início, com PF Judicial, sem perfil ou sem justificativa para `violacao_detectada`; guarda `estado_declarado` e `reclassificado_servidor` na evidência. | H5 |
| A5 Arquivo só de concluídas substitui a fotografia | `importar_arquivo` devolve `requer_confirmacao` e não grava nada; aceita com o lote do dia ou com `p_confirmar_lote_novo_so_concluidas = true`. A função original virou `_importar_arquivo_base` (interna). | H7 |
| A6 `anon` executava funções | Revogação geral para `public`/`anon`; funções internas revogadas também de `authenticated`. | H6 |

Limite que permanece: a unificação usa o critério da fase 2 (título da janela = Compromisso, Data do evento = Data, Prazo fatal, partes). Em 05/11/2026 o escritório confirmou que o título da tarefa no ADVBOX é o texto da coluna Compromisso (premissa do A8 confirmada); a validação na tela real com a extensão instalada segue na Etapa 5.

## 0008 — novas estruturas

| Estrutura | O que faz |
|---|---|
| `normalizar_cnj`, `cnj_digito_valido`, `foro_do_cnj` | Formato CNJ a partir de qualquer pontuação; dígito verificador (Res. CNJ 65/2008, mód 97). |
| `processos` | Um registro por CNJ normalizado, preenchido pela importação e pela Webjur; guarda `advbox_lawsuit_id` quando a conferência o informa. |
| `equipes` + `colaboradores.equipe_id` | Filtro por equipe; alteração só por `admin_definir_equipe` (auditada). |
| Calendário por foro | Nova abrangência `foro` (tribunal + código OOOO do CNJ) para feriados municipais. Feriado estadual = abrangência `tribunal`. Funções de dias úteis e D-4/D-7 ganharam versão com foro; as de 2 argumentos continuam valendo. Cadastro por `admin_cadastrar_dia_nao_util` (exige fundamento; auditado). |
| `publicacoes`, `publicacoes_coletas` | Publicação Webjur imutável, teor integral e registro bruto preservados. Duplicidade = CNJ + data + teor normalizado: a mesma publicação vista no portal e no Gmail vira 1 publicação com 2 coletas; publicações diferentes do mesmo processo e data **não** se fundem. |
| `conferencias_publicacao` | Double check, só acrescenta. "Encontrada" exige a publicação específica do ADVBOX na evidência; erro de acesso/coleta exige a descrição do erro e nunca vira "ausente". |
| `tarefas_analise`, `tarefas_analise_historico` | Uma tarefa por publicação (chave única). Preparada automaticamente quando ausente ou processo não cadastrado; tipo e responsável vêm de `parametros` (Mayra Gomes / "análise do caso"); observações começam com "WEBJUR — Disponibilizada em …" e trazem o teor integral. Fluxo: preparada → aprovada → criação em andamento → criada; falha incerta → `verificar_no_advbox` (não pode recriar antes de conferir). |
| `log_integracao` | Erros e avisos de integração; erros também viram evento de auditoria. |
| `conferencias_alerta` + `v_alertas_conferencia` | Conferência humana dos alertas (ex.: PF Judicial vencido como pendência de conferência, nunca como perda de prazo automática). |
| `v_publicacoes`, `v_double_check_diario` | Situação de cada publicação e relatório diário. Percentual de ausentes = (ausentes + processo não cadastrado) ÷ (encontradas + ausentes + não cadastrado); erros e inconclusivas ficam fora. |

Parâmetros novos ainda **não confirmados**: grafia exata do tipo "análise do caso" no ADVBOX, data da tarefa de análise (data da conferência x próximo dia útil), fonte principal da Webjur, área do ADVBOX que comprova a captura.

## Dado relevante da base real (arquivos de 24/10/2026)

A importação registrou 418 processos, todos com dígito verificador válido, em **27 tribunais e 143 foros**. Os feriados de 2026 dos quatro tribunais com mais processos (TJMG 176, TJSP 53, TJPR 28, TJGO 25) foram cadastrados na migração 0009 — ver `docs/ETAPA3_IMPORTACAO.md`.

## Testes

| Bateria | Resultado |
|---|---|
| `tests/run_tests.py` — fase 1/2, agora com os 3 arquivos reais | 64/64 |
| `tests/auditoria_hipoteses.py` — achados da auditoria após a 0007 | 8/8 conformes |
| `tests/test_etapa2.py` — 0008 | 64/64 |
| `extensao/tests/testar_extensao.js` — sem alteração na extensão | 29/29 |

Os arquivos reais convertidos (`tests/out/real.json`, `concluidas*.json`) contêm dados de clientes. Eles ficam só no ambiente de teste e não fazem parte do pacote entregue.
