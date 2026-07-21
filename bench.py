"""Run workload.sql via the Python duckdb client at a given thread count.
Usage: python bench.py [threads]"""
import duckdb, sys, time

threads = int(sys.argv[1]) if len(sys.argv) > 1 else 8
stmts = [ln.rstrip(";").strip() for ln in open("workload.sql", encoding="utf-8").read().splitlines() if ln.strip()]

con = duckdb.connect(":memory:")
plat = con.execute("PRAGMA platform").fetchone()[0]
con.execute(f"SET threads TO {threads}")

t = time.perf_counter()
for s in stmts:
    con.execute(s)
el = time.perf_counter() - t
con.close()
print(f"Py  | duckdb {duckdb.__version__:<6} | {plat:<20} | threads={threads:2d} | {el:6.2f}s")
