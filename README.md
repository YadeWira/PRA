# PRA

**packRaster Algorithm**: lossless recompression of uncompressed and
RLE-coded raster images (PNM, BMP, Radiance HDR and more), in FreePascal,
with a C core where it pays and some x86-64 assembly; no libraries.

The spiritual successor of [packPNM](https://github.com/YadeWira/packRAW):
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
images: ICO, CUR, DCX, Netpbm images in a row, DDS mipmaps; see
[doc/FORMATS.md](doc/FORMATS.md) for what comes next.

On the Netpbm, BMP and HDR files of a local corpus that both give back,
PRA's output is 11% smaller than packPNM's ([doc/CODEC.md](doc/CODEC.md)).

Status: in development. The codec: [doc/CODEC.md](doc/CODEC.md); limits: [doc/POLICY.md](doc/POLICY.md). Built bottom-up, each layer with its tests:

| Layer | Unit | Status |
|---|---|---|
| hash (BLAKE3-128) | `pas/prablake3.pas` | done, from PJA |
| binary arithmetic coder | `pas/praarith.pas` | done, from PJA |
| raster layout, limits | `pas/praraster.pas`, `pas/pralimits.pas` | done |
| Netpbm parser (P1-P7, PF/Pf) | `pas/prapnm.pas` | done |
| plain Netpbm text, any writer | `pas/praplain.pas` | done |
| BMP and Radiance HDR parsers | `pas/prabmp.pas`, `pas/prahdr.pas` | done |
| farbfeld, TGA, Sun Raster, WBMP, PCX, SGI, XWD, MTV, VIFF, VIPS, DDS | `pas/praother.pas` | done |
| run-length files, any writer | `pas/prarle.pas` | done (TGA, PCX, Sun Raster, SGI, BMP) |
| more formats | | [the list](doc/FORMATS.md) |
| model (counters, mixers, APM) | `pas/pramodel.pas` | first version |
| header and tail model | `pas/prabytes.pas` | first version |
| several images a file (ICO, CUR, DCX, Netpbm, DDS) | `pas/praparts.pas` | done |
| codec stream (versions 2 and 3) | `pas/pracodec.pas` | first version |
| container (`.pra`) | `pas/praformat.pas`, `pas/prapack.pas`, `pas/prafs.pas` | done ([doc/FORMAT.md](doc/FORMAT.md)) |
| command line (`pra`) | `pas/pracli.pas` | done ([doc/CLI.md](doc/CLI.md)) |

```sh
./run_tests.sh      # needs Free Pascal 3.2.2 and python3; builds and tests everything
fpc -O3 -dPRA_FAST -Fupas -Fipas -FUbuild -obuild/pra pas/pracli.pas   # just the command
```
 See [doc/FORMATS.md](doc/FORMATS.md) for the target
formats.

## License

MIT (see [LICENSE](LICENSE)). PRA is a new implementation: it takes ideas
from packPNM (LGPLv3) but none of its code.
