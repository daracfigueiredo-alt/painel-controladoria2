/**
 * Triagem diária dos e-mails da Webjur — script da conta controladoria.oecadv@gmail.com
 * Controladoria Jurídica Oliveira e Camilo (docs/ETAPA13_WEBJUR_EMAIL.md)
 *
 * O que faz, todo dia às 13h e às 17h (horário de Brasília):
 *   1. procura na caixa os e-mails de webjur@webjur.com.br dos últimos 10 dias que ainda não foram tratados;
 *   2. envia cada um ao sistema da controladoria (função webjur-email), que lê as publicações,
 *      confere a contagem declarada pela Webjur e registra;
 *   3. marca a conversa no Gmail:
 *        "Controladoria/Webjur importado"  — registrado (ou já estava registrado);
 *        "Controladoria/Webjur conferir"   — contagem divergente ou e-mail não reconhecido:
 *                                             conferir no portal da Webjur e importar a Planilha no painel.
 *      E-mails com erro de conexão ficam sem marca e são reenviados na execução seguinte.
 *
 * O script só LÊ os e-mails e coloca as marcas acima. Não apaga, não move, não responde nem encaminha nada.
 *
 * Configuração (uma vez): veja o passo a passo em docs/ETAPA13_WEBJUR_EMAIL.md.
 *   - Propriedade do script WEBJUR_SECRET = o mesmo valor do segredo WEBJUR_EMAIL_SECRET da função.
 *   - Executar instalarAgendamento() uma vez e autorizar.
 */

var URL_FUNCAO = 'https://impoejdocxuihficjvxm.supabase.co/functions/v1/webjur-email';
// Chave PÚBLICA do projeto (a mesma do painel). Só passa pela portaria da função; quem autoriza é o WEBJUR_SECRET.
var CHAVE_PUBLICA = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImltcG9lamRvY3h1aWhmaWNqdnhtIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTQwODU4MjgsImV4cCI6MjEwOTY2MTgyOH0.8Q3kHln772M2wfYFXqU4QSTNIGi1KgvshHN7J6XldNo';
var REMETENTE = 'webjur@webjur.com.br';
var MARCA_OK = 'Controladoria/Webjur importado';
var MARCA_CONFERIR = 'Controladoria/Webjur conferir';
var POR_CHAMADA = 5;          // e-mails por envio (cada e-mail da Webjur tem uns 300 KB)
var DIAS = 10;                // janela de busca
var IGNORAR = '-subject:(boleto OR fatura OR cobrança OR "nota fiscal")';

function triagemWebjur() {
  var segredo = segredoDoScript_();
  var ok = marca_(MARCA_OK), conferir = marca_(MARCA_CONFERIR);
  var consulta = 'from:' + REMETENTE + ' newer_than:' + DIAS + 'd -label:"' + MARCA_OK + '" -label:"' + MARCA_CONFERIR + '"';
  consulta += ' ' + IGNORAR;   // cobranças da Webjur (boleto, fatura, nota fiscal) não são e-mails de publicações
  var conversas = GmailApp.search(consulta, 0, 100);
  var fila = [];
  conversas.forEach(function (c) {
    c.getMessages().forEach(function (m) {
      if (m.getFrom().toLowerCase().indexOf(REMETENTE) >= 0) fila.push({ conversa: c, msg: m });
    });
  });
  var resumo = { enviados: 0, importados: 0, conferir: 0, erros: 0 };
  var porConversa = {};
  for (var i = 0; i < fila.length; i += POR_CHAMADA) {
    var lote = fila.slice(i, i + POR_CHAMADA);
    var corpo = { mensagens: lote.map(function (x) {
      return { gmail_id: x.msg.getId(), assunto: x.msg.getSubject(),
               raw_base64: Utilities.base64Encode(x.msg.getRawContent(), Utilities.Charset.UTF_8) };
    }) };
    var resposta;
    try { resposta = chamar_(segredo, corpo); }
    catch (e) { console.error('Falha ao enviar: ' + e.message); resumo.erros += lote.length; continue; }   // tenta de novo na próxima execução
    resumo.enviados += lote.length;
    (resposta.resultados || []).forEach(function (r, k) {
      var c = lote[k].conversa, id = c.getId();
      if (!porConversa[id]) porConversa[id] = { conversa: c, ok: true, erro: false };
      if (r.ok) { resumo.importados++; return; }
      var soErro = r.erro && !(r.remessas || []).length;   // erro de leitura ou do banco: tenta de novo
      if (soErro) { porConversa[id].erro = true; resumo.erros++; console.error(r.gmail_id + ': ' + r.erro); }
      else { porConversa[id].ok = false; resumo.conferir++; }
    });
  }
  Object.keys(porConversa).forEach(function (id) {
    var x = porConversa[id];
    if (x.erro) return;
    x.conversa.addLabel(x.ok ? ok : conferir);
  });
  console.log('Triagem Webjur: ' + JSON.stringify(resumo));
  return resumo;
}

/** Confere se o script fala com o sistema (não envia e-mail nenhum). */
function testarConexao() {
  var r = chamar_(segredoDoScript_(), { acao: 'testar' });
  console.log(r.mensagem || JSON.stringify(r));
}

/** Cria (ou recria) o agendamento: todo dia às 13h e às 17h. Rodar uma vez. */
function instalarAgendamento() {
  ScriptApp.getProjectTriggers().forEach(function (t) {
    if (t.getHandlerFunction() === 'triagemWebjur') ScriptApp.deleteTrigger(t);
  });
  [13, 17].forEach(function (h) {
    ScriptApp.newTrigger('triagemWebjur').timeBased().everyDays(1).atHour(h).inTimezone('America/Sao_Paulo').create();
  });
  marca_(MARCA_OK); marca_(MARCA_CONFERIR);
  console.log('Agendamento criado: todo dia às 13h e às 17h (Brasília).');
}

function chamar_(segredo, corpo) {
  var r = UrlFetchApp.fetch(URL_FUNCAO, {
    method: 'post', contentType: 'application/json', muteHttpExceptions: true,
    headers: { Authorization: 'Bearer ' + CHAVE_PUBLICA, 'x-webjur-secret': segredo },
    payload: JSON.stringify(corpo)
  });
  var txt = r.getContentText(), j = {};
  try { j = JSON.parse(txt); } catch (e) { /* resposta não JSON */ }
  if (r.getResponseCode() !== 200) throw new Error('HTTP ' + r.getResponseCode() + ': ' + (j.motivo || j.erro || txt.slice(0, 200)) +
    (j.diagnostico ? ' ' + JSON.stringify(j.diagnostico) : ''));
  return j;
}
function segredoDoScript_() {
  var s = PropertiesService.getScriptProperties().getProperty('WEBJUR_SECRET');
  if (!s) throw new Error('Falta a propriedade WEBJUR_SECRET (Configurações do projeto › Propriedades do script).');
  return s.trim();
}
function marca_(nome) { return GmailApp.getUserLabelByName(nome) || GmailApp.createLabel(nome); }

/** Diagnóstico da configuração: mostra só o tamanho e o início do SHA-256 do WEBJUR_SECRET (nunca o valor).
 *  A função webjur-email devolve o mesmo resumo do segredo dela quando recusa a chamada. */
function diagnosticoSegredo() { var s = (PropertiesService.getScriptProperties().getProperty('WEBJUR_SECRET') || '').trim(); var d = Utilities.computeDigest(Utilities.DigestAlgorithm.SHA_256, s, Utilities.Charset.UTF_8).map(function (b) { return ('0' + (b & 255).toString(16)).slice(-2); }).join(''); console.log('tamanho ' + s.length + ', resumo ' + d.slice(0, 6) + ', só letras a-f e números: ' + /^[0-9a-f]+$/.test(s)); }
