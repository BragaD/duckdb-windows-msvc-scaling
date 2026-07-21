``` r
# Self-contained DuckDB reprex — the FAST (R / MinGW) side of the comparison.
# On the SAME machine, the Python wheel and the duckdb CLI (both MSVC) run the
# identical workload ~2-3x slower (see bench.py / bench_cli.sh in the repo).
# Render a GitHub-ready snippet with:  reprex::reprex(input = "reprex_r.R")
suppressWarnings(suppressPackageStartupMessages({
  library(DBI)
  library(duckdb)
}))

con <- suppressMessages(dbConnect(duckdb(), dbdir = ":memory:"))

# Which build is this? R/CRAN on Windows is MinGW; the CLI + PyPI wheel are MSVC.
dbGetQuery(con, "SELECT platform FROM pragma_platform()")$platform
#> [1] "windows_amd64_mingw"
as.character(packageVersion("duckdb"))
#> [1] "1.5.4.3"

dbExecute(con, "SET threads TO 8")
#> [1] 0

# A wide table (id, key, 8 string payload columns), 8M rows, + a 2M-row dict.
payload <- paste(sprintf("'p%d_' || CAST(hash(i * %d) %% 100000 AS VARCHAR) AS p%d",
                         1:8, (1:8) * 7L + 3L, 1:8), collapse = ", ")
dbExecute(con, sprintf(
  "CREATE TABLE t AS SELECT i AS id, 'k' || CAST(hash(i) %% 2000000 AS VARCHAR) AS key, %s
   FROM range(8000000) g(i)", payload))
#> [1] 8e+06
dbExecute(con,
  "CREATE TABLE d AS SELECT 'k' || CAST(i AS VARCHAR) AS key, 'v' || CAST(i AS VARCHAR) AS value
   FROM range(2000000) g(i)")
#> [1] 2e+06

# Workload: carry the whole (widening) table through 6 LEFT JOINs, re-materialising each time.
system.time({
  for (k in 1:6) {
    dbExecute(con, sprintf(
      "CREATE OR REPLACE TABLE t AS SELECT t.*, d.value AS w%d FROM t LEFT JOIN d ON t.key = d.key", k))
  }
  invisible(dbGetQuery(con, "SELECT COUNT(*) FROM t"))
})["elapsed"]
#> elapsed 
#>    6.86

dbDisconnect(con, shutdown = TRUE)
```
