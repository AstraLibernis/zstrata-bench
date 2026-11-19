# Cross-check: zstrata, zstrata-bench, zarbor, zscour (2026-11-19)

A read of zarbor and zscour against the measurements here, and of zstrata against both. Nothing
in this note is measured unless it says so: it is a list of what to measure and where each
project appears to be ahead. [DERIVED from reading the code]

## Outcome (later the same day)

The claims below were measured in the projects themselves: see docs/measurements.md,
"Confirmed in the real projects". Five were worth fixing and are fixed (zscour 892a333, zarbor
e134eae); zstrata now exposes a library (03c4dd4: `Pool`, `simd`, `sort`) that zscour uses.
The list of jobs to add further down is still open.

## Applied to zstrata (commit bc02a9f)

- Probes used `@mulAdd` without asking whether the CPU has the instruction. Built for a CPU
  without it, that is a library call per value (V1, V2: 20x to 35x slower [MEASURED]) and the
  map would understate the machine. `host.mulAdd` now fuses only where the instruction exists.
- `Pool.chunkFor(total, min_chunk)` states the piece size `parallelFor` hands out. zarbor
  re-derives that formula privately in three places to index per-piece scratch.

## Where the bench is behind the two projects (jobs to add)

From zarbor:

1. M1 with lopsided bin counts per feature (a few wide, most narrow). M1's uniform 8 x 256 is
   the case where taking rows outermost shows no gain.
2. M1 bins that carry a count as well as the two sums (16, 24 and 32 bytes per bin).
3. Histogram over a subset of rows through a row-index list, 200 to 20,000 rows, including the
   cost of clearing and reducing; and build-the-smaller-child-then-subtract against building
   both.
4. V4: `exp` and the logistic function: scalar `@exp`, polynomial at 8 and 16 wide, with an
   error column.
5. Thread crossovers for small work: rows per node from 256 to 16,000 by number of parts.
6. Stable two-way partition of row ids through a gathered byte column.
7. M3 beyond its one shape: binned inputs, variable-depth nodes, a model larger than the cache,
   and trees where every level asks the same question.
8. D3 on 64-bit records (key in the high half, payload in the low).

From zscour and its CSV reader:

9. D6 on quoted text (quote parity carried across chunks), a count-only variant, fields consumed
   in place instead of a stored position per delimiter, and an exact parallel split.
10. Text to number: digit fields to 64-bit integers and floats (std, a hand-written integer
    path, eight digits at a time).
11. Grouping by short strings at low and high cardinality.
12. Sorting 64-bit floats and producing ranks; quantiles on 64-bit floats.
13. Sums and correlations that skip missing values (branch against select).
14. Assigning values to bins by edges (binary search, branch-free search, compare-and-count).

## Where the two projects appear behind the bench (to check there, with a measurement each)

zarbor:

- Tree inference walks each tree with an `if` chain per node; M3's arithmetic step was 4.3x
  faster on its shape. zarbor's partition code already uses the arithmetic form.
- The logistic gradient uses 8-wide vectors; V3 measured 16 wide at 1.8x over 8 on this CPU.
  Other objectives are plain loops.
- Split scans interleave divisions with the running sums (M2: 1.4x for sums first, 8 at a time).
- Binning at load uses a comparison sort where D3's radix sort fits.

zscour:

- It reads files with the scalar parser and makes four passes over the bytes; D6's mask method
  is 7x to 8x faster per pass.
- Every numeric column is sorted with `std.mem.sort` (D3: radix is far faster on 32-bit keys;
  64-bit floats are item 12 above).
- Rank correlations are plain 64-bit loops per column pair (V2).
- Each numeric cell is parsed from text three times (item 10 would say what that costs).

## Disagreements to settle by measuring

- zarbor's notes call trees-outermost the fast order for inference; M3 measured that order with
  an `if` as the slow one. The shapes differ (large forest against small trees).
- zarbor splits histogram work across threads from 513 rows; M1 gained only 1.5x from threads
  at 10,000 rows. zarbor's threshold was tuned on another system and marked unrefined.
- The CSV reader's notes say threads lose under 2 MiB; D6 gained 11x at 1 MB. The setups differ.
