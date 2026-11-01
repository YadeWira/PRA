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
  - WBMP type 0: two zero bytes, width and height as multi-byte integers
    (7 bits a byte, the high bit set on all but the last), then 1-bit rows
    padded to a byte. }
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

end.
