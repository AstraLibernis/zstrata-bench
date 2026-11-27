#!/usr/bin/env python3
"""cmp_machines.py A B [--min 1.10]: every saved measurement of machine A against the same one of
machine B (results/<machine>/<job>/<variant>__<n>.tsv). ratio = A's rate / B's rate, so below 1
means A is slower. Prints a per-job summary, then the rows outside 1/min .. min whose spreads do
not explain the difference, then where the best variant differs between the two machines."""
import sys, os, csv, glob, statistics as st, collections
a, b = sys.argv[1], sys.argv[2]
lim = float(sys.argv[sys.argv.index('--min') + 1]) if '--min' in sys.argv else 1.10
def load(m):
    d = {}
    for f in glob.glob(f'results/{m}/*/*.tsv'):
        for r in csv.DictReader(open(f), delimiter='\t'):
            d[(r['job'], r['variant'], int(r['n']))] = (float(r['items_per_s']), float(r['spread']))
    return d
A, B = load(a), load(b)
both = sorted(k for k in A if k in B)
print(f"{a}: {len(A)} measurements, {b}: {len(B)}, in both: {len(both)}")
byjob = collections.defaultdict(list)
for k in both: byjob[k[0]].append(A[k][0] / B[k][0])
print(f"\n== per job: {a} rate / {b} rate (median, min..max)")
for j, v in sorted(byjob.items(), key=lambda kv: st.median(kv[1])):
    print(f"{j:5} {st.median(v):5.2f}  {min(v):5.2f}..{max(v):5.2f}  n={len(v)}")
print(f"\n== rows where {a} is under 1/{lim} or over {lim} of {b} (beyond both spreads)")
rows = []
for k in both:
    r = A[k][0] / B[k][0]
    if (r < 1 / lim or r > lim) and abs(r - 1) > A[k][1] + B[k][1]: rows.append((r, k))
for r, k in sorted(rows):
    print(f"{r:6.2f}x  {k[0]:5} {k[1]:16} n={k[2]:<11} {a} {A[k][0]:10.4g}/s  {b} {B[k][0]:10.4g}/s")
print("\n== best variant differs")
best = lambda M, j, n: max(((v, M[(jj, v, nn)][0]) for (jj, v, nn) in M if jj == j and nn == n), key=lambda t: t[1])
for j, n in sorted({(k[0], k[2]) for k in both}):
    (va, ra), (vb, rb) = best(A, j, n), best(B, j, n)
    if va != vb: print(f"{j:5} n={n:<11} {a}: {va} {ra:.4g}/s   {b}: {vb} {rb:.4g}/s   ({a}'s rate with {vb}: {A.get((j, vb, n), (float('nan'),))[0]:.4g})")
