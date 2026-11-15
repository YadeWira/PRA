{ Layer 3: the BMP parser (Windows and OS/2 bitmaps, "BM").

  BITMAPFILEHEADER (14 bytes: "BM", size, reserved, the pixels' offset),
  then a DIB header whose size says its version: 12 (OS/2 1.x, 16-bit
  sides), 16 or 64 (OS/2 2.x), 40 (Windows 3), 52, 56, 108 (Windows 4),
  124 (Windows 5). Everything up to the pixels' offset (palette, masks,
  colour profile) is the header, kept as bytes.

  The pixels: |height| rows, each padded to a multiple of 4 bytes, bottom-up
  when the height is positive. Uncompressed (BI_RGB) at 1, 2, 4, 8, 16, 24
  and 32 bits, and BI_BITFIELDS / BI_ALPHABITFIELDS at 16 and 32 bits (the
  masks only say what the bits mean: the bytes are coded as they are).
  - 1, 2, 4, 8 bits: palette indices, one channel;
  - 16 bits: one 16-bit little-endian sample;
  - 24 bits: three 8-bit channels (B, G, R);
  - 32 bits: four 8-bit channels (B, G, R, A or unused).
  RLE8 and RLE4 are run-length coded (prarle: the pixels and the writer's
  choices, given back exactly); JPEG and PNG inside a BMP are
  psUnsupported. }
unit prabmp;

{$I pra.inc}
{$ifopt R-}{$fatal prabmp: range checks ($R+) are mandatory}{$endif}
{$ifopt Q-}{$fatal prabmp: overflow checks ($Q+) are mandatory}{$endif}

interface

uses SysUtils, praraster;

function ParseBmp(const d: TBytes; out L: TRasterLayout): TParseStatus;

implementation

uses pralimits, prarle;

function U16(const d: TBytes; i: SizeInt): Int64;
begin Result := d[i] or (d[i + 1] shl 8); end;

function U32(const d: TBytes; i: SizeInt): Int64;
begin Result := Int64(d[i]) or (Int64(d[i + 1]) shl 8) or (Int64(d[i + 2]) shl 16) or (Int64(d[i + 3]) shl 24); end;

function U32BE(const d: TBytes; i: SizeInt): Int64;
begin Result := (Int64(d[i]) shl 24) or (Int64(d[i + 1]) shl 16) or (Int64(d[i + 2]) shl 8) or Int64(d[i + 3]); end;

function S32(const d: TBytes; i: SizeInt): Int64;
begin
  Result := U32(d, i);
  if Result >= $80000000 then Result := Result - $100000000;
end;

{ A MacBinary header (128 bytes: a zero, the name's length and the name, the
  forks' lengths) before the file: where the file starts, 0 if none }
function MacBinarySkip(const d: TBytes): Int64;
begin
  Result := 0;
  if (Length(d) > 128 + 2) and (d[0] = 0) and (d[1] in [1..63]) and (d[74] = 0) and (d[82] = 0)
     and (U32BE(d, 83) >= 2) and (U32BE(d, 83) <= Length(d) - 128) then Result := 128;
end;

function ParseBmp(const d: TBytes; out L: TRasterLayout): TParseStatus;
var offset, dib, w, h, bpp, comp, used, base, mb, colors, planes, rows: Int64;
begin
  L.Clear;
  { BM, a file header first; after MacBinary's; or a bare DIB (a header
    size first, as a .dib or the clipboard keeps it) }
  mb := MacBinarySkip(d);
  if (Length(d) >= mb + 2) and (d[mb] = Ord('B')) and (d[mb + 1] = Ord('M')) then base := mb + 14
  else if (mb = 0) and (Length(d) >= 40) and ((U32(d, 0) = 40) or (U32(d, 0) = 52) or (U32(d, 0) = 56)
          or (U32(d, 0) = 108) or (U32(d, 0) = 124)) and (U16(d, 12) = 1)
          and (Cardinal(U16(d, 14)) in [1, 4, 8, 16, 24, 32]) and ((U32(d, 16) = 0) or (U32(d, 16) = 3)) then base := 0
  else Exit(psNotThis);
  if Length(d) < base + 12 then Exit(psMalformed);
  dib := U32(d, base);
  case dib of
    12: begin
      w := U16(d, base + 4); h := U16(d, base + 6); bpp := U16(d, base + 10); comp := 0; colors := 0;
    end;
    16, 40, 52, 56, 64, 108, 124: begin
      if Length(d) < base + 16 then Exit(psMalformed);
      w := S32(d, base + 4); h := S32(d, base + 8); bpp := U16(d, base + 14);
      if dib >= 20 then begin
        if Length(d) < base + 20 then Exit(psMalformed);
        comp := U32(d, base + 16);
      end else comp := 0;
      if (dib >= 36) and (Length(d) >= base + 36) then colors := U32(d, base + 32) else colors := 0;
    end;
  else
    Exit(psMalformed);
  end;
  if base > 0 then offset := mb + U32(d, mb + 10)
  else begin
    { a bare DIB: the pixels after the header, its masks (BI_BITFIELDS in a
      40-byte header) and its palette }
    planes := 0;
    if (comp = 3) and (dib = 40) then planes := 12;
    if bpp <= 8 then begin
      if (colors = 0) or (colors > (Int64(1) shl bpp)) then colors := Int64(1) shl bpp;
      planes := planes + 4 * colors;
    end else if colors <= 256 then planes := planes + 4 * colors;
    offset := dib + planes;
  end;
  { the pixels start after the headers, inside the file and within the limit }
  if (offset < base + dib) or (offset > Length(d)) or (offset > MAX_TEXT_HEADER) then Exit(psMalformed);
  if h < 0 then begin h := -h; L.bottomUp := False; end else L.bottomUp := True;
  L.format := rfBMP;
  L.width := w; L.height := h;
  L.bigEndian := False;
  case comp of
    0: ;
    3, 6: if (bpp <> 16) and (bpp <> 32) then Exit(psMalformed);
    1: if bpp <> 8 then Exit(psMalformed);
    2: if bpp <> 4 then Exit(psMalformed);
    4, 5: Exit(psUnsupported);   { JPEG, PNG }
  else
    Exit(psMalformed);
  end;
  case bpp of
    1, 2, 4, 8: begin L.channels := 1; L.bits := bpp; L.maxval := (1 shl bpp) - 1; end;
    16: begin L.channels := 1; L.bits := 16; L.maxval := 65535; end;
    24: begin L.channels := 3; L.bits := 8; L.maxval := 255; end;
    32: begin L.channels := 4; L.bits := 8; L.maxval := 255; end;
  else
    Exit(psMalformed);
  end;
  L.dataOffset := offset;
  if comp in [1, 2] then begin
    { run-length coded (prarle): bottom-up only; the tokens' length }
    if not L.bottomUp then begin L.format := rfNone; Exit(psMalformed); end;
    L.coding := CODING_BMP_RLE;
    Result := SizeRows(L, High(Int64) shr 2);
    if Result = psOk then Result := BmpRleLength(d, offset, w, h, bpp, used);
    if Result <> psOk then begin L.format := rfNone; Exit; end;
    L.dataLength := used;
    Exit(psOk);
  end;
  Result := SizeRows(L, Length(d) - offset);
  { cut short: the rows that are there are the image, what is left of the
    last one its tail }
  if (Result = psTruncated) and (L.rowBytes > 0) then begin
    rows := (Length(d) - offset) div L.rowBytes;
    if rows >= 1 then begin
      L.height := rows;
      Result := SizeRows(L, Length(d) - offset);
    end;
  end;
  if Result <> psOk then L.format := rfNone;
end;

end.
