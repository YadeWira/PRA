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
| 3 | `praparts` | files of several images: where each image is |
| 4 | `prabytes` | the bytes kept (header, tail): a small byte model |
| 5 | `pracodec` | the stream: layout, header, tail, pixels |

## Stream, version 4

```
version     1 B     4
header      a section: the bytes before the pixels
layout      format 1 B, width, height, channels (varints), bits 1 B,
            flags 1 B (bit 0 big-endian, bit 1 float, bit 2 bottom-up,
            bit 3 run-length coded (TGA, Sun Raster, SGI, BMP) or plain
            text (PBM, PGM, PPM)), maxval (varint)
  HDR only: the scanlines' length (varint), then each line's run-length
            coder as runs: mode 1 B (0 flat, 1 Radiance, 2 stb), count (varint)
  run-length TGA, Sun Raster, PCX, SGI, BMP, plain Netpbm: the coded length (varint), then the
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

Versions 1 and 2 (the model before the match models, never released) are
refused: a stream of another model cannot be decoded by this one.

## Stream of parts, version 3

A file of several images (ICO, CUR, DCX, Netpbm images in a row, a DDS
file's mipmaps and cube faces: `praparts`) is cut into parts, one after the
other; the file is the parts joined.

```
version     1 B     3
parts       how many (varint), then each:
  kind      1 B: 0 bytes, 1 image, 2 copy
  bytes:    a section (as above)
  image:    its length in the file (varint), its stream's length (varint),
            then its stream: version 4, as if the image were a file
  copy:     its length (varint), and where the same bytes are earlier in
            the file (varint)
```

A part that is byte for byte an earlier one (64 bytes and more) is a copy:
a PSD whose layer is its composite, an icon's masks alike. A PSD's
composite is cut plane by plane when a plane is a layer's channel (the
planes between such ones stay one interleaved image).

An image whose stream is not smaller than it (a 2 x 2 mipmap) is coded as
bytes instead, and bytes next to bytes are one part. If no image is left,
a file that is one image with the rest as its tail is coded so. The
decoder checks each part's length against the cap before decoding it; a
part's image stream is never itself a stream of parts. The encoder has
checked each image and each section as it coded them; then it reads the
frame back, the images taken from the original.

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

**Match models.** Two: where the last 2 samples (in coding order) were
last seen, and where the last 4 were; the sample that followed them then
is expected again. Each gives, at every decision of the residual (its
length's tree, its bits, its sign, while the coded bits still agree with
it), the bit it expects, and a counter for (how long the match has held,
the expected bit) gives the mixer an input; the longer match's state also
selects the first mixer's weights. Indices take the same, on their value's
tree. On the tuning sets: the photos 6.5% smaller (a 16-bit RGB image 25%),
the synthetic images 5.5% (favicon.ico below xz); about a fifth slower.

**Mixing.** Two mixers: one selected by the decision, the sub-channel and
the match's state, one by the decision and the local activity, averaged in
the logistic domain, then an APM keyed by the decision and the activity
(1/4 input, 3/4 APM).

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
- BMP RLE8 and RLE4: (n, v) runs, (0, 0) end of row, (0, 1) end of
  bitmap, (0, 2, dx, dy) moves, (0, n) literals padded to two bytes. The
  rows are as wide as an uncompressed BMP's, padding included: some
  writers (ImageMagick) code the padding's pixels too. A pixel a move or
  an early end skips is 0. The data ends at the end of bitmap, or after
  the rows, or with the file (the decoder knows its length).

**10 bits packed (DPX, Cineon).** Three samples a 32-bit word, from the
top bits down (the two free bits below; or, DPX's packing 2, on top): the
words are unpacked to 16-bit samples, three a word (a row's last word's
spare samples too: the codec keeps them apart as padding), and the free
bits are coded beside them (nearly free: they are 0). How the words are
packed and their byte order, the decoder reads from the header.

**OpenEXR scanlines.** The offsets of the lines and each line's head (its
y, its size) are rebuilt from the layout and the data window's ymin;
each line's channels, one after the other in the file, are interleaved for
the model. A file whose lines are not one after the other, in order, is
left.

**PackBits** (TIFF 32773, PSD, IFF's ByteRun1): a header byte, n + 1
literal bytes or 257 - n copies; the choices coded as with the others,
against the run and the literal a usual writer makes, in the line or past
it. PSD's composite is its channels' planes: decoded, then interleaved for
the model (CODING_PLANES_PACKBITS).

**IFF bitplanes.** ILBM's rows hold each plane's bits in turn (ACBM: whole
planes one after another); they become pixels (8-bit indices, or 8 bits a
channel for 24 and 32 planes) as wide as the rows' padding to 16 bits, so
the padding's bits come back too. The BMHD in the kept header tells the
decoder how many planes and whether ByteRun1.

**TIFF and PSD are parts.** A TIFF's directories point at strips or tiles
anywhere in the file: `praparts` cuts the file at them, strips that follow
each other become one image, tiles of one image stack into one as wide as
a tile; the rest (header, directories, LZW or JPEG strips) is bytes. A
PSD's layers' channels (and masks) are images each, its composite one
image of all its channels.

**Plain Netpbm (P1, P2, P3).** The numbers are an image (`praplain`); the
writer's formatting is coded beside them: the separator before each
number, a symbol at a time (space, LF, CR, TAB, another byte, the end), and
any zeros a number starts with. Two contexts, averaged: the column where
the next number would end (lines wrapped at so many columns:
ImageMagick), and how many numbers the line holds (netpbm wraps at so
many numbers); both with the separator before, and whether a row ends.

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

### 01/11/2026: XCF

GIMP's files (versions 0 to 3, run-length): each layer's, mask's and
channel's first level is one image, its tiles (64 x 64) decoded into it;
the run-length choices (run or literal, short or long form, the count
against the run and the literal a usual writer makes) coded beside. 10
corpus files, 18.7 MB -> 9.99 MB, every one back byte for byte, every one
below xz (body1_300dpi 3.67 MB against 4.42; example.xcf 1.19 against
1.87; test.xcf 159 KB against 320).

### 01/11/2026: MIFF

17 files of the corpus, 3.85 MB -> 467 KB (12.1%), every one back byte for
byte, every one below xz (dna.mif 108,909 against 170,200; aquarium.miff
69,010 against 95,620). ImageMagick's RLE is a pixel and a count, the runs
across rows; the counts are coded against the run there is (nearly free).
Old headers end in form feed, line feed, ':', line feed; a montage has its
directory of names before the map.

### 01/11/2026: match models (stream version 4)

Tuning set (10 photos, 18 MB) and a synthetic set (18 icons, screen dumps,
PCX, logos):

| | photos | synthetic |
|---|---|---|
| before | 6,967,923 | 371,098 |
| one match, after 8 samples | 6,907,881 | 365,393 |
| one match, after 4 | 6,687,187 | 357,573 |
| one match, after 2 | 6,619,685 | 358,792 |
| two: after 2 and 8 | 6,601,862 | 356,353 |
| two: after 2 and 4 | 6,517,524 | 352,162 |
| two: after 2 and 3 | 6,516,367 | 353,075 |
| (2, 4), the longer's state selecting mixer weights | 6,514,360 | 351,587 |
| and the indices mode too | 6,514,360 | 350,731 |

Short contexts win: a 'match' after 2 samples is the last time the same
two samples came in a row, which in images is a strong guess. favicon.ico
11,718 -> 9,997 (xz 10,004); cool.bmp 143,982 -> 129,746;
lighthouse_rgb48.ppm 1,486,227 -> 1,068,110. Time: set1 27.8 s -> 33.8 s.
1-bit images (their own model) are unchanged: fonts and fax pages next.
The whole local corpus under 20 MB, every format: 497 files, 464 MB,
27.49%, every one back byte for byte.

### 01/11/2026: containers (batch 3): TIFF, PSD, IFF

TIFF and BigTIFF (uncompressed and PackBits strips and tiles), PSD and PSB
(layers' channels and masks, the composite), IFF (ILBM, PBM, ACBM); every
file back byte for byte. Against xz -9e, on the files PRA takes:

| | files | size | PRA | xz |
|---|---|---|---|---|
| TIFF | 64 | 128.1 MB | 58.8 MB | 78.6 MB |
| PSD | 13 | 81.4 MB | 24.4 MB | 23.7 MB |
| IFF | 99 | 9.0 MB | 3.19 MB | 5.08 MB |

PSD: the composite interleaved was 27-35% smaller than its planes one under
the other. Several PSDs keep a layer that is the composite again: as
copies (a parts stream's kind 2) sample_1920x1280.psd went from 7.55 MB to
4.82 MB (xz 5.18), Tour.psd 289 to 199 KB (xz 229). Where PRA still loses
(example.psd 10.8 MB to xz's 8.65, main1, example_small) the layers are
near copies of the composite, not the same bytes: a match model's work.
TIFF: tiles stacked into one image made TOPO.HMR (thousands of tiles) 3.5
times faster. Fuzzing found a BigTIFF directory count that overflowed.
LZW, Deflate, JPEG and CCITT strips stay as bytes.

### 01/11/2026: film and science (batch 2)

DPX, Cineon, FITS, VICAR, DICOM and OpenEXR (uncompressed): 50 files of
the corpus, 166 MB, every one back byte for byte. Without the 51 MB
Cineon, 49 files, 115.2 MB: 26.90%, against xz -9e's 35.9% (41.4 MB).
Some: boy.cin (10 bits packed) 39.7% (xz 62.5%), the 11 MB 10-bit RGBA
checkerboard DPX 6,407 bytes, n1355256227.1.map (VICAR HALF) 6.7%,
CT.4032.1 (DICOM, 16 bits) 36.4% (xz 46.0%), abydos.exr (halves) 4.0%.
Left: 9 OpenEXR files (ZIP, PIZ, tiles, deep). Fuzzing found a VICAR
label that looped forever (a key not found moved the search back one
byte), an EXR channel type that overflowed an integer, and a BMP RLE cut
right after its header (no token: now truncated).

### 01/11/2026: BMP RLE8 and RLE4, plain Netpbm

The corpus has 3 RLE BMPs (crowd.dt, input.bmp, VGALOGO.RLE: RLE4) and 6
plain Netpbm files; with RLE BMPs and plain files written from corpus
images by ImageMagick and netpbm: 20 files, 24.6 MB, 8.27%, all back byte
for byte, every one below xz -9e (example.ppm, 10.8 MB: 1,154,710 against
2,208,908; input.bmp 3,089 against 3,844). What the formatting costs, the
same image plain against binary: abydos.pgm 48,148 binary, 49,776 from
ImageMagick, 49,420 from netpbm (55,595 before the count-of-numbers
context); testimg.ppm 13,568, 13,807, 13,790. ImageMagick's RLE8 codes
each row's padding pixels too: 3 of the 6 RLE files were refused until
the rows were as wide as their padding.

### 01/11/2026: several images a file (stream version 3)

ICO and CUR (a DIB's colours and its AND mask as two images, a PNG as
bytes, OS/2's 12-byte DIB header too), DCX, Netpbm images in a row, DDS
mipmaps and cube faces. Corpus: abydos.ico 9.7% (xz: 18.3%), abydos.dcx
16.6%, title.dds 66,113 -> 26,956 (its mipmaps were its tail),
BMAP_3684.pbm (two images) 4.4%. favicon.ico 11,758 against xz's 10,004:
image by image PRA and xz are even, but its 128 x 128 RGBA icon (flat
areas, the same runs again) is 6,369 against 5,644: the pixel model has no
match model yet. Not taken: Windows 1.0 icons and cursors, OS/2's own
icon format (BA, IC, CI), an ICO of PNG entries only (nothing to model).

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
