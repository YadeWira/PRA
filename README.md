# PRA

**packRaster Algorithm**: lossless recompression of uncompressed and
RLE-coded raster images (PNM, BMP, Radiance HDR and more), in FreePascal,
with a C core where it pays and some x86-64 assembly; no libraries.

The spiritual successor of [packPNM](https://github.com/packjpg/packPNM):
written from scratch, with a codec and container of its own; it shares no
code with packPNM and does not read its files.

```sh
pra a image.ppm          # -> image.pra
pra x image.pra          # -> image.ppm, the same file byte for byte
pra list image.pra       # original size, stored size, hash
```

The original comes back **byte for byte**, and nothing is written unless it
verified: `a` decompresses its own result and compares it with the input
first, and `x` checks the size and the BLAKE3 hash the `.pra` carries.
Today PRA takes PBM, PGM and PPM (binary and plain text), PAM and PFM, BMP
(uncompressed, bitfields, RLE8 and RLE4), Radiance HDR, TGA, PCX, SGI, Sun Raster (each
raw and run-length, given back byte for byte whoever wrote it), farbfeld,
WBMP, XWD, MTV, VIFF, VIPS and uncompressed DDS, and files of several
images: ICO, CUR, DCX, Netpbm images in a row, DDS mipmaps; and film and
science: DPX, Cineon (10 bits packed too), FITS, VICAR, uncompressed DICOM
and uncompressed OpenEXR; and containers: TIFF and BigTIFF (uncompressed
and PackBits), PSD and PSB (layers too), IFF ILBM, PBM and ACBM, MIFF,
GIMP's XCF, Macintosh PICT; see
[doc/FORMATS.md](doc/FORMATS.md) for what comes next.

PRA belongs to a family of recompressors that share that rule: the original
comes back byte for byte, and nothing is written unless it verified.

| Sibling | Formats | Successor of |
|---|---|---|
| [PMPA](https://github.com/YadeWira/PMPA) | MPEG audio (MP1, MP2, MP3) | [packMP3](https://github.com/YadeWira/packMP3), [packMP2](https://github.com/YadeWira/packMP2) |
| **PRA** | raster images (PNM, BMP, TIFF, PSD, HDR, ...) | [packPNM](https://github.com/packjpg/packPNM) |
| [PPA](https://github.com/YadeWira/PPA) | the PNG family (PNG, APNG, MNG, JNG) | [packPNG](https://github.com/YadeWira/packPNG) |
| [PAIA](https://github.com/YadeWira/PAIA) | animated images (GIF, WebP, FLI/FLC, ANI, ...) | (new) |
| [PJA](https://github.com/YadeWira/PJA) | JPEG and JPEG-LS | [packJPG](https://github.com/YadeWira/packJPG) |

On the Netpbm, BMP and HDR files of a local corpus that both give back,
PRA's output is 16% smaller than packPNM's; on all of them (136 MB, the ones
packPNM refuses or does not give back counted at their size) PRA makes
30.8% of the size and packPNM 86.9% ([doc/CODEC.md](doc/CODEC.md)).

## Speed and memory

About 0.6 MB/s a thread, both ways (decoding runs the same model), and the
bands of a big image on several threads (`-th`, up to 8 by default):

| file | size | `a`, 8 threads | `x`, 8 threads | `a`, 1 thread |
|---|---|---|---|---|
| a 10-bit Cineon, 4096 x 3112 | 51 MB | 15 s, 675 MB | 13 s, 401 MB | 81 s, 300 MB |
| a PSD of layers, 2400 x 3200 | 26 MB | 42 s, 716 MB | 38 s, 361 MB | |
| a PPM, plain text | 11 MB | 8 s, 140 MB | 7 s, 74 MB | |

Memory grows with the threads: each band has its models, and `a` decodes
each band beside it as it codes it, to check it.

Status: 0.1.0, the first release ([the releases](https://github.com/YadeWira/PRA/releases)). Until 1.0.0 the stream and the container may change with no promise: a `.pra` made by a 0.x may not open in a later version. From 1.0.0 on, what is released is read for ever. The codec: [doc/CODEC.md](doc/CODEC.md); limits: [doc/POLICY.md](doc/POLICY.md). Built bottom-up, each layer with its tests:

| Layer | Unit | Status |
|---|---|---|
| hash (BLAKE3-128) | `pas/prablake3.pas` | done, from PJA |
| binary arithmetic coder | `pas/praarith.pas` | done, from PJA |
| raster layout, limits | `pas/praraster.pas`, `pas/pralimits.pas` | done |
| Netpbm parser (P1-P7, PF/Pf) | `pas/prapnm.pas` | done |
| plain Netpbm text, any writer | `pas/praplain.pas` | done |
| DPX, Cineon, FITS, VICAR, DICOM, OpenEXR | `pas/prasci.pas` | done |
| TIFF, PSD (parts), IFF ILBM (bitplanes), PackBits | `pas/praparts.pas`, `pas/praother.pas`, `pas/prarle.pas` | done |
| BMP and Radiance HDR parsers | `pas/prabmp.pas`, `pas/prahdr.pas` | done |
| farbfeld, TGA, Sun Raster, WBMP, PCX, SGI, XWD, MTV, VIFF, VIPS, DDS | `pas/praother.pas` | done |
| run-length files, any writer | `pas/prarle.pas` | done (TGA, PCX, Sun Raster, SGI, BMP) |
| more formats | | [the list](doc/FORMATS.md) |
| model (counters, mixers, APM, match models) | `pas/pramodel.pas`, `pas/pracodec.pas` | second version |
| header and tail model | `pas/prabytes.pas` | first version |
| several images a file (ICO, CUR, DCX, Netpbm, DDS) | `pas/praparts.pas` | done |
| codec stream (versions 3 and 4) | `pas/pracodec.pas` | first version |
| container (`.pra`) | `pas/praformat.pas`, `pas/prapack.pas`, `pas/prafs.pas` | done ([doc/FORMAT.md](doc/FORMAT.md)) |
| command line (`pra`) | `pas/pracli.pas` | done ([doc/CLI.md](doc/CLI.md)) |

```sh
./run_tests.sh      # needs Free Pascal 3.2.2 and python3; builds and tests everything
fpc -O3 -dPRA_FAST -Fupas -Fipas -FUbuild -obuild/pra pas/pracli.pas   # just the command
```

## License

MIT (see [LICENSE](LICENSE)). PRA is a new implementation: it takes ideas
from packPNM (LGPLv3) but none of its code.
