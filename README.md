# DuckDB on Windows: the MSVC build scales much worse than the MinGW build (multi-threaded, wide joins)

> Reproduction for **[duckdb/duckdb#24027](https://github.com/duckdb/duckdb/issues/24027)**.

## Summary

On Windows, the **MSVC build** of DuckDB (`platform = windows_amd64`, used by the
official **CLI** and the **PyPI Python wheel**) shows **substantially worse
multi-threaded scaling** than the **MinGW build** (`platform =
windows_amd64_mingw`, used by the **R/CRAN** package) on workloads dominated by
wide `LEFT JOIN`s and wide table re-materialization.

Same DuckDB version, same SQL, same data, same settings — only the **build
toolchain** differs:

| client | `PRAGMA platform` | duckdb | threads = 8 |
|---|---|---|---:|
| R (`DBI`+`duckdb`, Rtools/MinGW) | `windows_amd64_mingw` | 1.5.4 | **9.3 s** |
| Python (PyPI wheel, MSVC) | `windows_amd64` | 1.5.4 | 20.8 s |
| duckdb CLI (MSVC) | `windows_amd64` | 1.5.4 | 23.7 s |

All three run **the same DuckDB 1.5.4**. The MinGW build is **~2.2× faster** at
8 threads, and the gap **widens with thread count** — at 16 threads it is ~3×
(the MinGW build keeps scaling with cores; the MSVC builds *regress* past ~4
threads). **Single-threaded, all three are within ~10%** of each other — so it
is not the engine, the SQL, the settings, or the Python/R binding; it tracks
exactly with the **compiler toolchain of the build**.

## Environment

- Windows Server 2022; Intel Xeon Gold 6426Y, 24 logical cores (virtual machine), 512 GB RAM.
- **DuckDB 1.5.4 in all three clients** (R package `duckdb` 1.5.4.3 → engine
  1.5.4; Python wheel 1.5.4; CLI 1.5.4). Same version everywhere — the only
  difference is the **build toolchain** (`windows_amd64` = MSVC vs.
  `windows_amd64_mingw`). (We also saw the identical split with 1.5.2, so it is
  not version-specific.)

## Reproduction

```sh
Rscript gen_data.R     # writes t.parquet (8M rows, wide) + dict.parquet (2M rows)
bash run_all.sh        # runs R, Python and the CLI at threads = 1 4 8 16
```

Prereqs: `Rscript` (with `duckdb` + `DBI`), `python` (with `duckdb`), and the
`duckdb` CLI. If they are not on `PATH`, override with env vars: `RSCRIPT`,
`PYTHON`, `DUCKDB_CLI` (and `THREADS` to change the sweep).

`workload.sql` is a minimal wide-join workload: build a wide table
(`id`, `key`, 10 string columns), then **6×**
`CREATE OR REPLACE TABLE t AS SELECT t.*, d.value FROM t LEFT JOIN d ON t.key = d.key`
— i.e. carry the whole (widening) table through a `LEFT JOIN` against a 2M-row
dictionary, re-materialising each time — then `COUNT(*)`.

A self-contained, single-file R version (generates its own smaller data inline)
is in **`reprex_r.R`**; its rendered output **`reprex_r_reprex.md`** is a
copy-paste-ready snippet.

## Results (this machine)

<!-- RESULTS -->
DuckDB **1.5.4** in all three; `workload.sql`; wall-clock seconds (lower is
better). Measured on a shared machine, so treat the absolute numbers as
indicative — the **scaling shape** is the point.

| threads | R — `windows_amd64_mingw` | Python — `windows_amd64` (MSVC) | CLI — `windows_amd64` (MSVC) |
|--------:|--------------------------:|--------------------------------:|-----------------------------:|
|   **1** |                    47.9 s |                          54.0 s |                       52.2 s |
|   **4** |                    13.8 s |                          18.9 s |                       19.6 s |
|   **8** |                 **9.3 s** |                          20.8 s |                       23.7 s |
|  **16** |                 **9.2 s** |                          28.3 s |                       27.3 s |

speedup from 1→16 threads: **R (MinGW) ≈ 5.2×**, while **Python/CLI (MSVC)
peak around 4 threads (~2.8×) and then get *slower*** (Python 18.9 s → 28.3 s
from 4 → 16 threads).
<!-- /RESULTS -->

The shape: the **MinGW** build turns more threads into a real speedup; the
**MSVC** builds barely improve past ~4 threads and then get *slower*.
Single-threaded (row 1) the three builds are within ~10%.

## What we ruled out

- **The Python binding** — the native **CLI** (no language binding) is just as
  slow as the Python wheel. Both are `windows_amd64` (MSVC); only R is MinGW.
- **Engine / SQL / settings** — identical DuckDB version, identical SQL,
  identical session settings (`threads`, `memory_limit`,
  `preserve_insertion_order`, `temp_directory`, `default_order`,
  `checkpoint_threshold`, …, dumped from fresh connections). Single-threaded,
  R ≈ Python ≈ CLI.
- **The CRT allocator** — overriding the process `malloc` with **mimalloc** (on
  the Python/MSVC process via `minject`, with `mimalloc: malloc is redirected`
  confirmed) does **not** help (≤ 5% at 8 threads, nothing at 24). `SET
  allocator_background_threads = true` does not help either.

So the difference appears to be in the **MSVC build's parallel execution**
(hash-join build/probe and wide materialisation) — plausibly DuckDB's internal
memory management or MSVC code generation / threading — rather than the CRT
allocator.

## Notes

- This reduces a real workload: a name-splitting + dictionary-lookup pipeline
  that runs ~3× slower under the MSVC Python wheel than under the equivalent
  MinGW R package, on the same machine and data.
- Likely Windows/MSVC-specific (on Linux, where DuckDB bundles jemalloc, we do
  not expect this). Filed because the **official Windows CLI and the PyPI
  wheel** are both affected, while the R build is not.
