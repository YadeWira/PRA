# Target formats

PRA handles raster images whose pixels are stored raw or with a simple RLE,
so they can be decoded and rebuilt bit-exactly. Formats that already carry
strong entropy coding (PNG, GIF, JPEG, WebP, AVIF, QOI) are out of scope.

Sample counts refer to the local corpus
(`/mnt/OSR_D3/fileFormatSamples/fileFormatSamples/image/<folder>`; copy, never
work in place).

## Base (inherited from packPNM): done

| Format | Pixels | Corpus folder (files) | Status |
|---|---|---|---|
| PBM / PGM / PPM | raw | pbm 14, pgm 14, ppm 14 | binary done; plain (P1-P3) not yet |
| PAM, PFM | raw | pam 6, pfm 4 | done |
| BMP | raw, bitfields; RLE4/RLE8 | bmp 42 | raw and bitfields done (1 to 32 bits, OS/2 too); RLE not yet |
| Radiance HDR | RGBE + RLE | radiance 10 | done (Radiance's and stb's run-length coders, flat lines) |

## Batch 1: header + raw/RLE pixels

| Format | Pixels | Corpus folder (files) | Status |
|---|---|---|---|
| farbfeld | 16-bit RGBA raw | farbfeld 3 | **done** |
| TGA | raw / RLE | tga 36, bloodLaceCompressedTGA 8 | **done** (raw and RLE; not the BloodLace variant) |
| PCX | RLE | pcx 34 | **done** |
| DCX | several PCX | dcx 11 | **done** |
| SGI / RGB | raw / RLE, planar | sgi 16 | **done** |
| Sun Raster | raw / RLE | sunRaster 12 | **done** |
| ICO / CUR | DIB (reuses BMP) | ico 15, cur 15, icoOS2 12 | **done**: DIB entries (colours and mask), PNG entries as bytes; not Windows 1.0's nor OS/2's own format |
| WBMP | 1-bit raw | wirelessBMP 10 | **done** |
| XWD | raw | xwd 11 | **done** (either byte order, rows as long as the header says) |
| MTV, VIFF, VIPS | raw | mtv 11, viff 13, vips 1 | **done** (VIFF: one image, its bands as planes) |
| DDS uncompressed | raw (BCn is separate) | dds 16, ddsMIPChain 15 | **done**: the main surface (a volume's slices too); mipmaps and a cube map's other faces as images of their own. DXT/BC: not raw pixels. ddsMIPChain holds headerless DXT chains, not DDS files |

## Batch 2: film and science, high bit depth

| Format | Notes | Corpus folder (files) |
|---|---|---|
| DPX | 10-bit packed in 32-bit words | dpx 7 |
| Cineon | same, predecessor of DPX | cin 13 |
| FITS | big-endian int/float | fits 11 |
| VICAR | NASA/JPL | vicar 10 |
| DICOM uncompressed | 12/16-bit | dicom 11 |
| OpenEXR | uncompressed/RLE first, ZIP/PIZ later | exr 12 |

## Batch 3: complex containers

| Format | Pixels | Corpus folder (files) |
|---|---|---|
| TIFF / BigTIFF | raw / PackBits | tiff 126, bigTIFF 8 |
| PSD | raw / PackBits | psd 15 |
| IFF ILBM | ByteRun1, bitplanes | iffILBM 128 |
| PICT, XCF, MIFF, Palm, Intergraph, VTF | various | pict 67, xcf 10, miff 18, palmBitmap 11, intergraphRasterImage 12, vtf 10 |

## Out of scope

XBM/XPM (C source text), QOI (already compressed, no samples), niche retro
formats.
