# PRA

**packRaster Algorithm**: lossless recompression of uncompressed and
RLE-coded raster images (PNM, BMP, Radiance HDR and more), in FreePascal,
with a C core where it pays and some x86-64 assembly; no libraries.

The successor of [packPNM](https://github.com/YadeWira/packRAW): a new codec
and container of its own. The original comes back **byte for byte**, and
nothing is written unless it verified.

Status: design phase. See [doc/FORMATS.md](doc/FORMATS.md) for the target
formats.
