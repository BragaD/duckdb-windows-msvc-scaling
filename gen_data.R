# Generate the benchmark parquet with R + DuckDB (deterministic, hash-based).
# Writes t.parquet (wide, 8M rows) and dict.parquet (2M rows) to the cwd.
# Any DuckDB client would produce identical files — the same engine writes them.
suppressMessages({library(DBI); library(duckdb)})

N <- 8000000L   # rows in the wide table
M <- 2000000L   # rows in the dictionary (the join build side)

con <- dbConnect(duckdb(), dbdir = ":memory:")
dbExecute(con, "SET threads TO 4")

# 10 deterministic string payload columns -> a genuinely "wide" table.
payload <- paste(
  sprintf("'p%d_' || CAST(hash(i * %d) %% 100000 AS VARCHAR) AS p%d",
          0:9, (0:9) * 7L + 13L, 0:9),
  collapse = ",\n    ")

dbExecute(con, sprintf("
COPY (
  SELECT
    i AS id,
    'k' || CAST(hash(i) %% %d AS VARCHAR) AS key,
    %s
  FROM range(%d) t(i)
) TO 't.parquet' (FORMAT parquet)", M, payload, N))

dbExecute(con, sprintf("
COPY (
  SELECT 'k' || CAST(i AS VARCHAR) AS key, 'v' || CAST(i AS VARCHAR) AS value
  FROM range(%d) t(i)
) TO 'dict.parquet' (FORMAT parquet)", M))

cat(sprintf("t.parquet: %d rows\ndict.parquet: %d rows\n",
    dbGetQuery(con, "SELECT COUNT(*) FROM read_parquet('t.parquet')")[[1]],
    dbGetQuery(con, "SELECT COUNT(*) FROM read_parquet('dict.parquet')")[[1]]))
dbDisconnect(con, shutdown = TRUE)
