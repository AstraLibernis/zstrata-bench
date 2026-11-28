#!/usr/bin/env python3
"""ceiling.py [LINUX] [WINDOWS]: is the Linux work at its ceiling target (docs/PLAN.md, "Ceiling
target")? Defaults: results/znver5-16t-linux against results/znver5-16t-windows.
Exit 0 = target met, 1 = open gaps remain.

A row is a GAP when Linux's rate is under ROW_LIM of Windows' and the difference is beyond both
saved spreads. ROW_LIM comes from noise: two identical plain Linux runs (results/linux-plain,
linux-plain2) differ by up to 0.88-1.18x on 95% of rows (2026-11-27), so 0.85 is the smallest gap
one run can show. A job is a GAP when its median ratio is under JOB_LIM. A gap is accepted when
docs/ceiling-exceptions.tsv names it with a cause outside the code (power, driver, permission) or
as `tried` (one bounded experiment recorded in docs/measurements.md did not close it).
Rows where Linux is ahead are never work items."""
import sys, os, csv, glob, fnmatch, statistics as st, collections
ROW_LIM, JOB_LIM = 0.85, 0.95
OUTSIDE = {'power', 'driver', 'permission', 'tried'}
root = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
lin = sys.argv[1] if len(sys.argv) > 1 else 'znver5-16t-linux'
win = sys.argv[2] if len(sys.argv) > 2 else 'znver5-16t-windows'
def load(m):
    d = {}
    for f in glob.glob(f'{root}/results/{m}/*/*.tsv'):
        for r in csv.DictReader(open(f), delimiter='\t'):
            d[(r['job'], r['variant'], r['n'])] = (float(r['items_per_s']), float(r['spread']))
    return d
L, W = load(lin), load(win)
exc = [r for r in csv.reader(open(f'{root}/docs/ceiling-exceptions.tsv'), delimiter='\t')
       if r and not r[0].startswith('#')]
def accepted(name):
    for pat, cause, why in exc:
        if fnmatch.fnmatch(name, pat): return cause, why
both = sorted(k for k in L if k in W)
if not both: sys.exit(f"no shared measurements between {lin} and {win}")
jobs = collections.defaultdict(list); rows = []
for k in both:
    r = L[k][0] / W[k][0]; jobs[k[0]].append(r)
    if r < ROW_LIM and abs(r - 1) > L[k][1] + W[k][1]: rows.append((r, k))
print(f"{lin}: {len(L)}, {win}: {len(W)}, shared {len(both)}; "
      f"median Linux/Windows {st.median(r for v in jobs.values() for r in v):.3f}")
open_ = set()
def show(name, text):
    a = accepted(name)
    if a is None or a[0] not in OUTSIDE: open_.add(name)
    print(f"{text} {name:34} {('ACCEPTED ' + a[0] + ': ' + a[1]) if a else 'OPEN'}")
print(f"\n== jobs with median under {JOB_LIM}")
for j, v in sorted(jobs.items(), key=lambda kv: st.median(kv[1])):
    if st.median(v) < JOB_LIM: show(j, f"{st.median(v):5.2f}x n={len(v):<3}")
print(f"\n== rows under {ROW_LIM}x beyond both spreads: {len(rows)}")
for r, k in sorted(rows): show('/'.join(k), f"{r:5.2f}x")
print(f"\nceiling target: {'MET' if not open_ else f'NOT MET, {len(open_)} open item(s)'}")
sys.exit(bool(open_))
