{ Layer 3: plain (text) PBM, PGM and PPM, given back exactly whoever wrote
  them.

  P1, P2 and P3 hold their samples as decimal numbers in text. The numbers
  are an image like any other (P1: 1 bit, P2 and P3: 8 or 16 bits by
  maxval) and go to the pixel coder; what is left is the writer's way of
  writing them, coded here: the whitespace (and comments) before each
  number, and any zeros it starts with. A separator is coded a symbol at a
  time (space, line feed, carriage return, tab, any other byte, the end),
  in contexts of what a writer decides on: the column and the next number's
  digits (lines are wrapped near 70 columns; netpbm pads numbers to the
  width of maxval), whether a row ends, and what the separator before was.

  P1's digits may follow each other with nothing between them. }
unit praplain;

{$I pra.inc}
{$ifdef PRA_FAST}
  {$R-}{$Q-}
{$else}
  {$ifopt R-}{$fatal praplain: range checks ($R+) are mandatory}{$endif}
  {$ifopt Q-}{$fatal praplain: overflow checks ($Q+) are mandatory}{$endif}
{$endif}

interface

uses SysUtils, praraster;

{ The numbers' text at d[first..]: count numbers (P1, p1: digits 0 and 1;
  else decimal, at most maxv), each after whitespace or comments (P1's
  after nothing too, but the first). used: up to the last digit. }
function PlainLength(const d: TBytes; first: SizeInt; count: Int64; p1: Boolean; maxv: Integer;
                     out used: Int64): TParseStatus;
{ the numbers as the pixels the codec models (L: their raw layout), the
  writing coded (side), and the text's length }
function PlainScan(const d: TBytes; first: SizeInt; const L: TRasterLayout;
                   out raw, side: TBytes; out used: Int64): TParseStatus;
function PlainRebuild(const raw, side: TBytes; const L: TRasterLayout; usedLimit: Int64; out coded: TBytes): Boolean;
{ before anything is allocated: each number takes a byte at least }
function PlainFits(const L: TRasterLayout; available: Int64): Boolean;

implementation

uses Math, praarith, pramodel, prarle;

const
  SY_END = 0;
  SY_SPACE = 1;
  SY_LF = 2;
  SY_CR = 3;
  SY_TAB = 4;
  SY_OTHER = 5;
  SY_NONE = 7;
  CTX_BITS = 16;
  MAX_ZEROS = 15;
  COUNTER_LIMIT = 255;

type
  { a few hashed contexts, no mixing: the writer's choices are nearly
    certain }
  TTextCoder = record
    encoding: Boolean;
    enc: TArithEncoder;
    dec: TArithDecoder;
    c: array of TCounter;
    procedure Init(encode: Boolean; const data: TBytes);
    function Bit(ctx: Cardinal; b: Integer): Integer;
    function Tree(ctx: Cardinal; v, nbits: Integer): Integer;
    { two contexts, their predictions averaged in the logistic domain }
    function Bit2(ca, cb: Cardinal; b: Integer): Integer;
    function Tree2(ca, cb: Cardinal; v, nbits: Integer): Integer;
  end;

procedure TTextCoder.Init(encode: Boolean; const data: TBytes);
var i: Integer;
begin
  encoding := encode;
  c := nil; SetLength(c, 1 shl CTX_BITS);
  for i := 0 to High(c) do CounterInit(c[i]);
  if encode then enc.Init else dec.Init(data, 0);
end;

function TTextCoder.Bit(ctx: Cardinal; b: Integer): Integer;
var p: Integer; k: Cardinal;
begin
  k := ctx and Cardinal((1 shl CTX_BITS) - 1);
  p := c[k].p;
  if p < 32 then p := 32 else if p > 65535 - 32 then p := 65535 - 32;
  if encoding then enc.Encode(b, p) else b := dec.Decode(p);
  CounterUpdate(c[k], b, COUNTER_LIMIT);
  Result := b;
end;

function TTextCoder.Bit2(ca, cb: Cardinal; b: Integer): Integer;
var p: Integer; ka, kb: Cardinal;
begin
  ka := ca and Cardinal((1 shl CTX_BITS) - 1);
  kb := cb and Cardinal((1 shl CTX_BITS) - 1);
  p := Squash(SarLongint(Stretch(c[ka].p shr 4) + Stretch(c[kb].p shr 4), 1)) shl 4;
  if p < 32 then p := 32 else if p > 65535 - 32 then p := 65535 - 32;
  if encoding then enc.Encode(b, p) else b := dec.Decode(p);
  CounterUpdate(c[ka], b, COUNTER_LIMIT);
  CounterUpdate(c[kb], b, COUNTER_LIMIT);
  Result := b;
end;

function TTextCoder.Tree2(ca, cb: Cardinal; v, nbits: Integer): Integer;
var t, j: Integer;
begin
  t := 1;
  for j := nbits - 1 downto 0 do
    t := 2 * t + Bit2(Hash2(ca, Cardinal(t)), Hash2(cb, Cardinal(t)), (v shr j) and 1);
  Result := t - (1 shl nbits);
end;

function TTextCoder.Tree(ctx: Cardinal; v, nbits: Integer): Integer;
var t, j: Integer;
begin
  t := 1;
  for j := nbits - 1 downto 0 do t := 2 * t + Bit(Hash2(ctx, Cardinal(t)), (v shr j) and 1);
  Result := t - (1 shl nbits);
end;

function IsSpace(b: Byte): Boolean; inline;
begin Result := (b = 32) or ((b >= 9) and (b <= 13)); end;

function IsDigit(b: Byte): Boolean; inline;
begin Result := (b >= 48) and (b <= 57); end;

function Digits(v: Integer): Integer;
begin
  Result := 1;
  while v >= 10 do begin v := v div 10; Inc(Result); end;
end;

function SymbolOf(b: Byte): Integer;
begin
  case b of
    32: Result := SY_SPACE;
    10: Result := SY_LF;
    13: Result := SY_CR;
    9: Result := SY_TAB;
  else Result := SY_OTHER;
  end;
end;

{ the separator at d[p]: whitespace and comments (a '#' to the end of its
  line), its end }
function SeparatorEnd(const d: TBytes; p: SizeInt): SizeInt;
begin
  while p < Length(d) do begin
    if IsSpace(d[p]) then Inc(p)
    else if d[p] = Ord('#') then begin
      while (p < Length(d)) and (d[p] <> 10) and (d[p] <> 13) do Inc(p);
    end else Break;
  end;
  Result := p;
end;

{ the number at d[p] (P1: one digit): its value and its digits; False if
  there is none or it is too big }
function ReadValue(const d: TBytes; p: SizeInt; p1: Boolean; maxv: Integer; out v, len: Integer): Boolean;
begin
  v := 0; len := 0;
  if p1 then begin
    if (p >= Length(d)) or not (d[p] in [48, 49]) then Exit(False);
    v := d[p] - 48; len := 1;
    Exit(True);
  end;
  while (p + len < Length(d)) and IsDigit(d[p + len]) do begin
    if v > maxv then Exit(False);
    v := v * 10 + d[p + len] - 48;
    Inc(len);
    if len > 5 + MAX_ZEROS then Exit(False);
  end;
  Result := (len > 0) and (v <= maxv);
end;

function PlainLength(const d: TBytes; first: SizeInt; count: Int64; p1: Boolean; maxv: Integer;
                     out used: Int64): TParseStatus;
var p, e: SizeInt; i: Int64; v, len: Integer;
begin
  used := 0;
  if count < 1 then Exit(psMalformed);
  if count > Length(d) - first then Exit(psTruncated);
  p := first;
  i := 0;
  while i < count do begin
    e := SeparatorEnd(d, p);
    { the first number after whitespace; P2 and P3's numbers apart }
    if (e = p) and ((i = 0) or not p1) then begin
      if e >= Length(d) then Exit(psTruncated);
      Exit(psMalformed);
    end;
    if e >= Length(d) then Exit(psTruncated);
    { no digit at all: not a number; a number too big for the bits: a
      variant PRA leaves }
    if not IsDigit(d[e]) then Exit(psMalformed);
    if not ReadValue(d, e, p1, maxv, v, len) then Exit(psUnsupported);
    { zeros before a number: at most MAX_ZEROS }
    if len - Digits(v) > MAX_ZEROS then Exit(psUnsupported);
    p := e + len;
    Inc(i);
  end;
  used := p - first;
  Result := psOk;
end;

function PlainFits(const L: TRasterLayout; available: Int64): Boolean;
var n, rb: Int64;
begin
  Result := False;
  if (L.width < 1) or (L.height < 1) or not (L.channels in [1, 3]) or not (L.bits in [1, 8, 16]) then Exit;
  if L.width > MAX_RAW div L.height then Exit;
  n := L.width * L.height;
  if n > MAX_RAW div L.channels then Exit;
  n := n * L.channels;
  rb := (L.width * L.channels * L.bits + 7) div 8;
  Result := (n <= available) and (rb * L.height <= MAX_RAW);
end;

function GetSample(const raw: TBytes; const L: TRasterLayout; rb, i: Int64): Integer; inline;
var y, x: Int64;
begin
  case L.bits of
    1: begin
      y := i div L.width; x := i - y * L.width;
      Result := (raw[y * rb + x shr 3] shr (7 - (x and 7))) and 1;
    end;
    8: Result := raw[i];
  else Result := (raw[2 * i] shl 8) or raw[2 * i + 1];
  end;
end;

procedure SetSample(var raw: TBytes; const L: TRasterLayout; rb, i: Int64; v: Integer); inline;
var y, x: Int64;
begin
  case L.bits of
    1: begin
      y := i div L.width; x := i - y * L.width;
      if v <> 0 then raw[y * rb + x shr 3] := raw[y * rb + x shr 3] or (1 shl (7 - (x and 7)));
    end;
    8: raw[i] := v;
  else begin raw[2 * i] := v shr 8; raw[2 * i + 1] := v and 255; end;
  end;
end;

type
  { what the writer has done so far: the contexts }
  TWriter = record
    col: Integer;                       { bytes since the last line feed }
    inLine: Integer;                    { numbers since the last line feed }
    last: array[0..3] of Integer;       { the previous separator's first symbols }
    rowLen: Int64;                      { numbers a row }
    p1, zerosSeen: Integer;
    procedure Init(const L: TRasterLayout);
    procedure Put(b: Byte);
  end;

procedure TWriter.Init(const L: TRasterLayout);
var k: Integer;
begin
  col := 0; inLine := 0;
  for k := 0 to 3 do last[k] := SY_NONE;
  rowLen := L.width * L.channels;
  p1 := Ord(L.bits = 1);
  zerosSeen := 0;
end;

procedure TWriter.Put(b: Byte);
begin
  if b = 10 then begin col := 0; inLine := 0; end else if col < 255 then Inc(col);
end;

{ one separator symbol, both ways: sym, and the byte when it is another }
function CodeSymbol(var tc: TTextCoder; const w: TWriter; i: Int64; k, prev, digitsNext: Integer;
                    sym: Integer; var other: Integer): Integer;
var ctx, ctxN, wrap: Cardinal; rowStart, kk: Integer;
begin
  if k > 3 then kk := 3 else kk := k;
  rowStart := Ord((i mod w.rowLen) = 0);
  { where a line would end with the next number on it }
  wrap := Cardinal(w.col + digitsNext);
  if wrap > 100 then wrap := 100;
  ctx := Hash4(Cardinal(kk + 8 * prev), Cardinal(w.last[kk]), wrap + 128 * Cardinal(digitsNext),
               Cardinal(rowStart + 2 * w.p1 + 4 * Ord(i = 0)));
  { lines of so many numbers (netpbm's) rather than of so many columns }
  ctxN := Hash4(Cardinal(kk + 8 * prev + 64), Cardinal(w.last[kk]), Cardinal(Min(w.inLine, 255)),
                Cardinal(rowStart + 2 * w.p1 + 4 * Ord(i = 0)));
  Result := tc.Tree2(ctx, ctxN, sym, 3);
  if Result = SY_OTHER then other := tc.Tree(Hash2(ctx, 77), other, 8);
end;

{ the zeros before number i, both ways }
function CodeZeros(var tc: TTextCoder; var w: TWriter; digitsNext, zeros: Integer): Integer;
var ctx: Cardinal;
begin
  ctx := Hash3(9, Cardinal(digitsNext), Cardinal(w.zerosSeen));
  if tc.Bit(ctx, Ord(zeros > 0)) = 0 then Exit(0);
  Result := tc.Tree(Hash2(ctx, 1), zeros, 4);
  w.zerosSeen := 1;
end;

function PlainScan(const d: TBytes; first: SizeInt; const L: TRasterLayout;
                   out raw, side: TBytes; out used: Int64): TParseStatus;
var
  p, e, q: SizeInt; i, n, rb: Int64; v, len, maxv, k, prev, sym, other, nd: Integer;
  tc: TTextCoder; w: TWriter; p1: Boolean;
begin
  raw := nil; side := nil;
  p1 := L.bits = 1;
  if p1 then maxv := 1 else maxv := (1 shl L.bits) - 1;
  n := L.width * L.height * L.channels;
  Result := PlainLength(d, first, n, p1, maxv, used);
  if Result <> psOk then Exit;
  if not PlainFits(L, used) then Exit(psUnsupported);
  rb := (L.width * L.channels * L.bits + 7) div 8;
  SetLength(raw, rb * L.height);
  tc.Init(True, nil);
  w.Init(L);
  p := first;
  i := 0;
  while i < n do begin
    e := SeparatorEnd(d, p);
    ReadValue(d, e, p1, maxv, v, len);
    SetSample(raw, L, rb, i, v);
    nd := Digits(v);
    { the separator, a symbol at a time, then its end }
    prev := SY_NONE; k := 0;
    for q := p to e do begin
      if q < e then begin sym := SymbolOf(d[q]); other := d[q]; end else begin sym := SY_END; other := 0; end;
      CodeSymbol(tc, w, i, k, prev, nd, sym, other);
      if k <= 3 then w.last[k] := sym;
      if q < e then w.Put(d[q]);
      prev := sym; Inc(k);
    end;
    for k := k to 3 do w.last[k] := SY_END;
    if not p1 then CodeZeros(tc, w, nd, len - nd);
    for q := e to e + len - 1 do w.Put(d[q]);
    Inc(w.inLine);
    p := e + len;
    Inc(i);
  end;
  side := tc.enc.Finish;
end;

function PlainRebuild(const raw, side: TBytes; const L: TRasterLayout; usedLimit: Int64; out coded: TBytes): Boolean;
var
  o: SizeInt; i, n, rb: Int64; v, k, prev, sym, other, nd, zeros, j: Integer;
  tc: TTextCoder; w: TWriter; p1: Boolean; txt: string;
begin
  coded := nil; Result := False;
  if (usedLimit < 1) or not PlainFits(L, usedLimit) then Exit;
  rb := (L.width * L.channels * L.bits + 7) div 8;
  if Length(raw) <> rb * L.height then Exit;
  p1 := L.bits = 1;
  n := L.width * L.height * L.channels;
  SetLength(coded, usedLimit);
  tc.Init(False, side);
  w.Init(L);
  o := 0;
  i := 0;
  while i < n do begin
    v := GetSample(raw, L, rb, i);
    if p1 and (v > 1) then Exit;
    nd := Digits(v);
    prev := SY_NONE; k := 0;
    repeat
      other := 0;
      sym := CodeSymbol(tc, w, i, k, prev, nd, 0, other);
      if k <= 3 then w.last[k] := sym;
      if sym <> SY_END then begin
        if o >= usedLimit then Exit;
        case sym of
          SY_SPACE: coded[o] := 32;
          SY_LF: coded[o] := 10;
          SY_CR: coded[o] := 13;
          SY_TAB: coded[o] := 9;
          SY_OTHER: coded[o] := other;
        else Exit;                                    { only a damaged side }
        end;
        w.Put(coded[o]); Inc(o);
      end;
      prev := sym; Inc(k);
    until sym = SY_END;
    for k := k to 3 do w.last[k] := SY_END;
    zeros := 0;
    if not p1 then zeros := CodeZeros(tc, w, nd, 0);
    txt := StringOfChar('0', zeros) + IntToStr(v);
    if o + Length(txt) > usedLimit then Exit;
    for j := 1 to Length(txt) do begin coded[o] := Ord(txt[j]); w.Put(coded[o]); Inc(o); end;
    Inc(w.inLine);
    Inc(i);
  end;
  Result := o = usedLimit;
end;

end.
