"""Gera planilhas FICTÍCIAS para o teste do painel (nenhum dado real)."""
import os, openpyxl
D = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures"); os.makedirs(D, exist_ok=True)
CAB = ['Prioridade','Data','Hora','Término','Hora Término','Prazo fatal','Data Conclusão','Pontuação','Compromisso',
       'Local','Remetente','Destinatário','Partes','Processo (CNJ)','Protocolo','Tipo de ação','Observações']
def salvar(nome, cab, linhas):
    wb = openpyxl.Workbook(); ws = wb.active; ws.title = "Dados"; ws.append(cab)
    for l in linhas: ws.append(l)
    wb.save(os.path.join(D, nome))
def l(data, pf, comp, obs="", pont=None, concl=None):
    return ['NORMAL', data, None, None, None, pf, concl, pont, comp, None, 'TESTE REMETENTE', 'TESTE COLAB A',
            'T001 - Parte Fictícia', '0000001-65.2026.8.13.0024', None, 'TESTE', obs]
# 1) erros por linha: data inválida (linha 3) e destinatário vazio (linha 4); avisos na linha 5
r = [l('05/11/2026', '10/11/2026', 'TESTE FICTÍCIO OK', 'Linha 1 do texto\nLinha 2 do texto. PF: 10/11.', 3),
     l('31/02/2026', '10/11/2026', 'TESTE FICTÍCIO DATA INVÁLIDA'),
     l('05/11/2026', '10/11/2026', 'TESTE FICTÍCIO SEM DESTINATÁRIO'),
     l('12/11/2026', '10/11/2026', 'TESTE FICTÍCIO AGENDA APÓS PF')]
r[2][11] = None
r[3][13] = '123-FORA-DO-PADRAO'
salvar("Advbox-2026-11-05_ficticio_erros.xlsx", CAB, r)
# 2) coluna obrigatória ausente
salvar("ficticio_sem_coluna.xlsx", [c for c in CAB if c != 'Prazo fatal'], [[x for i, x in enumerate(r[0]) if i != 5]])
# 3) linha vazia no meio (deve manter a numeração) e vazias no fim (descartadas)
wb = openpyxl.Workbook(); ws = wb.active; ws.title = "Dados"; ws.append(CAB)
ws.append(l('06/11/2026', '13/11/2026', 'TESTE FICTÍCIO A')); ws.append([None] * 17)
ws.append(l('06/11/2026', '13/11/2026', 'TESTE FICTÍCIO B')); ws.cell(row=10, column=1, value=None)
wb.save(os.path.join(D, "ficticio_linha_vazia.xlsx"))
# 4) não é xlsx
open(os.path.join(D, "nao_e_planilha.xlsx"), "w").write("texto qualquer")
print("fixtures geradas em", D)
