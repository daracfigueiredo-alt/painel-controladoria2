"""Testes do calendário real 2026 (migração 0009): contagens por tribunal, idempotência e
D-4 em datas que dependem dos feriados cadastrados. Banco LOCAL."""
import subprocess, os, sys, datetime
PSQL = ["psql", "-h", "/tmp", "-p", "5433", "-U", "postgres", "-At", "-q", "-v", "ON_ERROR_STOP=1"]
HERE = os.path.dirname(os.path.abspath(__file__)); MIGDIR = os.path.join(HERE, "..", "supabase", "migrations")
MIG = sorted(os.path.join(MIGDIR, f) for f in os.listdir(MIGDIR)); DB = "ctrl_calendario"; res = []
def q(sql): return subprocess.run(PSQL + ["-d", DB], input=sql, capture_output=True, text=True, check=True).stdout.strip()
def check(n, e, o): res.append((n, str(e), str(o), "OK" if str(e) == str(o) else "FALHA"))
subprocess.run(PSQL + ["-d", "postgres", "-c", f"drop database if exists {DB}", "-c", f"create database {DB}"], check=True, capture_output=True)
for f in [os.path.join(HERE, "00_stub_supabase_local.sql")] + MIG:
    subprocess.run(PSQL + ["-d", DB, "-f", f], check=True, capture_output=True)
check("Total de dias cadastrados para os 4 tribunais", "92", q("select count(*) from calendario_dias_nao_uteis where abrangencia<>'nacional'"))
subprocess.run(PSQL + ["-d", DB, "-f", next(m for m in MIG if os.path.basename(m).startswith("0009_"))], check=True, capture_output=True)
check("Carga repetida não duplica (idempotente)", "92", q("select count(*) from calendario_dias_nao_uteis where abrangencia<>'nacional'"))
check("Todo registro tem fundamento", "0", q("select count(*) from calendario_dias_nao_uteis where abrangencia<>'nacional' and coalesce(fundamento,'')=''"))
check("Nenhum feriado nacional repetido no nível do tribunal", "0",
      q("select count(*) from calendario_dias_nao_uteis t join calendario_dias_nao_uteis n on n.data=t.data and n.abrangencia='nacional' where t.abrangencia<>'nacional'"))
# D-4 = PF − 3 dias úteis (regra confirmada), agora com o calendário de cada tribunal
casos = [
 ("TJMG BH: PF 10/12/2026 (7/12 sem expediente, 8/12 Dia da Justiça)", "'2026-12-10','8.13','0024'", "2026-12-03"),
 ("TJMG: PF 03/11/2026 (30/10 Dia do Funcionário Público, 2/11 Finados)", "'2026-11-03','8.13','0702'", "2026-10-27"),
 ("TJPR: PF 10/12/2026 (8/12 NÃO é feriado no TJPR; transferido para 18/12)", "'2026-12-10','8.16','0014'", "2026-12-07"),
 ("TJPR Curitiba 0001: PF 10/09/2026 (8/9 padroeira; 7/9 Independência)", "'2026-09-10','8.16','0001'", "2026-09-03"),
 ("TJPR outro foro: PF 10/09/2026 (só 7/9)", "'2026-09-10','8.16','0014'", "2026-09-04"),
 ("TJSP: PF 30/10/2026 (28/10 Dia do Servidor)", "'2026-10-30','8.26','0100'", "2026-10-26"),
 ("TJGO: PF 30/10/2026 (28/10 Dia do Servidor)", "'2026-10-30','8.09','0051'", "2026-10-26"),
 ("TJGO: ponto facultativo (5/6) conta como dia útil", "'2026-06-09','8.09','0051'", "2026-06-03"),
 ("Tribunal sem calendário cadastrado: só nacionais", "'2026-10-30','8.05','0001'", "2026-10-27"),
]
for nome, args, esp in casos:
    check("D-4 " + nome, esp, q(f"select calcular_d4({args})"))
w = max(len(x[0]) for x in res)
for n, e, o, s in res: print(f"{s:5} | {n:<{w}} | esperado: {e} | obtido: {o}")
print(f"\n{sum(1 for x in res if x[3]=='OK')}/{len(res)} OK — executado em {datetime.datetime.now():%d/%m/%Y %H:%M}")
sys.exit(0 if all(x[3] == "OK" for x in res) else 1)
