# Etapa 5 — Extensão no ADVBOX real (06/11/2026)

## 1. Inspeção da tela real (somente leitura)

A inspeção foi feita em 06/11/2026, com autorização, no Chrome da controladoria já logado no ADVBOX como Mayra Gomes.

**O que foi feito:**

- uma tarefa da própria usuária (291306485), já marcada como lida, foi aberta;
- o modo **Editar tarefa** foi aberto e fechado pelo X, **sem salvar**;
- o resto foi lido por requisição GET (`/posts/<id>/edit`) e pelo DOM.

**O que não foi feito:** nenhuma conclusão, edição, encaminhamento ou criação de tarefa. A tarefa continuou como estava.

### O que a tela real mostrou

| Ponto | Tela real | Extensão 0.1 (fase 2) | Versão 0.2.0 |
|---|---|---|---|
| ID da tarefa | `a.button.toggle[data-id]` = número do post; a URL ganha `?t=` com o mesmo número | Lia só o botão | Lê os dois. Se divergirem, a tarefa **não** é monitorada |
| Título | "Análise do Caso" (tipo da tarefa, com maiúsculas e minúsculas) | Correto | Correto. O banco compara com `upper()`, que preserva acento (Á) |
| Processo | CNJ seguido do texto do ícone "content_copy" | Vinha "CNJ content_copy" | Só o CNJ |
| Responsável | Só a foto; o nome fica em `li[title="Nome: Situação"]` | Não lia | Lê nome, situação e ID do usuário |
| "Atribuir tarefa" | Formulário com campos **vazios** que **cria tarefa nova** | Tratado como realocação da tarefa aberta (**errado**: geraria alertas falsos em massa) | Sem trava |
| "Editar tarefa" | `form.modal-inner-create`, com `editing` = ID e `date`, `date_deadline` e `guests[]` preenchidos. **É aqui que data, prazo e responsáveis mudam** | Não vigiava | Travas 2 e 3, com campo de justificativa da controladoria |
| Conclusão pela lista | `a.change-status[data-field=completed][data-value=1][data-post=ID]`: conclui sem abrir a tarefa | **Não vigiava** (a trava podia ser contornada) | Trava 1 também na lista |
| Intimações na lista | Grupo `data-group="publication"`, 100 linhas "INTIMAÇÃO JUDICIAL" com o mesmo círculo | — | Fora da trava (a confirmar). Útil para a Etapa 7 |
| Encaminhar | `form.form-event` (POST `/post-events`): `user`, `post_id`, sem comentário | — | Registra com justificativa e nunca bloqueia (efeito a confirmar) |
| Reabrir a tarefa | — | Não reconsultava (achado A9) | Reconsulta a cada abertura |

### Leitor da versão 0.2.0 aplicado à tarefa real

Os dados foram lidos de uma cópia da janela montada fora da área visível, sem scripts, e descartada em seguida:

| Campo | Lido |
|---|---|
| ID (botão / URL) | 291306485 / 291306485, sem conflito |
| Título | Análise do Caso |
| Data do evento / prazo fatal | 27/10/2026 / 27/10/2026 |
| Criado por / em | Mayra Gabriela Costa Gomes / 23/10/2026 16:44 |
| Processo | CNJ de 25 caracteres (válido) |
| Partes | 1 parte (o cliente) |
| Responsáveis | Mayra Gabriela Costa Gomes — Pendente |
| PF Judicial anotado | nenhum, o que está correto: a descrição diz "Prazo 05 dias" e não traz "PF:" |
| Lista | 187 círculos de conclusão visíveis. Grupos: prazo fatal (58), outros (6), não lidos (23), publicações (100). Os títulos foram lidos de todas as linhas de tarefa |

## 2. O que foi alterado

| Arquivo | Alteração |
|---|---|
| `extensao/lib/advbox_parse.js` | CNJ limpo; título robusto; descrição sem a pontuação "50pts"; `lerResponsaveis`, `idDaTarefa`, `lerEdicao`, `avaliarEdicao`, `avaliarEncaminhamento`, `tituloDaLista`. A função `avaliarFormulario`, baseada na interpretação errada de "Atribuir tarefa", foi removida |
| `extensao/content.js` | Trava 1 também na lista, com consulta em lote; travas 2 e 3 em "Editar tarefa" com campo de justificativa; registro do "Encaminhar"; reconsulta a cada abertura; grupo de publicações fora da trava |
| `extensao/background.js` | Nova mensagem `inicios`, que chama `ext_inicios_por_ids` |
| `supabase/migrations/0012_extensao_advbox_real.sql` | `ext_inicios_por_ids()` (só leitura; máximo de 200 IDs; exige perfil). `_tarefa_por_advbox()` não deixa um clique na lista sobrescrever a última leitura completa da janela |
| `extensao/tests/advbox_real_ficticio.html` | Réplica fictícia da estrutura real. Substitui `advbox_simulado.html`, que representava a interpretação errada |

## 3. Testes

| Bateria | Resultado |
|---|---|
| Extensão: leitura, regras e interceptação na réplica da estrutura real (2 rodadas) | 53/53 |
| Banco da Etapa 5 (`tests/test_etapa5.py`) | 13/13 |
| Regressão completa (banco, Etapa 2, calendário, auditoria, Etapa 4, painel ponta a ponta) | 64, 64, 13, 8, 41, 31 e 40 — sem falhas |
| Leitura na tela real com o leitor 0.2.0 | 1 tarefa e a lista do painel (ver a seção 1) |

Os testes encontraram e corrigiram dois problemas da própria versão 0.2.0 antes da entrega:

- o campo de justificativa do "Encaminhar" era inserido fora do formulário e se repetia a cada atualização da tela;
- o título não era lido quando o ícone e a palavra "Excluir" vinham na mesma linha.

## 4. O que ainda falta para a homologação da extensão

1. **Teste de clique real:** concluir e editar com a extensão instalada, numa **tarefa de teste criada só para isso**. Depende da autorização do escritório e do Supabase de homologação, porque a extensão precisa de um banco acessível pela internet.
2. **Efeito de "Encaminhar":** confirmar se troca o responsável ou só notifica.
3. **Quadro (kanban), Agenda e Atividades:** conferir como a conclusão acontece nessas telas.
4. **Intimações:** decidir se marcar uma intimação como resolvida deve exigir algum registro. Hoje elas estão fora da trava.
5. **Data de início do monitoramento:** preencher `tratativa_monitorada_desde` quando a extensão entrar em uso.
