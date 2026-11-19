# zstrata-bench

Which way of writing a job uses this machine best, measured.

[zstrata](https://github.com/AstraLibernis/zstrata) maps the hardware that exists and its limits.
zstrata-bench takes the recurring jobs in data processing, data science and model learning, writes
each several ways, and measures which way uses that hardware best, so that "should this be written
this way or that way?" is looked up instead of guessed.

- Plan and progress: [`docs/PLAN.md`](docs/PLAN.md)
- How to work on it and add a job: [`docs/GUIDE.md`](docs/GUIDE.md)
- Numbers and what they mean: [`docs/measurements.md`](docs/measurements.md)

Status: the harness, the data-processing jobs D1 to D5, the data-science jobs S1 to S6 and the
lookup are done.

```sh
zig build test                                             # every variant against its reference
zig build -Doptimize=ReleaseFast
zig-out/bin/zstrata-bench list                             # jobs and what each variant changes
zig-out/bin/zstrata-bench run D1 --quick                   # seconds: checks the path
zig-out/bin/zstrata-bench run D1                           # measure; each result is saved as it finishes
zig-out/bin/zstrata-bench check                            # what is saved, stale or missing
zig-out/bin/zstrata-bench look group total --rows 1e7      # the measured answer for a job
zig-out/bin/zstrata-bench map                              # all answers to map/<machine>.tsv
```

Needs Zig 0.17.x. zstrata is fetched as a package by the build; its thread pool is
used as a library. All inputs are generated examples; the repository holds no real data.

GPL-3.0-or-later. See `COPYING`.
