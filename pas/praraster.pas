{ Layer 3: what a raster parser says about a file.

  A parser does not convert anything: it finds where the pixel data is and
  describes how it is laid out. The file is then three consecutive parts,

      header  [0, dataOffset)                      kept as bytes
      pixels  [dataOffset, dataOffset + dataLength) modelled by the codec
      tail    [dataOffset + dataLength, end)        kept as bytes

  so rebuilding the file is concatenating the three again. This is what makes
  a parser's mistake harmless for exactness: a wrong offset or a wrong
  layout only costs compression, never a byte of the original.

  The pixel part is `height` rows of `rowBytes` bytes each; a row holds
  `width` pixels of `channels` samples of `bits` bits, interleaved, packed
  most significant bit first when bits < 8, and whatever is left over at the
  end of the row (padding bits or bytes) is part of the row too.

  A Radiance HDR file's pixels are run-length coded: for it, dataLength is
  the coded scanlines' length, and the codec decodes them (prahdr). }
unit praraster;

{$I pra.inc}
{$ifopt R-}{$fatal praraster: range checks ($R+) are mandatory}{$endif}
{$ifopt Q-}{$fatal praraster: overflow checks ($Q+) are mandatory}{$endif}

interface

uses SysUtils;

type
  { new formats go at the end: the stream keeps their number }
  TRasterFormat = (rfNone, rfPBM, rfPGM, rfPPM, rfPAM, rfPFM, rfBMP, rfHDR,
    rfFarbfeld, rfTGA, rfSUN, rfWBMP, rfPCX, rfSGI);

  TParseStatus = (
    psOk,
    psNotThis,       { not this parser's format: try the next one }
    psMalformed,     { looks like it, but the header is broken }
    psTruncated,     { the header promises more pixel data than the file has }
    psUnsupported);  { a valid variant this version does not handle }

const
  { how the file stores its pixels: as they are, or run-length coded
    (dataLength is then the coded length, and the codec decodes them) }
  CODING_RAW = 0;
  CODING_HDR = 1;       { Radiance's scanlines (prahdr) }
  CODING_TGA_RLE = 2;   { TGA types 9, 10, 11 (prarle) }
  CODING_SUN_RLE = 3;   { Sun Raster type 2 (prarle) }
  CODING_PCX = 4;       { PCX (prarle, its planes: praother) }
  CODING_SGI_RLE = 5;   { SGI run-length (prarle) }
  CODING_SGI_RAW = 6;   { SGI verbatim: planes, interleaved for the codec (prarle) }

type
  TRasterLayout = record
    format: TRasterFormat;
    width, height: Int64;         { pixels }
    channels: Integer;            { samples per pixel }
    bits: Integer;                { per sample: 1, 8, 16 or 32 }
    maxval: Int64;                { the format's declared maximum (a hint: samples may exceed it) }
    bigEndian: Boolean;           { for bits > 8 }
    isFloat: Boolean;             { 32-bit IEEE samples }
    bottomUp: Boolean;            { the first row is the image's bottom }
    rowBytes: Int64;
    dataOffset, dataLength: Int64;
    coding: Integer;
    procedure Clear;
  end;

function FormatName(f: TRasterFormat): string;
function StatusName(s: TParseStatus): string;

{ rowBytes and dataLength from width, channels and bits; psTruncated if the
  pixels do not fit in the `available` bytes after dataOffset. Never
  overflows: every product is checked against `available` first. }
function SizeRows(var L: TRasterLayout; available: Int64): TParseStatus;

implementation

uses pralimits;

procedure TRasterLayout.Clear;
begin
  format := rfNone; width := 0; height := 0; channels := 0; bits := 0; maxval := 0;
  bigEndian := True; isFloat := False; bottomUp := False;
  rowBytes := 0; dataOffset := 0; dataLength := 0; coding := CODING_RAW;
end;

function FormatName(f: TRasterFormat): string;
begin
  case f of
    rfPBM: Result := 'PBM';
    rfPGM: Result := 'PGM';
    rfPPM: Result := 'PPM';
    rfPAM: Result := 'PAM';
    rfPFM: Result := 'PFM';
    rfBMP: Result := 'BMP';
    rfHDR: Result := 'HDR';
    rfFarbfeld: Result := 'farbfeld';
    rfTGA: Result := 'TGA';
    rfSUN: Result := 'Sun Raster';
    rfWBMP: Result := 'WBMP';
    rfPCX: Result := 'PCX';
    rfSGI: Result := 'SGI';
  else Result := 'none';
  end;
end;

function StatusName(s: TParseStatus): string;
begin
  case s of
    psOk: Result := 'ok';
    psNotThis: Result := 'not this format';
    psMalformed: Result := 'malformed header';
    psTruncated: Result := 'truncated pixel data';
  else Result := 'unsupported variant';
  end;
end;

function SizeRows(var L: TRasterLayout; available: Int64): TParseStatus;
var bitsPerRow: Int64;
begin
  if (L.width < 1) or (L.height < 1) or (L.width > MAX_DIMENSION) or (L.height > MAX_DIMENSION)
     or (L.channels < 1) or (L.channels > MAX_CHANNELS) or (L.bits < 1) or (L.bits > 32) then Exit(psMalformed);
  { width <= 2^24, channels <= 2^8, bits <= 32: at most 2^37, no overflow }
  bitsPerRow := L.width * L.channels * L.bits;
  { rows padded: BMP to 4 bytes, Sun Raster to 2 }
  case L.format of
    rfBMP: L.rowBytes := ((bitsPerRow + 31) div 32) * 4;   { 4 bytes }
    rfSUN: L.rowBytes := ((bitsPerRow + 15) div 16) * 2;   { 2 bytes }
  else L.rowBytes := (bitsPerRow + 7) div 8;
  end;
  if (available < L.rowBytes) or (L.height > available div L.rowBytes) then Exit(psTruncated);
  L.dataLength := L.rowBytes * L.height;
  Result := psOk;
end;

end.
