# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 AstraLibernis
#
# Outside checks for the data-processing jobs D2 to D7: NumPy rebuilds the same input, does the
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


def d6(n):
    # No text is built: field k has 1 + mix(k) % 8 digits and is followed by one delimiter, so
    # the delimiter after field k sits at (sum of lengths up to k) + k.
    if n == 0:
        return 0.0
    fields = np.arange(n, dtype=np.uint64)  # more fields than could ever fit in n bytes
    lengths = (mix(fields) % np.uint64(8) + np.uint64(1)).astype(np.int64)
    positions = np.cumsum(lengths) + np.arange(n, dtype=np.int64)
    positions = positions[positions < n]
    a = float(len(positions))
    if len(positions):
        a += float(positions[0]) + float(positions[len(positions) // 2]) + float(positions[-1])
    return a


def d7(n, distinct):
    different = np.unique(keys(n, 8, distinct))
    return float(len(different)) + float((different % np.uint64(1009) + np.uint64(1)).sum())


job, n, theirs = sys.argv[1], int(float(sys.argv[2])), float(sys.argv[3])
jobs = {
    "D2": (lambda: d2(n, 0.5), 1e-12),
    "D2s": (lambda: d2(n, 0.01), 1e-12),
    "D3": (lambda: d3(n), 0.0),
    "D4": (lambda: d4(n, max(1, min(1000, n))), 1e-9),
    "D4m": (lambda: d4(n, max(1, min(100_000, n))), 1e-9),
    "D4h": (lambda: d4(n, max(1, n // 4)), 1e-9),
    "D5": (lambda: d5(n), 1e-9),
    "D6": (lambda: d6(n), 0.0),
    "D7": (lambda: d7(n, max(1, min(1000, n))), 0.0),
    "D7u": (lambda: d7(n, max(1, n // 2)), 0.0),
}
run, tolerance = jobs[job]
sys.exit(0 if report(f"{job} n={n}", run(), theirs, tolerance) else 1)
