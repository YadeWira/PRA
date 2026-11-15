#!/usr/bin/env python3
"""Single-bit flips in the compressed file, as PJA's safety table counts them:
for each tool, each input is compressed once; then N flips per file, each on
a fresh copy, decompressed; a flip that gives back a file different from the
original WITHOUT an error (exit 0 and an output there) is counted.

    flips.py <pra> <packPNM> <in dir> <work dir> <flips per file>
"""
import os, random, shutil, subprocess, sys
from concurrent.futures import ThreadPoolExecutor

pra, ppn, ind, work, per = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5])
files = sorted(os.listdir(ind))
os.makedirs(work, exist_ok=True)
rnd = random.Random(20261115)


def compress(tool, name):
    d = os.path.join(work, tool, name)
    shutil.rmtree(d, ignore_errors=True); os.makedirs(d)
    src = os.path.join(d, 'x' + os.path.splitext(name)[1])
    shutil.copy(os.path.join(ind, name), src)
    if tool == 'pra':
        subprocess.run([pra, 'a', '-q', '-th', '1', src, '-o', os.path.join(d, 'c.pra')], capture_output=True)
        out = os.path.join(d, 'c.pra')
    else:
        subprocess.run([ppn, '-np', os.path.basename(src)], cwd=d, capture_output=True, stdin=subprocess.DEVNULL)
        out = os.path.join(d, 'x.prw')
    return out if os.path.exists(out) else None


def trial(tool, name, comp, k, bit):
    d = os.path.join(work, tool, name, 't%d' % k)
    shutil.rmtree(d, ignore_errors=True); os.makedirs(d)
    b = bytearray(open(comp, 'rb').read())
    b[bit // 8] ^= 1 << (bit % 8)
    c = os.path.join(d, os.path.basename(comp))
    open(c, 'wb').write(b)
    if tool == 'pra':
        out = os.path.join(d, 'back')
        r = subprocess.run([pra, 'x', '-q', '-th', '1', c, '-o', out], capture_output=True)
    else:
        r = subprocess.run([ppn, '-np', os.path.basename(c)], cwd=d, capture_output=True, stdin=subprocess.DEVNULL)
        outs = [x for x in os.listdir(d) if x != os.path.basename(c)]
        out = os.path.join(d, outs[0]) if outs else None
    wrong = False
    if r.returncode == 0 and out and os.path.exists(out):
        wrong = open(out, 'rb').read() != open(os.path.join(ind, name), 'rb').read()
    shutil.rmtree(d, ignore_errors=True)
    return wrong


for tool in ('pra', 'packPNM'):
    jobs = []
    taken = 0
    for name in files:
        comp = compress(tool, name)
        if not comp: continue
        taken += 1
        n = os.path.getsize(comp) * 8
        for k in range(per):
            jobs.append((tool, name, comp, k, rnd.randrange(n)))
    with ThreadPoolExecutor(32) as ex:
        res = list(ex.map(lambda j: trial(*j), jobs))
    print(tool, 'files', taken, 'flips', len(jobs), 'wrong without an error', sum(res))
