{ Layer 2b's predictor: zlib's deflate, the way zlib 1.3 makes its choices,
  so that a stream zlib wrote can be told by its parameters alone.

  This is a port of zlib's deflate.c and trees.c (Jean-loup Gailly and Mark
  Adler, the zlib license: see NOTICE), cut down to what decides the bits:
  the hash chains and longest_match, deflate_fast (levels 1-3), deflate_slow
  (4-9), deflate_rle and deflate_huff, the symbol buffer that ends a block,
  and _tr_flush_block's choice between a stored, a fixed and a dynamic
  block, with build_tree, gen_bitlen and the run-length coding of the code
  lengths (scan_tree, send_tree, build_bl_tree). It does not write bits: it
  gives the choices as a TZStream, which ppadeflate.Encode writes.

  The whole input is given at once and finished (Z_FINISH); zlib gives the
  same bits when the input comes in pieces, as libpng feeds it a row at a
  time, because it only decides with at least MIN_LOOKAHEAD bytes ahead or
  at the end. Or with flushes and parameter changes in between (a flow,
  ZlibChoicesFlow: recipe kind 1), the way zlib makes them: deflate drains
  what it was given up to the flush (its lookahead ends there), ends the
  block if it holds symbols, writes the flush's marker (an empty stored
  block for Z_SYNC_FLUSH and Z_FULL_FLUSH, an empty fixed one for
  Z_PARTIAL_FLUSH, none for Z_BLOCK), and the two positions before the
  flush, which had no lookahead to be inserted, are inserted into the hash
  when the next input comes (s->insert); Z_FULL_FLUSH forgets the past (the
  hash cleared, the positions start again). deflateParams ends the block
  with Z_BLOCK first when the strategy or the kind of loop changes. Older
  zlibs differ (TZlibFlow.variant): up to 1.2.5.2 a flush ends a block even
  an empty one, inserts nothing after it, and Z_PARTIAL_FLUSH may write a
  second empty block, by the bits written so far and the last block's
  end-of-block code length (last_eob_len); up to 1.2.3.3 Z_FULL_FLUSH
  clears the hash but the positions go on. Positions are absolute: zlib's
  window slides, but a position the slide would forget is always further
  back than MAX_DIST, where no match may reach anyway. What the slide does
  decide is whether a block can still be stored (its start must be in the
  window): that is followed here, sliding where zlib slides when it is fed
  in pieces.

  Level 0 (deflate_stored) is not here yet. }
unit ppazlib;

{$I ppa.inc}
{ PPA_FAST: the release build, without range and overflow checks, as the
  model's. The predictor only indexes its own arrays with its own values
  (the parameters are validated before it runs), never with what a stream
  says; the checked build is the reference and gives the same choices. }
{$ifdef PPA_FAST}
  {$R-}{$Q-}
{$else}
  {$ifopt R-}{$fatal ppazlib: range checks ($R+) are mandatory}{$endif}
  {$ifopt Q-}{$fatal ppazlib: overflow checks ($Q+) are mandatory}{$endif}
{$endif}

interface

uses SysUtils, ppadeflate, ppathreads;

const
  Z_DEFAULT_STRATEGY = 0;
  Z_FILTERED = 1;
  Z_HUFFMAN_ONLY = 2;
  Z_RLE = 3;
  Z_FIXED = 4;

type
  TZlibParams = record
    level: Integer;      { 1..9 }
    strategy: Integer;   { Z_DEFAULT_STRATEGY..Z_FIXED }
    memLevel: Integer;   { 1..9 }
    wbits: Integer;      { 8..15 }
  end;

const
  { a flow's events: what deflate was asked for once it had the bytes
    before pos }
  ZE_SYNC = 1;       { deflate(Z_SYNC_FLUSH) }
  ZE_FULL = 2;       { deflate(Z_FULL_FLUSH) }
  ZE_PARTIAL = 3;    { deflate(Z_PARTIAL_FLUSH) }
  ZE_BLOCK = 4;      { deflate(Z_BLOCK) }
  ZE_PARAMS = 5;     { the level and strategy change (deflateParams, after its own flush if it made one) }
  ZE_MAX_AT = 4;     { events at one position, at most }
  { the zlib whose flushes a flow follows }
  ZV_NEW = 0;        { 1.2.5.3 to 1.3.x }
  ZV_125 = 1;        { 1.2.3.4 to 1.2.5.2: empty blocks at flushes, no insert after them, Z_PARTIAL_FLUSH's second block }
  ZV_123 = 2;        { up to 1.2.3.3: as ZV_125, and Z_FULL_FLUSH keeps the positions }
  ZV_LAST = ZV_123;
  { a flag of the variant: zlib built with TOO_FAR = 32767 (deflate_slow
    keeps a match of 3 bytes however far), as pngcrush builds it; the
    version is the variant's low bits (ZV_VERSION) }
  ZV_NO_TOO_FAR = 4;
  ZV_VERSION = 3;
  { the loops deflate picks from the level and strategy }
  FN_HUFF = 0; FN_RLE = 1; FN_FAST = 2; FN_SLOW = 3;

type
  TZlibEvent = record
    pos: SizeInt;          { 0..the input's length }
    kind: Byte;            { ZE_SYNC..ZE_PARAMS }
    level, strategy: Byte; { ZE_PARAMS: the new ones }
  end;

  { the flushes and parameter changes zlib made along the stream }
  TZlibFlow = record
    variant: Byte;                    { ZV_NEW..ZV_LAST, or one of them + ZV_NO_TOO_FAR }
    events: array of TZlibEvent;      { by pos, in the order they were made }
  end;

  { the C loop's tables and its tokens, kept from one run to the next by a
    caller that runs it many times (a search): cleared, not allocated and
    given back to the system each time. Not to be shared between threads }
  TZLongs = array of LongWord;
  TZQWords = array of QWord;
  TZWords = array of Word;
  TZlibScratch = record
    head32, t4, t8, t16: TZLongs;
    posC: TZQWords;
    cnt, d16, tokLen, tokVal: TZWords;
  end;
  PZlibScratch = ^TZlibScratch;

{ What zlib with these parameters makes of plain: its blocks and tokens. The
  header, Adler-32 and tail are left for the caller. If ref is given, stops
  at the first block that differs from ref's and returns False; True means
  every block was the same (z then holds them all). }
function ZlibChoices(const plain: TBytes; const prm: TZlibParams; ref: PZStream;
  out z: TZStream; threads: Integer = 1): Boolean;

{ The zlib parameters that give z's blocks and tokens, if there are any:
  levels from the header's FLEVEL (any with a bare deflate stream), the
  window from its CINFO up to 15, every strategy and memLevel. }
function FindZlibParams(const z: TZStream; out prm: TZlibParams): Boolean;
{ The same, also giving the choices found (z's blocks and tokens, made by
  zlib with prm) }
function FindZlibParams(const z: TZStream; out prm: TZlibParams; out choices: TZStream): Boolean;

{ The same as ZlibChoices, with a flow's flushes and parameter changes
  (ZlibFlowValid must hold: the caller checks). goodBlocks: how many of
  ref's first blocks were made the same before they parted (all of them on
  True). One thread: threads is not used yet with events. }
function ZlibChoicesFlow(const plain: TBytes; const prm: TZlibParams; const flow: TZlibFlow; ref: PZStream;
  out z: TZStream; out goodBlocks: SizeInt; threads: Integer = 1; scratch: PZlibScratch = nil): Boolean;

{ Whether a flow can be followed on plainLen bytes from prm: a known
  variant; events in order of pos (at most plainLen), at most 2 a byte
  and 2 more, and ZE_MAX_AT at one position; parameters in range; and a change of loop (FN_*) only at the
  start or just after a flush at its position, as zlib makes them (with
  Z_BLOCK, or Z_PARTIAL_FLUSH before 1.2.3.4) }
function ZlibFlowValid(const flow: TZlibFlow; const prm: TZlibParams; plainLen: SizeInt): Boolean;

{ The loop deflate runs for a level and strategy (FN_*) }
function ZlibFunc(level, strategy: Integer): Integer;

{ The bits block b of z takes when written from bit bitPos of the deflate
  data (a stored block's padding depends on it), its 3 header bits
  included }
function BlockBits(const z: TZStream; const b: TDeflateBlock; bitPos: Int64): Int64;

{ The zlib header zlib writes for these parameters }
function ZlibHeader(const prm: TZlibParams): Word;

{ zlib's trees (_tr_flush_block, build_tree, gen_bitlen, build_bl_tree,
  scan_tree) for a block of these symbol counts (lfreq[0..285], END_BLOCK
  included; dfreq[0..29]): its dynamic header into b (hlit, hdist, hclen,
  clen, clenSeq, litLen, distLen; nothing else of b changed), and whether
  zlib would write it with the fixed codes (they are no bigger) }
procedure ZlibTrees(const lfreq, dfreq: array of Integer; var b: TDeflateBlock; out fixedNoBigger: Boolean);
{ zlib's run-length coding (send_tree) of the code lengths lens[0..count-1]
  (count >= 1), appended to seq at nSeq: symbol or (extra shl 5), as
  TDeflateBlock.clenSeq. seq must have room for count more }
procedure ZlibSendTree(const lens: array of Byte; count: Integer; var seq: array of Word; var nSeq: Integer);
{ zlib's code-length code (build_bl_tree) for these counts of the 19
  code-length symbols: clen by symbol, and hclen (at least 4) }
procedure ZlibBlTree(const freq: array of Integer; out clen: array of Byte; out hclen: Integer);

var
  { the parallel rebuild's thresholds: PAR_MIN_BYTES_DEFAULT and a quarter
    of it, a segment's least; PPA_TEST_PAR_BYTES makes them smaller for the
    tests (the samples are small), with the same tokens }
  PAR_MIN_BYTES: SizeInt = 1024 * 1024;
  PAR_SEG_MIN: SizeInt = 256 * 1024;

  { deflate's loop and longest_match in C (ppazlibc.c); False: in Pascal,
    the reference. PPA_NOC=1 in the environment makes it False }
  UseZlibC: Boolean = True;

implementation

{$L ppazlibc.o}

type
  { ppazlibc.c's zdeflate_t, field for field: the state of its deflate loop }
  TZDeflate = record
    plain: PByte; n: SizeInt;
    wsize, wmask, maxDist, hashMask, hashShift: SizeInt;
    head: PLongWord; pos: PQWord; cnt: PWord; t4, t8: PLongWord;
    insH: SizeInt;
    strstart, matchStart, prevMatch, winBase: SizeInt;
    matchLength, prevLength, matchAvailable: SizeInt;
    goodMatch, maxLazy, niceMatch, maxChain, filtered, fast: SizeInt;
    tokLen, tokVal: PWord; nTok: SizeInt;
    refLen, refVal: PWord; refN, checkNow, stop: SizeInt;
    lfreq, dfreq: PInteger; symNext, symEnd: SizeInt;
    lengthCode, distCode: PByte;
    pending: SizeInt;
    skipBits: SizeInt;
    d16: PWord; t16: PLongWord;
    stopAt: SizeInt;
    syncPos, syncTok: PSizeInt; nSync, maxSync: SizeInt;
    endLit: SizeInt;
    syncLo, syncHi: SizeInt;
    key1: SizeInt;    { d4's key: 4 bytes, or 6 for deflate_slow's filtered strategy }
    lim: SizeInt;     { the lookahead ends here (a flush's position, or n) }
    lo: SizeInt;      { no match starts at or before it (Z_FULL_FLUSH: the hash forgot it) }
    tooFar: SizeInt;  { deflate_slow drops a match of 3 further than this (TOO_FAR) }
  end;

const
  ZD_DONE = 0; ZD_FLUSH = 1; ZD_STOP = 2; ZD_SEGEND = 3;
  { the parallel rebuild (ParallelSlow): only above this many bytes, and
    each segment parsed this far into the next one, where the two must have
    met (a match ending at the same position in both) }
  PAR_MIN_BYTES_DEFAULT = 1024 * 1024;
  PAR_OVERLAP = 32 * 1024;
  PAR_SKIP_BITS = 19;   { as SKIP_BITS_MAX: fewer slots cost more in collisions than they save }

function ppaz_deflate(var s: TZDeflate): SizeInt; cdecl; external name 'ppaz_deflate';
procedure ppaz_preinsert(var s: TZDeflate; from, upTo: SizeInt); cdecl; external name 'ppaz_preinsert';

const
  MIN_MATCH = 3;
  MAX_MATCH = 258;
  MIN_LOOKAHEAD = MAX_MATCH + MIN_MATCH + 1;
  TOO_FAR = 4096;
  { the skipped chains' tables: about two entries a byte of input, from 2^12 to 2^19 each }
  SKIP_BITS_MIN = 12;
  SKIP_BITS_MAX = 19;
  L_CODES = 286;
  D_CODES = 30;
  BL_CODES = 19;
  HEAP_SIZE = 2 * L_CODES + 1;
  LITERALS = 256;
  END_BLOCK = 256;

  { good lazy nice chain, by level }
  CONFIG: array[1..9, 0..3] of Integer = (
    (4, 4, 8, 4), (4, 5, 16, 8), (4, 6, 32, 32),
    (4, 4, 16, 16), (8, 16, 32, 32), (8, 16, 128, 128),
    (8, 32, 128, 256), (32, 128, 258, 1024), (32, 258, 258, 4096));

  EXTRA_LBITS: array[0..28] of Integer = (
    0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0);
  EXTRA_DBITS: array[0..29] of Integer = (
    0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13);
  EXTRA_BLBITS: array[0..18] of Integer = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 3, 7);
  BL_ORDER: array[0..18] of Integer = (16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15);

var
  { the length code (0..28) of each length - MIN_MATCH }
  LengthCode: array[0..255] of Byte;
  { the distance code (0..29) of each distance - 1 }
  DistCode: array[0..32767] of Byte;
  StaticLLen: array[0..L_CODES + 1] of Integer;
  StaticDLen: array[0..D_CODES - 1] of Integer;

type
  { one of zlib's trees: Freq, and Len (zlib keeps Dad in the same place,
    here apart: Len is only read for a node after it is written) }
  TTree = record
    freq: array[0..HEAP_SIZE - 1] of Integer;
    len: array[0..HEAP_SIZE] of Integer;   { + the guard scan_tree writes }
    dad: array[0..HEAP_SIZE - 1] of Integer;
    maxCode: Integer;
  end;

  TTreeState = record
    heap: array[0..HEAP_SIZE] of Integer;
    heapLen, heapMax: Integer;
    depth: array[0..HEAP_SIZE - 1] of Integer;
    blCount: array[0..15] of Integer;
    optLen, staticLen: Int64;
  end;

function ZlibHeader(const prm: TZlibParams): Word;
var h, flags, wb: LongWord;
begin
  wb := prm.wbits; if wb = 8 then wb := 9;
  h := (8 + ((wb - 8) shl 4)) shl 8;
  if (prm.strategy >= Z_HUFFMAN_ONLY) or (prm.level < 2) then flags := 0
  else if prm.level < 6 then flags := 1
  else if prm.level = 6 then flags := 2
  else flags := 3;
  h := h or (flags shl 6);
  Inc(h, 31 - (h mod 31));
  Result := Word(h);
end;

{ ---------------------------------------------------------------- trees.c }

function Smaller(const t: TTree; const ts: TTreeState; n, m: Integer): Boolean; inline;
begin
  Result := (t.freq[n] < t.freq[m]) or ((t.freq[n] = t.freq[m]) and (ts.depth[n] <= ts.depth[m]));
end;

procedure PqDownHeap(var t: TTree; var ts: TTreeState; k: Integer);
var v, j: Integer;
begin
  v := ts.heap[k];
  j := k shl 1;
  while j <= ts.heapLen do begin
    if (j < ts.heapLen) and Smaller(t, ts, ts.heap[j + 1], ts.heap[j]) then Inc(j);
    if Smaller(t, ts, v, ts.heap[j]) then Break;
    ts.heap[k] := ts.heap[j]; k := j;
    j := j shl 1;
  end;
  ts.heap[k] := v;
end;

{ elems: the tree's symbols; stree: lengths of the static tree (nil for the
  bit length tree); extra/extraBase: the extra bits of symbols >= extraBase }
procedure GenBitLen(var t: TTree; var ts: TTreeState; stree: PInteger;
  const extra: array of Integer; extraBase, maxLength: Integer);
var h, n, m, bits, xbits, overflow, f: Integer;
begin
  for bits := 0 to 15 do ts.blCount[bits] := 0;
  overflow := 0;
  t.len[ts.heap[ts.heapMax]] := 0;
  for h := ts.heapMax + 1 to HEAP_SIZE - 1 do begin
    n := ts.heap[h];
    bits := t.len[t.dad[n]] + 1;
    if bits > maxLength then begin bits := maxLength; Inc(overflow); end;
    t.len[n] := bits;
    if n > t.maxCode then Continue;
    Inc(ts.blCount[bits]);
    xbits := 0;
    if n >= extraBase then xbits := extra[n - extraBase];
    f := t.freq[n];
    Inc(ts.optLen, Int64(f) * (bits + xbits));
    if stree <> nil then Inc(ts.staticLen, Int64(f) * (stree[n] + xbits));
  end;
  if overflow = 0 then Exit;
  repeat
    bits := maxLength - 1;
    while ts.blCount[bits] = 0 do Dec(bits);
    Dec(ts.blCount[bits]);
    Inc(ts.blCount[bits + 1], 2);
    Dec(ts.blCount[maxLength]);
    Dec(overflow, 2);
  until overflow <= 0;
  h := HEAP_SIZE;
  for bits := maxLength downto 1 do begin
    n := ts.blCount[bits];
    while n <> 0 do begin
      Dec(h);
      m := ts.heap[h];
      if m > t.maxCode then Continue;
      if t.len[m] <> bits then begin
        Inc(ts.optLen, Int64(bits - t.len[m]) * t.freq[m]);
        t.len[m] := bits;
      end;
      Dec(n);
    end;
  end;
end;

procedure BuildTree(var t: TTree; var ts: TTreeState; elems: Integer; stree: PInteger;
  const extra: array of Integer; extraBase, maxLength: Integer);
var n, m, node, maxCode: Integer;
begin
  ts.heapLen := 0; ts.heapMax := HEAP_SIZE;
  maxCode := -1;
  for n := 0 to elems - 1 do
    if t.freq[n] <> 0 then begin
      Inc(ts.heapLen); ts.heap[ts.heapLen] := n; maxCode := n;
      ts.depth[n] := 0;
    end else
      t.len[n] := 0;
  while ts.heapLen < 2 do begin
    if maxCode < 2 then begin Inc(maxCode); node := maxCode; end else node := 0;
    Inc(ts.heapLen); ts.heap[ts.heapLen] := node;
    t.freq[node] := 1;
    ts.depth[node] := 0;
    Dec(ts.optLen);
    if stree <> nil then Dec(ts.staticLen, stree[node]);
  end;
  t.maxCode := maxCode;
  for n := ts.heapLen div 2 downto 1 do PqDownHeap(t, ts, n);
  node := elems;
  repeat
    n := ts.heap[1];
    ts.heap[1] := ts.heap[ts.heapLen]; Dec(ts.heapLen);
    PqDownHeap(t, ts, 1);
    m := ts.heap[1];
    Dec(ts.heapMax); ts.heap[ts.heapMax] := n;
    Dec(ts.heapMax); ts.heap[ts.heapMax] := m;
    t.freq[node] := t.freq[n] + t.freq[m];
    if ts.depth[n] >= ts.depth[m] then ts.depth[node] := ts.depth[n] + 1
    else ts.depth[node] := ts.depth[m] + 1;
    t.dad[n] := node; t.dad[m] := node;
    ts.heap[1] := node; Inc(node);
    PqDownHeap(t, ts, 1);
  until ts.heapLen < 2;
  Dec(ts.heapMax); ts.heap[ts.heapMax] := ts.heap[1];
  GenBitLen(t, ts, stree, extra, extraBase, maxLength);
end;

{ scan_tree and send_tree in one: counts the bit length symbols into bl, or
  appends them to seq }
procedure ScanTree(var t: TTree; maxCode: Integer; var bl: TTree;
  var seq: array of Word; var nSeq: Integer; send: Boolean);
var n, prevlen, curlen, nextlen, count, maxCount, minCount: Integer;

  procedure Put(sym, extra: Integer);
  begin
    if send then begin seq[nSeq] := Word(sym or (extra shl 5)); Inc(nSeq); end
    else Inc(bl.freq[sym]);
  end;

begin
  prevlen := -1; nextlen := t.len[0]; count := 0; maxCount := 7; minCount := 4;
  if nextlen = 0 then begin maxCount := 138; minCount := 3; end;
  t.len[maxCode + 1] := $FFFF;
  for n := 0 to maxCode do begin
    curlen := nextlen; nextlen := t.len[n + 1];
    Inc(count);
    if (count < maxCount) and (curlen = nextlen) then Continue
    else if count < minCount then begin
      if send then
        while count > 0 do begin Put(curlen, 0); Dec(count); end
      else Inc(bl.freq[curlen], count);
    end else if curlen <> 0 then begin
      if curlen <> prevlen then begin Put(curlen, 0); Dec(count); end;
      Put(16, count - 3);
    end else if count <= 10 then Put(17, count - 3)
    else Put(18, count - 11);
    count := 0; prevlen := curlen;
    if nextlen = 0 then begin maxCount := 138; minCount := 3; end
    else if curlen = nextlen then begin maxCount := 6; minCount := 3; end
    else begin maxCount := 7; minCount := 4; end;
  end;
end;

{ ---------------------------------------------------------------- deflate.c }

function BlockBits(const z: TZStream; const b: TDeflateBlock; bitPos: Int64): Int64;
var i: SizeInt; l, c, v: Integer;

  { a match's length code and extra bits: 258 as 284 is 284 with 5 }
  function LenBits(l: Integer; fixed: Boolean): Integer;
  begin
    if l = LEN_258_AS_284 then c := 284 - LITERALS - 1 else c := LengthCode[l - MIN_MATCH];
    if fixed then Result := StaticLLen[c + LITERALS + 1] else Result := b.litLen[c + LITERALS + 1];
    if l = LEN_258_AS_284 then Inc(Result, 5) else Inc(Result, EXTRA_LBITS[c]);
  end;

begin
  case b.btype of
    btStored: Exit(((bitPos + 3 + 7) and not Int64(7)) - bitPos + 32 + 8 * Int64(b.storedLen));
    btFixed: begin
      Result := 3 + StaticLLen[END_BLOCK];
      for i := b.firstToken to b.firstToken + b.nTokens - 1 do begin
        l := z.tokLen[i]; v := z.tokVal[i];
        if l = 0 then Inc(Result, StaticLLen[v])
        else Inc(Result, LenBits(l, True) + 5 + EXTRA_DBITS[DistCode[v - 1]]);
      end;
    end;
  else begin
    Result := 3 + 5 + 5 + 4 + 3 * b.hclen + b.litLen[END_BLOCK];
    for i := 0 to High(b.clenSeq) do begin
      c := b.clenSeq[i] and $1F;
      Inc(Result, b.clen[c] + EXTRA_BLBITS[c]);
    end;
    for i := b.firstToken to b.firstToken + b.nTokens - 1 do begin
      l := z.tokLen[i]; v := z.tokVal[i];
      if l = 0 then Inc(Result, b.litLen[v])
      else Inc(Result, LenBits(l, False) + b.distLen[DistCode[v - 1]] + EXTRA_DBITS[DistCode[v - 1]]);
    end;
  end;
  end;
end;

function ZlibFunc(level, strategy: Integer): Integer;
begin
  if strategy = Z_HUFFMAN_ONLY then Result := FN_HUFF
  else if strategy = Z_RLE then Result := FN_RLE
  else if level <= 3 then Result := FN_FAST
  else Result := FN_SLOW;
end;

function ZlibFlowValid(const flow: TZlibFlow; const prm: TZlibParams; plainLen: SizeInt): Boolean;
var k, same: SizeInt; lv, st: Integer; e: TZlibEvent;
begin
  Result := False;
  if ((flow.variant and not ZV_NO_TOO_FAR) > ZV_LAST) or (plainLen < 0) then Exit;
  if Length(flow.events) > 2 * Int64(plainLen) + 2 then Exit;
  lv := prm.level; st := prm.strategy;
  same := 0;
  for k := 0 to High(flow.events) do begin
    e := flow.events[k];
    if (e.pos < 0) or (e.pos > plainLen) then Exit;
    if (k > 0) and (e.pos < flow.events[k - 1].pos) then Exit;
    { at one position: a partial, a sync and a full flush (each stronger
      than the one before: a weaker or the same one again does nothing in
      zlib) and a parameter change. zlib may also make deflateParams' own
      Z_BLOCK, the weakest, before them: from 1.2.5.3 on it then adds
      nothing, before it an empty block such a flow cannot hold
      (doc/PREFLATE.md) }
    if (k > 0) and (e.pos = flow.events[k - 1].pos) then Inc(same) else same := 1;
    if same > ZE_MAX_AT then Exit;
    case e.kind of
      ZE_SYNC, ZE_FULL, ZE_PARTIAL, ZE_BLOCK: ;
      ZE_PARAMS: begin
        if (e.level < 1) or (e.level > 9) or (e.strategy > Z_FIXED) then Exit;
        { a change of loop: at the start, or just after a flush there (a
          level or a strategy of the same loop may change anywhere, at the
          top of its loop: deflateParams without a flush; zlib 1.2.5.3 on
          flushes for a strategy too, before it only for the loop) }
        if (ZlibFunc(e.level, e.strategy) <> ZlibFunc(lv, st)) and (e.pos > 0) and
           ((k = 0) or (flow.events[k - 1].kind = ZE_PARAMS) or (flow.events[k - 1].pos <> e.pos)) then Exit;
        lv := e.level; st := e.strategy;
      end;
    else Exit;
    end;
  end;
  Result := True;
end;

{ a scratch's array, at least n long, its first n cleared }
procedure Zeroed32(var a: TZLongs; n: SizeInt);
begin
  if Length(a) < n then begin a := nil; SetLength(a, n); end
  else FillChar(a[0], n * SizeOf(LongWord), 0);
end;

procedure Zeroed64(var a: TZQWords; n: SizeInt);
begin
  if Length(a) < n then begin a := nil; SetLength(a, n); end
  else FillChar(a[0], n * SizeOf(QWord), 0);
end;

procedure Zeroed16(var a: TZWords; n: SizeInt);
begin
  if Length(a) < n then begin a := nil; SetLength(a, n); end
  else FillChar(a[0], n * SizeOf(Word), 0);
end;

function ZlibChoices(const plain: TBytes; const prm: TZlibParams; ref: PZStream;
  out z: TZStream; threads: Integer): Boolean;
var flow: TZlibFlow; good: SizeInt;
begin
  flow := Default(TZlibFlow);
  Result := ZlibChoicesFlow(plain, prm, flow, ref, z, good, threads);
end;

function ZlibChoicesFlow(const plain: TBytes; const prm: TZlibParams; const flow: TZlibFlow; ref: PZStream;
  out z: TZStream; out goodBlocks: SizeInt; threads: Integer; scratch: PZlibScratch): Boolean;
var
  n: SizeInt;                       { input length }
  wsize, wmask, maxDist: SizeInt;
  hashBits, hashSize, hashMask, hashShift: Integer;
  head: array of SizeInt;
  prev: array of SizeInt;
  { DeflateC's state (ppazlibc.c): zlib's head as 32-bit positions; each
    window position's zpos_t (8 bytes: zlib's prev, the last position
    before it with the same 4 (or 6) and 8 bytes, through the tables t4 and
    t8, and its order in its hash chain, by cnt, each chain's insertions) }
  head32: TZLongs;
  posC: TZQWords;
  { the same 16 bytes, for the long chains of levels 8 and 9 only }
  d16: TZWords;
  t16: TZLongs;
  cnt: TZWords;
  t4, t8: TZLongs;
  skipBits: Integer;
  insH: LongWord;
  strstart, matchStart, prevMatch, blockStart, winBase: SizeInt;
  matchLength, prevLength, matchAvailable: Integer;
  goodMatch, maxLazy, niceMatch, maxChain: Integer;
  symEnd, symNext: Integer;
  nTok, nBlocks: SizeInt;
  ltree, dtree, bltree: TTree;
  ts: TTreeState;
  diverged: Boolean;
  hashHead: SizeInt;
  bflush: Boolean;
  maxInsert: SizeInt;
  stop, checkNow: Boolean;
  { the flow: the parameters in force (prm, then each ZE_PARAMS'); where the
    lookahead ends (a flush's position, or n); a loop's stop at its top
    once strstart reaches stopAt (a ZE_PARAMS without a flush; 0: none);
    where the positions start (Z_FULL_FLUSH, zlib 1.2.3.4 on: strstart 0
    again) and the newest position no match may start at (lo: NIL, or what
    Z_FULL_FLUSH forgot); the positions still to insert after a flush
    (s->insert); the bits written so far and the last block's end-of-block
    code length, for the second empty block of an old Z_PARTIAL_FLUSH }
  cur: TZlibParams;
  lim, stopAt, org, lo, insert: SizeInt;
  needFill: Boolean;
  variant: Integer;
  tooFar: SizeInt;
  trackBits: Boolean;
  bitPos: Int64;
  lastEob: Integer;
  { whether any of the flow's loops keeps hash chains, and the run's C
    state (ppazlibc.c's zdeflate_t), kept from one stretch to the next }
  chains, cReady: Boolean;
  st: TZDeflate;
  k: SizeInt;

  function Lookahead: SizeInt; inline;
  begin
    Result := lim - strstart;
  end;

  function Win(i: SizeInt): Byte; inline;
  begin
    if i < n then Result := plain[i] else Result := 0;
  end;

  procedure UpdateHash(c: Byte); inline;
  begin
    insH := ((insH shl hashShift) xor c) and LongWord(hashMask);
  end;

  { INSERT_STRING: returns the previous head }
  function InsertString(str: SizeInt): SizeInt; inline;
  begin
    UpdateHash(Win(str + MIN_MATCH - 1));
    Result := head[insH];
    prev[str and wmask] := Result;
    head[insH] := str;
  end;

  { zlib slides its window when fed in pieces: at the top of the loop, once
    strstart is at wsize + MAX_DIST of the window }
  procedure Slide; inline;
  begin
    while strstart - winBase >= wsize + maxDist do Inc(winBase, wsize);
  end;

  { the bytes past the lookahead are the input's (zlib's window holds
    others there): they only decide a match that already reaches the
    lookahead's end, which nice, capped to the lookahead, takes at once,
    and which is cut to the lookahead }
  function LongestMatch(curMatch: SizeInt): Integer;
  var chainLength, len, bestLen, nice: Integer;
      scan, match, limit: SizeInt;
      scanEnd1, scanEnd: Byte;
  begin
    chainLength := maxChain;
    bestLen := prevLength;
    nice := niceMatch;
    if strstart > maxDist then limit := strstart - maxDist else limit := 0;
    if limit < lo then limit := lo;
    scan := strstart;
    scanEnd1 := Win(scan + bestLen - 1);
    scanEnd := Win(scan + bestLen);
    if prevLength >= goodMatch then chainLength := chainLength shr 2;
    if nice > Lookahead then nice := Lookahead;
    repeat
      match := curMatch;
      if (Win(match + bestLen) = scanEnd) and (Win(match + bestLen - 1) = scanEnd1) and
         (Win(match) = Win(scan)) and (Win(match + 1) = Win(scan + 1)) then begin
        { scan[2] and match[2] are equal by the hash; the comparison goes
          on from 3, at most to strend; past the end of the input zlib
          compares whatever its window holds, which only matters when the
          match already reaches the end, where nice stops the search }
        len := 3;
        while (len < MAX_MATCH) and (scan + len < n) and (plain[match + len] = plain[scan + len]) do Inc(len);
        if (scan + len >= n) and (len < MAX_MATCH) then len := MAX_MATCH;  { reaches the end: capped below }
        if len > bestLen then begin
          matchStart := curMatch;
          bestLen := len;
          if len >= nice then Break;
          scanEnd1 := Win(scan + bestLen - 1);
          scanEnd := Win(scan + bestLen);
        end;
      end;
      curMatch := prev[curMatch and wmask];
      Dec(chainLength);
    until (curMatch <= limit) or (chainLength = 0);
    if bestLen <= Lookahead then Result := bestLen else Result := Lookahead;
  end;

  procedure AddToken(len, dist: Integer);
  begin
    if nTok = Length(z.tokLen) then begin
      SetLength(z.tokLen, 2 * nTok + 4096);
      SetLength(z.tokVal, Length(z.tokLen));
    end;
    z.tokLen[nTok] := len; z.tokVal[nTok] := dist;
    { against ref, at once, unless ref's block is stored (zlib may still
      choose to store this one, and its tokens would not count) }
    if checkNow then
      if (nTok >= Length(ref^.tokLen)) or (ref^.tokLen[nTok] <> len) or (ref^.tokVal[nTok] <> dist) then begin
        diverged := True; stop := True;
      end;
    Inc(nTok);
  end;

  procedure SetCheckNow;
  begin
    checkNow := (ref <> nil) and (nBlocks <= High(ref^.blocks)) and (ref^.blocks[nBlocks].btype <> btStored);
  end;

  function TallyLit(c: Byte): Boolean; inline;
  begin
    AddToken(0, c);
    Inc(ltree.freq[c]);
    Inc(symNext);
    Result := symNext = symEnd;
  end;

  function TallyDist(dist, lenMinus3: Integer): Boolean; inline;
  begin
    AddToken(lenMinus3 + MIN_MATCH, dist);
    Inc(ltree.freq[LengthCode[lenMinus3] + LITERALS + 1]);
    Inc(dtree.freq[DistCode[dist - 1]]);
    Inc(symNext);
    Result := symNext = symEnd;
  end;

  procedure InitBlock;
  var i: Integer;
  begin
    for i := 0 to L_CODES - 1 do ltree.freq[i] := 0;
    for i := 0 to D_CODES - 1 do dtree.freq[i] := 0;
    for i := 0 to BL_CODES - 1 do bltree.freq[i] := 0;
    ltree.freq[END_BLOCK] := 1;
    ts.optLen := 0; ts.staticLen := 0;
    symNext := 0;
  end;

  function SameBlock(const a, b: TDeflateBlock): Boolean;
  var i: Integer;
  begin
    Result := False;
    if (a.final <> b.final) or (a.btype <> b.btype) or (a.nTokens <> b.nTokens) then Exit;
    case a.btype of
      btStored: if (a.storedLen <> b.storedLen) or (a.pad <> b.pad) then Exit;
      btDynamic: begin
        if (a.hlit <> b.hlit) or (a.hdist <> b.hdist) or (a.hclen <> b.hclen) then Exit;
        for i := 0 to 18 do if a.clen[i] <> b.clen[i] then Exit;
        if Length(a.clenSeq) <> Length(b.clenSeq) then Exit;
        for i := 0 to High(a.clenSeq) do if a.clenSeq[i] <> b.clenSeq[i] then Exit;
      end;
    end;
    for i := 0 to a.nTokens - 1 do
      if (z.tokLen[a.firstToken + i] <> ref^.tokLen[b.firstToken + i]) or
         (z.tokVal[a.firstToken + i] <> ref^.tokVal[b.firstToken + i]) then Exit;
    Result := True;
  end;

  { the block b made, against ref's; then kept }
  procedure PutBlock(const b: TDeflateBlock);
  begin
    if ref <> nil then
      if (nBlocks > High(ref^.blocks)) or not SameBlock(b, ref^.blocks[nBlocks]) then begin
        diverged := True; stop := True;
      end else if goodBlocks = nBlocks then Inc(goodBlocks);
    if nBlocks = Length(z.blocks) then SetLength(z.blocks, 2 * nBlocks + 8);
    z.blocks[nBlocks] := b;
    Inc(nBlocks);
  end;

  { an empty stored block (a flush's marker): 3 bits, up to the byte, LEN
    and NLEN }
  procedure StoredBits;
  begin
    Inc(bitPos, 3);
    bitPos := (bitPos + 7) and not Int64(7);
    Inc(bitPos, 32);
  end;

  { _tr_flush_block }
  procedure FlushBlock(last: Boolean);
  var
    b: TDeflateBlock;
    maxBlIndex, i, nSeq: Integer;
    optLenb, staticLenb, storedLen: Int64;
    firstTok: SizeInt;
    seq: array[0..L_CODES + D_CODES] of Word;
  begin
    b := Default(TDeflateBlock);
    b.final := last;
    firstTok := nTok - symNext;
    b.firstToken := firstTok;
    storedLen := strstart - blockStart;

    BuildTree(ltree, ts, L_CODES, @StaticLLen[0], EXTRA_LBITS, LITERALS + 1, 15);
    BuildTree(dtree, ts, D_CODES, @StaticDLen[0], EXTRA_DBITS, 0, 15);
    { build_bl_tree }
    nSeq := 0;
    ScanTree(ltree, ltree.maxCode, bltree, seq, nSeq, False);
    ScanTree(dtree, dtree.maxCode, bltree, seq, nSeq, False);
    BuildTree(bltree, ts, BL_CODES, nil, EXTRA_BLBITS, 0, 7);
    maxBlIndex := BL_CODES - 1;
    while maxBlIndex >= 3 do begin
      if bltree.len[BL_ORDER[maxBlIndex]] <> 0 then Break;
      Dec(maxBlIndex);
    end;
    Inc(ts.optLen, 3 * (Int64(maxBlIndex) + 1) + 5 + 5 + 4);

    optLenb := (ts.optLen + 3 + 7) shr 3;
    staticLenb := (ts.staticLen + 3 + 7) shr 3;
    if (staticLenb <= optLenb) or (cur.strategy = Z_FIXED) then optLenb := staticLenb;

    if (storedLen + 4 <= optLenb) and (blockStart >= winBase) then begin
      b.btype := btStored;
      b.plainPos := blockStart;
      b.storedLen := storedLen;
      { a stored block keeps no tokens }
      nTok := firstTok;
    end else if staticLenb = optLenb then begin
      b.btype := btFixed;
      b.nTokens := symNext;
    end else begin
      b.btype := btDynamic;
      b.nTokens := symNext;
      b.hlit := ltree.maxCode + 1;
      b.hdist := dtree.maxCode + 1;
      b.hclen := maxBlIndex + 1;
      for i := 0 to 18 do b.clen[i] := bltree.len[i];
      for i := 0 to L_CODES - 1 do if i <= ltree.maxCode then b.litLen[i] := ltree.len[i];
      for i := 0 to D_CODES - 1 do if i <= dtree.maxCode then b.distLen[i] := dtree.len[i];
      nSeq := 0;
      ScanTree(ltree, b.hlit - 1, bltree, seq, nSeq, True);
      ScanTree(dtree, b.hdist - 1, bltree, seq, nSeq, True);
      SetLength(b.clenSeq, nSeq);
      for i := 0 to nSeq - 1 do b.clenSeq[i] := seq[i];
    end;

    if trackBits then
      case b.btype of
        btStored: begin StoredBits; Inc(bitPos, 8 * b.storedLen); lastEob := 8; end;
        btFixed: begin Inc(bitPos, BlockBits(z, b, bitPos)); lastEob := StaticLLen[END_BLOCK]; end;
      else begin Inc(bitPos, BlockBits(z, b, bitPos)); lastEob := b.litLen[END_BLOCK]; end;
      end;
    PutBlock(b);
    InitBlock;
    blockStart := strstart;
    SetCheckNow;
  end;

  { a flush's marker: an empty stored block (_tr_stored_block of nothing)
    or an empty fixed one (_tr_align) }
  procedure AddMarker(stored: Boolean);
  var b: TDeflateBlock;
  begin
    b := Default(TDeflateBlock);
    b.firstToken := nTok;
    if stored then begin
      b.btype := btStored; b.plainPos := strstart;
      if trackBits then begin StoredBits; lastEob := 8; end;
    end else begin
      b.btype := btFixed;
      if trackBits then Inc(bitPos, 3 + StaticLLen[END_BLOCK]);
    end;
    PutBlock(b);
    SetCheckNow;
  end;

  { deflate_fast, until the lookahead is drained or, at the top of the
    loop, strstart reaches stopAt }
  procedure DeflateFast;
  begin
    while not stop do begin
      if (stopAt > 0) and (strstart >= stopAt) then Exit;
      Slide;
      if Lookahead = 0 then Break;
      hashHead := 0;
      if Lookahead >= MIN_MATCH then hashHead := InsertString(strstart);
      if (hashHead > lo) and (strstart - hashHead <= maxDist) then
        matchLength := LongestMatch(hashHead);
      if matchLength >= MIN_MATCH then begin
        bflush := TallyDist(strstart - matchStart, matchLength - MIN_MATCH);
        if (matchLength <= maxLazy) and (Lookahead - matchLength >= MIN_MATCH) then begin
          Dec(matchLength);
          repeat
            Inc(strstart);
            InsertString(strstart);
            Dec(matchLength);
          until matchLength = 0;
          Inc(strstart);
        end else begin
          Inc(strstart, matchLength);
          matchLength := 0;
          insH := Win(strstart);
          UpdateHash(Win(strstart + 1));
        end;
      end else begin
        bflush := TallyLit(plain[strstart]);
        Inc(strstart);
      end;
      if bflush then FlushBlock(False);
    end;
  end;

  { deflate_slow, the same way; drained, the literal it still holds }
  procedure DeflateSlow;
  begin
    while not stop do begin
      if (stopAt > 0) and (strstart >= stopAt) then Exit;
      Slide;
      if Lookahead = 0 then Break;
      hashHead := 0;
      if Lookahead >= MIN_MATCH then hashHead := InsertString(strstart);
      prevLength := matchLength; prevMatch := matchStart;
      matchLength := MIN_MATCH - 1;
      if (hashHead > lo) and (prevLength < maxLazy) and (strstart - hashHead <= maxDist) then begin
        matchLength := LongestMatch(hashHead);
        if (matchLength <= 5) and ((cur.strategy = Z_FILTERED) or
           ((matchLength = MIN_MATCH) and (strstart - matchStart > tooFar))) then
          matchLength := MIN_MATCH - 1;
      end;
      if (prevLength >= MIN_MATCH) and (matchLength <= prevLength) then begin
        maxInsert := strstart + Lookahead - MIN_MATCH;
        bflush := TallyDist(strstart - 1 - prevMatch, prevLength - MIN_MATCH);
        { lookahead -= prev_length - 1, as strstart moves }
        Dec(prevLength, 2);
        repeat
          Inc(strstart);
          if strstart <= maxInsert then InsertString(strstart);
          Dec(prevLength);
        until prevLength = 0;
        matchAvailable := 0;
        matchLength := MIN_MATCH - 1;
        Inc(strstart);
        if bflush then FlushBlock(False);
      end else if matchAvailable <> 0 then begin
        bflush := TallyLit(plain[strstart - 1]);
        if bflush then FlushBlock(False);
        Inc(strstart);
      end else begin
        matchAvailable := 1;
        Inc(strstart);
      end;
    end;
    if stop then Exit;
    if matchAvailable <> 0 then begin
      TallyLit(plain[strstart - 1]);
      matchAvailable := 0;
    end;
  end;

  procedure DeflateRle;
  var run: Integer; prevByte: Byte;
  begin
    while not stop do begin
      if (stopAt > 0) and (strstart >= stopAt) then Exit;
      Slide;
      if Lookahead = 0 then Break;
      matchLength := 0;
      if (Lookahead >= MIN_MATCH) and (strstart > org) then begin
        prevByte := plain[strstart - 1];
        run := 0;
        while (run < MAX_MATCH) and (strstart + run < lim) and (plain[strstart + run] = prevByte) do Inc(run);
        if run >= MIN_MATCH then matchLength := run;
      end;
      if matchLength >= MIN_MATCH then begin
        bflush := TallyDist(1, matchLength - MIN_MATCH);
        Inc(strstart, matchLength);
        matchLength := 0;
      end else begin
        bflush := TallyLit(plain[strstart]);
        Inc(strstart);
      end;
      if bflush then FlushBlock(False);
    end;
  end;

  procedure DeflateHuff;
  begin
    while not stop do begin
      if (stopAt > 0) and (strstart >= stopAt) then Exit;
      Slide;
      if Lookahead = 0 then Break;
      bflush := TallyLit(plain[strstart]);
      Inc(strstart);
      if bflush then FlushBlock(False);
    end;
  end;

  { the key of DeflateC's nx4 links: deflate_slow with the filtered strategy
    drops every match of 5 bytes or fewer, so its search starts at 5 and the
    links of the same 6 bytes skip more (ppazlibc.c's zd_longest) }
  function Key1(fast: Boolean): SizeInt;
  begin
    if not fast and (prm.strategy = Z_FILTERED) then Result := 6 else Result := 4;
  end;

  { DeflateFast or DeflateSlow in C (ppazlibc.c's ppaz_deflate, on st, set
    up by SetupC), which comes back here to flush each block }
  procedure DeflateC(fast: Boolean);
  var r: SizeInt;
  begin
    st.strstart := strstart; st.matchStart := matchStart; st.prevMatch := prevMatch; st.winBase := winBase;
    st.matchLength := matchLength; st.prevLength := prevLength; st.matchAvailable := matchAvailable;
    st.insH := insH; st.nTok := nTok; st.symNext := symNext;
    st.goodMatch := goodMatch; st.maxLazy := maxLazy; st.niceMatch := niceMatch; st.maxChain := maxChain;
    st.filtered := Ord(cur.strategy = Z_FILTERED); st.fast := Ord(fast);
    st.lim := lim; st.lo := lo; st.stopAt := stopAt; st.pending := 0; st.tooFar := tooFar;
    repeat
      st.checkNow := Ord(checkNow); st.stop := Ord(stop);
      r := ppaz_deflate(st);
      strstart := st.strstart; nTok := st.nTok; symNext := st.symNext; winBase := st.winBase;
      if st.stop <> 0 then begin stop := True; diverged := True; end;
      if r <> ZD_FLUSH then Break;
      FlushBlock(False);
      st.nTok := nTok; st.symNext := symNext;
    until False;
    matchStart := st.matchStart; prevMatch := st.prevMatch; matchLength := st.matchLength;
    prevLength := st.prevLength; matchAvailable := st.matchAvailable; insH := st.insH;
  end;

  { DeflateC's state: its tables, as the flow needs them: d4's key 6 only
    where every loop with chains is a filtered deflate_slow, the 16 bytes'
    links where any is a level of chains of 1024 or more }
  procedure SetupC;
  var k: SizeInt; key, room, reach: SizeInt; long16: Boolean; lv, sg: Integer;
  begin
    key := Key1(prm.level <= 3);
    long16 := CONFIG[prm.level, 3] >= 1024;
    lv := prm.level; sg := prm.strategy;
    if ZlibFunc(lv, sg) < FN_FAST then key := 0;
    for k := 0 to High(flow.events) do
      if flow.events[k].kind = ZE_PARAMS then begin
        lv := flow.events[k].level; sg := flow.events[k].strategy;
        if ZlibFunc(lv, sg) >= FN_FAST then begin
          if CONFIG[lv, 3] >= 1024 then long16 := True;
          if (lv <= 3) or (sg <> Z_FILTERED) then key := 4
          else if key = 0 then key := 6;
        end;
      end;
    if key = 0 then key := 4;
    if scratch <> nil then begin
      Zeroed32(scratch^.head32, hashSize); head32 := scratch^.head32;
      Zeroed64(scratch^.posC, wsize); posC := scratch^.posC;
      Zeroed16(scratch^.cnt, hashSize); cnt := scratch^.cnt;
    end else begin
      head32 := nil; SetLength(head32, hashSize);
      posC := nil; SetLength(posC, wsize); cnt := nil; SetLength(cnt, hashSize);
    end;
    { the skip tables' size only changes how often a collision makes the
      search walk zlib's chain, never the choices: sized by what the run
      may reach (against ref, a few times ref's tokens) }
    reach := n;
    if (ref <> nil) and (4 * (Length(ref^.tokLen) + SizeInt(symEnd)) < reach) then reach := 4 * (Length(ref^.tokLen) + symEnd);
    skipBits := SKIP_BITS_MIN;
    while (skipBits < SKIP_BITS_MAX) and (SizeInt(1) shl skipBits < 2 * reach) do Inc(skipBits);
    d16 := nil; t16 := nil;
    if scratch <> nil then begin
      Zeroed32(scratch^.t4, 1 shl skipBits); t4 := scratch^.t4;
      Zeroed32(scratch^.t8, 1 shl skipBits); t8 := scratch^.t8;
      if long16 then begin
        Zeroed16(scratch^.d16, wsize); d16 := scratch^.d16;
        Zeroed32(scratch^.t16, 1 shl skipBits); t16 := scratch^.t16;
      end;
    end else begin
      t4 := nil; SetLength(t4, 1 shl skipBits);
      t8 := nil; SetLength(t8, 1 shl skipBits);
      if long16 then begin
        SetLength(d16, wsize); SetLength(t16, 1 shl skipBits);
      end;
    end;
    { room for every token; against ref, for ref's and a block's more
      (where ref's block is stored, zlib's tokens until it decides; past
      ref's, the first one stops the run) }
    room := n + 8;
    if (ref <> nil) and (Length(ref^.tokLen) + symEnd + 16 < room) then room := Length(ref^.tokLen) + symEnd + 16;
    if scratch <> nil then begin
      { the scratch's own arrays (the end's SetLength gives z a copy of
        what it holds) }
      if Length(scratch^.tokLen) < room then begin
        scratch^.tokLen := nil; scratch^.tokVal := nil;
        SetLength(scratch^.tokLen, room); SetLength(scratch^.tokVal, room);
      end;
      if nTok > 0 then begin
        Move(z.tokLen[0], scratch^.tokLen[0], nTok * SizeOf(Word));
        Move(z.tokVal[0], scratch^.tokVal[0], nTok * SizeOf(Word));
      end;
      z.tokLen := scratch^.tokLen; z.tokVal := scratch^.tokVal;
    end else begin
      SetLength(z.tokLen, room); SetLength(z.tokVal, room);
    end;
    st := Default(TZDeflate);
    st.plain := @plain[0]; st.n := n;
    st.wsize := wsize; st.wmask := wmask; st.maxDist := maxDist;
    st.hashMask := hashMask; st.hashShift := hashShift;
    st.head := @head32[0]; st.pos := @posC[0]; st.cnt := @cnt[0]; st.t4 := @t4[0]; st.t8 := @t8[0];
    if Length(t16) > 0 then begin st.d16 := @d16[0]; st.t16 := @t16[0]; end;
    st.tokLen := @z.tokLen[0]; st.tokVal := @z.tokVal[0];
    if (ref <> nil) and (Length(ref^.tokLen) > 0) then begin
      st.refLen := @ref^.tokLen[0]; st.refVal := @ref^.tokVal[0]; st.refN := Length(ref^.tokLen);
    end;
    st.lfreq := @ltree.freq[0]; st.dfreq := @dtree.freq[0];
    st.symEnd := symEnd;
    st.lengthCode := @LengthCode[0]; st.distCode := @DistCode[0];
    st.skipBits := skipBits;
    st.key1 := key;
    st.lim := n; st.tooFar := tooFar;
    cReady := True;
  end;

  { deflate_slow on several threads, the same tokens and blocks (levels 4 to
    9, default or filtered strategy, nothing to compare with). The input is
    cut into segments, and each is parsed on its own from its start: the
    window before it inserted first (deflate_slow inserts every position,
    so its chains and skip links are then the whole run's), with no match
    pending, as the run is just after each match. Where a segment and the
    next both end a match at the same position, from there on they make the
    same tokens: the tokens are taken from one up to that position and from
    the next after it. Then the blocks, in order, as the run ends them (a
    block's symbols full; whether it may be stored is decided with the
    window base the run had, which follows from the positions). False, and
    nothing changed, where two segments did not meet: the caller runs
    deflate_slow alone. }
  function ParallelSlow: Boolean;
  type
    TSeg = record
      a, stopAt, nTok, nSync, endLit, tokBase: SizeInt;
      syncPos, syncTok: array of SizeInt;
    end;
  var
    segs: array of TSeg;
    nSeg, segLen, segRoom, k, i, j, pos, iterStart, t, total, piece, tl: SizeInt;
    tlen, tval: Integer;
    from, upTo: array of SizeInt;
    toks: PWord;                    { every segment's tokens: lengths, then values }
    ok: Boolean;

    procedure RunSeg(k: SizeInt);
    var st: TZDeflate; hd, a4, a8, a16: array of LongWord; pv: array of QWord; c16, n16: array of Word;
        lf, df: array of LongInt; sb, len, pre, r, maxSync: SizeInt;
    begin
      with segs[k] do begin
        len := stopAt - a;
        if stopAt = 0 then len := n - a;
        pre := a - wsize; if pre < 0 then pre := 0;
        hd := nil; SetLength(hd, hashSize); pv := nil; SetLength(pv, wsize);
        c16 := nil; SetLength(c16, hashSize);
        { a segment's tables: its window's positions live, a few times their
          number of slots is enough (and stays in the cache) }
        sb := SKIP_BITS_MIN;
        while (sb < PAR_SKIP_BITS) and (SizeInt(1) shl sb < 2 * (len + a - pre)) do Inc(sb);
        a4 := nil; SetLength(a4, 1 shl sb); a8 := nil; SetLength(a8, 1 shl sb);
        n16 := nil; a16 := nil;
        if CONFIG[prm.level, 3] >= 1024 then begin SetLength(n16, wsize); SetLength(a16, 1 shl sb); end;
        lf := nil; SetLength(lf, L_CODES); df := nil; SetLength(df, D_CODES);
        { the syncs near its start and in the overlap only }
        maxSync := 2 * PAR_OVERLAP div 3 + 16;
        syncPos := nil; SetLength(syncPos, maxSync); syncTok := nil; SetLength(syncTok, maxSync);
        st := Default(TZDeflate);
        st.plain := @plain[0]; st.n := n;
        st.wsize := wsize; st.wmask := wmask; st.maxDist := maxDist;
        st.hashMask := hashMask; st.hashShift := hashShift;
        st.head := @hd[0]; st.pos := @pv[0]; st.cnt := @c16[0]; st.t4 := @a4[0]; st.t8 := @a8[0];
        if Length(a16) > 0 then begin st.d16 := @n16[0]; st.t16 := @a16[0]; end;
        st.skipBits := sb;
        st.key1 := Key1(False);   { before the window is inserted: its links have this key }
        ppaz_preinsert(st, pre, a);
        st.strstart := a; st.matchStart := 0; st.prevMatch := 0; st.winBase := 0;
        st.matchLength := MIN_MATCH - 1; st.prevLength := MIN_MATCH - 1; st.matchAvailable := 0;
        st.goodMatch := goodMatch; st.maxLazy := maxLazy; st.niceMatch := niceMatch; st.maxChain := maxChain;
        st.filtered := Ord(prm.strategy = Z_FILTERED); st.fast := 0;
        st.tokLen := toks + tokBase; st.tokVal := toks + tl + tokBase; st.nTok := 0;
        st.lfreq := @lf[0]; st.dfreq := @df[0];
        st.symNext := 0; st.symEnd := High(SizeInt);
        st.lengthCode := @LengthCode[0]; st.distCode := @DistCode[0];
        st.stopAt := stopAt;
        st.lim := n; st.lo := 0; st.tooFar := tooFar;
        { its start is where it meets the segment before it }
        syncPos[0] := a; syncTok[0] := 0;
        st.syncPos := @syncPos[1]; st.syncTok := @syncTok[1]; st.maxSync := maxSync - 1;
        st.syncLo := a + PAR_OVERLAP;
        if stopAt = 0 then st.syncHi := High(SizeInt) else st.syncHi := stopAt - PAR_OVERLAP;
        r := ppaz_deflate(st);
        if (r <> ZD_SEGEND) and (r <> ZD_DONE) then nTok := -1 else nTok := st.nTok;
        nSync := st.nSync + 1;
        endLit := st.endLit;
      end;
    end;

    function Slided(x: SizeInt): SizeInt;
    begin
      Result := 0;
      while x - Result >= wsize + maxDist do Inc(Result, wsize);
    end;

  begin
    Result := False;
    { two segments a thread: one that is slower to parse (a photo's detail
      against its sky) leaves less of the others waiting }
    nSeg := 2 * threads;
    if nSeg > n div PAR_SEG_MIN then nSeg := n div PAR_SEG_MIN;
    if nSeg < 2 then Exit;
    segLen := (n + nSeg - 1) div nSeg;
    { as many as there are segLen bytes for (rounding up can leave the last
      ones empty, past the end) }
    nSeg := (n + segLen - 1) div segLen;
    if nSeg < 2 then Exit;
    segRoom := segLen + PAR_OVERLAP + 16;
    tl := nSeg * segRoom;
    segs := nil; SetLength(segs, nSeg);
    for k := 0 to nSeg - 1 do begin
      segs[k] := Default(TSeg);
      segs[k].a := k * segLen;
      segs[k].tokBase := k * segRoom;
      if k = nSeg - 1 then segs[k].stopAt := 0
      else begin
        segs[k].stopAt := (k + 1) * segLen + PAR_OVERLAP;
        if segs[k].stopAt >= n then segs[k].stopAt := 0;
      end;
    end;
    GetMem(toks, 2 * tl * SizeOf(Word));
    try
      ParallelFor(nSeg, threads, @RunSeg);
      for k := 0 to nSeg - 1 do if segs[k].nTok < 0 then Exit;
      { where each segment hands over to the next: the first position past
        the next one's start where both just ended a match }
      from := nil; SetLength(from, nSeg); upTo := nil; SetLength(upTo, nSeg);
      from[0] := 0;
      for k := 1 to nSeg - 1 do begin
        ok := False;
        i := 0; j := 0;
        while (i < segs[k - 1].nSync) and (j < segs[k].nSync) do begin
          if segs[k - 1].syncPos[i] < segs[k].syncPos[j] then Inc(i)
          else if segs[k - 1].syncPos[i] > segs[k].syncPos[j] then Inc(j)
          else if segs[k - 1].syncTok[i] < from[k - 1] then begin Inc(i); Inc(j); end
          else begin ok := True; Break; end;
        end;
        if not ok then Exit;
        upTo[k - 1] := segs[k - 1].syncTok[i];
        from[k] := segs[k].syncTok[j];
      end;
      upTo[nSeg - 1] := segs[nSeg - 1].nTok;
      { the tokens, in order, and the blocks as deflate_slow ends them }
      total := 0;
      for k := 0 to nSeg - 1 do Inc(total, upTo[k] - from[k]);
      SetLength(z.tokLen, total + 8); SetLength(z.tokVal, total + 8);
      { TallyLit and TallyDist inlined (nothing to compare with): a token a
        step, the blocks' frequencies counted, a block ended where its
        symbols are full }
      pos := 0; t := 0;
      for k := 0 to nSeg - 1 do
        for piece := segs[k].tokBase + from[k] to segs[k].tokBase + upTo[k] - 1 do begin
          Inc(t);
          tlen := toks[piece]; tval := toks[tl + piece];
          z.tokLen[nTok] := tlen; z.tokVal[nTok] := tval; Inc(nTok);
          if tlen = 0 then begin
            Inc(ltree.freq[tval]);
            Inc(pos); iterStart := pos;
          end else begin
            Inc(ltree.freq[LengthCode[tlen - MIN_MATCH] + LITERALS + 1]);
            Inc(dtree.freq[DistCode[tval - 1]]);
            iterStart := pos + 1; Inc(pos, tlen);
          end;
          Inc(symNext);
          { the literal deflate_slow emits after its loop ends no block }
          if (symNext = symEnd) and not ((t = total) and (segs[nSeg - 1].endLit <> 0)) then begin
            strstart := pos; winBase := Slided(iterStart);
            FlushBlock(False);
          end;
        end;
    finally
      FreeMem(toks);
    end;
    if pos <> n then raise Exception.Create('ppazlib: the segments do not cover the input');
    strstart := n; winBase := Slided(n);
    FlushBlock(True);
    Result := True;
  end;

  procedure SetParams(level, strategy: Integer);
  begin
    cur.level := level; cur.strategy := strategy;
    goodMatch := CONFIG[level, 0]; maxLazy := CONFIG[level, 1];
    niceMatch := CONFIG[level, 2]; maxChain := CONFIG[level, 3];
  end;

  { fill_window after a flush, once the input that follows comes: the hash
    started again from the first position not inserted (its own two
    bytes), and s->insert, the positions before strstart the lookahead did
    not reach, inserted now that they have their 3 bytes; zlib takes the
    input all at once here (a piece of a byte or two would insert fewer,
    and the rest at the next). Where the hash went on along the input
    (fill_window between flushes) it was already that. }
  procedure Refill;
  var look, from, k, i: SizeInt;
  begin
    needFill := False;
    look := Lookahead;
    if look + insert < MIN_MATCH then Exit;
    from := strstart - insert; k := 0;
    while (insert > 0) do begin
      Inc(k); Dec(insert);
      if look + insert < MIN_MATCH then Break;
    end;
    if not chains then Exit;
    if UseZlibC and (n > 0) and (k > 0) then begin
      if not cReady then SetupC;
      ppaz_preinsert(st, from, from + k);
      insH := st.insH;
    end else begin
      insH := plain[from]; UpdateHash(plain[from + 1]);
      for i := from to from + k - 1 do InsertString(i);
    end;
  end;

  { the loop of the parameters in force, from strstart until the lookahead
    (lim) is drained or, at its top, strstart reaches stopPos (> 0) }
  procedure Run(stopPos: SizeInt);
  begin
    if needFill then Refill;
    stopAt := stopPos;
    case ZlibFunc(cur.level, cur.strategy) of
      FN_HUFF: DeflateHuff;
      FN_RLE: DeflateRle;
    else
      if UseZlibC and (n > 0) then begin
        if not cReady then SetupC;
        DeflateC(cur.level <= 3);
      end
      else if cur.level <= 3 then DeflateFast
      else DeflateSlow;
    end;
    stopAt := 0;
  end;

  { what deflate does at a flush once it has drained its input: the block
    ended (an empty one too before 1.2.5.3), the flush's marker, and what
    the hash takes or forgets }
  procedure Flush(kind: Integer);
  var eob: Integer;
  begin
    if (variant <> ZV_NEW) or (symNext > 0) then FlushBlock(False);
    if stop then Exit;
    case kind of
      ZE_SYNC, ZE_FULL: AddMarker(True);
      ZE_PARTIAL: begin
        eob := lastEob;
        AddMarker(False);
        { _tr_align before 1.2.5.3: a second one when the first's 10 bits
          and the previous end-of-block code gave inflate too little
          lookahead (bi_valid: the bits not yet written as a byte) }
        if (variant <> ZV_NEW) and (1 + eob + 10 - (bitPos and 7) < 9) then AddMarker(False);
        lastEob := StaticLLen[END_BLOCK];
      end;
    end;
    insert := 0;
    needFill := True;
    if kind = ZE_FULL then begin
      if variant = ZV_123 then begin
        { the hash cleared: no position before strstart is a match's start }
        if strstart > 0 then lo := strstart - 1;
      end else begin
        { strstart 0 again, at this position }
        org := strstart; lo := strstart; winBase := strstart; blockStart := strstart;
      end;
    end else if (variant = ZV_NEW) and (ZlibFunc(cur.level, cur.strategy) >= FN_FAST) then begin
      insert := strstart - org;
      if insert > MIN_MATCH - 1 then insert := MIN_MATCH - 1;
    end;
  end;

  procedure RunFlow;
  var k, j: SizeInt; e: TZlibEvent;
  begin
    for k := 0 to High(flow.events) do begin
      if stop then Exit;
      e := flow.events[k];
      if e.kind = ZE_PARAMS then begin
        if strstart < e.pos then begin
          { the input goes on to the next flush, or to the end }
          lim := n;
          for j := k + 1 to High(flow.events) do
            if flow.events[j].kind <> ZE_PARAMS then begin lim := flow.events[j].pos; Break; end;
          if lim < strstart then lim := strstart;
          Run(e.pos);
          if stop then Exit;
        end;
        SetParams(e.level, e.strategy);
      end else begin
        lim := e.pos;
        if lim < strstart then lim := strstart;
        Run(0);
        if stop then Exit;
        Flush(e.kind);
      end;
    end;
    if stop then Exit;
    lim := n;
    Run(0);
    if not stop then FlushBlock(True);
  end;

var wb: Integer;
begin
  z := Default(TZStream);
  goodBlocks := 0;
  n := Length(plain);
  wb := prm.wbits; if wb = 8 then wb := 9;
  wsize := SizeInt(1) shl wb; wmask := wsize - 1; maxDist := wsize - MIN_LOOKAHEAD;
  hashBits := prm.memLevel + 7;
  hashSize := 1 shl hashBits; hashMask := hashSize - 1;
  hashShift := (hashBits + MIN_MATCH - 1) div MIN_MATCH;
  cur := prm;
  variant := flow.variant and ZV_VERSION;
  if (flow.variant and ZV_NO_TOO_FAR) <> 0 then tooFar := 32767 else tooFar := TOO_FAR;
  trackBits := (Length(flow.events) > 0) and (variant <> ZV_NEW);
  bitPos := 0; lastEob := 8;
  lim := n; stopAt := 0; org := 0; lo := 0; insert := 0; needFill := False;
  { the chains: Pascal's (the reference, DeflateFast and DeflateSlow) or
    C's; deflate_huff and deflate_rle keep none }
  chains := ZlibFunc(prm.level, prm.strategy) >= FN_FAST;
  for k := 0 to High(flow.events) do
    if (flow.events[k].kind = ZE_PARAMS) and (ZlibFunc(flow.events[k].level, flow.events[k].strategy) >= FN_FAST) then
      chains := True;
  cReady := False;
  symEnd := (1 shl (prm.memLevel + 6)) - 1;
  head := nil; prev := nil;
  if not chains then
  else if not UseZlibC then begin
    SetLength(head, hashSize); SetLength(prev, wsize);
  end;
  goodMatch := CONFIG[prm.level, 0]; maxLazy := CONFIG[prm.level, 1];
  niceMatch := CONFIG[prm.level, 2]; maxChain := CONFIG[prm.level, 3];
  strstart := 0; blockStart := 0; winBase := 0; insH := 0;
  matchStart := 0; prevMatch := 0;
  matchLength := MIN_MATCH - 1; prevLength := MIN_MATCH - 1; matchAvailable := 0;
  nTok := 0; nBlocks := 0; diverged := False; stop := False;
  FillChar(ltree, SizeOf(ltree), 0);
  FillChar(dtree, SizeOf(dtree), 0);
  FillChar(bltree, SizeOf(bltree), 0);
  FillChar(ts, SizeOf(ts), 0);
  InitBlock;
  SetCheckNow;
  { fill_window's first hash: the first two bytes }
  if n >= MIN_MATCH then begin insH := plain[0]; UpdateHash(plain[1]); end;

  if Length(flow.events) > 0 then RunFlow
  else if UseZlibC and (ref = nil) and (threads > 1) and (prm.level >= 4) and (n >= PAR_MIN_BYTES) and
          (prm.strategy in [Z_DEFAULT_STRATEGY, Z_FILTERED]) and ParallelSlow then
  else begin
    Run(0);
    if not stop then FlushBlock(True);
  end;

  SetLength(z.blocks, nBlocks);
  SetLength(z.tokLen, nTok);
  SetLength(z.tokVal, nTok);
  z.raw := True;
  z.plain := plain;
  Result := not diverged and ((ref = nil) or (nBlocks = Length(ref^.blocks)));
end;

function FindZlibParams(const z: TZStream; out prm: TZlibParams): Boolean;
var e: TZStream;
begin
  Result := FindZlibParams(z, prm, e);
end;

function FindZlibParams(const z: TZStream; out prm: TZlibParams; out choices: TZStream): Boolean;
var lvMin, lvMax, wbMin, lv, st, ml, wb, k, first: Integer; order: array[0..8] of Integer;
const ML_ORDER: array[0..8] of Integer = (8, 9, 7, 6, 5, 4, 3, 2, 1);
begin
  { zlib ends a block when its symbols fill the buffer memLevel sizes,
    2^(memLevel + 6) - 1 of them: a first block of that many, with more
    after it, names the memLevel to try first (the others still follow:
    a writer that flushes gives blocks of other lengths) }
  order := ML_ORDER;
  first := 0;
  if Length(z.blocks) > 1 then
    for ml := 1 to 9 do
      if z.blocks[0].nTokens = (SizeInt(1) shl (ml + 6)) - 1 then first := ml;
  if first > 0 then begin
    k := 0;
    while order[k] <> first do Inc(k);
    while k > 0 do begin order[k] := order[k - 1]; Dec(k); end;
    order[0] := first;
  end;
  Result := False;
  prm := Default(TZlibParams);
  choices := Default(TZStream);
  case z.header[1] shr 6 of
    0: begin lvMin := 1; lvMax := 1; end;
    1: begin lvMin := 2; lvMax := 5; end;
    2: begin lvMin := 6; lvMax := 6; end;
  else begin lvMin := 7; lvMax := 9; end;
  end;
  wbMin := (z.header[0] shr 4) + 8;
  if z.raw then begin lvMin := 1; lvMax := 9; wbMin := 15; end;
  for wb := 15 downto wbMin do
    for ml := 0 to 8 do
      for st := Z_DEFAULT_STRATEGY to Z_FIXED do
        for lv := lvMin to lvMax do begin
          { huffman and rle do not depend on the level }
          if (st in [Z_HUFFMAN_ONLY, Z_RLE]) and (lv <> lvMin) then Continue;
          prm.level := lv; prm.strategy := st; prm.memLevel := order[ml]; prm.wbits := wb;
          if ZlibChoices(z.plain, prm, @z, choices) then Exit(True);
        end;
end;

procedure ZlibTrees(const lfreq, dfreq: array of Integer; var b: TDeflateBlock; out fixedNoBigger: Boolean);
var
  ltree, dtree, bltree: TTree; ts: TTreeState;
  maxBlIndex, i, nSeq: Integer;
  seq: array[0..L_CODES + D_CODES] of Word;
begin
  ltree := Default(TTree); dtree := Default(TTree); bltree := Default(TTree); ts := Default(TTreeState);
  for i := 0 to L_CODES - 1 do ltree.freq[i] := lfreq[i];
  for i := 0 to D_CODES - 1 do dtree.freq[i] := dfreq[i];
  BuildTree(ltree, ts, L_CODES, @StaticLLen[0], EXTRA_LBITS, LITERALS + 1, 15);
  BuildTree(dtree, ts, D_CODES, @StaticDLen[0], EXTRA_DBITS, 0, 15);
  nSeq := 0;
  ScanTree(ltree, ltree.maxCode, bltree, seq, nSeq, False);
  ScanTree(dtree, dtree.maxCode, bltree, seq, nSeq, False);
  BuildTree(bltree, ts, BL_CODES, nil, EXTRA_BLBITS, 0, 7);
  maxBlIndex := BL_CODES - 1;
  while maxBlIndex >= 3 do begin
    if bltree.len[BL_ORDER[maxBlIndex]] <> 0 then Break;
    Dec(maxBlIndex);
  end;
  Inc(ts.optLen, 3 * (Int64(maxBlIndex) + 1) + 5 + 5 + 4);
  fixedNoBigger := (ts.staticLen + 3 + 7) shr 3 <= (ts.optLen + 3 + 7) shr 3;
  b.hlit := ltree.maxCode + 1;
  b.hdist := dtree.maxCode + 1;
  b.hclen := maxBlIndex + 1;
  for i := 0 to 18 do b.clen[i] := bltree.len[i];
  FillChar(b.litLen, SizeOf(b.litLen), 0);
  FillChar(b.distLen, SizeOf(b.distLen), 0);
  for i := 0 to ltree.maxCode do b.litLen[i] := ltree.len[i];
  for i := 0 to dtree.maxCode do b.distLen[i] := dtree.len[i];
  nSeq := 0;
  ScanTree(ltree, b.hlit - 1, bltree, seq, nSeq, True);
  ScanTree(dtree, b.hdist - 1, bltree, seq, nSeq, True);
  SetLength(b.clenSeq, nSeq);
  for i := 0 to nSeq - 1 do b.clenSeq[i] := seq[i];
end;

procedure ZlibSendTree(const lens: array of Byte; count: Integer; var seq: array of Word; var nSeq: Integer);
var t, bl: TTree; i: Integer;
begin
  t.len[0] := 0;   { (only len is read, up to count: the rest need no clearing) }
  for i := 0 to count - 1 do t.len[i] := lens[i];
  ScanTree(t, count - 1, bl, seq, nSeq, True);
end;

procedure ZlibBlTree(const freq: array of Integer; out clen: array of Byte; out hclen: Integer);
var bltree: TTree; ts: TTreeState; i: Integer;
begin
  bltree := Default(TTree); ts := Default(TTreeState);
  for i := 0 to BL_CODES - 1 do bltree.freq[i] := freq[i];
  BuildTree(bltree, ts, BL_CODES, nil, EXTRA_BLBITS, 0, 7);
  hclen := BL_CODES;
  while hclen > 4 do begin
    if bltree.len[BL_ORDER[hclen - 1]] <> 0 then Break;
    Dec(hclen);
  end;
  for i := 0 to BL_CODES - 1 do clen[i] := bltree.len[i];
end;

procedure MakeTables;
var code, len, n, dist: Integer;
const BASE_LENGTH: array[0..28] of Integer = (
        0, 1, 2, 3, 4, 5, 6, 7, 8, 10, 12, 14, 16, 20, 24, 28, 32, 40, 48, 56,
        64, 80, 96, 112, 128, 160, 192, 224, 0);
      BASE_DIST: array[0..29] of Integer = (
        0, 1, 2, 3, 4, 6, 8, 12, 16, 24, 32, 48, 64, 96, 128, 192, 256, 384, 512, 768,
        1024, 1536, 2048, 3072, 4096, 6144, 8192, 12288, 16384, 24576);
begin
  for code := 0 to 27 do
    for n := 0 to (1 shl EXTRA_LBITS[code]) - 1 do begin
      len := BASE_LENGTH[code] + n;
      LengthCode[len] := code;
    end;
  { as zlib: length 258 (255 here) has its own code, 28 }
  LengthCode[255] := 28;
  for code := 0 to 29 do
    for n := 0 to (1 shl EXTRA_DBITS[code]) - 1 do begin
      dist := BASE_DIST[code] + n;
      DistCode[dist] := code;
    end;
  for n := 0 to 143 do StaticLLen[n] := 8;
  for n := 144 to 255 do StaticLLen[n] := 9;
  for n := 256 to 279 do StaticLLen[n] := 7;
  for n := 280 to 287 do StaticLLen[n] := 8;
  for n := 0 to D_CODES - 1 do StaticDLen[n] := 5;
end;

initialization
  MakeTables;
  UseZlibC := GetEnvironmentVariable('PPA_NOC') <> '1';
  PAR_MIN_BYTES := StrToInt64Def(GetEnvironmentVariable('PPA_TEST_PAR_BYTES'), PAR_MIN_BYTES_DEFAULT);
  if PAR_MIN_BYTES < 64 then PAR_MIN_BYTES := PAR_MIN_BYTES_DEFAULT;
  PAR_SEG_MIN := PAR_MIN_BYTES div 4;
end.
