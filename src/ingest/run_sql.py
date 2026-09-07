"""Execute .sql files against the DuckDB database, in order.

Orchestration only - it reads files and runs them. No transformation logic lives
here; that is the SQL's job.

Usage:
    python src/ingest/run_sql.py sql/00_ddl                 # every .sql in a dir
    python src/ingest/run_sql.py sql/02_mapping/10_person.sql
    python src/ingest/run_sql.py sql/00_ddl --db data/other.duckdb
"""

import glob
import os
import sys
import time

import duckdb

DEFAULT_DB = os.path.join("data", "fhir_omop.duckdb")


def targets(paths):
    out = []
    for p in paths:
        if os.path.isdir(p):
            out.extend(sorted(glob.glob(os.path.join(p, "*.sql"))))
        else:
            out.append(p)
    return out


def main():
    args = sys.argv[1:]
    db = DEFAULT_DB
    if "--db" in args:
        i = args.index("--db")
        db = args[i + 1]
        args = args[:i] + args[i + 2:]
    if not args:
        sys.exit(__doc__)

    files = targets(args)
    if not files:
        sys.exit(f"No .sql files found in {args}")

    con = duckdb.connect(db)
    for path in files:
        with open(path, encoding="utf-8") as fh:
            sql = fh.read()
        t0 = time.time()
        try:
            con.execute(sql)
        except Exception as e:
            con.close()
            sys.exit(f"\nFAILED  {path}\n{type(e).__name__}: {e}")
        print(f"  ok  {path}  ({time.time()-t0:.1f}s)")
    con.close()
    print(f"\n{len(files)} file(s) executed against {db}")


if __name__ == "__main__":
    main()
