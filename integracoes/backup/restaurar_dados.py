#!/usr/bin/env python3
"""Restauração dos dados da controladoria a partir do arquivo baixado no painel
(Configurações › Backup dos dados, migração 0060). Gera arquivos SQL; não conecta em banco nenhum.

Uso:
  python restaurar_dados.py backup_dados_controladoria_AAAA-MM-DD_HHhMM.json  [pasta_de_saida]

Gera, na pasta de saída (padrão: ao lado do backup):
  1_restaurar_dados.sql     -> apaga os dados de exemplo das migrações e grava todas as tabelas do backup,
                               numa transação só (ou tudo, ou nada); acerta os contadores de id.
  2_remapear_usuarios.sql   -> depois de recriar as contas (mesmos e-mails), troca os IDs antigos das contas
                               pelos novos em todas as colunas do tipo uuid.
  conferencia.txt           -> quantas linhas cada tabela deve ter depois da restauração.

Pré-requisito: banco novo com TODAS as migrações aplicadas (supabase/migrations, em ordem).
Rodar com psql (a senha é digitada pela controladoria):  psql "<string de conexão>" -f 1_restaurar_dados.sql
Passo a passo completo: docs/RESTAURAR.md.
"""
import hashlib, json, os, secrets, sys

def tag_livre(texto):
    while True:
        t = "$bk" + secrets.token_hex(4) + "$"
        if t not in texto:
            return t

def ident(n):
    return '"' + n.replace('"', '""') + '"'

def main():
    if len(sys.argv) < 2:
        print(__doc__); sys.exit(1)
    origem = sys.argv[1]
    saida = sys.argv[2] if len(sys.argv) > 2 else os.path.dirname(os.path.abspath(origem))
    os.makedirs(saida, exist_ok=True)
    bruto = open(origem, "rb").read()
    b = json.loads(bruto.decode("utf-8"))
    if b.get("formato") != "controladoria-backup-1":
        sys.exit("Arquivo não é um backup da controladoria (formato desconhecido).")
    tabelas = b["tabelas"]
    print(f"Backup de {b['gerado_em']} — banco {b.get('banco')} — {len(tabelas)} tabelas — SHA-256 {hashlib.sha256(bruto).hexdigest()}")
    if b.get("migracoes"):
        print(f"Migrações no banco de origem: {len(b['migracoes'])} (última {b['migracoes'][-1]})")

    sql = ["-- Restauração dos dados da controladoria — gerado por integracoes/backup/restaurar_dados.py",
           f"-- Backup de {b['gerado_em']} (banco {b.get('banco')}). Aplicar num banco com todas as migrações.",
           "\\set ON_ERROR_STOP on", "begin;",
           "-- sem gatilhos durante a carga: as tabelas de histórico são imutáveis e a carga é uma cópia fiel",
           "set local session_replication_role = replica;", "set local statement_timeout = 0;"]
    nomes = sorted(tabelas)
    sql.append("truncate " + ", ".join("public." + ident(t) for t in nomes) + " restart identity;")
    conf = []
    for t in nomes:
        info = tabelas[t]; linhas = info["linhas"]
        cols = [c for c in info["colunas"] if not c["gerada"]]
        lista = ", ".join(ident(c["nome"]) for c in cols)
        conf.append(f"{t}\t{len(linhas)}")
        if not linhas:
            continue
        for i in range(0, len(linhas), 2000):   # blocos de 2.000 linhas
            texto = json.dumps(linhas[i:i + 2000], ensure_ascii=False)
            q = tag_livre(texto)
            ov = " overriding system value" if any(c["identidade"] for c in cols) else ""
            # campos json/jsonb vêm direto do arquivo (o null do JSON é preservado; os vazios estão em __sql_nulos)
            def expr(c):
                if c["tipo"] in ("json", "jsonb"):
                    n = c["nome"].replace("'", "''")
                    return f"case when coalesce(e->'__sql_nulos', '[]') ? '{n}' then null else (e->'{n}')::{c['tipo']} end"
                return "p." + ident(c["nome"])
            sel = ", ".join(expr(c) for c in cols)
            sql.append(f"insert into public.{ident(t)} ({lista}){ov}\n  select {sel}\n  from jsonb_array_elements({q}{texto}{q}::jsonb) e"
                       f" cross join lateral jsonb_populate_record(null::public.{ident(t)}, e) p;")
        for c in info["colunas"]:
            if c["sequencia"]:
                sql.append(f"select setval(pg_get_serial_sequence('public.{ident(t)}', '{c['nome']}'), "
                           f"coalesce((select max({ident(c['nome'])}) from public.{ident(t)}), 1), "
                           f"(select count(*) > 0 from public.{ident(t)}));")
    sql.append("-- conferência: aborta se alguma tabela não ficou com a quantidade do backup")
    sql.append("do $c$ declare r record; n bigint; begin")
    sql.append("  for r in select * from (values " + ", ".join(f"('{t}', {len(tabelas[t]['linhas'])})" for t in nomes) + ") v(t, esperado) loop")
    sql.append("    execute format('select count(*) from public.%I', r.t) into n;")
    sql.append("    if n <> r.esperado then raise exception 'Tabela %: % linhas, esperado %', r.t, n, r.esperado; end if;")
    sql.append("  end loop; end $c$;")
    sql.append("commit;")
    sql.append("\\echo 'Restauração concluída: todas as tabelas conferidas.'")
    open(os.path.join(saida, "1_restaurar_dados.sql"), "w", encoding="utf-8").write("\n".join(sql) + "\n")

    # remapeamento das contas: o ID novo de cada conta é procurado pelo e-mail
    us = b.get("usuarios") or []
    mapa = json.dumps([{"id": u["id"], "email": u["email"]} for u in us], ensure_ascii=False)
    q = tag_livre(mapa)
    rem = f"""-- Troca os IDs antigos das contas pelos novos (recrie as contas no Supabase Auth com os MESMOS e-mails antes).
\\set ON_ERROR_STOP on
begin;
set local session_replication_role = replica;
do $r$
declare u record; c record; novo uuid; faltam text := ''; n bigint; total bigint := 0;
begin
  for u in select * from jsonb_to_recordset({q}{mapa}{q}::jsonb) as x(id uuid, email text) loop
    select id into novo from auth.users where lower(email) = lower(u.email);
    if novo is null then faltam := faltam || ' ' || u.email; continue; end if;
    if novo = u.id then continue; end if;
    for c in select table_name, column_name from information_schema.columns
              where table_schema = 'public' and data_type = 'uuid'
                and table_name in (select tablename from pg_tables where schemaname = 'public') loop
      execute format('update public.%I set %I = $1 where %I = $2', c.table_name, c.column_name, c.column_name) using novo, u.id;
      get diagnostics n = row_count; total := total + n;
    end loop;
  end loop;
  if faltam <> '' then raise exception 'Contas ainda não recriadas:%', faltam; end if;
  raise notice 'Remapeamento concluído: % valores trocados.', total;
end $r$;
commit;
"""
    open(os.path.join(saida, "2_remapear_usuarios.sql"), "w", encoding="utf-8").write(rem)
    open(os.path.join(saida, "conferencia.txt"), "w", encoding="utf-8").write(
        f"Backup de {b['gerado_em']}\nContas no backup: {len(us)} ({', '.join(u['email'] for u in us)})\n\nTabela\tLinhas\n" + "\n".join(conf) + "\n")
    print(f"Arquivos gerados em {saida}: 1_restaurar_dados.sql, 2_remapear_usuarios.sql, conferencia.txt")

if __name__ == "__main__":
    main()
