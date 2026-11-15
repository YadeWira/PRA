{ The info providers (prainfo) of what PRA reads: the raster formats (each
  image's layout and how its pixels are coded, as the parsers find them,
  and the parts of a file of several images), and the .pra (the container,
  doc/FORMAT.md, and the stream inside it, doc/CODEC.md, read from its
  headers: no pixel is decoded).

  Nothing of what an image holds is shown: no pixel, no text of a header
  (a comment, an XML block): only sizes, places and the layout. }
unit prainforaster;

{$I pra.inc}
{$ifopt R-}{$fatal prainforaster: range checks ($R+) are mandatory}{$endif}
{$ifopt Q-}{$fatal prainforaster: overflow checks ($Q+) are mandatory}{$endif}

interface

uses SysUtils, prainfo, praraster;

{ how the pixels of a layout are coded, in words: "raw", "PackBits"... }
function CodingName(coding: Integer): string;
{ a layout as fields of n }
procedure DescribeLayout(const L: TRasterLayout; n: TInfoNode);

implementation

uses praformat, pracodec, praparts;

const
  { a list stops here; the rest counted }
  MAX_LISTED = 64;

function CodingName(coding: Integer): string;
begin
  case coding of
    CODING_RAW: Result := 'raw';
    CODING_HDR: Result := 'Radiance scanlines';
    CODING_TGA_RLE: Result := 'TGA run-length';
    CODING_SUN_RLE: Result := 'Sun Raster run-length';
    CODING_PCX: Result := 'PCX run-length';
    CODING_SGI_RLE: Result := 'SGI run-length';
    CODING_PLANES: Result := 'planes';
    CODING_BMP_RLE: Result := 'BMP RLE';
    CODING_PLAIN: Result := 'plain text';
    CODING_PACK10: Result := '10 bits packed';
    CODING_EXR: Result := 'OpenEXR scanlines';
    CODING_PACKBITS: Result := 'PackBits';
    CODING_PLANES_PACKBITS: Result := 'planes, PackBits';
    CODING_ILBM: Result := 'IFF (bitplanes, ByteRun1, or Impulse runs)';
    CODING_MIFF_RLE: Result := 'MIFF run-length';
    CODING_XCF: Result := 'XCF tiles, run-length';
    CODING_PICT_ROWS: Result := 'PICT rows, PackBits';
  else
    Result := 'coding ' + IntToStr(coding);
  end;
end;

procedure DescribeLayout(const L: TRasterLayout; n: TInfoNode);
begin
  n.Str('format', FormatName(L.format));
  n.Num('width', L.width);
  n.Num('height', L.height);
  n.Num('channels', L.channels);
  n.Num('bits', L.bits);
  if L.isFloat then n.Bool('float', True)
  else n.Num('maxval', L.maxval);
  if L.bits > 8 then n.Bool('big_endian', L.bigEndian);
  n.Num('pixels_offset', L.dataOffset);
  n.Num('pixels_bytes', L.dataLength);
  n.Str('coding', CodingName(L.coding));
end;

{ ---------- the raster formats ---------- }

function ProbeRaster(const d: TBytes): Boolean;
begin
  Result := FileFormat(d) <> rfNone;
end;

procedure DescribeRaster(const d: TBytes; n: TInfoNode);
var L: TRasterLayout; st: TParseStatus; parts: TParts; fmt: TRasterFormat; k, images: Integer;
    list, it, img: TInfoNode;
begin
  st := ParseAny(d, L);
  if SplitFile(d, st, L, parts, fmt) then begin
    n.Str('format', FormatName(fmt));
    n.Num('size', Length(d));
    images := 0;
    for k := 0 to High(parts) do if parts[k].kind = pkImage then Inc(images);
    n.Num('parts', Length(parts));
    n.Num('images', images);
    list := n.List('part_list');
    for k := 0 to High(parts) do begin
      if k >= MAX_LISTED then begin
        n.Num('parts_not_listed', Length(parts) - MAX_LISTED);
        Break;
      end;
      it := list.Obj;
      it.Num('offset', parts[k].first);
      it.Num('bytes', parts[k].len);
      if parts[k].kind = pkImage then begin
        it.Str('kind', 'image');
        img := it.Obj('image');
        DescribeLayout(parts[k].L, img);
        it.line := 'image at ' + IntToStr(parts[k].first) + ', ' + IntToStr(parts[k].len) + ' B: ' +
                   IntToStr(parts[k].L.width) + ' x ' + IntToStr(parts[k].L.height) + ', ' +
                   IntToStr(parts[k].L.channels) + ' x ' + IntToStr(parts[k].L.bits) + ' bits, ' +
                   CodingName(parts[k].L.coding);
        if Length(parts[k].refs) > 0 then begin
          it.Bool('against_layers', True);
          it.line := it.line + ', against its layers';
        end;
      end else begin
        it.Str('kind', 'bytes');
        it.line := 'bytes at ' + IntToStr(parts[k].first) + ', ' + IntToStr(parts[k].len) + ' B';
      end;
    end;
    Exit;
  end;
  if st <> psOk then begin
    n.Str('format', 'unknown');
    n.Num('size', Length(d));
    Exit;
  end;
  n.Str('format', FormatName(L.format));
  n.Num('size', Length(d));
  img := n.Obj('image');
  DescribeLayout(L, img);
  n.Num('header_bytes', L.dataOffset);
  n.Num('tail_bytes', Length(d) - L.dataOffset - L.dataLength);
end;

{ ---------- the .pra ---------- }

function ProbePra(const d: TBytes): Boolean;
var i: Integer;
begin
  Result := Length(d) >= 4;
  if Result then
    for i := 0 to 3 do if d[i] <> MAGIC[i] then Exit(False);
end;

procedure DescribeStreamOf(const s: TBytes; maxRaw: QWord; n: TInfoNode);
var parts: TStreamParts; v, k: Integer; st: TDecodeStatus; list, it, img: TInfoNode; cap: Int64;
const KINDS: array[0..3] of string = ('bytes', 'image', 'copy', 'image against references');
begin
  n.Num('bytes', Length(s));
  if maxRaw > QWord(High(Int64)) then cap := High(Int64) else cap := Int64(maxRaw);
  st := DescribeStream(s, cap, v, parts);
  n.Num('version', v);
  if st <> dsOk then begin
    n.Str('problem', DecodeStatusName(st));
    Exit;
  end;
  if v = PARTS_STREAM then begin
    n.Str('kind', 'parts');
    list := n.List('part_list');
    for k := 0 to High(parts) do begin
      if k >= MAX_LISTED then begin
        n.Num('parts_not_listed', Length(parts) - MAX_LISTED);
        Break;
      end;
      it := list.Obj;
      it.Str('kind', KINDS[parts[k].kind]);
      it.Num('bytes', parts[k].len);
      it.Num('stream_bytes', parts[k].streamLen);
      it.line := KINDS[parts[k].kind] + ', ' + IntToStr(parts[k].len) + ' B';
      if parts[k].kind in [1, 3] then begin
        img := it.Obj('image');
        DescribeLayout(parts[k].L, img);
        img.Num('bands', parts[k].bands);
        it.line := it.line + ' -> ' + IntToStr(parts[k].streamLen) + ' B: ' + FormatName(parts[k].L.format) + ' ' +
                   IntToStr(parts[k].L.width) + ' x ' + IntToStr(parts[k].L.height) + ', ' +
                   IntToStr(parts[k].bands) + ' band(s)';
      end else if parts[k].kind = 0 then
        it.line := it.line + ' -> ' + IntToStr(parts[k].streamLen) + ' B';
    end;
  end else if Length(parts) = 1 then begin
    n.Str('kind', 'image');
    img := n.Obj('image');
    DescribeLayout(parts[0].L, img);
    n.Num('bands', parts[0].bands);
  end;
end;

procedure DescribePra(const d: TBytes; n: TInfoNode);
var p: TPra; r: TPraResult; c, st: TInfoNode;
begin
  n.Str('format', 'PRA');
  n.Num('size', Length(d));
  c := n.Obj('container');
  if Length(d) >= 6 then begin
    c.Num('version', d[4]);
    c.Num('flags', d[5]);
  end;
  r := Open(d, p);
  if not r.Ok then begin
    c.Str('problem', r.Text);
    Exit;
  end;
  c.Num('original_size', p.orig_size);
  c.Str('original_blake3_128', HexBytes(p.hash));
  c.Str('extension', p.ext);
  c.Bool('stored', p.stored);
  c.Num('payload', Length(p.payload));
  if p.orig_size > 0 then c.Fixed('ratio_percent', 100 * Length(d) / p.orig_size);
  if p.stored then Exit;
  st := n.Obj('stream');
  { the headers decode up to the original's size: one larger than
    --max-output (x refuses it) is not read }
  if p.orig_size > InfoMaxOutput then begin
    st.Num('bytes', Length(p.payload));
    if Length(p.payload) > 0 then st.Num('version', p.payload[0]);
    st.Str('not_decoded', 'the original is larger than --max-output');
    Exit;
  end;
  DescribeStreamOf(p.payload, p.orig_size, st);
end;

initialization
  { the .pra first: its magic is no raster format's }
  RegisterInfoProvider('PRA', @ProbePra, @DescribePra);
  RegisterInfoProvider('raster', @ProbeRaster, @DescribeRaster);
end.
