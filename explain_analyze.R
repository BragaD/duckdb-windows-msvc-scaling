# EXPLAIN ANALYZE of one wide LEFT JOIN from the workload (R client).
# Usage: Rscript explain_analyze.R [threads]   (default 8)
suppressWarnings(suppressPackageStartupMessages({library(DBI); library(duckdb)}))
args <- commandArgs(trailingOnly = TRUE)
threads <- if (length(args) >= 1) as.integer(args[1]) else 8L

con <- suppressMessages(dbConnect(duckdb(), dbdir = ":memory:"))
invisible(dbExecute(con, sprintf("SET threads TO %d", threads)))

payload <- paste(sprintf("'p%d_' || CAST(hash(i * %d) %% 100000 AS VARCHAR) AS p%d",
                         1:8, (1:8) * 7L + 3L, 1:8), collapse = ", ")
invisible(dbExecute(con, sprintf(
  "CREATE TABLE t AS SELECT i AS id, 'k' || CAST(hash(i) %% 2000000 AS VARCHAR) AS key, %s FROM range(8000000) g(i)", payload)))
invisible(dbExecute(con, "CREATE TABLE d AS SELECT 'k' || CAST(i AS VARCHAR) AS key, 'v' || CAST(i AS VARCHAR) AS value FROM range(2000000) g(i)"))
for (k in 1:6) invisible(dbExecute(con, sprintf(
  "CREATE OR REPLACE TABLE t AS SELECT t.*, d.value AS w%d FROM t LEFT JOIN d ON t.key = d.key", k)))

cat(sprintf("# platform=%s  duckdb=%s  threads=%d\n",
    dbGetQuery(con, "PRAGMA platform")[[1]], as.character(packageVersion("duckdb")), threads))
plan <- dbGetQuery(con,
  "EXPLAIN ANALYZE CREATE OR REPLACE TABLE t2 AS SELECT t.*, d.value AS w FROM t LEFT JOIN d ON t.key = d.key")
cat(plan[[ncol(plan)]], sep = "\n")
dbDisconnect(con, shutdown = TRUE)
