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
    (a pad byte, then the three). The run-length type (2) is psUnsupported
    here.
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

implementation

uses pralimits, prarle;

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
var w, h, depth, rtype, maptype, maplen: Int64;
begin
  L.Clear;
  if (Length(d) < 4) or (U32BE(d, 0) <> $59A66A95) then Exit(psNotThis);
  if Length(d) < 32 then Exit(psMalformed);
  w := U32BE(d, 4); h := U32BE(d, 8); depth := U32BE(d, 12);
  rtype := U32BE(d, 20); maptype := U32BE(d, 24); maplen := U32BE(d, 28);
  if maptype > 2 then Exit(psMalformed);
  if maplen > MAX_TEXT_HEADER then Exit(psUnsupported);
  case rtype of
    0, 1, 3: ;
    2: Exit(psUnsupported);        { run-length coded }
  else Exit(psUnsupported);        { TIFF, IFF, experimental }
  end;
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

end.
