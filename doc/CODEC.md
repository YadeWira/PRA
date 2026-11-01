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
| 4 | `prabytes` | the bytes kept (header, tail): a small byte model |
| 5 | `pracodec` | the stream: layout, header, tail, pixels |

## Stream, version 2

```
version     1 B     1
header      a section: the bytes before the pixels
layout      format 1 B, width, height, channels (varints), bits 1 B,
            flags 1 B (bit 0 big-endian, bit 1 float, bit 2 bottom-up,
            bit 3 run-length coded: TGA, Sun Raster, SGI), maxval (varint)
  HDR only: the scanlines' length (varint), then each line's run-length
            coder as runs: mode 1 B (0 flat, 1 Radiance, 2 stb), count (varint)
  run-length TGA, Sun Raster, PCX, SGI: the coded length (varint), then the
            coder's choices (varint length, then the bytes; prarle)
tail        a section: the bytes after the pixels
  one channel of 2 to 8 bits only: the pixel mode, 1 B (0 samples, 1 indices)
bands       how many (varint, 1 to 256 and at most the rows), then the length
            of each but the last (varints)
pixels      each band arithmetic-coded on its own, one after the other, to
            the end of the stream

section     length (varint); when not 0, then 1 B: 0 the bytes as they are,
            1 coded (prabytes): the coded length (varint), then those bytes
```

Version 1 kept both sections as they are (length, then the bytes, no
method byte); the decoder still reads it.

**The bytes kept.** A section is coded with its own small model
(`prabytes`), or kept as it is when that is not smaller. Headers are
structs, names and palettes; the contexts are the last 1, 2, 3 and 5
bytes, the byte one 4-byte field above with the position in the field,
the byte one colour (3 bytes) above, and that field with the last byte;
one mixer selected by the bits so far and the position in the field, then
an APM. A nibble's counters sit together (16 to a slot), so a byte touches
two cache lines a context, not eight. The decoder checks a section's
length against the caps before decoding it.

**Bands.** The rows (of the pixels, or of an HDR file's RGBE) are cut into
bands of about the same number of rows, each coded with fresh models and its
own arithmetic coder, never looking at the band above: so they are coded and
decoded at once, one a thread. The encoder makes each at least 2 MiB of
pixels, at most 256; the decoder reads how many from the stream, so the
stream is the same whatever the threads. Each band is decoded from its own
copy of its bytes: what the arithmetic decoder reads past a band's end is
zeros, exactly as when the encoder's verifier decoded it.

Format numbers: 1 PBM, 2 PGM, 3 PPM, 4 PAM, 5 PFM, 6 BMP, 7 HDR, 8 farbfeld,
9 TGA, 10 Sun Raster, 11 WBMP, 12 PCX, 13 SGI, 14 XWD, 15 MTV, 16 VIFF,
17 VIPS, 18 DDS. New formats take the next number; a number never changes
meaning.

What the stream does not say, the format does: an SGI file without the
run-length flag, and a VIFF file of more than one band, keep their channels
as planes one after the other (interleaved for the model, `prarle`); an
XWD file's rows are as long as its header's bytes_per_line (`XwdStride`),
at most `MAX_ROW_PAD` bytes past their pixels.

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

**Run-length files, whoever wrote them** (`prarle`). A run-length coded
file is its pixels plus its writer's choices: where each packet starts,
whether it is a run or a literal, how long. Given both, the bytes follow.
So the pixels go to the pixel coder like any others, and the choices are
coded on their own, small, in contexts of what a usual coder would have
done at that point (how many equal values follow, crossing rows and not;
the literal it would write; the row's end). A writer that follows the usual
rule costs a fraction of a bit a packet, one that does not costs more, and
both come back byte for byte: nothing has to be recognised. Before this,
the guess-the-coder way (as for HDR) reproduced 8 of the corpus's 10
run-length TGAs; this way, all 10.
- TGA 9-11: header byte (run bit, count) and one or count pixels; packets
  may cross rows.
- PCX: `$C0|n v` runs and literal bytes, in lines of planes; the planes are
  turned into the pixels the model wants (8-bit planes interleaved as
  channels, 1-bit planes merged into 4-bit indices).
- Sun Raster type 2: `$80 n v` runs, `$80 0` a literal `$80`.
- SGI: per-row packets with a zero at the end, and the tables of where each
  row is: rebuilt from the rows when they lie one after the other right
  after the tables (every file of the corpus), their order coded as steps.
  SGI's planes (verbatim too) are interleaved as channels, and so are a
  VIFF file's bands.

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

Tried and dropped: coding the low bits of a residual (from the 2nd, 3rd or
4th below the top) with 3 contexts and one mixer instead of the whole
model: 0.17% to 0.35% larger on the tuning set, and no measurable gain.

Where it stands (the `pra` command, a machine with other work on it):

| file | size | `pra a` | `pra x` |
|---|---|---|---|
| sample_1920x1280.ppm (a noisy photo) | 7.37 MB | 10.9 s | 10.2 s |
| abydos.ppm | 1.44 MB | 1.2 s | 1.1 s |

About 0.7 to 1.2 MB/s each way, from 0.3 MB/s at the start, on one band;
then bands (below).

### 01/11/2026: bands

What independent bands cost on the tuning set (8 threads), and what they
give (`bench_codec`, compress and verify, 8 threads):

| band size | tuning set | sample_1920x1280.ppm | sample_1920x1280.hdr |
|---|---|---|---|
| one band | 6,965,359 | 9,928 ms | 15,145 ms |
| 4 MiB | 6,965,359 | | |
| **2 MiB** | 6,967,960 (+0.04%) | 4,393 ms | 6,155 ms |
| 1 MiB | 6,977,388 (+0.17%) | 2,395 ms | 4,917 ms |
| 512 KiB | 6,992,865 (+0.40%) | | |

2 MiB kept. The `pra` command, its default threads (the processors, up to
8), each file decompressed and compared:

| file | size | `pra a` | `pra x` |
|---|---|---|---|
| sample_1920x1280.ppm | 7.0 MB | 4.4 s | 3.8 s |
| sample_1920x1280.pfm | 28.1 MB | 8.7 s | 7.6 s |
| forest_path.hdr | 10.2 MB | 5.9 s | 5.0 s |
| abydos.ppm (one band) | 1.4 MB | 1.3 s | 1.1 s |

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

### 01/11/2026: the first batch of formats

farbfeld, TGA (raw and run-length), Sun Raster (raw and run-length), WBMP,
PCX and SGI (raw and run-length): 110 files of the local corpus, 168.3 MB,
22.13% after compression; every one back byte for byte. Left out: 3 PCX
files cut short, 1 file named .pcx that is not one, 1 TGA whose pixels do
not fit its declared size. Some: a 33 MB TGA 11.8%, abydos.ff 2.9%,
BUGLE.PCX 7.6%, a 17 MB 24-bit PCX 32.6%; sample_1920x1280.sgi
(run-length) 2,743,857 against 2,731,248 for the same pixels as a PPM: its
coder's choices and row order cost 0.4%.

### 01/11/2026: the header and the tail coded (stream version 2)

The headers and tails of the corpus's 252 files PRA takes: 205,400 bytes,
37,486 coded, each on its own (xz -9e on each, or as it is when smaller:
47,665). Tuned on that set: the mixer's rate is what mattered (6: 40,393;
48: 37,273); the counters' limit and the table's size little. Per file:
input.viff 4,079 -> 3,030 (xz: 3,124 for the whole file), subimage.xv
1,165 -> 181, wolf.xv 3,008 -> 1,612, fig41.xwd 8,835 -> 6,609, title.dds
66,113 -> 28,158 (its mipmaps are its tail). About 0.6 MB/s, slower a byte
than the pixels; a header is small.

### 01/11/2026: XWD, MTV, VIFF, VIPS, uncompressed DDS

42 files of the local corpus, 31.7 MB, 25.35% after compression; every one
back byte for byte. Left out: the 8 DDS files whose surfaces are DXT/BC
compressed, and ddsMIPChain's 15 files (headerless DXT, not DDS). Some:
fig41.xwd (8-bit, rows padded) 1.2%, abydos.viff (four planes) 4.8%, the
same image as MTV 5.9%, test.v 19.1%. A small file pays for its header,
kept as it is: input.viff (70 x 46, a 1024-byte header and a 768-byte
map) is 4,079 bytes against xz's 3,124.

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

Speed: see "speed, first pass" above.

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
