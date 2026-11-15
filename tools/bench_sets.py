#!/usr/bin/env python3
"""PRA against general-purpose compressors (and packPNM on Netpbm/BMP/HDR),
file by file, on the corpus copies under 20 MB. Each tool's whole output
against the set's input; a file a tool does not take, or that does not
come back byte for byte, counts at its own size. PRA: pra a -th 1, then
pra x, compared. xz -9e, zstd -19 --long=27: always come back.

    bench_sets.py <pra> <packPNM> <corpus dir> <work dir> > table
"""
import os, shutil, subprocess, sys, time
from concurrent.futures import ThreadPoolExecutor

pra, ppn, corpus, work = sys.argv[1:5]
SETS = [
    ('Netpbm (PBM, PGM, PPM, PAM, PFM)', ['pbm', 'pgm', 'ppm', 'pam', 'pfm']),
    ('BMP', ['bmp']),
    ('Radiance HDR', ['hdr']),
    ('TIFF and BigTIFF', ['tiff', 'bigTIFF']),
    ('PSD', ['psd']),
    ('film and science (DPX, Cineon, FITS, VICAR, DICOM, OpenEXR)', ['dpx', 'cin', 'fits', 'vicar', 'dicom', 'exr']),
    ('IFF, MIFF, XCF, PICT', ['iffILBM', 'miff', 'xcf', 'pict']),
    ('the rest (TGA, PCX, SGI, Sun, ICO, DDS, XWD, ...)', ['tga', 'bloodLaceCompressedTGA', 'pcx', 'sgi', 'sunRaster',
        'ico', 'cur', 'dcx', 'dds', 'ddsMIPChain', 'farbfeld', 'wirelessBMP', 'xwd', 'mtv', 'viff', 'vips']),
]
LIMIT = 20 * 1024 * 1024
PPN_SETS = {'Netpbm (PBM, PGM, PPM, PAM, PFM)', 'BMP', 'Radiance HDR'}


def files_of(dirs):
    out = []
    for d in dirs:
        p = os.path.join(corpus, d)
        if not os.path.isdir(p): continue
        for root, _, fs in os.walk(p):
            for f in sorted(fs):
                q = os.path.join(root, f)
                if os.path.isfile(q) and 0 < os.path.getsize(q) <= LIMIT: out.append(q)
    return out


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, stdin=subprocess.DEVNULL, **kw)


def one(args):
    k, f, withppn = args
    d = os.path.join(work, 'f%d' % k)
    shutil.rmtree(d, ignore_errors=True); os.makedirs(d)
    n = os.path.getsize(f)
    data = open(f, 'rb').read()
    res = {'size': n}
    src = os.path.join(d, 'in' + os.path.splitext(f)[1][:16])
    shutil.copy(f, src)
    t = time.time()
    run([pra, 'a', '-q', '-th', '1', src, '-o', os.path.join(d, 'p.pra')])
    ta = time.time() - t
    p = os.path.join(d, 'p.pra')
    res['pra'] = n
    res['pra_a'] = ta
    if os.path.exists(p):
        t = time.time()
        run([pra, 'x', '-q', '-th', '1', p, '-o', os.path.join(d, 'back')])
        res['pra_x'] = time.time() - t
        b = os.path.join(d, 'back')
        if os.path.exists(b) and open(b, 'rb').read() == data: res['pra'] = os.path.getsize(p)
    res['taken'] = res['pra'] < n or os.path.exists(p)
    res['xz'] = min(n, len(run(['xz', '-9e', '-c', f]).stdout))
    res['zstd'] = min(n, len(run(['zstd', '-19', '--long=27', '-c', f]).stdout))
    if withppn:
        v = os.path.join(d, 'v'); os.makedirs(v)
        c = os.path.join(d, 'x' + os.path.splitext(f)[1][:16])
        shutil.copy(f, c)
        run([ppn, '-np', os.path.basename(c)], cwd=d)
        res['ppn'] = n
        w = os.path.join(d, 'x.prw')
        if os.path.exists(w) and os.path.getsize(w) > 0:
            shutil.copy(w, v)
            run([ppn, '-np', 'x.prw'], cwd=v)
            backs = [x for x in os.listdir(v) if x != 'x.prw']
            if backs and open(os.path.join(v, backs[0]), 'rb').read() == data: res['ppn'] = os.path.getsize(w)
    shutil.rmtree(d, ignore_errors=True)
    return res


def mb(x): return '%.1f MB' % (x / 1e6)


print('| set | files | size | xz -9e | zstd -19 | packPNM 1.6d | PRA |')
print('|---|---|---|---|---|---|---|')
tot = {}
for name, dirs in SETS:
    fs = files_of(dirs)
    withppn = name in PPN_SETS
    with ThreadPoolExecutor(32) as ex:
        rs = list(ex.map(one, [(i + hash(name) % 100000 * 1000, f, withppn) for i, f in enumerate(fs)]))
    S = sum(r['size'] for r in rs)
    def pct(key): return '%.2f%%' % (100 * sum(r[key] for r in rs) / S)
    ppncol = pct('ppn') if withppn else '-'
    print('| %s | %d | %s | %s | %s | %s | **%s** |' % (name, len(rs), mb(S), pct('xz'), pct('zstd'), ppncol, pct('pra')),
          flush=True)
    for key in ('size', 'xz', 'zstd', 'pra', 'pra_a', 'pra_x'):
        tot[key] = tot.get(key, 0) + sum(r.get(key, 0) for r in rs)
S = tot['size']
print('| **all** | | %s | %.2f%% | %.2f%% | - | **%.2f%%** |' % (mb(S), 100 * tot['xz'] / S, 100 * tot['zstd'] / S,
                                                         100 * tot['pra'] / S))
print('pra a %.1f s, pra x %.1f s (one thread each, summed)' % (tot['pra_a'], tot['pra_x']))
