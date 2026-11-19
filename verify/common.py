# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 AstraLibernis
#
# The input generators of src/data.zig, repeated with NumPy so the outside checks see exactly
# the same data.
import numpy as np

A, C = 1664525, 1013904223
MASK = np.uint64(0xFFFFFFFF)


def states(n, seed):
    """The first n states of the generator after `seed` (data.next), as uint64 below 2^32."""
    if n == 0:
        return np.zeros(0, dtype=np.uint64)
    # state_k = A^k * seed + C * (A^(k-1) + ... + 1), modulo 2^32. Wrapping modulo 2^64 and then
    # masking is the same as working modulo 2^32 throughout.
    mult = np.full(n, A, dtype=np.uint64)
    mult[0] = 1
    a_pow = np.multiply.accumulate(mult) & MASK  # A^0 .. A^(n-1)
    geo = np.add.accumulate(a_pow) & MASK  # 1 + A + ... + A^k
    return (((a_pow * np.uint64(A)) & MASK) * np.uint64(seed) + geo * np.uint64(C)) & MASK


def unit(n, seed):
    """data.fillUnit: float32 values in [0, 1)."""
    return (states(n, seed) >> np.uint64(8)).astype(np.float32) / np.float32(16777216.0)


def mix(x):
    """data.mix on an array of uint64 values below 2^32."""
    x = x ^ (x >> np.uint64(16))
    x = (x * np.uint64(0x85EBCA6B)) & MASK
    x = x ^ (x >> np.uint64(13))
    x = (x * np.uint64(0xC2B2AE35)) & MASK
    return x ^ (x >> np.uint64(16))


def mixed(n, seed):
    """data.fillMixed: scrambled 32-bit values (as uint64 below 2^32)."""
    return mix(states(n, seed))


def keys(n, seed, distinct):
    """data.fillKeys: keys drawn from `distinct` scrambled values."""
    return mix(mixed(n, seed) % np.uint64(distinct))


def report(name, ours, theirs, tolerance):
    ok = abs(ours - theirs) <= tolerance * max(1.0, abs(ours))
    print(f"{name}: NumPy {ours!r}  zstrata-bench {theirs!r}  {'AGREE' if ok else 'DIFFER'}")
    return ok


def byte_values(n, seed):
    """data.fillBytes: the low 8 bits of each scrambled value."""
    return (mixed(n, seed) & np.uint64(0xFF)).astype(np.int64)
