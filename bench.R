# Run workload.sql via the R duckdb client at a given thread count.
# Usage: Rscript bench.R [threads]
suppressMessages({library(DBI); library(duckdb)})
args <- commandArgs(trailingOnly = TRUE)
threads <- if (length(args) >= 1) as.integer(args[1]) else 8L

stmts <- sub(";\\s*$", "", trimws(readLines("workload.sql", warn = FALSE)))
stmts <- stmts[nzchar(stmts)]

con <- dbConnect(duckdb(), dbdir = ":memory:")
plat <- dbGetQuery(con, "PRAGMA platform")[[1]]
ver <- as.character(packageVersion("duckdb"))
dbExecute(con, sprintf("SET threads TO %d", threads))

t0 <- Sys.time()
for (s in stmts) {
  if (grepl("^SELECT", s, ignore.case = TRUE)) invisible(dbGetQuery(con, s)) else invisible(dbExecute(con, s))
}
el <- as.numeric(difftime(Sys.time(), t0, units = "secs"))
dbDisconnect(con, shutdown = TRUE)
cat(sprintf("R   | duckdb %-6s | %-20s | threads=%2d | %6.2fs\n", ver, plat, threads, el))
