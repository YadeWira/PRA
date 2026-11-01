{ Layer 3: film and science. DPX, Cineon, FITS, VICAR, DICOM and
  uncompressed OpenEXR: headers that describe plain arrays of samples.

  - DPX (SMPTE 268M): "SDPX" big-endian or "XPDS" little-endian, an image
    element of 8, 10, 12 or 16 bits (or 32-bit floats). 8, 12 and 16 bits:
    samples as they are, rows padded to 32 bits unless packing is 0 (12 bits
    sit in 16). 10 bits, packing 1 or 2: three samples a 32-bit word (from
    its top bits, then two bits free; or the two free bits on top): the
    words are unpacked to 16-bit samples, the free bits coded beside them.
    One image element.
  - Cineon: magic 802A5FD7, channels of 8 bits or of 10 bits packed three
    to a 32-bit word (packing 5: on top; 6: below), pixel-interleaved.
  - FITS: 80-byte cards in 2880-byte blocks to END, then the array, big-
    endian: 8 or 16-bit integers or 32-bit floats; a third axis of 2 to 4
    is planes (channels), any other is images one under the other. Rows go
    bottom up. Padding and extensions are the tail.
  - VICAR: "LBLSIZE=" and a label of KEY=VALUE, records of RECSIZE bytes;
    BYTE, HALF (INTFMT gives the order), REAL (IEEE); bands one after the
    other (BSQ: planes) or interleaved by pixel (BIP).
  - DICOM, uncompressed: elements (implicit or explicit VR, little-endian,
    or explicit big-endian) up to the pixel data; 8 or 16 bits, one or
    three samples, interleaved or in planes; frames one under the other.
  - OpenEXR, one part, scanlines, no compression: each line a block (its
    y, its size, then each channel's samples in turn): the line offsets
    and the blocks' heads are rebuilt, the channels interleaved. Half or
    float channels, all the same. }
unit prasci;

{$I pra.inc}
{$ifopt R-}{$fatal prasci: range checks ($R+) are mandatory}{$endif}
{$ifopt Q-}{$fatal prasci: overflow checks ($Q+) are mandatory}{$endif}

interface

uses SysUtils, praraster;

function ParseDpx(const d: TBytes; out L: TRasterLayout): TParseStatus;
function ParseCineon(const d: TBytes; out L: TRasterLayout): TParseStatus;
function ParseFits(const d: TBytes; out L: TRasterLayout): TParseStatus;
function ParseVicar(const d: TBytes; out L: TRasterLayout): TParseStatus;
function ParseDicom(const d: TBytes; out L: TRasterLayout): TParseStatus;
function ParseExr(const d: TBytes; out L: TRasterLayout): TParseStatus;

{ The bytes a row takes when the header says (XWD, DPX, Cineon, VICAR),
  from the header at hdr[first..first+len); -1 when the rows are as long
  as their samples. }
function HeaderStride(f: TRasterFormat; const hdr: TBytes; first, len: SizeInt): Int64;

{ ---------- 10-bit samples packed three to a 32-bit word ---------- }

{ How the header packs them: methodB (the free bits on top), the words'
  byte order; False if it does not. }
function Pack10Params(f: TRasterFormat; const hdr: TBytes; first, len: SizeInt; out methodB, wordsBE: Boolean): Boolean;
{ words in a row of W x C samples }
function Pack10Words(w: Int64; channels: Integer): Int64;
{ the words at d[first..]: the samples (16 bits, big-endian, 3 a word, a row
  of 3 x words), the free bits coded (side) }
function Pack10Scan(const d: TBytes; first: SizeInt; const L: TRasterLayout; methodB, wordsBE: Boolean;
                    out raw, side: TBytes): Boolean;
function Pack10Rebuild(const raw, side: TBytes; const L: TRasterLayout; methodB, wordsBE: Boolean;
                       out coded: TBytes): Boolean;
function Pack10Fits(const L: TRasterLayout; available: Int64): Boolean;

{ ---------- OpenEXR scanlines ---------- }

{ The line offsets and blocks at d[first..] (first: where the offsets
  begin): the samples, the channels interleaved. ymin: the data window's. }
function ExrScan(const d: TBytes; first: SizeInt; const L: TRasterLayout; out raw: TBytes): Boolean;
function ExrRebuild(const raw: TBytes; first: SizeInt; const L: TRasterLayout; ymin: Int64; out coded: TBytes): Boolean;
{ the data window's ymin, from the header }
function ExrYMin(const hdr: TBytes; first, len: SizeInt; out ymin: Int64): Boolean;
function ExrFits(const L: TRasterLayout; available: Int64): Boolean;

implementation

uses Math, pralimits, praarith, pramodel, prarle, praother;

function U16(const d: TBytes; i: SizeInt; be: Boolean): Int64;
begin
  if be then Result := (d[i] shl 8) or d[i + 1] else Result := d[i] or (d[i + 1] shl 8);
end;

function U32(const d: TBytes; i: SizeInt; be: Boolean): Int64;
begin
  if be then Result := (Int64(d[i]) shl 24) or (Int64(d[i + 1]) shl 16) or (Int64(d[i + 2]) shl 8) or Int64(d[i + 3])
  else Result := (Int64(d[i + 3]) shl 24) or (Int64(d[i + 2]) shl 16) or (Int64(d[i + 1]) shl 8) or Int64(d[i]);
end;

function S32LE(const d: TBytes; i: SizeInt): Int64;
begin
  Result := U32(d, i, False);
  if Result >= $80000000 then Result := Result - $100000000;
end;

function Finish(const d: TBytes; var L: TRasterLayout): TParseStatus;
begin
  if L.dataOffset > MAX_TEXT_HEADER then begin L.format := rfNone; Exit(psUnsupported); end;
  if L.dataOffset > Length(d) then begin L.format := rfNone; Exit(psTruncated); end;
  Result := SizeRows(L, Length(d) - L.dataOffset);
  if Result <> psOk then L.format := rfNone;
end;

{ samples a pixel of a DPX descriptor; 0: not one PRA takes }
function DpxChannels(desc: Integer): Integer;
begin
  case desc of
    1..8: Result := 1;               { one component: R, G, B, A, Y, ... }
    50, 102: Result := 3;            { RGB, CbYCr }
    51, 52, 103: Result := 4;        { RGBA, ABGR, CbYCrA }
    100: Result := 2;                { CbYCrY 4:2:2 }
    101: Result := 3;                { CbYaCrYa 4:2:2:4 }
    150..156: Result := desc - 148;  { 2 to 8 generic components }
  else Result := 0;
  end;
end;

{ the DPX header's numbers: byte order, size, element 0 }
type
  TDpxHead = record
    be: Boolean;
    w, h, offset, eol: Int64;
    channels, bits, packing, encoding, elements: Integer;
  end;

function ReadDpxHead(const d: TBytes; first, len: SizeInt; out x: TDpxHead): TParseStatus;
var o: Int64;
begin
  x.be := False; x.w := 0; x.h := 0; x.offset := 0; x.eol := 0;
  x.channels := 0; x.bits := 0; x.packing := 0; x.encoding := 0; x.elements := 0;
  if (len < 4) or (first < 0) or (first + len > Length(d)) then Exit(psNotThis);
  if (d[first] = Ord('S')) and (d[first + 1] = Ord('D')) and (d[first + 2] = Ord('P')) and (d[first + 3] = Ord('X')) then x.be := True
  else if (d[first] = Ord('X')) and (d[first + 1] = Ord('P')) and (d[first + 2] = Ord('D')) and (d[first + 3] = Ord('S')) then x.be := False
  else Exit(psNotThis);
  if len < 852 then Exit(psMalformed);
  x.elements := U16(d, first + 770, x.be);
  x.w := U32(d, first + 772, x.be); x.h := U32(d, first + 776, x.be);
  x.channels := DpxChannels(d[first + 800]);
  x.bits := d[first + 803];
  x.packing := U16(d, first + 804, x.be);
  x.encoding := U16(d, first + 806, x.be);
  o := U32(d, first + 808, x.be);
  if (o = 0) or (o = $FFFFFFFF) then o := U32(d, first + 4, x.be);
  x.offset := o;
  x.eol := U32(d, first + 812, x.be);
  if x.eol = $FFFFFFFF then x.eol := 0;
  Result := psOk;
end;

{ ---------- DPX ---------- }

function ParseDpx(const d: TBytes; out L: TRasterLayout): TParseStatus;
var x: TDpxHead;
begin
  L.Clear;
  Result := ReadDpxHead(d, 0, Length(d), x);
  if Result <> psOk then Exit;
  if (x.elements <> 1) or (x.encoding <> 0) or (x.channels = 0) or (x.eol > 65536) then Exit(psUnsupported);
  L.format := rfDPX;
  L.width := x.w; L.height := x.h; L.channels := x.channels; L.bigEndian := x.be;
  L.dataOffset := x.offset;
  case x.bits of
    8: L.bits := 8;
    10: begin
      if not (x.packing in [1, 2]) or (x.eol <> 0) then begin L.format := rfNone; Exit(psUnsupported); end;
      L.bits := 16; L.bigEndian := True; L.coding := CODING_PACK10;
    end;
    12: begin
      if x.packing = 0 then begin L.format := rfNone; Exit(psUnsupported); end;
      L.bits := 16;
    end;
    16: L.bits := 16;
    32: begin L.bits := 32; L.isFloat := True; end;
  else begin L.format := rfNone; Exit(psUnsupported); end;
  end;
  if L.isFloat then L.maxval := 0 else L.maxval := (Int64(1) shl x.bits) - 1;
  if L.dataOffset > MAX_TEXT_HEADER then begin L.format := rfNone; Exit(psUnsupported); end;
  if L.dataOffset > Length(d) then begin L.format := rfNone; Exit(psTruncated); end;
  if L.coding = CODING_PACK10 then begin
    Result := SizeRows(L, High(Int64) shr 2);
    if Result <> psOk then begin L.format := rfNone; Exit; end;
    L.rowBytes := Pack10Words(L.width, L.channels) * 6;
    L.dataLength := Pack10Words(L.width, L.channels) * 4 * L.height;
    if not Pack10Fits(L, Length(d) - L.dataOffset) then begin
      L.format := rfNone;
      if L.dataLength > Length(d) - L.dataOffset then Exit(psTruncated);
      Exit(psUnsupported);
    end;
    Exit(psOk);
  end;
  Result := SizeRowsStride(L, Length(d) - L.dataOffset, HeaderStride(rfDPX, d, 0, L.dataOffset));
  if Result <> psOk then L.format := rfNone;
end;

{ ---------- Cineon ---------- }

type
  TCinHead = record
    be: Boolean;
    w, h, offset, eol: Int64;
    channels, bits, packing, interleave: Integer;
  end;

function ReadCinHead(const d: TBytes; first, len: SizeInt; out x: TCinHead): TParseStatus;
var k: Integer;
begin
  x.be := False; x.w := 0; x.h := 0; x.offset := 0; x.eol := 0;
  x.channels := 0; x.bits := 0; x.packing := 0; x.interleave := 0;
  if (len < 4) or (first < 0) or (first + len > Length(d)) then Exit(psNotThis);
  if (d[first] = $80) and (d[first + 1] = $2A) and (d[first + 2] = $5F) and (d[first + 3] = $D7) then x.be := True
  else if (d[first] = $D7) and (d[first + 1] = $5F) and (d[first + 2] = $2A) and (d[first + 3] = $80) then x.be := False
  else Exit(psNotThis);
  if len < 712 then Exit(psMalformed);
  x.offset := U32(d, first + 4, x.be);
  x.channels := d[first + 193];
  if (x.channels < 1) or (x.channels > 8) then Exit(psMalformed);
  x.bits := d[first + 198];
  x.w := U32(d, first + 200, x.be); x.h := U32(d, first + 204, x.be);
  { every channel the same }
  for k := 1 to x.channels - 1 do
    if (d[first + 196 + 28 * k + 2] <> x.bits) or (U32(d, first + 196 + 28 * k + 4, x.be) <> x.w)
       or (U32(d, first + 196 + 28 * k + 8, x.be) <> x.h) then Exit(psUnsupported);
  x.interleave := d[first + 680];
  x.packing := d[first + 681];
  x.eol := U32(d, first + 684, x.be);
  if x.eol = $FFFFFFFF then x.eol := 0;
  Result := psOk;
end;

function ParseCineon(const d: TBytes; out L: TRasterLayout): TParseStatus;
var x: TCinHead;
begin
  L.Clear;
  Result := ReadCinHead(d, 0, Length(d), x);
  if Result <> psOk then Exit;
  if (x.interleave <> 0) or (x.eol > 65536) then Exit(psUnsupported);
  L.format := rfCineon;
  L.width := x.w; L.height := x.h; L.channels := x.channels; L.bigEndian := x.be;
  L.dataOffset := x.offset;
  case x.bits of
    8: L.bits := 8;
    10: begin
      if not (x.packing in [5, 6]) or (x.eol <> 0) then begin L.format := rfNone; Exit(psUnsupported); end;
      L.bits := 16; L.bigEndian := True; L.coding := CODING_PACK10;
    end;
  else begin L.format := rfNone; Exit(psUnsupported); end;
  end;
  L.maxval := (Int64(1) shl x.bits) - 1;
  if L.dataOffset > MAX_TEXT_HEADER then begin L.format := rfNone; Exit(psUnsupported); end;
  if L.dataOffset > Length(d) then begin L.format := rfNone; Exit(psTruncated); end;
  if L.coding = CODING_PACK10 then begin
    Result := SizeRows(L, High(Int64) shr 2);
    if Result <> psOk then begin L.format := rfNone; Exit; end;
    L.rowBytes := Pack10Words(L.width, L.channels) * 6;
    L.dataLength := Pack10Words(L.width, L.channels) * 4 * L.height;
    if not Pack10Fits(L, Length(d) - L.dataOffset) then begin
      L.format := rfNone;
      if L.dataLength > Length(d) - L.dataOffset then Exit(psTruncated);
      Exit(psUnsupported);
    end;
    Exit(psOk);
  end;
  Result := SizeRowsStride(L, Length(d) - L.dataOffset, HeaderStride(rfCineon, d, 0, L.dataOffset));
  if Result <> psOk then L.format := rfNone;
end;

{ ---------- text headers: FITS cards, VICAR labels ---------- }

function TextAt(const d: TBytes; first, len: SizeInt): string;
var i: SizeInt;
begin
  Result := '';
  SetLength(Result, len);
  for i := 0 to len - 1 do Result[i + 1] := Chr(d[first + i]);
end;

{ an integer at s[p..]: spaces, a sign, digits; False if none or too big }
function IntAt(const s: string; p: Integer; out v: Int64): Boolean;
var neg: Boolean; n: Integer;
begin
  v := 0; neg := False; n := 0;
  while (p <= Length(s)) and (s[p] = ' ') do Inc(p);
  if (p <= Length(s)) and (s[p] in ['+', '-']) then begin neg := s[p] = '-'; Inc(p); end;
  while (p <= Length(s)) and (s[p] in ['0'..'9']) do begin
    if v > 100000000000 then Exit(False);
    v := v * 10 + Ord(s[p]) - 48; Inc(p); Inc(n);
  end;
  if neg then v := -v;
  Result := n > 0;
end;

{ ---------- FITS ---------- }

function ParseFits(const d: TBytes; out L: TRasterLayout): TParseStatus;
const MAGIC = 'SIMPLE  =';
var
  k, i: Integer; card, key: string; bitpix, naxis, v: Int64; axes: array[1..9] of Int64; ended: Boolean;
  cards, n3: Int64;
begin
  L.Clear;
  if Length(d) < 9 then Exit(psNotThis);
  for i := 1 to 9 do if d[i - 1] <> Ord(MAGIC[i]) then Exit(psNotThis);
  if Length(d) < 2880 then Exit(psMalformed);
  bitpix := 0; naxis := -1; for i := 1 to 9 do axes[i] := -1;
  ended := False; cards := 0;
  while (not ended) and ((cards + 1) * 80 <= Length(d)) and (cards * 80 < MAX_TEXT_HEADER) do begin
    card := TextAt(d, cards * 80, 80);
    key := TrimRight(Copy(card, 1, 8));
    if key = 'END' then ended := True
    else if Copy(card, 9, 2) = '= ' then begin
      if key = 'BITPIX' then begin if not IntAt(card, 11, bitpix) then Exit(psMalformed); end
      else if key = 'NAXIS' then begin if not IntAt(card, 11, naxis) then Exit(psMalformed); end
      else if (Length(key) = 6) and (Copy(key, 1, 5) = 'NAXIS') and (key[6] in ['1'..'9']) then begin
        if not IntAt(card, 11, v) then Exit(psMalformed);
        axes[Ord(key[6]) - 48] := v;
      end;
    end;
    Inc(cards);
  end;
  if not ended then begin
    if cards * 80 >= MAX_TEXT_HEADER then Exit(psUnsupported);
    Exit(psTruncated);
  end;
  { SIMPLE = T (where the standard puts it, or anywhere after the '=') }
  key := Trim(Copy(TextAt(d, 0, 80), 10, 71));
  if (key = '') or (key[1] <> 'T') then Exit(psUnsupported);
  if (naxis < 1) or (naxis > 9) then Exit(psUnsupported);
  for k := 1 to naxis do if (axes[k] < 1) or (axes[k] > MAX_DIMENSION) then Exit(psUnsupported);
  L.format := rfFITS; L.bigEndian := True; L.bottomUp := True;
  case bitpix of
    8: L.bits := 8;
    16: L.bits := 16;
    -32: begin L.bits := 32; L.isFloat := True; end;
  else begin L.format := rfNone; Exit(psUnsupported); end;   { 32 and 64-bit integers, doubles }
  end;
  if L.isFloat then L.maxval := 0 else L.maxval := (Int64(1) shl L.bits) - 1;
  L.width := axes[1]; L.channels := 1;
  if naxis = 1 then L.height := 1 else L.height := axes[2];
  { a third axis of 2 to 4: planes; anything more, images one under another }
  n3 := 1;
  for k := 3 to naxis do begin
    if n3 > MAX_DIMENSION div axes[k] then begin L.format := rfNone; Exit(psUnsupported); end;
    n3 := n3 * axes[k];
  end;
  if (naxis = 3) and (n3 >= 2) and (n3 <= 4) and (L.bits in [8, 16]) then begin
    L.channels := n3; L.coding := CODING_PLANES;
  end else if n3 > 1 then begin
    if L.height > MAX_DIMENSION div n3 then begin L.format := rfNone; Exit(psUnsupported); end;
    L.height := L.height * n3;
  end;
  L.dataOffset := (cards * 80 + 2879) div 2880 * 2880;
  Result := Finish(d, L);
end;

{ ---------- VICAR ---------- }

{ a label's value: KEY= at the label's start or after a space; a quoted
  string without its quotes; '' if there is none }
function LabelValue(const s, key: string): string;
var p, q, at: Integer;
begin
  Result := '';
  p := 1;
  { the first KEY= at the start or after a space }
  while True do begin
    at := Pos(key + '=', Copy(s, p, Length(s) - p + 1));
    if at = 0 then Exit;
    p := p + at - 1;
    if (p = 1) or (s[p - 1] = ' ') then Break;
    Inc(p);
  end;
  q := p + Length(key) + 1;
  if (q <= Length(s)) and (s[q] = '''') then begin
    Inc(q);
    while (q <= Length(s)) and (s[q] <> '''') do begin Result := Result + s[q]; Inc(q); end;
  end else
    while (q <= Length(s)) and (s[q] <> ' ') do begin Result := Result + s[q]; Inc(q); end;
end;

function LabelInt(const s, key: string; dflt: Int64): Int64;
var v: Int64;
begin
  if IntAt(LabelValue(s, key), 1, v) then Result := v else Result := dflt;
end;

{ the label's size, from "LBLSIZE=n " at d[first..] }
function VicarLabelSize(const d: TBytes; first, len: SizeInt; out size: Int64): Boolean;
var s: string;
begin
  Result := False; size := 0;
  if (len < 9) or (TextAt(d, first, 8) <> 'LBLSIZE=') then Exit;
  s := TextAt(d, first, Min(len, 40));
  Result := IntAt(s, 9, size) and (size >= 9) and (size <= MAX_TEXT_HEADER);
end;

type
  TVicarHead = record
    recsize, nl, ns, nb, nbb, nlb, bytes: Int64;
    org, fmt: string;
    be, isFloat: Boolean;
  end;

function ReadVicarHead(const d: TBytes; first, len: SizeInt; out x: TVicarHead): TParseStatus;
var lbl: Int64; s, intfmt, realfmt: string;
begin
  x.recsize := 0; x.nl := 0; x.ns := 0; x.nb := 0; x.nbb := 0; x.nlb := 0; x.bytes := 0;
  x.org := ''; x.fmt := ''; x.be := False; x.isFloat := False;
  if (len < 8) or (TextAt(d, first, 8) <> 'LBLSIZE=') then Exit(psNotThis);
  if not VicarLabelSize(d, first, len, lbl) then Exit(psMalformed);
  if lbl > len then Exit(psTruncated);
  s := TextAt(d, first, lbl);
  x.fmt := UpperCase(LabelValue(s, 'FORMAT'));
  x.org := UpperCase(LabelValue(s, 'ORG'));
  if x.org = '' then x.org := 'BSQ';
  x.recsize := LabelInt(s, 'RECSIZE', -1);
  x.nl := LabelInt(s, 'NL', -1); x.ns := LabelInt(s, 'NS', -1); x.nb := LabelInt(s, 'NB', 1);
  x.nbb := LabelInt(s, 'NBB', 0); x.nlb := LabelInt(s, 'NLB', 0);
  intfmt := UpperCase(LabelValue(s, 'INTFMT'));
  realfmt := UpperCase(LabelValue(s, 'REALFMT'));
  if x.fmt = 'BYTE' then x.bytes := 1
  else if (x.fmt = 'HALF') or (x.fmt = 'WORD') then begin x.bytes := 2; x.be := intfmt = 'HIGH'; end
  else if x.fmt = 'REAL' then begin
    x.bytes := 4; x.isFloat := True;
    if realfmt = 'RIEEE' then x.be := False else if (realfmt = 'IEEE') or (realfmt = '') then x.be := True
    else Exit(psUnsupported);                         { VAX floats }
  end else Exit(psUnsupported);                       { FULL, DOUB, COMP }
  if (x.recsize < 1) or (x.nl < 1) or (x.ns < 1) or (x.nb < 1) or (x.nlb < 0) then Exit(psMalformed);
  if x.nbb <> 0 then Exit(psUnsupported);             { a prefix to every record }
  Result := psOk;
end;

function ParseVicar(const d: TBytes; out L: TRasterLayout): TParseStatus;
var x: TVicarHead; lbl: Int64;
begin
  L.Clear;
  Result := ReadVicarHead(d, 0, Length(d), x);
  if Result <> psOk then Exit;
  VicarLabelSize(d, 0, Length(d), lbl);
  L.format := rfVICAR; L.bigEndian := x.be; L.isFloat := x.isFloat;
  L.bits := 8 * x.bytes;
  if L.isFloat then L.maxval := 0 else L.maxval := (Int64(1) shl L.bits) - 1;
  L.width := x.ns; L.height := x.nl; L.channels := 1;
  if (x.nb > 1) and (x.org = 'BIP') then begin
    if x.nb > MAX_CHANNELS then begin L.format := rfNone; Exit(psUnsupported); end;
    L.channels := x.nb;
  end else if x.nb > 1 then begin
    if x.org <> 'BSQ' then begin L.format := rfNone; Exit(psUnsupported); end;
    if (x.nb <= 4) and (x.recsize = x.ns * x.bytes) and (L.bits in [8, 16]) then begin
      L.channels := x.nb; L.coding := CODING_PLANES;
    end else begin
      if x.nl > MAX_DIMENSION div x.nb then begin L.format := rfNone; Exit(psUnsupported); end;
      L.height := x.nl * x.nb;
    end;
  end;
  if x.nlb > MAX_TEXT_HEADER div x.recsize then begin L.format := rfNone; Exit(psUnsupported); end;
  L.dataOffset := lbl + x.nlb * x.recsize;
  if L.dataOffset > MAX_TEXT_HEADER then begin L.format := rfNone; Exit(psUnsupported); end;
  if L.dataOffset > Length(d) then begin L.format := rfNone; Exit(psTruncated); end;
  if L.coding = CODING_PLANES then Result := SizeRows(L, Length(d) - L.dataOffset)
  else Result := SizeRowsStride(L, Length(d) - L.dataOffset, x.recsize);
  if Result <> psOk then L.format := rfNone;
end;

function HeaderStride(f: TRasterFormat; const hdr: TBytes; first, len: SizeInt): Int64;
var dx: TDpxHead; cx: TCinHead; vx: TVicarHead; natural: Int64; bits: Integer;
begin
  Result := -1;
  case f of
    rfXWD: Result := XwdStride(hdr, first, len);
    rfDPX:
      if ReadDpxHead(hdr, first, len, dx) = psOk then begin
        if dx.bits in [12, 16] then bits := 16 else bits := dx.bits;
        if (dx.channels = 0) or (dx.w < 1) or (dx.w > MAX_DIMENSION) or not (bits in [8, 16, 32]) then Exit;
        natural := (dx.w * dx.channels * bits + 7) div 8;
        { rows padded to 32 bits, unless packed }
        if dx.packing <> 0 then natural := (natural + 3) div 4 * 4;
        Result := natural + dx.eol;
      end;
    rfCineon:
      if ReadCinHead(hdr, first, len, cx) = psOk then begin
        if (cx.w < 1) or (cx.w > MAX_DIMENSION) or (cx.bits <> 8) then Exit;
        natural := cx.w * cx.channels;
        { packing 5 and 6: rows to 32 bits }
        if cx.packing in [5, 6] then natural := (natural + 3) div 4 * 4;
        Result := natural + cx.eol;
      end;
    rfVICAR:
      if ReadVicarHead(hdr, first, len, vx) = psOk then Result := vx.recsize;
  end;
end;

{ ---------- DICOM ---------- }

const
  TS_IMPLICIT_LE = 0;
  TS_EXPLICIT_LE = 1;
  TS_EXPLICIT_BE = 2;

type
  TDicomScan = record
    d: TBytes;
    ts: Integer;
    rows, cols, bits, spp, planar, frames: Int64;
    pixFirst, pixLen: Int64;
    ok, compressed: Boolean;
    depth: Integer;
  end;

function IsVR(a, b: Byte): Boolean;
const VRS = 'AEASATCSDADSDTFLFDISLOLTOBODOFOLOVOWPNSHSLSQSSSTSVTMUCUIULUNURUSUTUV';
var i: Integer;
begin
  Result := False;
  i := 1;
  while i < Length(VRS) do begin
    if (Ord(VRS[i]) = a) and (Ord(VRS[i + 1]) = b) then Exit(True);
    Inc(i, 2);
  end;
end;

function LongVR(a, b: Byte): Boolean;
begin
  Result := (a in [Ord('O'), Ord('S'), Ord('U')]) and
    (((a = Ord('O')) and (b in [Ord('B'), Ord('D'), Ord('F'), Ord('L'), Ord('V'), Ord('W')]))
     or ((a = Ord('S')) and (b in [Ord('Q'), Ord('V')]))
     or ((a = Ord('U')) and (b in [Ord('C'), Ord('N'), Ord('R'), Ord('T'), Ord('V')])));
end;

{ the integer value of an element (US, IS, UL), or -1 }
function DicomInt(var x: TDicomScan; p, len: Int64; vr0, vr1: Byte; be: Boolean): Int64;
var s: string; v: Int64;
begin
  Result := -1;
  if (vr0 = Ord('I')) and (vr1 = Ord('S')) then begin
    s := Trim(TextAt(x.d, p, Min(len, 16)));
    if IntAt(s, 1, v) then Result := v;
  end else if len = 2 then Result := U16(x.d, p, be)
  else if len = 4 then Result := U32(x.d, p, be);
end;

procedure DicomElements(var x: TDicomScan; var p: Int64; limit: Int64; inItem: Boolean);
var
  g, e, len: Int64; vr0, vr1: Byte; hl: Integer; be, explicit: Boolean; ts: string; v: Int64;
  s: string;
begin
  Inc(x.depth);
  if x.depth > 16 then begin x.ok := False; Exit; end;
  while x.ok and (p + 8 <= limit) do begin
    { the group 0002 (file meta) is always explicit little-endian }
    be := x.ts = TS_EXPLICIT_BE;
    g := U16(x.d, p, be); e := U16(x.d, p + 2, be);
    if (g = 2) and be then begin be := False; g := U16(x.d, p, False); e := U16(x.d, p + 2, False); end;
    { item and sequence delimiters }
    if g = $FFFE then begin
      len := U32(x.d, p + 4, be);
      Inc(p, 8);
      if e = $E00D then begin Dec(x.depth); Exit; end;      { the item ends }
      if e = $E0DD then begin Dec(x.depth); Exit; end;      { the sequence ends }
      if e = $E000 then begin
        if len = $FFFFFFFF then DicomElements(x, p, limit, True)
        else begin if len > limit - p then begin x.ok := False; Exit; end; Inc(p, len); end;
        Continue;
      end;
      x.ok := False; Exit;
    end;
    vr0 := x.d[p + 4]; vr1 := x.d[p + 5];
    explicit := ((x.ts <> TS_IMPLICIT_LE) or (g = 2)) and IsVR(vr0, vr1);
    if explicit then begin
      if LongVR(vr0, vr1) then begin
        if p + 12 > limit then begin x.ok := False; Exit; end;
        len := U32(x.d, p + 8, be); hl := 12;
      end else begin len := U16(x.d, p + 6, be); hl := 8; end;
    end else begin
      len := U32(x.d, p + 4, be); hl := 8; vr0 := 0; vr1 := 0;
    end;
    Inc(p, hl);
    if (g = $7FE0) and (e = $10) and not inItem then begin
      if len = $FFFFFFFF then x.compressed := True       { encapsulated: compressed frames }
      else begin x.pixFirst := p; x.pixLen := len; end;
      Dec(x.depth); Exit;
    end;
    if len = $FFFFFFFF then begin
      { a sequence (or UN) of undefined length: its items }
      DicomElements(x, p, limit, True);
      Continue;
    end;
    if len > limit - p then begin x.ok := False; Exit; end;
    if not inItem then begin
      if (g = 2) and (e = $10) then begin
        s := Trim(StringReplace(TextAt(x.d, p, len), #0, '', [rfReplaceAll]));
        ts := s;
        if ts = '1.2.840.10008.1.2' then x.ts := TS_IMPLICIT_LE
        else if ts = '1.2.840.10008.1.2.1' then x.ts := TS_EXPLICIT_LE
        else if ts = '1.2.840.10008.1.2.2' then x.ts := TS_EXPLICIT_BE
        else x.compressed := True;
      end else if g = $28 then begin
        v := DicomInt(x, p, len, vr0, vr1, be);
        case Integer(e) of
          $2: x.spp := v;
          $6: x.planar := v;
          $8: x.frames := v;
          $10: x.rows := v;
          $11: x.cols := v;
          $100: x.bits := v;
        end;
      end;
    end;
    Inc(p, len);
  end;
  Dec(x.depth);
end;

function ParseDicom(const d: TBytes; out L: TRasterLayout): TParseStatus;
var x: TDicomScan; p, g, n: Int64; preamble: Boolean;
begin
  L.Clear;
  preamble := (Length(d) >= 132) and (d[128] = Ord('D')) and (d[129] = Ord('I')) and (d[130] = Ord('C')) and (d[131] = Ord('M'));
  if preamble then p := 132
  else begin
    { no preamble (ACR-NEMA and old DICOM): the first element has to be of
      group 0002 or 0008, implicit or explicit, with a plausible length }
    if Length(d) < 16 then Exit(psNotThis);
    g := U16(d, 0, False);
    if (g <> 2) and (g <> 8) then Exit(psNotThis);
    if IsVR(d[4], d[5]) then n := U16(d, 6, False) else n := U32(d, 4, False);
    if n > 1024 then Exit(psNotThis);
    p := 0;
  end;
  x.d := d; x.ts := TS_IMPLICIT_LE;
  if preamble then x.ts := TS_EXPLICIT_LE;
  x.rows := -1; x.cols := -1; x.bits := -1; x.spp := 1; x.planar := 0; x.frames := 1;
  x.pixFirst := -1; x.pixLen := -1; x.ok := True; x.compressed := False; x.depth := 0;
  DicomElements(x, p, Length(d), False);
  if x.pixFirst < 0 then begin
    if x.compressed then Exit(psUnsupported);
    if preamble then Exit(psMalformed);
    Exit(psNotThis);
  end;
  if x.compressed then Exit(psUnsupported);
  if (x.rows < 1) or (x.cols < 1) or ((x.bits <> 8) and (x.bits <> 16)) or ((x.spp <> 1) and (x.spp <> 3)) or (x.frames < 1) then
    Exit(psUnsupported);
  L.format := rfDICOM;
  L.width := x.cols; L.bits := x.bits; L.channels := x.spp;
  L.bigEndian := x.ts = TS_EXPLICIT_BE;
  L.maxval := (Int64(1) shl L.bits) - 1;
  if x.rows > MAX_DIMENSION div x.frames then begin L.format := rfNone; Exit(psUnsupported); end;
  L.height := x.rows * x.frames;
  if (x.spp = 3) and (x.planar = 1) then begin
    if x.frames <> 1 then begin L.format := rfNone; Exit(psUnsupported); end;
    L.coding := CODING_PLANES;
  end;
  L.dataOffset := x.pixFirst;
  Result := Finish(d, L);
  { the pixel data's own length: never less than the image }
  if (Result = psOk) and (L.dataLength > x.pixLen) then begin L.format := rfNone; Result := psMalformed; end;
end;

{ ---------- OpenEXR ---------- }

type
  TExrHead = record
    channels, ptype: Integer;
    xmin, ymin, xmax, ymax: Int64;
    compression, lineOrder: Integer;
    headerEnd: Int64;
  end;

function ReadExrHead(const d: TBytes; first, len: SizeInt; out x: TExrHead): TParseStatus;
var
  p, e, sz, q, qe, pt: Int64; name, typ: string; flags: Int64; n: Integer;
  function CStr(at, limit: Int64; out s: string; out next: Int64): Boolean;
  var k: Int64;
  begin
    s := ''; k := at;
    while (k < limit) and (d[k] <> 0) and (k - at < 256) do begin s := s + Chr(d[k]); Inc(k); end;
    Result := (k < limit) and (d[k] = 0);
    next := k + 1;
  end;
begin
  x.channels := 0; x.ptype := -1; x.xmin := 0; x.ymin := 0; x.xmax := -1; x.ymax := -1;
  x.compression := -1; x.lineOrder := 0; x.headerEnd := 0;
  if (len < 4) or (first < 0) or (first + len > Length(d)) then Exit(psNotThis);
  if (d[first] <> $76) or (d[first + 1] <> $2F) or (d[first + 2] <> $31) or (d[first + 3] <> $01) then Exit(psNotThis);
  if len < 9 then Exit(psMalformed);
  flags := U32(d, first + 4, False);
  if (flags and 255) <> 2 then Exit(psUnsupported);
  if (flags and $1E00) <> 0 then Exit(psUnsupported);    { tiled, long names, deep, several parts }
  e := first + len;
  p := first + 8;
  while True do begin
    if p >= e then Exit(psTruncated);
    if d[p] = 0 then begin x.headerEnd := p + 1 - first; Break; end;
    if not CStr(p, e, name, p) or not CStr(p, e, typ, p) then Exit(psMalformed);
    if p + 4 > e then Exit(psTruncated);
    sz := U32(d, p, False); Inc(p, 4);
    if sz > e - p then Exit(psTruncated);
    if name = 'compression' then begin if sz >= 1 then x.compression := d[p]; end
    else if name = 'lineOrder' then begin if sz >= 1 then x.lineOrder := d[p]; end
    else if (name = 'dataWindow') and (sz = 16) then begin
      x.xmin := S32LE(d, p); x.ymin := S32LE(d, p + 4); x.xmax := S32LE(d, p + 8); x.ymax := S32LE(d, p + 12);
    end else if name = 'channels' then begin
      q := p; qe := p + sz; n := 0;
      while (q < qe) and (d[q] <> 0) do begin
        if not CStr(q, qe, typ, q) or (q + 16 > qe) then Exit(psMalformed);
        pt := U32(d, q, False);
        if pt > 2 then Exit(psUnsupported);
        { sampling must be 1 x 1 }
        if (U32(d, q + 8, False) <> 1) or (U32(d, q + 12, False) <> 1) then Exit(psUnsupported);
        if (x.ptype >= 0) and (pt <> x.ptype) then Exit(psUnsupported);   { mixed types }
        x.ptype := pt; Inc(n); Inc(q, 16);
      end;
      x.channels := n;
    end;
    Inc(p, sz);
  end;
  Result := psOk;
end;

function ExrBytes(ptype: Integer): Integer;
begin
  case ptype of
    1: Result := 2;      { half }
    2: Result := 4;      { float }
  else Result := 0;      { uint: not modelled }
  end;
end;

function ExrFits(const L: TRasterLayout; available: Int64): Boolean;
var line: Int64;
begin
  Result := False;
  if (L.width < 1) or (L.height < 1) or (L.channels < 1) or not (L.bits in [16, 32]) then Exit;
  line := L.width * L.channels * (L.bits div 8);
  if line > MAX_RAW div L.height then Exit;
  Result := L.height * (16 + line) <= available;
end;

function ExrWalk(const d: TBytes; first: SizeInt; const L: TRasterLayout; ymin: Int64; fill: Boolean;
                 var raw: TBytes): Boolean; forward;

function ParseExr(const d: TBytes; out L: TRasterLayout): TParseStatus;
var x: TExrHead; bytes: Integer; none: TBytes;
begin
  L.Clear;
  Result := ReadExrHead(d, 0, Length(d), x);
  if Result <> psOk then Exit;
  if (x.compression <> 0) or (x.lineOrder <> 0) or (x.channels < 1) or (x.channels > MAX_CHANNELS) then
    Exit(psUnsupported);                              { RLE, ZIP, PIZ, ...: not yet }
  bytes := ExrBytes(x.ptype);
  if bytes = 0 then Exit(psUnsupported);
  if (x.xmax < x.xmin) or (x.ymax < x.ymin) or (x.xmax - x.xmin >= MAX_DIMENSION) or (x.ymax - x.ymin >= MAX_DIMENSION) then
    Exit(psMalformed);
  L.format := rfEXR; L.coding := CODING_EXR;
  L.width := x.xmax - x.xmin + 1; L.height := x.ymax - x.ymin + 1;
  L.channels := x.channels; L.bits := 8 * bytes; L.isFloat := bytes = 4; L.bigEndian := False;
  if L.isFloat then L.maxval := 0 else L.maxval := 65535;
  L.dataOffset := x.headerEnd;
  if L.dataOffset > MAX_TEXT_HEADER then begin L.format := rfNone; Exit(psUnsupported); end;
  Result := SizeRows(L, High(Int64) shr 2);
  if Result <> psOk then begin L.format := rfNone; Exit; end;
  L.dataLength := L.height * (8 + 8 + L.rowBytes);
  if not ExrFits(L, Length(d) - L.dataOffset) then begin L.format := rfNone; Exit(psTruncated); end;
  { the blocks one after the other, in order: anything else is not rebuilt }
  none := nil;
  if not ExrWalk(d, L.dataOffset, L, x.ymin, False, none) then begin L.format := rfNone; Exit(psUnsupported); end;
end;

{ ---------- OpenEXR scanlines: offsets, blocks ---------- }

function ExrYMin(const hdr: TBytes; first, len: SizeInt; out ymin: Int64): Boolean;
var x: TExrHead;
begin
  Result := ReadExrHead(hdr, first, len, x) = psOk;
  ymin := x.ymin;
end;

{ check only (raw nil in the parser) or fill raw }
function ExrWalk(const d: TBytes; first: SizeInt; const L: TRasterLayout; ymin: Int64; fill: Boolean;
                 var raw: TBytes): Boolean;
var
  y, x, c, k: SizeInt; line, bs, tableEnd, blk, src, dst: Int64;
begin
  Result := False;
  bs := L.bits div 8;
  line := L.width * L.channels * bs;
  tableEnd := first + 8 * L.height;
  if first + L.dataLength > Length(d) then Exit;
  for y := 0 to L.height - 1 do begin
    blk := tableEnd + y * (8 + line);
    { the offset (64 bits, little-endian), the block's y and size }
    if (U32(d, first + 8 * y, False) <> (blk and $FFFFFFFF)) or (U32(d, first + 8 * y + 4, False) <> (blk shr 32)) then Exit;
    if (S32LE(d, blk) <> ymin + y) or (U32(d, blk + 4, False) <> line) then Exit;
    if fill then
      for c := 0 to L.channels - 1 do
        for x := 0 to L.width - 1 do begin
          src := blk + 8 + (c * L.width + x) * bs;
          dst := y * line + (x * L.channels + c) * bs;
          for k := 0 to bs - 1 do raw[dst + k] := d[src + k];
        end;
  end;
  Result := True;
end;

function ExrScan(const d: TBytes; first: SizeInt; const L: TRasterLayout; out raw: TBytes): Boolean;
var x: TExrHead;
begin
  raw := nil;
  Result := (ReadExrHead(d, 0, first, x) = psOk);
  if not Result then Exit;
  Result := ExrWalk(d, first, L, x.ymin, False, raw);
  if not Result then Exit;
  SetLength(raw, L.rowBytes * L.height);
  Result := ExrWalk(d, first, L, x.ymin, True, raw);
end;

function ExrRebuild(const raw: TBytes; first: SizeInt; const L: TRasterLayout; ymin: Int64; out coded: TBytes): Boolean;
var y, x, c, k: SizeInt; line, bs, tableEnd, blk, o, src, dst: Int64;
begin
  coded := nil; Result := False;
  if not ExrFits(L, High(Int64) shr 2) then Exit;
  bs := L.bits div 8;
  line := L.width * L.channels * bs;
  if Length(raw) <> line * L.height then Exit;
  SetLength(coded, L.height * (16 + line));
  tableEnd := first + 8 * L.height;
  for y := 0 to L.height - 1 do begin
    blk := tableEnd + y * (8 + line);
    o := 8 * y;
    for k := 0 to 7 do coded[o + k] := (blk shr (8 * k)) and 255;
    o := blk - first;
    for k := 0 to 3 do coded[o + k] := ((ymin + y) shr (8 * k)) and 255;
    for k := 0 to 3 do coded[o + 4 + k] := (line shr (8 * k)) and 255;
    for c := 0 to L.channels - 1 do
      for x := 0 to L.width - 1 do begin
        dst := o + 8 + (c * L.width + x) * bs;
        src := y * line + (x * L.channels + c) * bs;
        for k := 0 to bs - 1 do coded[dst + k] := raw[src + k];
      end;
  end;
  Result := True;
end;

{ ---------- 10 bits packed ---------- }

function Pack10Params(f: TRasterFormat; const hdr: TBytes; first, len: SizeInt; out methodB, wordsBE: Boolean): Boolean;
var dx: TDpxHead; cx: TCinHead;
begin
  Result := False; methodB := False; wordsBE := True;
  case f of
    rfDPX:
      if (ReadDpxHead(hdr, first, len, dx) = psOk) and (dx.bits = 10) and (dx.packing in [1, 2]) then begin
        methodB := dx.packing = 2; wordsBE := dx.be; Result := True;
      end;
    rfCineon:
      if (ReadCinHead(hdr, first, len, cx) = psOk) and (cx.bits = 10) and (cx.packing in [5, 6]) then begin
        methodB := cx.packing = 6; wordsBE := cx.be; Result := True;
      end;
  end;
end;

function Pack10Words(w: Int64; channels: Integer): Int64;
begin
  Result := (w * channels + 2) div 3;
end;

function Pack10Fits(const L: TRasterLayout; available: Int64): Boolean;
var words: Int64;
begin
  Result := False;
  if (L.width < 1) or (L.height < 1) or (L.channels < 1) or (L.width > MAX_DIMENSION) or (L.channels > MAX_CHANNELS) then Exit;
  words := Pack10Words(L.width, L.channels);
  if words * 6 > MAX_RAW div L.height then Exit;
  Result := words * 4 * L.height <= available;
end;

{ the free bits of each word, both ways: nearly always zero }
function CodePad(var pc: TPacketCoder; prev, pad: Integer): Integer;
begin
  Result := pc.Tree(4 * prev, pad, 2);
end;

function Pack10Scan(const d: TBytes; first: SizeInt; const L: TRasterLayout; methodB, wordsBE: Boolean;
                    out raw, side: TBytes): Boolean;
var k: SizeInt; n, v, o: Int64; s: array[0..2] of Integer; j, pad, prev: Integer; pc: TPacketCoder;
begin
  raw := nil; side := nil;
  Result := Pack10Fits(L, Length(d) - first);
  if not Result then Exit;
  n := Pack10Words(L.width, L.channels) * L.height;
  SetLength(raw, n * 6);
  pc.Init(True, nil);
  prev := 0;
  for k := 0 to n - 1 do begin
    v := U32(d, first + 4 * k, wordsBE);
    if methodB then begin
      s[0] := (v shr 20) and 1023; s[1] := (v shr 10) and 1023; s[2] := v and 1023; pad := v shr 30;
    end else begin
      s[0] := (v shr 22) and 1023; s[1] := (v shr 12) and 1023; s[2] := (v shr 2) and 1023; pad := v and 3;
    end;
    o := 6 * k;
    for j := 0 to 2 do begin raw[o + 2 * j] := s[j] shr 8; raw[o + 2 * j + 1] := s[j] and 255; end;
    CodePad(pc, prev, pad);
    prev := pad;
  end;
  side := pc.enc.Finish;
end;

function Pack10Rebuild(const raw, side: TBytes; const L: TRasterLayout; methodB, wordsBE: Boolean;
                       out coded: TBytes): Boolean;
var k: SizeInt; n, v, o: Int64; s: array[0..2] of Int64; j, pad, prev: Integer; pc: TPacketCoder;
begin
  coded := nil; Result := False;
  if not Pack10Fits(L, High(Int64) shr 2) then Exit;
  n := Pack10Words(L.width, L.channels) * L.height;
  if Length(raw) <> n * 6 then Exit;
  SetLength(coded, n * 4);
  pc.Init(False, side);
  prev := 0;
  for k := 0 to n - 1 do begin
    o := 6 * k;
    for j := 0 to 2 do begin
      s[j] := (raw[o + 2 * j] shl 8) or raw[o + 2 * j + 1];
      if s[j] > 1023 then Exit;                       { only damaged pixels }
    end;
    pad := CodePad(pc, prev, 0);
    prev := pad;
    if methodB then v := (Int64(pad) shl 30) or (s[0] shl 20) or (s[1] shl 10) or s[2]
    else v := (s[0] shl 22) or (s[1] shl 12) or (s[2] shl 2) or pad;
    if wordsBE then begin
      coded[4 * k] := v shr 24; coded[4 * k + 1] := (v shr 16) and 255; coded[4 * k + 2] := (v shr 8) and 255; coded[4 * k + 3] := v and 255;
    end else begin
      coded[4 * k + 3] := v shr 24; coded[4 * k + 2] := (v shr 16) and 255; coded[4 * k + 1] := (v shr 8) and 255; coded[4 * k] := v and 255;
    end;
  end;
  Result := True;
end;

end.
