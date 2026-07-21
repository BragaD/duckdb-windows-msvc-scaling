# DuckDB on Windows: parallel wide-join performance is gated by the process heap, not the build toolchain

> Reproduction for **[duckdb/duckdb#24027](https://github.com/duckdb/duckdb/issues/24027)**.
>
> **Update — root cause found.** This repo was originally filed as "the MSVC
> build scales much worse than the MinGW build". Continuing the investigation
> showed the toolchain is **irrelevant**: the real variable is the **heap of
> the host process**. R only looked fast because `Rscript.exe`/`Rterm.exe`
> opt into the **Windows Segment Heap** in their embedded manifests; the
> duckdb CLI and `python.exe` use the default (legacy) NT heap, which
> collapses under multi-threaded allocation. Opting any of them into the
> Segment Heap via a one-line manifest setting closes the entire gap.

## Summary

On Windows, a multi-threaded workload dominated by wide `LEFT JOIN`s +
re-materialization (`CREATE TABLE AS`) runs **~2.3× slower** in any process
that uses the default **legacy NT heap**, and matches R's speed in any process
that opts into the **Segment Heap** (`<heapType>SegmentHeap</heapType>` in the
application manifest). Same DuckDB 1.5.4, same SQL, same machine, threads = 8,
in-memory data (no disk I/O in the measured window):

| DuckDB binary | host heap: legacy | host heap: SegmentHeap |
|---|---:|---:|
| **official CLI (MSVC)** | 14.8–16.1 s | **7.0–7.2 s** |
| CLI built from source, MinGW (msys2 gcc 14.2) | 17.6–18.6 s | **6.9–7.4 s** |
| CLI built from source, MinGW (Rtools45 gcc 14.2) | 17.0–20.8 s | **7.0–7.8 s** |
| Python wheel (MSVC) in CPython 3.10 | 17.4–17.7 s | **7.2–7.5 s** |
| R-package MinGW DLL loaded via ctypes in CPython | 16.2–18.9 s | **7.1–7.3 s** |
| R package (CRAN) in `Rscript.exe` | — | **7.0–7.4 s** (stock) |

Every build lands on ~7 s under the Segment Heap and ~15–20 s under the legacy
heap — including the **official MSVC CLI**, which gets 2.2× faster with only
its manifest patched, and the **R MinGW DLL**, which becomes just as slow as
everything else when hosted in an unpatched `python.exe`.

## How the root cause was isolated

1. **Toolchain ruled out.** The CLI was rebuilt from unmodified v1.5.4 sources
   with two different MinGW toolchains (msys2 gcc 14.2, Rtools45 gcc 14.2 —
   the R package's own toolchain). Both were exactly as slow as the official
   MSVC CLI, while the R package (same engine sources, near-identical build
   flags) stayed ~2.3× faster.
2. **Operator isolated.** `EXPLAIN ANALYZE` of one wide join at 8 threads:
   `HASH_JOIN` (1.30 s vs 1.51 s) and `TABLE_SCAN` (1.23 s vs 1.27 s) are at
   parity; the entire gap is in **`CREATE_TABLE_AS`** — 28.99 s vs 7.94 s of
   cumulative operator time (the row-group append / re-materialization path).
3. **Hot path sampled.** Attaching gdb during the slow phase shows worker
   threads dominated by `ntdll!RtlAllocateHeap` and
   `ntdll!RtlEnterCriticalSection`, reached from `ucrtbase!_malloc_base` ←
   `duckdb::Allocator::DefaultAllocate` ← `duckdb::Vector::Initialize` —
   classic legacy-NT-heap lock contention. The same workload in the R process
   spends its samples inside engine code doing real work.
4. **The discriminating detail.** The embedded manifests of `Rscript.exe` /
   `Rterm.exe` contain `<heapType>SegmentHeap</heapType>`; `duckdb.exe` and
   `python.exe` do not.
5. **Causal A/B.** Patching **only the manifest** (byte-identical binaries
   otherwise) flips every slow case to R-level speed — see the table above.
   Conversely, the "fast" R MinGW DLL becomes slow inside an unpatched
   CPython host. The heap of the host process is both necessary and
   sufficient to explain the difference.

This also explains the original observation that the legacy builds **regress
past ~4 threads** (heap lock convoy: more threads → more contention on the
process-heap critical section), while Segment-Heap processes keep scaling.

## Reproduce

```sh
Rscript gen_data.R     # writes t.parquet (8M rows, wide) + dict.parquet (2M rows)
bash run_all.sh        # runs R, Python and the CLI at threads = 1 4 8 16
```

Then demonstrate the fix on any affected binary (no rebuild needed):

```sh
python patch_segment_heap.py path/to/duckdb.exe   # writes duckdb-sh.exe
duckdb-sh.exe            # same binary, Segment Heap -> ~2.3x faster at 8 threads
```

- `patch_segment_heap.py` patches the embedded manifest in place
  (size-preserving). For exes **without** an embedded manifest, drop
  `duckdb.exe.manifest` (in this repo) next to the exe instead.
- For Python note that the manifest must go on the **process executable**
  (`python.exe`), not on the extension module: in a venv, `Scripts\python.exe`
  is only a launcher — patch the base interpreter it points to
  (`pyvenv.cfg` → `home`).

`workload.sql` is the minimal workload: build a wide table (`id`, `key`,
8 string columns; 8M rows) plus a 2M-row dictionary, then **6×**
`CREATE OR REPLACE TABLE t AS SELECT t.*, d.value FROM t LEFT JOIN d ON t.key = d.key`,
re-materializing the widening table each time. A self-contained single-file R
version is in `reprex_r.R` (rendered: `reprex_r_reprex.md`);
`explain_analyze.{R,py,sql}` produce the per-operator profiles.

## Environment

- Windows Server 2022 (x86_64); Intel Xeon Gold 6426Y, 24 logical cores
  (virtual machine), 512 GB RAM. Shared machine — absolute numbers are
  indicative; paired A/B runs were interleaved in the same window.
- DuckDB **1.5.4** everywhere (official CLI `windows_amd64`, PyPI wheel
  `windows_amd64`, CRAN R package `windows_amd64_mingw` 1.5.4.3, plus two
  from-source MinGW CLI builds `windows_amd64_mingw`). The same split
  reproduces with 1.5.2.

## Takeaway for DuckDB

The official Windows CLI (and any host process embedding DuckDB) can get the
entire ~2.3× parallel-workload speedup by opting into the Segment Heap — for
the CLI it is a one-line addition to the linked manifest:

```xml
<application xmlns="urn:schemas-microsoft-com:asm.v3">
  <windowsSettings>
    <heapType xmlns="http://schemas.microsoft.com/SMI/2020/WindowsSettings">SegmentHeap</heapType>
  </windowsSettings>
</application>
```

The Python wheel cannot fix this from inside the wheel (the manifest belongs
to `python.exe`), but the effect is worth documenting for Windows users —
python.org CPython does not opt in as of 3.13.

## Notes

- This reduces a real workload: a name-splitting + dictionary-lookup pipeline
  that ran ~3× slower under Python/Snakemake than under the equivalent R
  targets pipeline, on the same machine and data. With the host interpreter
  patched, the gap disappears.
- An earlier version of this README attributed the difference to MSVC codegen;
  that was a confound (the R comparison crossed both toolchain *and* host
  heap). The from-source MinGW builds and the ctypes cross-hosting test above
  disentangle the two.
