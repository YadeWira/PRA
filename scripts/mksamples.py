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

# ---------- farbfeld, TGA, Sun Raster, WBMP ----------
out = os.path.join(root, 'other'); os.makedirs(out, exist_ok=True)
w, h = 30, 20
write('ff_rgba16.ff', b'farbfeld' + struct.pack('>II', w, h) +
      b''.join(struct.pack('>HHHH', smooth(x, y, 0, 65535), smooth(x, y, 1, 65535), smooth(x, y, 2, 65535), 65535) for y in range(h) for x in range(w)))

def tga(name, imgtype, bpp, pixel, idfield=b'', cmap=b'', cmbits=0, desc=0, footer=False, w=33, h=21):
    cmtype = 1 if cmap else 0
    cmlen = len(cmap) // ((cmbits + 7) // 8) if cmap else 0
    head = struct.pack('<BBBHHBHHHHBB', len(idfield), cmtype, imgtype, 0, cmlen, cmbits, 0, 0, w, h, bpp, desc)
    data = b''.join(pixel(x, y) for y in range(h) for x in range(w))
    foot = (b'\x00' * 8 + b'TRUEVISION-XFILE.\x00') if footer else b''
    write(name, head + idfield + cmap + data + foot)

tga('tga_rgb24.tga', 2, 24, lambda x, y: bytes([smooth(x, y, 2, 255), smooth(x, y, 1, 255), smooth(x, y, 0, 255)]), b'made by mksamples', footer=True)
tga('tga_bgra32_top.tga', 2, 32, lambda x, y: bytes([smooth(x, y, 2, 255), smooth(x, y, 1, 255), smooth(x, y, 0, 255), 255]), desc=0x28)
tga('tga_rgb16.tga', 2, 16, lambda x, y: struct.pack('<H', (smooth(x, y, 0, 31) << 10) | (smooth(x, y, 1, 31) << 5) | smooth(x, y, 2, 31)), desc=1)
tga('tga_gray8.tga', 3, 8, lambda x, y: bytes([smooth(x, y, 0, 255)]))
tga('tga_mapped8.tga', 1, 8, lambda x, y: bytes([((x // 4) + (y // 3) * 5) % 40]), cmap=bytes(i * 5 % 256 for i in range(40 * 3)), cmbits=24)

def sun(name, depth, rtype, rowfn, w=29, h=17, cmap=b''):
    rowbytes = ((w * depth + 15) // 16) * 2
    rows = b''.join(r + bytes(rowbytes - len(r)) for r in (rowfn(y) for y in range(h)))
    head = struct.pack('>8I', 0x59A66A95, w, h, depth, len(rows), rtype, 1 if cmap else 0, len(cmap))
    write(name, head + cmap + rows)

sun('ras_bgr24.ras', 24, 1, lambda y: b''.join(bytes([smooth(x, y, 2, 255), smooth(x, y, 1, 255), smooth(x, y, 0, 255)]) for x in range(29)))
sun('ras_rgb24_t3.ras', 24, 3, lambda y: b''.join(bytes([smooth(x, y, 0, 255), smooth(x, y, 1, 255), smooth(x, y, 2, 255)]) for x in range(29)))
sun('ras_xbgr32.ras', 32, 1, lambda y: b''.join(bytes([0, smooth(x, y, 2, 255), smooth(x, y, 1, 255), smooth(x, y, 0, 255)]) for x in range(29)))
sun('ras_mapped8.ras', 8, 1, lambda y: bytes(((x // 3) + y) % 16 for x in range(29)), cmap=bytes(i * 17 % 256 for i in range(48)))
sun('ras_mono1.ras', 1, 1, lambda y: pack1([1 if (x * y) % 7 < 3 else 0 for x in range(29)]))

def mbi(v):
    out = [v & 0x7F]; v >>= 7
    while v: out.append(0x80 | (v & 0x7F)); v >>= 7
    return bytes(reversed(out))
w, h = 45, 30
write('wbmp_shape.wbmp', b'\x00\x00' + mbi(w) + mbi(h) + b''.join(pack1([1 if ((x - 22) ** 2 + (y - 15) ** 2) < 120 else 0 for x in range(w)]) for y in range(h)))
w, h = 200, 3
write('wbmp_wide.wbmp', b'\x00\x00' + mbi(w) + mbi(h) + b''.join(pack1([(x // 5 + y) % 2 for x in range(w)]) for y in range(h)))

# TGA run-length: a usual coder (runs of 2 or more, rows apart), one whose
# packets cross rows, and one that chooses at random: PRA has to give back
# any of them, byte for byte
def tga_rle(px, w, h, ps, cross, randomly):
    out = bytearray(); rows = [px] if cross else [px[y*w:(y+1)*w] for y in range(h)]
    for row in rows:
        i = 0; n = len(row)
        while i < n:
            r = 1
            while i + r < n and r < 128 and row[i + r] == row[i]: r += 1
            if randomly: r = 1 + rand() % r
            if r >= 2 or (randomly and rand() % 4 == 0):
                out.append(0x80 | (r - 1)); out += row[i]; i += r; continue
            j = i + 1
            while j < n and j - i < 128 and not (j + 1 < n and row[j + 1] == row[j]):
                j += 1
            if randomly: j = i + 1 + rand() % (j - i)
            out.append(j - i - 1)
            for k in range(i, j): out += row[k]
            i = j
    return bytes(out)

def tga_rle_file(name, imgtype, bpp, pixel, cross, randomly, cmap=b'', cmbits=0, w=37, h=23):
    ps = (bpp + 7) // 8
    px = [pixel(x, y) for y in range(h) for x in range(w)]
    cmlen = len(cmap) // ((cmbits + 7) // 8) if cmap else 0
    head = struct.pack('<BBBHHBHHHHBB', 0, 1 if cmap else 0, imgtype, 0, cmlen, cmbits, 0, 0, w, h, bpp, 0)
    write(name, head + cmap + tga_rle(px, w, h, ps, cross, randomly))

flat = lambda x, y, c: 50 if 8 <= x < 25 else smooth(x, y, c, 255)
tga_rle_file('tga_rle24.tga', 10, 24, lambda x, y: bytes([flat(x, y, 2), flat(x, y, 1), flat(x, y, 0)]), False, False)
tga_rle_file('tga_rle32_cross.tga', 10, 32, lambda x, y: bytes([flat(x, y, 2), flat(x, y, 1), flat(x, y, 0), 255]), True, False)
tga_rle_file('tga_rle8_random.tga', 11, 8, lambda x, y: bytes([flat(x, y, 0) // 8 * 8]), False, True)
tga_rle_file('tga_rle_mapped.tga', 9, 8, lambda x, y: bytes([(x // 6 + y // 4) % 12]), True, True,
             cmap=bytes(i * 9 % 256 for i in range(36)), cmbits=24)

# PCX: lines of planes, each run-length coded the usual way (runs of 2 and
# more, a byte of $C0 and up as a run of 1, lines apart), and one at random
def pcx_rle(data, linelen, randomly=False):
    out = bytearray()
    for s0 in range(0, len(data), linelen):
        line = data[s0:s0 + linelen]; i = 0
        while i < len(line):
            r = 1
            while i + r < len(line) and r < 63 and line[i + r] == line[i]: r += 1
            if randomly: r = 1 + rand() % r
            if r >= 2 or line[i] >= 0xC0 or (randomly and rand() % 3 == 0):
                out += bytes([0xC0 | r, line[i]])
            else:
                out.append(line[i])
            i += r
    return bytes(out)

def pcx(name, bpp, planes, bpl, lines, plane_byte, palette=b'', randomly=False, w=None):
    w = w or bpl * 8 // bpp
    head = struct.pack('<BBBBHHHHHH', 10, 5, 1, bpp, 0, 0, w - 1, lines - 1, 72, 72)
    head += bytes(48) + b'\x00' + bytes([planes]) + struct.pack('<HH', bpl, 1) + bytes(58)
    data = b''.join(bytes(plane_byte(x, y, c) for x in range(bpl)) for y in range(lines) for c in range(planes))
    write(name, head + pcx_rle(data, planes * bpl, randomly) + palette)

pcx('pcx_rgb24.pcx', 8, 3, 32, 20, lambda x, y, c: flat(x, y, c))
pcx('pcx_pal8.pcx', 8, 1, 40, 25, lambda x, y, c: (x // 5 + y // 4) * 7 % 256, b'\x0c' + bytes(i % 256 for i in range(768)))
pcx('pcx_ega.pcx', 1, 4, 6, 24, lambda x, y, c: (0xF0 if (x + y + c) % 3 else 0x0F) if y % 4 else 0xFF)
pcx('pcx_3plane.pcx', 1, 3, 4, 16, lambda x, y, c: [0xAA, 0x55, 0xC3][c] if (y + x) % 2 else 0)
pcx('pcx_mono.pcx', 1, 1, 10, 30, lambda x, y, c: 0xFF if (x * y) % 5 else 0xC3, randomly=True)
pcx('pcx_4bit.pcx', 4, 1, 16, 12, lambda x, y, c: ((x // 2) % 16) << 4 | (y % 16))

# Sun Raster type 2: $80 n v for runs (here of 3 and more), $80 0 for a
# literal $80, and one at random
def sun_rle(data, randomly=False):
    out = bytearray(); i = 0
    while i < len(data):
        r = 1
        while i + r < len(data) and r < 256 and data[i + r] == data[i]: r += 1
        if randomly: r = 1 + rand() % r
        if r >= 3 or (randomly and r >= 2):
            out += bytes([0x80, r - 1, data[i]])
        else:
            r = 1
            out += b'\x80\x00' if data[i] == 0x80 else bytes([data[i]])
        i += r
    return bytes(out)

def sun2(name, depth, rowfn, w=27, h=15, randomly=False, cmap=b''):
    rowbytes = ((w * depth + 15) // 16) * 2
    rows = b''.join(r + bytes(rowbytes - len(r)) for r in (rowfn(y) for y in range(h)))
    coded = sun_rle(rows, randomly)
    head = struct.pack('>8I', 0x59A66A95, w, h, depth, len(coded), 2, 1 if cmap else 0, len(cmap))
    write(name, head + cmap + coded)

sun2('ras_rle24.ras', 24, lambda y: b''.join(bytes([flat(x, y, 2), 0x80 if x == 3 else flat(x, y, 1), flat(x, y, 0)]) for x in range(27)))
sun2('ras_rle8_random.ras', 8, lambda y: bytes(128 if x % 9 == 0 else (x // 4) * 20 % 256 for x in range(27)), randomly=True,
     cmap=bytes(i * 3 % 256 for i in range(36)))

# SGI: verbatim, and run-length with its tables, rows laid in table order
# or row by row (channels interleaved), packets usual or random
def sgi_head(storage, bpc, dim, xs, ys, zs):
    return struct.pack('>HBBHHHHIII', 474, storage, bpc, dim, xs, ys, zs, 0, 255 if bpc == 1 else 65535, 0) \
        + b'synthetic'.ljust(80, b'\0') + struct.pack('>I', 0) + bytes(404)

def sgi_row_rle(vals, bpc, randomly):
    u = (lambda v: bytes([v])) if bpc == 1 else (lambda v: struct.pack('>H', v))
    out = bytearray(); i = 0; n = len(vals)
    while i < n:
        r = 1
        while i + r < n and r < 127 and vals[i + r] == vals[i]: r += 1
        if randomly and r > 1: r = 1 + rand() % r
        if r >= 3:
            out += u(r) + u(vals[i]); i += r; continue
        j = i + 1
        while j < n and j - i < 127 and not (j + 2 < n and vals[j] == vals[j + 1] == vals[j + 2]): j += 1
        if randomly: j = i + 1 + rand() % (j - i)
        out += u(0x80 | (j - i)) + b''.join(u(v) for v in vals[i:j]); i = j
    return bytes(out) + u(0)

def sgi(name, bpc, xs, ys, zs, val, rle, ymajor=False, randomly=False):
    dim = 3 if zs > 1 else 2
    head = sgi_head(1 if rle else 0, bpc, dim, xs, ys, zs)
    if not rle:
        data = b''.join((bytes([val(x, y, z)]) if bpc == 1 else struct.pack('>H', val(x, y, z)))
                        for z in range(zs) for y in range(ys) for x in range(xs))
        write(name, head + data); return
    rows = ys * zs
    order = [y + z * ys for y in range(ys) for z in range(zs)] if ymajor else list(range(rows))
    first = 512 + 8 * rows; starts = [0] * rows; lens = [0] * rows; body = bytearray()
    for idx in order:
        y, z = idx % ys, idx // ys
        enc = sgi_row_rle([val(x, y, z) for x in range(xs)], bpc, randomly)
        starts[idx] = first + len(body); lens[idx] = len(enc); body += enc
    write(name, head + struct.pack('>%dI' % rows, *starts) + struct.pack('>%dI' % rows, *lens) + body)

sv = lambda x, y, z: flat(x, y, z)
sgi('sgi_raw8.sgi', 1, 25, 14, 3, sv, False)
sgi('sgi_raw16.sgi', 2, 20, 11, 4, lambda x, y, z: smooth(x, y, z, 65535), False)
sgi('sgi_rle_rows.rgb', 1, 33, 17, 3, sv, True)
sgi('sgi_rle_ymajor.rgb', 1, 30, 15, 4, sv, True, ymajor=True)
sgi('sgi_rle_gray.bw', 1, 40, 12, 1, lambda x, y, z: flat(x, y, 0) // 16 * 16, True, randomly=True)
sgi('sgi_rle16.sgi', 2, 18, 10, 3, lambda x, y, z: 3000 if 5 <= x < 12 else smooth(x, y, z, 65535), True, ymajor=True)

# XWD: big- and little-endian headers, rows longer than their pixels, a
# colour map, a bitmap (XYBitmap, one plane)
def xwd(name, be, fmt, depth, bpp, w, h, bpl, rowfn, ncolors=0, xname=b'xwd sample\0', order=1, tail=b''):
    e = '>' if be else '<'
    hs = 100 + len(xname)
    head = struct.pack(e + '25I', hs, 7, fmt, depth, w, h, 0, order, 32 if bpp > 8 else 8, 1, 32, bpp, bpl,
                       4 if bpp > 8 else 3, 0xFF0000 if bpp > 8 else 0, 0xFF00 if bpp > 8 else 0, 0xFF if bpp > 8 else 0,
                       8, ncolors, ncolors, w, h, 0, 0, 0) + xname
    cmap = b''.join(struct.pack(e + 'IHHHBB', i, i * 257, (i * 3 % 256) * 257, (255 - i) * 257, 7, 0) for i in range(ncolors))
    rows = b''.join(r + bytes(bpl - len(r)) for r in (rowfn(y) for y in range(h)))
    write(name, head + cmap + rows + tail)

xwd('xwd_rgb32_be.xwd', True, 2, 24, 32, 27, 19, 27 * 4 + 8,
    lambda y: b''.join(bytes([0, smooth(x, y, 0, 255), smooth(x, y, 1, 255), smooth(x, y, 2, 255)]) for x in range(27)))
xwd('xwd_mapped8_le.xwd', False, 2, 8, 8, 31, 17, 32, lambda y: bytes(((x // 3) + y) % 24 for x in range(31)), ncolors=24, order=0)
xwd('xwd_bitmap.xwd', True, 0, 1, 1, 50, 21, 8, lambda y: pack1([1 if (x + 2 * y) % 9 < 4 else 0 for x in range(50)]), ncolors=2)

# MTV: "width height\n" and R, G, B; one with a byte after the pixels
w, h = 26, 18
mtv = lambda: b''.join(bytes([smooth(x, y, 0, 255), smooth(x, y, 1, 255), smooth(x, y, 2, 255)]) for y in range(h) for x in range(w))
write('mtv_rgb.mtv', b'%d %d\n' % (w, h) + mtv())
write('mtv_tail.mtv', b'%d %d\n' % (w, h) + mtv() + b'\n')

# VIFF: a band's plane after another, big- and little-endian, a colour map
def viff(name, be, w, h, bands, storage, plane, mapbytes=b'', maprow=0, mapcol=0):
    e = '>' if be else '<'
    head = bytes([0xAB, 1, 1, 3, 2 if be else 8, 0, 0, 0]) + b'synthetic'.ljust(512, b'\0')
    head += struct.pack(e + '5I', w, h, 0, 0xFFFFFFFF, 0xFFFFFFFF) + struct.pack(e + '2f', 1.0, 1.0)
    head += struct.pack(e + '15I', 1, 0, 1, bands, storage, 0, 1 if mapbytes else 0, 1 if mapbytes else 0,
                        maprow, mapcol, 0, 2 if mapbytes else 0, 0, 15 if bands == 3 else 0, 0)
    head = head.ljust(1024, b'\0')
    write(name, head + mapbytes + b''.join(plane(b) for b in range(bands)))

viff('viff_rgb_be.viff', True, 23, 15, 3, 1, lambda b: bytes(smooth(x, y, b, 255) for y in range(15) for x in range(23)))
viff('viff_gray16_le.xv', False, 21, 13, 1, 2, lambda b: b''.join(struct.pack('<H', smooth(x, y, 0, 65535)) for y in range(13) for x in range(21)))
viff('viff_mapped.xv', False, 28, 16, 1, 1, lambda b: bytes(((x // 4) + y) % 20 for y in range(16) for x in range(28)),
     mapbytes=bytes(i * 13 % 256 for i in range(3 * 20)), maprow=3, mapcol=20)

# VIPS: 64-byte header, pixels, then the metadata (XML)
def vips(name, be, w, h, bands, fmt, data, xml=b''):
    e = '>' if be else '<'
    magic = b'\x08\xf2\xa6\xb6' if be else b'\xb6\xa6\xf2\x08'
    head = magic + struct.pack(e + '7I2f', w, h, bands, 8, fmt, 0, 22, 1.0, 1.0) + struct.pack(e + 'IHHII', 0, 0, 0, 0, 0)
    write(name, head.ljust(64, b'\0') + data + xml)

vips('vips_rgb_be.v', True, 25, 16, 3, 0, raster(25, 16, 3, 255, False),
     b'<?xml version="1.0"?>\n<root xmlns="http://www.vips.ecs.soton.ac.uk/vips/8.7.0"><header/></root>\n')
vips('vips_gray16_le.v', False, 19, 14, 1, 2, b''.join(struct.pack('<H', smooth(x, y, 0, 65535)) for y in range(14) for x in range(19)))

# DDS, uncompressed: 32-bit, two byte channels (A8L8), a volume, mipmaps
def dds(name, w, h, bits, masks, data, depth=0, mips=0, caps2=0, pfflags=0x41, fourcc=0):
    head = b'DDS ' + struct.pack('<7I', 124, 0x100F | (0x20000 if mips else 0) | (0x800000 if depth else 0),
                                 h, w, (w * bits + 7) // 8, depth, mips) + bytes(44)
    head += struct.pack('<8I', 32, pfflags, fourcc, bits, *masks) + struct.pack('<5I', 0x1000, caps2, 0, 0, 0)
    write(name, head + data)

dds('dds_bgra32.dds', 22, 14, 32, (0xFF0000, 0xFF00, 0xFF, 0xFF000000), raster(22, 14, 4, 255, False))
dds('dds_a8l8.dds', 20, 12, 16, (0xFF, 0, 0, 0xFF00), raster(20, 12, 2, 255, False), pfflags=0x20001)
dds('dds_volume.dds', 12, 8, 24, (0xFF0000, 0xFF00, 0xFF, 0), raster(12, 24, 3, 255, False), depth=3, caps2=0x200000, pfflags=0x40)
dds('dds_mips.dds', 16, 16, 32, (0xFF0000, 0xFF00, 0xFF, 0xFF000000),
    raster(16, 16, 4, 255, False) + raster(8, 8, 4, 255, False) + raster(4, 4, 4, 255, False)
    + raster(2, 2, 4, 255, False) + raster(1, 1, 4, 255, False), mips=5)

# ---------- several images a file ----------
out = os.path.join(root, 'multi'); os.makedirs(out, exist_ok=True)
other = os.path.join(root, 'other')

# ICO: a 4-bit palette entry, a 32-bit one, a PNG kept as it is; CUR with
# OS/2's 12-byte DIB header
def dib(w, h, bpp, rowfn, pal=b'', core=False):
    rowbytes = ((w * bpp + 31) // 32) * 4
    xor = b''.join(r + bytes(rowbytes - len(r)) for r in (rowfn(y) for y in range(h)))
    mrow = ((w + 31) // 32) * 4
    mask = b''.join(pack1([1 if (x - w // 2) ** 2 + (y - h // 2) ** 2 > (w // 2) ** 2 else 0 for x in range(w)]).ljust(mrow, b'\0') for y in range(h))
    if core:
        head = struct.pack('<IHHHH', 12, w, 2 * h, 1, bpp)
    else:
        head = struct.pack('<IiiHHIIiiII', 40, w, 2 * h, 1, bpp, 0, len(xor) + len(mask), 0, 0, len(pal) // 4, 0)
    return head + pal + xor + mask

def icondir(kind, entries, hot=(0, 0)):
    head = struct.pack('<HHH', 0, kind, len(entries))
    off = 6 + 16 * len(entries); dirs = b''; body = b''
    for w, h, bpp, data in entries:
        a, b = (1, bpp) if kind == 1 else hot
        dirs += struct.pack('<BBBBHHII', w % 256, h % 256, 16 if bpp == 4 else 0, 0, a, b, len(data), off + len(body))
        body += data
    return head + dirs + body

pal16 = b''.join(bytes([i * 16, 255 - i * 16, (i * 37) % 256, 0]) for i in range(16))
e4 = dib(32, 32, 4, lambda y: pack4([((x // 4) + (y // 4)) % 16 for x in range(32)]), pal16)
e32 = dib(24, 24, 32, lambda y: b''.join(bytes([smooth(x, y, 2, 255), smooth(x, y, 1, 255), smooth(x, y, 0, 255), 255 if x % 9 else 0]) for x in range(24)))
png = b'\x89PNG\r\n\x1a\n' + bytes(rand() % 256 for _ in range(60))
write('ico_three.ico', icondir(1, [(32, 32, 4, e4), (24, 24, 32, e32), (16, 16, 32, png)]))
pal2 = b'\x00\x00\x00\xff\xff\xff'
write('cur_core.cur', icondir(2, [(32, 32, 1, dib(32, 32, 1, lambda y: pack1([1 if (x * y) % 5 < 2 else 0 for x in range(32)]), pal2, core=True))], hot=(3, 4)))

# DCX: two PCX files after the table
p1 = open(os.path.join(other, 'pcx_pal8.pcx'), 'rb').read()
p2 = open(os.path.join(other, 'pcx_rgb24.pcx'), 'rb').read()
table = struct.pack('<I', 0x3ADE68B1) + struct.pack('<3I', 4 + 4 * 1024, 4 + 4 * 1024 + len(p1), 0) + bytes(4 * 1024 - 12)
write('dcx_two.dcx', table + p1 + p2)

# Netpbm: three images in a row, and a byte after them
write('pnm_three.pgm', b'P5\n20 12\n255\n' + raster(20, 12, 1, 255, False) + b'P6\n16 10\n255\n' + raster(16, 10, 3, 255, False)
      + b'P4\n13 7\n' + bytes(rand() % 256 for _ in range(14)) + b'\n')

# DDS: a cube map of two faces with mipmaps, 32 bits
def mipchain(w, h, ch):
    out = b''
    while True:
        out += raster(w, h, ch, 255, False)
        if w == 1 and h == 1: return out
        w, h = max(1, w // 2), max(1, h // 2)
head = b'DDS ' + struct.pack('<7I', 124, 0x2100F, 8, 8, 32, 0, 4) + bytes(44)
head += struct.pack('<8I', 32, 0x41, 0, 32, 0xFF0000, 0xFF00, 0xFF, 0xFF000000) + struct.pack('<5I', 0x401008, 0x200 | 0x400 | 0x800, 0, 0, 0)
write('dds_cube_mips.dds', head + mipchain(8, 8, 4) + mipchain(8, 8, 4))

# ---------- BMP run-length, plain Netpbm ----------
out = os.path.join(root, 'bmp')

# RLE8 and RLE4: a usual writer (runs of 2 and up, literals of 3 and up,
# rows apart, an end of row and an end of bitmap), one that chooses at
# random (moves, rows ended early, padding bytes not zero, no end of
# bitmap), and one that codes each row's padding too (ImageMagick)
def bmp_rle(w, h, bits, px, randomly=False, padded=False):
    wp = ((w * bits + 31) // 32 * 4) * 8 // bits if padded else w
    out_ = bytearray()
    y = 0
    while y < h:
        row = [px(x, y) if x < w else 0 for x in range(wp)]
        x = 0
        while x < wp:
            if randomly and rand() % 23 == 0 and y + 1 < h and x < w - 2:
                dx = rand() % 3
                out_ += bytes([0, 2, dx, 0]); x += dx; continue      # a move along the row
            if randomly and rand() % 41 == 0 and x > 0:
                break                                                # the row ended early
            r = 1
            while x + r < wp and r < 255 and (row[x + r] == row[x] if bits == 8 else row[x + r] == row[x + (r & 1)]):
                r += 1
            if randomly and r > 1: r = 1 + rand() % r
            if r >= 2 or wp - x < 3:
                v = row[x] if bits == 8 else (row[x] << 4) | (row[x + 1] if r > 1 else (rand() % 16 if randomly else 0))
                out_ += bytes([r, v]); x += r; continue
            n = 3
            while x + n < wp and n < 255 and not (x + n + 1 < wp and row[x + n] == row[x + n + 1]): n += 1
            if randomly: n = 3 + rand() % (n - 2)
            vals = row[x:x + n]
            if bits == 8: data = bytes(vals)
            else:
                data = bytes(((vals[i] << 4) | (vals[i + 1] if i + 1 < n else (rand() % 16 if randomly else 0))) for i in range(0, n, 2))
            out_ += bytes([0, n]) + data
            if len(data) & 1: out_ += bytes([rand() % 256 if randomly else 0])
            x += n
        y += 1
        if y < h or not randomly: out_ += b'\x00\x00' if y < h else b''
    if not randomly or rand() % 2: out_ += b'\x00\x01'
    return bytes(out_)

def bmp_rle_file(name, w, h, bits, px, **kw):
    pal = b''.join(bytes([i * 13 % 256, i * 29 % 256, i * 47 % 256, 0]) for i in range(1 << bits))
    data = bmp_rle(w, h, bits, px, **kw)
    off = 14 + 40 + len(pal)
    head = b'BM' + struct.pack('<IHHI', off + len(data), 0, 0, off)
    head += struct.pack('<IiiHHIIiiII', 40, w, h, 1, bits, 1 if bits == 8 else 2, len(data), 2835, 2835, 1 << bits, 0)
    write(name, head + pal + data)

blob = lambda x, y: ((x // 6) + (y // 4) * 3) % 11 if (x - 20) ** 2 + (y - 12) ** 2 < 150 else 2
bmp_rle_file('rle8_usual.bmp', 47, 25, 8, lambda x, y: blob(x, y) * 7)
bmp_rle_file('rle8_random.bmp', 41, 23, 8, lambda x, y: blob(x, y) * 3, randomly=True)
bmp_rle_file('rle8_padded.bmp', 45, 19, 8, lambda x, y: blob(x, y) * 5, padded=True)
bmp_rle_file('rle4_usual.bmp', 43, 21, 4, lambda x, y: blob(x, y))
bmp_rle_file('rle4_random.bmp', 39, 22, 4, lambda x, y: (blob(x, y) + x % 2) % 16, randomly=True)

# plain: netpbm's (numbers padded to maxval's width, lines up to 70
# columns), ImageMagick's (a row a line), P1's digits run together, a
# comment and CR LF among the numbers, zeros before numbers, 16 bits
out = os.path.join(root, 'pnm')
def wrap70(nums, width=0):
    lines, cur = [], ''
    for n in nums:
        t = str(n).rjust(width)
        if cur and len(cur) + 1 + len(t) > 70: lines.append(cur); cur = t
        else: cur = (cur + ' ' + t) if cur else t
    lines.append(cur)
    return '\n'.join(lines) + '\n'
g = [smooth(x, y, 0, 255) for y in range(14) for x in range(23)]
write('plain_netpbm.pgm', ('P2\n23 14\n255\n' + ''.join(wrap70(g[y * 23:(y + 1) * 23], 3) for y in range(14))).encode())
c = [smooth(x, y, ch, 255) for y in range(11) for x in range(17) for ch in range(3)]
write('plain_rows.ppm', ('P3\n# rows\n17 11\n255\n' + ''.join(' '.join(map(str, c[y * 51:(y + 1) * 51])) + '\n' for y in range(11))).encode())
b = [1 if (x * x + y * 3) % 7 < 3 else 0 for y in range(13) for x in range(29)]
write('plain_run.pbm', ('P1\n29 13\n' + ''.join(''.join(map(str, b[y * 29:(y + 1) * 29])) + '\n' for y in range(13))).encode())
odd = 'P2\r\n9 6\r\n65535\r\n'
for y in range(6):
    vals = [smooth(x, y, 0, 65535) for x in range(9)]
    odd += ' '.join(('00' + str(v)) if (x + y) % 5 == 0 else str(v) for x, v in enumerate(vals)) + ('  # row %d\r\n' % y if y == 2 else '\r\n')
write('plain_odd16.pgm', odd.encode())

# ---------- film and science ----------
out = os.path.join(root, 'sci'); os.makedirs(out, exist_ok=True)

def pack10(samples, methodB=False, pads=None):
    words = []
    for k in range(0, len(samples), 3):
        s = (samples[k:k + 3] + [0, 0])[:3]
        pad = pads(k // 3) if pads else 0
        words.append((pad << 30) | (s[0] << 20) | (s[1] << 10) | s[2] if methodB else (s[0] << 22) | (s[1] << 12) | (s[2] << 2) | pad)
    return words

def v10(x, y, c): return smooth(x, y, c, 255) * 4 + (x + c) % 4

# DPX: 10 bits (packing 1, big-endian; packing 2, little-endian with free
# bits set), 8 bits with rows padded to 32 bits, 16 bits little-endian
def dpx(name, be, w, h, desc, bits, packing, data):
    e = '>' if be else '<'
    head = bytearray(2048)
    head[0:4] = b'SDPX' if be else b'XPDS'
    struct.pack_into(e + 'I', head, 4, 2048); head[8:12] = b'V2.0'; struct.pack_into(e + 'I', head, 16, 2048 + len(data))
    struct.pack_into(e + 'HHII', head, 768, 0, 1, w, h)
    head[800] = desc; head[801] = 2; head[802] = 2; head[803] = bits
    struct.pack_into(e + 'HHIII', head, 804, packing, 0, 2048, 0, 0)
    write(name, bytes(head) + data)

def dpx10(name, be, w, h, ch, desc, methodB, pads=None):
    data = b''
    for y in range(h):
        ws = pack10([v10(x, y, c) for x in range(w) for c in range(ch)], methodB, pads)
        data += b''.join(struct.pack('>I' if be else '<I', v) for v in ws)
    dpx(name, be, w, h, desc, 10, 2 if methodB else 1, data)

dpx10('dpx_10bit_rgb.dpx', True, 29, 17, 3, 50, False)
dpx10('dpx_10bit_rgba_le.dpx', False, 23, 13, 4, 51, True, pads=lambda k: 3 if k % 17 == 0 else 0)
w, h = 37, 15
dpx('dpx_8bit_padded.dpx', True, w, h, 6, 8, 1, b''.join(bytes(smooth(x, y, 0, 255) for x in range(w)) + bytes(3) for y in range(h)))
w, h = 21, 11
dpx('dpx_16bit_le.dpx', False, w, h, 50, 16, 1, b''.join(b''.join(struct.pack('<H', smooth(x, y, c, 65535)) for x in range(w) for c in range(3)) + bytes(2) for y in range(h)))

# Cineon: 10 bits three to a word, big-endian; 8 bits
def cineon(name, w, h, bits, data):
    head = bytearray(1024)
    struct.pack_into('>IIIIII', head, 0, 0x802A5FD7, 1024, 1024, 0, 0, 1024 + len(data))
    head[192] = 0; head[193] = 3
    for k in range(3):
        head[196 + 28 * k + 1] = k + 1; head[196 + 28 * k + 2] = bits
        struct.pack_into('>II', head, 196 + 28 * k + 4, w, h)
    head[680] = 0; head[681] = 5
    write(name, bytes(head) + data)

w, h = 31, 14
cineon('cin_10bit.cin', w, h, 10, b''.join(struct.pack('>I', v) for y in range(h) for v in pack10([v10(x, y, c) for x in range(w) for c in range(3)])))
w, h = 24, 10
cineon('cin_8bit.cin', w, h, 8, b''.join(bytes(smooth(x, y, c, 255) for x in range(w) for c in range(3)) for y in range(h)))

# FITS: 16-bit integers, three planes of bytes, floats
def fits(name, cards, data):
    head = b''.join(c.ljust(80).encode() for c in cards + ['END'])
    head += b' ' * ((-len(head)) % 2880)
    write(name, head + data + bytes((-len(data)) % 2880))
card = lambda k, v: '%-8s= %20s' % (k, v)
w, h = 33, 19
fits('fits_16.fits', [card('SIMPLE', 'T'), card('BITPIX', 16), card('NAXIS', 2), card('NAXIS1', w), card('NAXIS2', h), card('BZERO', 32768)],
     b''.join(struct.pack('>H', smooth(x, y, 0, 65535)) for y in range(h) for x in range(w)))
w, h = 27, 16
fits('fits_rgb.fits', [card('SIMPLE', 'T'), card('BITPIX', 8), card('NAXIS', 3), card('NAXIS1', w), card('NAXIS2', h), card('NAXIS3', 3)],
     b''.join(bytes(smooth(x, y, c, 255) for x in range(w)) for c in range(3) for y in range(h)))
w, h = 19, 12
fits('fits_float.fits', [card('SIMPLE', 'T'), card('BITPIX', -32), card('NAXIS', 2), card('NAXIS1', w), card('NAXIS2', h)],
     b''.join(struct.pack('>f', smooth(x, y, 0, 1000) / 7.0) for y in range(h) for x in range(w)))

# VICAR: bytes in records longer than a row, a binary header line; HALF
# bands one after the other
def vicar(name, label, recsize, body, nlb=0):
    lbl = len(label) + 16
    lbl = (lbl + recsize - 1) // recsize * recsize
    text = ('LBLSIZE=%d ' % lbl + label).ljust(lbl).encode()
    write(name, text + bytes(nlb * recsize) + body)
w, h = 30, 18
vicar('vicar_byte.img', "FORMAT='BYTE' TYPE='IMAGE' ORG='BSQ' NL=%d NS=%d NB=1 NBB=0 NLB=1 RECSIZE=%d" % (h, w, w + 4), w + 4,
      b''.join(bytes(smooth(x, y, 0, 255) for x in range(w)) + b'\0\0\0\0' for y in range(h)), nlb=1)
w, h = 22, 13
vicar('vicar_half3.img', "FORMAT='HALF' TYPE='IMAGE' ORG='BSQ' NL=%d NS=%d NB=3 NBB=0 NLB=0 RECSIZE=%d INTFMT='HIGH'" % (h, w, 2 * w), 2 * w,
      b''.join(struct.pack('>H', smooth(x, y, c, 4095)) for c in range(3) for y in range(h) for x in range(w)))

# DICOM: implicit little-endian without a preamble, a sequence of
# undefined length before the pixels; explicit with a preamble, RGB planes
def el_i(g, e, v): return struct.pack('<HHI', g, e, len(v)) + v
def el_e(g, e, vr, v):
    if vr in (b'OB', b'OW', b'SQ', b'UN', b'UT'): return struct.pack('<HH', g, e) + vr + b'\0\0' + struct.pack('<I', len(v)) + v
    return struct.pack('<HH', g, e) + vr + struct.pack('<H', len(v)) + v
w, h = 26, 20
px = b''.join(struct.pack('<H', smooth(x, y, 0, 4095)) for y in range(h) for x in range(w))
seq = struct.pack('<HHI', 0x0008, 0x1140, 0xFFFFFFFF) + struct.pack('<HHI', 0xFFFE, 0xE000, 0xFFFFFFFF) \
      + el_i(0x0008, 0x1150, b'1.2.3\0') + struct.pack('<HHI', 0xFFFE, 0xE00D, 0) + struct.pack('<HHI', 0xFFFE, 0xE0DD, 0)
write('dicom_implicit.dcm', el_i(0x0008, 0x0005, b'ISO_IR 100') + seq + el_i(0x0028, 0x0002, struct.pack('<H', 1))
      + el_i(0x0028, 0x0010, struct.pack('<H', h)) + el_i(0x0028, 0x0011, struct.pack('<H', w))
      + el_i(0x0028, 0x0100, struct.pack('<H', 16)) + el_i(0x7FE0, 0x0010, px))
w, h = 18, 12
ts = b'1.2.840.10008.1.2.1\0'
meta = el_e(0x0002, 0x0010, b'UI', ts)
px = b''.join(bytes(smooth(x, y, c, 255) for y in range(h) for x in range(w)) for c in range(3))
write('dicom_rgb_planes.dcm', bytes(128) + b'DICM' + el_e(0x0002, 0x0000, b'UL', struct.pack('<I', len(meta))) + meta
      + el_e(0x0028, 0x0002, b'US', struct.pack('<H', 3)) + el_e(0x0028, 0x0006, b'US', struct.pack('<H', 1))
      + el_e(0x0028, 0x0010, b'US', struct.pack('<H', h)) + el_e(0x0028, 0x0011, b'US', struct.pack('<H', w))
      + el_e(0x0028, 0x0100, b'US', struct.pack('<H', 8)) + el_e(0x7FE0, 0x0010, b'OB', px))

# OpenEXR, one part, scanlines, uncompressed: halves (y from 5), floats
def exr(name, names, ptype, w, h, ymin, val):
    def attr(n, t, v): return n.encode() + b'\0' + t.encode() + b'\0' + struct.pack('<I', len(v)) + v
    chl = b''.join(c.encode() + b'\0' + struct.pack('<iBBBBii', ptype, 0, 0, 0, 0, 1, 1) for c in names) + b'\0'
    head = b'\x76\x2f\x31\x01' + struct.pack('<I', 2)
    head += attr('channels', 'chlist', chl) + attr('compression', 'compression', b'\0')
    head += attr('dataWindow', 'box2i', struct.pack('<4i', 0, ymin, w - 1, ymin + h - 1))
    head += attr('displayWindow', 'box2i', struct.pack('<4i', 0, ymin, w - 1, ymin + h - 1))
    head += attr('lineOrder', 'lineOrder', b'\0') + attr('pixelAspectRatio', 'float', struct.pack('<f', 1.0))
    head += attr('screenWindowCenter', 'v2f', struct.pack('<2f', 0, 0)) + attr('screenWindowWidth', 'float', struct.pack('<f', 1.0)) + b'\0'
    bs = 2 if ptype == 1 else 4
    line = w * len(names) * bs
    table = len(head) + 8 * h
    offs = b''.join(struct.pack('<Q', table + y * (8 + line)) for y in range(h))
    blocks = b''
    for y in range(h):
        blocks += struct.pack('<iI', ymin + y, line)
        for c in range(len(names)):
            for x in range(w):
                v = val(x, y, c)
                blocks += struct.pack('<e', v) if ptype == 1 else struct.pack('<f', v)
    write(name, head + offs + blocks)
exr('exr_half.exr', ['B', 'G', 'R'], 1, 25, 14, 5, lambda x, y, c: smooth(x, y, c, 255) / 64.0)
exr('exr_float.exr', ['Y', 'Z'], 2, 16, 9, 0, lambda x, y, c: smooth(x, y, c, 1000) / 9.0)

# ---------- containers: TIFF, PSD, IFF ----------
out = os.path.join(root, 'cont'); os.makedirs(out, exist_ok=True)

def packbits(data, linelen, randomly=False):
    o = bytearray()
    for s in range(0, len(data), linelen):
        line = data[s:s + linelen]; i = 0
        while i < len(line):
            r = 1
            while i + r < len(line) and r < 128 and line[i + r] == line[i]: r += 1
            if randomly and r > 2: r = 2 + rand() % (r - 1)
            if r >= 2:
                o += bytes([257 - r, line[i]]); i += r; continue
            j = i + 1
            while j < len(line) and j - i < 128 and not (j + 1 < len(line) and line[j] == line[j + 1]): j += 1
            if randomly: j = i + 1 + rand() % (j - i)
            o += bytes([j - i - 1]) + line[i:j]; i = j
    return bytes(o)

# TIFF: entries (tag, type, values); strips or tiles laid where asked
def tiff(name, be, entries_fn, big=False):
    e = '>' if be else '<'
    data, entries = entries_fn()
    head_len = 16      # the classic header in 8, then 8 zero bytes: data offsets from 16 either way
    blob = bytearray(head_len) + data
    def put(fmt, v): return struct.pack(e + fmt, v)
    tsz = {3: 2, 4: 4, 16: 8}
    ents = []; extra = bytearray()
    ifd_at = len(blob)
    n = len(entries)
    es = 20 if big else 12
    after = ifd_at + (8 if big else 2) + n * es + (8 if big else 4)
    for tag, typ, vals in sorted(entries):
        raw = b''.join(put({2: 'H', 4: 'I', 8: 'Q'}[tsz[typ]], v) for v in vals)
        inl = 8 if big else 4
        if len(raw) <= inl: val = raw.ljust(inl, b'\0')
        else: val = put('Q' if big else 'I', after + len(extra)); extra += raw + (b'\0' if len(raw) & 1 else b'')
        ents.append(put('H', tag) + put('H', typ) + put('Q' if big else 'I', len(vals)) + val)
    ifd = put('Q' if big else 'H', n) + b''.join(ents) + put('Q' if big else 'I', 0)
    blob += ifd + extra
    if big: blob[0:16] = (b'MM' if be else b'II') + put('H', 43) + put('H', 8) + put('H', 0) + put('Q', ifd_at)
    else: blob[0:8] = (b'MM' if be else b'II') + put('H', 42) + put('I', ifd_at)
    write(name, bytes(blob))

def rgb_rows(w, h, two=False):
    return [b''.join((struct.pack('>H', smooth(x, y, c, 65535)) if two else bytes([smooth(x, y, c, 255)])) for x in range(w) for c in range(3)) for y in range(h)]

def tiff_strips(w, h, rps, rowfn, spp, bps, comp=1, planar=1, gap=0, be=False):
    def fn():
        data = bytearray(); offs = []; cnts = []
        planes = spp if planar == 2 else 1
        for p in range(planes):
            for s in range(0, h, rps):
                rows = b''.join(rowfn(y, p) for y in range(s, min(h, s + rps)))
                if comp == 32773: rows = packbits(rows, len(rowfn(0, p)))
                offs.append(16 + len(data)); cnts.append(len(rows)); data += rows + bytes(gap)
        ents = [(256, 3, [w]), (257, 3, [h]), (258, 3, [bps] * spp), (259, 3, [comp]), (262, 3, [2 if spp >= 3 else 1]),
                (273, 4, offs), (277, 3, [spp]), (278, 3, [rps]), (279, 4, cnts), (284, 3, [planar])]
        return bytes(data), ents
    return fn

w, h = 37, 23
rr = rgb_rows(w, h)
tiff('tiff_rgb_strips.tif', False, tiff_strips(w, h, 5, lambda y, p: rr[y], 3, 8))
rr16 = rgb_rows(21, 13, True)
tiff('tiff_rgb16_mm.tif', True, tiff_strips(21, 13, 4, lambda y, p: rr16[y], 3, 16, be=True))
gray = [bytes(((x // 5) * 30 + (y // 3) * 7) % 256 if (x + y) % 9 else 200 for x in range(53)) for y in range(31)]
tiff('tiff_packbits.tif', False, tiff_strips(53, 31, 8, lambda y, p: gray[y], 1, 8, comp=32773))
tiff('tiff_planar_gap.tif', True, tiff_strips(29, 17, 17, lambda y, p: bytes(smooth(x, y, p, 255) for x in range(29)), 3, 8, planar=2, gap=3))
def tiles():
    tw = th = 16; W, H = 40, 24; data = bytearray(); offs = []; cnts = []
    for ty in range(0, H, th):
        for tx in range(0, W, tw):
            t = b''.join(bytes(smooth(tx + x, ty + y, 0, 255) for x in range(tw)) for y in range(th))
            offs.append(16 + len(data)); cnts.append(len(t)); data += t
    ents = [(256, 3, [W]), (257, 3, [H]), (258, 3, [8]), (259, 3, [1]), (262, 3, [1]), (277, 3, [1]),
            (322, 3, [tw]), (323, 3, [th]), (324, 4, offs), (325, 4, cnts)]
    return bytes(data), ents
tiff('tiff_tiles.tif', False, tiles)
tiff('tiff_big.tif', False, tiff_strips(19, 11, 11, lambda y, p: rgb_rows(19, 11)[y], 3, 8), big=True)

# PSD: a raw composite; a layered one, RLE channels, a mask, an RLE composite
def psd(name, w, h, ch, layers, rle):
    head = b'8BPS' + struct.pack('>H', 1) + bytes(6) + struct.pack('>HIIHH', ch, h, w, 8, 3)
    head += struct.pack('>I', 0) + struct.pack('>I', 12) + b'8BIM\x03\xed\x00\x00\x00\x00\x00\x00'
    def plane_data(planes, rows, width, use_rle):
        if not use_rle: return struct.pack('>H', 0) + b''.join(planes)
        rows_enc = [packbits(pl[y * width:(y + 1) * width], width) for pl in planes for y in range(rows)]
        return struct.pack('>H', 1) + b''.join(struct.pack('>H', len(r)) for r in rows_enc) + b''.join(rows_enc)
    recs = b''; chdata = b''
    for (top, left, lh, lw, mask) in layers:
        chans = [(c, bytes(smooth(x + c * 3, y, c, 255) for y in range(lh) for x in range(lw))) for c in (-1, 0, 1, 2)]
        if mask: chans.append((-2, bytes(255 if (x - mask[1] // 2) ** 2 + (y - mask[0] // 2) ** 2 < 40 else 0 for y in range(mask[0]) for x in range(mask[1]))))
        recs += struct.pack('>iiiiH', top, left, top + lh, left + lw, len(chans))
        datas = []
        for cid, pl in chans:
            ph, pw = (mask[0], mask[1]) if cid == -2 else (lh, lw)
            dd = plane_data([pl], ph, pw, rle); datas.append(dd)
            recs += struct.pack('>hI', cid, len(dd))
        maskdata = struct.pack('>I', 20) + struct.pack('>iiii', top, left, top + mask[0], left + mask[1]) + b'\0\0\0\0' if mask else struct.pack('>I', 0)
        extra = maskdata + struct.pack('>I', 0) + bytes([4]) + b'name'[:3] + b'\0' * 0
        extra = maskdata + struct.pack('>I', 0) + b'\x03abc'
        recs += b'8BIMnorm' + bytes([255, 0, 0, 0]) + struct.pack('>I', len(extra)) + extra
        chdata += b''.join(datas)
    li = struct.pack('>h', len(layers)) + recs + chdata
    if len(li) & 1: li += b'\0'
    lm = (struct.pack('>I', len(li)) + li + struct.pack('>I', 0)) if layers else b''
    head += struct.pack('>I', len(lm)) + lm
    comp = [bytes(smooth(x, y, c, 255) for y in range(h) for x in range(w)) for c in range(ch)]
    write(name, head + plane_data(comp, h, w, rle))
psd('psd_raw.psd', 31, 19, 3, [], False)
psd('psd_layers_rle.psd', 33, 21, 3, [(2, 3, 12, 15, None), (5, 1, 9, 10, (8, 6))], True)
# one layer the size of the image, raw: its channels are the composite's
# planes byte for byte (the layer's pixels are the composite's: same smooth())
def psd_dup(name, w, h):
    comp = [bytes(smooth(x, y, c, 255) for y in range(h) for x in range(w)) for c in range(3)]
    recs = struct.pack('>iiiiH', 0, 0, h, w, 3)
    for c in range(3): recs += struct.pack('>hI', c, 2 + w * h)
    extra = struct.pack('>I', 0) + struct.pack('>I', 0) + b'\x03abc'
    recs += b'8BIMnorm' + bytes([255, 0, 0, 0]) + struct.pack('>I', len(extra)) + extra
    li = struct.pack('>h', 1) + recs + b''.join(struct.pack('>H', 0) + comp[c] for c in range(3))
    if len(li) & 1: li += b'\0'
    lm = struct.pack('>I', len(li)) + li + struct.pack('>I', 0)
    head = b'8BPS' + struct.pack('>H', 1) + bytes(6) + struct.pack('>HIIHH', 3, h, w, 8, 3) + struct.pack('>I', 0) + struct.pack('>I', 0)
    write(name, head + struct.pack('>I', len(lm)) + lm + struct.pack('>H', 0) + b''.join(comp))
psd_dup('psd_dup.psd', 28, 18)

# IFF: ILBM 5 planes ByteRun1, PBM, ACBM, ILBM 24 planes uncompressed
def iff(name, typ, w, h, planes, comp, body, cmap=True):
    bmhd = struct.pack('>HHhhBBBBHBBhh', w, h, 0, 0, planes, 0, comp, 0, 0, 10, 11, w, h)
    chunks = b'BMHD' + struct.pack('>I', 20) + bmhd
    if cmap and planes <= 8:
        cm = bytes((i * 37 + k * 11) % 256 for i in range(1 << min(planes, 8)) for k in range(3))
        chunks += b'CMAP' + struct.pack('>I', len(cm)) + cm + (b'\0' if len(cm) & 1 else b'')
    tag = b'ABIT' if typ == b'ACBM' else b'BODY'
    chunks += tag + struct.pack('>I', len(body)) + body + (b'\0' if len(body) & 1 else b'')
    write(name, b'FORM' + struct.pack('>I', 4 + len(chunks)) + typ + chunks)
def bitplanes(w, h, planes, val, plane_major=False):
    rb = (w + 15) // 16 * 2; rows = {}
    for y in range(h):
        for p in range(planes):
            bits = [(val(x, y) >> p) & 1 for x in range(w)] + [0] * (rb * 8 - w)
            rows[(y, p)] = bytes(sum(bits[i * 8 + k] << (7 - k) for k in range(8)) for i in range(rb))
    order = [(y, p) for p in range(planes) for y in range(h)] if plane_major else [(y, p) for y in range(h) for p in range(planes)]
    return b''.join(rows[k] for k in order), rb
blobv = lambda x, y: ((x // 4) + (y // 3)) % 32 if (x - 18) ** 2 + (y - 10) ** 2 < 90 else 3
b5, rb = bitplanes(37, 21, 5, blobv)
iff('ilbm_5planes.iff', b'ILBM', 37, 21, 5, 1, packbits(b5, rb))
pw = 30
pbm_rows = b''.join(bytes(smooth(x, y, 0, 255) for x in range(pw)) for y in range(14))
iff('pbm_chunky.lbm', b'PBM ', pw, 14, 8, 1, packbits(pbm_rows, pw))
b4, rb = bitplanes(25, 13, 4, lambda x, y: (x + 2 * y) % 16, plane_major=True)
iff('acbm_4planes.acbm', b'ACBM', 25, 13, 4, 0, b4)
b24, rb = bitplanes(20, 9, 24, lambda x, y: (smooth(x, y, 0, 255)) | (smooth(x, y, 1, 255) << 8) | (smooth(x, y, 2, 255) << 16))
iff('ilbm_24.iff', b'ILBM', 20, 9, 24, 0, b24, cmap=False)
# RGBN and RGB8 (Impulse): a pixel and its count, runs across rows; counts
# inline, in a byte (the inline count 0) and in a word (the byte 0 too)
def impulse(w, h, val, rgb8, forms):
    px = [val(x, y) for y in range(h) for x in range(w)]
    out = bytearray(); i = 0; k = 0
    cmax = 127 if rgb8 else 7
    while i < len(px):
        n = 1
        while i + n < len(px) and px[i + n] == px[i] and n < 65535: n += 1
        f = forms[k % len(forms)]; k += 1
        if f == 0 and n > cmax: n = cmax
        if f == 1 and n > 255: n = 255
        r, g, b, gl = px[i]
        inl = n if f == 0 else 0
        if rgb8: out += bytes((r, g, b, (gl << 7) | inl))
        else: out += struct.pack('>H', (r << 12) | (g << 8) | (b << 4) | (gl << 3) | inl)
        if f == 1: out.append(n)
        if f == 2: out += b'\0' + struct.pack('>H', n)
        i += n
    return bytes(out)
def iff_rgb(name, typ, w, h, body):
    bmhd = struct.pack('>HHhhBBBBHBBhh', w, h, 0, 0, 13 if typ == b'RGBN' else 25, 0, 4, 0, 0, 10, 11, w, h)
    chunks = b'BMHD' + struct.pack('>I', 20) + bmhd
    chunks += b'BODY' + struct.pack('>I', len(body)) + body + (b'\0' if len(body) & 1 else b'')
    write(name, b'FORM' + struct.pack('>I', 4 + len(chunks)) + typ + chunks)
iff_rgb('rgbn_runs.rgbn', b'RGBN', 41, 23, impulse(41, 23,
    lambda x, y: (smooth(x, y, 0, 15) if x < 20 else 9, smooth(x, y, 1, 15) // 4 * 4, 3 if y > 15 else smooth(x, y, 2, 15), int(x == y)),
    False, [0, 1, 0, 2]))
iff_rgb('rgb8_runs.rgb8', b'RGB8', 33, 19, impulse(33, 19,
    lambda x, y: (smooth(x, y, 0, 255) // 16 * 16, 200 if x < 12 else smooth(x, y, 1, 255), (x // 7) * 30, int(y < 3)),
    True, [0, 0, 1, 2]))

# MIFF: DirectClass as it is (new header end ':' ^Z), PseudoClass run-length
# (the old end: form feed, line feed, ':', line feed), 16 bits, RGBA RLE
def miff_rle(pixels, ps):
    out = bytearray(); i = 0; n = len(pixels) // ps
    while i < n:
        r = 1
        while i + r < n and r < 256 and pixels[(i + r) * ps:(i + r + 1) * ps] == pixels[i * ps:(i + 1) * ps]: r += 1
        out += pixels[i * ps:(i + 1) * ps] + bytes([r - 1]); i += r
    return bytes(out)
w, h = 29, 17
write('miff_direct.miff', b'id=ImageMagick  version=1.0\nclass=DirectClass  colors=0  matte=False\ncolumns=%d  rows=%d  depth=8\n{a comment: here}\n\x0c\n:\x1a' % (w, h)
      + b''.join(bytes([smooth(x, y, c, 255) for c in range(3)]) for y in range(h) for x in range(w)))
w, h = 33, 21
idx = bytes(((x // 5) + (y // 4)) % 12 if (x + y) % 7 else 3 for y in range(h) for x in range(w))
cmap = bytes((i * 23 + k * 61) % 256 for i in range(12) for k in range(3))
write('miff_pseudo_rle.miff', b'{\n  made by mksamples\n}\nid=ImageMagick\nclass=PseudoClass  colors=12\ncompression=RunlengthEncoded\ncolumns=%d  rows=%d\n\x0c\n:\n' % (w, h)
      + cmap + miff_rle(idx, 1))
w, h = 19, 11
write('miff_16.miff', b'id=ImageMagick\nclass=DirectClass  matte=False\ncolumns=%d  rows=%d  depth=16\n\x0c\n:\x1a' % (w, h)
      + b''.join(struct.pack('>3H', *[smooth(x, y, c, 65535) for c in range(3)]) for y in range(h) for x in range(w)))
w, h = 24, 14
rgba = b''.join(bytes([smooth(x // 3 * 3, y // 2 * 2, c, 255) for c in range(3)] + [255]) for y in range(h) for x in range(w))
write('miff_rgba_rle.miff', b'id=ImageMagick\nclass=DirectClass  alpha-trait=Blend\ncompression=RLE\ncolumns=%d  rows=%d  depth=8\n\x0c\n:\x1a' % (w, h) + miff_rle(rgba, 4))

# XCF (GIMP, version 0): two layers (RGBA across two tiles, RGB), the
# first with a mask; tiles run-length coded the way GIMP does
def xcf_rle(plane):
    out = bytearray(); i = 0; n = len(plane)
    while i < n:
        r = 1
        while i + r < n and plane[i + r] == plane[i] and r < 32768: r += 1
        if r >= 2:
            out += (bytes([r - 1, plane[i]]) if r < 128 else bytes([127, r >> 8, r & 255, plane[i]])); i += r; continue
        j = i + 1
        while j < n and not (j + 1 < n and plane[j] == plane[j + 1]) and j - i < 32768: j += 1
        c = j - i
        out += (bytes([256 - c]) if c < 128 else bytes([128, c >> 8, c & 255])) + plane[i:j]; i = j
    return bytes(out)
def xcf(name, w, h, layers):
    head = bytearray(b'gimp xcf file\0' + struct.pack('>III', w, h, 0))
    head += struct.pack('>II', 17, 1) + b'\x01' + struct.pack('>II', 0, 0)    # compression RLE, end
    ptr_at = len(head)
    head += bytes(4 * (len(layers) + 1) + 4)                                  # layer pointers, 0, channel 0
    blob = bytearray(head)
    def level(lw, lh, bpp, px):
        tiles = []
        for ty in range(0, lh, 64):
            for tx in range(0, lw, 64):
                tw, th = min(64, lw - tx), min(64, lh - ty)
                t = b''
                for c in range(bpp):
                    t += xcf_rle(bytes(px(tx + x, ty + y, c) for y in range(th) for x in range(tw)))
                tiles.append(t)
        lv = len(blob)
        blob.extend(struct.pack('>II', lw, lh)); tp = len(blob); blob.extend(bytes(4 * (len(tiles) + 1)))
        for k, t in enumerate(tiles):
            struct.pack_into('>I', blob, tp + 4 * k, len(blob)); blob.extend(t)
        hi = len(blob)
        blob.extend(struct.pack('>IIII', lw, lh, bpp, lv) + struct.pack('>I', 0))
        return hi
    lptrs = []
    for (lw, lh, bpp, px, mask) in layers:
        hier = level(lw, lh, bpp, px)
        mptr = 0
        if mask:
            mh = level(lw, lh, 1, mask)
            mptr = len(blob)
            blob.extend(struct.pack('>II', lw, lh) + struct.pack('>I', 5) + b'mask\0' + struct.pack('>II', 0, 0) + struct.pack('>I', mh))
        lptrs.append(len(blob))
        blob.extend(struct.pack('>III', lw, lh, 1 if bpp == 4 else 0) + struct.pack('>I', 6) + b'layer\0'
                    + struct.pack('>II', 0, 0) + struct.pack('>II', hier, mptr))
    for k, lp in enumerate(lptrs): struct.pack_into('>I', blob, ptr_at + 4 * k, lp)
    write(name, bytes(blob))
xcf('xcf_layers.xcf', 70, 40, [(70, 40, 4, lambda x, y, c: 255 if c == 3 else smooth(x, y, c, 255), lambda x, y, c: 255 if (x - 35) ** 2 + (y - 20) ** 2 < 300 else 0),
                               (30, 20, 3, lambda x, y, c: ((x // 6) * 40 + c * 70) % 256, None)])

# PICT: version 2 with an 8-bit PackBitsRect (a colour table) and a 32-bit
# DirectBitsRect (packType 4: a row's planes), version 1 with a 1-bit one
def pict_rows(rows, rb):
    out = b''
    for r in rows:
        e = packbits(r, len(r))
        out += (struct.pack('>H', len(e)) if rb > 250 else bytes([len(e)])) + e
    return out
def pict2(name, ops, w, h):
    body = struct.pack('>H', 0) + struct.pack('>4h', 0, 0, h, w) + b'\x00\x11\x02\xff' + b'\x0c\x00' + bytes(24) + ops
    if len(body) & 1: body += b'\0'
    write(name, bytes(512) + body + b'\x00\xff')
def pixmap(rb, w, h, pt, ps, cmpc, cmps):
    return struct.pack('>H4h', rb | 0x8000, 0, 0, h, w) + struct.pack('>HHIIIHHHHIII', 0, pt, 0, 0x480000, 0x480000, 16 if ps > 8 else 0, ps, cmpc, cmps, 0, 0, 0)
w, h = 45, 21
rb = 46
rows = [bytes(((x // 4) + (y // 3)) % 20 if x < w else 0 for x in range(rb)) for y in range(h)]
ctab = struct.pack('>IHH', 0, 0, 19) + b''.join(struct.pack('>4H', i, i * 3000 % 65536, i * 7000 % 65536, i * 11000 % 65536) for i in range(20))
op98 = struct.pack('>H', 0x98) + pixmap(rb, w, h, 0, 8, 1, 8) + ctab + struct.pack('>4h', 0, 0, h, w) * 2 + struct.pack('>H', 0) + pict_rows(rows, rb)
pict2('pict_indexed.pict', op98, w, h)
w, h = 33, 17
rb = 4 * w
rows = [b''.join(bytes(smooth(x, y, c, 255) for x in range(w)) for c in range(3)) for y in range(h)]
op9a = struct.pack('>HI', 0x9A, 0xFF) + pixmap(rb, w, h, 4, 32, 3, 8) + struct.pack('>4h', 0, 0, h, w) * 2 + struct.pack('>H', 0) + pict_rows(rows, rb)
pict2('pict_direct32.pict', op9a, w, h)
# version 1: one-byte opcodes, a 1-bit PackBitsRect
w, h = 70, 25
rb = 10
rows = [pack1([1 if (x * 3 + y * 5) % 11 < 4 else 0 for x in range(w)]).ljust(rb, b'\0') for y in range(h)]
v1 = struct.pack('>H', 0) + struct.pack('>4h', 0, 0, h, w) + b'\x11\x01' + b'\x98' + struct.pack('>H4h', rb, 0, 0, h, w) \
     + struct.pack('>4h', 0, 0, h, w) * 2 + struct.pack('>H', 0) + pict_rows(rows, rb) + b'\xff'
write('pict_v1_bitmap.pict', bytes(512) + v1)

# PSD: a layer that nearly is the composite (a few pixels differ, so no
# plane is a copy): the composite coded against it
def psd_near(name, w, h):
    layer = [bytes(smooth(x, y, c, 255) for y in range(h) for x in range(w)) for c in range(3)]
    comp = [bytearray(p) for p in layer]
    for c in range(3):
        for k in range(0, w * h, 37): comp[c][k] = (comp[c][k] + 50) % 256
    def rle_plane(pl):
        rows = [packbits(pl[y * w:(y + 1) * w], w) for y in range(h)]
        return b''.join(struct.pack('>H', len(r)) for r in rows) + b''.join(rows)
    recs = struct.pack('>iiiiH', 0, 0, h, w, 3)
    datas = [struct.pack('>H', 1) + rle_plane(layer[c]) for c in range(3)]
    for c in range(3): recs += struct.pack('>hI', c, len(datas[c]))
    extra = struct.pack('>I', 0) + struct.pack('>I', 0) + b'\x03abc'
    recs += b'8BIMnorm' + bytes([255, 0, 0, 0]) + struct.pack('>I', len(extra)) + extra
    li = struct.pack('>h', 1) + recs + b''.join(datas)
    if len(li) & 1: li += b'\0'
    lm = struct.pack('>I', len(li)) + li + struct.pack('>I', 0)
    head = b'8BPS' + struct.pack('>H', 1) + bytes(6) + struct.pack('>HIIHH', 3, h, w, 8, 3) + struct.pack('>I', 0) + struct.pack('>I', 0)
    rows = [packbits(bytes(comp[c][y * w:(y + 1) * w]), w) for c in range(3) for y in range(h)]
    write(name, head + struct.pack('>I', len(lm)) + lm + struct.pack('>H', 1)
          + b''.join(struct.pack('>H', len(r)) for r in rows) + b''.join(rows))
psd_near('psd_nearcopy.psd', 40, 26)
