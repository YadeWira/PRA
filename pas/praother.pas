{ Layer 3: parsers of formats whose pixels are stored as they are, one image
  a file: farbfeld, uncompressed Truevision TGA, Sun Raster (standard and
  RGB types) and WBMP (type 0).

  - farbfeld: "farbfeld", width and height (32-bit big-endian), then RGBA,
    16 bits a sample, big-endian.
  - TGA: an 18-byte header, an ID field and a colour map, then the pixels,
    as they are (types 1, 2, 3) or run-length coded (9, 10, 11: prarle):
    colour-mapped (type 1) or grey (type 3) at 8 bits, true colour (type 2)
    at 16 (one little-endian sample: the bits are 5-5-5), 24 (B, G, R) or
    32 (B, G, R, A). There is no magic number: the header has to be
    plausible and the pixels have to fit. What follows the pixels (TGA 2.0's
    extension area and footer) is the tail.
  - Sun Raster: magic 59A66A95, a 32-byte header and a colour map; rows
    padded to 16 bits; depth 1, 8, 24 (B, G, R; R, G, B for type 3) or 32
    (a pad byte, then the three). Type 2 run-length codes those bytes
    (prarle).
  - PCX (ZSoft): a 128-byte header (manufacturer 10, encoding 1), then the
    lines run-length coded (prarle), each line the planes one after the
    other; what follows (the 256-colour palette, $0C and 768 bytes) is the
    tail. 1, 2, 4 or 8 bits in one plane; 8 bits in 3 or 4 planes (RGB,
    RGBA); 1 bit in 2 to 4 planes (EGA's 16 colours).
  - SGI (IRIS): magic 474, a 512-byte header, then the channels one after
    the other (rows bottom to top, 1 or 2 bytes a value, big-endian),
    verbatim or run-length coded with tables of rows (prarle). Up to 4
    channels.
  - WBMP type 0: two zero bytes, width and height as multi-byte integers
    (7 bits a byte, the high bit set on all but the last), then 1-bit rows
    padded to a byte.
  - XWD (X11 window dump, version 7): a header of 32-bit fields (in either
    byte order: the version, 7, tells which) and a name, a colour map of
    12-byte entries, then the rows, bytes_per_line bytes each (which the
    stream does not keep: the decoder reads it from the header). 1, 4, 8,
    16 (one sample, in the file's byte order), 24 or 32 bits a pixel.
  - MTV (MTV ray tracer): "width height\n", then R, G, B. A text header of
    two numbers is a weak signature: the pixels have to fill the file.
  - VIFF (Khoros): $AB 1, a 1024-byte header, a colour map, then each band
    (channel) as a plane of its own, verbatim: bits, bytes, 16-bit values
    or (one band) 32-bit floats, in the byte order the header names.
  - VIPS: magic 08 F2 A6 B6 (big-endian) or B6 A6 F2 08 (little), a 64-byte
    header, the pixels interleaved, then the metadata (XML): the tail.
  - DDS, uncompressed: "DDS ", a 124-byte header, then the main surface (a
    volume's slices one under the other); its mipmaps and a cube map's
    other faces stay in the tail. Compressed surfaces (DXT, BC) are not
    raw pixels: PRA leaves them. }
unit praother;

{$I pra.inc}
{$ifopt R-}{$fatal praother: range checks ($R+) are mandatory}{$endif}
{$ifopt Q-}{$fatal praother: overflow checks ($Q+) are mandatory}{$endif}

interface

uses SysUtils, praraster;

function ParseFarbfeld(const d: TBytes; out L: TRasterLayout): TParseStatus;
function ParseTga(const d: TBytes; out L: TRasterLayout): TParseStatus;
function ParseSun(const d: TBytes; out L: TRasterLayout): TParseStatus;
function ParseWbmp(const d: TBytes; out L: TRasterLayout): TParseStatus;
function ParsePcx(const d: TBytes; out L: TRasterLayout): TParseStatus;
function ParseSgi(const d: TBytes; out L: TRasterLayout): TParseStatus;
function ParseXwd(const d: TBytes; out L: TRasterLayout): TParseStatus;
function ParseMtv(const d: TBytes; out L: TRasterLayout): TParseStatus;
function ParseViff(const d: TBytes; out L: TRasterLayout): TParseStatus;
function ParseVips(const d: TBytes; out L: TRasterLayout): TParseStatus;
function ParseDds(const d: TBytes; out L: TRasterLayout): TParseStatus;

{ XWD: the bytes a row takes, from its header (at hdr[first..first+len));
  -1 if that is not an XWD header }
function XwdStride(const hdr: TBytes; first, len: SizeInt): Int64;

{ PCX: what its 128-byte header (at hdr[first..]) says of the planes: bits a
  pixel in a plane, planes, bytes a plane's line, lines. False if it is not
  one PRA takes. }
function PcxParams(const hdr: TBytes; first: SizeInt; out bpp, planes, bpl, lines: Integer): Boolean;
{ A PCX's decoded lines (each: the planes one after the other) <-> the
  pixels the codec models: 8-bit planes interleaved into channels, 1-bit
  planes merged into 4-bit indices, one plane as it is. }
function PcxToPixels(const dec: TBytes; bpp, planes, bpl, lines: Integer): TBytes;
{ the pixels' layout: width, channels, bits }
procedure PcxPixels(bpp, planes, bpl: Integer; out w, channels, bits: Integer);
function PcxFromPixels(const px: TBytes; bpp, planes, bpl, lines: Integer): TBytes;

implementation

uses pralimits, prarle;

function U16LE(const d: TBytes; i: SizeInt): Int64; forward;

function U16LE(const d: TBytes; i: SizeInt): Int64;
begin Result := d[i] or (d[i + 1] shl 8); end;

function U32BE(const d: TBytes; i: SizeInt): Int64;
begin Result := (Int64(d[i]) shl 24) or (Int64(d[i + 1]) shl 16) or (Int64(d[i + 2]) shl 8) or Int64(d[i + 3]); end;

function U32LE(const d: TBytes; i: SizeInt): Int64;
begin Result := (Int64(d[i + 3]) shl 24) or (Int64(d[i + 2]) shl 16) or (Int64(d[i + 1]) shl 8) or Int64(d[i]); end;

function U32(const d: TBytes; i: SizeInt; be: Boolean): Int64;
begin if be then Result := U32BE(d, i) else Result := U32LE(d, i); end;

function Finish(const d: TBytes; var L: TRasterLayout): TParseStatus;
begin
  if L.dataOffset > MAX_TEXT_HEADER then Exit(psUnsupported);
  Result := SizeRows(L, Length(d) - L.dataOffset);
  if Result <> psOk then L.format := rfNone;
end;

{ ---------- farbfeld ---------- }

function ParseFarbfeld(const d: TBytes; out L: TRasterLayout): TParseStatus;
const MAGIC = 'farbfeld';
var i: Integer;
begin
  L.Clear;
  if Length(d) < 8 then Exit(psNotThis);
  for i := 1 to 8 do if d[i - 1] <> Ord(MAGIC[i]) then Exit(psNotThis);
  if Length(d) < 16 then Exit(psMalformed);
  L.format := rfFarbfeld;
  L.width := U32BE(d, 8); L.height := U32BE(d, 12);
  L.channels := 4; L.bits := 16; L.maxval := 65535; L.bigEndian := True;
  L.dataOffset := 16;
  Result := Finish(d, L);
end;

{ ---------- TGA ---------- }

function ParseTga(const d: TBytes; out L: TRasterLayout): TParseStatus;
var idLen, cmType, imgType, cmFirst, cmLen, cmBits, w, h, bpp, desc, cmBytes, used: Int64;
begin
  L.Clear;
  if Length(d) < 18 then Exit(psNotThis);
  idLen := d[0]; cmType := d[1]; imgType := d[2];
  cmFirst := U16LE(d, 3); cmLen := U16LE(d, 5); cmBits := d[7];
  w := U16LE(d, 12); h := U16LE(d, 14); bpp := d[16]; desc := d[17];
  { no magic: everything has to be plausible, or it is not a TGA }
  if not (imgType in [1, 2, 3, 9, 10, 11]) or (cmType > 1) then Exit(psNotThis);
  if (w = 0) or (h = 0) or not (bpp in [8, 15, 16, 24, 32]) then Exit(psNotThis);
  if (desc and $C0) <> 0 then Exit(psNotThis);                { interleaving: never used }
  if (imgType in [1, 9]) <> (cmType = 1) then Exit(psNotThis);  { a colour map with its type }
  if (cmType = 1) and not (cmBits in [15, 16, 24, 32]) then Exit(psNotThis);
  if (cmType = 0) and ((cmFirst <> 0) or (cmLen <> 0)) and (cmBits = 0) then ;  { tolerated }
  if cmType = 1 then cmBytes := cmLen * ((cmBits + 7) div 8) else cmBytes := 0;
  L.format := rfTGA;
  L.width := w; L.height := h;
  L.bottomUp := (desc and $20) = 0;
  L.bigEndian := False;
  case bpp of
    8: begin L.channels := 1; L.bits := 8; end;
    15, 16: begin L.channels := 1; L.bits := 16; end;
    24: begin L.channels := 3; L.bits := 8; end;
    32: begin L.channels := 4; L.bits := 8; end;
  end;
  if (imgType in [1, 3]) and (bpp <> 8) then Exit(psUnsupported);  { 16-bit indices, 16-bit grey }
  L.maxval := (Int64(1) shl L.bits) - 1;
  L.dataOffset := 18 + idLen + cmBytes;
  if L.dataOffset > Length(d) then begin L.format := rfNone; Exit(psTruncated); end;
  if imgType >= 9 then begin
    { run-length coded (prarle): the packets' length, walking them }
    L.coding := CODING_TGA_RLE;
    Result := SizeRows(L, High(Int64) shr 2);
    if Result = psOk then Result := TgaRleLength(d, L.dataOffset, L.width, L.height, (bpp + 7) div 8, used);
    if Result <> psOk then begin L.format := rfNone; Exit; end;
    L.dataLength := used;
    Exit(psOk);
  end;
  Result := Finish(d, L);
end;

{ ---------- Sun Raster ---------- }

function ParseSun(const d: TBytes; out L: TRasterLayout): TParseStatus;
var w, h, depth, rtype, maptype, maplen, used: Int64;
begin
  L.Clear;
  if (Length(d) < 4) or (U32BE(d, 0) <> $59A66A95) then Exit(psNotThis);
  if Length(d) < 32 then Exit(psMalformed);
  w := U32BE(d, 4); h := U32BE(d, 8); depth := U32BE(d, 12);
  rtype := U32BE(d, 20); maptype := U32BE(d, 24); maplen := U32BE(d, 28);
  if maptype > 2 then Exit(psMalformed);
  if maplen > MAX_TEXT_HEADER then Exit(psUnsupported);
  if not (rtype in [0, 1, 2, 3]) then Exit(psUnsupported);    { TIFF, IFF, experimental }
  L.format := rfSUN;
  L.width := w; L.height := h; L.bigEndian := True;
  case depth of
    1: begin L.channels := 1; L.bits := 1; end;
    8: begin L.channels := 1; L.bits := 8; end;
    24: begin L.channels := 3; L.bits := 8; end;
    32: begin L.channels := 4; L.bits := 8; end;
  else begin L.format := rfNone; Exit(psMalformed); end;
  end;
  L.maxval := (Int64(1) shl L.bits) - 1;
  L.dataOffset := 32 + maplen;
  if L.dataOffset > Length(d) then begin L.format := rfNone; Exit(psTruncated); end;
  if rtype = 2 then begin
    { run-length coded (prarle): the rows' bytes, padded, decoded }
    L.coding := CODING_SUN_RLE;
    Result := SizeRows(L, High(Int64) shr 2);
    if Result = psOk then Result := ByteRleLength(brSun, d, L.dataOffset, L.rowBytes * L.height, used);
    if Result <> psOk then begin L.format := rfNone; Exit; end;
    L.dataLength := used;
    Exit(psOk);
  end;
  Result := Finish(d, L);
end;

{ ---------- WBMP ---------- }

{ a multi-byte integer: at most 4 bytes (28 bits) }
function ReadMbi(const d: TBytes; var p: SizeInt; out v: Int64): Boolean;
var k: Integer; b: Byte;
begin
  v := 0;
  for k := 1 to 4 do begin
    if p >= Length(d) then Exit(False);
    b := d[p]; Inc(p);
    v := (v shl 7) or (b and $7F);
    if (b and $80) = 0 then Exit(True);
  end;
  Result := False;
end;

function ParseWbmp(const d: TBytes; out L: TRasterLayout): TParseStatus;
var p: SizeInt; w, h: Int64;
begin
  L.Clear;
  if (Length(d) < 4) or (d[0] <> 0) or (d[1] <> 0) then Exit(psNotThis);
  p := 2;
  if not ReadMbi(d, p, w) or not ReadMbi(d, p, h) then Exit(psNotThis);
  if (w = 0) or (h = 0) then Exit(psNotThis);
  L.format := rfWBMP;
  L.width := w; L.height := h; L.channels := 1; L.bits := 1; L.maxval := 1;
  L.dataOffset := p;
  Result := Finish(d, L);
  { two zero bytes and two numbers is a weak signature: a WBMP has to fill
    the file, give or take a little }
  if (Result = psOk) and (Length(d) - L.dataOffset - L.dataLength > 16) then begin
    L.format := rfNone; Result := psNotThis;
  end;
  if Result = psTruncated then begin L.format := rfNone; Result := psNotThis; end;
end;

{ ---------- PCX ---------- }

function PcxParams(const hdr: TBytes; first: SizeInt; out bpp, planes, bpl, lines: Integer): Boolean;
var y0, y1: Int64;
begin
  bpp := 0; planes := 0; bpl := 0; lines := 0;
  if (first < 0) or (first + 128 > Length(hdr)) or (hdr[first] <> 10) or (hdr[first + 2] <> 1) then Exit(False);
  bpp := hdr[first + 3]; planes := hdr[first + 65]; bpl := U16LE(hdr, first + 66);
  y0 := U16LE(hdr, first + 6); y1 := U16LE(hdr, first + 10);
  lines := y1 - y0 + 1;
  if (lines < 1) or (bpl < 1) then Exit(False);
  case bpp of
    1: Result := planes in [1, 2, 3, 4];
    2, 4: Result := planes = 1;
    8: Result := planes in [1, 3, 4];
  else Result := False;
  end;
end;

{ the pixels' layout: width, channels, bits }
procedure PcxPixels(bpp, planes, bpl: Integer; out w, channels, bits: Integer);
begin
  if planes = 1 then begin w := bpl * 8 div bpp; channels := 1; bits := bpp; end
  else if bpp = 8 then begin w := bpl; channels := planes; bits := 8; end
  else begin w := bpl * 8; channels := 1; bits := 4; end;
end;

function PcxToPixels(const dec: TBytes; bpp, planes, bpl, lines: Integer): TBytes;
var y, x, c, line, v: Integer; o: Int64;
begin
  if planes = 1 then Exit(Copy(dec, 0, Length(dec)));
  { 8-bit planes: as many bytes; 1-bit planes: 4 bits a pixel, whatever the
    planes (2 to 4) }
  Result := nil;
  if bpp = 8 then SetLength(Result, Length(dec)) else SetLength(Result, Int64(lines) * bpl * 4);
  line := planes * bpl;
  for y := 0 to lines - 1 do begin
    o := Int64(y) * line;
    if bpp = 8 then
      for x := 0 to bpl - 1 do
        for c := 0 to planes - 1 do Result[o + x * planes + c] := dec[o + c * bpl + x]
    else
      { 1-bit planes: pixel x's index has plane c's bit as its bit c; two
        4-bit pixels a byte, the first in the high half }
      for x := 0 to bpl * 8 - 1 do begin
        v := 0;
        for c := 0 to planes - 1 do v := v or (((dec[o + c * bpl + x shr 3] shr (7 - x and 7)) and 1) shl c);
        if (x and 1) = 0 then Result[Int64(y) * bpl * 4 + x shr 1] := v shl 4
        else Result[Int64(y) * bpl * 4 + x shr 1] := Result[Int64(y) * bpl * 4 + x shr 1] or v;
      end;
  end;
end;

function PcxFromPixels(const px: TBytes; bpp, planes, bpl, lines: Integer): TBytes;
var y, x, c, line, v: Integer; o: Int64;
begin
  if planes = 1 then Exit(Copy(px, 0, Length(px)));
  line := planes * bpl;
  Result := nil; SetLength(Result, Int64(lines) * line);
  for y := 0 to lines - 1 do begin
    o := Int64(y) * line;
    if bpp = 8 then
      for x := 0 to bpl - 1 do
        for c := 0 to planes - 1 do Result[o + c * bpl + x] := px[o + x * planes + c]
    else
      for x := 0 to bpl * 8 - 1 do begin
        v := px[Int64(y) * bpl * 4 + x shr 1];
        if (x and 1) = 0 then v := v shr 4 else v := v and 15;
        for c := 0 to planes - 1 do
          if ((v shr c) and 1) <> 0 then
            Result[o + c * bpl + x shr 3] := Result[o + c * bpl + x shr 3] or (1 shl (7 - x and 7));
      end;
  end;
end;

function ParsePcx(const d: TBytes; out L: TRasterLayout): TParseStatus;
var bpp, planes, bpl, lines, w, ch, bits: Integer; used: Int64;
begin
  L.Clear;
  if (Length(d) < 3) or (d[0] <> 10) or not (d[1] in [0, 2, 3, 4, 5]) then Exit(psNotThis);
  if d[2] <> 1 then Exit(psUnsupported);          { not run-length coded }
  if Length(d) < 128 then Exit(psMalformed);
  if not PcxParams(d, 0, bpp, planes, bpl, lines) then Exit(psUnsupported);
  PcxPixels(bpp, planes, bpl, w, ch, bits);
  L.format := rfPCX; L.coding := CODING_PCX;
  L.width := w; L.height := lines; L.channels := ch; L.bits := bits;
  L.maxval := (Int64(1) shl bits) - 1;
  L.dataOffset := 128;
  Result := SizeRows(L, High(Int64) shr 2);
  if Result = psOk then
    Result := ByteRleLength(brPcx, d, 128, Int64(lines) * planes * bpl, used);
  if Result <> psOk then begin L.format := rfNone; Exit; end;
  L.dataLength := used;
end;

{ ---------- SGI ---------- }

function ParseSgi(const d: TBytes; out L: TRasterLayout): TParseStatus;
var storage, bpc, dim, xs, ys, zs: Integer; used, size: Int64;
begin
  L.Clear;
  if (Length(d) < 2) or (d[0] <> 1) or (d[1] <> $DA) then Exit(psNotThis);
  if Length(d) < 512 then Exit(psMalformed);
  storage := d[2]; bpc := d[3];
  dim := (d[4] shl 8) or d[5];
  xs := (d[6] shl 8) or d[7]; ys := (d[8] shl 8) or d[9]; zs := (d[10] shl 8) or d[11];
  if (storage > 1) or not (bpc in [1, 2]) or not (dim in [1, 2, 3]) then Exit(psMalformed);
  if dim = 1 then begin ys := 1; zs := 1; end else if dim = 2 then zs := 1;
  if (xs < 1) or (ys < 1) or (zs < 1) then Exit(psMalformed);
  if zs > 4 then Exit(psUnsupported);
  L.format := rfSGI;
  L.width := xs; L.height := ys; L.channels := zs; L.bits := 8 * bpc; L.bigEndian := True;
  L.maxval := (Int64(1) shl L.bits) - 1;
  L.bottomUp := True;
  L.dataOffset := 512;
  if storage = 0 then begin
    L.coding := CODING_PLANES;
    size := Int64(xs) * ys * zs * bpc;
    if size > Length(d) - 512 then begin L.format := rfNone; Exit(psTruncated); end;
    L.dataLength := size;
    L.rowBytes := Int64(xs) * zs * bpc;
    Exit(psOk);
  end;
  L.coding := CODING_SGI_RLE;
  Result := SgiRleLength(d, 512, xs, ys, zs, bpc, used);
  if Result <> psOk then begin L.format := rfNone; Exit; end;
  L.dataLength := used;
  L.rowBytes := Int64(xs) * zs * bpc;
end;

{ ---------- XWD ---------- }

{ the header's byte order: the version (7) is the second field }
function XwdOrder(const d: TBytes; first: SizeInt; out be: Boolean): Boolean;
begin
  be := U32BE(d, first + 4) = 7;
  Result := be or (U32LE(d, first + 4) = 7);
end;

function XwdStride(const hdr: TBytes; first, len: SizeInt): Int64;
var be: Boolean;
begin
  Result := -1;
  if (first < 0) or (len < 100) or (first + len > Length(hdr)) or not XwdOrder(hdr, first, be) then Exit;
  Result := U32(hdr, first + 48, be);
end;

function ParseXwd(const d: TBytes; out L: TRasterLayout): TParseStatus;
var be: Boolean; hs, fmt, depth, order, bpp, ncolors: Int64;

  function F(k: Integer): Int64;
  begin Result := U32(d, 4 * k, be); end;

begin
  L.Clear;
  if (Length(d) < 100) or not XwdOrder(d, 0, be) then Exit(psNotThis);
  hs := F(0); fmt := F(2); depth := F(3); order := F(7); bpp := F(11); ncolors := F(19);
  { no magic: the version and plausible fields }
  if (hs < 100) or (fmt > 2) or (depth < 1) or (depth > 32) or (order > 1) then Exit(psNotThis);
  if (hs > MAX_TEXT_HEADER) or (ncolors > 65536) then Exit(psUnsupported);
  { XY formats: a plane after another; one plane is a bitmap like Z's }
  if (fmt < 2) and (depth <> 1) then Exit(psUnsupported);
  L.format := rfXWD;
  L.width := F(4); L.height := F(5);
  L.bigEndian := order = 1;
  case Cardinal(bpp) of
    1, 4, 8, 16: begin L.channels := 1; L.bits := bpp; end;
    24: begin L.channels := 3; L.bits := 8; end;
    32: begin L.channels := 4; L.bits := 8; end;
  else begin L.format := rfNone; Exit(psUnsupported); end;
  end;
  L.maxval := (Int64(1) shl L.bits) - 1;
  L.dataOffset := hs + 12 * ncolors;
  if L.dataOffset > Length(d) then begin L.format := rfNone; Exit(psTruncated); end;
  Result := SizeRowsStride(L, Length(d) - L.dataOffset, F(12));
  if Result <> psOk then L.format := rfNone;
end;

{ ---------- MTV ---------- }

function ParseMtv(const d: TBytes; out L: TRasterLayout): TParseStatus;
var p: SizeInt; w, h: Int64;

  function Number(out v: Int64): Boolean;
  var k: Integer;
  begin
    v := 0; k := 0;
    while (p < Length(d)) and (d[p] in [48..57]) and (k < 9) do begin
      v := v * 10 + d[p] - 48; Inc(p); Inc(k);
    end;
    Result := (k > 0) and (v > 0);
  end;

begin
  L.Clear;
  p := 0;
  if not Number(w) or (p >= Length(d)) or (d[p] <> 32) then Exit(psNotThis);
  Inc(p);
  if not Number(h) or (p >= Length(d)) or (d[p] <> 10) then Exit(psNotThis);
  L.format := rfMTV;
  L.width := w; L.height := h; L.channels := 3; L.bits := 8; L.maxval := 255;
  L.dataOffset := p + 1;
  Result := Finish(d, L);
  { two numbers is a weak signature: the pixels have to fill the file }
  if (Result = psOk) and (Length(d) - L.dataOffset - L.dataLength > 16) then Result := psNotThis;
  if Result = psTruncated then Result := psNotThis;
  if Result <> psOk then L.format := rfNone;
end;

{ ---------- VIFF ---------- }

function ParseViff(const d: TBytes; out L: TRasterLayout): TParseStatus;
var be: Boolean; images, bands, storage, scheme, mapScheme, mapStorage, mapBytes, bpc: Int64;

  function F(at: Integer): Int64;
  begin Result := U32(d, at, be); end;

begin
  L.Clear;
  if (Length(d) < 2) or (d[0] <> $AB) or (d[1] <> 1) then Exit(psNotThis);
  if Length(d) < 1024 then Exit(psMalformed);
  case d[4] of
    2: be := True;           { IEEE: big-endian }
    4, 8: be := False;       { DEC, NS: little-endian }
  else Exit(psUnsupported);  { Cray }
  end;
  images := F(556); bands := F(560); storage := F(564); scheme := F(568);
  mapScheme := F(572); mapStorage := F(576);
  if (bands < 1) or (images < 1) then Exit(psMalformed);
  if (scheme <> 0) or (images <> 1) or (bands > 4) then Exit(psUnsupported);
  L.format := rfVIFF;
  L.width := F(520); L.height := F(524); L.channels := bands; L.bigEndian := be;
  case Cardinal(storage) of
    0: L.bits := 1;
    1: L.bits := 8;
    2: L.bits := 16;
    5: begin L.bits := 32; L.isFloat := True; end;
  else begin L.format := rfNone; Exit(psUnsupported); end;
  end;
  { planes of bits and of floats: one band only }
  if (bands > 1) and not (L.bits in [8, 16]) then begin L.format := rfNone; Exit(psUnsupported); end;
  if L.isFloat then L.maxval := 0 else L.maxval := (Int64(1) shl L.bits) - 1;
  { the colour map: map_row_size values for each of map_col_size entries }
  mapBytes := 0;
  if mapScheme <> 0 then begin
    case Cardinal(mapStorage) of
      1: bpc := 1;
      2: bpc := 2;
      4, 5: bpc := 4;
      9: bpc := 8;
    else begin L.format := rfNone; Exit(psUnsupported); end;
    end;
    if (F(580) > 65536) or (F(584) > 65536) then begin L.format := rfNone; Exit(psUnsupported); end;
    mapBytes := F(580) * F(584) * bpc;
  end;
  L.dataOffset := 1024 + mapBytes;
  if L.dataOffset > Length(d) then begin L.format := rfNone; Exit(psTruncated); end;
  if bands = 1 then Exit(Finish(d, L));
  { the bands' planes: verbatim, interleaved for the codec (prarle) }
  L.coding := CODING_PLANES;
  Result := SizeRows(L, Length(d) - L.dataOffset);
  if Result <> psOk then L.format := rfNone;
end;

{ ---------- VIPS ---------- }

function ParseVips(const d: TBytes; out L: TRasterLayout): TParseStatus;
var be: Boolean; bands, fmt: Int64;
begin
  L.Clear;
  if Length(d) < 4 then Exit(psNotThis);
  if (d[0] = $08) and (d[1] = $F2) and (d[2] = $A6) and (d[3] = $B6) then be := True
  else if (d[0] = $B6) and (d[1] = $A6) and (d[2] = $F2) and (d[3] = $08) then be := False
  else Exit(psNotThis);
  if Length(d) < 64 then Exit(psMalformed);
  bands := U32(d, 12, be); fmt := U32(d, 20, be);
  if bands < 1 then Exit(psMalformed);
  if U32(d, 24, be) <> 0 then Exit(psUnsupported);   { coded: LabQ, RAD }
  L.format := rfVIPS;
  L.width := U32(d, 4, be); L.height := U32(d, 8, be);
  if bands > MAX_CHANNELS then Exit(psUnsupported);
  L.channels := bands;
  L.bigEndian := be;
  case Cardinal(fmt) of
    0, 1: L.bits := 8;        { unsigned and signed char }
    2, 3: L.bits := 16;       { unsigned and signed short }
    6: begin L.bits := 32; L.isFloat := True; end;
  else begin L.format := rfNone; Exit(psUnsupported); end;   { 32-bit integers, double, complex }
  end;
  if L.isFloat then L.maxval := 0 else L.maxval := (Int64(1) shl L.bits) - 1;
  L.dataOffset := 64;
  Result := Finish(d, L);
end;

{ ---------- DDS ---------- }

function ParseDds(const d: TBytes; out L: TRasterLayout): TParseStatus;
const
  DDPF_FOURCC = $4;
  DDSCAPS2_VOLUME = $200000;
var h, depth, pfFlags, bitCount, m, bytes: Int64; k: Integer;
begin
  L.Clear;
  if (Length(d) < 4) or (d[0] <> Ord('D')) or (d[1] <> Ord('D')) or (d[2] <> Ord('S')) or (d[3] <> 32) then
    Exit(psNotThis);
  if (Length(d) < 128) or (U32LE(d, 4) <> 124) then Exit(psMalformed);
  h := U32LE(d, 12); depth := U32LE(d, 24);
  pfFlags := U32LE(d, 80); bitCount := U32LE(d, 88);
  L.format := rfDDS;
  L.width := U32LE(d, 16); L.bigEndian := False;
  if (pfFlags and DDPF_FOURCC) <> 0 then
    { a Direct3D format number in place of four letters: the wide ones }
    case Cardinal(U32LE(d, 84)) of
      36, 110, 113: begin L.channels := 4; L.bits := 16; end;
      34, 112: begin L.channels := 2; L.bits := 16; end;
      111: begin L.channels := 1; L.bits := 16; end;
      114: begin L.channels := 1; L.bits := 32; L.isFloat := True; end;
      115: begin L.channels := 2; L.bits := 32; L.isFloat := True; end;
      116: begin L.channels := 4; L.bits := 32; L.isFloat := True; end;
    else begin L.format := rfNone; Exit(psUnsupported); end;   { DXT, BC, DX10 }
    end
  else
    case Cardinal(bitCount) of
      8: begin L.channels := 1; L.bits := 8; end;
      16: begin
        { two byte-wide masks (V8U8, A8L8): two channels; else one 16-bit value }
        bytes := 0;
        for k := 0 to 3 do begin
          m := U32LE(d, 92 + 4 * k);
          if (m = $FF) or (m = $FF00) then Inc(bytes) else if m <> 0 then bytes := -8;
        end;
        if bytes = 2 then begin L.channels := 2; L.bits := 8; end
        else begin L.channels := 1; L.bits := 16; end;
      end;
      24: begin L.channels := 3; L.bits := 8; end;
      32: begin L.channels := 4; L.bits := 8; end;
    else begin L.format := rfNone; Exit(psUnsupported); end;
    end;
  { a volume: its slices one under the other }
  if ((U32LE(d, 112) and DDSCAPS2_VOLUME) <> 0) and (depth > 1) then begin
    if (h > 0) and (depth > MAX_DIMENSION div h) then begin L.format := rfNone; Exit(psMalformed); end;
    h := h * depth;
  end;
  L.height := h;
  if L.isFloat then L.maxval := 0 else L.maxval := (Int64(1) shl L.bits) - 1;
  L.dataOffset := 128;
  Result := Finish(d, L);
end;

end.
