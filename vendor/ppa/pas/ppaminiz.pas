{ miniz's deflate (tdefl, miniz 1.x to 3.x), exact: the choices it makes
  for a stream's bytes with given flags, as ppadeflate's blocks and tokens
  (ppadeflate.Encode writes them: the same bits). Recipe kind 2
  (ppapreflate) names miniz and its flags.

  A port of miniz's tdefl_compress_normal, tdefl_compress_fast,
  tdefl_find_match and tdefl_flush_block (miniz: MIT / public domain, Rich
  Geldreich and contributors; NOTICE has its license), step for step where
  a step decides a choice:
    - the parse (UseMinizC: ppaminizc.c, the same; Pascal the reference):
      the 32 KB ring with its 257 mirrored bytes, the 16-bit positions of
      the hash heads and links (0 ends a chain, so does a position 64K
      before), probes 3 at a time, the dropped matches (3 bytes from 8 KB
      or further, one whose distance is the ring position, at most 5 bytes
      with TDEFL_FILTER_MATCHES), lazy or greedy, RLE, raw; level 1's own
      loop (tdefl_compress_fast) in builds with unaligned loads (miniz 1.x
      on x86 and x86-64: variant MZV_FAST), which miniz 3.x builds without
      by default (level 1 then goes through the normal loop);
    - the blocks: the LZ code buffer (64 KB) full, or past 31 KB of bytes
      when the codes take 115/128 of them (not in level 1's loop); static
      codes under 48 bytes or with TDEFL_FORCE_ALL_STATIC_BLOCKS, else
      miniz's trees (ppacorr.LensMiniz, SeqMiniz); a stored block when the
      coded one is no smaller than its bytes and they are all still in the
      window; static codes when the coded block overflows the output buffer.
  miniz 1.14 and 3.0.2 give the same streams at every level but 1 (the
  loop), checked on the corpus. One call with all the bytes and
  TDEFL_FINISH, as tdefl_compress_mem_to_heap, the PNG writer and
  mz_compress make it: no flushes. }
unit ppaminiz;

{$I ppa.inc}
{$ifopt R-}{$fatal ppaminiz: range checks ($R+) are mandatory}{$endif}
{$ifopt Q-}{$fatal ppaminiz: overflow checks ($Q+) are mandatory}{$endif}

interface

uses SysUtils, ppadeflate;

const
  { tdefl's flags, as miniz has them: the probes (low 12 bits) and these }
  MZ_PROBES_MASK = $FFF;
  MZ_GREEDY = $4000;
  MZ_RLE = $10000;
  MZ_FILTER = $20000;
  MZ_STATIC = $40000;
  MZ_RAW = $80000;
  MZ_FLAGS = MZ_PROBES_MASK or MZ_GREEDY or MZ_RLE or MZ_FILTER or MZ_STATIC or MZ_RAW;
  { the build: 0, level 1 through the normal loop (miniz 3.x by default,
    or built without unaligned loads); MZV_FAST, level 1's own loop (miniz
    1.x on x86, or built with MINIZ_USE_UNALIGNED_LOADS_AND_STORES) }
  MZV_FAST = 1;
  MZV_LAST = MZV_FAST;

type
  TMinizParams = record
    flags: LongWord;    { MZ_FLAGS' bits only }
    variant: Integer;   { 0..MZV_LAST }
  end;

function MinizValid(const p: TMinizParams): Boolean;

{ The choices miniz makes with p for plain (raw deflate, no framing), in e
  (blocks, tokens, plain). ref: a stream's choices to follow; False as soon
  as a token, a block's end or its type is not ref's (e is then not
  usable). False also on a block whose static codes overflow miniz's
  output buffer (no stream miniz writes) and on p MinizValid refuses.
  hdr: the zlib header's 2 bytes written before the first block (miniz's
  output buffer holds them). }
function MinizChoices(const plain: TBytes; const p: TMinizParams; ref: PZStream; hdr: Boolean;
  out e: TZStream): Boolean;

{ The flags (and build) whose choices are z's: the levels' probes, greedy
  or lazy, and the strategies (filtered, RLE, Huffman only, fixed, raw),
  the likely ones first. choices: MinizChoices of them. }
function FindMinizParams(const z: TZStream; out p: TMinizParams; out choices: TZStream): Boolean;

var
  { the parse in C (ppaminizc.c); False: in Pascal, the reference. PPA_NOC=1
    in the environment makes it False }
  UseMinizC: Boolean = True;

implementation

uses ppacorr;

{$L ppaminizc.o}

const
  DICT_SIZE = 32768;
  DICT_MASK = DICT_SIZE - 1;
  MIN_MATCH = 3;
  MAX_MATCH = 258;
  HASH_SIZE = 1 shl 15;
  HASH_SHIFT = 5;
  LEVEL1_HASH_MASK = 4095;
  CODE_BUF_SIZE = 64 * 1024;
  OUT_BUF_SIZE = (CODE_BUF_SIZE * 13) div 10;
  FAST_LOOKAHEAD = 4096;

type
  { a block the parse ended: its tokens, the bytes it covers (from dictPos,
    total), whether they were all still in the window when it ended
    (stored allowed), final }
  TMzBlock = record
    firstTok, nTok, dictPos, total: SizeInt;
    rawOk, final: SizeInt;
  end;
  PMzBlock = ^TMzBlock;

  { ppaminizc.c's mz_parse_t, field for field }
  TMzParse = record
    plain: PByte; n: SizeInt;
    flags, fast: SizeInt;
    dict: PByte; hash, next: PWord;
    tokLen, tokVal: PWord; nTok: SizeInt;
    blocks: PMzBlock; nBlocks, maxBlocks: SizeInt;
    { ref: per block, -1 stored (its range checked), else its first token and count }
    refFirst, refCount, refPos, refLen: PSizeInt; refBlocks: SizeInt;
    refTokLen, refTokVal: PWord;
    useRef: SizeInt;
  end;

function ppamz_parse(var s: TMzParse): SizeInt; cdecl; external name 'ppamz_parse';

const
  NUM_PROBES: array[0..10] of Word = (0, 1, 6, 32, 16, 32, 128, 256, 512, 768, 1500);

var
  LenSymT: array[3..258] of Word;
  DistSymT: array[1..32768] of Byte;
  FixedLitT: array[0..287] of Byte;

function MinizValid(const p: TMinizParams): Boolean;
begin
  Result := ((p.flags and not LongWord(MZ_FLAGS)) = 0) and (p.variant >= 0) and (p.variant <= MZV_LAST);
end;

{ ---------------------------------------------------------------- the parse (the reference) }

{ the parse of s.plain into tokens and blocks; False at the first
  difference from the ref (s.useRef) }
function ParsePas(var s: TMzParse): Boolean;
var
  dict: array of Byte;
  hash, next: array of Word;
  lookPos, lookSize, dictSize, total, dictPos, codeOfs, flagsLeft: SizeInt;
  savedLen, savedDist, savedLit: SizeInt;
  src, srcLeft: SizeInt;
  maxProbes: array[0..1] of SizeInt;
  greedy: Boolean;
  blockTok: SizeInt;     { tokens in the current block }
  ok: Boolean;

  { the ref's block bi: -1 none past its end }
  function RefStored(bi: SizeInt): Boolean;
  begin
    Result := s.refFirst[bi] < 0;
  end;

  procedure Token(len, val: SizeInt);
  var bi, k: SizeInt;
  begin
    if s.useRef <> 0 then begin
      bi := s.nBlocks;
      if bi >= s.refBlocks then ok := False
      else if not RefStored(bi) then begin
        if blockTok >= s.refCount[bi] then ok := False
        else begin
          k := s.refFirst[bi] + blockTok;
          if (s.refTokLen[k] <> len) or (s.refTokVal[k] <> val) then ok := False;
        end;
      end;
    end;
    s.tokLen[s.nTok] := len; s.tokVal[s.nTok] := val;
    Inc(s.nTok); Inc(blockTok);
  end;

  procedure Literal(c: SizeInt);
  begin
    Token(0, c);
    Inc(total); Inc(codeOfs);
    Dec(flagsLeft);
    if flagsLeft = 0 then begin flagsLeft := 8; Inc(codeOfs); end;
  end;

  procedure Match(len, dist: SizeInt);
  begin
    Token(len, dist);
    Inc(total, len); Inc(codeOfs, 3);
    Dec(flagsLeft);
    if flagsLeft = 0 then begin flagsLeft := 8; Inc(codeOfs); end;
  end;

  procedure Flush(final: Boolean);
  var bi: SizeInt;
  begin
    bi := s.nBlocks;
    if s.useRef <> 0 then begin
      if bi >= s.refBlocks then ok := False
      else if RefStored(bi) then begin
        if (s.refPos[bi] <> dictPos) or (s.refLen[bi] <> total) then ok := False;
      end else if blockTok <> s.refCount[bi] then ok := False;
      if final and (bi + 1 <> s.refBlocks) then ok := False;
    end;
    if bi >= s.maxBlocks then begin ok := False; Exit; end;
    s.blocks[bi].firstTok := s.nTok - blockTok;
    s.blocks[bi].nTok := blockTok;
    s.blocks[bi].dictPos := dictPos;
    s.blocks[bi].total := total;
    s.blocks[bi].rawOk := Ord(lookPos - dictPos <= dictSize);
    s.blocks[bi].final := Ord(final);
    Inc(s.nBlocks);
    Inc(dictPos, total);
    total := 0; codeOfs := 1; flagsLeft := 8; blockTok := 0;
  end;

  procedure PutDict(dst: SizeInt; c: Byte); inline;
  begin
    dict[dst] := c;
    if dst < MAX_MATCH - 1 then dict[DICT_SIZE + dst] := c;
  end;

  { tdefl_find_match (the byte-by-byte one; the unaligned one finds the same) }
  procedure FindMatch(maxDist, maxLen: SizeInt; var mDist, mLen: SizeInt);
  var pos, ml, probe, nextP, dist, left, plen, k: SizeInt; c0, c1: Byte; hit: Boolean;
  begin
    pos := lookPos and DICT_MASK; ml := mLen; probe := pos;
    left := maxProbes[Ord(ml >= 32)];
    c0 := dict[pos + ml]; c1 := dict[pos + ml - 1];
    if maxLen <= ml then Exit;
    dist := 0;
    while True do begin
      hit := False;
      repeat
        Dec(left);
        if left = 0 then Exit;
        for k := 1 to 3 do begin
          nextP := next[probe];
          if nextP = 0 then Exit;
          dist := (lookPos - nextP) and $FFFF;
          if dist > maxDist then Exit;
          probe := nextP and DICT_MASK;
          if (dict[probe + ml] = c0) and (dict[probe + ml - 1] = c1) then begin hit := True; Break; end;
        end;
      until hit;
      if dist = 0 then Exit;
      plen := 0;
      while (plen < maxLen) and (dict[pos + plen] = dict[probe + plen]) do Inc(plen);
      if plen > ml then begin
        mDist := dist; ml := plen; mLen := ml;
        if ml = maxLen then Exit;
        c0 := dict[pos + ml]; c1 := dict[pos + ml - 1];
      end;
    end;
  end;

  { tdefl_compress_normal, all the bytes and TDEFL_FINISH }
  procedure Normal;
  var dst, ins, h, num, i, curLen, curDist, curPos, move: SizeInt; c: Byte;
  begin
    while ok and ((srcLeft > 0) or (lookSize > 0)) do begin
      if lookSize + dictSize >= MIN_MATCH - 1 then begin
        dst := (lookPos + lookSize) and DICT_MASK;
        ins := lookPos + lookSize - 2;
        h := (SizeInt(dict[ins and DICT_MASK]) shl HASH_SHIFT) xor dict[(ins + 1) and DICT_MASK];
        num := srcLeft; if num > MAX_MATCH - lookSize then num := MAX_MATCH - lookSize;
        Dec(srcLeft, num); Inc(lookSize, num);
        for i := 1 to num do begin
          c := s.plain[src]; Inc(src);
          PutDict(dst, c);
          h := ((h shl HASH_SHIFT) xor c) and (HASH_SIZE - 1);
          next[ins and DICT_MASK] := hash[h];
          hash[h] := Word(ins and $FFFF);
          dst := (dst + 1) and DICT_MASK;
          Inc(ins);
        end;
      end else
        while (srcLeft > 0) and (lookSize < MAX_MATCH) do begin
          c := s.plain[src]; Inc(src);
          dst := (lookPos + lookSize) and DICT_MASK;
          Dec(srcLeft);
          PutDict(dst, c);
          Inc(lookSize);
          if lookSize + dictSize >= MIN_MATCH then begin
            ins := lookPos + (lookSize - 1) - 2;
            h := ((SizeInt(dict[ins and DICT_MASK]) shl (HASH_SHIFT * 2)) xor
              (SizeInt(dict[(ins + 1) and DICT_MASK]) shl HASH_SHIFT) xor c) and (HASH_SIZE - 1);
            next[ins and DICT_MASK] := hash[h];
            hash[h] := Word(ins and $FFFF);
          end;
        end;
      if dictSize > DICT_SIZE - lookSize then dictSize := DICT_SIZE - lookSize;

      move := 1;
      curDist := 0;
      if savedLen <> 0 then curLen := savedLen else curLen := MIN_MATCH - 1;
      curPos := lookPos and DICT_MASK;
      if (s.flags and (MZ_RLE or MZ_RAW)) <> 0 then begin
        if (dictSize <> 0) and ((s.flags and MZ_RAW) = 0) then begin
          c := dict[(curPos - 1) and DICT_MASK];
          curLen := 0;
          while (curLen < lookSize) and (dict[curPos + curLen] = c) do Inc(curLen);
          if curLen < MIN_MATCH then curLen := 0 else curDist := 1;
        end;
      end else
        FindMatch(dictSize, lookSize, curDist, curLen);
      if ((curLen = MIN_MATCH) and (curDist >= 8 * 1024)) or (curPos = curDist) or
         (((s.flags and MZ_FILTER) <> 0) and (curLen <= 5)) then begin
        curDist := 0; curLen := 0;
      end;
      if savedLen <> 0 then begin
        if curLen > savedLen then begin
          Literal(savedLit);
          if curLen >= 128 then begin
            Match(curLen, curDist);
            savedLen := 0; move := curLen;
          end else begin
            savedLit := dict[curPos]; savedDist := curDist; savedLen := curLen;
          end;
        end else begin
          Match(savedLen, savedDist);
          move := savedLen - 1; savedLen := 0;
        end;
      end else if curDist = 0 then
        Literal(dict[curPos])
      else if greedy or ((s.flags and MZ_RLE) <> 0) or (curLen >= 128) then begin
        Match(curLen, curDist);
        move := curLen;
      end else begin
        savedLit := dict[curPos]; savedDist := curDist; savedLen := curLen;
      end;
      Inc(lookPos, move);
      Dec(lookSize, move);
      Inc(dictSize, move); if dictSize > DICT_SIZE then dictSize := DICT_SIZE;
      if (codeOfs > CODE_BUF_SIZE - 8) or
         ((total > 31 * 1024) and ((((codeOfs * 115) shr 7) >= total) or ((s.flags and MZ_RAW) <> 0))) then
        Flush(False);
    end;
  end;

  { tdefl_compress_fast, all the bytes and TDEFL_FINISH }
  procedure Fast;
  var dst, num, n, i, curPos, len, dist, probe, h, k: SizeInt; tri: LongWord; stop: Boolean;
  begin
    curPos := lookPos and DICT_MASK;
    while ok and ((srcLeft > 0) or (lookSize > 0)) do begin
      dst := (lookPos + lookSize) and DICT_MASK;
      num := srcLeft; if num > FAST_LOOKAHEAD - lookSize then num := FAST_LOOKAHEAD - lookSize;
      Dec(srcLeft, num); Inc(lookSize, num);
      while num > 0 do begin
        n := DICT_SIZE - dst; if n > num then n := num;
        Move(s.plain[src], dict[dst], n);
        if dst < MAX_MATCH - 1 then begin
          k := MAX_MATCH - 1 - dst; if k > n then k := n;
          Move(s.plain[src], dict[DICT_SIZE + dst], k);
        end;
        Inc(src, n);
        dst := (dst + n) and DICT_MASK;
        Dec(num, n);
      end;
      if dictSize > DICT_SIZE - lookSize then dictSize := DICT_SIZE - lookSize;
      while ok and (lookSize >= 4) do begin
        len := 1;
        tri := LongWord(dict[curPos]) or (LongWord(dict[curPos + 1]) shl 8) or (LongWord(dict[curPos + 2]) shl 16);
        h := (tri xor (tri shr 17)) and LEVEL1_HASH_MASK;
        probe := hash[h];
        hash[h] := Word(lookPos and $FFFF);
        dist := (lookPos - probe) and $FFFF;
        probe := probe and DICT_MASK;
        if (dist <= dictSize) and (dict[probe] = Byte(tri)) and (dict[probe + 1] = Byte(tri shr 8)) and
           (dict[probe + 2] = Byte(tri shr 16)) then begin
          { the 2-byte words from the third on, 4 at a time, 32 times: the
            first that differs, and whether its first byte is the same }
          i := 2; stop := False;
          for k := 1 to 128 do begin
            if (dict[curPos + i] <> dict[probe + i]) or (dict[curPos + i + 1] <> dict[probe + i + 1]) then begin
              stop := True; Break;
            end;
            if k < 128 then Inc(i, 2);
          end;
          if stop then len := i + Ord(dict[curPos + i] = dict[probe + i])
          else if dist <> 0 then len := MAX_MATCH
          else len := 0;
          if (len < MIN_MATCH) or ((len = MIN_MATCH) and (dist >= 8 * 1024)) then begin
            len := 1;
            Literal(Byte(tri));
          end else begin
            if len > lookSize then len := lookSize;
            Match(len, dist);
          end;
        end else
          Literal(Byte(tri));
        Inc(lookPos, len);
        Inc(dictSize, len); if dictSize > DICT_SIZE then dictSize := DICT_SIZE;
        curPos := (curPos + len) and DICT_MASK;
        Dec(lookSize, len);
        if codeOfs > CODE_BUF_SIZE - 8 then Flush(False);
      end;
      while ok and (lookSize > 0) do begin
        Literal(dict[curPos]);
        Inc(lookPos);
        Inc(dictSize); if dictSize > DICT_SIZE then dictSize := DICT_SIZE;
        curPos := (curPos + 1) and DICT_MASK;
        Dec(lookSize);
        if codeOfs > CODE_BUF_SIZE - 8 then Flush(False);
      end;
    end;
  end;

begin
  SetLength(dict, DICT_SIZE + MAX_MATCH - 1);
  SetLength(hash, HASH_SIZE);
  SetLength(next, DICT_SIZE);
  FillChar(dict[0], Length(dict), 0);
  FillChar(hash[0], 2 * Length(hash), 0);
  FillChar(next[0], 2 * Length(next), 0);
  maxProbes[0] := 1 + ((s.flags and $FFF) + 2) div 3;
  maxProbes[1] := 1 + (((s.flags and $FFF) shr 2) + 2) div 3;
  greedy := (s.flags and MZ_GREEDY) <> 0;
  lookPos := 0; lookSize := 0; dictSize := 0; total := 0; dictPos := 0;
  codeOfs := 1; flagsLeft := 8;
  savedLen := 0; savedDist := 0; savedLit := 0;
  src := 0; srcLeft := s.n;
  s.nTok := 0; s.nBlocks := 0; blockTok := 0;
  ok := True;
  if s.fast <> 0 then Fast else Normal;
  if ok then Flush(True);
  Result := ok;
end;

{ ---------------------------------------------------------------- the blocks }

procedure MakeTables;
var l, s, d: Integer;
const
  LEN_B: array[257..285] of Word = (3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
    35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258);
  DIST_B: array[0..29] of Word = (1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
    257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577);
begin
  s := 257;
  for l := 3 to 258 do begin
    while (s < 284) and (l >= LEN_B[s + 1]) do Inc(s);
    LenSymT[l] := s;
  end;
  LenSymT[258] := 285;
  s := 0;
  for d := 1 to 32768 do begin
    while (s < 29) and (d >= DIST_B[s + 1]) do Inc(s);
    DistSymT[d] := s;
  end;
  for l := 0 to 287 do
    if l <= 143 then FixedLitT[l] := 8
    else if l <= 255 then FixedLitT[l] := 9
    else if l <= 279 then FixedLitT[l] := 7
    else FixedLitT[l] := 8;
end;

{ the bits of a block with these codes: its symbols, without the header }
function SymBits(const z: TZStream; first, cnt: SizeInt; const ll, dl: array of Byte): Int64;
const
  LX: array[257..285] of Byte = (0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
    3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0);
  DX: array[0..29] of Byte = (0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
    7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13);
var i: SizeInt; l, s: Integer;
begin
  Result := ll[256];
  for i := first to first + cnt - 1 do begin
    l := z.tokLen[i];
    if l = 0 then Inc(Result, ll[z.tokVal[i]])
    else begin
      s := LenSymT[l];
      Inc(Result, ll[s] + LX[s]);
      s := DistSymT[z.tokVal[i]];
      Inc(Result, dl[s] + DX[s]);
    end;
  end;
end;

{ tdefl_start_dynamic_block for the counts of a block: its header into b;
  its bits (header and symbols, the 3 block header bits included) }
function Dynamic(const z: TZStream; var b: TDeflateBlock): Int64;
const
  CLX: array[0..18] of Byte = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 3, 7);
  ORD_: array[0..18] of Byte = (16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15);
var lf: array[0..287] of Integer; df: array[0..31] of Integer; sf: array[0..18] of Integer;
  lens: array[0..315] of Byte; seq: array[0..316] of Word; cl: array[0..18] of Byte;
  i, nSeq, nl, nd, total, nb: Integer; l: Integer;
begin
  FillChar(lf, SizeOf(lf), 0); FillChar(df, SizeOf(df), 0);
  for i := b.firstToken to b.firstToken + b.nTokens - 1 do begin
    l := z.tokLen[i];
    if l = 0 then Inc(lf[z.tokVal[i]])
    else begin Inc(lf[LenSymT[l]]); Inc(df[DistSymT[z.tokVal[i]]]); end;
  end;
  lf[256] := 1;
  FillChar(b.litLen, SizeOf(b.litLen), 0); FillChar(b.distLen, SizeOf(b.distLen), 0);
  LensMiniz(lf, 288, 15, b.litLen);
  LensMiniz(df, 32, 15, b.distLen);
  nl := 286; while (nl > 257) and (b.litLen[nl - 1] = 0) do Dec(nl);
  nd := 30; while (nd > 1) and (b.distLen[nd - 1] = 0) do Dec(nd);
  for i := 0 to nl - 1 do lens[i] := b.litLen[i];
  for i := 0 to nd - 1 do lens[nl + i] := b.distLen[i];
  total := nl + nd;
  SeqMiniz(lens, total, seq, nSeq);
  FillChar(sf, SizeOf(sf), 0);
  for i := 0 to nSeq - 1 do Inc(sf[seq[i] and $1F]);
  FillChar(cl, SizeOf(cl), 0);
  LensMiniz(sf, 19, 7, cl);
  nb := 18; while (nb >= 0) and (cl[ORD_[nb]] = 0) do Dec(nb);
  Inc(nb); if nb < 4 then nb := 4;
  b.btype := btDynamic;
  b.hlit := nl; b.hdist := nd; b.hclen := nb;
  for i := 0 to 18 do b.clen[i] := cl[i];
  SetLength(b.clenSeq, nSeq);
  for i := 0 to nSeq - 1 do b.clenSeq[i] := seq[i];
  Result := 3 + 5 + 5 + 4 + 3 * nb;
  for i := 0 to nSeq - 1 do Inc(Result, cl[seq[i] and $1F] + CLX[seq[i] and $1F]);
  Inc(Result, SymBits(z, b.firstToken, b.nTokens, b.litLen, b.distLen));
end;

function StaticBits(const z: TZStream; const b: TDeflateBlock): Int64;
var dl: array[0..31] of Byte;
begin
  FillChar(dl, SizeOf(dl), 5);
  Result := 3 + SymBits(z, b.firstToken, b.nTokens, FixedLitT, dl);
end;

type
  { what a run of the parse needs, kept from one candidate to the next (the
    search runs many on the same bytes): the tokens and blocks, the ring,
    hash heads and links (C's), the ref's blocks }
  TMzWork = record
    tokLen, tokVal: array of Word;
    blocks: array of TMzBlock;
    dict: array of Byte;
    hash, next: array of Word;
    ref: PZStream;
    refFirst, refCount, refPos, refLen: array of SizeInt;
    dummyTok: array[0..0] of Word;
  end;

function MzRun(const plain: TBytes; const p: TMinizParams; ref: PZStream; hdr: Boolean; var w: TMzWork;
  out e: TZStream): Boolean;
var
  s: TMzParse;
  t: TZStream;
  n, i, k, nb, outTok: SizeInt;
  bitPos, bits, startByte, b0: Int64;
  stored: Boolean;
  bl: TDeflateBlock;
begin
  e := Default(TZStream);
  e.raw := True;
  Result := False;
  if not MinizValid(p) then Exit;
  n := Length(plain);
  if Length(w.tokLen) < n + 1 then begin
    w.tokLen := nil; w.tokVal := nil;
    SetLength(w.tokLen, n + 1); SetLength(w.tokVal, n + 1);
  end;
  if Length(w.blocks) < n div 16384 + 4 then SetLength(w.blocks, n div 16384 + 4);
  s := Default(TMzParse);
  if n > 0 then s.plain := @plain[0];
  s.n := n;
  s.flags := p.flags;
  s.fast := Ord((p.variant = MZV_FAST) and ((p.flags and MZ_PROBES_MASK) = 1) and ((p.flags and MZ_GREEDY) <> 0) and
    ((p.flags and (MZ_FILTER or MZ_RAW or MZ_RLE)) = 0));
  s.tokLen := @w.tokLen[0]; s.tokVal := @w.tokVal[0];
  s.blocks := @w.blocks[0]; s.maxBlocks := Length(w.blocks);
  if ref <> nil then begin
    nb := Length(ref^.blocks);
    if w.ref <> ref then begin
      w.refFirst := nil; w.refCount := nil; w.refPos := nil; w.refLen := nil;
      SetLength(w.refFirst, nb + 1); SetLength(w.refCount, nb + 1); SetLength(w.refPos, nb + 1); SetLength(w.refLen, nb + 1);
      for i := 0 to nb - 1 do
        with ref^.blocks[i] do
          if btype = btStored then begin
            w.refFirst[i] := -1; w.refCount[i] := 0; w.refPos[i] := plainPos; w.refLen[i] := storedLen;
          end else begin
            w.refFirst[i] := firstToken; w.refCount[i] := nTokens; w.refPos[i] := 0; w.refLen[i] := 0;
          end;
      w.ref := ref;
    end;
    s.refFirst := @w.refFirst[0]; s.refCount := @w.refCount[0]; s.refPos := @w.refPos[0]; s.refLen := @w.refLen[0];
    s.refBlocks := nb;
    if Length(ref^.tokLen) > 0 then begin
      s.refTokLen := @ref^.tokLen[0]; s.refTokVal := @ref^.tokVal[0];
    end else begin
      w.dummyTok[0] := 0; s.refTokLen := @w.dummyTok[0]; s.refTokVal := @w.dummyTok[0];
    end;
    s.useRef := 1;
  end;
  if UseMinizC then begin
    if Length(w.dict) = 0 then begin
      SetLength(w.dict, DICT_SIZE + MAX_MATCH - 1); SetLength(w.hash, HASH_SIZE); SetLength(w.next, DICT_SIZE);
    end;
    FillChar(w.dict[0], Length(w.dict), 0);
    FillChar(w.hash[0], 2 * Length(w.hash), 0);
    FillChar(w.next[0], 2 * Length(w.next), 0);
    s.dict := @w.dict[0]; s.hash := @w.hash[0]; s.next := @w.next[0];
    if ppamz_parse(s) = 0 then Exit;
  end else if not ParsePas(s) then Exit;
  { the blocks: each block's tokens kept in place unless it is stored (t:
    the tokens as the work holds them, for the bits of each block) }
  t := Default(TZStream);
  t.tokLen := w.tokLen; t.tokVal := w.tokVal;
  SetLength(e.blocks, s.nBlocks);
  bitPos := 0; outTok := 0;
  for i := 0 to s.nBlocks - 1 do begin
    bl := Default(TDeflateBlock);
    bl.final := w.blocks[i].final <> 0;
    { its tokens moved down over the stored blocks' before it }
    if outTok <> w.blocks[i].firstTok then
      for k := 0 to w.blocks[i].nTok - 1 do begin
        w.tokLen[outTok + k] := w.tokLen[w.blocks[i].firstTok + k];
        w.tokVal[outTok + k] := w.tokVal[w.blocks[i].firstTok + k];
      end;
    bl.firstToken := outTok; bl.nTokens := w.blocks[i].nTok;
    bl.plainPos := w.blocks[i].dictPos;
    stored := ((p.flags and MZ_RAW) <> 0) and (w.blocks[i].rawOk <> 0);
    if not stored then begin
      { the bytes miniz's output buffer holds when the block is written:
        the zlib header (first block), the bits left from the block before
        and the block's }
      if hdr and (i = 0) then startByte := 2 else startByte := 0;
      b0 := bitPos and 7;
      if ((p.flags and MZ_STATIC) <> 0) or (w.blocks[i].total < 48) then begin
        bl.btype := btFixed; bits := StaticBits(t, bl);
      end else
        bits := Dynamic(t, bl);
      { no smaller than its bytes (from after the final bit), and they are all in the window: stored }
      if (w.blocks[i].total > 0) and ((b0 + bits) div 8 - (b0 + 1) div 8 + 1 >= w.blocks[i].total) and
         (w.blocks[i].rawOk <> 0) then stored := True
      else if startByte + (b0 + bits) div 8 >= OUT_BUF_SIZE - 16 then begin
        { the coded block overflows the output buffer: static codes }
        bl.btype := btFixed; SetLength(bl.clenSeq, 0);
        bits := StaticBits(t, bl);
        if startByte + (b0 + bits) div 8 >= OUT_BUF_SIZE - 16 then Exit;
      end;
    end;
    if stored then begin
      bl.btype := btStored; bl.nTokens := 0; SetLength(bl.clenSeq, 0);
      bl.storedLen := w.blocks[i].total; bl.pad := 0;
      bits := ((bitPos + 3 + 7) and not Int64(7)) - bitPos + 32 + 8 * Int64(bl.storedLen);
    end else Inc(outTok, bl.nTokens);
    if ref <> nil then
      if (i >= Length(ref^.blocks)) or (ref^.blocks[i].btype <> bl.btype) then Exit;
    e.blocks[i] := bl;
    Inc(bitPos, bits);
  end;
  e.plain := plain;
  e.tokLen := Copy(w.tokLen, 0, outTok);
  e.tokVal := Copy(w.tokVal, 0, outTok);
  Result := True;
end;

function MinizChoices(const plain: TBytes; const p: TMinizParams; ref: PZStream; hdr: Boolean;
  out e: TZStream): Boolean;
var w: TMzWork;
begin
  w := Default(TMzWork);
  Result := MzRun(plain, p, ref, hdr, w, e);
end;

{ ---------------------------------------------------------------- the search }

function FindMinizParams(const z: TZStream; out p: TMinizParams; out choices: TZStream): Boolean;
const ORDER: array[0..9] of Integer = (6, 9, 10, 1, 2, 3, 4, 5, 7, 8);
var cand: array of TMinizParams; nc: Integer;
  hasShort, hasNotRle, hasMatch, anyDynamic, allStored: Boolean;
  i, k, lv: SizeInt; l, d: Integer; pr: LongWord; w: TMzWork;

  procedure Add(flags: LongWord; variant: Integer);
  var j: Integer;
  begin
    for j := 0 to nc - 1 do
      if (cand[j].flags = flags) and (cand[j].variant = variant) then Exit;
    if nc = Length(cand) then SetLength(cand, 2 * nc + 16);
    cand[nc].flags := flags; cand[nc].variant := variant;
    Inc(nc);
  end;

  { the levels' probes, greedy as the level makes it first, with extra flags }
  procedure Levels(extra: LongWord);
  var j: Integer; g: LongWord;
  begin
    for j := 0 to High(ORDER) do begin
      lv := ORDER[j];
      pr := NUM_PROBES[lv];
      if lv <= 3 then g := MZ_GREEDY else g := 0;
      if (pr = 1) and (g <> 0) then Add(pr or g or extra, MZV_FAST);
      Add(pr or g or extra, 0);
      if (pr = 1) and (g = 0) then Add(pr or MZ_GREEDY or extra, MZV_FAST);
      Add(pr or (g xor MZ_GREEDY) or extra, 0);
    end;
  end;

begin
  Result := False;
  p := Default(TMinizParams);
  choices := Default(TZStream);
  hasShort := False; hasNotRle := False; hasMatch := False; anyDynamic := False; allStored := True;
  for i := 0 to High(z.blocks) do
    with z.blocks[i] do begin
      if btype <> btStored then allStored := False;
      if btype = btDynamic then anyDynamic := True;
      for k := firstToken to firstToken + nTokens - 1 do begin
        l := z.tokLen[k];
        if l = 0 then Continue;
        { miniz writes 258 as 285 and never keeps 3 bytes from 8 KB or further }
        if (l > 258) then Exit;
        d := z.tokVal[k];
        if (l = 3) and (d >= 8 * 1024) then Exit;
        hasMatch := True;
        if l <= 5 then hasShort := True;
        if d <> 1 then hasNotRle := True;
      end;
    end;
  nc := 0; cand := nil;
  if allStored then Add(MZ_RAW, 0);
  Levels(0);
  if not hasShort then Levels(MZ_FILTER);
  { (static codes: no dynamic block, but blocks no smaller stored) }
  if not anyDynamic then Levels(MZ_STATIC);
  if not hasNotRle then Add(MZ_RLE, 0);
  if not hasMatch then begin Add(0, 0); Add(MZ_RAW, 0); end;
  w := Default(TMzWork);
  for i := 0 to nc - 1 do
    if MzRun(z.plain, cand[i], @z, not z.raw, w, choices) then begin
      p := cand[i];
      Exit(True);
    end;
  choices := Default(TZStream);
end;

initialization
  MakeTables;
  UseMinizC := GetEnvironmentVariable('PPA_NOC') <> '1';
end.
