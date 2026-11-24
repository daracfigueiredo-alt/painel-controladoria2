const fs=require('fs'); const vm=require('vm');
const code=fs.readFileSync(require('path').join(__dirname,'../../integracoes/apps_script/triagem_webjur.gs'),'utf8');
const labels={}; const added=[]; let fetches=[];
const mk=(id,from,ok)=>({getId:()=>id,getFrom:()=>from,getSubject:()=>'Public',getRawContent:()=>'RAW'+id,_ok:ok});
const conv=(id,msgs)=>({getId:()=>id,getMessages:()=>msgs,addLabel:l=>added.push([id,l.n])});
const threads=[conv('t1',[mk('m1','Webjur <webjur@webjur.com.br>','ok')]),conv('t2',[mk('m2','webjur@webjur.com.br','conf')]),conv('t3',[mk('m3','webjur@webjur.com.br','erro')]),conv('t4',[mk('m4','outro@x.com','ok')])];
const ctx={console,JSON,Object,
 GmailApp:{search:(q)=>{ctx.q=q;return threads},getUserLabelByName:n=>labels[n],createLabel:n=>(labels[n]={n})},
 PropertiesService:{getScriptProperties:()=>({getProperty:()=>'segredo'})},
 Utilities:{base64Encode:s=>Buffer.from(s).toString('base64'),Charset:{UTF_8:1}},
 UrlFetchApp:{fetch:(u,o)=>{const b=JSON.parse(o.payload);fetches.push(b.mensagens.map(m=>m.gmail_id));
   return {getResponseCode:()=>200,getContentText:()=>JSON.stringify({resultados:b.mensagens.map(m=>{const id=m.gmail_id;
     return id==='m1'?{gmail_id:id,ok:true,remessas:[{status:'importada'}]}:id==='m2'?{gmail_id:id,ok:false,remessas:[{status:'contagem_divergente'}]}:{gmail_id:id,ok:false,erro:'falha',remessas:[]}})})}}}};
vm.createContext(ctx); vm.runInContext(code+'\nthis.r=triagemWebjur();',ctx);
// verificações (simulação do Gmail e da função; dados fictícios)
let ok = 0, falhas = 0;
const check = (n, e, o) => { const a = JSON.stringify(e), b = JSON.stringify(o); if (a === b) { ok++; console.log('OK  ', n); } else { falhas++; console.log('FALHA', n, a, b); } };
check('busca só e-mails da Webjur ainda não tratados, sem as cobranças', 'from:webjur@webjur.com.br newer_than:10d -label:"Controladoria/Webjur importado" -label:"Controladoria/Webjur conferir" -subject:(boleto OR fatura OR cobrança OR "nota fiscal")', ctx.q);
check('envia só mensagens do remetente da Webjur', [['m1', 'm2', 'm3']], fetches);
check('marca importado / conferir; erro fica sem marca (reenvio na próxima)', [['t1', 'Controladoria/Webjur importado'], ['t2', 'Controladoria/Webjur conferir']], added);
check('resumo', { enviados: 3, importados: 1, conferir: 1, erros: 1 }, ctx.r);
console.log(`\n${ok}/${ok + falhas} OK`); if (falhas) process.exit(1);
