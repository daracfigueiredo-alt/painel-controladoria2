/* Testes das regras puras da criação automática da tarefa de análise (dados FICTÍCIOS, formato
 * conferido no formulário real do ADVBOX em 10/11/2026). O preenchimento na página real é
 * testado na homologação, com tarefa de TESTE no caso "TESTE 1.0". */
const C = require('../lib/advbox_criacao.js');
const res = [];
const check = (n, e, o) => res.push([n, String(e), String(o), String(e) === String(o) ? 'OK' : 'FALHA']);
const CNJ = '5000928-87.2026.8.13.0074';
const ops = [`BANCO FICTICIO S.A. - <b style="text-decoration: underline">${CNJ}</b> - AÇÃO REVISIONAL`,
             `RC2 - G122 - LOJA FICTICIA LTDA - <b style="text-decoration: underline">${CNJ}</b> - AÇÃO REVISIONAL`,
             `OUTRO - <b>5000928-87.2026.8.13.0075</b> - AÇÃO`];
check('Processo: só opções com o CNJ completo', 2, C.filtrarProcessos(ops, { cnj: CNJ }).length);
check('Processo: CNJ incompleto não procura', 0, C.filtrarProcessos(ops, { cnj: '5000928-87.2026' }).length);
check('Processo: "Nenhum processo encontrado" não é opção', 0, C.filtrarProcessos(['Nenhum processo encontrado. Cadastre o processo deste cliente na fase de ATENDIMENTO.'], { cnj: CNJ }).length);
check('Teste: caso pelo nome (TESTE 1.0), não TESTE 1.01', 1,
  C.filtrarProcessos(['<b style="text-decoration: underline">TESTE 1.0</b> - NEGOCIAÇÃO COM FORNECEDORES', '<b>TESTE 1.01</b> - OUTRO'], { teste: true, busca: 'TESTE 1.0' }).length);
const col = [{ lawsuit_id: '14149776', texto: ops[0] }, { lawsuit_id: '14149777', texto: ops[1] }];
const real2 = [{ lawsuit_id: '19414964', texto: 'CAIXA ECONOMICA FEDERAL - CEF - 6017473-77.2026.4.06.0000 - AGRAVO DE INSTRUMENTO' },
  { lawsuit_id: '19414964', texto: 'E500 - GUSTAVO REIS LIMA - 6017473-77.2026.4.06.0000 - AGRAVO DE INSTRUMENTO' },
  { lawsuit_id: '19414964', texto: 'E500 - SAMUEL ROCHA LIMA - 6017473-77.2026.4.06.0000 - AGRAVO DE INSTRUMENTO' }];
check('Mesmo processo listado uma vez por parte (mesmo ID, caso real #2): usa o processo, pela primeira linha', 'usar|19414964|CAIXA ECONOMICA FEDERAL - CEF - 6017473-77.2026.4.06.0000 - AGRAVO DE INSTRUMENTO',
  (d => `${d.acao}|${d.lawsuit_id}|${d.texto}`)(C.decidirProcesso(real2, null, '6017473-77.2026.4.06.0000')));
check('IDs de processo diferentes para o CNJ: continua bloqueando', 'bloquear|processo_ambiguo',
  (d => `${d.acao}|${d.motivo}`)(C.decidirProcesso([...real2, { lawsuit_id: '1', texto: 'OUTRO - 6017473-77.2026.4.06.0000' }], null, '6017473-77.2026.4.06.0000')));
check('Dois cadastros para o CNJ, sem processo conhecido: bloqueia (ambíguo) e lista as opções', 'bloquear|processo_ambiguo|2',
  (d => `${d.acao}|${d.motivo}|${d.detalhe.opcoes.length}`)(C.decidirProcesso(col, null, CNJ)));
check('Dois cadastros, processo conhecido: usa o conhecido', 'usar|14149777', (d => `${d.acao}|${d.lawsuit_id}`)(C.decidirProcesso(col, '14149777', CNJ)));
check('Processo conhecido fora da busca: bloqueia (divergente)', 'bloquear|processo_divergente', (d => `${d.acao}|${d.motivo}`)(C.decidirProcesso(col, '1', CNJ)));
check('Nenhum cadastro: bloqueia (cadastrar antes)', 'bloquear|processo_nao_encontrado', (d => `${d.acao}|${d.motivo}`)(C.decidirProcesso([], null, CNJ)));
check('Um cadastro: usa', 'usar|14149776', (d => `${d.acao}|${d.lawsuit_id}`)(C.decidirProcesso(col.slice(0, 1), null, CNJ)));
check('Tipo exato', 'true|false|false', [C.tipoConfere('ANÁLISE DO CASO (50 pts)', 'ANÁLISE DO CASO (50 pts)'),
  C.tipoConfere('ANÁLISE DE CASO TRIBUTÁRIO (60 pts)', 'ANÁLISE DO CASO (50 pts)'), C.tipoConfere('ANÁLISE DO CASO', 'ANÁLISE DO CASO (50 pts)')].join('|'));
check('Data ISO -> dd/mm/aaaa', '11/11/2026', C.dataBR('2026-11-11'));
const esp = { lawsuit_id: '19368297', tipo_id: '8849391', responsavel_id: '296462', data: '10/11/2026', prazo_fatal: '11/11/2026', descricao: 'Linha 1\nLinha 2' };
const campos = { lawsuits_id: ['19368297'], tasks_id: ['8849391'], 'guests[]': ['296462'], date: ['10/11/2026'], date_deadline: ['11/11/2026'],
                 comments: ['Linha 1\r\nLinha 2'], editing: [''], workflow: [''], workflow_id: ['0'] };
check('Formulário conferido: sem divergência (quebra de linha \\r\\n aceita)', 0, C.conferirFormulario(campos, esp).length);
check('Dois responsáveis: divergência', 'responsavel', C.conferirFormulario({ ...campos, 'guests[]': ['296462', '1'] }, esp).map(d => d.campo).join());
check('Outra data, outro tipo, descrição cortada: 3 divergências', 'tipo,data,descricao',
  C.conferirFormulario({ ...campos, tasks_id: ['10384487'], date: ['11/11/2026'], comments: ['Linha 1'] }, esp).map(d => d.campo).join());
check('Formulário de edição (editing) nunca é enviado', 'editing', C.conferirFormulario({ ...campos, editing: ['297747789'] }, esp).map(d => d.campo).join());
check('Fluxo de trabalho escolhido: divergência', 'workflow', C.conferirFormulario({ ...campos, workflow: ['16617'] }, esp).map(d => d.campo).join());
const agora = Date.UTC(2026, 10, 10, 16, 36);   // 13:36 em Brasília
const tela = { titulo: 'Análise do Caso', criado_em: '10/11/2026 13:34' };
check('Tarefa criada confere (título = tipo sem pontos, criada agora, ID novo)', 0, C.conferirCriada(tela, '1', '297747789', 'ANÁLISE DO CASO (50 pts)', agora).length);
check('Mesmo ID de antes do envio: não confere', 'mesmo ID de antes do envio', C.conferirCriada(tela, '297747789', '297747789', 'ANÁLISE DO CASO (50 pts)', agora).join());
check('Tarefa antiga aberta: não confere', 'criada fora da janela de 10 minutos', C.conferirCriada({ ...tela, criado_em: '09/11/2026 13:34' }, '1', '2', 'ANÁLISE DO CASO (50 pts)', agora).join());
check('Outro tipo aberto: não confere', 'título diferente do tipo', C.conferirCriada({ ...tela, titulo: 'Apelação' }, '1', '2', 'ANÁLISE DO CASO (50 pts)', agora).join());
const P = require('../lib/advbox_parse.js');
const TELA_REAL = 'done\nConcluir\nshare\nCopiar link\nedit\nEditar\ndelete\nExcluir\nclear\n{PAINEL}Análise do Caso\n50pts\n\nTESTE CONTROLADORIA — tarefa de análise criada automaticamente pela extensão (homologação). Pode ser desconsiderada.\n\nResponsável\n\n \n\nSituação\n\nPendente (1)\n\nData do evento\n\ntoday\nterça, 10/11/2026\n\nPrazo fatal\n\ntoday\nquarta, 11/11/2026\n\nCriado por\n\nMayra Gabriela Costa Gomes\n\n10/11/2026 15:07 (agora mesmo)\n\nProcesso\n\nNumeração não informada\n';
const PAINEL = 'Tratativa ainda não iniciada.\nIniciar tratativa\nAinda não localizada na planilha importada.\n';
const agoraReal = Date.UTC(2026, 10, 10, 18, 8);
check('Tela real (10/11, tarefa 297813142) lida SEM o painel da extensão: confere', 0,
  C.conferirCriada(P.lerTela(TELA_REAL.replace('{PAINEL}', ''), '297813142'), '297747789', '297813142', 'ANÁLISE DO CASO (50 pts)', agoraReal).length);
check('Com o texto do painel junto, o título sai errado (por isso a leitura esconde o painel)', 'título diferente do tipo',
  C.conferirCriada(P.lerTela(TELA_REAL.replace('{PAINEL}', PAINEL), '297813142'), '297747789', '297813142', 'ANÁLISE DO CASO (50 pts)', agoraReal).join());
const w = Math.max(...res.map(r => r[0].length));
for (const [n, e, o, s] of res) console.log(`${s.padEnd(5)} ${n.padEnd(w)}` + (s === 'OK' ? '' : `  esperado=${e} obtido=${o}`));
const ok = res.filter(r => r[3] === 'OK').length;
console.log(`\n${ok}/${res.length} OK`); process.exit(ok === res.length ? 0 : 1);
