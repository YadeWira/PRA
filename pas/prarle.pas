{ Layer 3: run-length coded pixels, given back exactly whoever wrote them.

  A run-length coded file is its pixels plus the writer's choices: where
  each packet starts, whether it is a run or a literal, how long it is.
  Given both, the bytes follow. So the pixels go to the pixel coder like any
  others, and the choices (the packets: a run flag and a count each) are
  coded here, small, in contexts of what a usual coder would have done at
  that point (how many equal values follow, how far the row's end is). A
  writer that follows the usual rule costs a fraction of a bit a packet; one
  that does not costs more, and still comes back byte for byte: nothing
  has to be recognised.

  TGA (image types 9, 10, 11): a packet is a byte, its top bit set for a
  run, its low 7 bits the count less one, then one pixel (a run) or count
  pixels (a literal). Packets may cross rows. }
unit prarle;

{$I pra.inc}
{$ifdef PRA_FAST}
  {$R-}{$Q-}
{$else}
  {$ifopt R-}{$fatal prarle: range checks ($R+) are mandatory}{$endif}
  {$ifopt Q-}{$fatal prarle: overflow checks ($Q+) are mandatory}{$endif}
{$endif}

interface

uses SysUtils, praraster;

const
  { the largest image a coded file may expand to, in pixel bytes }
  MAX_RAW = Int64(1) shl 31;

{ TGA's run-length pixels at d[L.dataOffset..]: the raw pixels (W x H x ps
  bytes, as the uncompressed type would hold them), the packets coded
  (side), and how many bytes the packets took (used). }
function TgaRleScan(const d: TBytes; const L: TRasterLayout; ps: Integer;
                    out raw, side: TBytes; out used: Int64): TParseStatus;

{ The packets' length, walking them (the parser): psTruncated, psMalformed
  (a packet past the image). }
function TgaRleLength(const d: TBytes; first: SizeInt; w, h: Int64; ps: Integer; out used: Int64): TParseStatus;

{ The packets again, from the raw pixels and side; False on a damaged side. }
function TgaRleRebuild(const raw, side: TBytes; const L: TRasterLayout; ps: Integer;
                       usedLimit: Int64; out coded: TBytes): Boolean;

{ Whether W x H pixels of ps bytes can be in `available` bytes of packets:
  a packet holds at most 128 pixels in 1 + ps bytes. Before anything is
  allocated. }
function TgaRleFits(w, h, ps, available: Int64): Boolean;

implementation

uses praarith, pramodel;

{ ---------- the packets' coder ---------- }

const
  N_CTX = 1 shl 12;
  PACKET_LIMIT = 60;

type
  { a few direct contexts, no mixing: the choices are nearly certain }
  TPacketCoder = record
    encoding: Boolean;
    enc: TArithEncoder;
    dec: TArithDecoder;
    c: array[0..N_CTX - 1] of TCounter;
    procedure Init(encode: Boolean; const data: TBytes);
    function Bit(ctx, b: Integer): Integer;
    { v in [0, 2^nbits), MSB first, a tree of contexts under ctx }
    function Tree(ctx, v, nbits: Integer): Integer;
  end;

procedure TPacketCoder.Init(encode: Boolean; const data: TBytes);
var i: Integer;
begin
  encoding := encode;
  for i := 0 to N_CTX - 1 do CounterInit(c[i]);
  if encode then enc.Init else dec.Init(data, 0);
end;

function TPacketCoder.Bit(ctx, b: Integer): Integer;
var p: Integer;
begin
  ctx := ctx and (N_CTX - 1);
  p := c[ctx].p;
  if p < 32 then p := 32 else if p > 65535 - 32 then p := 65535 - 32;
  if encoding then enc.Encode(b, p) else b := dec.Decode(p);
  CounterUpdate(c[ctx], b, PACKET_LIMIT);
  Result := b;
end;

function TPacketCoder.Tree(ctx, v, nbits: Integer): Integer;
var t, j: Integer;
begin
  t := 1;
  for j := nbits - 1 downto 0 do t := 2 * t + Bit(ctx + t, (v shr j) and 1);
  Result := t - (1 shl nbits);
end;

{ ---------- TGA ---------- }

function TgaRleFits(w, h, ps, available: Int64): Boolean;
begin
  Result := (w >= 1) and (h >= 1) and (ps >= 1) and (ps <= 4) and (w * h * ps <= MAX_RAW)
    and ((w * h + 127) div 128 * (1 + ps) <= available);
end;

{ how many equal pixels from n (n itself included), at most cap }
function RunAt(const raw: TBytes; n, total, ps, cap: Integer): Integer;
var k: Integer;
begin
  Result := 1;
  while (Result < cap) and (n + Result < total) do begin
    for k := 0 to ps - 1 do
      if raw[(n + Result) * ps + k] <> raw[n * ps + k] then Exit;
    Inc(Result);
  end;
end;

{ the literal a usual coder writes from n: up to the next pair of equal
  pixels, at most cap }
function LiteralAt(const raw: TBytes; n, total, ps, cap: Integer): Integer;
begin
  Result := 1;
  while (Result < cap) and (n + Result < total) do begin
    if (n + Result + 1 < total) and (RunAt(raw, n + Result, total, ps, 2) >= 2) then Exit;
    Inc(Result);
  end;
end;

function Bucket(v: Integer): Integer; inline;
begin
  if v >= 4 then Result := 3 else Result := v - 1;
  if Result < 0 then Result := 0;
end;

{ one packet's choice, both ways: isRun and count. Contexts: the run and
  the row's end at n, the run and literal a usual coder would write
  (crossing rows, and not), the previous packet's kind. }
procedure CodePacket(var pc: TPacketCoder; const raw: TBytes; n, total, w, ps: Integer;
                     var prevRun: Integer; var isRun, count: Integer);
var er, erRow, rowRem, el, elRow, ctx, e1, e2: Integer;
begin
  rowRem := w - n mod w;
  er := RunAt(raw, n, total, ps, 128);
  if er > rowRem then erRow := rowRem else erRow := er;
  ctx := Bucket(er) + 4 * Bucket(erRow) + 16 * prevRun + 32 * Ord(rowRem = 1);
  isRun := pc.Bit(ctx, isRun);
  if isRun <> 0 then begin e1 := er; e2 := erRow; end
  else begin
    el := LiteralAt(raw, n, total, ps, 128);
    elRow := el; if elRow > rowRem then elRow := rowRem;
    e1 := el; e2 := elRow;
  end;
  { the count: as expected crossing rows, or within the row, or spelled out }
  ctx := 64 + isRun * 64 + 8 * Ord(e1 = e2) + Bucket(e1);
  if pc.Bit(ctx, Ord(count = e1)) <> 0 then count := e1
  else if (e2 <> e1) and (pc.Bit(ctx + 32, Ord(count = e2)) <> 0) then count := e2
  else count := pc.Tree(256 + 256 * isRun, count - 1, 7) + 1;
  prevRun := isRun;
end;

function TgaRleLength(const d: TBytes; first: SizeInt; w, h: Int64; ps: Integer; out used: Int64): TParseStatus;
var p: SizeInt; n, total: Int64; c: Integer; hd: Byte;
begin
  used := 0;
  if not TgaRleFits(w, h, ps, Length(d) - first) then Exit(psTruncated);
  total := w * h; p := first; n := 0;
  while n < total do begin
    if p >= Length(d) then Exit(psTruncated);
    hd := d[p]; Inc(p);
    c := (hd and 127) + 1;
    if n + c > total then Exit(psMalformed);
    if (hd and 128) <> 0 then Inc(p, ps) else Inc(p, c * ps);
    if p > Length(d) then Exit(psTruncated);
    Inc(n, c);
  end;
  used := p - first;
  Result := psOk;
end;

function TgaRleScan(const d: TBytes; const L: TRasterLayout; ps: Integer;
                    out raw, side: TBytes; out used: Int64): TParseStatus;
var
  p: SizeInt; n, total, c, k, w, isRun, count, prevRun: Integer; hd: Byte; pc: TPacketCoder;
begin
  raw := nil; side := nil; used := 0;
  if not TgaRleFits(L.width, L.height, ps, Length(d) - L.dataOffset) then Exit(psTruncated);
  w := L.width; total := L.width * L.height;
  SetLength(raw, Int64(total) * ps);
  p := L.dataOffset; n := 0;
  { the packets: the pixels, checked }
  while n < total do begin
    if p >= Length(d) then Exit(psTruncated);
    hd := d[p]; Inc(p);
    c := (hd and 127) + 1;
    if n + c > total then Exit(psMalformed);        { a packet past the image }
    if (hd and 128) <> 0 then begin
      if p + ps > Length(d) then Exit(psTruncated);
      for k := 0 to c - 1 do Move(d[p], raw[(n + k) * ps], ps);
      Inc(p, ps);
    end else begin
      if p + c * ps > Length(d) then Exit(psTruncated);
      Move(d[p], raw[n * ps], c * ps);
      Inc(p, c * ps);
    end;
    Inc(n, c);
  end;
  used := p - L.dataOffset;
  { the packets: their choices, coded }
  pc.Init(True, nil);
  p := L.dataOffset; n := 0; prevRun := 0;
  while n < total do begin
    hd := d[p];
    isRun := hd shr 7; count := (hd and 127) + 1;
    CodePacket(pc, raw, n, total, w, ps, prevRun, isRun, count);
    if isRun <> 0 then Inc(p, 1 + ps) else Inc(p, 1 + count * ps);
    Inc(n, count);
  end;
  side := pc.enc.Finish;
  Result := psOk;
end;

function TgaRleRebuild(const raw, side: TBytes; const L: TRasterLayout; ps: Integer;
                       usedLimit: Int64; out coded: TBytes): Boolean;
var
  pc: TPacketCoder; n, total, w, isRun, count, prevRun: Integer; o: SizeInt;
begin
  coded := nil;
  w := L.width; total := L.width * L.height;
  if Length(raw) <> Int64(total) * ps then Exit(False);
  SetLength(coded, usedLimit);
  pc.Init(False, side);
  n := 0; o := 0; prevRun := 0;
  while n < total do begin
    isRun := 0; count := 1;
    CodePacket(pc, raw, n, total, w, ps, prevRun, isRun, count);
    { a damaged side: a count past the image, or more bytes than declared }
    if (count < 1) or (count > 128) or (n + count > total) then Exit(False);
    if isRun <> 0 then begin
      if o + 1 + ps > usedLimit then Exit(False);
      coded[o] := 128 or (count - 1);
      Move(raw[n * ps], coded[o + 1], ps);
      Inc(o, 1 + ps);
    end else begin
      if o + 1 + count * ps > usedLimit then Exit(False);
      coded[o] := count - 1;
      Move(raw[n * ps], coded[o + 1], count * ps);
      Inc(o, 1 + count * ps);
    end;
    Inc(n, count);
  end;
  Result := o = usedLimit;
end;

end.
