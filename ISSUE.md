<!-- Filled per the DuckDB bug-report template. Suggested title:
     Windows: MSVC build (windows_amd64) scales much worse with threads than the MinGW build (windows_amd64_mingw) on wide-join workloads -->

### What happens?

On Windows, the **MSVC build** of DuckDB (`PRAGMA platform` → `windows_amd64`,
used by the official **CLI** and the **PyPI Python wheel**) scales **much worse
with threads** than the **MinGW build** (`windows_amd64_mingw`, the **R/CRAN**
package), on workloads dominated by wide `LEFT JOIN`s / wide-table
re-materialization.

Same DuckDB **1.5.4**, same SQL, same data, same session settings — the only
difference is the **build toolchain**:

| client | `PRAGMA platform` | threads = 8 |
|---|---|---:|
| R (Rtools / MinGW) | `windows_amd64_mingw` | **9.3 s** |
| Python (PyPI wheel) | `windows_amd64` (MSVC) | 20.8 s |
| duckdb CLI | `windows_amd64` (MSVC) | 23.7 s |

Single-threaded the three are within ~10% of each other. As threads increase,
the MinGW build keeps scaling while the MSVC builds **peak around 4 threads and
then regress**:

| threads | R — `windows_amd64_mingw` | Python — `windows_amd64` (MSVC) | CLI — `windows_amd64` (MSVC) |
|--------:|--------------------------:|--------------------------------:|-----------------------------:|
|   **1** |                    47.9 s |                          54.0 s |                       52.2 s |
|   **4** |                    13.8 s |                          18.9 s |                       19.6 s |
|   **8** |                 **9.3 s** |                          20.8 s |                       23.7 s |
|  **16** |                 **9.2 s** |                          28.3 s |                       27.3 s |

(wall-clock seconds, lower is better; shared machine, so treat the absolute
numbers as indicative — the **scaling shape** is the point.)

`EXPLAIN ANALYZE` of a single wide join (threads = 8) isolates it: R
`windows_amd64_mingw` **1.27 s** vs Python / CLI `windows_amd64` (MSVC)
**4.67 / 4.62 s** (~3.7×).

**What we ruled out:**

- **The Python binding** — the native **CLI** (no language binding) is just as
  slow as the wheel; both are `windows_amd64` (MSVC), only R is MinGW.
- **Engine / SQL / settings** — identical DuckDB version, SQL, and session
  settings (`threads`, `memory_limit`, `preserve_insertion_order`,
  `temp_directory`, `default_order`, `checkpoint_threshold`, …). Single-threaded
  all three are at parity.
- **The CRT allocator** — overriding the process `malloc` with **mimalloc** (on
  the MSVC/Python process via `minject`, with `mimalloc: malloc is redirected`
  confirmed) does **not** help (≤ 5% at 8 threads, nothing at 24). `SET
  allocator_background_threads = true` does not help either.

So the difference appears to be in the **MSVC build's parallel execution**
(hash-join build/probe and wide materialization) — possibly DuckDB's internal
memory management or MSVC code generation / threading — rather than the CRT
allocator.

### To Reproduce

The workload builds a wide table (`id`, `key`, 8 string columns; 8M rows) plus a
2M-row dictionary, then carries the whole *widening* table through **6
`LEFT JOIN`s**, re-materializing each time. Each snippet below generates its own
data — no external files. Same machine, same DuckDB 1.5.4.

**R — `windows_amd64_mingw` (fast):**

``` r
suppressWarnings(suppressPackageStartupMessages({
  library(DBI)
  library(duckdb)
}))
con <- suppressMessages(dbConnect(duckdb(), dbdir = ":memory:"))

dbGetQuery(con, "SELECT platform FROM pragma_platform()")$platform
#> [1] "windows_amd64_mingw"
as.character(packageVersion("duckdb"))
#> [1] "1.5.4.3"

dbExecute(con, "SET threads TO 8")

payload <- paste(sprintf("'p%d_' || CAST(hash(i * %d) %% 100000 AS VARCHAR) AS p%d",
                         1:8, (1:8) * 7L + 3L, 1:8), collapse = ", ")
dbExecute(con, sprintf(
  "CREATE TABLE t AS SELECT i AS id, 'k' || CAST(hash(i) %% 2000000 AS VARCHAR) AS key, %s
   FROM range(8000000) g(i)", payload))
dbExecute(con,
  "CREATE TABLE d AS SELECT 'k' || CAST(i AS VARCHAR) AS key, 'v' || CAST(i AS VARCHAR) AS value
   FROM range(2000000) g(i)")

system.time({
  for (k in 1:6) dbExecute(con, sprintf(
    "CREATE OR REPLACE TABLE t AS SELECT t.*, d.value AS w%d FROM t LEFT JOIN d ON t.key = d.key", k))
  invisible(dbGetQuery(con, "SELECT COUNT(*) FROM t"))
})["elapsed"]
#> elapsed
#>    6.86
```

**Python — `windows_amd64` / MSVC (~2.5× slower on the same machine):**

``` python
import duckdb, time
con = duckdb.connect(":memory:")
print("platform:", con.execute("PRAGMA platform").fetchone()[0], "| duckdb", duckdb.__version__)
#> platform: windows_amd64 | duckdb 1.5.4
con.execute("SET threads TO 8")

payload = ", ".join(f"'p{j}_' || CAST(hash(i * {j*7+3}) % 100000 AS VARCHAR) AS p{j}" for j in range(1, 9))
con.execute(f"CREATE TABLE t AS SELECT i AS id, 'k' || CAST(hash(i) % 2000000 AS VARCHAR) AS key, {payload} FROM range(8000000) g(i)")
con.execute("CREATE TABLE d AS SELECT 'k' || CAST(i AS VARCHAR) AS key, 'v' || CAST(i AS VARCHAR) AS value FROM range(2000000) g(i)")

t0 = time.perf_counter()
for k in range(1, 7):
    con.execute(f"CREATE OR REPLACE TABLE t AS SELECT t.*, d.value AS w{k} FROM t LEFT JOIN d ON t.key = d.key")
con.execute("SELECT COUNT(*) FROM t").fetchone()
print(f"elapsed: {time.perf_counter()-t0:.2f}s")
#> elapsed: 17.28s
```

The **duckdb CLI** (also `windows_amd64` / MSVC) matches Python. Increasing
`SET threads TO 16` makes the MSVC builds *slower* still, while the MinGW build
stays flat and low.

Full harness — R data generator, per-client benchmarks, `EXPLAIN ANALYZE`
scripts, and a thread-sweep driver — is in the reproduction repo:
**https://github.com/BragaD/duckdb-windows-msvc-scaling**

### OS:

Windows Server 2022 (x86_64)

### DuckDB Version:

1.5.4 (R package `duckdb` 1.5.4.3 → engine 1.5.4; Python wheel 1.5.4; CLI 1.5.4)

### DuckDB Client:

Python (PyPI wheel) and the duckdb CLI — both `windows_amd64` (MSVC) — compared against R (CRAN), which is `windows_amd64_mingw`

### Hardware:

24 logical cores, ~500 GB RAM

### Full Name:

Douglas Braga

### Affiliation:

Ipea (Instituto de Pesquisa Econômica Aplicada)

### Did you include all relevant configuration (e.g., CPU architecture, Linux distribution) to reproduce the issue?

- [X] Yes, I have

### Did you include all code required to reproduce the issue?

- [X] Yes, I have

### Did you include all relevant data sets for reproducing the issue?

Not applicable - the reproduction does not require a data set
