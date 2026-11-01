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
| 3 | `praraster`, `prapnm` | parsers: header, pixels, tail |
| 4 | `pramodel` | counters, hashed tables, mixer, APM |
| 5 | `pracodec` | the stream: layout, header, tail, pixels |

## Stream, version 1

```
version     1 B     1
header      varint length, then the bytes as they are
layout      format 1 B, width, height, channels (varints), bits 1 B,
            flags 1 B (bit 0 big-endian, bit 1 float, bit 2 bottom-up),
            maxval (varint)
tail        varint length, then the bytes as they are
pixels      arithmetic-coded, to the end of the stream
```

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

### 01/11/2026: against packPNM 1.6d

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
