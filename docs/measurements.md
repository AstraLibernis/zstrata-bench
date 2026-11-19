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
  nothing in the plain code hints at it. [MEASURED; the reason is in "Vectorisation" below]
- Fused multiply-add adds 4 to 13%. Taking four rows per pass helps only at side 128 (1.3x).
- Tiling made no difference up to side 1024: the second matrix (4 MB) still fits the cache.
- Threads: 6.4x at side 1024. Textbook to best is 800x there.

## Across the data-science jobs

- Write the vectors out. In S1, S4, S5 and S6 the explicit 16-wide version is 8x to 12x faster
  than the plain loop, and in S6 the compiler vectorised nothing it was expected to.
- Lay data out so the long direction is the vector direction (S5), and cut long passes into
  cache-sized pieces when there are many of them (S4).
- A cheap counting pass can replace a sort when only a few positions are wanted (S3).

## M1: tree histogram build (2026-11-19)

Gradients and hessians of each row added into 256 bins for each of 8 features. Millions of rows
per second.

| Variant | 10,000 rows | 1,000,000 | 10,000,000 |
|---|---|---|---|
| per feature; gradient and hessian sums in separate tables | 219 | 227 | 228 |
| per feature; each bin's two sums side by side | 367 | 364 | 370 |
| bins stored row after row, one pass | 337 | 347 | 348 |
| side by side, rows to two tables in turn | 199 | 204 | 205 |
| side by side, 4,096 rows at a time | 363 | 363 | 370 |
| 16 parts with their own histograms, 16 threads | 556 | 2,590 | 2,963 |

[MEASURED, `run M1`; spread under 1% on one thread, up to 19% for the threaded rows shown.]

- **Keep a bin's gradient and hessian sums next to each other: 1.6x.** One cache line is touched
  per row and feature instead of two. [MEASURED; the cause is DERIVED]
- **Two tables in turn made it 1.8x slower**, the opposite of what the trick is for. With bins
  spread evenly, neighbouring rows rarely hit the same bin, and the second table only costs
  cache. [MEASURED; the cause is DERIVED]
- Row layout and cache-sized pieces change nothing here (within 6%).
- Threads: 7x to 8x from a million rows up.

## M2: best split scan (2026-11-19)

Millions of 256-bin histograms scanned per second.

| Variant | 100 histograms | 10,000 | 100,000 |
|---|---|---|---|
| running sums, branch on a new best | 2.9 | 2.9 | 2.9 |
| the same without the branch | 2.9 | 2.9 | 2.9 |
| running sums first, values 8 at a time, then pick | 4.1 | 4.1 | 4.1 |
| 8-wide over blocks, 16 threads | 5.7 | 37 | 17 |

[MEASURED, `run M2`; spread under 1% on one thread, up to 19% threaded.]

- **Separating the part that must run in order (the running sums) from the part that need not
  (the divisions) gains 1.4x.** The three one-thread variants give identical bits. [MEASURED]
- Branch or no branch makes no difference: a new best is rare, so the branch is predictable.
- Threads: 9x at 10,000 histograms (40 MB), 4x at 100,000 (400 MB).

## M3: tree ensemble inference (2026-11-19)

100 trees of depth 6. Millions of rows per second.

| Variant | 1,000 rows | 100,000 | 1,000,000 |
|---|---|---|---|
| row by row, an `if` at every test | 2.2 | 2.2 | 2.2 |
| row by row, the step written as arithmetic | 1.9 | 1.9 | 1.9 |
| 256 rows per tree before the next tree, arithmetic | 2.2 | 2.2 | 2.2 |
| the same with an `if` at every test | 0.53 | 0.52 | 0.52 |
| four rows side by side down each tree | 1.1 | 1.1 | 1.1 |
| eight rows side by side | 1.2 | 1.2 | 1.2 |
| tree-first arithmetic blocks, 16 threads | 5.7 | 14.5 | 16.1 |

[MEASURED, `run M3`; spread under 2% except the smallest threaded row.]

- **The same `if` is fast in one loop and 4.3x slower in another.** Row by row it runs at 2.2;
  with the trees on the outside it runs at 0.52. The data is random, so a real branch here is
  mispredicted half the time; the row-by-row speed suggests the compiler replaced the `if` with
  a conditional move there and kept a branch in the other loop. Writing the step as arithmetic
  is never the fastest by much, but it is never the slow one. [MEASURED; the explanation is
  DERIVED and not checked in the generated code]
- **Walking four or eight rows side by side halved the speed**, as written here. This is a
  result about this code, not proof the idea cannot work. [MEASURED]
- Threads: 7x at a million rows.

## M4: dense layer forward, 256 to 256 with ReLU (2026-11-19)

Thousands of rows per second (each row is 65,536 multiply-adds).

| Variant | 64 rows | 4,096 | 32,768 |
|---|---|---|---|
| plain dot product per output | 51 | 51 | 51 |
| dot product 16 at a time | 627 | 626 | 606 |
| dot product as four fused running sums | 680 | 680 | 659 |
| weights by input; all outputs of a row grow together | 598 | 599 | 586 |
| the last one on 16 threads | 2,702 | 3,040 | 2,984 |

[MEASURED, `run M4`; spread under 5%.]

- **16-wide dot product: 12x.** A plain dot product cannot be vectorised by the compiler, because
  that would change the order of the additions. [MEASURED; the reason is DERIVED]
- Four fused running sums add 9%. Storing the weights the other way round is 9% slower than
  that, not faster.
- Threads: 4.5x to 5x.

## M5: dense layer weight gradient and update (2026-11-19)

Thousands of batch rows per second (each row is 65,536 multiply-adds).

| Variant | 64 rows | 1,024 | 16,384 |
|---|---|---|---|
| batch row by batch row, plain loops | 73 | 77 | 77 |
| the same order, fused 16-wide | 443 | 623 | 646 |
| one weight row against the whole batch | 441 | 473 | 399 |
| one weight row against 64 batch rows at a time | 441 | 612 | 611 |
| tiled, weight rows over 16 threads | 1,398 | 4,420 | 4,818 |

[MEASURED, `run M5`; spread under 10% on one thread; threaded rows up to 36% at 64 rows.]

- **Fused 16-wide inner step: 6x to 8x** over the plain loop, which the compiler again left
  unvectorised (the same pattern as S6). [MEASURED]
- Taking one weight row against the whole batch loses 38% at 16,384 rows (the batch no longer
  fits the cache); tiling the batch recovers it. The simple row-by-row order is as fast as the
  tiled one on one thread. [MEASURED]
- Threads: 7.5x at 16,384 rows.

## M6: one Adam step (2026-11-19)

Billions of parameters per second (7 arrays of 4 bytes each are read or written per parameter).

| Variant | 10,000 | 1,000,000 | 50,000,000 |
|---|---|---|---|
| one plain loop | 0.68 | 0.66 | 0.68 |
| three plain loops | 0.52 | 0.49 | 0.49 |
| one loop, 16 at a time | 7.3 | 4.9 | 1.4 |
| 16-wide on 16 threads | 7.3 | 18.4 | 1.5 |

[MEASURED, `run M6`; spread under 3% on one thread, up to 22% threaded. Every variant writes
identical bits.]

- **16-wide: 11x in cache, 7x at 28 MB, 2x at 1.4 GB.** The plain loop has a square root and a
  division per parameter and the compiler kept it scalar. [MEASURED]
- At 50 million parameters threads add nothing (1.1x): the step moves 39 GB/s on one thread
  already, and memory is the limit. [MEASURED; "memory is the limit" is DERIVED]
- Splitting into three loops is 25% slower.

## Across the model-learning jobs

- The compiler left every floating-point inner loop scalar (M4, M5, M6, as S6 before). Explicit
  16-wide code gained 6x to 12x each time.
- Put things that are updated together next to each other (M1), and split work that must run in
  order from work that need not (M2).
- An `if` on unpredictable data can cost 4x or nothing depending on what the compiler makes of
  it (M3); the arithmetic form is the predictable choice.
- Two tricks from elsewhere made things worse on this data: alternating tables (M1) and walking
  several rows side by side (M3). Measure before keeping a trick.

## Graphics card against the CPU (2026-11-19)

Radeon RX 9070 XT through Vulkan compute. Five jobs have two GPU variants each:
**on the card** (data already in video memory, result left there: the dispatch alone) and
**with transfer** (from main memory, to the card, and back, in one submit). Times in
milliseconds for one run, next to the best CPU variants. Every GPU variant agrees with the
reference and with NumPy.

| Job and size | Best on one thread | 16 threads | GPU, on the card | GPU, with transfer |
|---|---|---|---|---|
| S5 distances, 1,000 points | 0.121 | 0.084 | 0.200 | 0.228 |
| S5 distances, 16,000 points | 31.6 | 5.13 | 1.87 | 1.74 |
| S6 matrix multiply, side 128 | 0.095 | 0.015 | 0.070 | 0.195 |
| S6 matrix multiply, side 1024 | 24.9 | 4.17 | 1.03 | 9.59 |
| M3 tree inference, 1,000 rows | 0.447 | 0.158 | 0.214 | 0.226 |
| M3 tree inference, 1,000,000 rows | 449 | 62.1 | 2.04 | 4.99 |
| M4 dense forward, 64 rows | 0.138 | 0.024 | 0.075 | 0.115 |
| M4 dense forward, 32,768 rows | 60.5 | 11.9 | 2.75 | 10.2 |
| M6 Adam step, 10,000 parameters | 0.002 | 0.002 | 0.070 | 0.089 |
| M6 Adam step, 50,000,000 parameters | 35.2 | 32.3 | 2.59 | 82.9 |

[MEASURED, `run S5`, `run S6`, `run M3`, `run M4`, `run M6`; spread under 15% for the GPU rows
shown, under 6% for most.]

What to do:

- **Small jobs stay on the CPU.** Every dispatch costs about 0.07 ms before any work is done. At
  the smallest size of every job the CPU wins, by up to 35x (the Adam step on 10,000 parameters).
  [MEASURED]
- **If the data can live on the card, the card wins every large job:** 2.7x over 16 threads for
  distances, 4x for matrix multiply and the dense layer, 12x for the Adam step, 30x for tree
  inference. [MEASURED]
- **Whether it still wins after the round trip depends on how much data moves per unit of work.**
  - Distances and tree inference move little and compute a lot: with transfer the card is still
    2.9x and 12x ahead of 16 threads.
  - Matrix multiply and the dense layer move megabytes for milliseconds of work: with transfer
    the card is 2.3x behind 16 threads for the matrix and level with them for the dense layer.
  - The Adam step moves 1.4 GB to do 2.6 ms of work: with transfer it takes 83 ms, 2.6x slower
    than the CPU, against 12x faster when the data stays put. [MEASURED]
- **So the placement rule is about where the data lives between steps**, not about the kernel.
  A training loop that keeps parameters, moments and gradients on the card gets the 12x; one that
  brings them back each step loses to the CPU. This is zstrata's playbook rule 4, measured here on
  whole jobs.
- **Tree inference is the surprise.** Nothing on the CPU beat 2.2 million rows per second on one
  thread; the card does 490 million. Each row walks 100 trees independently, which suits
  thousands of small cores.

Not measured: a GPU variant of the weight update (M5), and the shaders are first versions (no
tuning of workgroup size or shared memory), so the GPU numbers are a floor, not a ceiling.

## D6: split delimited text (2026-11-19)

Find every comma and newline in comma-separated numbers (about one byte in six is a delimiter).
Billions of bytes per second.

| Variant | 10 KB | 1 MB | 100 MB |
|---|---|---|---|
| test each byte, record if a delimiter | 4.8 | 0.95 | 0.93 |
| always record, move on only for a delimiter | 2.5 | 2.5 | 2.5 |
| std.mem.findAnyPos for each next delimiter | 3.8 | 0.86 | 0.86 |
| compare 64 bytes at a time, record the set bits | 13.9 | 8.0 | 6.8 |
| the same on 16 threads | 13.8 | 86 | 46 |

[MEASURED, `run D6`; spread under 4% on one thread except std at 10 KB (15%), up to 14% threaded.]

- **Compare 64 bytes at once: 7x to 8x** over the byte loop from 1 MB up. Each compare yields a
  64-bit mask, and only the set bits are visited. [MEASURED]
- **std's search is the slowest way here** (0.86), slightly behind the plain byte loop: it is
  called once per delimiter and delimiters are only a few bytes apart. [MEASURED; the reason is
  DERIVED]
- The branch-free loop is steady at 2.5 and 2.7x over the branch. At 10 KB the branch looks fast
  (4.8) for the same reason as in D2: the processor learns the short repeating input.
- Threads: 11x at 1 MB, 6.7x at 100 MB.

## D7: remove duplicate keys (2026-11-19)

Two jobs: D7 has 1,000 different keys, D7u has one different key per two rows. Millions of rows
per second at 20 million rows.

| Variant | D7: 1,000 different keys | D7u: 10 million different keys |
|---|---|---|
| std.AutoHashMap as a set | 203 | 78 |
| hand-written table | 217 | 85 |
| radix sort a copy, keep each new key | 358 | 177 |
| 16 parts with a table each, 16 threads | 2,544 | 72 |

[MEASURED, `run D7`, `run D7u`; spread under 2% on one thread; the D7 threaded row varies by up
to 34%.]

- **On one thread, sort then scan again beats hashing**, 1.6x to 2.3x, as in D4 and D5. [MEASURED]
- **Threads help only when keys repeat a lot.** With 1,000 different keys, per-part tables are
  12x faster than one thread. With 10 million different keys the same variant is slower than one
  thread: almost every key survives its part, so the merge on one thread does the whole job
  again. [MEASURED; the reason is DERIVED]

## Vectorisation: why plain loops stay slow, and how to write them (2026-11-19)

Three jobs isolate the question: V1 (`out = y + a * x`, a loop that stores), V2 (dot product, a
loop with a running total) and V3 (a storing loop with a square root and a division). Billions
of values per second, one thread, build for this machine (AVX-512).

| Variant | V1 at 1,000 | V1 at 10 million | V2 at 1,000 | V2 at 1 million | V3 at 1,000 | V3 at 10 million |
|---|---|---|---|---|---|---|
| plain loop | 5.1 | 4.5 | 2.8 | 2.6 | 0.71 | 0.70 |
| plain loop, `noalias` parameters | 5.1 | 4.4 | | | 0.71 | 0.70 |
| plain loop, `@setFloatMode(.optimized)` | | | 1.4 | 1.3 | | |
| vectors written out, 8 wide | 30 | 8.1 | | | 5.7 | 4.6 |
| vectors written out, 16 wide | 43 | 8.3 | 40 | 17 | 10.1 | 5.1 |
| width from `std.simd.suggestVectorLength` | 43 | 8.3 | 38 | 17 | 10.1 | 5.1 |

[MEASURED, `run V1`, `run V2`, `run V3`; spread under 2% except the 10-million rows, up to 5%.]

- **This Zig (0.17.1) does not turn loops into vector code in the program it builds.** Eight
  ways of writing a storing loop were timed (slices, an index, raw pointers, `noalias`, in
  place on one slice, integers instead of floats): all ran one value at a time. Build options
  (`-fllvm`, `-fstrip`, `-fsingle-threaded`, `-lc`, `-mcpu=x86_64_v3`) changed nothing.
  [MEASURED, scratch program, hyperfine] A forum thread reports the same from Zig 0.16 on
  (https://ziggit.dev/t/optimizing-the-goertzel-algorithm/16233); why upstream has it this way
  was not looked into.
- **The assembly listing from `-femit-asm` cannot be trusted on this point.** For the `noalias`
  loop the listing shows an 8-wide vector loop, while the bytes of the same function in the
  program built by the same command are one-at-a-time instructions, and it runs at
  one-at-a-time speed. Judge by timing, or by reading the built program, never by the listing.
  [MEASURED: the function's own bytes printed from inside the program]
- **`noalias` gains nothing here, and `@setFloatMode(.optimized)` made the dot product 2x
  slower** on this build. Neither is a route to vector code. [MEASURED]
- **Writing the vectors out is the fix: 6x to 14x** while the data fits the cache, about 2x
  for V1 at 10 million values where memory speed takes over, and 7x for V3 at any size because
  square root and division dominate. [MEASURED]

**The same source built for other CPUs**, run on this machine at 100,000 values (billions per
second). `x86_64` is the plainest 64-bit CPU (SSE2, 4 floats per register, no fused
multiply-add); `x86_64_v3` is AVX2 (8 floats).

| Variant | built for x86_64 | built for x86_64_v3 | built for this CPU |
|---|---|---|---|
| V1 plain | 4.9 | 4.8 | 4.9 |
| V1 vectors, 16 wide | 12.6 | 13.1 | 13.7 |
| V1 vectors, suggested width (4 / 8 / 16) | 12.3 | 12.9 | 13.7 |
| V1 16 wide with `@mulAdd` | 0.36 | 13.1 | 13.6 |
| V2 plain | 2.6 | 2.6 | 2.6 |
| V2 vectors, 16 wide | 20.8 | 29 | 31 |
| V2 16 wide, four sums, `@mulAdd` | 1.0 | 33 | 31 |
| V2 portable (suggested width, `@mulAdd` only if the CPU has it) | 20.8 | 33 | 31 |
| V3 plain | 0.70 | 0.70 | 0.70 |
| V3 vectors, 16 wide | 2.5 | 5.2 | 9.2 |
| V3 vectors, suggested width | 2.7 | 5.2 | 9.3 |

[MEASURED, `zig build -Doptimize=ReleaseFast -Dcpu=x86_64` (and `x86_64_v3`), then
`run V1 --size 100000` and so on; spread under 4%. These are builds for another CPU run on this
one, not measurements of another machine.]

- **Vector code is portable.** `@Vector(16, f32)` compiles for any CPU; on a narrower one the
  compiler splits it into what the CPU has, and it stayed within 7% of the suggested width in
  every case. On the plainest 64-bit CPU the written-out version is still 2.5x to 8x faster
  than the plain loop. [MEASURED]
- **`@mulAdd` is the one thing here that is not portable in speed.** On a CPU without the
  instruction it gives the right answer through a library routine per value: 20x to 35x slower
  than not fusing at all. Ask the build first (`builtin.cpu.has(.x86, .fma)`), as V2's
  `portable` variant does. [MEASURED]

**How to write a hot loop, from the above:**

1. Take the width from `std.simd.suggestVectorLength(T) orelse 4`. A fixed 16 is also fine.
2. Main loop on `@Vector(width, T)` loaded from `slice[i..][0..width].*`, then a plain loop
   for the leftover values.
3. For a running total, keep the total as a vector and `@reduce` once at the end. The result
   differs from the plain loop in the last bits, because the additions happen in another order.
4. Use `@mulAdd` only behind a check that the build's CPU has the instruction.
5. Confirm with a timing against the plain loop. Never confirm from an assembly listing.

## Confirmed in the real projects (2026-11-19)

The cross-check (docs/notes/cross-check-2026-11-19.md) listed where zarbor and zscour looked
behind these measurements. Each claim was then measured in the project's own code, on
generated data, with the result compared before and after. What reading the code suggested and
what the measurement said did not always agree, which is the point of this section.

**zscour** (generated 500,000 x 25 CSV, 82 MB; stage timers added to a scratch copy; whole run
with hyperfine, 5 runs, spread under 1%):

| Claim from reading | Measured share of the run | After the change | Verdict |
|---|---|---|---|
| Numeric columns sorted with a comparison sort (D3) | 651 ms of 1,920 (34%) | 75 ms with a radix sort on 64-bit floats | confirmed, and the largest cost |
| Ranks sorted with an indirect comparison sort (D3) | most of 450 ms (23%) | association stage 122 ms | confirmed |
| Each number parsed from text three times | about 300 ms (16%) for all three | fill pass 191 -> 139 ms parsing once | real but small; it was guessed to be the top cost and was not |
| Scalar CSV parser, four passes (D6) | 135 ms (7%) | not changed | real but minor here |
| Rank correlation is a plain loop (V2) | inside the 122 ms left | not changed | not the cost; the sort was |

Whole run 1.920 -> 0.953 s with a byte-identical report. [MEASURED]

**zarbor** (generated 28 features x 255 bins, logistic, 100 rounds, through the library; three
runs each, spread under 3% for phases and predict):

| Claim from reading | Measured | Verdict |
|---|---|---|
| Tree walk uses an `if` chain; M3's arithmetic step was 4.3x faster | 924 -> 462 ms on one thread (2.0x), 84 -> 65 ms on 16 threads (1.3x), same predictions | confirmed, at half the size M3 suggested: real trees have uneven depth and explicit children |
| Split scan interleaves divisions with running sums (M2: 1.4x) | split phase 1.6x to 1.7x faster, same splits bit for bit | confirmed; it is 15% of a shallow fit and 36% of a deep one |
| Logistic gradient is 8 wide where 16 is faster (V3) | gradients are 0.5 to 0.7% of a fit | true and irrelevant |
| Trees-outermost is the wrong order for prediction (M3) | blocks of 256 to 4,096 rows changed nothing | refuted for zarbor's shape |
| Threads start too early for small nodes (M1) | raising the threshold: 2.1x faster on small deep fits, 2.2x slower on a 2-million-row fit | both sides were right in their own regime; no single threshold wins |
| Binning sorts with a comparison sort (D3) | not measured: it runs once per load | open |

[MEASURED; the scratch harness and copies are not in any repo]

What this adds to the list below:

7. A reading of the code finds candidates; only a stage timer says which one is the cost. Of
   eleven claims, five were confirmed as worth fixing, three were true but too small to matter,
   two were refuted and one is unmeasured.
8. A microbenchmark's ratio is an upper bound. The tree walk gained 2.0x, not M3's 4.3x, and
   1.3x once every core was busy.
9. Thread thresholds do not transfer between workloads. Measure them at both ends of the sizes
   the code will see.

## What the whole set says, in one place

1. Write vectors out for hot loops: this Zig does not vectorise loops by itself (see
   "Vectorisation"), which cost 6x to 13x in every case measured (S1, S4, S5, S6, M4, M5, M6).
2. Do not branch on data that is a coin flip (D2, D6); write the step so it always runs.
3. Prefer passes that read memory in order to tables that jump around: sort then scan beat
   hashing on one thread for grouping, joining and removing duplicates (D4, D5, D7).
4. Threads pay when each thread's data fits its cache, or when the work per byte is large; they
   do not pay when one pass over memory is the whole job, or when a one-thread merge follows.
5. The graphics card wins large jobs when the data lives on it, and loses when little work is
   done per byte moved (see the GPU section).
6. Tricks carried over from elsewhere need measuring here: two of them made things slower.
