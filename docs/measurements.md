# Measurements and what they mean

Every number here comes from the files under `results/` and is tagged:
[MEASURED] read from a run, [DERIVED] reasoned from measured numbers.

Machine `znver5-16t-windows`: Ryzen 7 9800X3D (8 cores, 16 threads, AVX-512), Windows 11,
Zig 0.17.1, ReleaseFast, native CPU target.

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
