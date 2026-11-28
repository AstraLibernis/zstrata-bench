# zstrata-bench plan

Status: **B0 to B6 done** (2026-11-19): harness, the map and `look`, 25 jobs on the CPU (data D1 to D7, data science S1 to S6, model learning M1 to M6, vectorisation V1 to V3), and GPU variants for S5, S6, M3, M4 and M6. T, the program timer (`time`), done 2026-11-23. Next: B7 (LLM and zmural slices, when that work is live) and B8 (using it). Open items: docs/notes/open-items-2026-11-19.md.

## What this is

Two projects with separate jobs:

- **zstrata** maps the hardware that exists and its limits: how many cores, how wide the vectors,
  how big and how fast each cache and memory, what the GPU offers, what it costs to cross between
  them. It answers "what is this machine?".
- **zstrata-bench** takes the recurring jobs in the owner's work (data processing, data science,
  model learning, later LLM and zmural), writes each job several plausible ways, and measures which
  way uses the detected hardware best. It answers "how should this job be written here?".

The point is to stop guessing. When code for one of these jobs is written, the answer to "this way
or that way?" is looked up, with a measurement behind it.

## What it is not

- Not a map of every command or every combination. Commands are finite (Vulkan's registry lists
  720), combinations are not, and nobody maps them all. See "Prior work".
- Not a tuner for the other projects' code. It measures small, self-contained jobs. Applying a
  result to zarbor, zscour or zmural happens when that project is being worked on.
- Not a contest against libraries. A library can appear as one variant of a job, as a yardstick.
- Not a search engine over thousands of variants. Each job has a handful of hand-written variants
  that differ in one named choice at a time.

## Prior work (why this shape)

Researched 2026-11-19, a quick pass, not a survey:

| Approach | Examples | What we take from it |
|---|---|---|
| Time every primitive | uops.info, llvm-exegesis | Look up instruction costs there; do not re-measure them |
| Search per routine, save the answer | ATLAS, FFTW, SPIRAL, Kernel Tuner, CLTune | Measure per job on the machine it runs on, and store the result |
| Learned cost model | TVM auto-scheduler | Out of scope |
| Rules as a checker | Vulkan best-practices layer | Turn it on in every GPU test. It is free |

The best-practices layer was tried on a real GPU program on 2026-11-19: clean at real sizes, and it
did not flag one-submit-per-dispatch, which measured 1.56x slower. Measured patterns cover ground
the checker does not.

## The unit: a job

A job is one recurring task with a fixed input, a fixed output and a correctness check.

Every job has:

1. **A spec**: what goes in, what comes out, in one paragraph.
2. **A reference variant**: the plainest correct code. Every other variant must match its output.
3. **Variants**: each changes one named choice (see below) against the reference or another variant.
4. **Sizes**: at least three, a factor of 100 apart where memory allows, so crossovers show.
5. **An outside check**: a short Python script using an established library (NumPy, pandas,
   SciPy) that computes the same answer on a small input. Slow is fine. It is run when the job is
   added or its spec changes, not on every run.

## The choices

Nearly every "this way or that way" question is one of these:

| Choice | Options |
|---|---|
| Vector width | one value at a time, 4, 8, 16 lanes |
| Threads | 1, physical cores, all logical cores; static split or shared cursor |
| Chunk size | against L1, L2, L3 (sizes come from zstrata) |
| Data layout | array of records or one array per field; row-wise or column-wise |
| Number type | 64, 32 or 16-bit floats; 8, 16 or 32-bit integers |
| Branching | a branch, or branch-free arithmetic and masks |
| Device | CPU or GPU; with or without the cost of moving the data |
| Algorithm | where two standard ones exist (comparison sort or radix, hash or sort for grouping) |

About 20 jobs times a few choices each. That is what keeps the project finite.

## Job list

Order within a slice is the build order. Jobs marked (zstrata) already exist as zstrata cross-device
tasks and are brought over, not rewritten.

**D. Data processing** (first slice)

| Id | Job | Main choices |
|---|---|---|
| D1 | Add up a column | width, threads, chunk |
| D2 | Filter rows by a condition, count and collect | branching, width, threads |
| D3 | Sort a column of keys | algorithm, threads |
| D4 | Group by key and total | algorithm (hash, sort, direct index), key count, threads |
| D5 | Join two tables on a key | algorithm, layout |
| D6 | Split delimited text into fields | branching, width |
| D7 | Remove duplicate keys | algorithm |

**S. Data science**

| Id | Job | Main choices |
|---|---|---|
| S1 | Column statistics in one pass (mean, variance, min, max) | width, threads |
| S2 | Histogram / binning of a column | branching, bin type, threads |
| S3 | Quantiles | algorithm (sort or select) |
| S4 | Correlation between columns | layout, width, threads |
| S5 | Distances between all pairs of rows | width, tiles, threads, device |
| S6 | Matrix multiply | loop order, tiles, threads, device |

**M. Model learning**

| Id | Job | Main choices |
|---|---|---|
| M1 | Tree histogram build (gradients into bins) | layout, bin type, threads |
| M2 | Best-split scan over histograms | width |
| M3 | Run rows through a tree ensemble (zstrata) | layout, threads, device |
| M4 | Dense layer forward (zstrata) | width, number type, device |
| M5 | Dense layer backward and weight update | width, threads, device |
| M6 | Elementwise update over a large array (zstrata) | threads, device |

**L. LLM** (when that work starts)

| Id | Job | Main choices |
|---|---|---|
| L1 | Matrix multiply in 16-bit and 8-bit | number type, device |
| L2 | One attention block | tiles, device |
| L3 | Top-k selection from scores | algorithm |

**V. zmural** (when that project is worked on)

| Id | Job | Main choices |
|---|---|---|
| V1 | Scale a frame | device, filter |
| V2 | Colour conversion | width, device |
| V3 | Blur | passes, device |

## Milestones

Each milestone ends with: tests pass in Debug, results committed, `PLAN.md` ticked.

- **B0 Skeleton ✓ (2026-11-19).** Build file, the harness (timing, repeats, spread, disturbance check), seeded
  input generators, per-entry saved results, `--quick`, and job D1 end to end including the outside
  check. Proves the whole path with the simplest job.
- **Z1 Profile export (in zstrata).** `zstrata profile` writes the facts zstrata-bench needs as one
  small file: core and thread counts, vector width, cache sizes, memory speed, thread hand-off
  cost, GPU name, VRAM, shared-memory limit, round-trip cost, transfer speed. Small, but it is a
  change to zstrata, so it waits for the owner's go-ahead. Until then B0 reads the few facts it
  needs from zstrata's existing CSV.
- **B1 Data processing ✓ (2026-11-19).** D2 to D5. First real crossovers.
- **B2 The map and `look` ✓ (2026-11-19).** Distil results into one recommendation file per machine and a lookup
  command. Write the short "how to read an answer" page.
- **B3 Data science ✓ (2026-11-19).** S1 to S4, then S5 and S6 on CPU.
- **B4 Model learning ✓ (2026-11-19).** Bring M3, M4, M6 over from zstrata; add M1, M2, M5.
- **B5 GPU variants ✓ (2026-11-19, without M5 and without the best-practice checks in tests: see docs/measurements.md).** Add the device choice to the jobs where it can win (S5, S6, M3 to M6), with
  and without transfer cost, and the best-practices layer on in tests.
- **B6 Remaining data jobs ✓ (2026-11-19).** D6, D7.
- **V Vectorisation ✓ (2026-11-19).** V1 to V3: this Zig does not vectorise loops; written-out vectors are the fix and are portable (docs/measurements.md, "Vectorisation").
- **T Program timer ✓ (2026-11-23).** `zstrata-bench time`: whole programs timed from outside
  with hyperfine 2.0's options, statistics and JSON layout, plus Windows job-object metrics
  (process-tree memory, faults, processes, I/O). Checked against hyperfine: docs/TIMER.md.
- **B7 LLM and zmural slices.** Only when that work is live.
- **B8 Use it.** Add the lookup to the Zig working habit (the zcanon skill text), and apply
  results to a project when that project is next worked on. Both touch other repos: ask first.

## Ceiling target (Linux against Windows, set 2026-11-27)

The target is **parity with Windows on the same machine, not beating it**. Rows where Linux is
ahead are never work items. Check: `tools/ceiling.py` (Linux results against Windows'); exit 0 =
met.

- **Met when** no job's median Linux/Windows rate is under 0.95, and no row is under 0.85x beyond
  both spreads. The exception is a row listed in `docs/ceiling-exceptions.tsv` whose cause lies
  outside this code (`power`, `driver`, `permission`) or that is `tried`. 0.85 is the noise
  floor: two identical plain Linux runs differ by 0.88-1.18x on 95% of rows.
- **A row from a single full pass is first rerun once.** On 2026-11-27, 6 of 9 open rows (all of
  V2 at n=100,000 at 0.66x, D2s `branch`) cleared on the rerun.
- **Each remaining gap gets one bounded experiment**, recorded in the exceptions file. If it
  does not close the gap, the gap is `tried` and work on it stops.
- **A change counts** only when it beats the noise floor in a repeat and has a named cause
  (example: `src/aligned.zig`, 26 rows past the noise floor, all 16-wide loops on cached data).

State on 2026-11-27: job medians 0.98-1.03, overall 1.00. D6 `std` and D7 `sort` at
10,000 are `tried`. One row is open: S6 `gpu+transfer` at 2^27, 0.79x. That is the GPU download
path, the same gap as zstrata's `link/download` item (1.14x), and it is worked on there. When that
item is closed or `tried`, the Linux work here is finished.

## Decisions (owner, 2026-11-19)

1. **Z1, the `profile` export in zstrata: open.** Not decided yet. B0 does not need it: it reads
   the few facts it uses from zstrata's existing results file.
2. **Sharing code: decided.** zstrata is used as a reference or library. zstrata-bench depends on
   it as a Zig package for the Vulkan layer and thread pool; nothing is copied.
3. **First slice: decided.** Data processing.
4. **Visibility: decided, public.** Nothing private goes into this repo. Every input is a generated
   example (seeded, synthetic): no real datasets, no competition data, no file paths or names from
   the owner's other work, no credentials. Results describe one machine by its hardware only.

## Risks

- **Measuring the wrong thing.** A small job can behave differently inside a real program. Mitigation:
  sizes span cache levels, and results state the size band they hold for.
- **One machine.** Every number is this PC's. The profile file is what would let results be
  compared across machines later; nothing here claims they transfer.
- **Scope creep.** New jobs are added only when real work raises the question. The list above is
  the ceiling for now, not a promise.
- **Stale results.** A Zig or driver update can change answers. Each result records the Zig
  version, driver version and profile it was measured with, and `check` reports which are out of date.
