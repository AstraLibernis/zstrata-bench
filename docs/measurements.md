# Measurements and what they mean

Every number here comes from the files under `results/` and is tagged:
[MEASURED] read from a run, [DERIVED] reasoned from measured numbers.

Machine `znver5-16t-windows`: Ryzen 7 9800X3D (8 cores, 16 threads, AVX-512), Windows 11,
Zig 0.17.1, ReleaseFast, native CPU target.

The tables below were written from one full run. Results are re-measured whenever code changes,
so the files under `results/` and the output of `look` can differ from these tables by about
the spread. `look` and `map/` are the live answers; this page explains them.

How to read a row: the time is the median of the timed runs for one call of the variant; the rate
is items per second; spread is (third quartile - first quartile) / median.

## D1: add up a column (2026-11-19)

32-bit floats summed into a 64-bit total. All ten variants agree with the reference at 15 edge
sizes on 1, 3 and 16 threads, and the reference agrees with NumPy on 1,000 and 1,000,000 values
(`verify/d1_sum.py`).

| Variant | 10,000 values (40 KB) | 1,000,000 values (4 MB) | 100,000,000 values (400 MB) |
|---|---|---|---|
| reference: one at a time | 2.32 billion/s | 2.29 billion/s | 2.30 billion/s |
| reorder: compiler may reorder | 4.08 | 4.07 | 4.05 |
| lanes4 | 9.40 | 9.20 | 8.66 |
| lanes8 | 18.1 | 17.7 | 15.8 |
| lanes16 | 33.1 | 32.2 | 16.1 |
| lanes16x4: four running sums | 35.8 | 34.1 | 16.1 |
| lanes16x8 | 35.8 | 34.3 | 16.6 |
| threads8 | 35.3 | 135 | 17.5 |
| threads14 | 35.3 | 219 | 17.6 |
| threads16 | 35.3 | 226 | 17.6 |

[MEASURED, `run D1`, billions of values per second; spread at most 3.1% except the threaded rows at
1,000,000 values, 6 to 9%.]

What to do:

- **Always use 16-wide vectors.** 14x over the plain loop when the data is in cache, 7x when it
  is not. Letting the compiler reorder the plain loop only gets 1.8x. [MEASURED]
- **Extra running sums are not worth their code here.** Four chains add 6 to 8% in cache and
  nothing beyond it; eight add nothing over four. [MEASURED]
- **Threads pay only in the middle.** At 4 MB, 16 threads are 6.6x faster than one. At 40 KB the
  column is one block and the threaded variants run on one thread. At 400 MB every variant from
  lanes8 up reads at 63 to 70 GB/s and threads add 9%: the memory, not the processor, is the
  limit. [MEASURED; "memory is the limit" is DERIVED from the rate being flat across variants]
- **Between 8 and 16 threads** the 4 MB case gains 1.7x (135 to 226 billion/s); 14 and 16 threads
  are within each other's spread. [MEASURED]

One pair was also timed from outside the program: `hyperfine` on `one D1 reference 1e8` and
`one D1 lanes16 1e8` gives 103.1 ms and 65.6 ms whole-process, a difference of 37.5 ms; the
in-process medians differ by 37.3 ms. [MEASURED]

Not yet answered by D1: the sizes where threads start and stop paying (somewhere between 40 KB and
4 MB, and between 4 MB and 400 MB). That needs more sizes, and belongs with the L2 and L3 sizes
from zstrata.

## D2: filter rows and collect the ones that pass (2026-11-19)

Two jobs: D2 keeps about half the rows, D2s about 1 in 100. Rates in billions of rows per second.
All variants collect exactly the same rows as the reference (full-output test), and the answers
agree with NumPy.

| Variant | D2: half pass, 4 MB | D2: half pass, 400 MB | D2s: 1 in 100, 4 MB | D2s: 1 in 100, 400 MB |
|---|---|---|---|---|
| branch: test, copy if it passes | 0.32 | 0.31 | 5.8 | 4.4 |
| branchfree: always copy, advance on a pass | 4.6 | 4.4 | 4.8 | 4.8 |
| mask16: compare 16, copy the set bits | 1.8 | 1.7 | 38 | 9.3 |
| threads16 (mask16 per block) | 21 | 8.9 | 224 | 17 |

[MEASURED, `run D2`, `run D2s`; spread under 3% except the threaded 4 MB rows, up to 64%.]

What to do:

- **When the outcome is a coin flip, never branch.** The plain `if` runs at 0.32 billion rows/s
  beyond 40 KB; the branch-free copy is 14x faster with one changed line. [MEASURED]
- **When almost nothing passes, compare 16 at a time.** 6.5x over the branch at 4 MB, 2x at
  400 MB. The same variant is the slowest safe choice when half pass (1.8), because it then walks
  eight set bits per 16 values. [MEASURED]
- **So the rule depends on how many rows pass:** branch-free near half, mask when few. The
  crossover between them is not measured yet (it needs more pass rates than two).
- At 40 KB the half-pass branch looks fast (6.0 billion/s). That is the processor learning the
  repeating 10,000-value input across timed runs, not a real result. [DERIVED: it disappears at
  the larger sizes, where the pattern is too long to learn]
- **Threads:** 5x at 4 MB for half-pass, 2x at 400 MB, where memory is again the limit. The
  threaded variants leave the output as per-block runs; joining them into one array would cost
  another copy.

## D3: sort 32-bit keys (2026-11-19)

Millions of keys per second. Every variant leaves the column fully sorted (full-output test);
answers agree with NumPy.

| Variant | 10,000 | 1,000,000 | 10,000,000 |
|---|---|---|---|
| std.mem.sort (stable) | 27 | 16 | 13 |
| std.sort.pdq | 62 | 34 | 33 |
| radix, 8 bits per pass | 439 | 433 | 406 |
| radix, 11 bits per pass | 508 | 525 | 381 |
| 256 buckets, then radix on 16 threads | 706 | 1,196 | 1,201 |

[MEASURED, `run D3`; spread under 6% except pdq and the threaded rows at 10,000 keys, 17 to 24%.]

- **Plain integer keys: radix sort.** 12x to 16x over pdq and 27x to 33x over `std.mem.sort` at a
  million keys and above. [MEASURED]
- **8 or 11 bits per pass** is a wash: 11 bits wins by 20% at a million keys and loses by 6% at
  ten million. [MEASURED]
- **Threads give 2.3x to 3x**, not 16x: the first pass that deals keys into buckets runs on one
  thread. A parallel first pass is the obvious next variant. [MEASURED; the cause is DERIVED]

## D4: group by key and total (2026-11-19)

Three jobs by number of groups. Millions of rows per second at 20 million rows.

| Variant | D4: 1,000 groups | D4m: 100,000 groups | D4h: 5 million groups |
|---|---|---|---|
| std.AutoHashMap | 206 | 112 | 69 |
| hand-written table, dense group numbers | 211 | 184 | 82 |
| radix sort by key, then total each run | 261 | 237 | 168 |
| 16 parts with a table each, 16 threads | 2,528 | 763 | not built |

[MEASURED, `run D4`, `run D4m`, `run D4h`; spread under 5% for the 16-thread rows shown, under 4%
for the rest.]

- **On one thread, sorting first beats hashing at every group count**, by 1.2x with few groups
  and 2x with millions. Hashing pays one unpredictable memory access per row; the radix sort reads
  and writes in order. [MEASURED; the cause is DERIVED]
- **With threads and few groups, per-part tables win by a wide margin:** 12x over one thread at
  1,000 groups, 4x at 100,000. Each part's table stays in cache when there are few groups.
- The hand-written table is at most 1.6x faster than std's map, and equal at 1,000 groups.
- **A trap, kept on record.** The first version of this job drew its keys as multiples of one
  constant, and the table hashed with one multiply. With 1,000 groups the table then ran 9x slower
  than std's map (keys piled into few slots); with 100,000 groups it ran 2.7x *faster* than it
  does now (the pattern happened to walk memory in order). std's map was unaffected both times.
  Neither number said anything about tables in general. The keys are now fully scrambled and the
  table mixes twice. The raw output of those runs is in `docs/notes/`. [MEASURED]

## D5: join a large table to one a tenth its size (2026-11-19)

About half the large table's rows find a match. Millions of large-table rows per second; every
variant builds its index inside the timed run.

| Variant | 1,000,000 rows | 20,000,000 rows |
|---|---|---|
| std.AutoHashMap on the small table | 70 | 77 |
| hand-written table | 98 | 69 |
| radix sort both sides, then merge | 200 | 147 |
| table built on 1 thread, looked up on 16 | 819 | 625 |

[MEASURED, `run D5`; spread under 5%.]

- **On one thread, sort-merge is about 2x faster than either hash join.** [MEASURED]
- **Lookups parallelise well:** 8x to 9x over the one-thread table. The table is only read while
  the threads run. [MEASURED]
- At 20 million rows the small table has 2 million keys and no longer fits the cache; the
  hand-written table drops below std's map there (69 against 77). [MEASURED]

## Across the data jobs

- Sequential passes beat random access even when they do more work: radix sort then scan beats a
  hash table for grouping and joining on one thread.
- Threads help most when each thread's working data fits in cache (few groups, mid-sized
  columns), and least when one pass over memory is the whole job.
- Standard-library containers were never the fastest, and never fell into a trap either.
