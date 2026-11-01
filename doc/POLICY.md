# Limits and why

Every limit lives in `pas/pralimits.pas`. The parsers apply them when
reading a file, and the decoder applies the same ones before decoding:
a file the writer accepts is a file the reader accepts.

| limit | value | why |
|---|---|---|
| `MAX_DIMENSION` | 2^24 pixels a side | Far above any real image, and it keeps `width * channels * bits` below 2^37, so a row's size never overflows. |
| `MAX_CHANNELS` | 256 | PAM's DEPTH is free; real files use 1 to 4. |
| `MAX_TEXT_HEADER` | 1 MiB | A Netpbm header is a few dozen bytes; comments can make it bigger, but not this big. A header that does not end inside it is malformed. |

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
