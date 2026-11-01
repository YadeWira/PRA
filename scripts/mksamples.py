#!/usr/bin/env python3
"""Writes the synthetic samples of tests/pnm, tests/bmp and tests/hdr: small
images of every layout PRA takes, made from integers only (the same bytes
on every platform). The HDR scanlines are run-length coded the way
Radiance's fwritecolrs and stb_image_write do it.

    python3 scripts/mksamples.py tests
"""
import os, struct, sys

root = sys.argv[1]
out = os.path.join(root, 'pnm')
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

# ---------- BMP ----------
out = os.path.join(root, 'bmp'); os.makedirs(out, exist_ok=True)
def bmp(name, w, h, bpp, pixels_row, palette=b'', dib=40, topdown=False, comp=0, masks=b''):
    """pixels_row(y) -> the row's bytes without padding; rows stored bottom-up unless topdown"""
    rowbytes = ((w * bpp + 31) // 32) * 4
    rows = []
    for y in range(h):
        r = pixels_row(y)
        rows.append(r + bytes(rowbytes - len(r)))
    data = b''.join(rows if topdown else rows[::-1])
    if dib == 12:
        info = struct.pack('<IHHHH', 12, w, h, 1, bpp)
    else:
        info = struct.pack('<IiiHHIIiiII', 40, w, -h if topdown else h, 1, bpp, comp, len(data), 2835, 2835, 0, 0)
    off = 14 + len(info) + len(masks) + len(palette)
    head = b'BM' + struct.pack('<IHHI', off + len(data), 0, 0, off)
    write(name, head + info + masks + palette + data)

gray_pal = b''.join(bytes([i, i, i, 0]) for i in range(256))
rand_pal = b''.join(bytes([(i * 73) & 255, (i * 151) & 255, (i * 29) & 255, 0]) for i in range(256))
bmp('graypal8.bmp', 45, 30, 8, lambda y: bytes(smooth(x, y, 0, 255) for x in range(45)), gray_pal)
bmp('palette8.bmp', 50, 40, 8, lambda y: bytes(((x // 6) * 7 + (y // 5) * 13) % 37 for x in range(50)), rand_pal)
def pack4(vals):
    vals = vals + [0] * (len(vals) % 2)
    return bytes((vals[i] << 4) | vals[i + 1] for i in range(0, len(vals), 2))
bmp('palette4.bmp', 33, 21, 4, lambda y: pack4([((x // 3) + (y // 4)) % 16 for x in range(33)]), rand_pal[:64])
def pack1(vals):
    vals = vals + [0] * (-len(vals) % 8)
    return bytes(int(''.join(map(str, vals[i:i + 8])), 2) for i in range(0, len(vals), 8))
bmp('mono.bmp', 70, 25, 1, lambda y: pack1([1 if (x + y) % 11 < 4 else 0 for x in range(70)]), b'\x00\x00\x00\x00\xff\xff\xff\x00')
bmp('os2_24.bmp', 31, 19, 24, lambda y: b''.join(bytes([smooth(x, y, 2, 255), smooth(x, y, 1, 255), smooth(x, y, 0, 255)]) for x in range(31)), dib=12)
bmp('topdown24.bmp', 26, 17, 24, lambda y: b''.join(bytes([smooth(x, y, 2, 255), smooth(x, y, 1, 255), smooth(x, y, 0, 255)]) for x in range(26)), topdown=True)
bmp('bgra32.bmp', 24, 16, 32, lambda y: b''.join(bytes([smooth(x, y, 2, 255), smooth(x, y, 1, 255), smooth(x, y, 0, 255), 255 if x % 7 else 128]) for x in range(24)),
    comp=3, masks=struct.pack('<III', 0xFF0000, 0xFF00, 0xFF))
bmp('rgb565.bmp', 21, 14, 16, lambda y: b''.join(struct.pack('<H', ((smooth(x, y, 0, 31)) << 11) | (smooth(x, y, 1, 63) << 5) | smooth(x, y, 2, 31)) for x in range(21)),
    comp=3, masks=struct.pack('<III', 0xF800, 0x7E0, 0x1F))

# ---------- Radiance HDR ----------
out = os.path.join(root, 'hdr'); os.makedirs(out, exist_ok=True)
def radiance_component(s):
    out = bytearray(); w = len(s); j = 0; MINRUN = 4; cnt = 0
    while j < w:
        beg = j
        while beg < w:
            cnt = 1
            while cnt < 127 and beg + cnt < w and s[beg + cnt] == s[beg]: cnt += 1
            if cnt >= MINRUN: break
            beg += cnt
        if 1 < beg - j < MINRUN:
            c2 = j + 1
            while s[c2] == s[j]:
                c2 += 1
                if c2 == beg:
                    out += bytes([128 + beg - j, s[j]]); j = beg; break
        while j < beg:
            c2 = min(beg - j, 128); out.append(c2); out += bytes(s[j:j + c2]); j += c2
        if cnt >= MINRUN:
            out += bytes([128 + cnt, s[beg]]); j = beg + cnt
    return bytes(out)

def stb_component(s):
    out = bytearray(); w = len(s); x = 0
    while x < w:
        r = x
        while r + 2 < w:
            if s[r] == s[r + 1] == s[r + 2]: break
            r += 1
        if r + 2 >= w: r = w
        while x < r:
            n = min(r - x, 128); out.append(n); out += bytes(s[x:x + n]); x += n
        if r + 2 < w:
            while r < w and s[r] == s[x]: r += 1
            while x < r:
                n = min(r - x, 127); out += bytes([128 + n, s[x]]); x += n
    return bytes(out)

def hdr(name, w, h, coder, header=b'#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n'):
    lines = []
    for y in range(h):
        px = [(smooth(x, y, 0, 255), smooth(x, y, 1, 255), smooth(x, y, 2, 255), 128 + (x // 10) % 3) for x in range(w)]
        for x in range(w):            # runs: a flat stretch, and one of exactly 3
            if 5 <= x < 30: px[x] = (40, 41, 42, 129)   # (stb writes a run of 3, Radiance a dump)
            if 36 <= x < 39: px[x] = (7, 8, 9, 130)
        if coder is None:
            lines.append(b''.join(bytes(p) for p in px))
        else:
            line = bytes([2, 2, w >> 8, w & 255])
            for c in range(4): line += coder([p[c] for p in px])
            lines.append(line)
    write(name, header + b'-Y %d +X %d\n' % (h, w) + b''.join(lines))

hdr('radiance.hdr', 64, 20, radiance_component)
hdr('stb.hdr', 50, 16, stb_component, b'#?RADIANCE\n# Made with stb_image_write\nFORMAT=32-bit_rle_rgbe\n\n')
hdr('flat.hdr', 7, 9, None, b'#?RGBE\n\n')
