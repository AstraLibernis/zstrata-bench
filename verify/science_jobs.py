# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 AstraLibernis
#
# Outside checks for the data-science jobs S1 to S6: NumPy rebuilds the same input, does the job
# its own way, and the answer is compared with `zstrata-bench answer <job> <n>`.
# Usage: python verify/science_jobs.py <job> <n> <answer>
import math
import sys

import numpy as np

from common import report, unit


def s1(n):
    if n == 0:
        return 0.0
    x = unit(n, 11)
    d = x.astype(np.float64)
    mean = d.sum() / n
    return float(mean + ((d * d).sum() / n - mean * mean) + float(x.min()) + float(x.max()))


def s2(n):
    bins = (unit(n, 12) * np.float32(256)).astype(np.int64)
    counts = np.bincount(bins, minlength=256)
    return float((counts * np.arange(1, 257)).sum())


def s3(n):
    if n == 0:
        return 0.0
    s = np.sort(unit(n, 13))
    return float(sum(float(s[(n - 1) * p // 100]) for p in (1, 25, 50, 75, 99)))


def s4(n):
    if n < 2:
        return 0.0
    cols = [unit(n, 20 + c) for c in range(8)]
    for c in range(1, 8):
        cols[c] = cols[c] + np.float32(c * 0.125) * cols[0]  # float32 arithmetic, as in the job
    x = np.stack(cols, axis=1).astype(np.float64)
    r = np.corrcoef(x, rowvar=False)
    return float(r[np.triu_indices(8, 1)].sum())


def s5(n):
    points = math.isqrt(n)
    if points < 2:
        return 0.0
    x = np.stack([unit(points, 30 + d) for d in range(8)], axis=1)
    total = 0.0
    for lo in range(0, points, 512):  # in pieces, to keep the pair table small
        diff = x[lo : lo + 512, None, :] - x[None, :, :]
        d2 = (diff * diff).sum(axis=2)
        d2[np.arange(len(d2)), np.arange(lo, lo + len(d2))] = np.inf
        total += float(d2.min(axis=1).astype(np.float64).sum())
    return total


def s6(n):
    side = round(n ** (1.0 / 3.0))
    a = unit(side * side, 40).reshape(side, side)
    b = unit(side * side, 41).reshape(side, side)
    return float((a @ b).sum(dtype=np.float64))


job, n, theirs = sys.argv[1], int(float(sys.argv[2])), float(sys.argv[3])
jobs = {
    "S1": (s1, 1e-9),
    "S2": (s2, 0.0),
    "S3": (s3, 0.0),
    "S4": (s4, 1e-9),
    "S5": (s5, 1e-5),
    "S6": (s6, 1e-4),  # NumPy's library adds each element's terms in another order
}
run, tolerance = jobs[job]
sys.exit(0 if report(f"{job} n={n}", run(n), theirs, tolerance) else 1)
