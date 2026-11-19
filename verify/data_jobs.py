# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 AstraLibernis
#
# Outside checks for the data-processing jobs D2 to D5: NumPy rebuilds the same input, does the
# job its own way, and the answer is compared with `zstrata-bench answer <job> <n>`.
# Usage: python verify/data_jobs.py <job> <n> <answer>
import sys

import numpy as np

from common import keys, mix, mixed, report, unit


def d2(n, threshold):
    xs = unit(n, 12345)
    kept = xs[xs < np.float32(threshold)]
    a = float(len(kept))
    if len(kept):
        a += float(kept[0])
        a += float(kept[len(kept) // 2])
        a += float(kept[-1])
    return a


def d3(n):
    s = np.sort(mixed(n, 2))
    return float(s[0]) + float(s[n // 3]) + float(s[n // 2]) + float(s[n - 1]) if n else 0.0


def d4(n, groups):
    k = keys(n, 3, groups)
    v = unit(n, 4).astype(np.float64)
    distinct, which = np.unique(k, return_inverse=True)
    totals = np.bincount(which, weights=v, minlength=len(distinct))
    return float(len(distinct)) + float((totals * (distinct % np.uint64(1009) + np.uint64(1)).astype(np.float64)).sum())


def d5(n):
    m = max(1, n // 10)
    small_keys = mix(np.arange(m, dtype=np.uint64))
    payloads = unit(m, 5).astype(np.float64)
    large_keys = keys(n, 6, 2 * m)
    values = unit(n, 7).astype(np.float64)
    order = np.argsort(small_keys)
    sorted_keys = small_keys[order]
    at = np.searchsorted(sorted_keys, large_keys)
    at[at == m] = 0
    hit = sorted_keys[at] == large_keys
    return float(hit.sum()) + float((values[hit] * payloads[order[at[hit]]]).sum())


job, n, theirs = sys.argv[1], int(float(sys.argv[2])), float(sys.argv[3])
jobs = {
    "D2": (lambda: d2(n, 0.5), 1e-12),
    "D2s": (lambda: d2(n, 0.01), 1e-12),
    "D3": (lambda: d3(n), 0.0),
    "D4": (lambda: d4(n, max(1, min(1000, n))), 1e-9),
    "D4m": (lambda: d4(n, max(1, min(100_000, n))), 1e-9),
    "D4h": (lambda: d4(n, max(1, n // 4)), 1e-9),
    "D5": (lambda: d5(n), 1e-9),
}
run, tolerance = jobs[job]
sys.exit(0 if report(f"{job} n={n}", run(), theirs, tolerance) else 1)
