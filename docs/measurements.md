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
