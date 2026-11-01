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
  RLE4, RLE8, JPEG and PNG inside a BMP are psUnsupported. }
unit prabmp;

{$I pra.inc}
{$ifopt R-}{$fatal prabmp: range checks ($R+) are mandatory}{$endif}
{$ifopt Q-}{$fatal prabmp: overflow checks ($Q+) are mandatory}{$endif}

interface

uses SysUtils, praraster;

function ParseBmp(const d: TBytes; out L: TRasterLayout): TParseStatus;

implementation

uses pralimits;

function U16(const d: TBytes; i: SizeInt): Int64;
begin Result := d[i] or (d[i + 1] shl 8); end;

function U32(const d: TBytes; i: SizeInt): Int64;
begin Result := Int64(d[i]) or (Int64(d[i + 1]) shl 8) or (Int64(d[i + 2]) shl 16) or (Int64(d[i + 3]) shl 24); end;

function S32(const d: TBytes; i: SizeInt): Int64;
begin
  Result := U32(d, i);
  if Result >= $80000000 then Result := Result - $100000000;
end;

function ParseBmp(const d: TBytes; out L: TRasterLayout): TParseStatus;
var offset, dib, w, h, bpp, comp: Int64;
begin
  L.Clear;
  if (Length(d) < 2) or (d[0] <> Ord('B')) or (d[1] <> Ord('M')) then Exit(psNotThis);
  if Length(d) < 26 then Exit(psMalformed);
  offset := U32(d, 10);
  dib := U32(d, 14);
  case dib of
    12: begin
      w := U16(d, 18); h := U16(d, 20); bpp := U16(d, 24); comp := 0;
    end;
    16, 40, 52, 56, 64, 108, 124: begin
      if Length(d) < 14 + 16 then Exit(psMalformed);
      w := S32(d, 18); h := S32(d, 22); bpp := U16(d, 28);
      if dib >= 20 then begin
        if Length(d) < 14 + 20 then Exit(psMalformed);
        comp := U32(d, 30);
      end else comp := 0;
    end;
  else
    Exit(psMalformed);
  end;
  { the pixels start after the headers, inside the file and within the limit }
  if (offset < 14 + dib) or (offset > Length(d)) or (offset > MAX_TEXT_HEADER) then Exit(psMalformed);
  if h < 0 then begin h := -h; L.bottomUp := False; end else L.bottomUp := True;
  L.format := rfBMP;
  L.width := w; L.height := h;
  L.bigEndian := False;
  case comp of
    0: ;
    3, 6: if (bpp <> 16) and (bpp <> 32) then Exit(psMalformed);
    1, 2, 4, 5: Exit(psUnsupported);   { RLE8, RLE4, JPEG, PNG }
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
  Result := SizeRows(L, Length(d) - offset);
  if Result <> psOk then L.format := rfNone;
end;

end.
