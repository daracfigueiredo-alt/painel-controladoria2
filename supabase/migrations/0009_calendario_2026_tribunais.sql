-- =====================================================================
-- 0009 — Calendário 2026 dos tribunais com mais processos na carteira
-- (TJMG 8.13, TJSP 8.26, TJPR 8.16, TJGO 8.09). Somente DADOS; idempotente.
-- Fontes oficiais consultadas em 05/11/2026:
--  TJMG  Portaria Conjunta nº 1798/PR/2026 (DJe 14/4/2026; retroage a 1º/1/2026)
--        https://www8.tjmg.jus.br/institucional/at/pdf/pc17982026.pdf
--  TJSP  Provimento CSM nº 2.813/2025
--        https://portaldori.com.br/2025/11/26/feriados-justica-estadual-sp-e-cartorios-provimento-csm-no-2-813-2025-dispoe-sobre-a-suspensao-do-expediente-forense-no-exercicio-de-2026-e-da-outras-providencias/
--  TJPR  Decreto Judiciário nº 621/2025
--        https://portaldori.com.br/2025/12/03/tj-pr-tjpr-divulga-calendario-de-feriados-no-ano-de-2026/
--  TJGO  Calendário de feriados e pontos facultativos 2026 (versão de 08/06/2026)
--        https://docs.tjgo.jus.br/institucional/feriados/DOC_feriados_2026_08062026.pdf
-- Critérios:
--  * Feriados nacionais já cadastrados em 0002 não são repetidos. Corpus Christi não
--    está na tabela nacional (depende de cada tribunal) e é cadastrado por tribunal.
--  * "Suspensão de expediente" = tipo suspensao (dia não útil); recesso = recesso.
--  * Ponto facultativo = tipo ponto_facultativo: fica registrado, mas CONTA como
--    dia útil (o ato não informa suspensão de prazos). Confirmar com o escritório.
--  * Feriado municipal = abrangência foro (código OOOO do CNJ). Cadastrados só
--    os das capitais confirmados na fonte: BH (TJMG 0024), Curitiba Foro Central
--    (TJPR 0001), Goiânia (TJGO 0051).
--  * NÃO cadastrados (pendentes): feriados municipais das comarcas do interior
--    (Anexo Único da Portaria TJMG 1798/2026 e atos equivalentes), outros foros
--    de Curitiba, e todo o calendário de 2027 (ainda não publicado nas fontes).
-- =====================================================================
insert into public.calendario_dias_nao_uteis (data, abrangencia, tribunal_cnj, foro_cnj, tipo, descricao, fundamento)
select v.d::date, v.abr, v.trib, v.foro, v.tipo, v.descr, v.fund from (values
 -- ---------------- TJMG (8.13) — Portaria Conjunta 1798/PR/2026
 ('2026-01-02','tribunal','8.13',null,'recesso','Feriado forense (recesso) 1º a 6/1','Portaria Conjunta TJMG 1798/PR/2026, art. 1º'),
 ('2026-01-05','tribunal','8.13',null,'recesso','Feriado forense (recesso) 1º a 6/1','Portaria Conjunta TJMG 1798/PR/2026, art. 1º'),
 ('2026-01-06','tribunal','8.13',null,'recesso','Feriado forense (recesso) 1º a 6/1','Portaria Conjunta TJMG 1798/PR/2026, art. 1º'),
 ('2026-01-07','tribunal','8.13',null,'suspensao','Suspensão de prazos processuais 7 a 20/1','Portaria Conjunta TJMG 1798/PR/2026, art. 4º; LC 59/2001, art. 313, § 8º; Portaria Conjunta 1757/2025'),
 ('2026-01-08','tribunal','8.13',null,'suspensao','Suspensão de prazos processuais 7 a 20/1','Portaria Conjunta TJMG 1798/PR/2026, art. 4º'),
 ('2026-01-09','tribunal','8.13',null,'suspensao','Suspensão de prazos processuais 7 a 20/1','Portaria Conjunta TJMG 1798/PR/2026, art. 4º'),
 ('2026-01-12','tribunal','8.13',null,'suspensao','Suspensão de prazos processuais 7 a 20/1','Portaria Conjunta TJMG 1798/PR/2026, art. 4º'),
 ('2026-01-13','tribunal','8.13',null,'suspensao','Suspensão de prazos processuais 7 a 20/1','Portaria Conjunta TJMG 1798/PR/2026, art. 4º'),
 ('2026-01-14','tribunal','8.13',null,'suspensao','Suspensão de prazos processuais 7 a 20/1','Portaria Conjunta TJMG 1798/PR/2026, art. 4º'),
 ('2026-01-15','tribunal','8.13',null,'suspensao','Suspensão de prazos processuais 7 a 20/1','Portaria Conjunta TJMG 1798/PR/2026, art. 4º'),
 ('2026-01-16','tribunal','8.13',null,'suspensao','Suspensão de prazos processuais 7 a 20/1','Portaria Conjunta TJMG 1798/PR/2026, art. 4º'),
 ('2026-01-19','tribunal','8.13',null,'suspensao','Suspensão de prazos processuais 7 a 20/1','Portaria Conjunta TJMG 1798/PR/2026, art. 4º'),
 ('2026-01-20','tribunal','8.13',null,'suspensao','Suspensão de prazos processuais 7 a 20/1','Portaria Conjunta TJMG 1798/PR/2026, art. 4º'),
 ('2026-02-16','tribunal','8.13',null,'feriado','Carnaval (segunda-feira)','Portaria Conjunta TJMG 1798/PR/2026, art. 1º'),
 ('2026-02-17','tribunal','8.13',null,'feriado','Carnaval (terça-feira)','Portaria Conjunta TJMG 1798/PR/2026, art. 1º'),
 ('2026-02-18','tribunal','8.13',null,'feriado','Quarta-feira de Cinzas','Portaria Conjunta TJMG 1798/PR/2026, art. 1º'),
 ('2026-04-01','tribunal','8.13',null,'feriado','Semana Santa','Portaria Conjunta TJMG 1798/PR/2026, art. 1º'),
 ('2026-04-02','tribunal','8.13',null,'feriado','Semana Santa','Portaria Conjunta TJMG 1798/PR/2026, art. 1º'),
 ('2026-04-03','tribunal','8.13',null,'feriado','Semana Santa','Portaria Conjunta TJMG 1798/PR/2026, art. 1º'),
 ('2026-04-20','tribunal','8.13',null,'suspensao','Sem expediente (emenda de Tiradentes)','Portaria Conjunta TJMG 1798/PR/2026, art. 1º, parágrafo único'),
 ('2026-10-30','tribunal','8.13',null,'feriado','Dia do Funcionário Público (MG)','Portaria Conjunta TJMG 1798/PR/2026, art. 1º'),
 ('2026-12-07','tribunal','8.13',null,'suspensao','Sem expediente (emenda do Dia da Justiça)','Portaria Conjunta TJMG 1798/PR/2026, art. 1º, parágrafo único'),
 ('2026-12-08','tribunal','8.13',null,'feriado','Dia da Justiça','Portaria Conjunta TJMG 1798/PR/2026, art. 1º'),
 ('2026-12-21','tribunal','8.13',null,'recesso','Feriado forense (recesso) 20 a 31/12','Portaria Conjunta TJMG 1798/PR/2026, art. 1º'),
 ('2026-12-22','tribunal','8.13',null,'recesso','Feriado forense (recesso) 20 a 31/12','Portaria Conjunta TJMG 1798/PR/2026, art. 1º'),
 ('2026-12-23','tribunal','8.13',null,'recesso','Feriado forense (recesso) 20 a 31/12','Portaria Conjunta TJMG 1798/PR/2026, art. 1º'),
 ('2026-12-24','tribunal','8.13',null,'recesso','Feriado forense (recesso) 20 a 31/12','Portaria Conjunta TJMG 1798/PR/2026, art. 1º'),
 ('2026-12-28','tribunal','8.13',null,'recesso','Feriado forense (recesso) 20 a 31/12','Portaria Conjunta TJMG 1798/PR/2026, art. 1º'),
 ('2026-12-29','tribunal','8.13',null,'recesso','Feriado forense (recesso) 20 a 31/12','Portaria Conjunta TJMG 1798/PR/2026, art. 1º'),
 ('2026-12-30','tribunal','8.13',null,'recesso','Feriado forense (recesso) 20 a 31/12','Portaria Conjunta TJMG 1798/PR/2026, art. 1º'),
 ('2026-12-31','tribunal','8.13',null,'recesso','Feriado forense (recesso) 20 a 31/12','Portaria Conjunta TJMG 1798/PR/2026, art. 1º'),
 -- Comarca de Belo Horizonte (foro 0024)
 ('2026-06-04','foro','8.13','0024','feriado','Corpus Christi (municipal, BH)','Portaria Conjunta TJMG 1798/PR/2026, art. 2º'),
 ('2026-06-05','foro','8.13','0024','suspensao','Sem expediente em BH (emenda de Corpus Christi)','Portaria Conjunta TJMG 1798/PR/2026, art. 2º, parágrafo único'),
 ('2026-08-15','foro','8.13','0024','feriado','Assunção de Nossa Senhora (municipal, BH)','Portaria Conjunta TJMG 1798/PR/2026, art. 2º'),
 -- ---------------- TJSP (8.26) — Provimento CSM 2.813/2025 (Capital e Interior)
 ('2026-01-02','tribunal','8.26',null,'recesso','Recesso: sem expediente de 1º a 6/1','Provimento CSM 2.813/2025, art. 1º, § 1º'),
 ('2026-01-05','tribunal','8.26',null,'recesso','Recesso: sem expediente de 1º a 6/1','Provimento CSM 2.813/2025, art. 1º, § 1º'),
 ('2026-01-06','tribunal','8.26',null,'recesso','Recesso: sem expediente de 1º a 6/1','Provimento CSM 2.813/2025, art. 1º, § 1º'),
 ('2026-02-16','tribunal','8.26',null,'suspensao','Carnaval','Provimento CSM 2.813/2025, art. 1º'),
 ('2026-02-17','tribunal','8.26',null,'suspensao','Carnaval','Provimento CSM 2.813/2025, art. 1º'),
 ('2026-04-02','tribunal','8.26',null,'suspensao','Endoenças','Provimento CSM 2.813/2025, art. 1º'),
 ('2026-04-03','tribunal','8.26',null,'feriado','Sexta-feira da Paixão','Provimento CSM 2.813/2025, art. 1º'),
 ('2026-04-20','tribunal','8.26',null,'suspensao','Suspensão do expediente','Provimento CSM 2.813/2025, art. 1º'),
 ('2026-06-04','tribunal','8.26',null,'feriado','Corpus Christi','Provimento CSM 2.813/2025, art. 1º'),
 ('2026-06-05','tribunal','8.26',null,'suspensao','Suspensão do expediente','Provimento CSM 2.813/2025, art. 1º'),
 ('2026-07-09','tribunal','8.26',null,'feriado','Data Magna do Estado de São Paulo','Provimento CSM 2.813/2025, art. 1º'),
 ('2026-07-10','tribunal','8.26',null,'suspensao','Suspensão do expediente','Provimento CSM 2.813/2025, art. 1º'),
 ('2026-10-28','tribunal','8.26',null,'feriado','Dia do Servidor Público','Provimento CSM 2.813/2025, art. 1º'),
 ('2026-12-07','tribunal','8.26',null,'suspensao','Suspensão do expediente','Provimento CSM 2.813/2025, art. 1º'),
 ('2026-12-08','tribunal','8.26',null,'feriado','Dia da Justiça','Provimento CSM 2.813/2025, art. 1º'),
 ('2026-12-21','tribunal','8.26',null,'recesso','Recesso: sem expediente de 20 a 31/12','Provimento CSM 2.813/2025, art. 1º, § 1º'),
 ('2026-12-22','tribunal','8.26',null,'recesso','Recesso: sem expediente de 20 a 31/12','Provimento CSM 2.813/2025, art. 1º, § 1º'),
 ('2026-12-23','tribunal','8.26',null,'recesso','Recesso: sem expediente de 20 a 31/12','Provimento CSM 2.813/2025, art. 1º, § 1º'),
 ('2026-12-24','tribunal','8.26',null,'recesso','Recesso: sem expediente de 20 a 31/12','Provimento CSM 2.813/2025, art. 1º, § 1º'),
 ('2026-12-28','tribunal','8.26',null,'recesso','Recesso: sem expediente de 20 a 31/12','Provimento CSM 2.813/2025, art. 1º, § 1º'),
 ('2026-12-29','tribunal','8.26',null,'recesso','Recesso: sem expediente de 20 a 31/12','Provimento CSM 2.813/2025, art. 1º, § 1º'),
 ('2026-12-30','tribunal','8.26',null,'recesso','Recesso: sem expediente de 20 a 31/12','Provimento CSM 2.813/2025, art. 1º, § 1º'),
 ('2026-12-31','tribunal','8.26',null,'recesso','Recesso: sem expediente de 20 a 31/12','Provimento CSM 2.813/2025, art. 1º, § 1º'),
 -- ---------------- TJPR (8.16) — Decreto Judiciário 621/2025
 ('2026-02-16','tribunal','8.16',null,'suspensao','Véspera de Carnaval (suspensão de expediente)','Decreto Judiciário TJPR 621/2025, art. 2º'),
 ('2026-02-17','tribunal','8.16',null,'feriado','Carnaval','Decreto Judiciário TJPR 621/2025'),
 ('2026-04-02','tribunal','8.16',null,'suspensao','Quinta-feira Santa (suspensão de expediente)','Decreto Judiciário TJPR 621/2025, art. 2º'),
 ('2026-04-03','tribunal','8.16',null,'feriado','Paixão de Cristo','Decreto Judiciário TJPR 621/2025'),
 ('2026-04-20','tribunal','8.16',null,'suspensao','Suspensão de expediente','Decreto Judiciário TJPR 621/2025, art. 2º'),
 ('2026-06-04','tribunal','8.16',null,'feriado','Corpus Christi','Decreto Judiciário TJPR 621/2025'),
 ('2026-06-05','tribunal','8.16',null,'suspensao','Suspensão de expediente','Decreto Judiciário TJPR 621/2025, art. 2º'),
 ('2026-10-30','tribunal','8.16',null,'feriado','Dia do Funcionário Público (transferido de 28/10)','Decreto Judiciário TJPR 621/2025'),
 ('2026-12-18','tribunal','8.16',null,'feriado','Dia da Justiça (transferido de 8/12)','Decreto Judiciário TJPR 621/2025'),
 ('2026-12-24','tribunal','8.16',null,'suspensao','Véspera de Natal (suspensão de expediente)','Decreto Judiciário TJPR 621/2025, art. 3º'),
 ('2026-12-31','tribunal','8.16',null,'suspensao','Véspera de Ano Novo (suspensão de expediente)','Decreto Judiciário TJPR 621/2025, art. 3º'),
 ('2026-09-08','foro','8.16','0001','feriado','Padroeira de Curitiba (Foro Central de Curitiba)','Decreto Judiciário TJPR 621/2025'),
 -- ---------------- TJGO (8.09) — Calendário 2026 (Art. 123 RITJGO; Art. 91 COJEG)
 ('2026-02-16','tribunal','8.09',null,'feriado','Carnaval','Calendário TJGO 2026 (versão 08/06/2026)'),
 ('2026-02-17','tribunal','8.09',null,'feriado','Carnaval','Calendário TJGO 2026 (versão 08/06/2026)'),
 ('2026-02-18','tribunal','8.09',null,'ponto_facultativo','Carnaval — expediente até 12h (meio período)','Calendário TJGO 2026 (versão 08/06/2026)'),
 ('2026-03-20','tribunal','8.09',null,'ponto_facultativo','Evento MotoGP em Goiânia','Calendário TJGO 2026 (versão 08/06/2026)'),
 ('2026-04-01','tribunal','8.09',null,'feriado','Semana Santa','Calendário TJGO 2026 (versão 08/06/2026); Art. 91 COJEG'),
 ('2026-04-02','tribunal','8.09',null,'feriado','Semana Santa','Calendário TJGO 2026 (versão 08/06/2026); Art. 91 COJEG'),
 ('2026-04-03','tribunal','8.09',null,'feriado','Semana Santa','Calendário TJGO 2026 (versão 08/06/2026); Art. 91 COJEG'),
 ('2026-04-20','tribunal','8.09',null,'ponto_facultativo','Ponto facultativo','Calendário TJGO 2026 (versão 08/06/2026)'),
 ('2026-06-04','tribunal','8.09',null,'feriado','Corpus Christi (listado como nacional no TJGO; não consta da tabela nacional do sistema)','Calendário TJGO 2026 (versão 08/06/2026)'),
 ('2026-06-05','tribunal','8.09',null,'ponto_facultativo','Ponto facultativo','Calendário TJGO 2026 (versão 08/06/2026)'),
 ('2026-07-26','tribunal','8.09',null,'feriado','Fundação da Cidade de Goiás','Calendário TJGO 2026 (versão 08/06/2026)'),
 ('2026-10-24','tribunal','8.09',null,'feriado','Aniversário de Goiânia','Calendário TJGO 2026 (versão 08/06/2026)'),
 ('2026-10-28','tribunal','8.09',null,'feriado','Dia do Servidor Público','Calendário TJGO 2026; Lei estadual 20.756/2020'),
 ('2026-12-08','tribunal','8.09',null,'feriado','Dia da Justiça','Calendário TJGO 2026; Art. 123 RITJGO'),
 ('2026-12-21','tribunal','8.09',null,'recesso','Recesso forense (início 20/12; data final não informada na fonte)','Calendário TJGO 2026; Art. 123 RITJGO'),
 ('2026-12-22','tribunal','8.09',null,'recesso','Recesso forense','Calendário TJGO 2026; Art. 123 RITJGO'),
 ('2026-12-23','tribunal','8.09',null,'recesso','Recesso forense','Calendário TJGO 2026; Art. 123 RITJGO'),
 ('2026-12-24','tribunal','8.09',null,'recesso','Recesso forense','Calendário TJGO 2026; Art. 123 RITJGO'),
 ('2026-12-28','tribunal','8.09',null,'recesso','Recesso forense','Calendário TJGO 2026; Art. 123 RITJGO'),
 ('2026-12-29','tribunal','8.09',null,'recesso','Recesso forense','Calendário TJGO 2026; Art. 123 RITJGO'),
 ('2026-12-30','tribunal','8.09',null,'recesso','Recesso forense','Calendário TJGO 2026; Art. 123 RITJGO'),
 ('2026-12-31','tribunal','8.09',null,'recesso','Recesso forense','Calendário TJGO 2026; Art. 123 RITJGO'),
 ('2026-05-24','foro','8.09','0051','feriado','Nossa Senhora Auxiliadora (Goiânia)','Calendário TJGO 2026 (versão 08/06/2026)')
) v(d, abr, trib, foro, tipo, descr, fund)
on conflict do nothing;

insert into public.eventos (chave_dedupe, tipo, ocorrido_em, precisao_ocorrido, origem, historico_recuperado, classificacao, evidencia)
values ('carga:calendario_2026_tribunais', 'cadastro_administrativo', now(), 'segundo', 'administrativo', false, 'confirmado',
        jsonb_build_object('operacao','carga_calendario','migracao','0009','tribunais','8.13, 8.26, 8.16, 8.09',
                           'consulta_fontes','2026-11-05'))
on conflict (chave_dedupe) do nothing;
