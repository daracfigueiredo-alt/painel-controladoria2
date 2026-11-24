# Etapa 3 — Importação Excel e calendário de feriados (05/11/2026)

## 1. Calendário de feriados 2026 (migração `0009`)

São 92 dias carregados para os quatro tribunais com mais processos na carteira. Todos têm fundamento registrado, e a carga pode ser repetida sem duplicar nada.

| Tribunal | Fonte oficial | Dias |
|---|---|---|
| TJMG (8.13) | [Portaria Conjunta nº 1798/PR/2026](https://www8.tjmg.jus.br/institucional/at/pdf/pc17982026.pdf) | 31 estaduais + 3 de BH (foro 0024) |
| TJSP (8.26) | [Provimento CSM nº 2.813/2025](https://portaldori.com.br/2025/11/26/feriados-justica-estadual-sp-e-cartorios-provimento-csm-no-2-813-2025-dispoe-sobre-a-suspensao-do-expediente-forense-no-exercicio-de-2026-e-da-outras-providencias/) | 23 |
| TJPR (8.16) | [Decreto Judiciário nº 621/2025](https://portaldori.com.br/2025/12/03/tj-pr-tjpr-divulga-calendario-de-feriados-no-ano-de-2026/) | 11 + 1 de Curitiba (foro 0001) |
| TJGO (8.09) | [Calendário TJGO 2026, versão de 08/06/2026](https://docs.tjgo.jus.br/institucional/feriados/DOC_feriados_2026_08062026.pdf) | 22 + 1 de Goiânia (foro 0051) |

O TJMG também está na [página de feriados do tribunal](https://www.tjmg.jus.br/portal-tjmg/informes/calendario-de-feriados-em-2026-suspensoes-de-expediente.htm).

Critérios usados:

- **Tipos:**
  - Suspensão de expediente e recesso contam como dia não útil.
  - Ponto facultativo fica registrado, mas conta como dia útil. Isso afeta o TJGO em 18/02 (meio período), 20/03, 20/04 e 05/06.
- **TJMG:** os prazos ficaram suspensos de 7 a 20/1/2026, conforme o art. 4º da portaria. Esses dias foram cadastrados como suspensão.
- **TJPR:** o Dia da Justiça foi transferido para 18/12, então o 08/12 é dia útil no TJPR.
- **TJGO:** o tribunal trata Corpus Christi como feriado nacional, mas ele não está na tabela nacional do sistema. Por isso foi cadastrado no próprio tribunal. Os testes acharam essa omissão na primeira versão da carga.

**Pendente:**

- **Calendários de 2027:** ainda não foram publicados nas fontes. Até serem cadastrados, um D-4 de janeiro de 2027 é calculado só com os feriados nacionais. Exemplo: com PF em 05/01/2027 no TJSP, o recesso de janeiro não é considerado.
- **Feriados municipais das comarcas do interior:** estão no Anexo Único da portaria do TJMG e em atos equivalentes dos outros tribunais.
- **Outros foros de Curitiba.**
- **Ponto facultativo:** confirmar com o escritório se ele deve contar como dia não útil para o D-4.

Testes: `tests/test_calendario.py`, 13/13. Inclui o D-4 de BH com PF em 10/12/2026, que é 03/12, porque 07/12 e 08/12 não têm expediente.

## 2. Confirmação do escritório (05/11/2026)

O título da tarefa no ADVBOX é o mesmo texto da coluna Compromisso do Excel. Com isso, a premissa do achado A8 está confirmada, e a unificação por correspondência única pode valer na Etapa 5.

## 3. Painel — área "Importação Excel" (`painel/`)

O painel é feito em HTML, CSS e JavaScript, sem etapa de compilação, e usa duas bibliotecas incluídas na pasta `painel/vendor/`:

- `@supabase/supabase-js` 2.118.0;
- `fflate` 0.8.3.

As duas estão em versões corrigidas: `npm audit` não acusa nenhuma vulnerabilidade.

Os itens do Prompt Mestre §6 estão cobertos assim:

| Item do §6 | Implementação |
|---|---|
| 1. Seleção do arquivo | Vários `.xlsx` de uma vez. A ordem de seleção é a ordem de importação. |
| 2. Leitura | O leitor próprio, `js/xlsx_leitor.js`, roda no navegador. Ele produz exatamente o mesmo resultado do conversor em Python: as linhas e o SHA-256 conferem nos 3 arquivos reais. |
| 3. Validação | É feita antes do envio (colunas, formato, limite de 1.000 linhas, possível corte da exportação) e de novo no banco, linha por linha. |
| 4. Duplicidades | Mostra as linhas repetidas dentro do arquivo. Linhas repetidas no lote são ignoradas pelo banco. Um arquivo idêntico não é importado de novo. |
| 5. Inconsistências | Os avisos aparecem por linha: CNJ fora do padrão, data da agenda depois do PF etc. |
| 6. Lotes seguros | Cada arquivo é gravado numa única transação. O modo "Nova fotografia" e o modo "Complementar a base atual" são escolhidos explicitamente. Um arquivo só de concluídas exige confirmação. |
| 7. Histórico | Todas as importações, com lote, data, situação e contagens. |
| 8–11. Relatórios | Para cada arquivo: importadas (novas), atualizadas (já conhecidas), ignoradas (repetidas no lote), rejeitadas, sem vínculo seguro, unificadas pelo ID do ADVBOX, processos novos e alterações detectadas (data, PF e responsável). |
| 12. Erros por linha | Usam o número da linha da planilha. Uma linha vazia no meio da planilha mantém a numeração. |
| Mais de 1.000 registros | Vários arquivos entram no mesmo lote. |
| Fora do escopo, de propósito | Não há exclusão de importações, exportação CSV nem edição manual. |

Segurança:

- O painel usa só a chave publicável.
- A sessão fica guardada na aba do navegador e termina quando ela é fechada.
- Todo texto vindo dos dados entra como texto, sem interpretação de HTML.
- A política de segurança de conteúdo bloqueia scripts externos.
- A permissão é decidida no banco: o colaborador que chamar a função diretamente recebe erro 403.

As outras 10 áreas aparecem no menu marcadas com a etapa em que serão entregues. Nenhuma delas mostra número antes de existir.

## 4. Visões novas (migração `0010`)

- `v_importacoes`: histórico de importações com o número de linhas com avisos e de alterações detectadas.
- `v_importacao_linhas`: categoria de cada linha (nova, atualizada, ignorada, rejeitada ou sem vínculo seguro) com os erros e avisos.

## 5. Teste ponta a ponta (`tests/e2e/`)

O teste usa as migrações 0001 a 0010 reais num PostgreSQL local, com o RLS de verdade, e o Chromium.

A camada de API do Supabase foi substituída por `servidor_local.js`, uma emulação mínima feita só para o teste. O motivo: executar o binário baixado do PostgREST foi bloqueado no ambiente de desenvolvimento. **O teste no Supabase de homologação continua pendente (Etapa 10).**

Resultado: 39/39. A bateria cobre:

- login, perfil de colaborador e barreira no banco;
- leitor do painel igual ao conversor Python nos 3 arquivos reais;
- importação real de 878 linhas em cerca de 3 segundos;
- números da tela iguais aos gravados no banco;
- confirmação para o arquivo só de concluídas;
- complemento do lote;
- reimportação recusada;
- erros e avisos por linha;
- histórico;
- tela de celular sem rolagem horizontal;
- console do navegador sem erros.

Capturas de tela ficam em `tests/e2e/out/`.

Para executar:

```
cd tests/e2e && npm install
python3 gerar_fixtures.py
ARQ_REAIS=<pasta com os 3 .xlsx reais> node testar_painel.js
```

## 6. Implantação do painel

1. Preencha `painel/js/config.js` com a URL do Supabase e a chave publicável.
2. Publique a pasta `painel/` em qualquer hospedagem estática com HTTPS, como Netlify, Vercel, Cloudflare Pages ou o storage do Supabase.
3. Na hospedagem, configure o cabeçalho `Content-Security-Policy` com `frame-ancestors 'none'`. Essa diretiva não funciona dentro do HTML.
4. Os usuários são criados no Supabase Auth. O perfil é atribuído com `insert into perfis (...)`, conforme o README.
