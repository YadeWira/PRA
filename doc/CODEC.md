# The PRA codec

Its own stream, written from scratch. Everything is 32-bit integer
arithmetic with no floating point: every platform makes the same bytes, and
a ZPAQL decoder can reproduce it later (zpaq-std plugin). The checked build
(`$R+ $Q+`) is the proof of the 32-bit discipline: a product that needs more
than 32 bits raises there, and the test suite runs it.

## The one guarantee

The file comes back byte for byte. `EncodeFile` decodes its own stream and
compares it with the input before handing it out; if they differ, it gives
up and the caller stores the file as it is.

## Layers

| layer | unit | what it does |
|---|---|---|
| 2 | `praarith` | binary arithmetic coder (from PJA) |
| 3 | `praraster`, `prapnm`, `prabmp`, `prahdr` | parsers: header, pixels, tail |
| 4 | `pramodel` | counters, hashed tables, mixer, APM |
| 5 | `pracodec` | the stream: layout, header, tail, pixels |

## Stream, version 1

```
version     1 B     1
header      varint length, then the bytes as they are
layout      format 1 B, width, height, channels (varints), bits 1 B,
            flags 1 B (bit 0 big-endian, bit 1 float, bit 2 bottom-up),
            maxval (varint)
  HDR only: the scanlines' length (varint), then each line's run-length
            coder as runs: mode 1 B (0 flat, 1 Radiance, 2 stb), count (varint)
tail        varint length, then the bytes as they are
  one channel of 2 to 8 bits only: the pixel mode, 1 B (0 samples, 1 indices)
pixels      arithmetic-coded, to the end of the stream
```

Format numbers: 1 PBM, 2 PGM, 3 PPM, 4 PAM, 5 PFM, 6 BMP, 7 HDR. New formats
take the next number; a number never changes meaning.

The decoder checks the layout against the limits (`pralimits`) and against
the caller's cap on the output size **before** decoding anything.

## Pixels

**Samples.** 8 or 16 bits. A 32-bit float is first made monotonic (sign
bit set: all bits flipped; clear: the sign bit set) and split into a high
and a low 16-bit half, coded as two sub-channels: the high halves first.

**Order and reference.** With three channels or more, green is coded first,
then red and blue with green as their reference channel.

**Prediction.**
- a channel with a reference: MED (LOCO-I's median) on the difference to the
  reference, plus the reference's actual value at this pixel;
- 8-bit channels without one (gray, green): 12 predictors (W, N, NE, NW,
  W+N-NW, W+NE-N, N+NE-NNE, (W+N)/2, MED, 2N-NN, (W+NE)/2, 2W-WW) blended,
  each weighted by 1 / (its error at W, N, NW and NE, plus 1)^2;
- anything else: MED.

**Residual.** Taken modulo 2^bits into [-2^(bits-1), 2^(bits-1)), coded as
its bit length (a binary tree), the bits below the top one, and the sign.

**Contexts** (10, hashed into one table of 2^12..2^22 counters, sized from
the image): local activity and the blend's best cost; the neighbours' errors
(W, N; NW, NE), signed and bucketed; the reference's error at this pixel;
horizontal and vertical gradients; order 0; where W, N, NE and W+N-NW lie
against the prediction; the exact values of W, N and of W, NW, N, NE.

**Mixing.** Two mixers: one selected by the decision and the sub-channel,
one by the decision and the local activity, averaged in the logistic
domain, then an APM keyed by the decision and the activity (1/4 input,
3/4 APM).

**1-bit images.** Their own model: three templates of 10, 16 and 22
neighbouring pixels, a mixer selected by the 5 nearest.

**Indices.** One channel of 2 to 8 bits may be intensities or symbols
(palette indices, a drawing of a few gray levels). The encoder codes it
both ways and keeps the smaller: as samples (above), or as indices, each
value coded whole by a binary tree in 8 contexts of the exact neighbouring
values (W; N; W,N; W,N,NW; W,N,NE; W,WW,NW,N,NE; N,NN,NE; order 0), with
the mixers and the APM selected by which neighbours are equal.

**Rows with padding.** One channel: the padding samples are coded as
pixels (a BMP's 4-byte alignment, a PBM's last bits). Several channels (a
24-bit BMP): the padding bytes after the pixels, through a byte tree in a
context of their position.

**Radiance HDR.** The scanlines are decoded to RGBE (four 8-bit channels,
green first, red and blue against it, the exponent last) and each line's
coder is found (`prahdr`): the decoder codes the lines again the same way.

## Measurements

Every number says what was measured, on what, and when.

### 01/11/2026: tuning the first model

Set of 10 files (`set1`: PPM, PGM, 16-bit PPM, PFM; 7.67 MB of output to
start), one change at a time, total size:

| change | total | |
|---|---|---|
| MED, 6 contexts, one mixer | 7,669,528 | start |
| + the green error added to red and blue's prediction | (in the start) | without it 8,187,123 |
| + exact-value contexts, alone | 7,856,025 | worse without an APM |
| + 12 predictors blended, everywhere | 7,850,526 | better on 8-bit gray, worse on 16-bit and float |
| + bias correction per context (CALIC) | 8,071,292 | worse: dropped |
| + contexts of the predictors against the prediction | 7,627,490 | -0.5% |
| + APM | 7,494,884 | -2.3% |
| both | 7,378,458 | |
| mixer learning rate 8/16 (finer) | 7,289,373 | |
| + a second mixer, selected by activity | 7,267,963 | |
| + exact-value contexts | 7,239,387 | |
| red and blue: MED on the difference to green, not MED + green's error | 6,986,821 | -3.5%; testimg.ppm 17,899 -> 13,822 |
| + blending, only on 8-bit channels without a reference | **6,965,299** | |

Tried and left as they were: counter limit 255 (the counters adapt too
slowly: worse than 127), initial mixer weights (0.09 is best), mixer rates
6 to 10 (flat).

### 01/11/2026: speed, first pass

`bench_codec` (compress and verify, the fast build, one thread pinned to a
core, the best of three) on abydos.ppm, house.l.pgm and abydos.hdr; and
callgrind's instruction count on dragon.ppm, which does not depend on the
machine's load. One change at a time; the output stays the same bytes
unless said.

| change | 3 files | dragon.ppm, instructions |
|---|---|---|
| start | 10,796 ms | |
| `{$inline on}` in pra.inc: FreePascal ignored `inline` without it | 8,683 ms | 3,610 M (with the next two) |
| the mixer's weights walked by pointer | 8,291 ms | |
| the mixer's two loops in SSE4.1 assembly, chosen by cpuid, with Pascal twins (`test_model` compares them; `PRA_NOASM=1` forces Pascal) | 7,891 ms | |
| the blend's weights from a table of 2^30 / c^2 instead of two divisions each (changes the streams: 6,965,346 -> 6,965,349 on the tuning set) | about the same | |
| the stretch and rate tables in the interface (FreePascal does not inline a function using its unit's private symbols: St16 and CounterUpdate stayed calls); both mixers read one array of inputs | **5,909 ms** | **2,980 M** |

Then the check beside the encoding: `EncodeFile` decoded its whole stream
after writing it; now a second thread decodes the pixel coder's bytes as
they come out (pjaarith's TLiveStream), and the part before the pixels is
read back from the final stream as the decoder reads it. The same streams,
the same guarantee (the decoder never sees the original), half the time on
two cores: the three files, pinned to two cores, **3,244 ms**. A bare
thread (BeginThread): TThread.WaitFor from the main thread waits in steps
of 100 ms in FreePascal 3.2, which made every small file 100 ms slower.

A smaller counter table (2^16 instead of 2^22) was only 3.5% faster: the
time goes to computing, not to waiting for memory. Choosing between samples
and indices on the first 65,536 samples' rows instead of the whole image
(the same choice on every file of the corpus) halves the time of one-channel
images: SWAN.BGA 4.5 s -> 2.7 s.

### 01/11/2026: BMP and HDR, and the indices mode

On the BMP and HDR files of the local corpus. Palette images were the weak
point: predicted as intensities, their indices compress worse than
packPNM's order-2 model of the values. Coding them as indices, and keeping
whichever of the two ways is smaller:

| file | samples | indices (kept) | packPNM |
|---|---|---|---|
| SWAN.BGA (8-bit palette) | 273,949 | **120,672** | 189,350 |
| YARN.BGA | 240,667 | **106,715** | 165,459 |
| test.bmp | 123,394 | **80,802** | 90,985 |
| WATER5.BMP | 18,351 | **9,923** | 10,627 |
| dragon.pgm (few gray levels) | 27,150 | **11,444** | 23,963 |
| logo (PGM) | 5,224 | **2,158** | 4,142 |

PGM gained the mode byte too: a PGM's stream is one byte longer when the
samples win (house.l.pgm: 32,126 -> 32,127).

### 01/11/2026: against packPNM 1.6d, the whole corpus

PNM, BMP and HDR files of the local corpus: 92 files, 136.3 MB. Every
output decompressed and compared with the original; a file a tool does not
take, or that does not come back byte for byte, counts at its own size.
packPNM was run with `-p` (or it refuses more), and its `-ver` is not
enough: on BMAP_3684.pbm (two images) it warns and drops the second one.

| | size | packPNM | PRA |
|---|---|---|---|
| all 92 files | 136,297,900 | 86.87% | **46.13%** |
| the 61 files both give back | 29,272,124 | 38.85% | **34.47%** |

packPNM gives back none of the 9 HDR files PRA takes (none of its rebuilt
scanlines match), and takes no PAM, PFM, OS/2 2.x BMP or 32-bit BMP with
bitfields. PRA loses only on files of a few hundred bytes (its stream's
own header) and on flag_b24.bmp (588 against 546). Neither takes the plain
P1-P3 files, RLE BMPs or fig8.pic; PRA does not take sunset_final.hdr (its
scanlines were written by a third coder).

Speed (the fast build, one thread): about 0.2 to 0.4 MB/s each way. Not
worked on yet.

### 01/11/2026: against packPNM 1.6d (Netpbm only)

The local corpus of Netpbm files (51 files, 81.9 MB). A file a tool does
not take counts at its own size; packPNM was run with `-ver`.

| | size | packPNM | PRA |
|---|---|---|---|
| all 51 files | 81,904,891 | 89.78% | **46.72%** |
| the 31 files both take | 15,453,609 | 45.85% | **41.81%** |

packPNM takes no PAM, no PFM, and not BMAP_3684.pbm (two images). PRA
loses on two images of few gray levels (dragon.pgm, logo: the blend is
worse there than MED alone) and on 15-byte files (the stream's own header).
Neither tool takes the plain P1, P2 and P3 files.
