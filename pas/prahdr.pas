{ Layer 3: the Radiance HDR parser (RGBE / XYZE, ".hdr", ".pic").

  The header is text: a first line "#?RADIANCE" (or "#?RGBE", or any "#?"
  program name), variable lines such as FORMAT=32-bit_rle_rgbe, an empty
  line, then the resolution line. Only the usual orientation, "-Y H +X W"
  (rows top to bottom, each left to right), is taken; the other seven are
  psUnsupported.

  Each scanline is W pixels of 4 bytes (R, G, B and a shared exponent), either
  flat, or run-length coded: the bytes 2, 2, W >> 8, W & 255, then each of the
  four components in turn as runs (128 + n, value) and dumps (n, n values).
  The coder that wrote a line chose where its runs start and stop, and that
  choice has to come back too: a line is taken when one of two known coders
  writes it again byte for byte:

  - Radiance's own (fwritecolrs in color.c): runs of at least 4, a run of 2
    or 3 written as such just before a long one, dumps of up to 128;
  - stb_image_write's (stbiw__write_hdr_scanline): runs of at least 3, dumps
    of up to 128, runs cut at 127.

  A flat line is copied as it is, so it always comes back. A line neither
  coder reproduces makes the file psUnsupported for now. }
unit prahdr;

{$I pra.inc}
{$ifopt R-}{$fatal prahdr: range checks ($R+) are mandatory}{$endif}
{$ifopt Q-}{$fatal prahdr: overflow checks ($Q+) are mandatory}{$endif}

interface

uses SysUtils, praraster;

const
  HDR_FLAT = 0;
  HDR_RADIANCE = 1;
  HDR_STB = 2;

{ The header and the scanlines' extent: on psOk, L.dataOffset is where the
  first scanline starts and L.dataLength how long the scanlines are. }
function ParseHdr(const d: TBytes; out L: TRasterLayout): TParseStatus;

{ The scanlines at d[L.dataOffset..] to W*H*4 bytes of RGBE, the coder of
  each line (modes, H bytes) and the scanlines' length (used): psTruncated,
  psMalformed (a broken run), or psUnsupported (a line neither coder writes
  again, or an image too large to hold). }
function HdrDecode(const d: TBytes; const L: TRasterLayout; out rgbe, modes: TBytes; out used: Int64): TParseStatus;

{ Whether W x H pixels can be in `available` bytes of scanlines at all: a
  line takes at least 4 + 8 * ceil(W / 127) bytes (4 * W below 8 pixels). Checked before anything
  is allocated, by the parser and by the decoder alike. }
function HdrFits(w, h, available: Int64): Boolean;

{ The scanlines again, from the pixels and each line's coder. }
function HdrEncode(const rgbe, modes: TBytes; const L: TRasterLayout): TBytes;

implementation

uses pralimits;

{ ---------- the header ---------- }

function ParseHdr(const d: TBytes; out L: TRasterLayout): TParseStatus;
var p, lineStart, limit: SizeInt; line: string; first, blank: Boolean; w, h, used: Int64; rgbe, modes: TBytes;
  parts: TStringArray;
begin
  L.Clear;
  if (Length(d) < 2) or (d[0] <> Ord('#')) or (d[1] <> Ord('?')) then Exit(psNotThis);
  limit := Length(d);
  if limit > MAX_TEXT_HEADER then limit := MAX_TEXT_HEADER;
  p := 0; first := True; blank := False;
  { the header lines, up to the empty one }
  repeat
    lineStart := p;
    while (p < limit) and (d[p] <> 10) do Inc(p);
    if p >= limit then Exit(psMalformed);
    SetString(line, PAnsiChar(@d[lineStart]), p - lineStart);
    Inc(p);
    if first then first := False
    else if line = '' then blank := True
    else if Copy(line, 1, 7) = 'FORMAT=' then
      if (line <> 'FORMAT=32-bit_rle_rgbe') and (line <> 'FORMAT=32-bit_rle_xyze') then Exit(psUnsupported);
  until blank;
  { the resolution line }
  lineStart := p;
  while (p < limit) and (d[p] <> 10) do Inc(p);
  if p >= limit then Exit(psMalformed);
  SetString(line, PAnsiChar(@d[lineStart]), p - lineStart);
  Inc(p);
  parts := line.Split([' '], TStringSplitOptions.ExcludeEmpty);
  if Length(parts) <> 4 then Exit(psMalformed);
  if not (((parts[0] = '-Y') or (parts[0] = '+Y') or (parts[0] = '-X') or (parts[0] = '+X'))
     and ((parts[2] = '-Y') or (parts[2] = '+Y') or (parts[2] = '-X') or (parts[2] = '+X'))) then Exit(psMalformed);
  if not TryStrToInt64(parts[1], h) or not TryStrToInt64(parts[3], w) then Exit(psMalformed);
  if (parts[0] <> '-Y') or (parts[2] <> '+X') then Exit(psUnsupported);
  L.format := rfHDR; L.coding := CODING_HDR;
  L.width := w; L.height := h; L.channels := 4; L.bits := 8; L.maxval := 255;
  L.dataOffset := p;
  { the size limits, and the decoded pixels have to fit in the limits too }
  Result := SizeRows(L, High(Int64) shr 2);
  if Result <> psOk then begin L.format := rfNone; Exit(psMalformed); end;
  { the scanlines' length: decode them }
  Result := HdrDecode(d, L, rgbe, modes, used);
  if Result <> psOk then begin L.format := rfNone; Exit; end;
  L.dataLength := used;
end;

{ ---------- the scanlines ---------- }

type
  THdrOut = record
    b: TBytes;
    n: SizeInt;
    procedure Put(x: Byte); inline;
  end;

procedure THdrOut.Put(x: Byte);
begin
  if n >= Length(b) then SetLength(b, 2 * Length(b) + 64);
  b[n] := x; Inc(n);
end;

{ Radiance's fwritecolrs, one component: s[k * 4] for k in [0, w) }
procedure RadianceComponent(var o: THdrOut; const s: TBytes; base, w: Integer);
const MINRUN = 4;
var j, beg, cnt, c2: Integer;

  function V(k: Integer): Byte; inline;
  begin Result := s[base + 4 * k]; end;

begin
  j := 0; cnt := 0;
  while j < w do begin
    { the next run of at least MINRUN }
    beg := j;
    while beg < w do begin
      cnt := 1;
      while (cnt < 127) and (beg + cnt < w) and (V(beg + cnt) = V(beg)) do Inc(cnt);
      if cnt >= MINRUN then Break;
      beg := beg + cnt;
    end;
    { a short run just before it gets its own marker }
    if (beg - j > 1) and (beg - j < MINRUN) then begin
      c2 := j + 1;
      while V(c2) = V(j) do begin
        Inc(c2);
        if c2 = beg then begin
          o.Put(128 + beg - j); o.Put(V(j));
          j := beg;
          Break;
        end;
      end;
    end;
    { what is not a run }
    while j < beg do begin
      c2 := beg - j;
      if c2 > 128 then c2 := 128;
      o.Put(c2);
      while c2 > 0 do begin o.Put(V(j)); Inc(j); Dec(c2); end;
    end;
    { the run }
    if cnt >= MINRUN then begin
      o.Put(128 + cnt); o.Put(V(beg));
      j := beg + cnt;
    end;
  end;
end;

{ stb_image_write's, one component }
procedure StbComponent(var o: THdrOut; const s: TBytes; base, w: Integer);
var x, r, len, k: Integer;

  function V(k: Integer): Byte; inline;
  begin Result := s[base + 4 * k]; end;

begin
  x := 0;
  while x < w do begin
    r := x;
    while r + 2 < w do begin
      if (V(r) = V(r + 1)) and (V(r) = V(r + 2)) then Break;
      Inc(r);
    end;
    if r + 2 >= w then r := w;
    while x < r do begin
      len := r - x;
      if len > 128 then len := 128;
      o.Put(len);
      for k := 0 to len - 1 do o.Put(V(x + k));
      Inc(x, len);
    end;
    if r + 2 < w then begin
      while (r < w) and (V(r) = V(x)) do Inc(r);
      while x < r do begin
        len := r - x;
        if len > 127 then len := 127;
        o.Put(128 + len); o.Put(V(x));
        Inc(x, len);
      end;
    end;
  end;
end;

{ line y of the pixels, coded by `mode` }
procedure EncodeLine(var o: THdrOut; const rgbe: TBytes; y, w, mode: Integer);
var base, c, k: Integer;
begin
  base := y * w * 4;
  if mode = HDR_FLAT then begin
    for k := 0 to 4 * w - 1 do o.Put(rgbe[base + k]);
    Exit;
  end;
  o.Put(2); o.Put(2); o.Put(w shr 8); o.Put(w and 255);
  for c := 0 to 3 do
    if mode = HDR_RADIANCE then RadianceComponent(o, rgbe, base + c, w)
    else StbComponent(o, rgbe, base + c, w);
end;

function HdrFits(w, h, available: Int64): Boolean;
const MAX_PIXELS = Int64(1) shl 29;      { 2 GiB of RGBE }
var line: Int64;
begin
  Result := (w >= 1) and (h >= 1) and (w <= MAX_DIMENSION) and (h <= MAX_DIMENSION) and (w * h <= MAX_PIXELS);
  if not Result then Exit;
  { below 8 pixels a line is always flat }
  if w < 8 then line := 4 * w else line := 4 + 8 * ((w + 126) div 127);
  Result := h <= available div line;
end;

function HdrDecode(const d: TBytes; const L: TRasterLayout; out rgbe, modes: TBytes; out used: Int64): TParseStatus;
var
  w, h, y, c, x, n, k, mode: Integer; p, start: SizeInt; v: Byte; o: THdrOut; ok: Boolean;
begin
  rgbe := nil; modes := nil; used := 0;
  if not HdrFits(L.width, L.height, Length(d) - L.dataOffset) then Exit(psTruncated);
  w := L.width; h := L.height;
  SetLength(rgbe, Int64(w) * h * 4);
  SetLength(modes, h);
  o.b := nil; SetLength(o.b, 16 * w + 64);
  p := L.dataOffset;
  for y := 0 to h - 1 do begin
    start := p;
    if (w >= 8) and (w < 32768) and (p + 4 <= Length(d)) and (d[p] = 2) and (d[p + 1] = 2)
       and ((d[p + 2] shl 8) or d[p + 3] = w) then begin
      { run-length coded: the four components in turn }
      Inc(p, 4);
      for c := 0 to 3 do begin
        x := 0;
        while x < w do begin
          if p >= Length(d) then Exit(psTruncated);
          n := d[p]; Inc(p);
          if n > 128 then begin
            n := n - 128;
            if x + n > w then Exit(psMalformed);
            if p >= Length(d) then Exit(psTruncated);
            v := d[p]; Inc(p);
            for k := 0 to n - 1 do rgbe[(Int64(y) * w + x + k) * 4 + c] := v;
          end else begin
            if (n = 0) or (x + n > w) then Exit(psMalformed);
            if p + n > Length(d) then Exit(psTruncated);
            for k := 0 to n - 1 do rgbe[(Int64(y) * w + x + k) * 4 + c] := d[p + k];
            Inc(p, n);
          end;
          Inc(x, n);
        end;
      end;
      { which coder writes it again, byte for byte }
      ok := False;
      for mode := HDR_RADIANCE to HDR_STB do begin
        o.n := 0;
        EncodeLine(o, rgbe, y, w, mode);
        if (o.n = p - start) and CompareMem(@o.b[0], @d[start], o.n) then begin
          modes[y] := mode; ok := True; Break;
        end;
      end;
      if not ok then Exit(psUnsupported);
    end else begin
      if p + 4 * Int64(w) > Length(d) then Exit(psTruncated);
      Move(d[p], rgbe[Int64(y) * w * 4], 4 * w);
      Inc(p, 4 * w);
      modes[y] := HDR_FLAT;
    end;
  end;
  used := p - L.dataOffset;
  Result := psOk;
end;

function HdrEncode(const rgbe, modes: TBytes; const L: TRasterLayout): TBytes;
var o: THdrOut; y: Integer;
begin
  o.b := nil; SetLength(o.b, L.width * 5 + 64); o.n := 0;
  for y := 0 to L.height - 1 do EncodeLine(o, rgbe, y, L.width, modes[y]);
  Result := Copy(o.b, 0, o.n);
end;

end.
