#!/usr/bin/env python3
"""Writes pas/praselftest.inc: the samples `pra selftest` carries inside the
binary, and the .pra each one has to give (doc/CLI.md, selftest).

Nine small files of tests/ (about 20 KB), one for each way the codec takes
an image: 16-bit gray samples, RGB, 1-bit, palette indices, a side coding
(BMP RLE8), Radiance's scanlines, floats, a file of several images (parts)
and a PSD whose composite is coded against its layer. Each .pra is the one
the given pra command makes of it; selftest checks every SIMD path and
thread count still makes those very bytes. (From PJA's tools/gen_selftest.py.)

    tools/gen_selftest.py <pra binary>            write the include
    tools/gen_selftest.py --check <pra binary>    exit 1 if it is not current
"""
import os, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, 'pas', 'praselftest.inc')
SAMPLES = ['pnm/gray16.pgm', 'pnm/crlf.ppm', 'pnm/shape.pbm', 'bmp/palette8.bmp', 'bmp/rle8_usual.bmp',
           'hdr/stb.hdr', 'pnm/gray_be.pfm', 'multi/ico_three.ico', 'cont/psd_nearcopy.psd']


def pas_bytes(name, b):
    out = [f'  {name}: array[0..{len(b) - 1}] of Byte = (']
    for i in range(0, len(b), 20):
        out.append('    ' + ', '.join(f'${x:02X}' for x in b[i:i + 20]) + (',' if i + 20 < len(b) else ''))
    out.append('  );')
    return out


def generate(pra):
    lines = ['{ Written by tools/gen_selftest.py: do not edit. The samples of `pra selftest`',
             '  (from tests/, scripts/mksamples.py) and the .pra of each. }', 'const']
    table = []
    with tempfile.TemporaryDirectory() as tmp:
        for k, rel in enumerate(SAMPLES):
            src = os.path.join(ROOT, 'tests', rel)
            data = open(src, 'rb').read()
            out = os.path.join(tmp, f's{k}.pra')
            subprocess.run([pra, 'a', '-q', '-f', '-th', '1', src, '-o', out], check=True)
            packed = open(out, 'rb').read()
            lines += pas_bytes(f'SELFTEST_IN_{k}', data)
            lines += pas_bytes(f'SELFTEST_PRA_{k}', packed)
            table.append((os.path.basename(rel), os.path.splitext(rel)[1][1:], k))
    lines.append(f'  SELFTEST_COUNT = {len(table)};')
    lines.append('  SELFTEST_NAMES: array[0..SELFTEST_COUNT - 1] of string = (' +
                 ', '.join(f"'{t[0]}'" for t in table) + ');')
    lines.append('  SELFTEST_EXTS: array[0..SELFTEST_COUNT - 1] of string = (' +
                 ', '.join(f"'{t[1]}'" for t in table) + ');')
    lines.append('')
    lines.append('procedure SelftestSample(k: Integer; out data, expect: TBytes);')
    lines.append('begin')
    lines.append('  data := nil; expect := nil;')
    lines.append('  case k of')
    for (_, _, k) in table:
        lines.append(f'    {k}: begin')
        lines.append(f'      SetLength(data, Length(SELFTEST_IN_{k})); Move(SELFTEST_IN_{k}[0], data[0], Length(data));')
        lines.append(f'      SetLength(expect, Length(SELFTEST_PRA_{k})); Move(SELFTEST_PRA_{k}[0], expect[0], Length(expect));')
        lines.append('    end;')
    lines.append('  end;')
    lines.append('end;')
    return '\n'.join(lines) + '\n'


def main():
    args = sys.argv[1:]
    check = args and args[0] == '--check'
    if check:
        args = args[1:]
    if len(args) != 1:
        sys.exit(__doc__)
    text = generate(args[0])
    if check:
        old = open(OUT).read() if os.path.exists(OUT) else ''
        if old != text:
            print('pas/praselftest.inc is not current: run tools/gen_selftest.py <pra>')
            sys.exit(1)
        print('pas/praselftest.inc is current')
        return
    open(OUT, 'w').write(text)
    print(f'wrote {OUT}')


main()
