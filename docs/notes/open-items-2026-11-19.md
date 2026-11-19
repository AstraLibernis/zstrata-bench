# Open items after the cross-check (2026-11-19)

What was left undone when the cross-check work stopped. Each item says what is needed to close
it. Background: docs/notes/cross-check-2026-11-19.md and docs/measurements.md, "Confirmed in the
real projects".

## Waiting on a decision

1. **zarbor importing zstrata.** zarbor is LGPL and has no dependencies; zstrata's
   `src/cpu/pool.zig` is GPL. Either that file is relicensed to LGPL and zarbor takes its pool
   and sorts from zstrata, or zarbor keeps its own pool and stays dependency-free. The gain for
   zarbor is small either way: its pool is the same design.

## Not done here

2. **This repo still has its own radix sort** (`src/kit/radix.zig`) instead of zstrata's
   `sort.radix`. Switching changes the stamp of every job that uses it (D3, D4, D5, D7, S3), so
   they all need re-measuring.
3. **The 14 jobs listed in the cross-check note** (lopsided histograms, row-subset histograms,
   `exp`, quoted CSV text, text to number, string grouping, 64-bit float sorts, and the rest)
   are not written.
4. **This repo's zstrata dependency is pinned to an older commit** (61eb42f). The library
   module, `Pool.chunkFor` and the guarded multiply-add arrived later (zstrata 03c4dd4).

## Not done in zarbor

5. **Its command-line program and bench tools do not build on Windows** (the library and tests
   do). The measurements here went through the library with a scratch harness kept outside the
   repos.
6. **The histogram thread threshold** (`hist.parallel_threshold`, tied to
   `partition.parallel_partition_min`): 512 is right for large data and about 2x too eager on
   small deep fits. No single value wins; a rule that depends on the node size is unwritten.
7. **Binning at load** still uses a comparison sort. Not measured: it runs once per load.
8. **Other objectives' gradients** are plain loops. Measured at under 1% of a fit (6% for
   poisson), so left alone.

## Not done in zscour

9. **It still reads files with the one-byte-at-a-time CSV parser** and makes four passes over
   the bytes: 135 ms of a 953 ms run on the generated file.
10. **Numbers are still parsed twice** (once to decide the column's type, once to fill it):
    about 250 ms of that run.
11. **The rank-correlation dot product** is still a plain loop. It was not the cost; the sort
    was.

## Not done in zstrata

12. **The `zig-0.17.1` tag** still points at the first public commit, not at the library commit.
13. **Profile export** (one file another project can read at build time) was discussed and not
    built.
