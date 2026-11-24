# Controladoria Jurídica — Oliveira e Camilo

Supabase (PostgreSQL), painel web e extensão de navegador. **Não usa API do ADVBOX.**

## Situação por etapa (ordem do Prompt Mestre, item 14)

| # | Etapa | Situação |
|---|---|---|
| 1 | Arquitetura e dependências | Feito. Diagnóstico do Excel em `docs/DIAGNOSTICO_EXCEL_E_DECISOES.md` |
| 2 | Esquema e modelo de dados | Feito. `0001`; ampliado na Etapa 2 (05/11/2026) por `0007` e `0008`: correções da auditoria, processos, equipes, feriados por foro, publicações Webjur, double check, tarefas de análise e log de integração. Ver `docs/ETAPA2_BANCO.md` |
| 3 | Restrições, RLS e auditoria | Feito e testado localmente. `0001`, `0005` |
| 4 | Importação Excel | Função e **tela** prontas (Etapa 3, 05/11/2026): `painel/`, área Importação Excel. Teste ponta a ponta 39/39 com os arquivos reais. Ver `docs/ETAPA3_IMPORTACAO.md` |
| 5 | Indicadores SQL | Parcial: prazos e alertas (`0004`). Faltam os cartões e gráficos da visão geral e por colaborador |
| 6 | Dashboards | Feito na Etapa 4 (ver a linha 4b abaixo) |
| 7 | Extensão: início da tratativa | Versão 0.2.0 ajustada à tela real na Etapa 5 (ver a linha 5 abaixo) |
| 8 | Travas | Implementadas na extensão. Conclusão no modo *bloquear*; realocação e prazo fatal no modo *observar* até o teste real. Nenhuma foi validada no ADVBOX. Pelo Excel, só há **detecção após o fato** |
| 4b | Dashboards e indicadores | Etapa 4 (06/11/2026): 5 áreas do painel; ver `docs/ETAPA4_INDICADORES.md` |
| 5 | Extensão no ADVBOX real | Etapa 5 (06/11/2026): versão 0.2.0 ajustada à tela real (leitura validada numa tarefa real); clique real pendente de tarefa de teste autorizada. Ver `docs/ETAPA5_EXTENSAO.md` |
| 6 | Módulo Webjur | Etapa 6 (06/11/2026): leitor do e-mail diário (7 e-mails reais, 122 publicações), remessas com conferência de completude, identificação por identificador do documento, área 7 do painel. Portal: exportação "Planilha" (CSV) importada no painel como fonte principal e e-mail como contingência (0015); conferido com dados reais de 05/11/2026 (39 = 39, sem duplicidade). Ver `docs/ETAPA6_WEBJUR.md`. Ver `docs/ETAPA6_WEBJUR.md` |
| 7b | Double check | Etapa 7 (06/11/2026): leitura da tela "Intimações recebidas" do ADVBOX pela extensão (0.3.0), varreduras com controle de completude, comparação por CNJ + data + teor com ligação um a um (0016), área 8 do painel e conferência manual. Limiares provisórios até calibração com dados reais. Ver `docs/ETAPA7_DOUBLE_CHECK.md` |
| 9 | Testes | Em 05/11/2026: 64/64 de banco (incluindo os 3 arquivos reais), 64/64 da Etapa 2, 8/8 das hipóteses da auditoria e 29/29 da extensão, todos num PostgreSQL local e numa página simulada. Ainda não rodaram num Supabase real nem no ADVBOX |
| 10 | Documentação de implantação | Parcial (este arquivo) |

## Implantação

Passo a passo do Supabase de homologação em `docs/SUPABASE_IMPLANTACAO.md`.

## Estrutura

```
supabase/migrations/
  0001_schema.sql              tabelas, imutabilidade da auditoria
  0002_regras_calendario.sql   parâmetros, feriados 2026–2027, D-4/D-7, dias úteis
  0003_importacao.sql          RPC importar_arquivo() transacional e idempotente
  0004_visoes_alertas.sql      v_tarefas_atuais, v_alertas, v_alteracoes_sem_justificativa
  0005_seguranca_rls.sql       RLS e privilégios mínimos
  0006_extensao.sql            funções da extensão, vínculo pelo ID do ADVBOX, v_travas
  0007_correcoes_auditoria.sql unificação por ID do ADVBOX, início visível ao responsável, trava conferida no servidor, proteção de lote, privilégios
  0008_estruturas_webjur_processos.sql  processos/CNJ, equipes, feriados por foro, publicações, double check, tarefas de análise, log, conferência de alertas
  0009_calendario_2026_tribunais.sql    feriados 2026 de TJMG, TJSP, TJPR e TJGO (com fontes)
  0010_painel_importacao.sql            visões do relatório de importação
  0011_indicadores.sql                  indicadores (definição única), prazos em risco, reagendamentos, tratativa
  0012_extensao_advbox_real.sql         consulta em lote da lista para a extensão; preserva a leitura completa da janela
painel/                        painel web (HTML/JS, sem build) — login, Visão geral, Indicadores por colaborador, Prazos em risco, Reagendamentos, Tratativa, Importação Excel
extensao/                      extensão Chrome (MV3) — ver extensao/LEIAME.md
tests/
  00_stub_supabase_local.sql   simula auth.uid() — SÓ para teste local
  run_tests.py                 esperado x obtido (dados fictícios + arquivo real)
  test_etapa2.py               testes da 0008
  test_calendario.py           testes do calendário real (0009)
  test_etapa4.py               testes dos indicadores (0011)
  test_etapa5.py               testes da extensão no banco (0012)
  e2e/                         teste ponta a ponta do painel (Chromium + banco local)
  auditoria_hipoteses.py       achados da auditoria de 05/11/2026 (A1–A7)
  xlsx_para_json.py            converte o .xlsx no formato enviado à RPC
docs/DIAGNOSTICO_EXCEL_E_DECISOES.md
```

## Regras centrais (únicas para todo o sistema)

- **D-7** = coluna *Data* do Excel (valor de origem). `calcular_d7_conferencia()` serve apenas para conferência.
- **D-4** = anotação "D-4: dd/mm", quando existe. Sem anotação, `calcular_d4(PF Judicial)` usa o parâmetro `d4_dias_uteis_antes_pf` = PF Judicial − 3 dias úteis (confirmado em 24/10/2026).
- **PF Judicial** = anotação "PF: dd/mm" em Observações. Sem ela, o status é `nao_confirmado`. **Nunca** é substituído pelo PF da Tarefa.
- **PF da Tarefa** = coluna *Prazo fatal*. Alterações entre importações viram eventos, e o PF Judicial nunca muda junto.
- Divergências viram alertas. Nenhuma data é corrigida automaticamente.

## Implantação no Supabase (ainda não executada)

1. Crie um projeto de **homologação**. Não use produção para os testes.
2. Rode as migrações `0001` a `0012` em ordem, no SQL Editor ou com `supabase db push`. **Não rode** `tests/00_stub_supabase_local.sql`.
3. Crie o primeiro usuário em Authentication. Depois, no SQL Editor:
   `insert into perfis (user_id, papel) values ('<uuid do usuário>', 'admin');`
4. O painel usará apenas a chave `anon` mais o login do usuário. A `service_role` nunca vai para o navegador nem para a extensão.

## Testes locais

PostgreSQL 16 em `/tmp:5433`, depois `python3 tests/run_tests.py`, `python3 tests/test_etapa2.py` e `python3 tests/auditoria_hipoteses.py`. Para o bloco com arquivos reais, gere `tests/out/real.json`, `concluidas.json` e `concluidas2.json` com `tests/xlsx_para_json.py` (não versionar: contêm dados de clientes).
