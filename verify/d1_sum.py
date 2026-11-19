# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 AstraLibernis
#
# Outside check for job D1 (add up a column): NumPy rebuilds the same input and adds it up.
# Usage: python verify/d1_sum.py <n> <answer printed by `zstrata-bench answer D1 <n>`>
import sys

import numpy as np

n = int(float(sys.argv[1]))
theirs = float(sys.argv[2])

# data.fillUnit, seed 12345: state_k = A^k * seed + C * (A^(k-1) + ... + 1), modulo 2^32.
# 64-bit wrap-around followed by a mask is the same as working modulo 2^32 throughout.
A, C, SEED = 1664525, 1013904223, 12345
mult = np.full(n, A, dtype=np.uint64)
mult[0] = 1
a_pow = np.multiply.accumulate(mult) & 0xFFFFFFFF  # A^0 .. A^(n-1)
geo = np.add.accumulate(a_pow) & 0xFFFFFFFF  # 1 + A + ... + A^k
state = ((a_pow * np.uint64(A) & 0xFFFFFFFF) * np.uint64(SEED) + geo * np.uint64(C)) & 0xFFFFFFFF
values = (state >> np.uint64(8)).astype(np.float32) / np.float32(16777216.0)

ours = float(values.sum(dtype=np.float64))
ok = abs(ours - theirs) <= 1e-9 * max(1.0, abs(ours))
print(f"NumPy {ours!r}  zstrata-bench {theirs!r}  {'AGREE' if ok else 'DIFFER'}")
sys.exit(0 if ok else 1)
