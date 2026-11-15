# The `pra` command

```
pra a [options] FILE...     compress:  image.ppm -> image.pra
pra x [options] FILE...     extract:   image.pra -> image.ppm (the original's extension)
pra list FILE...            what each .pra holds: original size, stored size, hash
pra t FILE...               test each .pra: extract and verify in memory, write nothing
pra info FILE...            the structure of each file, and what PRA does with it
pra report [FILE]           a bug report (no pixels, no header contents) and a link to open an issue
pra bench FILE...           how fast this machine runs a, a --no-verify and x on them
pra selftest                the samples inside the binary, on every SIMD path
pra --version, pra -V       the build, the compiler, the system and the SIMD path
```

The command and these switches are PJA's (the family's CLI); what differs
is said where it does.

| switch | what it does |
|---|---|
| `-o PATH` | output name with one input; a directory if it exists or ends in `/` |
| `--output-dir=DIR` | output directory, and nothing else |
| `-f`, `--force` | replace an existing output, only with something that verified |
| `-th N`, `--threads=N` | threads; by default the processors, up to 8. They go to files first, several at once, the largest first, and a file also takes for its bands (an image is cut into bands of about 1 MiB) as many of the free ones as its share of the bytes not yet started is of N, so that the last files take what the others left. The `.pra` is the same whatever the threads. Each file's lines still come out in the order of the inputs |
| `--max-output=SIZE` | `x`: refuse a declared original above SIZE (`256M` by default, `K`/`M`/`G`, `0` = no limit) |
| `--keep-corrupt` | `x`: an output that does not verify stays as `NAME.corrupt` (`pra.corrupt` beside it if that name would be too long) |
| `--no-verify` | `a`: do not decode the stream to check it before writing. Faster (the check runs beside the coding, on a thread of its own: it costs threads more than time); a codec bug would then only show when extracting, where the hash catches it. A side coding's rebuild (RLE, PackBits, ...) is still checked, and the `.pra` is the same byte for byte |
| `--no-sync` | `a`, `x`, `report`, `bench`: do not wait for each output to reach the disk before it takes its name. A few percent faster on a real disk, but after a power cut an output may be empty or missing ([below](#interrupted-runs)) |
| `--clean-temps` | `a`, `x`: delete the temporaries an interrupted run left in the directories this run writes to: only PRA's (`.pra-tmp-PID-N`), only regular files, only older than an hour, and never one whose process is still running ([below](#interrupted-runs)) |
| `-n`, `--dry-run` | do everything but write: an output that exists, or that two inputs share, or (`x`) a `.pra` whose size or hash does not match, fails as it would for real |
| `-q`, `--quiet` | only errors (`--stats` lines still come out, each under its file's name) |
| `--stats` | `a`, `x`, `t`: after each file, where its time went (below), its threads and its bands; then a line for the run: files, bytes in and out, time, MB/s of the originals |
| `--json` | `a`, `x`, `t`, `info`, `list`: one JSON object a line for each file, in the order of the inputs, then `{"summary": ...}`; errors still go to stderr as well |
| `--cpu=PATH` | the model's SIMD path: `plain` or `sse41`, before or after the command (`--cpu sse41`, with a space, is refused naming `--cpu=sse41`). A path this processor or this build lacks is refused (exit 2) naming those it has. Every path writes and reads the same bytes: only the speed changes (`selftest` proves it) |
| `-o REPORT` | `report`: the file the report goes to (never over an existing one) |
| `--with-file` | `report`: also copy the file beside the report as `pra-report-NAME`, to attach if you choose to (without FILE it is refused: exit 2) |
| `-r N` | `bench`: runs of each measure, the best one counts (3 by default) |
| `--` | everything after it is a file, even if it starts with a dash |

All warnings and errors go to stderr.

| exit status | when |
|---|---|
| 0 | every file went through (`t`: every `.pra` verified; `selftest`: every check passed) |
| 1 | a file failed: it is not what the command takes, it is damaged, it could not be read or written (each with its line on stderr); the command's own output could not be written (a full disk); `selftest`: a check failed |
| 2 | usage error: an unknown command or option, a value out of range, an option for another command, `--cpu` with a path not here |
| 3 | a bug in PRA: an exception that is not about the file or the system (a range check, an access violation; not a read or a write the system refused, nor memory it did not give). The run ends with `This is a bug in PRA. Please run: pra report FILE and open an issue at https://github.com/YadeWira/PRA/issues` |
| 130, 143, 129, 141 | ended by SIGINT (Ctrl-C), SIGTERM, SIGHUP or SIGPIPE, after deleting the temporaries it was writing ([below](#interrupted-runs)); `STATUS_CONTROL_C_EXIT` on Windows |

## Checking and reporting

These are for helping: telling what happened, on which machine, in a form
that can be pasted into an issue, and checking a build before trusting it.

### `pra t FILE...`

What `x` does, without writing: the format, the declared size against
`--max-output`, decoding, then the size and the BLAKE3-128. A line
`NAME: OK` for each one that verifies, `pra: NAME: FAILED: why` on stderr for
each that does not (exit 1). Takes `-th`, `-q`, `--max-output`, `--stats`
and `--json`; `-o`, `-f`, `-n` and `--keep-corrupt` are refused (exit 2).

### `pra info FILE...`

Any file: what it is and what PRA does with it (`pas/prainfo.pas`; the
providers are `pas/prainforaster.pas`):

- **An image PRA reads**: its format and size; the layout the parser found
  (width, height, channels, bits, the maximum or float, the byte order,
  where the pixels are and how many bytes, how they are coded: raw,
  PackBits, an RLE, Radiance's scanlines...); how many bytes the header
  and the tail take. A file of several images (TIFF, PSD, ICO, DDS with
  mipmaps, MIFF, XCF, PICT...) lists its parts: each image with its place,
  size and layout (and whether a PSD's composite goes against its layers),
  and the bytes between them. Past 64 parts they are counted, not listed.
- **A .pra**: the container (version, flags, the original's size,
  BLAKE3-128 and extension, stored or not) and the stream, from its headers
  only (no pixel decoded): its version, and for an image its layout and
  bands; for parts, each part (bytes, an image, a copy of earlier bytes, an
  image against references), its size and its stream's. A `.pra` that
  declares an original larger than `--max-output` is not read
  (`not_decoded`), as `x` refuses it.

Then `pra: ...`: for a `.pra`, whether it extracts and verifies; for
anything else, what `a --no-verify` would do (`takes it: stream version 4,
1935 B -> 728 B (37.62%)`, `stream version 3 (parts)`, `none (stored as is)`)
or `refuses it: NotRaster(not this format)`. Exit 1 only for a file that
cannot be read. `--json` gives the same tree.

Nothing of what an image holds is printed: no pixel, no text of its header
(a comment, an XML block, a layer's name), only the sizes.

### `pra report [FILE] [-o REPORT.txt] [--with-file]`

A plain-text bug report, to stdout or to `-o`'s file:

- PRA: version, commit, build date, FPC's version, the target; the system,
  the processor's name and features, the SIMD path in use and those it
  could take, the processors, the threads;
- the command line, each path cut to its name (an option's value too:
  `--output-dir=NAME`);
- for FILE: its size, BLAKE3-128, what PRA does with it and its structure,
  as `info` gives them (with `a`'s verification). Above 64 MB there is no
  dry run (`not estimated: the file is larger than 64 MB`), only the
  structure.

**What is not in it**: no pixel, no header contents (comments, XML, ICC
profiles, layer names: only how many bytes the header and the tail take),
no folder names. A report on a file that hits a bug says so
(`internal_error`) instead of ending.

Then a link that opens a new issue on GitHub with the report in it: a
report too long for a link (about 6000 characters) keeps its start (PRA,
the system, the command) and its end (the layout, the parts, what PRA
does), with a line in their place saying how many lines were cut and to
paste the whole report. `--with-file` copies FILE beside the report as
`pra-report-NAME` (never over an existing file): it goes nowhere unless you
attach it. GitHub takes a `.png`, `.jpg` or `.gif`; zip anything else.
Without FILE, the system part alone, for a problem with no file.

### `pra bench FILE... [-r N] [-th N]`

Prints the system part of the report, then for each file the best of N
runs (3 by default) of `a`, `a --no-verify` and `x`, in milliseconds and
MB/s (2^20 bytes) of the original, with where `a`'s and `x`'s time went,
and the write of the `.pra` alone; then the totals. Everything is in
memory but that write, which goes to a folder of its own in the system's
temporary folder and is deleted: nothing is written beside the inputs. A
`.pra` given is only extracted.

### `pra selftest`

The binary carries nine small samples, one for each way the codec takes an
image (16-bit gray samples, RGB, 1 bit, palette indices, BMP RLE8 as a
side coding, Radiance's scanlines, floats, a file of several images, a PSD
whose composite goes against its layer: `pas/praselftest.inc`, written by
`tools/gen_selftest.py` from `tests/`), and the `.pra` each one has to
give. On every SIMD path the processor has, with one thread and with two,
each is compressed, compared byte for byte with its expected `.pra` (whose
BLAKE3-128 it prints), and extracted back. `--cpu=PATH` checks that path
alone. Exit 0 only if every check passed. CI runs it on every platform.

### `pra --version`

```
pra 0.2.0
commit: ad0dd25
built: 2026/11/15
fpc: 3.2.2
target: x86_64-linux
system: Linux 6.12.116+deb13-amd64 x86_64
cpu: Intel(R) Xeon(R) CPU E5-2697A v4 @ 2.60GHz
cpu_features: sse2 sse4.1
cpu_path: sse41
cpu_paths_supported: plain sse41
processors: 64
default_threads: 8
```

The commit comes from `PRA_COMMIT` at build time: `.github/test.sh` and
`pas/run_tests.sh` set it from git when it is not set; a build without it
says `commit:` and nothing. PRA has no C part: there is no `c_compiler`
line.

### `--cpu=PATH`

The model's mixer runs in plain Pascal and, on x86-64, in SSE4.1 assembly
(`pas/pramodel.pas`). The path is chosen at start from cpuid
(`PRA_NOASM=1` turns the assembly off); `--cpu` chooses it instead, to
compare speeds or to rule a path out when chasing a bug. 32-bit builds have
the plain path only.

### `--stats`

```
gray16.pgm -> gray16.pra  1935 B -> 728 B  37.62%
  stats: read 0.04 ms, encode 11.15 ms, hash 0.01 ms, write 0.05 ms; total 11.25 ms; 2 thread(s), 1 band(s)
```

The stages: `read` the input; `encode` the model, with the verification
beside it (each band is decoded on a thread of its own while it is coded,
so its time is `encode`'s); `decode` (`x`, `t`); `hash` BLAKE3; `write` the
output, verified, flushed to the disk (unless `--no-sync`) and renamed;
`other` what falls between. `threads` are the file's own (what `-th` leaves
each file), `bands` the stream's (all its images').

### `--json`

One object a line, so that `python3 -c 'import json'` or `jq` read it
line by line:

```
{"file":"gray16.pgm","output":"gray16.pra","original_size":1935,"pra_size":728,"ratio_percent":37.62,"stored":false,"ok":true}
{"summary":{"command":"a","files":1,"failed":0,"bugs":0,"bytes_in":1935,"bytes_out":728,"seconds":0.012,"threads":8}}
```

The same thing has the same name in every command: `original_size` is
the original's bytes, `pra_size` the `.pra`'s.

| command | fields of each file (after `"file"`) |
|---|---|
| every one | `ok` (`true`: it went through; for `info`, it was read and described); `error` (what failed, as on stderr) when it did not; `internal_error` when it met a bug |
| `a` | `output`, `original_size`, `pra_size`, `ratio_percent`, `stored` |
| `x` | `output`, `original_size`, `pra_size` |
| `t` | `original_size`, `pra_size` |
| `list` | `original_size`, `pra_size`, `ratio_percent`, `stored`, `extension`, `blake3_128` |
| `info` | the tree the text shows: `format`, `size`, and the format's own (an image: `image` with its layout, `header_bytes`, `tail_bytes`; several: `parts`, `images`, `part_list`; `.pra`: `container`, `stream` with `version` a number); then `pra`: `command` (`a` or `x`), `ok`, `summary` (the line of the text), and for `a`: `takes`, `stream` (in words), `stream_version` (a number; 0 for stored as is), `pra_size`, `ratio_percent`, or `error`; for `x`: `original_size` or `error` |
| `--stats` (`a`, `x`, `t`) | `stats`: each stage's `NAME_ms`, `total_ms`, `threads`, `bands` |

The summary: `command`, `files`, `failed`, `bugs`, `bytes_in`, `bytes_out`,
`seconds`, `threads`.

## Nothing written that did not verify

- `a` writes the `.pra` only after the codec has decompressed its own stream
  and compared it with the input (unless `--no-verify` is asked for: a
  program that checks on its own, such as an archiver, need not pay for it
  twice).
- `x` does, in order: validate the format; refuse a declared size above
  `--max-output` **before** decoding; decode with that size as the cap;
  check the size **and** the hash; and only then write.
- Writing creates the file without following links, always as a temporary
  in the same directory (`.pra-tmp-PID-N`) that takes the output's name
  only once it is complete **and on the disk** (`fsync`; `FlushFileBuffers`
  on Windows), and on Unix the directory is flushed after the name is
  given: after a power cut the output is either whole or not there, never
  empty or partial under its name. (Windows has no call to flush a
  directory: the name is left to the file system's journal.) If only that
  last flush fails, the run fails (rc 1) with `written, but its directory
  could not be flushed to the disk`: the output is in place and whole, and
  a rerun needs `-f`. A run cut short (Ctrl-C, a kill, a full disk) never
  leaves a truncated file under the output's name. Without `-f` the name
  is only taken if it is still free; with `-f` the temporary is renamed on
  top: what was there is only replaced by something that verified. Nothing
  that fails deletes a file this run did not write.

## Interrupted runs

(PJA's, from its 0.9.5 and 0.9.7; PRA has them since 0.2.0.)

- **Ctrl-C, `kill`, a closed terminal, a closed pipe**: SIGINT, SIGTERM,
  SIGHUP and SIGPIPE (`pra x ... | head`; on Windows Ctrl-C, Ctrl-Break
  and closing the console) delete the temporaries the run is still
  writing, and it ends as the signal would have ended it (exit status 130
  for SIGINT, 143 for SIGTERM, 129 for SIGHUP, 141 for SIGPIPE;
  `STATUS_CONTROL_C_EXIT` on Windows). Outputs already written stay:
  each one verified. A signal ignored by whoever started `pra` (`nohup`, a
  background job of a script) stays ignored.
- **`kill -9`, a crash, a power cut**: nothing can run then, so a
  `.pra-tmp-PID-N` may stay. The next run that writes in that directory
  names them on stderr (`found 2 leftover temporaries of an interrupted
  run: ...; --clean-temps deletes them`), once per directory, and deletes
  nothing unless `--clean-temps` is given. Either way only names of PRA's
  own pattern count, only regular files (a link or a directory with that
  name is left alone), only older than an hour, and never one whose process
  (the PID in its name) is still running. With `-n` they are only named.
  The PID is checked in this machine's process table: in a directory
  shared with another machine or container (NFS, a bind mount) the hour of
  age is the only guard, so do not use `--clean-temps` there while another
  machine may be writing.
- **The flush beside the work**: each flush waits on the disk, so `a` and
  `x` hand each file's write, flush and rename to a thread of their own and
  go on with the next file; the file's line comes out once its write is
  done, in the same order, and the run ends only when every write has. At
  most 8 writes wait (their bytes in memory). Not with `--no-sync`
  (nothing to wait for), `-n`, or `--stats` (which times the write in the
  file's own stages); `PRA_SYNC_INLINE=1` writes in the file's own thread.

## Choices, and why

These are PJA's, where they were agreed and measured; PRA keeps them so
that both commands behave the same.

- **An existing output is refused without `-f`.** Otherwise
  `pra a -o a.pra b.ppm` silently replaces `a.pra`.
- **`-o` behaves like the destination of `cp`**: an existing directory or a
  path ending in `/` is a directory, anything else a name. **With more than
  one input, a destination that is not a directory is an error**: without
  that guard, `pra a *.ppm -o one.pra` would write every input over the same
  file and the last one would win.
- **Two inputs with the same output in one run: the second fails**, with or
  without `-f` (`a.ppm` and `a.pnm`, `d1/p.pgm` and `d2/p.pgm` with
  `--output-dir`, the same file twice), naming the input that took it; so
  does an output that is another input of the run.
- **On Unix a backslash is part of the name**, not a separator:
  `a\x.ppm` gives `a\x.pra`.
- **Values with `=` or a space, never glued**: `-th 4` or `--threads=4`. A
  glued `-th4` is refused naming the right spelling.
- **There is no bare `-t`.** `-th` is two letters; with no `-t`, it can never
  be read as `-t -h`.
- **`a` and `x` are filters**: `a` refuses a `.pra`, `x` anything that is not
  one. There is no mode that does both; shell globs separate them.
- **The output keeps the original's extension**, as it was written:
  `scan.PGM` comes back as `scan.PGM` (the `.pra` keeps it, with a check).
  The name is the `.pra`'s own. When there is none to keep (an extension
  the format does not take: more than 15 characters, or anything but
  letters, digits, `_` and `-`), the content decides: `.pgm`, `.bmp`,
  `.tif`, `.psd`, `.dcm` and so on, the format's usual one.
- **`a` refuses what it does not understand**, naming why: a BMP with a
  JPEG inside is `unsupported variant`, a text file `not this format`. PRA
  is not a general compressor.
- **Never larger than the original by more than 52 bytes** (37 and the
  extension): a file the codec does not make smaller is stored as it is,
  and `a` and `list` say so.
- **On Windows, `pra` expands `*` and `?` itself**, because neither `cmd`
  nor PowerShell does it for a program: `pra a scans\*.pgm` takes every
  file that matches, in order of name, folders left out. Only the name part
  is a pattern (`scans\*.pgm`, not `*\x.pgm`). A pattern that matches
  nothing fails as `no file matches`, and the other inputs still go through.
  Elsewhere the shell expands them, as always. Names are read in UTF-16
  and kept in UTF-8.
- **What `pra` prints is UTF-8, and every character shows on a Windows
  console**: to a console it writes UTF-16 (`WriteConsoleW`), without
  changing the console's code page; to a file or a pipe, UTF-8, so
  `--json` and `report` read the same on every system (`pas/praconsole.pas`,
  from PJA and PAIA).
- **A write the system refuses is reported in its own words**, with the
  error number: `could not write it: Not a directory (Io(20))`.

Tested by `pas/tests/cli.sh` (101 cells: round trips, existing outputs,
links, damage, `--keep-corrupt`, `--max-output`, threads, every usage
error; signals and the disk, held at the write's fsync with strace when it
is there; `t`, `info`, `report` and its privacy, `bench`, `selftest`,
`--cpu`, `--stats`, `--json`, `--no-verify`, and the end of a run that
meets a bug), on Linux; `.github/test.sh` runs `selftest` and every sample
on every platform CI builds.
