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


type
  { The byte-escape run-length codings: a run is marked by a byte, anything
    else is a literal.
    - PCX: a byte with its two top bits set is a run of (b and 63) copies
      (0 to 63) of the next byte; any other byte is itself. A literal of
      $C0 or more cannot be written: it is a run of 1.
    - Sun Raster type 2: $80 n v is n + 1 copies of v (n >= 1), $80 0 is a
      literal $80, any other byte is itself. }
  TByteRle = (brPcx, brSun);

{ The decoded bytes (count of them, rows of lineLen bytes, which runs may
  cross or not) at d[first..]: the bytes, the runs' choices coded (side),
  and how many coded bytes they took. }
function ByteRleScan(g: TByteRle; const d: TBytes; first: SizeInt; count, lineLen: Int64;
                     out raw, side: TBytes; out used: Int64): TParseStatus;
{ only the coded length (the parser) }
function ByteRleLength(g: TByteRle; const d: TBytes; first: SizeInt; count: Int64; out used: Int64): TParseStatus;
{ the coded bytes again, from the decoded ones and side }
function ByteRleRebuild(g: TByteRle; const raw, side: TBytes; lineLen, usedLimit: Int64; out coded: TBytes): Boolean;
{ whether count decoded bytes can be in `available` coded ones: a run holds
  at most 63 (PCX) or 256 (Sun) in 2 or 3 bytes }
function ByteRleFits(g: TByteRle; count, available: Int64): Boolean;

{ ---------- SGI ---------- }

{ An SGI image's pixels: the planes (channel after channel, rows bottom to
  top, bpc bytes a value, big-endian) <-> the pixels the codec models
  (channels interleaved). }
function SgiToPixels(const planar: TBytes; xs, ys, zs, bpc: Integer): TBytes;
function SgiFromPixels(const px: TBytes; xs, ys, zs, bpc: Integer): TBytes;

{ An SGI run-length image's coded part, from its tables (at d[first], after
  the 512-byte header) to the end of its last row: the pixels (as
  SgiToPixels gives them), the choices (the rows' order and each row's
  packets) coded, and the coded part's length. psUnsupported when the rows
  are not laid one after the other right after the tables. }
function SgiRleScan(const d: TBytes; first: SizeInt; xs, ys, zs, bpc: Integer;
                    out px, side: TBytes; out used: Int64): TParseStatus;
{ only the coded part's length (the parser) }
function SgiRleLength(const d: TBytes; first: SizeInt; xs, ys, zs, bpc: Integer; out used: Int64): TParseStatus;
function SgiRleRebuild(const px, side: TBytes; xs, ys, zs, bpc: Integer; usedLimit: Int64; out coded: TBytes): Boolean;
function SgiRleFits(xs, ys, zs, bpc: Integer; available: Int64): Boolean;

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

{ ---------- byte-escape codings: PCX, Sun Raster ---------- }

function MaxRun(g: TByteRle): Integer; inline;
begin
  if g = brPcx then Result := 63 else Result := 256;
end;

function ByteRleFits(g: TByteRle; count, available: Int64): Boolean;
begin
  if (count < 0) or (count > MAX_RAW) or (available < 0) then Exit(False);
  if g = brPcx then Result := (count + 62) div 63 * 2 <= available
  else Result := (count + 255) div 256 * 3 <= available;
end;

{ one coded token at d[p]: its count of decoded bytes, whether it is a run,
  its value, and its coded size; False if the data ends inside it }
function ReadToken(g: TByteRle; const d: TBytes; p: SizeInt; out count, isRun: Integer; out v: Byte;
                   out size: Integer): Boolean;
var b: Byte;
begin
  Result := False;
  if p >= Length(d) then Exit;
  b := d[p];
  if g = brPcx then begin
    if b >= $C0 then begin
      if p + 1 >= Length(d) then Exit;
      count := b and 63; isRun := 1; v := d[p + 1]; size := 2;
    end else begin count := 1; isRun := 0; v := b; size := 1; end;
  end else begin
    if b = $80 then begin
      if p + 1 >= Length(d) then Exit;
      if d[p + 1] = 0 then begin count := 1; isRun := 0; v := $80; size := 2; end
      else begin
        if p + 2 >= Length(d) then Exit;
        count := d[p + 1] + 1; isRun := 1; v := d[p + 2]; size := 3;
      end;
    end else begin count := 1; isRun := 0; v := b; size := 1; end;
  end;
  Result := True;
end;

function ByteRleLength(g: TByteRle; const d: TBytes; first: SizeInt; count: Int64; out used: Int64): TParseStatus;
var p: SizeInt; n: Int64; c, r, size: Integer; v: Byte;
begin
  used := 0;
  if not ByteRleFits(g, count, Length(d) - first) then Exit(psTruncated);
  p := first; n := 0;
  while n < count do begin
    if not ReadToken(g, d, p, c, r, v, size) then Exit(psTruncated);
    if n + c > count then Exit(psMalformed);
    { a PCX run of 0 decodes to nothing: its value could not come back }
    if c = 0 then Exit(psUnsupported);
    Inc(p, size); Inc(n, c);
  end;
  used := p - first;
  Result := psOk;
end;

{ how many equal bytes from n, at most cap }
function ByteRunAt(const raw: TBytes; n, total, cap: Int64): Integer;
begin
  Result := 1;
  while (Result < cap) and (n + Result < total) and (raw[n + Result] = raw[n]) do Inc(Result);
end;

{ one token's choice, both ways. Contexts: the run at n, crossing rows and
  not; whether the value forces a run (PCX, $C0 and up); the previous kind. }
procedure CodeByteToken(g: TByteRle; var pc: TPacketCoder; const raw: TBytes; n, total, lineLen: Int64;
                        var prevRun: Integer; var isRun, count: Integer);
var er, erLine, lineRem, ctx, forced, cap: Integer;
begin
  cap := MaxRun(g);
  lineRem := lineLen - n mod lineLen;
  er := ByteRunAt(raw, n, total, cap);
  if er > lineRem then erLine := lineRem else erLine := er;
  forced := Ord((g = brPcx) and (raw[n] >= $C0));
  if forced = 0 then begin
    ctx := Bucket(er) + 4 * Bucket(erLine) + 16 * prevRun + 32 * Ord(lineRem = 1) + 64 * Ord(g);
    isRun := pc.Bit(ctx, isRun);
  end else isRun := 1;
  if isRun = 0 then count := 1
  else begin
    ctx := 256 + 16 * forced + 4 * Ord(er = erLine) + Bucket(er) + 64 * Ord(g);
    if pc.Bit(ctx, Ord(count = er)) <> 0 then count := er
    else if (erLine <> er) and (pc.Bit(ctx + 32, Ord(count = erLine)) <> 0) then count := erLine
    else if g = brPcx then count := pc.Tree(1024, count, 6)
    else count := pc.Tree(2048, count - 1, 8) + 1;
  end;
  prevRun := isRun;
end;

function ByteRleScan(g: TByteRle; const d: TBytes; first: SizeInt; count, lineLen: Int64;
                     out raw, side: TBytes; out used: Int64): TParseStatus;
var p: SizeInt; n: Int64; c, r, size, k, prevRun, isRun, cnt: Integer; v: Byte; pc: TPacketCoder;
begin
  raw := nil; side := nil;
  Result := ByteRleLength(g, d, first, count, used);
  if Result <> psOk then Exit;
  if lineLen < 1 then Exit(psMalformed);
  SetLength(raw, count);
  p := first; n := 0;
  while n < count do begin
    ReadToken(g, d, p, c, r, v, size);
    for k := 0 to c - 1 do raw[n + k] := v;
    Inc(p, size); Inc(n, c);
  end;
  pc.Init(True, nil);
  p := first; n := 0; prevRun := 0;
  while n < count do begin
    ReadToken(g, d, p, c, r, v, size);
    isRun := r; cnt := c;
    CodeByteToken(g, pc, raw, n, count, lineLen, prevRun, isRun, cnt);
    Inc(p, size); Inc(n, c);
  end;
  side := pc.enc.Finish;
end;

function ByteRleRebuild(g: TByteRle; const raw, side: TBytes; lineLen, usedLimit: Int64; out coded: TBytes): Boolean;
var pc: TPacketCoder; n, total: Int64; o: SizeInt; prevRun, isRun, cnt: Integer; v: Byte;
begin
  coded := nil; Result := False;
  total := Length(raw);
  if (lineLen < 1) or (usedLimit < 0) then Exit;
  SetLength(coded, usedLimit);
  pc.Init(False, side);
  n := 0; o := 0; prevRun := 0;
  while n < total do begin
    isRun := 0; cnt := 1;
    CodeByteToken(g, pc, raw, n, total, lineLen, prevRun, isRun, cnt);
    if (cnt < 0) or (n + cnt > total) then Exit;
    v := raw[n];
    if isRun = 0 then begin
      if g = brPcx then begin
        if v >= $C0 then Exit;                     { only a damaged side }
        if o + 1 > usedLimit then Exit;
        coded[o] := v; Inc(o);
      end else if v = $80 then begin
        if o + 2 > usedLimit then Exit;
        coded[o] := $80; coded[o + 1] := 0; Inc(o, 2);
      end else begin
        if o + 1 > usedLimit then Exit;
        coded[o] := v; Inc(o);
      end;
    end else if g = brPcx then begin
      if (cnt < 1) or (cnt > 63) or (o + 2 > usedLimit) then Exit;
      coded[o] := $C0 or cnt; coded[o + 1] := v; Inc(o, 2);
    end else begin
      if (cnt < 2) or (cnt > 256) or (o + 3 > usedLimit) then Exit;
      coded[o] := $80; coded[o + 1] := cnt - 1; coded[o + 2] := v; Inc(o, 3);
    end;
    Inc(n, cnt);
  end;
  Result := o = usedLimit;
end;

{ ---------- SGI ---------- }

function SgiToPixels(const planar: TBytes; xs, ys, zs, bpc: Integer): TBytes;
var y, x, z, k: Integer; src, dst: Int64;
begin
  if zs = 1 then Exit(Copy(planar, 0, Length(planar)));
  Result := nil; SetLength(Result, Length(planar));
  for z := 0 to zs - 1 do
    for y := 0 to ys - 1 do
      for x := 0 to xs - 1 do begin
        src := ((Int64(z) * ys + y) * xs + x) * bpc;
        dst := ((Int64(y) * xs + x) * zs + z) * bpc;
        for k := 0 to bpc - 1 do Result[dst + k] := planar[src + k];
      end;
end;

function SgiFromPixels(const px: TBytes; xs, ys, zs, bpc: Integer): TBytes;
var y, x, z, k: Integer; src, dst: Int64;
begin
  if zs = 1 then Exit(Copy(px, 0, Length(px)));
  Result := nil; SetLength(Result, Length(px));
  for z := 0 to zs - 1 do
    for y := 0 to ys - 1 do
      for x := 0 to xs - 1 do begin
        dst := ((Int64(z) * ys + y) * xs + x) * bpc;
        src := ((Int64(y) * xs + x) * zs + z) * bpc;
        for k := 0 to bpc - 1 do Result[dst + k] := px[src + k];
      end;
end;

function SgiRleFits(xs, ys, zs, bpc: Integer; available: Int64): Boolean;
var rows: Int64;
begin
  rows := Int64(ys) * zs;
  Result := (xs >= 1) and (ys >= 1) and (zs >= 1) and (bpc in [1, 2])
    and (Int64(xs) * rows * bpc <= MAX_RAW)
    and (rows * 8 + rows * ((xs + 126) div 127 * 2 + 1) * bpc <= available);
end;

function BE32(const d: TBytes; i: SizeInt): Int64;
begin Result := (Int64(d[i]) shl 24) or (Int64(d[i + 1]) shl 16) or (Int64(d[i + 2]) shl 8) or d[i + 3]; end;

{ a unit (bpc bytes) of a row, as a number }
function UnitAt(const d: TBytes; p: SizeInt; bpc: Integer): Integer; inline;
begin
  if bpc = 1 then Result := d[p] else Result := (d[p] shl 8) or d[p + 1];
end;

{ the rows' order (row indices by start); False if the rows are not laid
  one after the other from the end of the tables }
function SgiOrder(const d: TBytes; first: SizeInt; rows: Integer; out order: array of Integer; out total: Int64): Boolean;
var i, j, k, t: Integer; st: array of Int64;
begin
  Result := False; total := 0;
  st := nil; SetLength(st, rows);
  for i := 0 to rows - 1 do begin st[i] := BE32(d, first + 4 * i); order[i] := i; end;
  { by start: a shell sort (rows are often nearly in order, not always) }
  k := rows div 2;
  while k > 0 do begin
    for i := k to rows - 1 do begin
      t := order[i]; j := i;
      while (j >= k) and (st[order[j - k]] > st[t]) do begin order[j] := order[j - k]; Dec(j, k); end;
      order[j] := t;
    end;
    k := k div 2;
  end;
  { the starts in the file count from its beginning: the tables are at 512 }
  total := first + 8 * Int64(rows);
  for i := 0 to rows - 1 do begin
    if st[order[i]] <> total then Exit;
    total := total + BE32(d, first + 4 * Int64(rows) + 4 * order[i]);
  end;
  Result := True;
end;

{ a row's packets, from p to rowEnd: into planar when fill, checking they
  give exactly xs values and end with a zero count where the row ends }
function SgiRow(const d: TBytes; p, rowEnd: SizeInt; xs, bpc: Integer; var planar: TBytes; dst: Int64;
                fill: Boolean): TParseStatus;
var n, c, k: Integer;
begin
  n := 0;
  repeat
    if p + bpc > rowEnd then Exit(psMalformed);
    c := UnitAt(d, p, bpc); Inc(p, bpc);
    if c = 0 then Break;
    if (c and 127) = 0 then Exit(psUnsupported);     { a zero count with its high bit set }
    if c > 255 then Exit(psUnsupported);             { a 16-bit count above 255 }
    if (c and 128) <> 0 then begin
      c := c and 127;
      if (n + c > xs) or (p + c * bpc > rowEnd) then Exit(psMalformed);
      if fill then Move(d[p], planar[dst + n * bpc], c * bpc);
      Inc(p, c * bpc);
    end else begin
      if (n + c > xs) or (p + bpc > rowEnd) then Exit(psMalformed);
      if fill then for k := 0 to c - 1 do Move(d[p], planar[dst + (n + k) * bpc], bpc);
      Inc(p, bpc);
    end;
    Inc(n, c);
  until False;
  { every value, and nothing after the zero }
  if (n <> xs) or (p <> rowEnd) then Exit(psUnsupported);
  Result := psOk;
end;

function SgiRleLength(const d: TBytes; first: SizeInt; xs, ys, zs, bpc: Integer; out used: Int64): TParseStatus;
var rows, i: Integer; order: array of Integer; total, a: Int64; dummy: TBytes; st: TParseStatus;
begin
  used := 0;
  if not SgiRleFits(xs, ys, zs, bpc, Length(d) - first) then Exit(psTruncated);
  rows := ys * zs;
  order := nil; SetLength(order, rows);
  if not SgiOrder(d, first, rows, order, total) then Exit(psUnsupported);
  if total > Length(d) then Exit(psTruncated);
  dummy := nil;
  for i := 0 to rows - 1 do begin
    a := BE32(d, first + 4 * order[i]);
    st := SgiRow(d, a, a + BE32(d, first + 4 * Int64(rows) + 4 * order[i]), xs, bpc, dummy, 0, False);
    if st <> psOk then Exit(st);
  end;
  used := total - first;
  Result := psOk;
end;

{ how many equal units from n in a row, at most cap }
function UnitRunAt(const row: TBytes; base: Int64; n, xs, bpc, cap: Integer): Integer;
var k: Integer;
begin
  Result := 1;
  while (Result < cap) and (n + Result < xs) do begin
    for k := 0 to bpc - 1 do
      if row[base + (n + Result) * bpc + k] <> row[base + n * bpc + k] then Exit;
    Inc(Result);
  end;
end;

{ the literal a usual coder writes from n: up to the next run of minRun }
function UnitLiteralAt(const row: TBytes; base: Int64; n, xs, bpc, minRun: Integer): Integer;
begin
  Result := 1;
  while (Result < 127) and (n + Result < xs) do begin
    if UnitRunAt(row, base, n + Result, xs, bpc, minRun) >= minRun then Exit;
    Inc(Result);
  end;
end;

{ one packet of a row, both ways }
procedure CodeSgiPacket(var pc: TPacketCoder; const planar: TBytes; base: Int64; n, xs, bpc: Integer;
                        var prevRun: Integer; var isRun, count: Integer);
var er, e2, e3, ctx: Integer;
begin
  er := UnitRunAt(planar, base, n, xs, bpc, 127);
  ctx := 3000 + Bucket(er) + 4 * prevRun + 8 * Ord(xs - n <= 2);
  isRun := pc.Bit(ctx, isRun);
  if isRun <> 0 then begin
    ctx := 3100 + Bucket(er);
    if pc.Bit(ctx, Ord(count = er)) <> 0 then count := er
    else count := pc.Tree(3200, count - 1, 7) + 1;
  end else begin
    e2 := UnitLiteralAt(planar, base, n, xs, bpc, 2);
    e3 := UnitLiteralAt(planar, base, n, xs, bpc, 3);
    ctx := 3400 + 4 * Ord(e2 = e3) + Bucket(e2);
    if pc.Bit(ctx, Ord(count = e3)) <> 0 then count := e3
    else if (e2 <> e3) and (pc.Bit(ctx + 16, Ord(count = e2)) <> 0) then count := e2
    else count := pc.Tree(3500, count - 1, 7) + 1;
  end;
  prevRun := isRun;
end;

{ the rows' order: each step from the row before, as the step before it,
  as the step zs rows before (a row of channels), or spelled out }
procedure CodeOrder(var pc: TPacketCoder; var order: array of Integer; rows, zs: Integer);
var i, prev, c1, c2, nb, k: Integer; steps: array of Integer; z: Cardinal;
begin
  steps := nil; SetLength(steps, rows);
  if not pc.encoding then for i := 0 to rows - 1 do order[i] := -1;
  for i := 0 to rows - 1 do begin
    if i = 0 then prev := 0 else prev := order[i - 1];
    if i >= 1 then c1 := steps[i - 1] else c1 := 0;
    if i >= zs then c2 := steps[i - zs] else c2 := c1;
    if pc.encoding then steps[i] := order[i] - prev;
    if pc.Bit(3990, Ord(steps[i] = c1)) <> 0 then steps[i] := c1
    else if (c2 <> c1) and (pc.Bit(3991, Ord(steps[i] = c2)) <> 0) then steps[i] := c2
    else begin
      { zigzag, then its bytes: how many, and each }
      z := 0; nb := 0;
      if pc.encoding then begin
        if steps[i] >= 0 then z := Cardinal(steps[i]) shl 1 else z := (Cardinal(-(steps[i] + 1)) shl 1) or 1;
        while (nb < 4) and ((z shr (8 * nb)) <> 0) do Inc(nb);
      end;
      nb := pc.Tree(3960, nb, 3);
      if nb > 4 then nb := 4;
      if not pc.encoding then z := 0;
      for k := 0 to nb - 1 do
        z := (z and not (Cardinal(255) shl (8 * k))) or (Cardinal(pc.Tree(3700, (z shr (8 * k)) and 255, 8)) shl (8 * k));
      if (z and 1) = 0 then steps[i] := Integer(z shr 1) else steps[i] := -Integer(z shr 1) - 1;
    end;
    { only a damaged side gives a row that is not one: the caller refuses it }
    if (Int64(prev) + steps[i] < 0) or (Int64(prev) + steps[i] >= rows) then begin order[i] := -1; Exit; end;
    order[i] := prev + steps[i];
  end;
end;

function SgiRleScan(const d: TBytes; first: SizeInt; xs, ys, zs, bpc: Integer;
                    out px, side: TBytes; out used: Int64): TParseStatus;
var
  rows, i, n, c, prevRun, isRun, cnt: Integer; order: array of Integer; total: Int64; planar: TBytes;
  p, rowStart, rowEnd: SizeInt; pc: TPacketCoder;
begin
  px := nil; side := nil;
  Result := SgiRleLength(d, first, xs, ys, zs, bpc, used);
  if Result <> psOk then Exit;
  rows := ys * zs;
  order := nil; SetLength(order, rows);
  SgiOrder(d, first, rows, order, total);
  planar := nil; SetLength(planar, Int64(xs) * rows * bpc);
  for i := 0 to rows - 1 do begin
    rowStart := BE32(d, first + 4 * i);
    SgiRow(d, rowStart, rowStart + BE32(d, first + 4 * Int64(rows) + 4 * i), xs, bpc, planar, Int64(i) * xs * bpc, True);
  end;
  { the choices: the order, then each row's packets, rows in file order }
  pc.Init(True, nil);
  CodeOrder(pc, order, rows, zs);
  for i := 0 to rows - 1 do begin
    p := BE32(d, first + 4 * order[i]);
    rowEnd := p + BE32(d, first + 4 * Int64(rows) + 4 * order[i]) - bpc;
    n := 0; prevRun := 0;
    while p < rowEnd do begin
      c := UnitAt(d, p, bpc);
      isRun := Ord((c and 128) = 0); cnt := c and 127;
      CodeSgiPacket(pc, planar, Int64(order[i]) * xs * bpc, n, xs, bpc, prevRun, isRun, cnt);
      if isRun <> 0 then Inc(p, 2 * bpc) else Inc(p, (1 + cnt) * bpc);
      Inc(n, cnt);
    end;
  end;
  side := pc.enc.Finish;
  px := SgiToPixels(planar, xs, ys, zs, bpc);
end;

function SgiRleRebuild(const px, side: TBytes; xs, ys, zs, bpc: Integer; usedLimit: Int64; out coded: TBytes): Boolean;
var
  rows, i, n, prevRun, isRun, cnt: Integer; order: array of Integer; planar, buf: TBytes; o, rowStart, base: Int64;
  pc: TPacketCoder; seen: array of Boolean;

  function Put(v: Integer): Boolean;
  begin
    if o + bpc > usedLimit then Exit(False);
    if bpc = 1 then buf[o] := v else begin buf[o] := v shr 8; buf[o + 1] := v and 255; end;
    Inc(o, bpc);
    Result := True;
  end;

  procedure Put32(at, v: Int64);
  begin
    buf[at] := v shr 24; buf[at + 1] := (v shr 16) and 255; buf[at + 2] := (v shr 8) and 255; buf[at + 3] := v and 255;
  end;

begin
  coded := nil; Result := False;
  rows := ys * zs;
  if (Length(px) <> Int64(xs) * rows * bpc) or (usedLimit < 8 * Int64(rows)) then Exit;
  planar := SgiFromPixels(px, xs, ys, zs, bpc);
  buf := nil; SetLength(buf, usedLimit);
  pc.Init(False, side);
  order := nil; SetLength(order, rows);
  CodeOrder(pc, order, rows, zs);
  { a permutation, or the side is damaged }
  seen := nil; SetLength(seen, rows);
  for i := 0 to rows - 1 do begin
    if (order[i] < 0) or (order[i] >= rows) or seen[order[i]] then Exit;
    seen[order[i]] := True;
  end;
  o := 8 * Int64(rows);
  for i := 0 to rows - 1 do begin
    base := Int64(order[i]) * xs * bpc;
    rowStart := o;
    n := 0; prevRun := 0;
    while n < xs do begin
      isRun := 0; cnt := 1;
      CodeSgiPacket(pc, planar, base, n, xs, bpc, prevRun, isRun, cnt);
      if (cnt < 1) or (cnt > 127) or (n + cnt > xs) then Exit;
      if isRun <> 0 then begin
        if not Put(cnt) or (o + bpc > usedLimit) then Exit;
        Move(planar[base + n * bpc], buf[o], bpc); Inc(o, bpc);
      end else begin
        if not Put(128 or cnt) or (o + cnt * bpc > usedLimit) then Exit;
        Move(planar[base + n * bpc], buf[o], cnt * bpc); Inc(o, cnt * bpc);
      end;
      Inc(n, cnt);
    end;
    if not Put(0) then Exit;
    { the tables: where this row starts in the file (after the 512-byte
      header) and how long it is }
    Put32(4 * Int64(order[i]), 512 + rowStart);
    Put32(4 * Int64(rows) + 4 * order[i], o - rowStart);
  end;
  if o <> usedLimit then Exit;
  coded := buf;
  Result := True;
end;

end.
