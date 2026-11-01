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

  - TIFF and BigTIFF: each image file directory's strips or tiles,
    uncompressed or PackBits, as images (strips that follow each other
    joined into one, tiles stacked into one as wide as a tile); the header,
    the directories, anything else, bytes.
  - PSD and PSB: each layer's channels and the composite image, raw or
    PackBits (its table of row lengths kept as bytes), each an image (the
    composite's channels interleaved); the rest, bytes.

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

uses Math, pralimits, prapnm, praother, prarle;

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


{ ---------- TIFF, BigTIFF: strips and tiles ---------- }

type
  TTiffRegion = record
    first, len: Int64;
    L: TRasterLayout;
    joinable: Boolean;      { rows that continue the region before (same image, plane) }
    key: Integer;           { which image and plane }
  end;
  TTiffRegions = array of TTiffRegion;
  TInt64Array = array of Int64;

  TTiffReader = record
    d: TBytes;
    be, big: Boolean;
    function U(p: Int64; size: Integer): Int64;
  end;

function TTiffReader.U(p: Int64; size: Integer): Int64;
var k: Integer;
begin
  Result := 0;
  if (p < 0) or (p + size > Length(d)) then Exit(-1);
  if be then for k := 0 to size - 1 do Result := (Result shl 8) or d[p + k]
  else for k := size - 1 downto 0 do Result := (Result shl 8) or d[p + k];
  if Result < 0 then Result := -1;            { a 64-bit value past Int64: none }
end;

const
  MAX_TIFF_VALUES = 1 shl 20;

{ a tag's values (SHORT, LONG, LONG8): the entry at e }
function TagValues(var t: TTiffReader; e: Int64; out vals: TInt64Array): Boolean;
var typ, cnt, sz, at: Int64; inl, k: Integer;
begin
  vals := nil; Result := False;
  typ := t.U(e + 2, 2);
  if t.big then begin cnt := t.U(e + 4, 8); inl := 8; at := e + 12; end
  else begin cnt := t.U(e + 4, 4); inl := 4; at := e + 8; end;
  case typ of
    3: sz := 2;
    4: sz := 4;
    16: sz := 8;
  else Exit;
  end;
  if (cnt < 1) or (cnt > MAX_TIFF_VALUES) then Exit;
  if cnt * sz > inl then at := t.U(at, inl);
  if (at < 0) or (at + cnt * sz > Length(t.d)) then Exit;
  SetLength(vals, cnt);
  for k := 0 to cnt - 1 do vals[k] := t.U(at + k * sz, sz);
  Result := True;
end;

{ one directory's strips or tiles into regions; False if it has none PRA
  takes (its data then stays bytes) }
procedure TiffImage(var t: TTiffReader; ifd: Int64; key: Integer; var regs: TTiffRegions);
var
  n, e, es, tag: Int64; k, i, idx: Integer; vals: TInt64Array;
  w, h, spp, bps, comp, planar, rps, tw, th, fmt: Int64;
  offs, cnts: TInt64Array; tiled: Boolean;
  planes, per, across, down, plane: Int64; L: TRasterLayout; rows, need, used: Int64; R: TTiffRegion;
begin
  w := -1; h := -1; spp := 1; bps := 1; comp := 1; planar := 1; rps := -1; tw := -1; th := -1; fmt := 1;
  offs := nil; cnts := nil; tiled := False;
  if t.big then begin n := t.U(ifd, 8); es := 20; e := ifd + 8; end
  else begin n := t.U(ifd, 2); es := 12; e := ifd + 2; end;
  if (n < 1) or (n > 4096) then Exit;
  for k := 0 to n - 1 do begin
    tag := t.U(e + k * es, 2);
    if tag < 0 then Exit;
    case Integer(tag) of
      256, 257, 258, 259, 277, 278, 284, 322, 323, 339: begin
        if not TagValues(t, e + k * es, vals) then Continue;
        case Integer(tag) of
          256: w := vals[0];
          257: h := vals[0];
          258: begin bps := vals[0]; for i := 1 to High(vals) do if vals[i] <> bps then Exit; end;
          259: comp := vals[0];
          277: spp := vals[0];
          278: rps := vals[0];
          284: planar := vals[0];
          322: tw := vals[0];
          323: th := vals[0];
          339: begin fmt := vals[0]; for i := 1 to High(vals) do if vals[i] <> fmt then Exit; end;
        end;
      end;
      273, 324: if not TagValues(t, e + k * es, offs) then Exit;
      279, 325: if not TagValues(t, e + k * es, cnts) then Exit;
    end;
  end;
  { tiles: TileWidth and TileLength say so, whichever tag the offsets are in
    (some writers put tiles in StripOffsets) }
  tiled := (tw > 0) and (th > 0);
  if (comp <> 1) and (comp <> 32773) then Exit;
  if (w < 1) or (h < 1) or (w > MAX_DIMENSION) or (h > MAX_DIMENSION) or (spp < 1) or (spp > 16) then Exit;
  { no byte counts (old writers): each strip as long as its pixels make it }
  if (offs = nil) or ((cnts <> nil) and (Length(offs) <> Length(cnts))) then Exit;
  if cnts = nil then begin
    SetLength(cnts, Length(offs));
    for k := 0 to High(cnts) do cnts[k] := Length(t.d) - Max(0, Min(offs[k], Length(t.d)));
  end;
  { the samples: chunky (all in a pixel) or planar (a plane each) }
  L.Clear;
  L.format := rfTIFF; L.bigEndian := t.be;
  if planar = 2 then begin planes := spp; L.channels := 1; end
  else begin planes := 1; L.channels := spp; end;
  { samples of under 8 bits in a pixel that fills 1, 2, 4 or 8 bits: one
    sample of them all }
  if (bps < 8) and (L.channels > 1) and (L.channels * bps in [2, 4, 8]) then begin
    bps := L.channels * bps; L.channels := 1;
  end;
  case Integer(Min(bps, 64)) of
    1, 2, 4: if L.channels <> 1 then Exit else L.bits := bps;
    8: L.bits := 8;
    16: if (fmt = 1) or (fmt = 2) then L.bits := 16 else Exit;
    32: if fmt = 3 then begin L.bits := 32; L.isFloat := True; end else Exit;
  else Exit;
  end;
  if L.isFloat then L.maxval := 0 else L.maxval := (Int64(1) shl L.bits) - 1;
  if tiled then begin
    if (tw < 1) or (th < 1) or (tw > MAX_DIMENSION) or (th > MAX_DIMENSION) then Exit;
    across := (w + tw - 1) div tw; down := (h + th - 1) div th;
    per := across * down;
  end else begin
    if (rps < 1) or (rps > h) then rps := h;
    per := (h + rps - 1) div rps;
  end;
  if per * planes <> Length(offs) then Exit;
  for idx := 0 to Length(offs) - 1 do begin
    plane := idx div per; i := idx mod per;
    if tiled then begin L.width := tw; rows := th; end
    else begin
      L.width := w; rows := rps;
        if (Int64(i) + 1) * rps > h then rows := h - Int64(i) * rps;
    end;
    L.height := rows; L.dataOffset := 0;
    if SizeRows(L, High(Int64) shr 2) <> psOk then Exit;
    need := L.dataLength;
    R.first := offs[idx]; R.L := L; R.key := key * 64 + Integer(plane);
    { strips of one image continue each other; tiles stack, one under the
      other, into an image as wide as a tile: one model for them all }
    R.joinable := i > 0;
    if comp = 1 then begin
      { uncompressed: the rows; a strip longer than its rows keeps the rest as bytes }
      if (cnts[idx] < need) or (R.first < 0) or (R.first + need > Length(t.d)) then Continue;
      R.len := need;
    end else begin
      if (R.first < 0) or (R.first > Length(t.d)) or (cnts[idx] < 1) or (cnts[idx] > Length(t.d) - R.first) then Continue;
      if PackBitsLength(t.d, R.first, need, used) <> psOk then Continue;
      R.len := used;
      R.L.coding := CODING_PACKBITS;
    end;
    R.L.dataLength := R.len;
    SetLength(regs, Length(regs) + 1);
    regs[High(regs)] := R;
  end;
end;

function SplitTiff(const d: TBytes; var parts: TParts): Boolean;
var
  t: TTiffReader; ifd, p, next: Int64; count, k, j, m: Integer; regs: TTiffRegions; tmp: TTiffRegion;
  seen: array of Int64; loop: Boolean; L: TRasterLayout;
begin
  Result := False;
  if Length(d) < 8 then Exit;
  if (d[0] = Ord('I')) and (d[1] = Ord('I')) then t.be := False
  else if (d[0] = Ord('M')) and (d[1] = Ord('M')) then t.be := True
  else Exit;
  t.d := d;
  case Integer(t.U(2, 2)) of
    42: begin t.big := False; ifd := t.U(4, 4); end;
    43: begin
      if (Length(d) < 16) or (t.U(4, 2) <> 8) then Exit;
      t.big := True; ifd := t.U(8, 8);
    end;
  else Exit;
  end;
  regs := nil; seen := nil; count := 0;
  while (ifd >= 8) and (ifd < Length(d)) and (count < 64) do begin
    loop := False;
    for k := 0 to High(seen) do if seen[k] = ifd then loop := True;
    if loop then Break;
    SetLength(seen, Length(seen) + 1); seen[High(seen)] := ifd;
    TiffImage(t, ifd, count, regs);
    { the next directory }
    if t.big then begin
      p := t.U(ifd, 8); if (p < 0) or (p > Length(d)) then Break;
      next := t.U(ifd + 8 + p * 20, 8);
    end else begin
      p := t.U(ifd, 2); if p < 0 then Break;
      next := t.U(ifd + 2 + p * 12, 4);
    end;
    if next <= 0 then Break;
    ifd := next; Inc(count);
  end;
  if regs = nil then Exit;
  { by offset, and apart }
  for k := 1 to High(regs) do begin
    j := k; tmp := regs[k];
    while (j > 0) and (regs[j - 1].first > tmp.first) do begin regs[j] := regs[j - 1]; Dec(j); end;
    regs[j] := tmp;
  end;
  for k := 1 to High(regs) do if regs[k].first < regs[k - 1].first + regs[k - 1].len then Exit;
  { rows of one image (and plane) that follow each other: one region }
  m := 0;
  for k := 1 to High(regs) do
    if regs[k].joinable and (regs[k].key = regs[m].key) and (regs[k].first = regs[m].first + regs[m].len)
       and (regs[k].L.coding = regs[m].L.coding) and (regs[k].L.width = regs[m].L.width)
       and (regs[m].L.height + regs[k].L.height <= MAX_DIMENSION) then begin
      Inc(regs[m].len, regs[k].len);
      Inc(regs[m].L.height, regs[k].L.height);
      regs[m].L.dataLength := regs[m].len;
    end else begin
      Inc(m); regs[m] := regs[k];
    end;
  SetLength(regs, m + 1);
  p := 0;
  for k := 0 to High(regs) do begin
    if Length(parts) >= MAX_PARTS - 2 then Break;
    AddBytes(parts, p, regs[k].first - p);
    L := regs[k].L;
    AddImage(parts, regs[k].first, regs[k].len, L);
    p := regs[k].first + regs[k].len;
  end;
  AddBytes(parts, p, Length(d) - p);
  Result := True;
end;

{ ---------- PSD, PSB: layers' channels, the composite ---------- }

function U16BE(const d: TBytes; i: Int64): Int64;
begin
  if (i < 0) or (i + 2 > Length(d)) then Exit(-1);
  Result := (d[i] shl 8) or d[i + 1];
end;

function U32BE(const d: TBytes; i: Int64): Int64;
begin
  if (i < 0) or (i + 4 > Length(d)) then Exit(-1);
  Result := (Int64(d[i]) shl 24) or (Int64(d[i + 1]) shl 16) or (Int64(d[i + 2]) shl 8) or d[i + 3];
end;

function S32BE(const d: TBytes; i: Int64): Int64;
begin
  Result := U32BE(d, i);
  if Result >= $80000000 then Result := Result - $100000000;
end;

function U64BE(const d: TBytes; i: Int64): Int64;
var hi: Int64;
begin
  hi := U32BE(d, i);
  if (hi < 0) or (hi >= $80000000) then Exit(-1);
  Result := (hi shl 32) or U32BE(d, i + 4);
end;

type
  TPsd = record
    big: Boolean;            { PSB: 8-byte lengths, 4-byte row counts }
    bits: Integer;
  end;

function PsdLayout(const x: TPsd; w, h: Int64; ch: Integer; out L: TRasterLayout): Boolean;
begin
  L.Clear;
  L.format := rfPSD; L.width := w; L.height := h; L.channels := ch; L.bigEndian := True;
  case x.bits of
    1, 8, 16: L.bits := x.bits;
    32: begin L.bits := 32; L.isFloat := True; end;
  end;
  if L.isFloat then L.maxval := 0 else L.maxval := (Int64(1) shl L.bits) - 1;
  Result := (w >= 1) and (h >= 1) and (w <= MAX_DIMENSION) and (h <= MAX_DIMENSION)
    and (SizeRows(L, High(Int64) shr 2) = psOk);
end;

{ the planes of rows at d[q..q+len): a compression word, then the rows as
  they are or PackBits after a table of the rows' lengths. False if they
  are not that (they stay bytes). }
function PsdPlanes(const d: TBytes; const x: TPsd; q, len, w, rows: Int64; ch: Integer; var parts: TParts): Boolean;
var comp, tbl, used: Int64; L: TRasterLayout;
begin
  Result := False;
  { several channels (the composite): interleaved for the model, planes in
    the file; 1-bit planes stay one under the other }
  if (ch > 1) and (x.bits in [1, 32]) then begin
    if rows > MAX_DIMENSION div ch then Exit;
    rows := rows * ch; ch := 1;
  end;
  if (len < 2) or (q + len > Length(d)) or not PsdLayout(x, w, rows, ch, L) then Exit;
  if ch > 1 then L.coding := CODING_PLANES;
  comp := U16BE(d, q);
  case comp of
    0: begin
      if len - 2 <> L.dataLength then Exit;
      AddBytes(parts, q, 2);
      AddImage(parts, q + 2, L.dataLength, L);
    end;
    1: begin
      if x.big then tbl := 4 * rows * ch else tbl := 2 * rows * ch;
      if len - 2 - tbl < 2 then Exit;
      if PackBitsLength(d, q + 2 + tbl, L.dataLength, used) <> psOk then Exit;
      if used <> len - 2 - tbl then Exit;
      if ch > 1 then L.coding := CODING_PLANES_PACKBITS else L.coding := CODING_PACKBITS;
      L.dataLength := used;
      AddBytes(parts, q, 2 + tbl);
      AddImage(parts, q + 2 + tbl, used, L);
    end;
  else Exit;
  end;
  Result := True;
end;


{ The composite's planes when one of them is a layer's channel, byte for
  byte (a single layer and its composite): such a plane a part of its own,
  which the encoder codes as a copy, the planes between them one image,
  interleaved. False when none is (the composite is then one image). }
function PsdPlanesApart(const d: TBytes; const x: TPsd; q, len, w, h: Int64; ch: Integer;
                        const layers: TInt64Array; var parts: TParts): Boolean;
var
  comp, tbl, pl, used, tot: Int64; c, k, y, g: Integer; L, G1: TRasterLayout; at, size: array of Int64;
  dup: Boolean; isDup: array of Boolean;
begin
  Result := False;
  if (ch < 2) or (len < 2) or (q + len > Length(d)) or not PsdLayout(x, w, h, 1, L) then Exit;
  comp := U16BE(d, q);
  at := nil; size := nil; SetLength(at, ch); SetLength(size, ch);
  case comp of
    0: begin
      pl := L.dataLength;
      if len - 2 <> pl * ch then Exit;
      for c := 0 to ch - 1 do begin at[c] := q + 2 + c * pl; size[c] := pl; end;
    end;
    1: begin
      if x.big then tbl := 4 * h * ch else tbl := 2 * h * ch;
      if len - 2 < tbl then Exit;
      pl := q + 2 + tbl;
      for c := 0 to ch - 1 do begin
        size[c] := 0;
        for y := 0 to h - 1 do
          if x.big then Inc(size[c], U32BE(d, q + 2 + 4 * (Int64(c) * h + y)))
          else Inc(size[c], U16BE(d, q + 2 + 2 * (Int64(c) * h + y)));
        at[c] := pl; Inc(pl, size[c]);
        if (pl > q + len) or (PackBitsLength(d, at[c], L.dataLength, used) <> psOk) or (used <> size[c]) then Exit;
      end;
      if pl <> q + len then Exit;
    end;
  else Exit;
  end;
  { which planes are a layer's channel; the others, next to each other,
    one image interleaved }
  dup := False;
  isDup := nil; SetLength(isDup, ch);
  for c := 0 to ch - 1 do begin
    isDup[c] := False;
    for k := 0 to Length(layers) div 2 - 1 do
      if (layers[2 * k + 1] = size[c]) and (size[c] > 0)
         and CompareMem(@d[layers[2 * k]], @d[at[c]], size[c]) then isDup[c] := True;
    if isDup[c] then dup := True;
  end;
  if not dup then Exit;
  AddBytes(parts, q, at[0] - q);
  c := 0;
  while c < ch do begin
    g := 1;
    if not isDup[c] then
      while (c + g < ch) and not isDup[c + g] do Inc(g);
    if not PsdLayout(x, w, h, g, G1) then Exit;
    tot := 0;
    for k := c to c + g - 1 do Inc(tot, size[k]);
    if g > 1 then begin
      if comp = 1 then G1.coding := CODING_PLANES_PACKBITS else G1.coding := CODING_PLANES;
    end else if comp = 1 then G1.coding := CODING_PACKBITS;
    if comp = 1 then G1.dataLength := tot;
    AddImage(parts, at[c], tot, G1);
    Inc(c, g);
  end;
  Result := True;
end;

function SplitPsd(const d: TBytes; var parts: TParts): Boolean;
var
  x: TPsd; ver, channels, h, w, depth, p, n, lmEnd, liLen, liEnd, count, q: Int64;
  lsz, k, c: Integer; top, left, bottom, right, nch, ln, extra, id, mt, ml, mb, mr: Int64; first: Integer;
  chans: array of record id, len, w, h: Int64; end;
  start: Int64; layers: TInt64Array;
begin
  Result := False;
  if (Length(d) < 34) or (d[0] <> Ord('8')) or (d[1] <> Ord('B')) or (d[2] <> Ord('P')) or (d[3] <> Ord('S')) then Exit;
  ver := U16BE(d, 4);
  if (ver <> 1) and (ver <> 2) then Exit;
  x.big := ver = 2;
  if x.big then lsz := 8 else lsz := 4;
  channels := U16BE(d, 12); h := U32BE(d, 14); w := U32BE(d, 18); depth := U16BE(d, 22);
  if (channels < 1) or (channels > 56) or not ((depth = 1) or (depth = 8) or (depth = 16) or (depth = 32)) then Exit;
  x.bits := depth;
  p := 26;
  n := U32BE(d, p); if (n < 0) or (n > Length(d) - p - 4) then Exit; Inc(p, 4 + n);     { colour mode data }
  n := U32BE(d, p); if (n < 0) or (n > Length(d) - p - 4) then Exit; Inc(p, 4 + n);     { image resources }
  if x.big then n := U64BE(d, p) else n := U32BE(d, p);
  if (n < 0) or (n > Length(d) - p - lsz) then Exit;
  lmEnd := p + lsz + n;
  chans := nil; layers := nil;
  start := 0;
  { the layers: their records, then each one's channels, in order }
  if n > 0 then begin
    q := p + lsz;
    if x.big then liLen := U64BE(d, q) else liLen := U32BE(d, q);
    if (liLen > 0) and (liLen <= lmEnd - q - lsz) then begin
      liEnd := q + lsz + liLen;
      q := q + lsz;
      count := U16BE(d, q); if count >= $8000 then count := $10000 - count;
      Inc(q, 2);
      for k := 0 to count - 1 do begin
        if q + 18 > liEnd then begin chans := nil; Break; end;
        top := U32BE(d, q); left := U32BE(d, q + 4); bottom := U32BE(d, q + 8); right := U32BE(d, q + 12);
        if top >= $80000000 then top := top - $100000000;
        if left >= $80000000 then left := left - $100000000;
        if bottom >= $80000000 then bottom := bottom - $100000000;
        if right >= $80000000 then right := right - $100000000;
        nch := U16BE(d, q + 16); Inc(q, 18);
        if (nch < 0) or (nch > 64) then begin chans := nil; Break; end;
        first := Length(chans);
        for c := 0 to nch - 1 do begin
          id := U16BE(d, q); if id >= $8000 then id := id - $10000;
          if x.big then ln := U64BE(d, q + 2) else ln := U32BE(d, q + 2);
          Inc(q, 2 + lsz);
          SetLength(chans, Length(chans) + 1);
          chans[High(chans)].id := id; chans[High(chans)].len := ln;
          chans[High(chans)].w := right - left; chans[High(chans)].h := bottom - top;
        end;
        { blend mode, opacity, flags, then the extra data: first the layer
          mask's, whose rectangle the mask channel (-2) has }
        extra := U32BE(d, q + 12);
        if extra < 0 then begin chans := nil; Break; end;
        if (extra >= 20) and (U32BE(d, q + 16) >= 16) then begin
          mt := S32BE(d, q + 20); ml := S32BE(d, q + 24); mb := S32BE(d, q + 28); mr := S32BE(d, q + 32);
          for c := first to High(chans) do
            if chans[c].id = -2 then begin chans[c].w := mr - ml; chans[c].h := mb - mt; end;
        end;
        q := q + 16 + extra;
        if q > liEnd then begin chans := nil; Break; end;
      end;
      { the channels' data, one after another }
      for k := 0 to High(chans) do begin
        if (chans[k].len < 2) or (chans[k].len > liEnd - q) then Break;
        AddBytes(parts, start, q - start);
        { the real user mask (-3): its rectangle is further on; bytes }
        if (chans[k].id < -2) or (chans[k].w < 1) or (chans[k].h < 1)
           or not PsdPlanes(d, x, q, chans[k].len, chans[k].w, chans[k].h, 1, parts) then
          AddBytes(parts, q, chans[k].len)
        else begin
          { where this channel's pixels are, for the composite to compare }
          SetLength(layers, Length(layers) + 2);
          layers[High(layers) - 1] := parts[High(parts)].first; layers[High(layers)] := parts[High(parts)].len;
        end;
        Inc(q, chans[k].len);
        start := q;
      end;
    end;
  end;
  AddBytes(parts, start, lmEnd - start);
  { the composite: every channel's plane, one after the other }
  if (h >= 1) and (w >= 1) and (channels * h <= MAX_DIMENSION) then begin
    if not PsdPlanesApart(d, x, lmEnd, Length(d) - lmEnd, w, h, channels, layers, parts)
       and not PsdPlanes(d, x, lmEnd, Length(d) - lmEnd, w, h, channels, parts) then
      AddBytes(parts, lmEnd, Length(d) - lmEnd);
  end else AddBytes(parts, lmEnd, Length(d) - lmEnd);
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
  if SplitTiff(d, parts) then begin fmt := rfTIFF; Exit(True); end;
  parts := nil;
  if SplitPsd(d, parts) then begin fmt := rfPSD; Exit(True); end;
  parts := nil;
  if SplitIco(d, parts, fmt) then Exit(True);
  parts := nil; fmt := rfNone;
end;

end.
