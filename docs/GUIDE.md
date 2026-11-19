# How to work on zstrata-bench

For whoever picks this up next (usually Claude in a fresh session). Read `PLAN.md` first for what
the project is; this page is how to proceed.

## Start of every session

1. Read `PLAN.md`: find the first milestone that is not ticked.
2. Read the newest file in `docs/notes/` if there is one (stopping points go there).
3. Check the machine is quiet: no local model loaded, no build running.
4. Run `zig build test` before changing anything. If it fails, fix that first.

## Layout (once B0 exists)

```
build.zig, build.zig.zon     Zig 0.17.x; depends on vulkan-zig (and zstrata, see PLAN decision 2)
src/main.zig                 commands: run, look, list, check
src/harness.zig              timing, repeats, spread, disturbance check, saved results
src/profile.zig              reads the machine facts zstrata measured
src/data.zig                 seeded input generators (same input every run)
src/jobs/<group>/<job>.zig   one file per job: spec, reference, variants
shaders/                     GPU variants
verify/<job>.py              the outside check (NumPy / pandas / SciPy)
results/<machine>/<job>/     one small file per measurement, saved as it finishes
map/<machine>.tsv            the distilled answers that `look` reads
docs/measurements.md         numbers and what they mean
docs/notes/                  stopping points, dated
```

## Commands (the target interface)

```
zig build run -Doptimize=ReleaseFast -- run D1            one job, every variant and size
zig build run -Doptimize=ReleaseFast -- run D             one group
zig build run -Doptimize=ReleaseFast -- run D4 --only hash,sort --size 1e6
zig build run -- run D1 --quick                           tiny sizes, seconds: checks the path
zig build run -- look "group by" --rows 1e7               the recommended way, with its numbers
zig build run -- list                                     jobs, variants, what is measured
zig build run -- check                                    results that are stale or missing
zig build test                                            Debug: every variant equals its reference
```

## Adding a job

1. **Write the spec** at the top of `src/jobs/<group>/<job>.zig`: input, output, one paragraph.
2. **Write the reference**: the plainest correct code, one thread, no tricks.
3. **Write the outside check** `verify/<job>.py` with an established library. Run it once on a small
   seeded input and confirm the reference matches. Record that in the job file's header.
4. **Add variants one choice at a time.** Name each by what it changes (`lanes16`, `threads`,
   `radix`, `gpu`). A variant that changes two things at once cannot be read afterwards.
5. **Test**: every variant against the reference, at sizes that hit the edges (0, 1, one less and
   one more than a vector, one less and one more than a chunk), and for threaded variants at 1, 3
   and 16 threads.
6. **Dry-run** with `--quick`. Fix script and parsing problems here, in seconds.
7. **Measure** with `run <job>`. Results save themselves one at a time.
8. **Write the answer** into `docs/measurements.md`: which variant wins in which size band, by how
   much, and the size where the answer changes. Then regenerate the map.

## Rules that are not optional

**Measuring**

- ReleaseFast, native CPU target. Never time a Debug build.
- Each measurement repeats and records its spread. A difference smaller than the spread is a tie,
  and a tie goes to the simpler variant.
- A run flags itself when the machine was disturbed (zstrata's markers). Disturbed results are
  re-measured, not averaged in.
- Every number in the docs is tagged [MEASURED] or [DERIVED]. No numbers in code comments.
- Report whole-job time and the rate (rows or bytes per second), with the size.

**Runs**

- Segments: any job, group or variant can be run alone.
- Every measurement is saved the moment it finishes and skipped next time unless its code, the
  Zig version or the machine profile changed. One failure reports itself and the rest continue.
- Nothing runs longer than about two minutes without being split. Slow entries get one run and say so.
- Dry-run tiny before any long run.

**Code**

- The Zig memory rules from the owner's standing instructions apply in full: one owner per
  allocation, `defer`/`errdefer` at the acquire, no large stack arrays in hot paths, pool tasks
  correct when one worker gets the whole range, reductions in a fixed order.
- Inputs are generated from a fixed seed. No timing depends on data that changes between runs.
- The repo is public. Inputs are synthetic examples only: never real datasets, competition data,
  names or paths from other work, or credentials.
- GPU tests run with the validation layer and its best-practice checks on.
- Each new test is mutation-checked once (break the code, see it fail, restore), briefly.
- Hot loops are written as vectors (`@Vector`, width from `std.simd.suggestVectorLength`), with
  `@mulAdd` only behind a CPU check: this Zig does not vectorise plain loops, and an assembly
  listing is not evidence either way (docs/measurements.md, "Vectorisation").

**Other repos**

- zstrata, zarbor, zscour, zmural and zcanon are not edited from here. A change there is proposed
  to the owner first (PLAN milestones Z1 and B8).

## What a finished answer looks like

An entry in the map is one line a person can act on:

```
job       rows        best variant      rate           next best      holds for
D4        1e6..1e8    hash, 14 threads  <measured>     <measured>     keys <= 1e5
D4        1e6..1e8    sort, radix       <measured>     <measured>     keys > 1e5
```

with the reason in `docs/measurements.md` and the code in the job file. If the answer cannot be
stated that plainly, the job needs another variant or another size, not a longer explanation.

## Stopping

Before ending a session that changed anything: tests pass, results committed and pushed, the
milestone ticked or a dated note in `docs/notes/` saying exactly where it stopped and what is next.

## Looking an answer up

Before writing code for one of the measured jobs, ask:

```
zstrata-bench look group total --rows 1e7
```

The words are matched against each job's id, title and group; every word must be found. `--rows`
picks the measured size nearest to the one you have. With no words, every job is shown.

For each job and size it prints up to two answers:

- **one thread:** the variant to use when the code must stay on one thread.
- **all threads:** the variant to use when threads are allowed. If no threaded variant beats the
  one-thread pick, it says so.

Each answer gives the rate, how many times faster it is than the plain way (the job's first
variant), what the variant does in one line, and the next best.

How the pick is made: the fastest variant, unless a plainer one (listed earlier in the job) is
within 5% of it, or within the two measurements' spreads added together, whichever is larger.
A tie goes to the plainer code.

`zstrata-bench map` writes the same answers for every job and size to `map/<machine>.tsv`.

Limits to keep in mind: an answer holds for the measured sizes and the stated input (for example
"about half the rows pass"), on the machine named at the top. Between two measured sizes the
answer can change; when it matters, measure that size with `run <job> --size N`.
