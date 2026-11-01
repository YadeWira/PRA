{ Layer 3: the BMP, Radiance HDR, farbfeld, TGA, Sun Raster and WBMP
  parsers (prabmp, prahdr, praother).
  - the samples (tests/bmp, tests/hdr): the layout each reports, and for
    HDR the coder found for each line (Radiance's, stb's, flat);
  - hostile headers: each gives its status, never an exception, and a huge
    declared image allocates nothing;
  - fuzzing: the samples' headers mutated at random: no exception, and on
    psOk the pixels lie inside the file.

    test_parsers <tests/bmp> <tests/hdr> <tests/other> }
program test_parsers;
{$I ../pra.inc}
uses SysUtils, Classes, Math, praraster, prabmp, prahdr, praother, pracodec;

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

function AllModes(const modes: TBytes; m: Byte): Boolean;
var i: Integer;
begin
  Result := Length(modes) > 0;
  for i := 0 to High(modes) do if modes[i] <> m then Exit(False);
end;

var
  dirB, dirH, dirO: string; d, rgbe, modes: TBytes; L: TRasterLayout; st: TParseStatus; used: Int64;
  i, k, bad, oks: Integer; samples: array of TBytes; hdrText: string;
begin
  cells := 0; failures := 0; seed := 88172645;
  dirB := ParamStr(1); dirH := ParamStr(2); dirO := ParamStr(3);

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
  ExpectBmp(WithU32(d, 30, 1), psUnsupported, 'RLE8');
  ExpectBmp(WithU32(d, 30, 2), psUnsupported, 'RLE4');
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
  d[23] := 2; ExpectSun(d, psUnsupported, 'Sun, run-length (type 2)');
  d[23] := 1; d[15] := 7; ExpectSun(d, psMalformed, 'Sun, depth 7');
  d := ReadAll(dirO + '/ff_rgba16.ff');
  Check(ParseFarbfeld(Copy(d, 0, Length(d) - 1), L) = psTruncated, 'farbfeld one byte short: truncated');
  Check(ParseFarbfeld(Copy(d, 0, 12), L) = psMalformed, 'farbfeld cut inside the header: malformed');
  d := ReadAll(dirO + '/wbmp_shape.wbmp');
  Check(ParseWbmp(Copy(d, 0, Length(d) - 1), L) = psNotThis, 'WBMP one byte short: not a WBMP (its signature is weak)');
  Check(ParseWbmp(Bytes(#0#0#$FF#$FF#$FF#$FF#$7F#1), L) = psNotThis, 'WBMP, a width of 5 bytes');

  Writeln('the layout''s own limits');
  L.Clear; L.width := 9; L.height := 13; L.channels := 1; L.bits := 0;
  Check(SizeRows(L, 1000) = psMalformed, '0 bits a sample: malformed, no division by zero');
  L.bits := 33;
  Check(SizeRows(L, 1000) = psMalformed, '33 bits a sample: malformed');

  Writeln('fuzzing');
  samples := nil;
  for k := 0 to 7 do begin
    SetLength(samples, Length(samples) + 1);
    case k of
      0: samples[High(samples)] := ReadAll(dirB + '/palette8.bmp');
      1: samples[High(samples)] := ReadAll(dirB + '/bgra32.bmp');
      2: samples[High(samples)] := ReadAll(dirH + '/radiance.hdr');
      3: samples[High(samples)] := ReadAll(dirH + '/stb.hdr');
      4: samples[High(samples)] := ReadAll(dirO + '/tga_mapped8.tga');
      5: samples[High(samples)] := ReadAll(dirO + '/ras_mapped8.ras');
      6: samples[High(samples)] := ReadAll(dirO + '/tga_rle_mapped.tga');
    else samples[High(samples)] := ReadAll(dirO + '/wbmp_shape.wbmp');
    end;
  end;
  bad := 0; oks := 0;
  for i := 1 to 20000 do begin
    d := Copy(samples[i mod 8], 0, Length(samples[i mod 8]));
    if i mod 5 = 0 then SetLength(d, Integer(Rand mod Cardinal(Length(d))));
    for k := 1 to 1 + Integer(Rand mod 3) do
      if Length(d) > 0 then d[Integer(Rand mod Cardinal(Min(Length(d), 120)))] := Byte(Rand);
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
  Check(bad = 0, Format('20000 mutated headers of 6 formats: no exception, pixels inside (%d ok)', [oks]));

  Writeln(cells, ' cells, ', failures, ' failures');
  if (failures > 0) or (cells < 70) then Halt(1);
end.
