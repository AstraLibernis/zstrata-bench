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

## S1: column statistics (2026-11-19)

Mean, variance, minimum and maximum of a column. Billions of values per second.

| Variant | 40 KB | 4 MB | 400 MB |
|---|---|---|---|
| one loop, one value at a time | 0.96 | 0.95 | 0.95 |
| four simple loops | 0.36 | 0.35 | 0.35 |
| one loop, 16 values at a time | 9.6 | 9.9 | 9.2 |
| 16-wide on 16 threads | 9.7 | 117 | 17.9 |

[MEASURED, `run S1`; spread under 3% except the threaded 4 MB rows, 6 to 7%.]

- **16-wide vectors: 10x**, at every size. [MEASURED]
- **Four simple loops are 2.7x slower than one**, not faster: the compiler did not turn the
  separate sum, min and max loops into anything quicker than the combined loop. [MEASURED]
- Threads: 12x at 4 MB, 1.9x at 400 MB (memory again).

## S2: histogram, 256 bins (2026-11-19)

Billions of values per second.

| Variant | 40 KB | 4 MB | 400 MB |
|---|---|---|---|
| one table | 4.0 | 4.2 | 4.2 |
| four tables fed in turn | 3.7 | 4.3 | 4.3 |
| 16 bin numbers at once, four tables | 4.2 | 4.6 | 4.6 |
| 16 parts on 16 threads | 5.6 | 32 | 17 |

[MEASURED, `run S2`; spread under 1% on one thread, up to 12% threaded.]

- **The plain loop is already within 10% of the tricks.** Four tables and wide bin numbers help
  when neighbouring values often land in the same bin; with evenly spread values they rarely do.
  A column with long runs of equal values would be the case to measure next. [MEASURED; the
  reason is DERIVED]
- Threads: 7x at 4 MB, 4x at 400 MB.

## S3: quantiles (2026-11-19)

The values at five positions of the sorted column. Millions of values per second.

| Variant | 10,000 | 1,000,000 | 10,000,000 |
|---|---|---|---|
| sort a copy (std.sort.pdq) | 62 | 34 | 33 |
| radix sort a copy | 304 | 300 | 286 |
| partition around each position | 566 | 86 | 88 |
| count top 16 bits, sort only the bins that matter | 301 | 1,260 | 1,261 |
| the same, counting on 16 threads | 52 | 1,224 | 1,481 |

[MEASURED, `run S3`; spread under 5% except the 10,000 rows of the partition and threaded
variants, up to 10%.]

- **For a few quantiles of a large column, do not sort.** Counting the top bits and sorting only
  the bins that hold a wanted position is 37x faster than sorting and 4.2x faster than a radix
  sort from a million values up. It also needs no copy of the column. [MEASURED]
- **Small columns: partition.** At 10,000 values it is the fastest (566), and counting 65,536
  bins costs more than the data. [MEASURED]
- Threads add at most 17% (10 million values) and cost 6x at 10,000 values.

## S4: correlation between 8 columns (2026-11-19)

Millions of rows per second (each row is 8 values; 44 sums are needed).

| Variant | 10,000 rows | 1,000,000 | 10,000,000 |
|---|---|---|---|
| one plain pass per column and per pair (44 passes) | 48 | 48 | 48 |
| the 44 passes, 16 values at a time | 467 | 410 | 310 |
| rows stored together, one pass | 334 | 334 | 335 |
| columns stored apart, one pass | 240 | 236 | 239 |
| 16-wide passes over 4,096 rows at a time | 513 | 491 | 404 |
| 16-wide passes over blocks, 16 threads | 501 | 3,621 | 1,975 |

[MEASURED, `run S4`; spread under 7%.]

- **Many passes are fine if each piece stays in cache.** 44 wide passes over 4,096 rows at a time
  is the fastest one-thread way at every size, 8x to 10x over the plain passes. Without the
  pieces, the same 44 passes fall from 467 to 310 as the table outgrows the cache. [MEASURED]
- **Row storage is steady** (334 at every size) and beats the unpieced column passes at 10
  million rows, but never the pieced ones. [MEASURED]
- Threads: 7x at a million rows, 5x at ten million.

## S5: nearest neighbour for every point, 8 dimensions (2026-11-19)

All pairs of points. Billions of pairs per second (a pair is 8 subtractions and 8 multiplies).

| Variant | 1,000 points | 4,000 points | 16,000 points |
|---|---|---|---|
| three plain loops | 0.65 | 0.65 | 0.65 |
| each pair's 8 dimensions as one vector | 0.80 | 0.80 | 0.80 |
| one array per dimension, 16 other points at a time | 8.3 | 6.8 | 7.8 |
| the same on 16 threads | 12.6 | 35.7 | 44.5 |

[MEASURED, `run S5`; spread under 1% on one thread except 12% for the 4,000-point wide row;
the 8-thread rows are noisy (12 to 49%) and are not shown.]

- **Vectorise across the many, not across the few.** Making a vector of a pair's 8 dimensions
  gains 1.2x; storing each dimension as its own array and taking 16 other points at once gains
  12x. Same arithmetic, different layout. [MEASURED]
- Threads: 5.7x at 16,000 points.

## S6: matrix multiply (2026-11-19)

Square matrices of 32-bit floats. Billions of multiply-adds per second.

| Variant | side 128 | side 512 | side 1024 |
|---|---|---|---|
| textbook loops (row, column, sum) | 3.3 | 1.0 | 0.32 |
| inner loops swapped | 5.0 | 5.1 | 5.1 |
| swapped, second matrix 128 rows at a time | 5.0 | 5.2 | 5.1 |
| inner step written as 16-wide vectors | 27 | 37 | 42 |
| 16-wide with fused multiply-add | 28 | 40 | 47 |
| fused, four rows per pass | 36 | 41 | 41 |
| fused, four rows per pass, 16 threads | 144 | 242 | 259 |

[MEASURED, `run S6`; spread under 3% on one thread, up to 10% threaded.]

- **The textbook order collapses as the matrix grows**: 10x slower per multiply-add at side 1024
  than at 128, because it walks the second matrix down its columns. Swapping the inner loops
  holds 5.1 at every size. [MEASURED; the cause is DERIVED]
- **The compiler did not vectorise the swapped loop.** Writing the same step as 16-wide vectors
  is 5x to 8x faster. This is the largest "written this way or that way" gap found so far, and
  nothing in the plain code hints at it. [MEASURED; why the compiler declines is not known]
- Fused multiply-add adds 4 to 13%. Taking four rows per pass helps only at side 128 (1.3x).
- Tiling made no difference up to side 1024: the second matrix (4 MB) still fits the cache.
- Threads: 6.4x at side 1024. Textbook to best is 800x there.

## Across the data-science jobs

- Write the vectors out. In S1, S4, S5 and S6 the explicit 16-wide version is 8x to 12x faster
  than the plain loop, and in S6 the compiler vectorised nothing it was expected to.
- Lay data out so the long direction is the vector direction (S5), and cut long passes into
  cache-sized pieces when there are many of them (S4).
- A cheap counting pass can replace a sort when only a few positions are wanted (S3).
