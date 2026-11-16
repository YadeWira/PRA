# What does not change

**Nothing is fixed yet.** PRA is at 0.x, and its formats may still change
from one release to the next: a `.pra` written by a 0.x release may not
open in a later one. The family's rule (the pack-algorithm group's rules):
a project fixes its formats in a 0.9.x release, once they are mature, and
writes here exactly what is fixed; from that release on, everything it
writes is read by every later release. 1.0.0 comes when PRA has its own
7-Zip method ID.

Until then, two promises already hold:

- **A format change never reads old bytes as something else.** Every
  change that makes other bytes bumps a version number (the container's or
  the codec stream's), and a release refuses a version it does not know:
  `FutureVersion` for a newer one, `OldVersion` (container) or a damaged
  stream for one it no longer reads. So a `.pra` either extracts byte for
  byte, checked against the size and the BLAKE3-128 it stores, or is
  refused with a reason: never a wrong file.
- **The release notes say** whether a release changed a format, and which
  older `.pra` files it still reads.

What may change in any release, frozen or not: speed, the encoder's
choices (bands, which parts of a file it codes as images, its tables), and
the files PRA takes (more, never fewer once frozen).

## The `.pra` file

`doc/FORMAT.md`. Magic `PRA\x01`, container version 1 (written since
0.1.0); the stored flag; the descriptor with the original's size,
BLAKE3-128 and extension. Not fixed yet.

## The codec stream

`doc/CODEC.md`. Not fixed yet.

| version | written by | for |
|---|---|---|
| 4 | the command since 0.1.0 | one image: its header and tail, its layout and coding, its bands, the pixels through the model |
| 3 | the command since 0.1.0 | a file of several parts: images (each a version 4 stream, alone or against references), copies of earlier bytes, and bytes |
| 5 | the command, after 0.2.0 | version 3 with deflate streams among the parts (a TIFF's Deflate strips): each stream's recipe in PPA's recipe format 2, which PPA froze in 0.3.0; written only when a file has such a part |

Versions 1 and 2 were never released: a release refuses them. Versions 6
and up are left for later, and a release refuses one it does not know as
`FutureVersion` (0.1.0 and 0.2.0 refuse version 5 so).

## The library, 7-Zip and zpaq-std

Not there yet. When they come: 7-Zip methods under the family's
experimental IDs `03 7F 3x` until PRA has its own, and zpaq-std codecs
whose name, index, stream and ZPAQL decoder are fixed when they ship.
