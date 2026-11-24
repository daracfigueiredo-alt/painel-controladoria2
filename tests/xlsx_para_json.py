"""Converte o .xlsx do ADVBOX no mesmo formato que o painel enviará à RPC
(lista de objetos {cabeçalho: texto}). Também calcula o SHA-256 do arquivo."""
import sys, json, hashlib, openpyxl
f = sys.argv[1]
ws = openpyxl.load_workbook(f, read_only=True).worksheets[0]
rows = list(ws.iter_rows(values_only=True))
h = [str(c) for c in rows[0]]
out = [{h[i]: ('' if v is None else str(v)) for i, v in enumerate(r)} for r in rows[1:]]
print(json.dumps({"hash": hashlib.sha256(open(f,'rb').read()).hexdigest(), "linhas": out}, ensure_ascii=False))
