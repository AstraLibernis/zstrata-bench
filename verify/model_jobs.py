# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 AstraLibernis
#
# Outside checks for the model-learning jobs M1 to M6: NumPy rebuilds the same input, does the
# job its own way, and the answer is compared with `zstrata-bench answer <job> <n>`.
# Usage: python verify/model_jobs.py <job> <n> <answer>
import sys

import numpy as np

from common import byte_values, mix, report, unit

F32 = np.float32


def m1(n):
    g = (unit(n, 60) - F32(0.5)).astype(np.float64)
    h = unit(n, 61).astype(np.float64)
    weights = np.arange(1, 257, dtype=np.float64)
    total = 0.0
    for f in range(8):
        b = byte_values(n, 50 + f)
        sum_g = np.bincount(b, weights=g, minlength=256)
        sum_h = np.bincount(b, weights=h, minlength=256)
        total += (f + 1) * float((weights * (sum_g + sum_h * 0.5)).sum())
    return total


def m2(n):
    if n == 0:
        return 0.0
    g = unit(n * 256, 70).astype(np.float64).reshape(n, 256) - 0.5
    h = unit(n * 256, 71).astype(np.float64).reshape(n, 256) + 0.01
    gl = np.cumsum(g, axis=1)
    hl = np.cumsum(h, axis=1)
    gt, ht = gl[:, -1:], hl[:, -1:]
    values = (gl * gl / (hl + 1.0) + (gt - gl) ** 2 / ((ht - hl) + 1.0))[:, :255]
    best = values.argmax(axis=1)  # the first largest, as in the job
    return float((values[np.arange(n), best] + best).sum())


def m3(n):
    rows = unit(n * 8, 90).reshape(n, 8)
    pred = np.zeros(n, dtype=F32)
    r = np.arange(n)
    for t in range(100):
        base = np.uint64(1000 * t)
        tests = np.arange(63, dtype=np.uint64)
        feat = (mix(base + tests) & np.uint64(7)).astype(np.int64)
        thr = (mix(base + tests + np.uint64(500_000)) >> np.uint64(8)).astype(F32) / F32(16777216.0)
        leaf_ids = np.arange(64, dtype=np.uint64)
        leaf = (mix(base + leaf_ids + np.uint64(900_000)) >> np.uint64(8)).astype(F32) / F32(16777216.0) - F32(0.5)
        i = np.zeros(n, dtype=np.int64)
        for _ in range(6):
            i = 2 * i + 1 + (rows[r, feat[i]] > thr[i])
        pred += leaf[i - 63]  # float32 running sum per row, in tree order
    return float(pred.astype(np.float64).sum())


def m4(n):
    x = (unit(n * 256, 100) - F32(0.5)).reshape(n, 256)
    w = ((unit(256 * 256, 101) - F32(0.5)) * F32(0.125)).reshape(256, 256)
    bias = unit(256, 102) - F32(0.5)
    return float(np.maximum(x @ w.T + bias, 0).sum(dtype=np.float64))


def m5(n):
    x = (unit(n * 256, 110) - F32(0.5)).reshape(n, 256)
    dy = (unit(n * 256, 111) - F32(0.5)).reshape(n, 256)
    w0 = ((unit(256 * 256, 112) - F32(0.5)) * F32(0.125)).reshape(256, 256)
    return float((w0 - F32(0.01) * (dy.T @ x)).sum(dtype=np.float64))


def m6(n):
    if n == 0:
        return 0.0
    w = unit(n, 120) - F32(0.5)
    m = (unit(n, 121) - F32(0.5)) * F32(0.1)
    v = unit(n, 122) * F32(0.01)
    g = unit(n, 123) - F32(0.5)
    b1, b2 = F32(0.9), F32(0.999)
    r1, r2 = F32(1.0) - b1, F32(1.0) - b2
    m2 = b1 * m + r1 * g
    v2 = b2 * v + r2 * g * g
    w2 = w - F32(0.001) * m2 / (np.sqrt(v2) + F32(1e-8))
    total = 0.0
    for a in (w2, m2, v2):
        total += float(a[::97].astype(np.float64).sum()) + float(a[-1])
    return total


job, n, theirs = sys.argv[1], int(float(sys.argv[2])), float(sys.argv[3])
jobs = {
    "M1": (m1, 1e-9),
    "M2": (m2, 1e-9),
    "M3": (m3, 1e-9),
    "M4": (m4, 1e-4),  # NumPy's library adds each output's products in another order
    "M5": (m5, 1e-4),
    "M6": (m6, 1e-6),
}
run, tolerance = jobs[job]
sys.exit(0 if report(f"{job} n={n}", run(n), theirs, tolerance) else 1)
