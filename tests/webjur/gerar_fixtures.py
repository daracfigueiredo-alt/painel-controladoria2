"""Gera e-mails FICTÍCIOS no formato do e-mail diário da Webjur.

A marcação (tabelas, spans, <b>rótulo:</b>, <br>) reproduz a dos e-mails reais conferidos em
06/11/2026; todo o conteúdo (nomes, números, textos) é inventado. CNJs com dígito válido.
"""
import os, quopri
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText
from email.utils import format_datetime
import datetime

AQUI = os.path.dirname(os.path.abspath(__file__))
F = os.path.join(AQUI, "fixtures"); os.makedirs(F, exist_ok=True)
SP = '<span class="font" style="font-family:Verdana"><span class="size" style="font-size:13px">{}</span></span>'
CNJ_A1, CNJ_A2, CNJ_A3 = "0000101-95.2026.8.02.0001", "0000102-80.2026.8.02.0001", "0000103-65.2026.8.02.0001"
CNJ_MG = "0000201-72.2026.8.13.0024"

def linha(conteudo): return f'<tr><td><div align="justify">{SP.format(conteudo)}</div></td></tr>'

def pub_djen(n, disp, publ, uf, vara, cnj, texto, ident, tipo="Intimação"):
    return "".join([
        f'<tr><td align="left">{SP.format(f"<br><br><b>Publicação: {n}</b><a name=\"SeqMat{n}\">.</a>&nbsp;&nbsp;")}<br></td></tr>',
        linha(f"<b>Data de Disponibilização:</b> {disp}"),
        f'<tr><td><div align="justify">{SP.format("<b>Data de Publicação:</b>")} {SP.format(publ)}</div></td></tr>',
        linha(f"<b>Jornal:</b> Diário Oficial DJ {uf}"),
        linha("<b>Caderno: </b>TJALDJEN"),
        f'<tr><td><div align="justify">{SP.format("<b>Local: </b>")}{SP.format("DJEN - Diário de Justiça Eletrônico Nacional - TJAL&nbsp;&nbsp;")}{SP.format(f" - {vara}&nbsp;&nbsp;")}</div></td></tr>',
        linha("<b>Página: </b>00001"),
        linha(f"{tipo}<br><br> <br> {tipo}<br> PROCESSO: {cnj} - PROCEDIMENTO COMUM CIVEL - ||<br><i> ADV:</i> <b>ADVOGADA FICTICIA DE TESTE</b> (OAB 999999/MG),<br>"
              f"<i> AUTOR:</i> Empresa Ficticia Ltda -<br><i> REU:</i> Outra Empresa Ficticia S.A. - {texto} |||<br> POLO ATIVO: EMPRESA FICTICIA LTDA<br>"
              f" ADVOGADO: ADVOGADA FICTICIA DE TESTE - OAB: 999999/MG"
              + (f" Acesso ao documento: https://exemplo.invalid/doc?x={ident} Identificador do documento: {ident}" if ident else "")),
    ])

def pub_superior(n, disp, publ, cnj, texto):
    return "".join([
        f'<tr><td align="left">{SP.format(f"<br><br><b>Publicação: {n}</b><a name=\"SeqMat{n}\">.</a>")}<br></td></tr>',
        linha(f"<b>Data de Disponibilização:</b> {disp}"),
        f'<tr><td><div align="justify">{SP.format("<b>Data de Publicação:</b>")} {SP.format(publ)}</div></td></tr>',
        linha("<b>Jornal:</b> Tribunais Superiores"),
        linha("<b>Tribunal:</b> Tribunal Regional Federal da 1ª Região - TRIBUNAL REGIONAL FEDERAL DA PRIMEIRA REGIÃO"),
        linha("<b>Seção:</b> DJ Seção Única"),
        linha("<b>Página: </b>00495"),
        linha(f"Ata de Distribuição de teste<br>PROCESSOS DISTRIBUÍDOS<br>PROCESSO: {cnj} CLASSE JUDICIAL: APELACAO CIVEL<br>{texto}"),
    ])

def secao(nome, data, pubs_html, n):
    cab = linha(f"<b>Leitura {nome} - {data} - Total de Publicações: {n}.</b>") + linha(f"Diário Oficial {nome} - Justiça: {data}") + linha("Vencimento da assinatura: 31/12/2099")
    if n == 0 and not pubs_html:
        return cab + linha("Não foi localizada qualquer publicação a ser enviada a sua caixa de e-mail na pesquisa realizada nesta data.") + linha("Observações importantes:") + linha("- Texto informativo fictício.")
    return cab + pubs_html + linha(f"Total de Publicações ( Assinatura {nome} ): {n}")

def email(chave, data_envio, secoes, resumo=None):
    resumo = resumo if resumo is not None else [(s[0], s[1], s[3]) for s in secoes]
    corpo = "".join([
        '<html><head><style>p{}</style></head><body><table>',
        linha("Para controle interno da controladoria (texto fictício de encaminhamento)."),
        linha("---------- Mensagem encaminhada ----------"), linha(" De: &lt;remetente@exemplo.invalid&gt;"),
        linha(f"Data: {data_envio}"), linha(f"Chave secreta do cliente: {chave}"),
        linha("Cliente<b>ADVOGADA FICTICIA DE TESTE</b>"), linha("Resumo"),
        *[linha(f"Leitura {n} ( {d} ) - Total publicações: {t} <a href='#'>Atalho</a>") for n, d, t in resumo],
        *[secao(*s) for s in secoes], '</table></body></html>'])
    return corpo

D = "05/10/2026"
TEXTO_IGUAL = "Intimem-se as partes para manifestacao em 5 (cinco) dias. Texto ficticio."
# E-mail 1: 3 publicações (2 do mesmo processo e mesma data, com teores diferentes) + 1 superior sem identificador
e1 = email("Public 4. UFs 3. (00.00000000)", "seg, 5 de out de 2026 às 09:40", [
    ("DJ Alagoas", D, pub_djen(1, D, "06/10/2026", "Alagoas", "1ª Vara Cível Fictícia", CNJ_A1, "Primeiro despacho ficticio: cite-se.", "900000001")
                    + pub_djen(2, D, "06/10/2026", "Alagoas", "1ª Vara Cível Fictícia", CNJ_A1, "Segundo despacho ficticio: intime-se o perito.", "900000002")
                    + pub_djen(3, D, "06/10/2026", "Alagoas", "2ª Vara Cível Fictícia", CNJ_A2, TEXTO_IGUAL, "900000003"), 3),
    ("DJ União", D, pub_superior(1, D, D, CNJ_MG, "APELANTE: EMPRESA FICTICIA LTDA DATA DISTRIBUICAO: 05/10/2026"), 1),
    ("DJ Acre", D, "", 0),
])
# E-mail 2 (revisão): repete a publicação 900000001 e traz outra com MESMO CNJ, data e teor da 900000003,
# porém com identificador diferente (publicação distinta na fonte).
e2 = email("Public 2. UFs 2. (00.00000000)", "seg, 5 de out de 2026 às 15:10", [
    ("DJ Alagoas", D, pub_djen(1, D, "06/10/2026", "Alagoas", "1ª Vara Cível Fictícia", CNJ_A1, "Primeiro despacho ficticio: cite-se.", "900000001")
                    + pub_djen(2, D, "06/10/2026", "Alagoas", "2ª Vara Cível Fictícia", CNJ_A2, TEXTO_IGUAL, "900000004"), 2),
    ("DJ Acre", D, "", 0),
])
# E-mail divergente: declara 2 publicações e traz 1; e o resumo lista um diário que não aparece.
e3 = email("Public 2. UFs 1. (00.00000000)", "ter, 6 de out de 2026 às 09:40", [
    ("DJ Alagoas", "06/10/2026", pub_djen(1, "06/10/2026", "07/10/2026", "Alagoas", "1ª Vara Cível Fictícia", CNJ_A3, "Despacho ficticio unico.", "900000010"), 2),
], resumo=[("DJ Alagoas", "06/10/2026", 2), ("DJ Bahia", "06/10/2026", 0)])

# Mesmo diário e data em DUAS seções (como DJ Minas Gerais 04/11/2026 no e-mail real: 25 e 4)
D2 = "07/10/2026"
e4 = email("Public 3. UFs 2. (00.00000000)", "qua, 7 de out de 2026 às 09:40", [
    ("DJ Alagoas", D2, pub_djen(1, D2, "08/10/2026", "Alagoas", "1ª Vara Cível Fictícia", CNJ_A3, "Despacho ficticio: designo audiencia de conciliacao para novembro.", "900000020")
                     + pub_djen(2, D2, "08/10/2026", "Alagoas", "1ª Vara Cível Fictícia", CNJ_A3, "Despacho ficticio: defiro a juntada dos documentos apresentados.", "900000021"), 2),
    ("DJ Alagoas", D2, pub_djen(1, D2, "08/10/2026", "Alagoas", "2ª Vara Cível Fictícia", CNJ_A2, "Despacho ficticio: manifestem-se sobre o laudo pericial.", "900000022"), 1),
])
# Encaminhamento com dois e-mails da Webjur no mesmo corpo (como o e-mail real de 06/11/2026)
def corpo(html): return html.split("<body>", 1)[1].rsplit("</body>", 1)[0]
e5 = "<html><body>" + linha("Segue publicações (texto fictício do encaminhamento).") + corpo(e4) + corpo(e3) + "</body></html>"

for nome, html in [("email_ficticio_1.html", e1), ("email_ficticio_secoes_repetidas.html", e4), ("encaminhamento_dois_emails.html", e5), ("email_ficticio_2_revisao.html", e2), ("email_ficticio_divergente.html", e3)]:
    open(os.path.join(F, nome), "w", encoding="utf-8").write(html)

# Mesmo e-mail 1 como .eml (multipart, quoted-printable, utf-8), para testar a leitura MIME
msg = MIMEMultipart("alternative")
msg["Subject"] = "=?utf-8?Q?Fwd:_Public_4._UFs_3._(00.00000000)?="
msg["From"] = "Encaminhador <encaminhador@exemplo.invalid>"
msg["Date"] = format_datetime(datetime.datetime(2026, 10, 5, 13, 0, tzinfo=datetime.timezone.utc))
msg.attach(MIMEText("Versão texto omitida.", "plain", "utf-8"))
msg.attach(MIMEText(e1, "html", "utf-8"))
for part in msg.get_payload():
    bruto = part.get_payload(decode=True)
    del part["Content-Transfer-Encoding"]; part["Content-Transfer-Encoding"] = "quoted-printable"
    part.set_payload(quopri.encodestring(bruto).decode("ascii"))
open(os.path.join(F, "email_ficticio_1.eml"), "w", encoding="ascii", newline="\r\n").write(msg.as_string())
print("fixtures geradas em", F)

# Encaminhamento .eml com um e-mail da Webjur ANEXADO (message/rfc822), como os 16 anexos do e-mail real
from email.mime.message import MIMEMessage
from email import message_from_string
fw = MIMEMultipart("mixed")
fw["Subject"] = "Publicações."; fw["From"] = "Controladoria <controladoria@exemplo.invalid>"
fw["Date"] = format_datetime(datetime.datetime(2026, 10, 8, 12, 0, tzinfo=datetime.timezone.utc))
fw.attach(MIMEText("Seguem as publicações (texto fictício).", "plain", "utf-8"))
interno = MIMEMultipart("alternative"); interno["Subject"] = "Public 2. UFs 2. (00.00000000)"
interno["Date"] = format_datetime(datetime.datetime(2026, 10, 5, 18, 10, tzinfo=datetime.timezone.utc))
interno.attach(MIMEText(e2, "html", "utf-8"))
anexo = MIMEMessage(interno); anexo.add_header("Content-Disposition", "attachment", filename="Public 2. UFs 2. (00.00000000).eml")
fw.attach(anexo)
open(os.path.join(F, "encaminhamento_com_anexo.eml"), "w", encoding="utf-8", newline="\r\n").write(fw.as_string())

# ---------------------------------------------------------------- exportação "Planilha" do portal (FICTÍCIA)
# Estrutura da exportação real de 06/11/2026: ";" sem aspas, Windows-1252, CRLF, teor como 12º campo
# (sem nome no cabeçalho), linha final "TOTAL DE PUBLICAÇÕES:;N;". Mesmas publicações do e-mail 1,
# com o teor "achatado" (sem quebras de linha e com o tipo uma vez só), como o portal exporta.
import re as _re
def achatar(cnj, texto, ident, tipo="Intimação"):
    t = (f"{tipo} PROCESSO: {cnj} - PROCEDIMENTO COMUM CIVEL - || ADV: ADVOGADA FICTICIA DE TESTE (OAB 999999/MG), "
         f"AUTOR: Empresa Ficticia Ltda - REU: Outra Empresa Ficticia S.A. - {texto} ||| POLO ATIVO: EMPRESA FICTICIA LTDA "
         f"ADVOGADO: ADVOGADA FICTICIA DE TESTE - OAB: 999999/MG")
    return t + (f" Acesso ao documento: Identificador do documento: {ident}" if ident else "")
CAB_CSV = "CÓDIGO WEBJUR;ESTADO;DATA DISP;DATA PUBLIC;COMENTARIO;TRIBUNAL;PAGINA;NRO. PROCESSO;LOCAL;CIDADE;PUBLICAÇÃO;"
def linha_csv(cod, uf, disp, publ, trib, cnj, local, tipo, teor):
    return f"{cod};{uf};{disp};{publ};;{trib};00001;{cnj};{local};;{tipo};{teor};\t"
DJEN_AL = "DJEN - Diário de Justiça Eletrônico Nacional - TJAL"
def csv(linhas, total=None):
    total = len(linhas) if total is None else total
    return "\r\n".join(["", "WEBJUR - RELATÓRIO DE PUBLICAÇÕES;", CAB_CSV, ""] + linhas + [f"TOTAL DE PUBLICAÇÕES:;{total};", ""])
L_P = [
    linha_csv("8000000001", "AL", D, "06/10/2026", DJEN_AL, CNJ_A1, "1ª Vara Cível Fictícia", "Intimação", achatar(CNJ_A1, "Primeiro despacho ficticio: cite-se.", "900000001")),
    linha_csv("8000000002", "AL", D, "06/10/2026", DJEN_AL, CNJ_A1, "1ª Vara Cível Fictícia", "Intimação", achatar(CNJ_A1, "Segundo despacho ficticio: intime-se o perito.", "900000002")),
    linha_csv("8000000003", "AL", D, "06/10/2026", DJEN_AL, CNJ_A2, "2ª Vara Cível Fictícia", "Intimação", achatar(CNJ_A2, TEXTO_IGUAL, "900000003")),
    # a do TRF1 sem identificador: só o conteúdo liga as duas fontes
    linha_csv("8000000004", "DJ", D, D, "Tribunal Regional Federal da 1ª Região", CNJ_MG, "", "Ata de Distribuição de teste",
              f"PROCESSOS DISTRIBUÍDOS PROCESSO: {CNJ_MG} CLASSE JUDICIAL: APELACAO CIVEL APELANTE: EMPRESA FICTICIA LTDA DATA DISTRIBUICAO: 05/10/2026"),
    # só no portal
    linha_csv("8000000005", "AL", D, "06/10/2026", DJEN_AL, CNJ_A3, "1ª Vara Cível Fictícia", "Despacho", achatar(CNJ_A3, "Despacho ficticio apenas no portal.", "900000030", "Despacho")),
]
open(os.path.join(F, "portal_exportacao_1.csv"), "w", encoding="cp1252", newline="").write(csv(L_P))
# Segunda exportação (período maior): repete os mesmos códigos e traz duas publicações SEM identificador,
# com o mesmo CNJ, data e teor, mas códigos diferentes (devem ficar separadas)
IGUAL = f"Expediente de 05/10/2026 00001 - {CNJ_A3} Autor : Empresa Ficticia Ltda Adv - Advogada Ficticia de Teste. Intimacao ficticia identica."
L_P2 = L_P + [
    linha_csv("8000000006", "AL", D, "06/10/2026", "TJALFCAP", CNJ_A3, "1ª Vara Cível Fictícia", "Expediente", IGUAL),
    linha_csv("8000000007", "AL", D, "06/10/2026", "TJALFCAP", CNJ_A3, "1ª Vara Cível Fictícia", "Expediente", IGUAL),
]
open(os.path.join(F, "portal_exportacao_2.csv"), "w", encoding="cp1252", newline="").write(csv(L_P2))
open(os.path.join(F, "portal_exportacao_incompleta.csv"), "w", encoding="cp1252", newline="").write(csv(L_P[:2], total=3))
