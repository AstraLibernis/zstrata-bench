# `zstrata-bench time`: timing whole programs

`run` measures a job's variants inside this program. `time` measures any program from outside,
the way [hyperfine](https://github.com/sharkdp/hyperfine) does: it starts the command many
times and reports mean ± σ, min … max, and a comparison with the first command. It takes
hyperfine 2.0's options under the same names, writes hyperfine's JSON layout, and adds what
hyperfine cannot read on Windows: the peak memory of the process and of the whole process tree.

It is a command like the others: it runs, prints, writes its files and exits.

```sh
zstrata-bench time 'prog --fast' 'prog --slow'                  # compare two commands
zstrata-bench time -w 3 -r 30 --export-json out.json 'prog'     # fixed runs, keep every run
zstrata-bench time --metrics all 'cmd /c "build.bat"'           # time, memory, faults, I/O
zstrata-bench time -L threads 1,8,16 'prog -j {threads}'        # one benchmark per value
zstrata-bench time --help                                       # every option
```

## What it measures

| Metric | What | Windows | Linux |
|---|---|---|---|
| `time_wall_clock` | start of the process to its end | yes | yes |
| `time_cpu` | user + system | yes, whole tree | yes, child and the children it waited for |
| `time_user`, `time_system` | CPU time split | yes, whole tree | yes |
| `memory_peak_resident` | peak memory of the started process itself (working set / max RSS) | yes | yes |
| `memory_peak_commit` | peak committed memory of the whole process tree | yes | no |
| `page_faults` | page faults | yes, whole tree | yes (minor + major) |
| `processes` | processes started, the command included | yes | no |
| `io_read_bytes`, `io_write_bytes` | bytes read and written, files and devices | yes, whole tree | no |

On Windows each run starts suspended, joins a new job object and is then let go, so even the
first child process it starts is counted. That is where the tree numbers come from.
`memory_peak_resident` is the started process alone: when the command is a launcher
(`cmd /c ...`, a venv's `python.exe`) the real work is in a child, and only
`memory_peak_commit` sees it.

Windows counts CPU time in scheduler ticks, so `time_cpu`, `time_user` and `time_system` move in
steps of about 15.6 ms and say little about runs shorter than half a second.

Hardware counters (cycles, instructions, cache misses, branch misses) need `perf` on Linux or
administrator rights on Windows. They are not offered.

`--metrics` takes a preset or a list. The first metric listed is the *primary*: it drives the
tables and the first-run warning. Every row on the terminal is compared with the first command.

| Preset | Metrics |
|---|---|
| `default` | wall time, peak memory of the process |
| `time` | wall, CPU, user, system |
| `memory` | peak memory of the process, peak commit of the tree, page faults |
| `all` | everything this OS reports |

Units: time `ns us ms s min h`; memory `B kB MB GB TB KiB MiB GiB TiB`; counts
`count k M B`. Example: `--metrics memory_peak_commit:MiB,time_wall_clock:ms`. Without a unit,
the one that suits the first command's mean is used for every command.

## How many runs

- `-w N` untimed warm-up runs first (default 0).
- `-r N` exactly N runs, or automatic: at least `-m` (default 10) and enough to fill about 3 s,
  at most `-M` if given. The first timed run sets the estimate; `--prepare` and `--conclude`
  time counts against the 3 s.

## Options

Every hyperfine 2.0 option, the same names. `zstrata-bench time --help` prints them all.

| Option | Meaning |
|---|---|
| `-w/--warmup`, `-m/--min-runs`, `-M/--max-runs`, `-r/--runs` | run counts, above |
| `--metrics` | above |
| `-N` (default), `-S`, `--shell SHELL` | start directly, through cmd.exe/sh, or through any shell (`"bash --norc"`) |
| `--env 'A=1 B="x y"'` | environment additions |
| `--input null\|FILE` | stdin |
| `--output null\|pipe\|inherit\|FILE`, `--show-output` | where stdout and stderr go |
| `-i`, `--ignore-failure[=all-non-zero\|CODES]` | keep runs with non-zero exit codes |
| `-s/--setup`, `-p/--prepare`, `-C/--conclude`, `-c/--cleanup` | hooks: once before, before each run, after each run, once after |
| `-P VAR MIN MAX`, `-D STEP`, `-L VAR a,b,c` | parameters; `{VAR}` is replaced in commands, names, hooks and `--env` |
| `-n/--command-name` | labels, one per command in order |
| `--style auto\|basic\|full\|nocolor\|color\|none` | `none` prints nothing; the others print the same plain text |
| `--export-json`, `--export-csv`, `--export-markdown`, `--export-asciidoc`, `--export-orgmode` | files |

Rules that hold throughout:

- Without a shell, a command that contains `| & ; < >`, a backtick or `$(` outside quotes is
  refused, as in hyperfine 2.0: add `-S` or quote the character.
- Hooks always run through a shell (the chosen one, else cmd.exe / sh). A hook that fails stops
  everything, as does a benchmarked command that exits non-zero without `-i`.
- With a shell, its own start-up is measured first (the mean of 50 runs of an empty command)
  and subtracted from the time metrics of every run. Memory and counts are not adjusted. A
  command faster than 5 ms through a shell gets a warning.
- A first run far above the rest is reported: more than ten normal-consistent MADs
  (1.4826 × 10) above the median of the primary metric, hyperfine's rule.
- Several parameters combine in the order given; the last one changes fastest. Commands are the
  innermost loop: `-L x 1,2 A B` runs A(1), B(1), A(2), B(2).

## Where it differs from hyperfine 2.0

| | hyperfine 2.0 | `zstrata-bench time` |
|---|---|---|
| Memory on Windows | not available | process peak, tree peak commit, faults, processes, I/O bytes |
| Exit codes on Windows | | the full 32-bit code (a crash shows as -1073741819, not 5) |
| Splitting a command without a shell | POSIX rules, a backslash escapes | quotes group words, a backslash is an ordinary character, so `C:\x\y` works |
| `--env`, `--prepare`, `--conclude`, `--output` per command | placed before each command | given once (for every command) or once per command, in command order |
| `--output pipe` | | stdout goes through the pipe, stderr is discarded |
| Hardware counters | Linux (`perf`) | none |
| Colours, progress bar | yes | plain text only |
| Markdown/AsciiDoc/Org tables | mean ± σ, change, factor | adds min and max columns |
| `--metrics memory` preset | no | yes |

The JSON is hyperfine's schema 2: per command, `measurements[]` with one `{value, unit}` per
metric and `exit_code` (null after a signal), `parameters`, and `summary.<metric>.{unit, count,
mean, stddev, median, min, max}` in base units (second, byte, count). `stddev` is null for one
run. Read a metric by its name, never by position. A script reading hyperfine 2.0's JSON reads
this one unchanged.

## Checked against hyperfine

[MEASURED] 2026-11-23, Ryzen 7 9800X3D, Windows 11, both tools `-N -w 3 -r 30`, alternating
three rounds, wall-time mean ± σ:

| Command | hyperfine 2.0.0 | zstrata-bench time |
|---|---|---|
| `cmd /c exit` | 5.99 ± 0.09, 5.99 ± 0.09, 6.14 ± 0.38 ms | 6.06 ± 0.16, 6.06 ± 0.10, 6.04 ± 0.08 ms |
| `powershell -NoProfile -c 1` | 109.79 ± 1.48, 110.32 ± 4.05, 109.69 ± 1.45 ms | 109.02 ± 0.95, 110.72 ± 3.45, 110.12 ± 1.41 ms |

[DERIVED] The two agree within one σ in every pair. The gap is at most 0.07 ms and changes sign
between rounds.

[MEASURED] `cmd /c "powershell -NoProfile -c 1"`, 10 runs, `--metrics all`: peak memory of
`cmd` itself 8.0 MiB, peak commit of the tree 59.1 MiB, 2 processes. A per-process probe
reports the 8 MiB; the PowerShell child that does the work is only in the tree figure.
