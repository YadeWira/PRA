#!/usr/bin/env python3
"""Writes the synthetic samples of tests/pnm: small images of every layout
PRA takes, made from integers only (the same bytes on every platform).

    python3 scripts/mksamples.py tests/pnm
"""
import os, struct, sys

out = sys.argv[1]
os.makedirs(out, exist_ok=True)
seed = 2463534242
def rand():
    global seed
    seed ^= (seed << 13) & 0xFFFFFFFF; seed ^= seed >> 17; seed ^= (seed << 5) & 0xFFFFFFFF
    return seed

def smooth(x, y, c, top):
    v = (x * 5 + y * 3 + c * 37) % 180 + rand() % 7
    if (x // 8 + y // 8) % 3 == 0: v += 40
    return v * top // 255

def raster(w, h, ch, top, two):
    b = bytearray()
    for y in range(h):
        for x in range(w):
            for c in range(ch):
                v = smooth(x, y, c, top)
                b += struct.pack('>H', v) if two else bytes([v])
    return bytes(b)

def write(name, data):
    open(os.path.join(out, name), 'wb').write(data)

write('gray8.pgm', b'P5\n48 32\n255\n' + raster(48, 32, 1, 255, False))
write('gray16.pgm', b'P5\n40 24\n65535\n' + raster(40, 24, 1, 65535, True))
write('gray10.pgm', b'P5\n30 20\n1023\n' + raster(30, 20, 1, 1023, True))
write('color.ppm', b'P6\n# synthetic\n64 48\n255\n' + raster(64, 48, 3, 255, False))
write('color16.ppm', b'P6\n32 24\n65535\n' + raster(32, 24, 3, 65535, True))
write('crlf.ppm', b'P6\r\n17 13\r\n255\n' + raster(17, 13, 3, 255, False))
write('rgba.pam', b'P7\nWIDTH 40\nHEIGHT 30\nDEPTH 4\nMAXVAL 255\nTUPLTYPE RGB_ALPHA\nENDHDR\n' + raster(40, 30, 4, 255, False))
write('grayalpha16.pam', b'P7\nWIDTH 20\nHEIGHT 16\nDEPTH 2\nMAXVAL 4095\nTUPLTYPE GRAYSCALE_ALPHA\nENDHDR\n' + raster(20, 16, 2, 4095, True))
# PBM: an odd width, rows padded to a byte
w, h = 37, 20
rows = bytearray()
for y in range(h):
    bits = [1 if ((x - 18) ** 2 + (y - 10) ** 2 < 64) or (x % 9 == 0) else 0 for x in range(w)]
    bits += [0] * (-w % 8)
    for i in range(0, len(bits), 8):
        rows.append(int(''.join(map(str, bits[i:i + 8])), 2))
write('shape.pbm', b'P4\n37 20\n' + bytes(rows))
# PFM: floats from integers
def floats(n, little):
    b = bytearray()
    for i in range(n):
        v = 0x3F800000 + (i % 50) * 40000 + rand() % 256
        if (i // 50) % 3 == 1: v |= 0x80000000
        b += struct.pack('<I' if little else '>I', v)
    return bytes(b)
write('rgb_le.pfm', b'PF\n24 16\n-1.000000\n' + floats(24 * 16 * 3, True))
write('gray_be.pfm', b'Pf\n20 10\n1.0\n' + floats(200, False))
# noise: the codec cannot shrink it, so it is stored as it is
write('noise.pgm', b'P5\n64 64\n255\n' + bytes(rand() & 255 for _ in range(64 * 64)))
# a tail after the image
write('tail.pgm', b'P5\n16 16\n255\n' + raster(16, 16, 1, 255, False) + b'some bytes after the image\n')
