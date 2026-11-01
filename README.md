# PRA

**packRaster Algorithm**: lossless recompression of uncompressed and
RLE-coded raster images (PNM, BMP, Radiance HDR and more), in FreePascal,
with a C core where it pays and some x86-64 assembly; no libraries.

The spiritual successor of [packPNM](https://github.com/YadeWira/packRAW):
written from scratch, with a codec and container of its own; it shares no
code with packPNM and does not read its files.

The original comes back **byte for byte**, and nothing is written unless it
verified.

Status: in development. The codec: [doc/CODEC.md](doc/CODEC.md); limits: [doc/POLICY.md](doc/POLICY.md). Built bottom-up, each layer with its tests:

| Layer | Unit | Status |
|---|---|---|
| hash (BLAKE3-128) | `pas/prablake3.pas` | done, from PJA |
| binary arithmetic coder | `pas/praarith.pas` | done, from PJA |
| raster layout, limits | `pas/praraster.pas`, `pas/pralimits.pas` | done |
| Netpbm parser (P4-P7, PF/Pf) | `pas/prapnm.pas` | done |
| more parsers | | BMP, HDR, then [the list](doc/FORMATS.md) |
| model (counters, mixers, APM) | `pas/pramodel.pas` | first version |
| codec stream (version 1) | `pas/pracodec.pas` | first version: 8.8% smaller than packPNM on the files both take |
| container | | |
| command line | | |

```sh
./run_tests.sh      # needs Free Pascal 3.2.2 and python3
```
 See [doc/FORMATS.md](doc/FORMATS.md) for the target
formats.

## License

MIT (see [LICENSE](LICENSE)). PRA is a new implementation: it takes ideas
from packPNM (LGPLv3) but none of its code.
