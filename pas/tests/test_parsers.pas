{ Layer 3: the BMP, Radiance HDR and other parsers (prabmp, prahdr,
  praother).
  - the samples (tests/bmp, tests/hdr): the layout each reports, and for
    HDR the coder found for each line (Radiance's, stb's, flat);
  - hostile headers: each gives its status, never an exception, and a huge
    declared image allocates nothing;
  - fuzzing: the samples' headers mutated at random: no exception, and on
    psOk the pixels lie inside the file.

    test_parsers <tests/bmp> <tests/hdr> <tests/other> }
program test_parsers;
{$I ../pra.inc}
uses SysUtils, Classes, Math, praraster, prabmp, prahdr, praother, prarle, praparts, prasci, pracodec;

var cells, failures: Integer;
procedure Check(ok: Boolean; const what: string);
begin Inc(cells); if ok then Writeln('  ', what:66, '  ok') else begin Inc(failures); Writeln('  ', what:66, '  FAIL'); end; end;

function ReadAll(const f: string): TBytes; var s: TFileStream;
begin s := TFileStream.Create(f, fmOpenRead or fmShareDenyNone); try Result := nil; SetLength(Result, s.Size);
  if s.Size > 0 then s.ReadBuffer(Result[0], s.Size); finally s.Free; end; end;

function Bytes(const s: string): TBytes;
var i: Integer;
begin
  Result := nil; SetLength(Result, Length(s));
  for i := 1 to Length(s) do Result[i - 1] := Ord(s[i]);
end;

function WithU32(const d: TBytes; at: Integer; v: Cardinal): TBytes;
begin
  Result := Copy(d, 0, Length(d));
  Result[at] := v and 255; Result[at + 1] := (v shr 8) and 255;
  Result[at + 2] := (v shr 16) and 255; Result[at + 3] := v shr 24;
end;

function WithU16(const d: TBytes; at: Integer; v: Cardinal): TBytes;
begin
  Result := Copy(d, 0, Length(d));
  Result[at] := v and 255; Result[at + 1] := (v shr 8) and 255;
end;

var seed: Cardinal;
function Rand: Cardinal;
begin seed := seed xor (seed shl 13); seed := seed xor (seed shr 17); seed := seed xor (seed shl 5); Result := seed; end;

procedure ExpectBmp(const d: TBytes; want: TParseStatus; const what: string);
var L: TRasterLayout; st: TParseStatus;
begin
  st := ParseBmp(d, L);
  Check(st = want, what + ': ' + StatusName(st));
end;

procedure ExpectTga(const d: TBytes; want: TParseStatus; const what: string);
var L: TRasterLayout; st: TParseStatus;
begin
  st := ParseTga(d, L);
  Check(st = want, what + ': ' + StatusName(st));
end;

procedure ExpectSun(const d: TBytes; want: TParseStatus; const what: string);
var L: TRasterLayout; st: TParseStatus;
begin
  st := ParseSun(d, L);
  Check(st = want, what + ': ' + StatusName(st));
end;

procedure ExpectHdr(const d: TBytes; want: TParseStatus; const what: string);
var L: TRasterLayout; st: TParseStatus;
begin
  st := ParseHdr(d, L);
  Check(st = want, what + ': ' + StatusName(st));
end;

{ ParseAny, then the parts of a file of several images }
function Split(const d: TBytes; out parts: TParts; out fmt: TRasterFormat): Boolean;
var L: TRasterLayout; st: TParseStatus;
begin
  st := ParseAny(d, L);
  Result := SplitFile(d, st, L, parts, fmt);
end;

{ the parts one after the other, the whole file, each image inside its
  part (all bytes, when no entry is an image: the encoder then refuses) }
function Covers(const d: TBytes; const parts: TParts): Boolean;
var k: Integer; p: Int64;
begin
  p := 0;
  for k := 0 to High(parts) do begin
    if (parts[k].first <> p) or (parts[k].len < 1) then Exit(False);
    if (parts[k].kind = pkImage) and ((parts[k].L.dataOffset < 0) or (parts[k].L.dataLength < 1)
       or (parts[k].L.dataOffset + parts[k].L.dataLength > parts[k].len)) then Exit(False);
    Inc(p, parts[k].len);
  end;
  Result := (Length(parts) >= 1) and (p = Length(d));
end;

function Kinds(const parts: TParts): string;
var k: Integer;
begin
  Result := '';
  for k := 0 to High(parts) do if parts[k].kind = pkImage then Result := Result + 'i' else Result := Result + 'b';
end;

function AllModes(const modes: TBytes; m: Byte): Boolean;
var i: Integer;
begin
  Result := Length(modes) > 0;
  for i := 0 to High(modes) do if modes[i] <> m then Exit(False);
end;

var
  dirB, dirH, dirO, dirM, dirS, dirC: string; parts: TParts; fmt: TRasterFormat; d, rgbe, modes: TBytes; L: TRasterLayout; st: TParseStatus; used: Int64;
  i, k, bad, oks, bpp, planes: Integer; samples: array of TBytes; hdrText: string; dd: TBytes;
begin
  cells := 0; failures := 0; seed := 88172645;
  dirB := ParamStr(1); dirH := ParamStr(2); dirO := ParamStr(3); dirM := ParamStr(4); dirS := ParamStr(5); dirC := ParamStr(6);

  Writeln('BMP samples');
  d := ReadAll(dirB + '/graypal8.bmp'); st := ParseBmp(d, L);
  Check((st = psOk) and (L.bits = 8) and (L.channels = 1) and L.bottomUp and (L.width = 45) and (L.rowBytes = 48),
    'graypal8.bmp: 8 bits, one channel, rows of 48 B, bottom-up');
  d := ReadAll(dirB + '/palette4.bmp'); st := ParseBmp(d, L);
  Check((st = psOk) and (L.bits = 4) and (L.rowBytes = 20), 'palette4.bmp: 4 bits, rows of 20 B');
  d := ReadAll(dirB + '/mono.bmp'); st := ParseBmp(d, L);
  Check((st = psOk) and (L.bits = 1) and (L.rowBytes = 12), 'mono.bmp: 1 bit, rows of 12 B');
  d := ReadAll(dirB + '/os2_24.bmp'); st := ParseBmp(d, L);
  Check((st = psOk) and (L.bits = 8) and (L.channels = 3) and (L.dataOffset = 26) and (L.rowBytes = 96),
    'os2_24.bmp: OS/2 header, three channels, rows of 96 B');
  d := ReadAll(dirB + '/topdown24.bmp'); st := ParseBmp(d, L);
  Check((st = psOk) and not L.bottomUp and (L.height = 17), 'topdown24.bmp: a negative height is top-down');
  d := ReadAll(dirB + '/bgra32.bmp'); st := ParseBmp(d, L);
  Check((st = psOk) and (L.channels = 4) and (L.dataOffset = 66), 'bgra32.bmp: bitfields, four channels after the masks');
  d := ReadAll(dirB + '/rgb565.bmp'); st := ParseBmp(d, L);
  Check((st = psOk) and (L.bits = 16) and not L.bigEndian and (L.rowBytes = 44), 'rgb565.bmp: one 16-bit little-endian sample');

  Writeln('BMP: hostile headers');
  d := ReadAll(dirB + '/graypal8.bmp');
  ExpectBmp(Bytes('BX'), psNotThis, '"BX"');
  ExpectBmp(Bytes('P5 1 1 255'#10'x'), psNotThis, 'a PGM');
  ExpectBmp(Copy(d, 0, 20), psMalformed, 'cut inside the headers');
  ExpectBmp(WithU32(d, 14, 41), psMalformed, 'a DIB header of 41 bytes');
  ExpectBmp(WithU32(d, 10, Length(d) + 1), psMalformed, 'the pixels after the end of the file');
  ExpectBmp(WithU32(d, 10, 20), psMalformed, 'the pixels inside the headers');
  ExpectBmp(Copy(d, 0, Length(d) - 1), psTruncated, 'one byte short');
  ExpectBmp(WithU32(d, 30, 2), psMalformed, 'RLE4 at 8 bits');
  ExpectBmp(WithU32(d, 30, 4), psUnsupported, 'a JPEG inside');
  ExpectBmp(WithU32(d, 30, 5), psUnsupported, 'a PNG inside');
  ExpectBmp(WithU32(d, 30, 3), psMalformed, 'bitfields at 8 bits');
  ExpectBmp(WithU32(d, 30, 99), psMalformed, 'compression 99');
  ExpectBmp(WithU16(d, 28, 7), psMalformed, '7 bits a pixel');
  ExpectBmp(WithU32(d, 18, 0), psMalformed, 'width 0');
  ExpectBmp(WithU32(d, 18, $FFFFFFF0), psMalformed, 'a negative width');
  ExpectBmp(WithU32(d, 18, 1 shl 24 + 1), psMalformed, 'width 2^24 + 1');
  ExpectBmp(WithU32(WithU32(d, 18, 1 shl 24), 22, 1 shl 24), psTruncated, '2^24 x 2^24: truncated, no overflow');
  ExpectBmp(WithU32(d, 22, 0), psMalformed, 'height 0');

  Writeln('HDR samples');
  d := ReadAll(dirH + '/radiance.hdr'); st := ParseHdr(d, L);
  Check((st = psOk) and (L.width = 64) and (L.height = 20) and (L.dataOffset + L.dataLength = Length(d)),
    'radiance.hdr: 64x20, the scanlines to the end');
  HdrDecode(d, L, rgbe, modes, used);
  Check(AllModes(modes, HDR_RADIANCE), '  every line: Radiance''s coder');
  d := ReadAll(dirH + '/stb.hdr'); st := ParseHdr(d, L);
  HdrDecode(d, L, rgbe, modes, used);
  k := 0;
  for i := 0 to High(modes) do if modes[i] = HDR_STB then Inc(k);
  Check((st = psOk) and (k > 0) and not AllModes(modes, HDR_FLAT),
    Format('stb.hdr: %d of %d lines need stb''s coder (the rest Radiance''s writes too)', [k, Length(modes)]));
  d := ReadAll(dirH + '/flat.hdr'); st := ParseHdr(d, L);
  HdrDecode(d, L, rgbe, modes, used);
  Check((st = psOk) and (L.width = 7) and AllModes(modes, HDR_FLAT), 'flat.hdr: 7 wide, every line flat');

  Writeln('HDR: hostile headers');
  hdrText := '#?RADIANCE'#10'FORMAT=32-bit_rle_rgbe'#10#10;
  ExpectHdr(Bytes('#!RADIANCE'#10), psNotThis, '"#!"');
  ExpectHdr(Bytes(hdrText), psMalformed, 'no resolution line');
  ExpectHdr(Bytes('#?RADIANCE'#10'FORMAT=32-bit_rle_rgbe'#10), psMalformed, 'no empty line');
  ExpectHdr(Bytes('#?RADIANCE'#10'FORMAT=48-bit_float'#10#10'-Y 1 +X 1'#10'abcd'), psUnsupported, 'an unknown FORMAT');
  ExpectHdr(Bytes(hdrText + '+Y 1 +X 1'#10'abcd'), psUnsupported, 'rows from the bottom (+Y)');
  ExpectHdr(Bytes(hdrText + '-X 1 +Y 1'#10'abcd'), psUnsupported, 'columns first (-X ... +Y)');
  ExpectHdr(Bytes(hdrText + '-Y 1 +X 1'#10'abcd'), psOk, '1x1 flat');
  ExpectHdr(Bytes(hdrText + '-Y 1 +X 1'#10'abc'), psTruncated, '1x1, one byte short');
  ExpectHdr(Bytes(hdrText + '-Y x +X 1'#10'abcd'), psMalformed, 'height "x"');
  ExpectHdr(Bytes(hdrText + '-Y 0 +X 1'#10), psMalformed, 'height 0');
  ExpectHdr(Bytes(hdrText + '-Y 1 +X 99999999999999999999'#10), psMalformed, 'a width that overflows 64 bits');
  ExpectHdr(Bytes(hdrText + '-Y 16777216 +X 16777216'#10'abcd'), psTruncated, '2^24 x 2^24 in 4 bytes: nothing allocated');
  { a run-length line with a run of zero, and one longer than the line }
  ExpectHdr(Bytes(hdrText + '-Y 1 +X 8'#10#2#2#0#8#0 + StringOfChar(#1, 20)), psMalformed, 'a dump of 0');
  ExpectHdr(Bytes(hdrText + '-Y 1 +X 8'#10#2#2#0#8#137#1 + StringOfChar(#1, 20)), psMalformed, 'a run of 9 in a line of 8');
  ExpectHdr(Bytes(hdrText + '-Y 1 +X 8'#10#2#2#0#8#136), psTruncated, 'a run with no value');
  { a line that is run-length coded but not as either coder writes it: a
    run of 2 that Radiance writes as a dump and stb as a dump too }
  ExpectHdr(Bytes(hdrText + '-Y 1 +X 8'#10#2#2#0#8 + #130#5#6#1#2#3#4#5#6 + #136#1 + #136#2 + #136#3),
    psUnsupported, 'a line neither coder writes: unsupported');

  Writeln('farbfeld, TGA, Sun Raster, WBMP');
  d := ReadAll(dirO + '/ff_rgba16.ff'); st := ParseAny(d, L);
  Check((st = psOk) and (L.format = rfFarbfeld) and (L.channels = 4) and (L.bits = 16) and (L.dataOffset = 16),
    'ff_rgba16.ff: farbfeld, RGBA of 16 bits after 16 bytes');
  d := ReadAll(dirO + '/tga_rgb24.tga'); st := ParseAny(d, L);
  Check((st = psOk) and (L.format = rfTGA) and (L.channels = 3) and (L.dataOffset = 18 + 17)
    and (L.dataOffset + L.dataLength = Length(d) - 26), 'tga_rgb24.tga: after its ID field; the footer is the tail');
  d := ReadAll(dirO + '/tga_bgra32_top.tga'); st := ParseAny(d, L);
  Check((st = psOk) and (L.channels = 4) and not L.bottomUp, 'tga_bgra32_top.tga: four channels, top-down');
  d := ReadAll(dirO + '/tga_rgb16.tga'); st := ParseAny(d, L);
  Check((st = psOk) and (L.bits = 16) and (L.channels = 1) and not L.bigEndian, 'tga_rgb16.tga: one 16-bit little-endian sample');
  d := ReadAll(dirO + '/tga_mapped8.tga'); st := ParseAny(d, L);
  Check((st = psOk) and (L.bits = 8) and (L.dataOffset = 18 + 120), 'tga_mapped8.tga: indices after the 120-byte colour map');
  d := ReadAll(dirO + '/ras_bgr24.ras'); st := ParseAny(d, L);
  Check((st = psOk) and (L.format = rfSUN) and (L.rowBytes = 88), 'ras_bgr24.ras: Sun, rows of 87 bytes padded to 88');
  d := ReadAll(dirO + '/ras_mono1.ras'); st := ParseAny(d, L);
  Check((st = psOk) and (L.bits = 1) and (L.rowBytes = 4), 'ras_mono1.ras: 1 bit, rows padded to 16 bits');
  d := ReadAll(dirO + '/ras_mapped8.ras'); st := ParseAny(d, L);
  Check((st = psOk) and (L.dataOffset = 32 + 48), 'ras_mapped8.ras: after the colour map');
  d := ReadAll(dirO + '/wbmp_wide.wbmp'); st := ParseAny(d, L);
  Check((st = psOk) and (L.format = rfWBMP) and (L.width = 200) and (L.dataOffset = 5), 'wbmp_wide.wbmp: width 200 in two bytes');
  d := ReadAll(dirO + '/tga_gray8.tga');
  ExpectTga(WithU16(d, 12, 0), psNotThis, 'TGA, width 0');
  d[2] := 7; ExpectTga(d, psNotThis, 'TGA, type 7');
  d := ReadAll(dirO + '/tga_gray8.tga'); d[16] := 12;
  ExpectTga(d, psNotThis, 'TGA, 12 bits a pixel');
  d := ReadAll(dirO + '/tga_gray8.tga');
  ExpectTga(Copy(d, 0, Length(d) - 1), psTruncated, 'TGA one byte short');
  Writeln('TGA run-length');
  d := ReadAll(dirO + '/tga_rle24.tga'); st := ParseAny(d, L);
  Check((st = psOk) and (L.coding = CODING_TGA_RLE) and (L.dataOffset = 18) and (L.dataOffset + L.dataLength = Length(d)),
    'tga_rle24.tga: run-length, the packets to the end');
  d := ReadAll(dirO + '/tga_rle_mapped.tga'); st := ParseAny(d, L);
  Check((st = psOk) and (L.coding = CODING_TGA_RLE) and (L.dataOffset = 18 + 36), 'tga_rle_mapped.tga: after its colour map');
  ExpectTga(Copy(d, 0, Length(d) - 1), psTruncated, 'TGA run-length one byte short');
  d := ReadAll(dirO + '/tga_rle24.tga');
  d[18] := $FF; d[19] := 1; d[20] := 2; d[21] := 3; d := Copy(d, 0, 22);
  d := WithU16(WithU16(d, 12, 2), 14, 2);
  ExpectTga(d, psMalformed, 'a run of 128 in an image of 4 pixels');
  d := WithU16(WithU16(ReadAll(dirO + '/tga_rle24.tga'), 12, 65535), 14, 65535);
  ExpectTga(d, psTruncated, '65535 x 65535 in a few bytes: nothing allocated');

  d := ReadAll(dirO + '/ras_bgr24.ras');
  ExpectSun(Copy(d, 0, 20), psMalformed, 'Sun, cut inside the header');
  ExpectSun(Copy(d, 0, Length(d) - 1), psTruncated, 'Sun one byte short');
  d[23] := 4; ExpectSun(d, psUnsupported, 'Sun, TIFF inside (type 4)');
  d[23] := 1; d[15] := 7; ExpectSun(d, psMalformed, 'Sun, depth 7');
  d := ReadAll(dirO + '/ff_rgba16.ff');
  Check(ParseFarbfeld(Copy(d, 0, Length(d) - 1), L) = psTruncated, 'farbfeld one byte short: truncated');
  Check(ParseFarbfeld(Copy(d, 0, 12), L) = psMalformed, 'farbfeld cut inside the header: malformed');
  d := ReadAll(dirO + '/wbmp_shape.wbmp');
  Check(ParseWbmp(Copy(d, 0, Length(d) - 1), L) = psNotThis, 'WBMP one byte short: not a WBMP (its signature is weak)');
  Check(ParseWbmp(Bytes(#0#0#$FF#$FF#$FF#$FF#$7F#1), L) = psNotThis, 'WBMP, a width of 5 bytes');

  Writeln('PCX and Sun run-length');
  d := ReadAll(dirO + '/pcx_rgb24.pcx'); st := ParseAny(d, L);
  Check((st = psOk) and (L.format = rfPCX) and (L.coding = CODING_PCX) and (L.channels = 3) and (L.width = 32)
    and (L.dataOffset = 128) and (L.dataOffset + L.dataLength = Length(d)), 'pcx_rgb24.pcx: three 8-bit planes as channels');
  d := ReadAll(dirO + '/pcx_pal8.pcx'); st := ParseAny(d, L);
  Check((st = psOk) and (L.bits = 8) and (L.channels = 1) and (Length(d) - L.dataOffset - L.dataLength = 769),
    'pcx_pal8.pcx: indices; the 769-byte palette is the tail');
  d := ReadAll(dirO + '/pcx_ega.pcx'); st := ParseAny(d, L);
  Check((st = psOk) and (L.bits = 4) and (L.width = 48), 'pcx_ega.pcx: four 1-bit planes as 4-bit indices');
  d := ReadAll(dirO + '/pcx_mono.pcx'); st := ParseAny(d, L);
  Check((st = psOk) and (L.bits = 1) and (L.width = 80), 'pcx_mono.pcx: one 1-bit plane');
  d := ReadAll(dirO + '/pcx_rgb24.pcx');
  Check(ParsePcx(Copy(d, 0, Length(d) - 1), L) = psTruncated, 'PCX one byte short: truncated');
  Check(ParsePcx(Copy(d, 0, 100), L) = psMalformed, 'PCX cut inside its header: malformed');
  d[2] := 0;
  Check(ParsePcx(d, L) = psUnsupported, 'PCX not run-length coded: unsupported');
  d := ReadAll(dirO + '/pcx_rgb24.pcx'); d[65] := 2;
  Check(ParsePcx(d, L) = psUnsupported, 'PCX, two 8-bit planes: unsupported');
  d := ReadAll(dirO + '/pcx_rgb24.pcx'); d[128] := $C0; d[129] := 7;
  Check(ParsePcx(d, L) = psUnsupported, 'PCX, a run of 0: unsupported');
  d := ReadAll(dirO + '/pcx_rgb24.pcx'); d[10] := 255; d[11] := 255;
  Check(ParsePcx(d, L) = psTruncated, 'PCX, 65536 lines in a few bytes: nothing allocated');
  { the planes <-> pixels, both ways, every layout }
  bad := 0;
  for k := 0 to 5 do begin
    case k of
      0: begin bpp := 8; planes := 3; end;
      1: begin bpp := 8; planes := 4; end;
      2: begin bpp := 1; planes := 2; end;
      3: begin bpp := 1; planes := 3; end;
      4: begin bpp := 1; planes := 4; end;
    else begin bpp := 4; planes := 1; end;
    end;
    SetLength(dd, 5 * planes * 7);
    for i := 0 to High(dd) do dd[i] := Byte(Rand);
    rgbe := PcxFromPixels(PcxToPixels(dd, bpp, planes, 7, 5), bpp, planes, 7, 5);
    if (Length(rgbe) <> Length(dd)) or not CompareMem(@rgbe[0], @dd[0], Length(dd)) then Inc(bad);
  end;
  Check(bad = 0, 'PCX planes to pixels and back, in all 6 layouts');
  d := ReadAll(dirO + '/ras_rle24.ras'); st := ParseAny(d, L);
  Check((st = psOk) and (L.coding = CODING_SUN_RLE) and (L.rowBytes = 82) and (L.dataOffset + L.dataLength = Length(d)),
    'ras_rle24.ras: run-length, rows of 81 bytes padded to 82');
  Check(ParseSun(Copy(d, 0, Length(d) - 1), L) = psTruncated, 'Sun run-length one byte short: truncated');

  Writeln('SGI');
  d := ReadAll(dirO + '/sgi_raw8.sgi'); st := ParseAny(d, L);
  Check((st = psOk) and (L.format = rfSGI) and (L.coding = CODING_PLANES) and (L.channels = 3)
    and (L.dataOffset = 512) and (L.dataLength = 25 * 14 * 3), 'sgi_raw8.sgi: verbatim, three planes');
  d := ReadAll(dirO + '/sgi_rle_ymajor.rgb'); st := ParseAny(d, L);
  Check((st = psOk) and (L.coding = CODING_SGI_RLE) and (L.channels = 4) and (L.dataOffset + L.dataLength = Length(d)),
    'sgi_rle_ymajor.rgb: run-length, the tables and rows to the end');
  d := ReadAll(dirO + '/sgi_rle16.sgi'); st := ParseAny(d, L);
  Check((st = psOk) and (L.bits = 16) and L.bigEndian, 'sgi_rle16.sgi: 16 bits, big-endian');
  Check(ParseSgi(Copy(d, 0, 400), L) = psMalformed, 'SGI cut inside its header: malformed');
  Check(ParseSgi(Copy(d, 0, Length(d) - 1), L) = psTruncated, 'SGI run-length one byte short: truncated');
  dd := Copy(d, 0, Length(d)); dd[512 + 3] := dd[512 + 3] xor 1;
  Check(ParseSgi(dd, L) = psUnsupported, 'SGI, a row not where the rows follow each other: unsupported');
  dd := Copy(d, 0, Length(d)); dd[3] := 3;
  Check(ParseSgi(dd, L) = psMalformed, 'SGI, 3 bytes a value: malformed');
  dd := Copy(d, 0, Length(d)); dd[11] := 5;
  Check(ParseSgi(dd, L) = psUnsupported, 'SGI, 5 channels: unsupported');
  dd := Copy(d, 0, Length(d)); dd[6] := 255; dd[8] := 255;
  Check(ParseSgi(dd, L) = psTruncated, 'SGI, 65280 x 65280 in a few bytes: nothing allocated');
  SetLength(dd, 7 * 5 * 3 * 2);
  for i := 0 to High(dd) do dd[i] := Byte(Rand);
  rgbe := SgiFromPixels(SgiToPixels(dd, 7, 5, 3, 2), 7, 5, 3, 2);
  Check(CompareMem(@rgbe[0], @dd[0], Length(dd)), 'SGI planes to pixels and back');

  Writeln('XWD, MTV, VIFF, VIPS, DDS');
  d := ReadAll(dirO + '/xwd_rgb32_be.xwd'); st := ParseAny(d, L);
  Check((st = psOk) and (L.format = rfXWD) and (L.channels = 4) and (L.rowBytes = 116) and (L.dataOffset = 111)
    and (L.dataLength = 116 * 19) and (XwdStride(d, 0, L.dataOffset) = 116),
    'xwd_rgb32_be.xwd: big-endian header, rows of 108 bytes in 116');
  d := ReadAll(dirO + '/xwd_mapped8_le.xwd'); st := ParseAny(d, L);
  Check((st = psOk) and (L.format = rfXWD) and (L.bits = 8) and (L.rowBytes = 32) and (L.dataOffset = 111 + 24 * 12),
    'xwd_mapped8_le.xwd: little-endian header, 24 colours');
  Check(ParseXwd(WithU32(d, 48, 30), L) = psMalformed, 'XWD, rows shorter than their pixels: malformed');
  Check(ParseXwd(WithU32(d, 48, 1 shl 30), L) = psMalformed, 'XWD, rows of 1 GiB: malformed, nothing allocated');
  Check(ParseXwd(WithU32(d, 20, 1 shl 24), L) = psTruncated, 'XWD, 16777216 rows in a few bytes: truncated');
  Check(ParseXwd(WithU32(d, 8, 1), L) = psUnsupported, 'XWD, XYPixmap of 8 planes: unsupported');
  Check(XwdStride(d, 0, 50) = -1, 'XWD stride from a header too short: none');
  d := ReadAll(dirO + '/xwd_bitmap.xwd'); st := ParseAny(d, L);
  Check((st = psOk) and (L.bits = 1) and (L.rowBytes = 8) and (L.width = 50), 'xwd_bitmap.xwd: XYBitmap, 50 bits in 8 bytes');
  d := ReadAll(dirO + '/mtv_rgb.mtv'); st := ParseAny(d, L);
  Check((st = psOk) and (L.format = rfMTV) and (L.dataOffset = 6) and (L.dataLength = Length(d) - 6), 'mtv_rgb.mtv: 26 x 18, R G B');
  d := ReadAll(dirO + '/mtv_tail.mtv'); st := ParseAny(d, L);
  Check((st = psOk) and (L.dataOffset + L.dataLength = Length(d) - 1), 'mtv_tail.mtv: a byte after the pixels');
  dd := Copy(d, 0, Length(d)); SetLength(dd, Length(d) + 100);
  Check(ParseMtv(dd, L) = psNotThis, 'MTV with 100 bytes too many: not this');
  Check(ParseMtv(Copy(d, 0, 100), L) = psNotThis, 'MTV cut short: not this');
  Check(ParseMtv(Bytes('26x18'#10), L) = psNotThis, '"26x18": not this');
  d := ReadAll(dirO + '/viff_rgb_be.viff'); st := ParseAny(d, L);
  Check((st = psOk) and (L.format = rfVIFF) and (L.coding = CODING_PLANES) and (L.channels = 3) and L.bigEndian
    and (L.dataOffset = 1024) and (L.dataLength = 23 * 15 * 3), 'viff_rgb_be.viff: three planes, big-endian');
  d := ReadAll(dirO + '/viff_gray16_le.xv'); st := ParseAny(d, L);
  Check((st = psOk) and (L.coding = CODING_RAW) and (L.bits = 16) and not L.bigEndian, 'viff_gray16_le.xv: one band, 16 bits, little-endian');
  d := ReadAll(dirO + '/viff_mapped.xv'); st := ParseAny(d, L);
  Check((st = psOk) and (L.dataOffset = 1024 + 60), 'viff_mapped.xv: a map of 3 x 20 bytes');
  Check(ParseViff(WithU32(d, 568, 1), L) = psUnsupported, 'VIFF, compressed: unsupported');
  Check(ParseViff(WithU32(d, 556, 2), L) = psUnsupported, 'VIFF, two images: unsupported');
  Check(ParseViff(WithU32(d, 584, 1 shl 20), L) = psUnsupported, 'VIFF, a map of a million colours: unsupported');
  Check(ParseViff(Copy(d, 0, 1000), L) = psMalformed, 'VIFF cut inside its header: malformed');
  d := ReadAll(dirO + '/vips_rgb_be.v'); st := ParseAny(d, L);
  Check((st = psOk) and (L.format = rfVIPS) and (L.channels = 3) and (L.dataOffset = 64)
    and (L.dataOffset + L.dataLength < Length(d)), 'vips_rgb_be.v: pixels, then the XML');
  d := ReadAll(dirO + '/vips_gray16_le.v'); st := ParseAny(d, L);
  Check((st = psOk) and (L.bits = 16) and not L.bigEndian, 'vips_gray16_le.v: 16 bits, little-endian');
  Check(ParseVips(WithU32(d, 24, 2), L) = psUnsupported, 'VIPS, coded (LabQ): unsupported');
  Check(ParseVips(WithU32(d, 20, 5), L) = psUnsupported, 'VIPS, 32-bit integers: unsupported');
  d := ReadAll(dirO + '/dds_bgra32.dds'); st := ParseAny(d, L);
  Check((st = psOk) and (L.format = rfDDS) and (L.channels = 4) and (L.dataOffset = 128), 'dds_bgra32.dds: 32 bits, four channels');
  d := ReadAll(dirO + '/dds_a8l8.dds'); st := ParseAny(d, L);
  Check((st = psOk) and (L.channels = 2) and (L.bits = 8), 'dds_a8l8.dds: two byte-wide masks, two channels');
  d := ReadAll(dirO + '/dds_volume.dds'); st := ParseAny(d, L);
  Check((st = psOk) and (L.height = 24), 'dds_volume.dds: three slices of 8 rows, one under the other');
  Check(ParseDds(WithU32(d, 24, $FFFFFF), L) = psMalformed, 'DDS, a volume of 16777215 slices: malformed');
  d := ReadAll(dirO + '/dds_mips.dds'); st := ParseAny(d, L);
  Check((st = psOk) and (L.dataLength = 16 * 16 * 4) and (L.dataOffset + L.dataLength < Length(d)),
    'dds_mips.dds: the main surface; the mipmaps in the tail');
  Check(ParseDds(WithU32(WithU32(d, 80, 4), 84, $31545844), L) = psUnsupported, 'DDS, DXT1: unsupported');
  Check(ParseDds(WithU32(d, 4, 100), L) = psMalformed, 'DDS, a header of 100 bytes: malformed');

  Writeln('BMP run-length');
  d := ReadAll(dirB + '/rle8_usual.bmp'); st := ParseAny(d, L);
  Check((st = psOk) and (L.coding = CODING_BMP_RLE) and (L.bits = 8) and (L.dataOffset + L.dataLength = Length(d)),
    'rle8_usual.bmp: RLE8, to its end of bitmap');
  d := ReadAll(dirB + '/rle4_random.bmp'); st := ParseAny(d, L);
  Check((st = psOk) and (L.coding = CODING_BMP_RLE) and (L.bits = 4), 'rle4_random.bmp: RLE4, moves, rows ended early');
  d := ReadAll(dirB + '/rle8_padded.bmp'); st := ParseAny(d, L);
  Check((st = psOk) and (L.dataOffset + L.dataLength = Length(d)), 'rle8_padded.bmp: runs over the rows'' padding');
  d := ReadAll(dirB + '/rle8_usual.bmp');
  st := ParseBmp(Copy(d, 0, Length(d) - 7), L);
  Check((st = psOk) and (L.dataOffset + L.dataLength <= Length(d) - 7), 'RLE8 cut short: the data ends with the file');
  Check(ParseBmp(WithU32(d, 22, Cardinal(-25)), L) = psMalformed, 'RLE8 top-down: malformed');
  dd := Copy(d, 0, Length(d)); dd[14 + 40 + 1024] := 200;
  Check(ParseBmp(dd, L) = psUnsupported, 'RLE8, a run of 200 in a row of 47: unsupported');
  Check(ParseBmp(WithU32(WithU32(d, 18, 60000), 22, 60000), L) = psUnsupported,
    'RLE8, 60000 x 60000 in a few bytes: unsupported, nothing allocated');

  Writeln('several images a file');
  d := ReadAll(dirM + '/ico_three.ico');
  Check(Split(d, parts, fmt) and (fmt = rfICO) and Covers(d, parts) and (Kinds(parts) = 'biiiib')
    and (parts[1].L.bits = 4) and (parts[1].L.dataOffset = 40 + 64) and (parts[2].L.bits = 1)
    and (parts[3].L.channels = 4) and (parts[3].L.height = 24),
    'ico_three.ico: directory, 4-bit and mask, 32-bit and mask, the PNG');
  Check(not Split(WithU32(d, 6 + 16 + 12, Length(d)), parts, fmt), 'ICO, an entry past the end: not split');
  Check(not Split(WithU32(d, 6 + 16 + 12, 54 + 10), parts, fmt), 'ICO, two entries over each other: not split');
  Check(not Split(WithU16(d, 4, 0), parts, fmt), 'ICO of no entries: not split');
  Check(not Split(WithU16(d, 4, 60000), parts, fmt), 'ICO of 60000 entries in a few bytes: not split');
  dd := WithU32(d, 54, 41);
  Check(Split(dd, parts, fmt) and Covers(dd, parts) and (Kinds(parts) = 'biib'),
    'ICO, a DIB header of 41 bytes: that entry kept as bytes');
  d := ReadAll(dirM + '/cur_core.cur');
  Check(Split(d, parts, fmt) and (fmt = rfCUR) and Covers(d, parts) and (Kinds(parts) = 'bii')
    and (parts[1].L.dataOffset = 12 + 6), 'cur_core.cur: OS/2''s 12-byte header, 3-byte colours');
  d := ReadAll(dirM + '/dcx_two.dcx');
  Check(Split(d, parts, fmt) and (fmt = rfDCX) and Covers(d, parts) and (Kinds(parts) = 'bii')
    and (parts[2].L.channels = 3) and (parts[2].L.coding = CODING_PCX), 'dcx_two.dcx: the table, two PCX');
  Check(not Split(WithU32(d, 8, 4000), parts, fmt), 'DCX, offsets going back: not split');
  Check(not Split(WithU32(d, 8, Length(d) + 1), parts, fmt), 'DCX, an offset past the end: not split');
  dd := WithU32(d, 4, 4); dd := WithU32(dd, 8, 0);
  Check(not Split(dd, parts, fmt), 'DCX, an offset inside its own table: not split');
  d := ReadAll(dirM + '/pnm_three.pgm');
  Check(Split(d, parts, fmt) and (fmt = rfPGM) and Covers(d, parts) and (Kinds(parts) = 'iiib')
    and (parts[1].L.format = rfPPM) and (parts[2].L.format = rfPBM) and (parts[3].len = 1),
    'pnm_three.pgm: PGM, PPM, PBM, a byte');
  Check(not Split(ReadAll(dirO + '/../pnm/gray8.pgm'), parts, fmt), 'one PGM: not split');
  d := ReadAll(dirM + '/dds_cube_mips.dds');
  Check(Split(d, parts, fmt) and (fmt = rfDDS) and Covers(d, parts) and (Kinds(parts) = 'iiiiiiii')
    and (parts[1].L.width = 4) and (parts[3].L.width = 1) and (parts[4].L.width = 8) and (parts[4].L.dataOffset = 0),
    'dds_cube_mips.dds: two faces of four levels');
  Check(not Split(ReadAll(dirO + '/dds_bgra32.dds'), parts, fmt), 'a DDS without mipmaps: not split');
  { mutated: never an exception, and the parts always cover the file }
  samples := nil; SetLength(samples, 4);
  samples[0] := ReadAll(dirM + '/ico_three.ico'); samples[1] := ReadAll(dirM + '/dcx_two.dcx');
  samples[2] := ReadAll(dirM + '/dds_cube_mips.dds'); samples[3] := ReadAll(dirM + '/cur_core.cur');
  bad := 0; oks := 0;
  for i := 1 to 8000 do begin
    d := Copy(samples[i mod 4], 0, Length(samples[i mod 4]));
    if i mod 5 = 0 then SetLength(d, Integer(Rand mod Cardinal(Length(d))));
    for k := 1 to 1 + Integer(Rand mod 3) do
      if Length(d) > 0 then d[Integer(Rand mod Cardinal(Min(Length(d), 140)))] := Byte(Rand);
    try
      if Split(d, parts, fmt) then begin
        Inc(oks);
        if not Covers(d, parts) then Inc(bad);
      end;
    except
      Inc(bad);
    end;
  end;
  Check(bad = 0, Format('8000 mutated files of several images: no exception, the parts cover them (%d split)', [oks]));

  Writeln('film and science');
  d := ReadAll(dirS + '/dpx_10bit_rgb.dpx'); st := ParseAny(d, L);
  Check((st = psOk) and (L.format = rfDPX) and (L.coding = CODING_PACK10) and (L.channels = 3) and (L.bits = 16)
    and (L.dataOffset = 2048) and (L.dataLength = Pack10Words(29, 3) * 4 * 17) and (L.rowBytes = Pack10Words(29, 3) * 6),
    'dpx_10bit_rgb.dpx: 10 bits, three to a word');
  d := ReadAll(dirS + '/dpx_10bit_rgba_le.dpx'); st := ParseAny(d, L);
  Check((st = psOk) and (L.coding = CODING_PACK10) and (L.channels = 4), 'dpx_10bit_rgba_le.dpx: packing 2, little-endian');
  d := ReadAll(dirS + '/dpx_8bit_padded.dpx'); st := ParseAny(d, L);
  Check((st = psOk) and (L.coding = CODING_RAW) and (L.rowBytes = 40) and (HeaderStride(rfDPX, d, 0, 2048) = 40),
    'dpx_8bit_padded.dpx: rows of 37 bytes in 40');
  dd := Copy(d, 0, Length(d)); dd[770 + 1] := 2;
  Check(ParseDpx(dd, L) = psUnsupported, 'DPX of two image elements: unsupported');
  dd := Copy(d, 0, Length(d)); dd[800] := 99;
  Check(ParseDpx(dd, L) = psUnsupported, 'DPX, a descriptor of 99: unsupported');
  Check(ParseDpx(Copy(d, 0, 900), L) = psTruncated, 'DPX cut after its header: truncated');
  d := ReadAll(dirS + '/cin_10bit.cin'); st := ParseAny(d, L);
  Check((st = psOk) and (L.format = rfCineon) and (L.coding = CODING_PACK10) and (L.dataOffset = 1024),
    'cin_10bit.cin: Cineon, 10 bits packed');
  dd := Copy(d, 0, Length(d)); dd[196 + 28 + 2] := 8;
  Check(ParseCineon(dd, L) = psUnsupported, 'Cineon, channels of 10 and 8 bits: unsupported');
  d := ReadAll(dirS + '/fits_rgb.fits'); st := ParseAny(d, L);
  Check((st = psOk) and (L.format = rfFITS) and (L.coding = CODING_PLANES) and (L.channels = 3) and (L.dataOffset = 2880)
    and L.bottomUp, 'fits_rgb.fits: three planes, after a block of cards');
  d := ReadAll(dirS + '/fits_float.fits'); st := ParseAny(d, L);
  Check((st = psOk) and L.isFloat and L.bigEndian and (L.dataOffset + L.dataLength < Length(d)),
    'fits_float.fits: 32-bit floats, padded to 2880');
  d := ReadAll(dirS + '/fits_16.fits');
  Check(ParseFits(Copy(d, 0, 2000), L) = psMalformed, 'FITS cut inside its first block: malformed');
  dd := Copy(d, 0, Length(d)); for i := 80 * 6 to 80 * 7 - 1 do dd[i] := 32;
  Check(ParseFits(dd, L) = psTruncated, 'FITS without END: truncated');
  dd := Copy(d, 0, Length(d)); dd[80 + 29] := Ord('4'); dd[80 + 28] := Ord('6');
  Check(ParseFits(dd, L) = psUnsupported, 'FITS of 64-bit integers: unsupported');
  d := ReadAll(dirS + '/vicar_byte.img'); st := ParseAny(d, L);
  Check((st = psOk) and (L.format = rfVICAR) and (L.rowBytes = 34) and (L.dataOffset mod 34 = 0),
    'vicar_byte.img: records of 34 bytes, a binary header line');
  d := ReadAll(dirS + '/vicar_half3.img'); st := ParseAny(d, L);
  Check((st = psOk) and (L.coding = CODING_PLANES) and (L.bits = 16) and L.bigEndian, 'vicar_half3.img: HALF, high first, three bands');
  dd := Copy(d, 0, Length(d)); dd[8] := Ord('9');
  Check(ParseVicar(dd, L) <> psOk, 'VICAR, a label size past the file: refused');
  d := ReadAll(dirS + '/dicom_implicit.dcm'); st := ParseAny(d, L);
  Check((st = psOk) and (L.format = rfDICOM) and (L.bits = 16) and not L.bigEndian and (L.dataOffset + L.dataLength = Length(d)),
    'dicom_implicit.dcm: no preamble, implicit VR, a sequence of undefined length');
  d := ReadAll(dirS + '/dicom_rgb_planes.dcm'); st := ParseAny(d, L);
  Check((st = psOk) and (L.coding = CODING_PLANES) and (L.channels = 3) and (L.bits = 8), 'dicom_rgb_planes.dcm: preamble, RGB in planes');
  dd := Copy(d, 0, Length(d)); SetLength(dd, Length(d) - 10);
  Check(ParseDicom(dd, L) <> psOk, 'DICOM, pixel data shorter than its image: refused');
  d := ReadAll(dirS + '/exr_half.exr'); st := ParseAny(d, L);
  Check((st = psOk) and (L.format = rfEXR) and (L.coding = CODING_EXR) and (L.channels = 3) and (L.bits = 16),
    'exr_half.exr: scanlines of halves');
  d := ReadAll(dirS + '/exr_float.exr'); st := ParseAny(d, L);
  Check((st = psOk) and L.isFloat and (L.channels = 2), 'exr_float.exr: two channels of floats');
  i := Length(d) - 25 * 0 - 9 * (8 + 16 * 2 * 4);
  dd := Copy(d, 0, Length(d)); dd[i + 4] := dd[i + 4] xor 1;
  Check(ParseExr(dd, L) = psUnsupported, 'EXR, a line offset not where the line is: unsupported');

  { mutated, anywhere in the first 1024 bytes: DPX's and EXR's fields are deep }
  samples := nil; SetLength(samples, 6);
  samples[0] := ReadAll(dirS + '/dpx_10bit_rgba_le.dpx'); samples[1] := ReadAll(dirS + '/cin_10bit.cin');
  samples[2] := ReadAll(dirS + '/dicom_implicit.dcm'); samples[3] := ReadAll(dirS + '/exr_half.exr');
  samples[4] := ReadAll(dirS + '/vicar_half3.img'); samples[5] := ReadAll(dirS + '/fits_rgb.fits');
  bad := 0; oks := 0;
  for i := 1 to 12000 do begin
    d := Copy(samples[i mod 6], 0, Length(samples[i mod 6]));
    if i mod 5 = 0 then SetLength(d, Integer(Rand mod Cardinal(Length(d))));
    for k := 1 to 1 + Integer(Rand mod 3) do
      if Length(d) > 0 then d[Integer(Rand mod Cardinal(Min(Length(d), 1024)))] := Byte(Rand);
    try
      st := ParseAny(d, L);
      if st = psOk then begin
        Inc(oks);
        if (L.dataOffset < 2) or (L.dataLength < 1) or (L.dataOffset + L.dataLength > Length(d)) then Inc(bad);
      end;
    except
      Inc(bad);
    end;
  end;
  Check(bad = 0, Format('12000 mutated DPX, Cineon, DICOM, EXR, VICAR, FITS: no exception, pixels inside (%d ok)', [oks]));

  Writeln('containers');
  d := ReadAll(dirC + '/tiff_rgb_strips.tif');
  Check(Split(d, parts, fmt) and (fmt = rfTIFF) and Covers(d, parts) and (Kinds(parts) = 'bib')
    and (parts[1].L.height = 23) and (parts[1].L.channels = 3), 'tiff_rgb_strips.tif: five strips, one image');
  d := ReadAll(dirC + '/tiff_packbits.tif');
  Check(Split(d, parts, fmt) and Covers(d, parts) and (Kinds(parts) = 'bib') and (parts[1].L.coding = CODING_PACKBITS),
    'tiff_packbits.tif: PackBits strips, one image');
  d := ReadAll(dirC + '/tiff_planar_gap.tif');
  Check(Split(d, parts, fmt) and Covers(d, parts) and (Kinds(parts) = 'bibibib'), 'tiff_planar_gap.tif: three planes apart');
  d := ReadAll(dirC + '/tiff_tiles.tif');
  Check(Split(d, parts, fmt) and Covers(d, parts) and (parts[1].L.width = 16) and (parts[1].L.height = 16 * 6),
    'tiff_tiles.tif: six tiles stacked');
  d := ReadAll(dirC + '/tiff_big.tif');
  Check(Split(d, parts, fmt) and (fmt = rfTIFF) and Covers(d, parts) and (Kinds(parts) = 'bib'), 'tiff_big.tif: BigTIFF');
  d := ReadAll(dirC + '/tiff_rgb16_mm.tif');
  Check(Split(d, parts, fmt) and (parts[1].L.bits = 16) and parts[1].L.bigEndian, 'tiff_rgb16_mm.tif: 16 bits, big-endian');
  Check(not Split(WithU32(ReadAll(dirC + '/tiff_rgb_strips.tif'), 4, 100000), parts, fmt), 'TIFF, its directory past the end: not split');
  d := ReadAll(dirC + '/tiff_rgb_strips.tif');
  dd := Copy(d, 0, Length(d)); dd[4] := 8; dd[5] := 0; dd[6] := 0; dd[7] := 0;
  Check(not Split(dd, parts, fmt) or Covers(dd, parts), 'TIFF, its directory over its header: never outside the file');
  d := ReadAll(dirC + '/psd_layers_rle.psd');
  Check(Split(d, parts, fmt) and (fmt = rfPSD) and Covers(d, parts) and (Pos('iiii', Kinds(parts)) = 0)
    and (parts[High(parts)].L.coding = CODING_PLANES_PACKBITS) and (parts[High(parts)].L.channels = 3),
    'psd_layers_rle.psd: the layers'' channels, a mask, an interleaved composite');
  d := ReadAll(dirC + '/psd_raw.psd');
  Check(Split(d, parts, fmt) and Covers(d, parts) and (parts[High(parts)].L.coding = CODING_PLANES),
    'psd_raw.psd: a raw composite, its planes interleaved');
  dd := Copy(d, 0, Length(d)); dd[4] := 0; dd[5] := 3;
  Check(not Split(dd, parts, fmt), 'PSD of version 3: not split');
  d := ReadAll(dirC + '/psd_dup.psd');
  Check(Split(d, parts, fmt) and Covers(d, parts) and (parts[High(parts)].L.channels = 1)
    and (parts[High(parts)].len = parts[High(parts) - 2].len),
    'psd_dup.psd: a layer that is the composite: its planes apart, to be copies');
  d := ReadAll(dirC + '/ilbm_5planes.iff'); st := ParseAny(d, L);
  Check((st = psOk) and (L.format = rfIFF) and (L.coding = CODING_ILBM) and (L.width = 48) and (L.channels = 1),
    'ilbm_5planes.iff: five planes, ByteRun1, rows of 48 pixels');
  d := ReadAll(dirC + '/ilbm_24.iff'); st := ParseAny(d, L);
  Check((st = psOk) and (L.channels = 3), 'ilbm_24.iff: 24 planes, three channels');
  d := ReadAll(dirC + '/pbm_chunky.lbm'); st := ParseAny(d, L);
  Check((st = psOk) and (L.width = 30) and (L.coding = CODING_ILBM), 'pbm_chunky.lbm: PBM, bytes');
  d := ReadAll(dirC + '/acbm_4planes.acbm'); st := ParseAny(d, L);
  Check((st = psOk) and (L.dataLength = 2 * 13 * 4 * 2), 'acbm_4planes.acbm: ACBM, whole planes');
  dd := Copy(d, 0, Length(d)); dd[12 + 8 + 9] := 1;
  Check(ParseIff(dd, L) = psUnsupported, 'ILBM with a mask plane: unsupported');
  d := ReadAll(dirC + '/miff_direct.miff'); st := ParseAny(d, L);
  Check((st = psOk) and (L.format = rfMIFF) and (L.channels = 3) and (L.dataLength = 29 * 17 * 3),
    'miff_direct.miff: DirectClass, a comment with a colon in it');
  d := ReadAll(dirC + '/miff_pseudo_rle.miff'); st := ParseAny(d, L);
  Check((st = psOk) and (L.coding = CODING_MIFF_RLE) and (L.channels = 1) and (L.dataOffset + L.dataLength = Length(d)),
    'miff_pseudo_rle.miff: the old header end, a map, run-length');
  d := ReadAll(dirC + '/miff_16.miff'); st := ParseAny(d, L);
  Check((st = psOk) and (L.bits = 16) and L.bigEndian, 'miff_16.miff: 16 bits');
  d := ReadAll(dirC + '/miff_rgba_rle.miff'); st := ParseAny(d, L);
  Check((st = psOk) and (L.channels = 4) and (L.coding = CODING_MIFF_RLE), 'miff_rgba_rle.miff: alpha, run-length');
  dd := Copy(d, 0, Length(d)); SetLength(dd, Length(d) - 3);
  Check(ParseMiff(dd, L) = psTruncated, 'MIFF run-length cut short: truncated');
  Check(ParseMiff(Bytes('id=ImageMagick class=DirectClass columns=3 rows=2 compression=Zip'#12#10':'#26'xx'), L) = psUnsupported,
    'MIFF of Zip: unsupported');
  d := ReadAll(dirC + '/xcf_layers.xcf');
  Check(Split(d, parts, fmt) and (fmt = rfXCF) and Covers(d, parts) and (Kinds(parts) = 'bibibib')
    and (parts[1].L.coding = CODING_XCF) and (parts[1].L.channels = 4) and (parts[3].L.channels = 1),
    'xcf_layers.xcf: two layers and a mask, their tiles as images');
  dd := Copy(d, 0, Length(d)); dd[9] := Ord('v'); dd[10] := Ord('0'); dd[11] := Ord('1'); dd[12] := Ord('1');
  Check(not Split(dd, parts, fmt), 'XCF v011 (64-bit pointers): not split');
  { mutated containers: never an exception, the parts always the whole file }
  samples := nil; SetLength(samples, 7);
  samples[5] := ReadAll(dirC + '/miff_pseudo_rle.miff'); samples[6] := ReadAll(dirC + '/xcf_layers.xcf');
  samples[0] := ReadAll(dirC + '/tiff_planar_gap.tif'); samples[1] := ReadAll(dirC + '/psd_layers_rle.psd');
  samples[2] := ReadAll(dirC + '/tiff_big.tif'); samples[3] := ReadAll(dirC + '/ilbm_5planes.iff');
  samples[4] := ReadAll(dirC + '/tiff_tiles.tif');
  bad := 0; oks := 0;
  for i := 1 to 10000 do begin
    d := Copy(samples[i mod 7], 0, Length(samples[i mod 7]));
    if i mod 5 = 0 then SetLength(d, Integer(Rand mod Cardinal(Length(d))));
    for k := 1 to 1 + Integer(Rand mod 3) do
      if Length(d) > 0 then d[Integer(Rand mod Cardinal(Min(Length(d), 1024)))] := Byte(Rand);
    try
      if Split(d, parts, fmt) then begin Inc(oks); if not Covers(d, parts) then Inc(bad); end
      else if ParseAny(d, L) = psOk then
        if (L.dataOffset + L.dataLength > Length(d)) or (L.dataLength < 1) then Inc(bad);
    except
      Inc(bad);
    end;
  end;
  Check(bad = 0, Format('10000 mutated TIFF, PSD, IFF, MIFF, XCF: no exception, the parts the whole file (%d split)', [oks]));

  Writeln('the layout''s own limits');
  L.Clear; L.width := 9; L.height := 13; L.channels := 1; L.bits := 0;
  Check(SizeRows(L, 1000) = psMalformed, '0 bits a sample: malformed, no division by zero');
  L.bits := 33;
  Check(SizeRows(L, 1000) = psMalformed, '33 bits a sample: malformed');

  Writeln('fuzzing');
  samples := nil;
  for k := 0 to 13 do begin
    SetLength(samples, Length(samples) + 1);
    case k of
      0: samples[High(samples)] := ReadAll(dirB + '/palette8.bmp');
      1: samples[High(samples)] := ReadAll(dirB + '/bgra32.bmp');
      2: samples[High(samples)] := ReadAll(dirH + '/radiance.hdr');
      3: samples[High(samples)] := ReadAll(dirH + '/stb.hdr');
      4: samples[High(samples)] := ReadAll(dirO + '/tga_mapped8.tga');
      5: samples[High(samples)] := ReadAll(dirO + '/pcx_ega.pcx');
      6: samples[High(samples)] := ReadAll(dirO + '/tga_rle_mapped.tga');
      7: samples[High(samples)] := ReadAll(dirO + '/xwd_mapped8_le.xwd');
      8: samples[High(samples)] := ReadAll(dirO + '/viff_rgb_be.viff');
      9: samples[High(samples)] := ReadAll(dirO + '/vips_rgb_be.v');
      10: samples[High(samples)] := ReadAll(dirO + '/dds_mips.dds');
      12: samples[High(samples)] := ReadAll(dirB + '/rle4_random.bmp');
      13: samples[High(samples)] := ReadAll(dirB + '/../pnm/plain_odd16.pgm');
    else samples[High(samples)] := ReadAll(dirO + '/sgi_rle_ymajor.rgb');
    end;
  end;
  bad := 0; oks := 0;
  for i := 1 to 20000 do begin
    d := Copy(samples[i mod 14], 0, Length(samples[i mod 14]));
    if i mod 5 = 0 then SetLength(d, Integer(Rand mod Cardinal(Length(d))));
    for k := 1 to 1 + Integer(Rand mod 3) do
      { VIFF's fields are past its 512-byte comment }
      if Length(d) > 0 then d[Integer(Rand mod Cardinal(Min(Length(d), IfThen(i mod 14 = 8, 620, 120))))] := Byte(Rand);
    try
      st := ParseAny(d, L);
      if st = psOk then begin
        Inc(oks);
        if (L.dataOffset < 2) or (L.dataLength < 1) or (L.dataOffset + L.dataLength > Length(d)) then Inc(bad);
      end;
    except
      Inc(bad);
    end;
  end;
  Check(bad = 0, Format('20000 mutated headers of 13 formats: no exception, pixels inside (%d ok)', [oks]));

  Writeln(cells, ' cells, ', failures, ' failures');
  if (failures > 0) or (cells < 200) then Halt(1);
end.
