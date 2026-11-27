# First Linux run, stopping point (2026-11-27)

Fedora 45, kernel 7.3.6, same machine as the Windows results. Stopped mid-comparison; nothing
here is a conclusion yet.

## What is in this branch

- `src/aligned.zig`, used from `src/main.zig`: every allocation on a cache-line boundary
  (`ZSB_PLAIN_ALLOC=1` turns it off). Reason: with libc linked the allocator is glibc `malloc`,
  whose big blocks start 16 bytes into a cache line (proven in zstrata, docs/measurements.md,
  "Linux gaps").
- `tools/cmp_machines.py A B`: every saved measurement of one results folder against another.
- `results/linux-plain`, `results/linux-plain2`: two full runs with the plain allocator.
  `results/linux-aligned`: one full run with the aligning allocator. Folder names are not
  machine ids, so `look` and `map` do not read them; they are inputs for the comparison.
- `map/znver5-16t-linux.tsv`: written from the first plain run. To be replaced.
- Not in the branch: `results/znver5-16t-linux`, left as a mix of two configurations by an
  interrupted run. Rerun `run D`, `run S`, `run M`, `run V` with `--force` before using it.

## What the first run says (single runs) [MEASURED]

- Median Linux / Windows rate per job: 0.92 to 1.03. A full pass takes about 3 minutes.
- Linux ahead on many `threads8` rows, 1.15x to 2.1x. Cause not tested.
- Linux behind, 0.70x to 0.85x, on 16-wide vector loops over small or cache-resident data:
  V1 and V2 at n=1000, M4 `dot16`, M5 `rowbyrow16` / `tiled` / `weightfirst`, S6 `lanes16` /
  `fused`, S2 `bins16`, S3 `histogram` at 10,000, D2s `mask16`.
- Aligned against plain, one run each: M4 and M5 medians +6%, single rows up to 1.5x (V2,
  S6 `fused`, M4 `dot16`). A few rows read 0.75x to 0.87x (D2s `threads8` and `branch`,
  D6 `std`, D7 `threads16`, D3 `radix11`); whether that is noise is not known.
- GPU variants, default power settings, screen off: S6 `gpu` at n=2^30 0.61x, S5 `gpu` 0.84x,
  `gpu+transfer` 0.70x to 0.82x; M6 `gpu` 1.7x to 2.4x and M4 `gpu` at n=64 2.05x ahead. The
  GPU's clocks follow load slowly on Linux (zstrata playbook rules 16 and 18); not rerun
  under zstrata's custom power profile.
- Windows has 3 V2 `suggestedx4` measurements the Linux build does not produce. Not looked at.

## Next

1. Plain and aligned twice each; compare only what holds in both repeats and exceeds the
   plain-against-plain noise. Decide whether the aligning allocator stays.
2. Rerun, write `map/znver5-16t-linux.tsv`, add a Linux section to `docs/measurements.md`.
3. GPU variants under the custom power profile (`zstrata/tools/linux/fullruns.sh` shows how
   it is set and restored).
