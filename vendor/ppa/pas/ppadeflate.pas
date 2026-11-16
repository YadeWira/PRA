{ Codec layer 2a: a zlib stream (or a bare deflate stream, as an iPhone's
  CgBI PNG has) split into the bytes it holds and every choice its encoder
  made, and back to the SAME bits.

  The choices deflate leaves to an encoder (RFC 1950, RFC 1951):
    - where each block starts and ends, whether it is the last one, and its
      type: stored, fixed Huffman codes or dynamic ones;
    - a dynamic block's code lengths, and how they are written: HLIT, HDIST,
      HCLEN, the code-length code, and the run-length symbols (16, 17, 18)
      that write the lengths;
    - the tokens: each literal and each match (length, distance), and for a
      match of 258 whether it is symbol 285 or 284 with all its extra bits
      set (both decode to 258);
    - the bits skipped before a stored block's LEN and after the last block,
      which should be zero and are not always;
    - the zlib header, whether the Adler-32 after the data is the right one,
      and whatever follows it.
  All of that is recorded here, so Encode gives back the stream bit for bit.
  Predicting those choices from the bytes alone, so that only where the
  prediction fails has to be stored, is layer 2b's job.

  This is the Pascal reference version: it decodes Huffman codes one bit at
  a time (as zlib's puff.c does). The fast version is measured against it. }
unit ppadeflate;

{$I ppa.inc}
{$ifopt R-}{$fatal ppadeflate: range checks ($R+) are mandatory}{$endif}
{$ifopt Q-}{$fatal ppadeflate: overflow checks ($Q+) are mandatory}{$endif}

interface

uses SysUtils;

const
  { tokLen of a match of 258 written as symbol 284 with extra bits 31 }
  LEN_258_AS_284 = 259;

type
  TZError = (
    zeNone,
    zeTruncated,    { the data ends before the last block does }
    zeBadBlock,     { block type 3, a stored LEN that is not ~NLEN }
    zeBadHeader,    { a dynamic block's code lengths do not make codes }
    zeBadCode,      { a code that is not in the table, symbols 286-287, 30-31 }
    zeBadDistance,  { further back than the bytes decoded so far }
    zeTooLarge,     { more bytes than the caller allows }
    { decoded, but does not give back the same bits }
    zeNoRoundTrip);

  TZResult = record
    err: TZError;
    pos: Int64;     { byte of the stream where it was detected }
    function Ok: Boolean;
    function Text: string;
  end;

  TBlockType = (btStored, btFixed, btDynamic);

  TDeflateBlock = record
    final: Boolean;
    btype: TBlockType;
    { the tokens of this block: tokLen/tokVal[firstToken..firstToken+nTokens-1] }
    firstToken, nTokens: SizeInt;
    { stored: the bits skipped up to the byte boundary before LEN, and LEN;
      its bytes are the plain bytes at plainPos }
    pad: Byte;
    plainPos, storedLen: SizeInt;
    { dynamic: what its header says }
    hlit, hdist, hclen: Integer;
    clen: array[0..18] of Byte;    { code-length code lengths, by symbol }
    { the code-length symbols as written: symbol or (extra shl 5) }
    clenSeq: array of Word;
    { the code lengths they give: literal/length, distance }
    litLen: array[0..287] of Byte;
    distLen: array[0..31] of Byte;
  end;

  TZStream = record
    raw: Boolean;                    { no zlib header nor Adler-32: bare deflate }
    header: array[0..1] of Byte;     { CMF, FLG }
    blocks: array of TDeflateBlock;
    { the tokens: tokLen 0 = the literal tokVal; 3..258 a match of that
      length at distance tokVal; LEN_258_AS_284 a match of 258 written so }
    tokLen, tokVal: array of Word;
    plain: TBytes;                   { the bytes the stream holds }
    endPad: Byte;                    { the bits after the last block }
    adlerOk: Boolean;                { the 4 bytes after the data are its Adler-32 }
    tail: TBytes;                    { what follows (the Adler-32 when not adlerOk) }
  end;
  PZStream = ^TZStream;

{ Whether the 2 bytes at a[0..1] are a zlib header deflate can follow. }
function IsZlibHeader(const a: TBytes): Boolean;

{ The stream a -> z. raw: a bare deflate stream, no zlib header. maxPlain
  caps the bytes it may hold. Never raises on any input. }
function Decode(const a: TBytes; raw: Boolean; maxPlain: SizeInt; out z: TZStream): TZResult;
{ z -> the stream }
function Encode(const z: TZStream): TBytes;

type
  { Encode one block at a time, for a caller that makes the blocks one by
    one and need not keep them all (the same bits as Encode: Encode is
    WriterBegin, WriterBlock for each block, WriterFinish) }
  TDeflWriter = record
    out_: TBytes;
    n: SizeInt;         { bytes written }
    buf: QWord;
    cnt: Integer;
  end;

{ the zlib header, unless z.raw }
procedure WriterBegin(var w: TDeflWriter; const z: TZStream);
{ block b, its tokens z.tokLen/tokVal[b.firstToken..], a stored block's
  bytes z.plain[b.plainPos..] }
procedure WriterBlock(var w: TDeflWriter; const z: TZStream; const b: TDeflateBlock);
{ how many pad bits a stored block written now has before its LEN (what
  its pad must fit in), and the bits after the last block if it ended now }
function WriterStoredPadBits(const w: TDeflWriter): Integer;
function WriterEndPadBits(const w: TDeflWriter): Integer;
{ z.endPad, the Adler-32 of z.plain if z.adlerOk, z.tail: the stream }
function WriterFinish(var w: TDeflWriter; const z: TZStream): TBytes;
{ Decode, Encode, and compare. }
function VerifyRoundTrip(const a: TBytes; raw: Boolean; maxPlain: SizeInt; out z: TZStream): TZResult;

var
  { a block's tokens written in C (ppadeflatec.c); False: in Pascal, the
    reference. PPA_NOC=1 in the environment makes it False }
  UseDeflateC: Boolean = True;

implementation


uses ppacrc;

{$L ppadeflatec.o}

type
  { ppadeflatec.c's ppad_tokens_t }
  TTokensArgs = record
    out_: PByte; n: PSizeInt; buf: PQWord; cnt: PInteger;
    tokLen, tokVal: PWord; first, count: SizeInt;
    lcode: PWord; llen: PByte;
    dcode: PWord; dlen: PByte;
    lenSym: PWord; distSym: PByte;
    lenBase: PWord; lenExtra: PByte;
    distBase: PWord; distExtra: PByte;
  end;

procedure ppad_tokens(var a: TTokensArgs); cdecl; external name 'ppad_tokens';

const
  LEN_BASE: array[257..285] of Word = (
    3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
    35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258);
  LEN_EXTRA: array[257..285] of Byte = (
    0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
    3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0);
  DIST_BASE: array[0..29] of Word = (
    1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
    257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145,
    8193, 12289, 16385, 24577);
  DIST_EXTRA: array[0..29] of Byte = (
    0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
    7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13);
  { the order the code-length code lengths are written in }
  CLEN_ORDER: array[0..18] of Byte = (
    16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15);
  CLEN_EXTRA: array[16..18] of Byte = (2, 3, 7);

var
  LenSym: array[3..258] of Word;     { the symbol of each length (258: 285) }
  DistSym: array[1..32768] of Byte;  { the symbol of each distance }
  FixedLit: array[0..287] of Byte;
  FixedDist: array[0..31] of Byte;

{ ---------------------------------------------------------------- results }

function TZResult.Ok: Boolean;
begin
  Result := err = zeNone;
end;

function TZResult.Text: string;
const NAMES: array[TZError] of string = ('None', 'Truncated', 'BadBlock', 'BadHeader',
  'BadCode', 'BadDistance', 'TooLarge', 'NoRoundTrip');
begin
  Result := NAMES[err] + '@' + IntToStr(pos);
end;

function IsZlibHeader(const a: TBytes): Boolean;
begin
  Result := (Length(a) >= 2) and ((a[0] and $0F) = 8) and ((a[0] shr 4) <= 7) and
            ((a[1] and $20) = 0) and (((LongWord(a[0]) shl 8) or a[1]) mod 31 = 0);
end;

{ ---------------------------------------------------------------- Huffman }

type
  { canonical code for decoding, as puff.c: how many codes of each length,
    and the symbols ordered by code }
  THuffDec = record
    count: array[0..15] of Integer;
    symbol: array[0..287] of Word;
  end;

{ False if the lengths are over-subscribed. An incomplete code is accepted:
  a code it lacks is caught when it is read. }
function BuildDec(out h: THuffDec; const lens: array of Byte; n: Integer): Boolean;
var offs: array[0..15] of Integer; i, left: Integer;
begin
  FillChar(h, SizeOf(h), 0);
  for i := 0 to n - 1 do Inc(h.count[lens[i]]);
  left := 1;
  for i := 1 to 15 do begin
    left := left * 2 - h.count[i];
    if left < 0 then Exit(False);
  end;
  offs[1] := 0;
  for i := 1 to 14 do offs[i + 1] := offs[i] + h.count[i];
  for i := 0 to n - 1 do
    if lens[i] <> 0 then begin
      h.symbol[offs[lens[i]]] := i;
      Inc(offs[lens[i]]);
    end;
  Result := True;
end;

type
  { canonical code for encoding: each symbol's code, bit-reversed so that it
    is written least significant bit first }
  THuffEnc = record
    code: array[0..287] of Word;
    len: array[0..287] of Byte;
  end;

procedure BuildEnc(out h: THuffEnc; const lens: array of Byte; n: Integer);
var count, next: array[0..16] of Integer; i, b, c, r: Integer;
begin
  FillChar(h, SizeOf(h), 0);
  FillChar(count, SizeOf(count), 0);
  for i := 0 to n - 1 do Inc(count[lens[i]]);
  count[0] := 0;
  c := 0;
  for b := 1 to 15 do begin
    c := (c + count[b - 1]) shl 1;
    next[b] := c;
  end;
  for i := 0 to n - 1 do begin
    h.len[i] := lens[i];
    if lens[i] = 0 then Continue;
    c := next[lens[i]] and $FFFF;
    Inc(next[lens[i]]);
    r := 0;
    for b := 1 to lens[i] do begin
      r := (r shl 1) or (c and 1);
      c := c shr 1;
    end;
    h.code[i] := r;
  end;
end;

{ ---------------------------------------------------------------- decoding }

type
  TBitReader = record
    pos: SizeInt;       { next byte to load }
    buf: LongWord;      { bits loaded, the next one lowest }
    cnt: Integer;       { how many }
    eof: Boolean;       { a bit was asked for past the end }
  end;

function GetBits(const a: TBytes; var br: TBitReader; n: Integer): LongWord;
begin
  while br.cnt < n do begin
    if br.pos >= Length(a) then begin br.eof := True; Exit(0); end;
    br.buf := br.buf or (LongWord(a[br.pos]) shl br.cnt);
    Inc(br.pos); Inc(br.cnt, 8);
  end;
  Result := br.buf and ((LongWord(1) shl n) - 1);
  br.buf := br.buf shr n;
  Dec(br.cnt, n);
end;

{ -1: no such code, or the end of the data }
function DecodeSym(const a: TBytes; var br: TBitReader; const h: THuffDec): Integer;
var code, first, index, count, len: Integer;
begin
  code := 0; first := 0; index := 0;
  for len := 1 to 15 do begin
    code := code or Integer(GetBits(a, br, 1));
    if br.eof then Exit(-1);
    count := h.count[len];
    if code - count < first then Exit(h.symbol[index + (code - first)]);
    Inc(index, count);
    Inc(first, count);
    first := first shl 1;
    code := code shl 1;
  end;
  Result := -1;
end;

function Decode(const a: TBytes; raw: Boolean; maxPlain: SizeInt; out z: TZStream): TZResult;
var
  br: TBitReader;
  nBlocks, nTok, nPlain, nSeq: SizeInt;
  b: TDeflateBlock;
  litDec, distDec, clenDec: THuffDec;
  lens: array[0..319] of Byte;
  sym, i, n, rep, prev, extra, len, dist: Integer;
  start, k: SizeInt;
  lastBlock: Boolean;

  function Fail(e: TZError): TZResult;
  begin
    Result.err := e; Result.pos := br.pos;
    if br.eof and (e in [zeBadCode, zeBadHeader]) then Result.err := zeTruncated;
  end;

  function Bits(n: Integer): Integer; inline;
  begin
    Result := Integer(GetBits(a, br, n));
  end;

  function NeedPlain(n: SizeInt): Boolean;
  var cap: SizeInt;
  begin
    if nPlain + n > maxPlain then Exit(False);
    cap := Length(z.plain);
    if nPlain + n > cap then begin
      if 2 * cap > nPlain + n then cap := 2 * cap else cap := nPlain + n + 1024;
      if cap > maxPlain then cap := maxPlain;
      SetLength(z.plain, cap);
    end;
    Result := True;
  end;

  procedure AddToken(l, v: Integer);
  begin
    if nTok = Length(z.tokLen) then begin
      SetLength(z.tokLen, 2 * nTok + 1024);
      SetLength(z.tokVal, Length(z.tokLen));
    end;
    z.tokLen[nTok] := l; z.tokVal[nTok] := v;
    Inc(nTok);
  end;

begin
  z.raw := raw; z.blocks := nil; z.tokLen := nil; z.tokVal := nil;
  z.plain := nil; z.tail := nil; z.endPad := 0; z.adlerOk := False;
  z.header[0] := 0; z.header[1] := 0;
  Result.err := zeNone; Result.pos := 0;
  FillChar(br, SizeOf(br), 0);
  nBlocks := 0; nTok := 0; nPlain := 0;

  if not raw then begin
    if not IsZlibHeader(a) then begin Result.err := zeBadBlock; Exit; end;
    z.header[0] := a[0]; z.header[1] := a[1];
    br.pos := 2;
  end;

  repeat
    b := Default(TDeflateBlock);
    b.final := Bits(1) = 1;
    n := Bits(2);
    if br.eof then Exit(Fail(zeTruncated));
    if n = 3 then Exit(Fail(zeBadBlock));
    b.btype := TBlockType(n);
    b.firstToken := nTok;
    lastBlock := b.final;

    case b.btype of
      btStored: begin
        b.pad := Byte(br.buf and ((LongWord(1) shl br.cnt) - 1));
        { what is left in the buffer is a whole number of bytes after this }
        k := br.cnt mod 8;
        b.pad := b.pad and ((1 shl k) - 1);
        GetBits(a, br, k);
        len := Bits(16);
        n := Bits(16);
        if br.eof then Exit(Fail(zeTruncated));
        if len <> (not n and $FFFF) then Exit(Fail(zeBadBlock));
        { the buffer is empty now: 32 bits were read on byte boundaries }
        if br.pos + len > Length(a) then Exit(Fail(zeTruncated));
        if not NeedPlain(len) then Exit(Fail(zeTooLarge));
        b.plainPos := nPlain; b.storedLen := len;
        if len > 0 then Move(a[br.pos], z.plain[nPlain], len);
        Inc(nPlain, len); Inc(br.pos, len);
      end;

      btFixed, btDynamic: begin
        if b.btype = btFixed then begin
          Move(FixedLit, b.litLen, SizeOf(FixedLit));
          Move(FixedDist, b.distLen, SizeOf(FixedDist));
          BuildDec(litDec, b.litLen, 288);
          BuildDec(distDec, b.distLen, 30);
        end else begin
          b.hlit := Bits(5) + 257;
          b.hdist := Bits(5) + 1;
          b.hclen := Bits(4) + 4;
          if br.eof then Exit(Fail(zeTruncated));
          if (b.hlit > 286) or (b.hdist > 30) then Exit(Fail(zeBadHeader));
          for i := 0 to b.hclen - 1 do b.clen[CLEN_ORDER[i]] := Bits(3);
          if br.eof then Exit(Fail(zeTruncated));
          if not BuildDec(clenDec, b.clen, 19) then Exit(Fail(zeBadHeader));
          nSeq := 0;
          SetLength(b.clenSeq, b.hlit + b.hdist);
          i := 0;
          FillChar(lens, SizeOf(lens), 0);
          while i < b.hlit + b.hdist do begin
            sym := DecodeSym(a, br, clenDec);
            if sym < 0 then Exit(Fail(zeBadHeader));
            if sym < 16 then begin
              lens[i] := sym; Inc(i);
              b.clenSeq[nSeq] := sym;
            end else begin
              extra := Bits(CLEN_EXTRA[sym]);
              if br.eof then Exit(Fail(zeTruncated));
              case sym of
                16: begin
                  if i = 0 then Exit(Fail(zeBadHeader));
                  prev := lens[i - 1]; rep := 3 + extra;
                end;
                17: begin prev := 0; rep := 3 + extra; end;
              else begin prev := 0; rep := 11 + extra; end;
              end;
              if i + rep > b.hlit + b.hdist then Exit(Fail(zeBadHeader));
              while rep > 0 do begin lens[i] := prev; Inc(i); Dec(rep); end;
              b.clenSeq[nSeq] := Word(sym or (extra shl 5));
            end;
            Inc(nSeq);
          end;
          SetLength(b.clenSeq, nSeq);
          if lens[256] = 0 then Exit(Fail(zeBadHeader));
          for i := 0 to b.hlit - 1 do b.litLen[i] := lens[i];
          for i := 0 to b.hdist - 1 do b.distLen[i] := lens[b.hlit + i];
          if not BuildDec(litDec, b.litLen, b.hlit) then Exit(Fail(zeBadHeader));
          if not BuildDec(distDec, b.distLen, b.hdist) then Exit(Fail(zeBadHeader));
        end;

        repeat
          sym := DecodeSym(a, br, litDec);
          if sym < 0 then Exit(Fail(zeBadCode));
          if sym < 256 then begin
            if not NeedPlain(1) then Exit(Fail(zeTooLarge));
            z.plain[nPlain] := sym; Inc(nPlain);
            AddToken(0, sym);
          end else if sym > 256 then begin
            if sym > 285 then Exit(Fail(zeBadCode));
            extra := Bits(LEN_EXTRA[sym]);
            len := LEN_BASE[sym] + extra;
            n := len;
            if (sym = 284) and (extra = 31) then n := LEN_258_AS_284;
            sym := DecodeSym(a, br, distDec);
            if (sym < 0) or (sym > 29) then Exit(Fail(zeBadCode));
            dist := DIST_BASE[sym] + Bits(DIST_EXTRA[sym]);
            if br.eof then Exit(Fail(zeTruncated));
            if dist > nPlain then Exit(Fail(zeBadDistance));
            if not NeedPlain(len) then Exit(Fail(zeTooLarge));
            start := nPlain - dist;
            for k := 0 to len - 1 do z.plain[nPlain + k] := z.plain[start + k];
            Inc(nPlain, len);
            AddToken(n, dist);
          end;
        until sym = 256;
      end;
    end;

    b.nTokens := nTok - b.firstToken;
    if nBlocks = Length(z.blocks) then SetLength(z.blocks, 2 * nBlocks + 8);
    z.blocks[nBlocks] := b;
    Inc(nBlocks);
  until lastBlock;

  { the bits left up to the byte boundary }
  k := br.cnt mod 8;
  z.endPad := Byte(GetBits(a, br, k));
  { whole bytes may be left in the buffer: they belong to what follows }
  br.pos := br.pos - br.cnt div 8;

  SetLength(z.blocks, nBlocks);
  SetLength(z.tokLen, nTok);
  SetLength(z.tokVal, nTok);
  SetLength(z.plain, nPlain);
  k := 0;
  if not raw and (Length(a) - br.pos >= 4) and
     (((LongWord(a[br.pos]) shl 24) or (LongWord(a[br.pos + 1]) shl 16) or
       (LongWord(a[br.pos + 2]) shl 8) or a[br.pos + 3]) = Adler32(1, z.plain, 0, nPlain)) then begin
    z.adlerOk := True; k := 4;
  end;
  SetLength(z.tail, Length(a) - br.pos - k);
  if Length(z.tail) > 0 then Move(a[br.pos + k], z.tail[0], Length(z.tail));
end;

{ ---------------------------------------------------------------- encoding }

type
  TBitWriter = TDeflWriter;

{ v's n low bits (n <= 24): kept in buf, written four bytes at a time }
procedure PutBits(var bw: TBitWriter; v: LongWord; n: Integer); inline;
var p: PByte;
begin
  bw.buf := bw.buf or (QWord(v) shl bw.cnt);
  Inc(bw.cnt, n);
  if bw.cnt >= 32 then begin
    if bw.n + 4 > Length(bw.out_) then SetLength(bw.out_, 2 * bw.n + 4096);
    p := @bw.out_[bw.n];
    {$push}{$R-}
    p[0] := Byte(bw.buf); p[1] := Byte(bw.buf shr 8); p[2] := Byte(bw.buf shr 16); p[3] := Byte(bw.buf shr 24);
    {$pop}
    Inc(bw.n, 4);
    bw.buf := bw.buf shr 32;
    Dec(bw.cnt, 32);
  end;
end;

{ the whole bytes in buf, written (the rest stays: fewer than 8 bits) }
procedure FlushBytes(var bw: TBitWriter);
begin
  while bw.cnt >= 8 do begin
    if bw.n = Length(bw.out_) then SetLength(bw.out_, 2 * bw.n + 4096);
    bw.out_[bw.n] := Byte(bw.buf);
    Inc(bw.n);
    bw.buf := bw.buf shr 8;
    Dec(bw.cnt, 8);
  end;
end;

procedure PutBytes(var bw: TBitWriter; const a: TBytes; first, len: SizeInt);
begin
  FlushBytes(bw);
  if len <= 0 then Exit;
  if bw.n + len > Length(bw.out_) then SetLength(bw.out_, 2 * (bw.n + len));
  Move(a[first], bw.out_[bw.n], len);
  Inc(bw.n, len);
end;

procedure WriterBegin(var w: TDeflWriter; const z: TZStream);
begin
  w := Default(TDeflWriter);
  if not z.raw then begin
    PutBits(w, z.header[0], 8);
    PutBits(w, z.header[1], 8);
  end;
end;

function WriterStoredPadBits(const w: TDeflWriter): Integer;
begin
  Result := (8 - (w.cnt + 3) mod 8) mod 8;
end;

function WriterEndPadBits(const w: TDeflWriter): Integer;
begin
  Result := (8 - w.cnt mod 8) mod 8;
end;

procedure WriterBlock(var w: TDeflWriter; const z: TZStream; const b: TDeflateBlock);
var
  lit, dst, cl: THuffEnc;
  i: SizeInt;
  sym, s, l, d, k: Integer;
  ta: TTokensArgs;
  cs: Word;
begin
  with b do begin
    PutBits(w, Ord(final), 1);
    PutBits(w, Ord(btype), 2);
    case btype of
      btStored: begin
        k := (8 - w.cnt mod 8) mod 8;
        PutBits(w, pad, k);
        PutBits(w, storedLen, 16);
        PutBits(w, not storedLen and $FFFF, 16);
        PutBytes(w, z.plain, plainPos, storedLen);
      end;
      btFixed, btDynamic: begin
        if btype = btDynamic then begin
          PutBits(w, hlit - 257, 5);
          PutBits(w, hdist - 1, 5);
          PutBits(w, hclen - 4, 4);
          for i := 0 to hclen - 1 do PutBits(w, clen[CLEN_ORDER[i]], 3);
          BuildEnc(cl, clen, 19);
          for i := 0 to High(clenSeq) do begin
            { the element into a Word first: `clenSeq[i] and $1F` loads 4
              bytes on x86 and x86-64, 2 past the last element (a fault where the
              block ends with its memory: Windows XP's heap) }
            cs := clenSeq[i];
            s := cs and $1F;
            PutBits(w, cl.code[s], cl.len[s]);
            if s >= 16 then PutBits(w, cs shr 5, CLEN_EXTRA[s]);
          end;
        end;
        if btype = btFixed then begin
          BuildEnc(lit, FixedLit, 288);
          BuildEnc(dst, FixedDist, 32);
        end else begin
          BuildEnc(lit, litLen, 288);
          BuildEnc(dst, distLen, 32);
        end;
        if UseDeflateC and (nTokens > 0) then begin
          { room for the worst: 48 bits a token }
          if w.n + 6 * nTokens + 16 > Length(w.out_) then SetLength(w.out_, 2 * (w.n + 6 * nTokens + 16));
          ta.out_ := @w.out_[0]; ta.n := @w.n; ta.buf := @w.buf; ta.cnt := @w.cnt;
          ta.tokLen := @z.tokLen[0]; ta.tokVal := @z.tokVal[0]; ta.first := firstToken; ta.count := nTokens;
          ta.lcode := @lit.code[0]; ta.llen := @lit.len[0]; ta.dcode := @dst.code[0]; ta.dlen := @dst.len[0];
          ta.lenSym := @LenSym[3]; ta.distSym := @DistSym[1];
          ta.lenBase := @LEN_BASE[257]; ta.lenExtra := @LEN_EXTRA[257];
          ta.distBase := @DIST_BASE[0]; ta.distExtra := @DIST_EXTRA[0];
          ppad_tokens(ta);
        end else
        for i := firstToken to firstToken + nTokens - 1 do begin
          l := z.tokLen[i];
          if l = 0 then begin
            sym := z.tokVal[i];
            PutBits(w, lit.code[sym], lit.len[sym]);
          end else begin
            if l = LEN_258_AS_284 then begin
              PutBits(w, lit.code[284], lit.len[284]);
              PutBits(w, 31, 5);
            end else begin
              sym := LenSym[l];
              PutBits(w, lit.code[sym], lit.len[sym]);
              PutBits(w, l - LEN_BASE[sym], LEN_EXTRA[sym]);
            end;
            d := z.tokVal[i];
            sym := DistSym[d];
            PutBits(w, dst.code[sym], dst.len[sym]);
            PutBits(w, d - DIST_BASE[sym], DIST_EXTRA[sym]);
          end;
        end;
        PutBits(w, lit.code[256], lit.len[256]);
      end;
    end;
  end;
end;

function WriterFinish(var w: TDeflWriter; const z: TZStream): TBytes;
var k: Integer; ad: LongWord;
begin
  k := (8 - w.cnt mod 8) mod 8;
  PutBits(w, z.endPad, k);
  if z.adlerOk then begin
    ad := Adler32(1, z.plain, 0, Length(z.plain));
    PutBits(w, ad shr 24, 8); PutBits(w, (ad shr 16) and $FF, 8);
    PutBits(w, (ad shr 8) and $FF, 8); PutBits(w, ad and $FF, 8);
  end;
  PutBytes(w, z.tail, 0, Length(z.tail));
  FlushBytes(w);
  SetLength(w.out_, w.n);
  Result := w.out_;
  w.out_ := nil;
end;

function Encode(const z: TZStream): TBytes;
var w: TDeflWriter; bi: SizeInt;
begin
  WriterBegin(w, z);
  for bi := 0 to High(z.blocks) do WriterBlock(w, z, z.blocks[bi]);
  Result := WriterFinish(w, z);
end;

function VerifyRoundTrip(const a: TBytes; raw: Boolean; maxPlain: SizeInt; out z: TZStream): TZResult;
var r: TBytes; i: SizeInt;
begin
  Result := Decode(a, raw, maxPlain, z);
  if not Result.Ok then Exit;
  r := Encode(z);
  if Length(r) <> Length(a) then begin
    Result.err := zeNoRoundTrip;
    if Length(r) < Length(a) then Result.pos := Length(r) else Result.pos := Length(a);
    Exit;
  end;
  for i := 0 to High(a) do
    if r[i] <> a[i] then begin Result.err := zeNoRoundTrip; Result.pos := i; Exit; end;
end;

{ ---------------------------------------------------------------- tables }

procedure MakeTables;
var s, l, i: Integer;
begin
  for s := 257 to 284 do
    for l := LEN_BASE[s] to LEN_BASE[s] + (1 shl LEN_EXTRA[s]) - 1 do
      if l <= 258 then LenSym[l] := s;
  LenSym[258] := 285;
  for s := 0 to 29 do
    for i := DIST_BASE[s] to DIST_BASE[s] + (1 shl DIST_EXTRA[s]) - 1 do
      DistSym[i] := s;
  for i := 0 to 143 do FixedLit[i] := 8;
  for i := 144 to 255 do FixedLit[i] := 9;
  for i := 256 to 279 do FixedLit[i] := 7;
  for i := 280 to 287 do FixedLit[i] := 8;
  for i := 0 to 31 do FixedDist[i] := 5;
end;

initialization
  UseDeflateC := GetEnvironmentVariable('PPA_NOC') <> '1';
  MakeTables;
end.
