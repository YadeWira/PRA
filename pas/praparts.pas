{ Layer 3: files of several images. A file is cut into parts, one after the
  other: images (each coded as a file of its own, its header and tail
  included) and bytes between them (the byte model). Rebuilding the file is
  joining the parts again, so, as with a parser, a wrong cut costs only
  compression.

  - Netpbm: images one after the other (PBM, PGM, PPM, PAM, PFM), as
    netpbm writes several.
  - DCX: a table of up to 1023 offsets (magic B1 68 DE 3A), then PCX files;
    each is cut where the next begins.
  - ICO and CUR: a directory of 16-byte entries, then each image: a PNG
    (kept as bytes) or a DIB without its file header, whose height counts
    twice (a BITMAPINFOHEADER, or OS/2's BITMAPCOREHEADER): the colours,
    then the AND mask (1 bit a pixel, rows of 4 bytes): two images.
  - DDS: the main surface, then its mipmaps, each half as wide and as high
    (and deep, for a volume), then the same for each other face of a cube
    map: each an image without a header.

  A part that is not an image PRA can code becomes bytes: a file of several
  images never fails as a whole. }
unit praparts;

{$I pra.inc}
{$ifopt R-}{$fatal praparts: range checks ($R+) are mandatory}{$endif}
{$ifopt Q-}{$fatal praparts: overflow checks ($Q+) are mandatory}{$endif}

interface

uses SysUtils, praraster;

type
  TPartKind = (pkBytes, pkImage);

  TPart = record
    kind: TPartKind;
    first, len: Int64;             { where it is in the file }
    L: TRasterLayout;              { pkImage: its layout, offsets from first }
  end;
  TParts = array of TPart;

{ The parts of a file of several images, and the file's format (rfICO,
  rfCUR, rfDCX, or its images' own). False when it is not one: then
  `st` and `L`, what ParseAny said of the whole file, stand. }
function SplitFile(const d: TBytes; st: TParseStatus; const L: TRasterLayout;
                   out parts: TParts; out fmt: TRasterFormat): Boolean;

implementation

uses Math, prapnm, praother;

const
  MAX_PARTS = 1 shl 16;

function U16LE(const d: TBytes; i: SizeInt): Int64;
begin Result := d[i] or (d[i + 1] shl 8); end;

function U32LE(const d: TBytes; i: SizeInt): Int64;
begin Result := (Int64(d[i + 3]) shl 24) or (Int64(d[i + 2]) shl 16) or (Int64(d[i + 1]) shl 8) or Int64(d[i]); end;

function S32LE(const d: TBytes; i: SizeInt): Int64;
begin
  Result := U32LE(d, i);
  if Result >= $80000000 then Result := Result - $100000000;
end;

procedure AddBytes(var parts: TParts; first, len: Int64);
var n: Integer;
begin
  if len <= 0 then Exit;
  n := Length(parts);
  { two byte parts in a row are one }
  if (n > 0) and (parts[n - 1].kind = pkBytes) and (parts[n - 1].first + parts[n - 1].len = first) then begin
    Inc(parts[n - 1].len, len); Exit;
  end;
  SetLength(parts, n + 1);
  parts[n].kind := pkBytes; parts[n].first := first; parts[n].len := len;
  parts[n].L.Clear;
end;

procedure AddImage(var parts: TParts; first, len: Int64; const L: TRasterLayout);
var n: Integer;
begin
  n := Length(parts);
  SetLength(parts, n + 1);
  parts[n].kind := pkImage; parts[n].first := first; parts[n].len := len;
  parts[n].L := L;
end;

{ ---------- Netpbm: one image after another ---------- }

function SplitPnm(const d: TBytes; const L0: TRasterLayout; var parts: TParts): Boolean;
var p, e: Int64; L: TRasterLayout;
begin
  e := L0.dataOffset + L0.dataLength;
  AddImage(parts, 0, e, L0);
  p := e;
  while (p < Length(d)) and (Length(parts) < MAX_PARTS) do begin
    if ParsePnm(Copy(d, p, Length(d) - p), L) <> psOk then Break;
    e := L.dataOffset + L.dataLength;
    AddImage(parts, p, e, L);
    Inc(p, e);
  end;
  AddBytes(parts, p, Length(d) - p);
  Result := Length(parts) > 1;
end;

{ ---------- DCX: PCX files at the offsets of a table ---------- }

function SplitDcx(const d: TBytes; var parts: TParts): Boolean;
var n, k: Integer; off: array of Int64; e: Int64; L: TRasterLayout;
begin
  Result := False;
  if (Length(d) < 8) or (U32LE(d, 0) <> $3ADE68B1) then Exit;
  off := nil; n := 0;
  while (n < 1023) and (8 + 4 * n <= Length(d)) and (U32LE(d, 4 + 4 * n) <> 0) do begin
    SetLength(off, n + 1);
    off[n] := U32LE(d, 4 + 4 * n);
    { after the table, in order, inside the file }
    if (off[n] < 8 + 4 * n) or (off[n] >= Length(d)) or ((n > 0) and (off[n] <= off[n - 1])) then Exit;
    Inc(n);
  end;
  if n = 0 then Exit;
  AddBytes(parts, 0, off[0]);
  for k := 0 to n - 1 do begin
    if k < n - 1 then e := off[k + 1] else e := Length(d);
    if ParsePcx(Copy(d, off[k], e - off[k]), L) = psOk then AddImage(parts, off[k], e - off[k], L)
    else AddBytes(parts, off[k], e - off[k]);
  end;
  Result := True;
end;

{ ---------- ICO, CUR: a directory, then DIBs and PNGs ---------- }

{ a DIB at d[first..first+size): its colours and its AND mask as images }
procedure SplitDib(const d: TBytes; first, size: Int64; var parts: TParts);
var hs, w, h2, bpp, comp, colours, entry, pal, maskLen, used: Int64; L, M: TRasterLayout;
begin
  used := 0;
  if size >= 12 then begin
    hs := U32LE(d, first);
    { BITMAPINFOHEADER (40 bytes, 4-byte colours) or BITMAPCOREHEADER (12, 3-byte) }
    if (hs = 40) and (size >= 40) then begin
      w := S32LE(d, first + 4); h2 := S32LE(d, first + 8); bpp := U16LE(d, first + 14);
      comp := U32LE(d, first + 16); colours := U32LE(d, first + 32); entry := 4;
    end else if hs = 12 then begin
      w := U16LE(d, first + 4); h2 := U16LE(d, first + 6); bpp := U16LE(d, first + 10);
      comp := 0; colours := 0; entry := 3;
    end else comp := -1;
    if (comp = 0) and (w > 0) and (h2 > 0) and not Odd(h2)
       and (bpp in [1, 4, 8, 16, 24, 32]) and (colours <= 256) then begin
      L.Clear;
      L.format := rfBMP; L.width := w; L.height := h2 div 2; L.bigEndian := False; L.bottomUp := True;
      case bpp of
        1, 4, 8, 16: begin L.channels := 1; L.bits := bpp; end;
        24: begin L.channels := 3; L.bits := 8; end;
        32: begin L.channels := 4; L.bits := 8; end;
      end;
      L.maxval := (Int64(1) shl L.bits) - 1;
      pal := 0;
      if bpp <= 8 then begin
        if colours = 0 then colours := Int64(1) shl bpp;
        pal := entry * colours;
      end;
      L.dataOffset := hs + pal;
      if (L.dataOffset <= size) and (SizeRows(L, size - L.dataOffset) = psOk) then begin
        used := L.dataOffset + L.dataLength;
        AddImage(parts, first, used, L);
        { the AND mask: 1 bit a pixel, rows of 4 bytes, as a BMP's }
        M := L;
        M.channels := 1; M.bits := 1; M.maxval := 1; M.dataOffset := 0;
        if SizeRows(M, size - used) = psOk then begin
          maskLen := M.dataLength;
          AddImage(parts, first + used, maskLen, M);
          Inc(used, maskLen);
        end;
      end;
    end;
  end;
  AddBytes(parts, first + used, size - used);
end;

function SplitIco(const d: TBytes; var parts: TParts; out fmt: TRasterFormat): Boolean;
var n, k, j: Integer; off, size: array of Int64; t, p: Int64;
begin
  Result := False; fmt := rfNone;
  if (Length(d) < 6) or (d[0] <> 0) or (d[1] <> 0) or not (d[2] in [1, 2]) or (d[3] <> 0) then Exit;
  n := U16LE(d, 4);
  if (n = 0) or (6 + 16 * n > Length(d)) then Exit;
  off := nil; size := nil; SetLength(off, n); SetLength(size, n);
  for k := 0 to n - 1 do begin
    size[k] := U32LE(d, 6 + 16 * k + 8); off[k] := U32LE(d, 6 + 16 * k + 12);
    if (off[k] < 6 + 16 * n) or (size[k] < 1) or (off[k] > Length(d) - size[k]) then Exit;
  end;
  { by offset (a directory is seldom out of order), and apart }
  for k := 1 to n - 1 do begin
    j := k;
    while (j > 0) and (off[j - 1] > off[j]) do begin
      t := off[j]; off[j] := off[j - 1]; off[j - 1] := t;
      t := size[j]; size[j] := size[j - 1]; size[j - 1] := t;
      Dec(j);
    end;
  end;
  for k := 1 to n - 1 do if off[k] < off[k - 1] + size[k - 1] then Exit;
  if d[2] = 1 then fmt := rfICO else fmt := rfCUR;
  p := 6 + 16 * n;
  AddBytes(parts, 0, p);
  for k := 0 to n - 1 do begin
    AddBytes(parts, p, off[k] - p);
    { a PNG stays as it is }
    if (size[k] >= 8) and (d[off[k]] = $89) and (d[off[k] + 1] = Ord('P')) and (d[off[k] + 2] = Ord('N'))
       and (d[off[k] + 3] = Ord('G')) then AddBytes(parts, off[k], size[k])
    else SplitDib(d, off[k], size[k], parts);
    p := off[k] + size[k];
  end;
  AddBytes(parts, p, Length(d) - p);
  Result := True;
end;

{ ---------- DDS: mipmaps and faces after the main surface ---------- }

function SplitDds(const d: TBytes; const L0: TRasterLayout; var parts: TParts): Boolean;
const
  DDSD_MIPMAPCOUNT = $20000;
  DDSCAPS2_CUBEMAP = $200;
  DDSCAPS2_VOLUME = $200000;
var
  mips, faces, f, k, bpp: Integer; w, h, dp, caps2, p, len: Int64; M: TRasterLayout;
begin
  Result := False;
  mips := 1;
  if (U32LE(d, 8) and DDSD_MIPMAPCOUNT) <> 0 then begin
    mips := Integer(Min(U32LE(d, 28), 32));
    if mips < 1 then mips := 1;
  end;
  caps2 := U32LE(d, 112);
  faces := 1;
  if (caps2 and DDSCAPS2_CUBEMAP) <> 0 then begin
    faces := 0;
    for k := 10 to 15 do if ((caps2 shr k) and 1) <> 0 then Inc(faces);
    if faces = 0 then faces := 1;
  end;
  if (mips = 1) and (faces = 1) then Exit;
  dp := 1;
  if ((caps2 and DDSCAPS2_VOLUME) <> 0) and (U32LE(d, 24) > 1) then dp := U32LE(d, 24);
  bpp := L0.channels * L0.bits div 8;
  p := L0.dataOffset + L0.dataLength;
  AddImage(parts, 0, p, L0);
  for f := 0 to faces - 1 do
    for k := 0 to mips - 1 do begin
      if (f = 0) and (k = 0) then Continue;
      w := Max(1, L0.width shr k);
      h := Max(1, (L0.height div dp) shr k);
      M := L0;
      M.width := w; M.height := h * Max(1, dp shr k); M.dataOffset := 0;
      if (SizeRows(M, Length(d) - p) <> psOk) or (Length(parts) >= MAX_PARTS) then begin
        AddBytes(parts, p, Length(d) - p);
        Exit(True);
      end;
      len := M.dataLength;
      if len <> M.width * M.height * bpp then begin AddBytes(parts, p, Length(d) - p); Exit(True); end;
      AddImage(parts, p, len, M);
      Inc(p, len);
    end;
  AddBytes(parts, p, Length(d) - p);
  Result := True;
end;

function SplitFile(const d: TBytes; st: TParseStatus; const L: TRasterLayout;
                   out parts: TParts; out fmt: TRasterFormat): Boolean;
begin
  parts := nil; fmt := rfNone; Result := False;
  if st = psOk then begin
    fmt := L.format;
    case L.format of
      rfPBM, rfPGM, rfPPM, rfPAM, rfPFM:
        if L.dataOffset + L.dataLength < Length(d) then Result := SplitPnm(d, L, parts);
      rfDDS:
        if L.dataOffset + L.dataLength < Length(d) then Result := SplitDds(d, L, parts);
    end;
    if not Result then parts := nil;
    Exit;
  end;
  if SplitDcx(d, parts) then begin fmt := rfDCX; Exit(True); end;
  parts := nil;
  if SplitIco(d, parts, fmt) then Exit(True);
  parts := nil; fmt := rfNone;
end;

end.
