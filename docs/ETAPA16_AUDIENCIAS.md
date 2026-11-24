# Etapa 16 — Painel de audiências (14/11/2026)

**Pedido da controladoria:** painel de audiências.

**Decisões da controladoria (14/11/2026):**
- as audiências vêm das **intimações do CNJ e da Webjur**;
- o painel deve ter agenda por dia e equipe, alertas de pendência, double check e ata/resultado.

## Como funciona

1. **Leitura das intimações:** a cada hora (agendamento `controladoria_audiencias`, só banco), no double check das 18:30 e pelo botão "Ler intimações agora". O robô lê o texto das intimações e guarda a audiência designada.
   - **Data:** "dia 16/11/2026", "para 10/12/26", "26 de janeiro de 2.027".
   - **Hora:** "às 08:23", "14h30", "9 horas".
   - **Tipo:** conciliação, mediação, instrução e julgamento, depoimento/testemunhas, una etc.
   - **Modalidade:** virtual, presencial ou híbrida.
   - **Link da sala:** Teams, Zoom, Meet, Webex ou link encurtado.
2. **O que não é designação fica de fora:**
   - "deixo de designar";
   - "interesse na realização de audiência";
   - "eventual audiência";
   - "resultado infrutífero da audiência";
   - "audiência anteriormente designada";
   - "remessa ao CEJUSC para designação de nova data";
   - "20 dias da audiência".

   O verbo precisa estar na mesma frase e perto da palavra "audiência".
3. **Sem data na intimação:** é o caso do Projudi ("AUDIÊNCIA DE CONCILIAÇÃO DESIGNADA (03/11/2026)", que é a data do ato) e do eproc ("Evento 29 – 24/08/2026 – Audiência de Conciliação designada"). A audiência fica como **sem data** até alguém completar no painel.
4. **Mesma audiência em várias intimações** (uma para cada destinatário, no CNJ e na Webjur): fica uma audiência só, com todas as fontes ligadas.
5. **Redesignação:** a nova data passa a valer e a audiência anterior do mesmo processo fica como "redesignada".
6. **Equipe:** a API do Atlas não informa a equipe do cliente (conferido em 14/11 pela ação `diagnostico`, que mostra só os nomes dos campos). Por isso a equipe vem da letra do código do cliente: C = Celeste, P = Prime, G = Gold, E = Êxitos, D = Delta. Isso fica no parâmetro `equipes_por_letra`, ainda **a confirmar**.

## Pendências (painel e double check diário, tipo "Audiência pendente")

| Pendência | Quando | Gravidade no double check |
|---|---|---|
| Sem data na intimação | Audiência designada sem a data | Média |
| Sem advogado | Audiência futura sem advogado designado | Alta até 7 dias antes; média antes disso |
| Sem confirmação | Faltam até 2 dias úteis (`audiencias_confirmar_dias`) e não foi confirmada | Alta |
| Sem tarefa no Atlas | Nenhuma tarefa com "audiência" e o número do processo vencendo até 20 dias antes (`audiencias_tarefa_dias`) | Alta até 7 dias antes; média antes disso |
| Sem ata/resultado | A audiência já passou e o resultado não foi registrado | Baixa |

## Quem faz o quê

| Perfil | Pode |
|---|---|
| Controladoria | Tudo. Também "Ler intimações agora" |
| Líder | Nas audiências da equipe que acompanha: designar advogado e preposto, completar ou corrigir data, hora e modalidade (com motivo), confirmar, registrar ata |
| Advogado designado | Ver as suas audiências, confirmar, registrar ata |
| Diretoria | Ler tudo |

**Histórico:** identificação, nova fonte, designação, confirmação, correção, releitura e resultado ficam em `audiencia_eventos`, que é imutável.

## Teste real (14/11/2026, 23:10–23:20)

- **Leitura:** 763 intimações dos últimos 60 dias (CNJ e Webjur); 15 citavam audiência designada.
- **Resultado da 1ª leitura:** 7 audiências.
- **E27 (0052 e 0053), dois erros de leitura encontrados:**
  - "26 de Janeiro de **2.027**": o ano com ponto não era lido, e a audiência ficou sem data;
  - "remessa ao CEJUSC para designação de nova data para audiência", junto com o "designada" da frase seguinte, virou audiência.
- **Correção do E27:**
  - verbo colado à palavra e na mesma frase;
  - ano com ponto passa a ser lido;
  - releitura automática: as audiências não são apagadas — a falsa ficou "descartada" e a outra ganhou data e hora. Tudo ficou no histórico.
- **Situação final: 6 audiências.**

| Processo | Audiência | Equipe |
|---|---|---|
| TRT3 Ouro Preto | 16/11 às 08:23, conciliação, virtual, com link do Zoom (4 fontes) | Prime |
| TJSP | 19/11 às 14:30, depoimento pessoal, presencial | Prime |
| TJMT | 26/01/2027 às 14:30, conciliação, virtual, com link | Êxitos |
| Projudi (TJPR) | Conciliação, sem data | Gold |
| eproc (TJMG) | Conciliação, sem data | Êxitos |
| TJMG | "Mantenho a audiência designada", sem data | Êxitos |

- **Painel como controladoria:** 1,2 s.
- **Pendências na abertura do painel:**
  - 3 sem data;
  - 5 sem advogado;
  - 2 sem tarefa no Atlas;
  - 1 sem confirmação.

## Testes

| Suíte | Verificações |
|---|---|
| `tests/test_etapa16.py`: extração (formatos reais reescritos), o que não é designação, leitura e deduplicação CNJ × Webjur, redesignação, equipe pela letra, pendências, tarefa do Atlas, designar, confirmar, corrigir, ata, permissões (inclusive usuário sem perfil), double check, releitura | 55 |
| `tests/e2e/testar_audiencias.js`: leitura pela tela, agenda × banco, completar data, designar, filtro por pendência, diretoria, peticionador | 13 |

## Decisões de 16/11/2026 (0055)

- **Equipe pela letra do código do cliente:** regra **confirmada** pela controladoria (C = Celeste, P = Prime, G = Gold, E = Êxitos, D = Delta). A equipe "A" deixou de existir, então cliente com código "A..." aparece como "sem equipe".
- **Tarefa de audiência no Atlas:** autorizada, mas a equipe **ainda não acompanha audiências pelo Atlas**.
  - A pendência "sem tarefa no Atlas" foi desligada (parâmetro `audiencias_cobrar_tarefa_atlas` = false), no painel e no double check.
  - As inconsistências desse tipo que estão abertas se regularizam sozinhas na rotina das 18:30.
  - Quando a equipe passar a usar o Atlas para audiências, é só ligar o parâmetro e construir o botão "Criar tarefa no Atlas".
  - **Para o botão:** `create_task` pede o responsável, o cliente e o processo do Atlas, e o sistema já tem os três.
- **Banco real depois da 0055 (6 audiências):**
  - 3 sem data;
  - 6 sem advogado;
  - 1 sem confirmação: a de 16/11 às 08:23;
  - nenhuma "sem tarefa no Atlas".
