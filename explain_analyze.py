"""EXPLAIN ANALYZE of one wide LEFT JOIN from the workload (Python client).
Usage: python explain_analyze.py [threads]   (default 8)
Prints PRAGMA platform, duckdb version, and the profiled plan tree."""
import duckdb, sys
sys.stdout.reconfigure(encoding="utf-8")  # the plan tree uses box-drawing chars

threads = int(sys.argv[1]) if len(sys.argv) > 1 else 8
con = duckdb.connect(":memory:")
con.execute(f"SET threads TO {threads}")

payload = ", ".join(f"'p{j}_' || CAST(hash(i * {j*7+3}) % 100000 AS VARCHAR) AS p{j}" for j in range(1, 9))
con.execute(f"CREATE TABLE t AS SELECT i AS id, 'k' || CAST(hash(i) % 2000000 AS VARCHAR) AS key, {payload} FROM range(8000000) g(i)")
con.execute("CREATE TABLE d AS SELECT 'k' || CAST(i AS VARCHAR) AS key, 'v' || CAST(i AS VARCHAR) AS value FROM range(2000000) g(i)")
for k in range(1, 7):  # widen t to match a late join in the workload
    con.execute(f"CREATE OR REPLACE TABLE t AS SELECT t.*, d.value AS w{k} FROM t LEFT JOIN d ON t.key = d.key")

print(f"# platform={con.execute('PRAGMA platform').fetchone()[0]}  duckdb={duckdb.__version__}  threads={threads}")
plan = con.execute(
    "EXPLAIN ANALYZE CREATE OR REPLACE TABLE t2 AS "
    "SELECT t.*, d.value AS w FROM t LEFT JOIN d ON t.key = d.key"
).fetchall()[0][1]
print(plan)
con.close()
