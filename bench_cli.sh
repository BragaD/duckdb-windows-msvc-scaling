#!/usr/bin/env bash
# Run workload.sql via the duckdb CLI at a given thread count.
# Usage: bench_cli.sh [threads]   (needs `duckdb` on PATH, or set $DUCKDB_CLI)
th="${1:-8}"
CLI="${DUCKDB_CLI:-duckdb}"
cd "$(dirname "$0")"
plat=$(echo "SELECT platform FROM pragma_platform();" | "$CLI" -noheader -list :memory: 2>/dev/null | tr -d '[:space:]')
ver=$("$CLI" --version 2>/dev/null | awk '{print $1}')
s=$(date +%s.%N)
{ echo "SET threads TO $th;"; cat workload.sql; } | "$CLI" :memory: >/dev/null
e=$(date +%s.%N)
awk "BEGIN{printf \"CLI | duckdb %-6s | %-20s | threads=%2d | %6.2fs\n\", \"$ver\", \"$plat\", $th, $e-$s}"
