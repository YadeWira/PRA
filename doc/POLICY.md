# Limits and why

Every limit lives in `pas/pralimits.pas`. The parsers apply them when
reading a file, and the decoder applies the same ones before decoding:
a file the writer accepts is a file the reader accepts.

| limit | value | why |
|---|---|---|
| `MAX_DIMENSION` | 2^24 pixels a side | Far above any real image, and it keeps `width * channels * bits` below 2^37, so a row's size never overflows. |
| `MAX_CHANNELS` | 256 | PAM's DEPTH is free; real files use 1 to 4. |
| `MIN_PAYLOAD` | 13 bytes | The smallest codec stream: no `.pra` payload can be smaller. |
| `MAX_EXPANSION_RATIO` | 65,536 | How many times its payload a declared original may be, checked before decoding. The coder's probabilities stop at 1/4096, so a decision costs at least 0.00035 bits: a blank 8-bit image compresses about 6,000:1 at most, a blank PBM about 23,000:1. |
| `--max-output` | 256 MiB by default | The user's own cap on what `x` decodes. |
| HDR image | 2^29 pixels | The RGBE is decoded whole into memory (2 GiB at most). And before it is allocated, the scanlines have to be long enough to hold it: a line takes at least 4 + 8 x ceil(W / 127) bytes (4 x W below 8 pixels), in the parser and in the decoder alike (`HdrFits`). |
| `MAX_ROW_PAD` | 64 KiB | When the header says how long a row is (XWD's bytes_per_line), the bytes past its pixels: a few in real files (rows padded to 32 bits). More is malformed, and a 1 GiB row in a small file allocates nothing. |
| parts of a file | 65,536 | How many images `praparts` cuts a file into (an ICO's entries are counted by a 16-bit number). The decoder needs no cap of its own: a part takes at least two bytes of the stream, and each part's length is checked against what is left of `--max-output` before it is decoded. |
| `MAX_TEXT_HEADER` | 1 MiB | A header (Netpbm, HDR text, or a BMP's headers and palette up to its pixels) is a few dozen to a few thousand bytes; comments or a colour profile can make it bigger, but not this big. A header that does not end inside it is malformed. |

## What a parser promises

A parser splits a file into header, pixels and tail
(`pas/praraster.pas`), and rebuilding the file is joining the three
again. So a parser can be wrong about a file without losing a byte: the
worst it can do is make compression worse. That is why the parsers are
liberal: samples above `maxval` are fine, and anything after the pixels is
the tail.

They are strict about one thing: the pixels have to be in the file. A
header promising more than there is gives `psTruncated`, and the size is
checked by division, never by multiplying first.

## Not handled yet

- Plain (ASCII) PBM, PGM and PPM (P1, P2, P3): exactness would need their
  formatting (line breaks, spacing) modelled too.
- Several images in one Netpbm file: the second one is the tail for now.
- BMP with RLE4, RLE8, JPEG or PNG pixels; a DIB without its file header.
- HDR with any orientation but `-Y H +X W`, or scanlines written by a coder
  other than Radiance's or stb_image_write's.
