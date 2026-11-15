# PRA

**packRaster Algorithm**: lossless recompression of **raster images**
(Netpbm, BMP, Radiance HDR, TIFF, PSD, DPX, FITS, DICOM, OpenEXR and some
forty more), in FreePascal, with some x86-64 assembly; no libraries. The
spiritual successor of [packPNM](https://github.com/packjpg/packPNM): a
new codec and format of its own, written from scratch (it does not read
packPNM's files), smaller and verified before anything is written.

| Component | Status |
|---|---|
| CI | [![CI][ciBadge]][ciLink] |
| Latest release | [![Release][relBadge]][relLink] |

```sh
pra a image.ppm          # -> image.pra, about 61% smaller on a corpus of every format
pra x image.pra          # -> image.ppm, the same file byte for byte
```

The original comes back **byte for byte**, header, comments, padding and
whatever follows the image included, and nothing is written under an
output's name unless it verified: compressing decompresses the result and
compares it with the input before writing, and extracting checks the size
and the BLAKE3 hash stored in the `.pra`.

The formats are not fixed yet: until a 0.9.x release fixes them, a `.pra`
made by one 0.x release may not open in a later one, which then refuses it
with a reason, never gives back a wrong file
([doc/STABILITY.md](doc/STABILITY.md)).

PRA belongs to a family of recompressors that share that rule: the original
comes back byte for byte, and nothing is written unless it verified.

| Sibling | Formats | Successor of |
|---|---|---|
| [PMPA](https://github.com/YadeWira/PMPA) | MPEG audio (MP1, MP2, MP3) | [packMP3](https://github.com/YadeWira/packMP3), [packMP2](https://github.com/YadeWira/packMP2) |
| **PRA** | raster images (PNM, BMP, TIFF, PSD, HDR, ...) | [packPNM](https://github.com/packjpg/packPNM) |
| [PPA](https://github.com/YadeWira/PPA) | the PNG family (PNG, APNG, MNG, JNG) | [packPNG](https://github.com/YadeWira/packPNG) |
| [PAIA](https://github.com/YadeWira/PAIA) | animated images (GIF, WebP, FLI/FLC, ANI, ...) | (new) |
| [POA](https://github.com/YadeWira/POA) | Ogg (Vorbis, Opus, FLAC, Speex, Theora) | (new) |
| [PDA](https://github.com/YadeWira/PDA) | documents (PDF, Office, OpenDocument, EPUB, CHM, ...) | (new) |
| [PJA](https://github.com/YadeWira/PJA) | JPEG, JPEG-LS and JPEG 2000 | [packJPG](https://github.com/YadeWira/packJPG) |

## What it handles

- **Netpbm and the simple rasters**: PBM, PGM, PPM (binary and plain
  text), PAM, PFM; BMP (raw, bitfields, RLE8, RLE4, bare DIBs); TGA, PCX,
  SGI, Sun Raster (raw and run-length, whoever wrote them), farbfeld, WBMP,
  XWD, MTV, VIFF, VIPS, uncompressed DDS; Radiance HDR.
- **Files of several images**: ICO, CUR, DCX, Netpbm images in a row, DDS
  mipmaps and cube maps.
- **Film and science**: DPX and Cineon (10 bits packed too), FITS (8 to 64
  bits, floats and doubles, extensions), VICAR, uncompressed DICOM and
  OpenEXR.
- **Containers**: TIFF and BigTIFF (uncompressed and PackBits, strips and
  tiles, every page), PSD and PSB (layers too; the composite coded against
  them), IFF (ILBM, PBM, ACBM, RGBN, RGB8), MIFF, GIMP's XCF, Macintosh
  PICT; MacBinary-wrapped files.

Inside a file it takes, what PRA does not model (a TIFF's LZW or JPEG
strips, a PSD's ZIP channels) goes through as bytes; anything else `pra a`
refuses, and says why ([details][wHandles]).

## Install

Download the command for your platform from the [latest release][relLink]:
Linux (x86-64, x86, arm64; glibc 2.34 or later), macOS (Apple silicon) or
Windows (x64, x86). Each build is tested by CI on its own platform, and a
`.pra` made on one opens on any other ([installing][wInstall],
[platforms][wPlat]).

```sh
pra a *.tif --output-dir=packed   # compress many
pra x packed/*.pra -o restored/   # and back
pra list packed/*.pra             # sizes and hashes
```

The command's manual is [doc/CLI.md](doc/CLI.md).

## Against other compressors

File by file, every file of a local corpus under 20 MB (638 MB, the
corpus's copies of each raster format), against xz and zstd and, on the
formats it takes, packPNM. Each set's whole output against its input; a
file a tool does not take, or does not give back byte for byte, counts at
its own size ([how, and the details][wComp]).

| set | files | size | xz -9e | zstd -19 | packPNM 1.6d | PRA |
|---|---|---|---|---|---|---|
| Netpbm (PBM, PGM, PPM, PAM, PFM) | 51 | 52.4 MB | 33.66% | 37.20% | 84.04% | **22.04%** |
| BMP | 42 | 24.7 MB | 27.21% | 30.03% | 61.43% | **16.90%** |
| Radiance HDR | 10 | 29.7 MB | 72.64% | 78.67% | 100.00% | **53.72%** |
| TIFF and BigTIFF | 130 | 162.9 MB | 66.03% | 69.52% | - | **61.00%** |
| PSD | 12 | 30.4 MB | 36.47% | 41.05% | - | **29.08%** |
| film and science (DPX, Cineon, FITS, VICAR, DICOM, OpenEXR) | 58 | 119.4 MB | 37.82% | 41.95% | - | **29.09%** |
| IFF, MIFF, XCF, PICT | 220 | 75.2 MB | 53.49% | 58.89% | - | **45.96%** |
| the rest (TGA, PCX, SGI, Sun, ICO, DDS, XWD, ...) | 216 | 143.0 MB | 42.95% | 48.14% | - | **27.12%** |
| **all** | 739 | 637.8 MB | 48.83% | 53.19% | - | **38.88%** |

Speed on 20 Netpbm and BMP files both take (6.8 MB; two Xeon E5-2697A v4;
"8 at once": `pra -th 8`, packPNM 8 processes):

| | packPNM 1.6d | PRA |
|---|---|---|
| compress, 1 thread | **1.5 s** | 13.4 s |
| decompress, 1 thread | **1.6 s** | 9.1 s |
| compress, 8 at once | **0.35 s** | 2.7 s |
| decompress, 8 at once | **0.45 s** | 3.2 s |

PRA is the smallest on every set: about a fifth below xz -9e overall, and
on Netpbm, BMP and HDR files a quarter to a third of what packPNM leaves
(packPNM gives back none of the HDR files). packPNM is about 9 times
faster; PRA codes about 0.3 MB/s a thread and decodes about 0.45 MB/s
(the model runs both ways), and spreads a big image's bands and several
files over the threads. On TIFF most of what PRA does not model is LZW,
Deflate or JPEG data, coded as bytes.

## Safe by design

PRA's first rule is that the original comes back byte for byte, or nothing
is written. Measured against packPNM on the same 20 files and the same
damage ([how][wSafe]):

| | PRA | packPNM 1.6d |
|---|---|---|
| 4,000 single-bit flips in the compressed file: a wrong file given back without an error | **0** | 3,745 |
| stores a hash of the original | **yes** (BLAKE3) | no |
| checks its output before writing it, by default | **yes** | no (`-ver` asks for it) |
| writes through a symbolic link at the output's name | **no** | no (takes another name) |
| killed while writing: a partial file under the output's name | **no** | yes |
| written promise that its files keep opening | not yet (a 0.9.x release fixes them; until then a newer release refuses an old file, never misreads it) | no |

It is design, not luck: a stored hash and size, a decode-and-compare before
writing, a temporary that takes the output's name only when it is complete
and on the disk (and is deleted on Ctrl-C), and a clean refusal of anything
it does not understand. What it does not do: repair a damaged `.pra` (keep
backups, or use an archiver with recovery records) or authenticate it (the
hash catches accidents, not tampering).

## Against archivers

Not measured yet: PRA has no 7-Zip codec nor zpaq-std plugin for now (both
planned, below). On its own, `pra` against xz and zstd is the table above.

## In 7-Zip and zpaq-std

Not yet. A 7-Zip codec (`libpra`, under the family's experimental method
IDs `03 7F 3x`) and PRA's codecs for [zpaq-std](https://github.com/YadeWira/zpaq-std)'s
`-sa` (each block with a ZPAQL decoder, so that any zpaq extracts it) are
planned ([zpaq-std][wPlugin], [7-Zip][wLib]).

## Reporting a bug

```sh
pra report scan.tif -o report.txt   # what happened, on which machine
```

It writes a plain-text report (PRA's build, the system, the command line,
and the file's size, hash and structure, but no pixels, no header
contents and no folder names) and prints a link that opens a [new
issue][issues] with it filled in. `--with-file` puts a copy of the file
beside it, to attach if you choose to ([details][wBugs],
[doc/CLI.md](doc/CLI.md#checking-and-reporting)).

## More

The [wiki][wiki] has the rest: [benchmarks][wComp], [safety][wSafe],
[building and testing][wBuild], [how it works][wHow], the [source
layout][wLayout], [FreePascal pitfalls][wFpc] and the [release
history][wRel]. The codec's full notes are in [doc/CODEC.md](doc/CODEC.md),
the file format in [doc/FORMAT.md](doc/FORMAT.md), the formats taken and
planned in [doc/FORMATS.md](doc/FORMATS.md), what does not change in
[doc/STABILITY.md](doc/STABILITY.md), the limits in
[doc/POLICY.md](doc/POLICY.md).

## Building

FreePascal 3.2 and python3; no C compiler:

```sh
./run_tests.sh                                                         # every test
fpc -O3 -dPRA_FAST -Fupas -Fipas -FUbuild -obuild/pra pas/pracli.pas   # the command
```

## License

MIT, see `LICENSE`. PRA takes ideas from packPNM (LGPLv3) but none of its
code; several units come from [PJA](https://github.com/YadeWira/PJA) (MIT).
See `NOTICE`.

[ciBadge]: https://github.com/YadeWira/PRA/actions/workflows/ci.yml/badge.svg "Continuous Integration"
[ciLink]: https://github.com/YadeWira/PRA/actions/workflows/ci.yml
[relBadge]: https://img.shields.io/github/v/release/YadeWira/PRA "Latest release"
[relLink]: https://github.com/YadeWira/PRA/releases/latest
[issues]: https://github.com/YadeWira/PRA/issues/new?template=bug_report.yml
[wiki]: https://github.com/YadeWira/PRA/wiki
[wComp]: https://github.com/YadeWira/PRA/wiki/Benchmarks
[wSafe]: https://github.com/YadeWira/PRA/wiki/Safety-and-robustness
[wHandles]: https://github.com/YadeWira/PRA/wiki/What-PRA-handles
[wInstall]: https://github.com/YadeWira/PRA/wiki/Installing
[wPlat]: https://github.com/YadeWira/PRA/wiki/Platforms
[wPlugin]: https://github.com/YadeWira/PRA/wiki/The-zpaq-std-plugin
[wLib]: https://github.com/YadeWira/PRA/wiki/Library-and-7-Zip
[wBugs]: https://github.com/YadeWira/PRA/wiki/Reporting-bugs
[wBuild]: https://github.com/YadeWira/PRA/wiki/Building
[wHow]: https://github.com/YadeWira/PRA/wiki/How-it-works
[wLayout]: https://github.com/YadeWira/PRA/wiki/Source-layout
[wFpc]: https://github.com/YadeWira/PRA/wiki/FreePascal-pitfalls
[wRel]: https://github.com/YadeWira/PRA/wiki/Releases
