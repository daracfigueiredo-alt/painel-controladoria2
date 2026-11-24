# Etapa 9 — Auditoria e segurança (10/11/2026)

## 1. Auditoria do que já existia (banco de homologação)

| Verificação | Resultado |
|---|---|
| RLS | Ligado nas 22 tabelas. |
| Papel anônimo (sem login) | Não lê nenhuma tabela nem visão. |
| Gravação direta por usuário logado | Nenhuma tabela aceita INSERT, UPDATE ou DELETE vindo direto do usuário; tudo passa por funções. |
| Funções SECURITY DEFINER | Todas foram **chamadas de verdade** como colaborador e como usuário sem perfil. As de administrador recusaram os dois; as da extensão recusaram o usuário sem perfil. Hoje são 37, contando as novas desta etapa. |
| Registros de auditoria | Já eram imutáveis contra UPDATE e DELETE: eventos, linhas importadas, publicações, conferências, histórico das tarefas de análise, log. |

### Lacunas encontradas e tratadas (migrações 0029 e 0030)
1. **Configuração sem rastro.** Alterações de parâmetros, perfis de acesso, calendário, colaboradores e equipes não guardavam o antes e o depois, nem quem alterou.
   - Correção: tabela imutável `auditoria_configuracao`, preenchida por gatilho com valor anterior, novo, usuário e motivo.
2. **TRUNCATE não era barrado.** Os registros imutáveis aceitavam TRUNCATE, que esvazia a tabela inteira.
   - Correção: agora é recusado em 18 tabelas, inclusive para o dono do banco.
3. **Log de integração aberto.** Qualquer perfil podia gravar mensagens direto no log.
   - Correção: só as funções do próprio banco gravam. Nem a extensão nem o painel usavam essa permissão.
4. **Sem histórico único (§23).** Criada a função `auditoria_linha_tempo()` e o painel na área 10.
5. **Sem conferência de integridade.** Criada a função `auditoria_integridade()`, disponível no painel.

### Avisos do Security Advisor mantidos de propósito
- **"Signed-in users can execute SECURITY DEFINER function" (37).** É o desenho do sistema: o usuário nunca grava direto, só por essas funções, e cada uma confere o perfil. O teste `tests/test_etapa9.py` chama todas a cada execução.
- **`v_lote_atual`.** Expõe só o número e o horário do lote, para o colaborador ver a data da atualização (já documentado na 0019).
- **"Leaked password protection disabled".** É configuração do Supabase Auth, feita no painel do Supabase (Authentication → Policies/Settings). Verificar se o plano atual oferece.

## 2. Área 10 — Histórico de auditoria
Linha do tempo única, com filtros por período (até 1 ano), categoria e busca (ID da tarefa, CNJ, pessoa ou texto). Cada registro tem um detalhe com antes, depois, evidência e a referência ao registro de origem. Há exportação em CSV.

- **Origens reunidas:**
  - eventos das tarefas;
  - importações;
  - publicações recebidas;
  - conferências;
  - tarefas de análise;
  - varreduras do ADVBOX;
  - erros e avisos de integração;
  - alterações de configuração.
- **"Recuperado"** é o evento lido de texto anterior à implantação (observações do Excel). **"Registrado"** é o gravado no momento em que aconteceu. Nada anterior à implantação é inventado.
- **Integridade:** um botão roda as verificações:
  - duplicidades de tarefas de análise;
  - tarefa "criada" sem ID do ADVBOX;
  - criações presas;
  - publicações sem conferência;
  - unificações em cadeia;
  - linhas sem tarefa;
  - tabelas sem RLS;
  - acesso anônimo;
  - funções sem `search_path`;
  - ausência de administrador;
  - erros de integração;
  - parâmetros provisórios.

## 3. Área 11 — Configurações administrativas
Toda alteração exige motivo de pelo menos 10 caracteres e entra no histórico.

| Seção | O que faz |
|---|---|
| Parâmetros | Os provisórios (Prompt Mestre, parte XII) aparecem primeiro. É possível alterar o valor (o tipo é preservado) e marcar como confirmado. Parâmetros novos só entram por migração. |
| Usuários e perfis | Lista as contas do Supabase Auth com o último acesso e define o papel: administradora, colaborador ligado ao nome no ADVBOX, ou sem acesso. A administradora não retira o próprio acesso e sempre sobra pelo menos uma. |
| Calendário de dias não úteis | Incluir, com fundamento obrigatório. Remover, com motivo; o dia removido fica guardado na auditoria. |
| Log de integração | Mostra os últimos 7 dias. |

## 4. Primeira verificação de integridade real (10/11/2026)
- **Nenhum erro.**
- **87 linhas ambíguas** no lote atual: linhas do Excel que valem para mais de uma tarefa e, por regra, ficam sem vínculo. Aparecem como informativo.
- **16 parâmetros provisórios**, que aguardam a confirmação da controladoria.
- **2 erros de integração**, ambos já conhecidos e tratados:
  - o teste de título da tarefa 297813142, corrigido na extensão 0.4.1;
  - uma varredura incompleta das intimações.

## 5. Testes
| Teste | Resultado |
|---|---|
| `tests/test_etapa9.py` | 36/36 |
| `tests/e2e/testar_auditoria.js` | 15/15 |
| Demais suítes do banco | todas OK, sem regressão |
| Testes ponta a ponta das etapas 7 e 8 | todos OK, sem regressão |

O teste da Etapa 2 foi atualizado: o colaborador **não** grava mais direto no log de integração.
