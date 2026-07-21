#!/usr/bin/env bash
# Reproduce the DuckDB Windows MSVC-vs-MinGW parallel-scaling gap across the
# R (MinGW build), Python (MSVC wheel) and CLI (MSVC) clients on one machine.
#
# Prereqs: `Rscript` (with the `duckdb` + `DBI` packages), `python` (with the
# `duckdb` package), and the `duckdb` CLI. Override the executables via env
# vars if they are not on PATH: RSCRIPT, PYTHON, DUCKDB_CLI. THREADS overrides
# the sweep (default: 1 4 8 16).
set -e
cd "$(dirname "$0")"
RSCRIPT="${RSCRIPT:-Rscript}"
PYTHON="${PYTHON:-python}"
THREADS="${THREADS:-1 4 8 16}"

[ -f t.parquet ] || { echo "generating data (once)..."; "$RSCRIPT" gen_data.R; }

echo "client | version        | platform             | threads | time"
echo "-------+----------------+----------------------+---------+--------"
for th in $THREADS; do
  "$RSCRIPT" bench.R "$th"
  "$PYTHON" bench.py "$th"
  bash bench_cli.sh "$th"
done
