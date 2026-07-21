<!-- Filled per the DuckDB bug-report template. Title:
     Windows: multithreaded wide-join workloads are ~2.3x slower under the default
     process heap — a SegmentHeap manifest opt-in fixes the CLI and Python
     (R is unaffected only because Rscript.exe already opts in) -->

### What happens?

> **Update (2026-07-21) — root cause identified.** This issue was originally
> filed as "the MSVC build (`windows_amd64`) scales much worse than the MinGW
> build (`windows_amd64_mingw`)". Follow-up investigation (details in the
> comments) showed the **build toolchain is irrelevant**: the real variable is
> the **heap of the host process**. The body below reflects the corrected
> diagnosis; the original text is preserved in the edit history.

On Windows, DuckDB workloads dominated by wide `LEFT JOIN`s + wide-table
re-materialization (`CREATE TABLE AS`) run **~2.3× slower** in any process
that uses the default **legacy NT heap**, and the slowdown **grows with
thread count** (the legacy heap's lock convoy: such builds peak around 4
threads and then regress). Processes that opt into the **Windows Segment
Heap** (`<heapType>SegmentHeap</heapType>` in the application manifest) keep
scaling.

The R client appeared faster than the CLI and the Python wheel only because
**`Rscript.exe`/`Rterm.exe` ship that manifest entry** — `duckdb.exe` (CLI)
and `python.exe` do not. Same DuckDB 1.5.4, same SQL, same machine, threads =
8, in-memory data:

| DuckDB binary | host heap: legacy | host heap: SegmentHeap |
|---|---:|---:|
| **official CLI (MSVC)** | 14.8–16.1 s | **7.0–7.2 s** |
| CLI built from source, MinGW (msys2 gcc 14.2) | 17.6–18.6 s | **6.9–7.4 s** |
| CLI built from source, MinGW (Rtools45 gcc 14.2) | 17.0–20.8 s | **7.0–7.8 s** |
| Python wheel (MSVC) in CPython 3.10 | 17.4–17.7 s | **7.2–7.5 s** |
| R-package MinGW DLL loaded via ctypes in CPython | 16.2–18.9 s | **7.1–7.3 s** |
| R package (CRAN) in `Rscript.exe` | — | **7.0–7.4 s** (stock) |

The "SegmentHeap" columns differ from the "legacy" ones **only by the
manifest** — byte-identical binaries otherwise. Note the cross checks: the
official MSVC CLI becomes as fast as R with nothing but a manifest patch, and
the R package's own MinGW DLL becomes as *slow* as everything else when
loaded (via ctypes) into an unpatched `python.exe`.

Where the time goes (isolated in the comments): `EXPLAIN ANALYZE` shows
`HASH_JOIN` and `TABLE_SCAN` at parity between fast and slow runs; the whole
gap is in **`CREATE_TABLE_AS`** (28.99 s vs 7.94 s cumulative operator time
at 8 threads). Stack sampling during the slow phase shows worker threads in
`ntdll!RtlAllocateHeap` / `ntdll!RtlEnterCriticalSection` via
`ucrtbase!_malloc_base` ← `duckdb::Allocator::DefaultAllocate` ←
`duckdb::Vector::Initialize` — i.e. legacy-process-heap lock contention on
the row-group append path.

**Suggested fix:** add the Segment Heap opt-in to the Windows CLI's manifest
(one line at link time):

```xml
<application xmlns="urn:schemas-microsoft-com:asm.v3">
  <windowsSettings>
    <heapType xmlns="http://schemas.microsoft.com/SMI/2020/WindowsSettings">SegmentHeap</heapType>
  </windowsSettings>
</application>
```

The Python wheel cannot do this from inside the wheel (the manifest belongs
to `python.exe`, and python.org CPython does not opt in as of 3.13), but the
effect seems worth documenting for Windows users embedding DuckDB.

### To Reproduce

The workload builds a wide table (`id`, `key`, 8 string columns; 8M rows)
plus a 2M-row dictionary, then carries the whole *widening* table through
**6 `LEFT JOIN`s**, re-materializing each time (`SET threads TO 8;` first):

```sql
CREATE TABLE t AS SELECT i AS id, 'k' || CAST(hash(i) % 2000000 AS VARCHAR) AS key,
  'p1_' || CAST(hash(i * 10) % 100000 AS VARCHAR) AS p1,
  'p2_' || CAST(hash(i * 17) % 100000 AS VARCHAR) AS p2,
  'p3_' || CAST(hash(i * 24) % 100000 AS VARCHAR) AS p3,
  'p4_' || CAST(hash(i * 31) % 100000 AS VARCHAR) AS p4,
  'p5_' || CAST(hash(i * 38) % 100000 AS VARCHAR) AS p5,
  'p6_' || CAST(hash(i * 45) % 100000 AS VARCHAR) AS p6,
  'p7_' || CAST(hash(i * 52) % 100000 AS VARCHAR) AS p7,
  'p8_' || CAST(hash(i * 59) % 100000 AS VARCHAR) AS p8
FROM range(8000000) g(i);
CREATE TABLE d AS SELECT 'k' || CAST(i AS VARCHAR) AS key, 'v' || CAST(i AS VARCHAR) AS value FROM range(2000000) g(i);
.timer on
CREATE OR REPLACE TABLE t AS SELECT t.*, d.value AS w1 FROM t LEFT JOIN d ON t.key = d.key;
-- ... repeat 5 more times (w2..w6); sum the times
```

1. Run it in the official Windows CLI → ~15–16 s for the six joins.
2. Opt the same exe into the Segment Heap — either with
   [`patch_segment_heap.py`](https://github.com/BragaD/duckdb-windows-msvc-scaling/blob/main/patch_segment_heap.py)
   (in-place manifest patch, writes `duckdb-sh.exe`) or by re-embedding the
   manifest with `mt.exe` — and run the identical SQL → **~7 s**.
3. For Python, the manifest must go on the base `python.exe` (in a venv,
   `Scripts\python.exe` is a launcher; patch the interpreter that
   `pyvenv.cfg` → `home` points to). Same 17 s → 7 s effect.

Full harness — data generator, per-client benchmarks, `EXPLAIN ANALYZE`
scripts, thread-sweep driver, and the manifest patch tooling — is in the
reproduction repo: **https://github.com/BragaD/duckdb-windows-msvc-scaling**

### OS:

Windows Server 2022 (x86_64)

### DuckDB Version:

1.5.4 (official CLI; PyPI wheel; CRAN R package 1.5.4.3; two from-source MinGW CLI builds. Same behavior with 1.5.2)

### DuckDB Client:

CLI and Python — any host process on the default legacy heap. R (CRAN) is unaffected only because `Rscript.exe` opts into the Segment Heap in its manifest

### Hardware:

Intel Xeon Gold 6426Y, 24 logical cores (virtual machine), 512 GB RAM

### Full Name:

Douglas Braga

### Affiliation:

Institute for Applied Economic Research (Ipea)

### Did you include all relevant configuration (e.g., CPU architecture, Linux distribution) to reproduce the issue?

- [X] Yes, I have

### Did you include all code required to reproduce the issue?

- [X] Yes, I have

### Did you include all relevant data sets for reproducing the issue?

Not applicable - the reproduction does not require a data set
