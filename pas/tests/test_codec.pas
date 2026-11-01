{ Layer 5: the codec stream (pracodec).
  - synthetic images of every layout the codec takes (PBM of awkward widths,
    PGM and PPM of 8 and 16 bits, PAM of 1 to 5 channels, PFM in both byte
    orders with NaN, infinities and negative zero), with comments and tails:
    each comes back byte for byte, and encoding twice gives the same stream;
  - what it does not take (plain PNM, garbage) is refused, not mangled;
  - the decoder's limits: a cap below the file's size is refused before
    decoding; a newer version is named;
  - damage: thousands of flipped bytes and truncations never raise;
  - the BLAKE3 of all the streams, printed: run_tests.sh builds this test
    with and without PRA_FAST and demands the same line. }
program test_codec;
{$I ../pra.inc}
uses {$ifdef UNIX} cthreads, {$endif} SysUtils, prablake3, praraster, pracodec;

var cells, failures: Integer;
procedure Check(ok: Boolean; const what: string);
begin Inc(cells); if ok then Writeln('  ', what:66, '  ok') else begin Inc(failures); Writeln('  ', what:66, '  FAIL'); end; end;

var seed: Cardinal;
function Rand: Cardinal;
begin seed := seed xor (seed shl 13); seed := seed xor (seed shr 17); seed := seed xor (seed shl 5); Result := seed; end;

function Bytes(const s: string): TBytes;
var i: Integer;
begin
  Result := nil; SetLength(Result, Length(s));
  for i := 1 to Length(s) do Result[i - 1] := Ord(s[i]);
end;

procedure Append(var d: TBytes; const more: TBytes);
var n: Integer;
begin
  n := Length(d); SetLength(d, n + Length(more));
  if Length(more) > 0 then Move(more[0], d[n], Length(more));
end;

{ a smooth image with some noise and a few edges: sample (x, y, c) of `bits` }
function Sample(x, y, c, bits: Integer): Cardinal;
var v: Integer;
begin
  v := (x * 7 + y * 3 + c * 40) mod 200 + Integer(Rand mod 9);
  if (x > 10) and (y mod 13 < 4) then v := v + 30;
  if bits = 16 then Result := Cardinal(v) * 257 + Rand mod 64 else Result := Cardinal(v) and 255;
end;

function MakeGray(const header: string; w, h, channels, bits: Integer; bigEndian: Boolean): TBytes;
var x, y, c, n: Integer; v: Cardinal; px: TBytes;
begin
  Result := Bytes(header);
  px := nil; SetLength(px, w * h * channels * (bits div 8)); n := 0;
  for y := 0 to h - 1 do
    for x := 0 to w - 1 do
      for c := 0 to channels - 1 do begin
        v := Sample(x, y, c, bits);
        if bits = 8 then begin px[n] := v; Inc(n); end
        else if bigEndian then begin px[n] := v shr 8; px[n + 1] := v and 255; Inc(n, 2); end
        else begin px[n] := v and 255; px[n + 1] := v shr 8; Inc(n, 2); end;
      end;
  Append(Result, px);
end;

function MakePbm(w, h: Integer): TBytes;
var px: TBytes; rowBytes, i: Integer;
begin
  Result := Bytes(Format('P4'#10'%d %d'#10, [w, h]));
  rowBytes := (w + 7) div 8;
  px := nil; SetLength(px, rowBytes * h);
  for i := 0 to High(px) do
    if (i div rowBytes) mod 5 < 2 then px[i] := Byte(Rand) else px[i] := $F0;
  Append(Result, px);
end;

function MakePfm(w, h, channels: Integer; littleEndian: Boolean): TBytes;
var px: TBytes; i, n: Integer; v: Cardinal;
begin
  if channels = 3 then Result := Bytes('PF'#10) else Result := Bytes('Pf'#10);
  if littleEndian then Append(Result, Bytes(Format('%d %d'#10'-1.000000'#10, [w, h])))
  else Append(Result, Bytes(Format('%d %d'#10'1.0'#10, [w, h])));
  px := nil; SetLength(px, w * h * channels * 4); n := 0;
  for i := 0 to w * h * channels - 1 do begin
    { floats from integers: the same input on every platform }
    v := $3F800000 + Cardinal(i mod 50) * 40000 + Rand mod 256;
    if (i div 50) mod 3 = 1 then v := v or $80000000;
    case i mod 97 of
      5: v := $7FC00000;            { NaN }
      6: v := $7F800000;            { +inf }
      7: v := $FF800000;            { -inf }
      8: v := $80000000;            { -0 }
      9: v := 1;                    { the smallest denormal }
    end;
    if littleEndian then begin
      px[n] := v and 255; px[n + 1] := (v shr 8) and 255; px[n + 2] := (v shr 16) and 255; px[n + 3] := v shr 24;
    end else begin
      px[n] := v shr 24; px[n + 1] := (v shr 16) and 255; px[n + 2] := (v shr 8) and 255; px[n + 3] := v and 255;
    end;
    Inc(n, 4);
  end;
  Append(Result, px);
end;

function Same(const a, b: TBytes): Boolean;
begin
  Result := (Length(a) = Length(b)) and ((Length(a) = 0) or CompareMem(@a[0], @b[0], Length(a)));
end;

var
  all: TBlake3;
  samples: array of TBytes;
  names: array of string;

procedure Add(const name: string; const d: TBytes);
begin
  SetLength(samples, Length(samples) + 1); samples[High(samples)] := d;
  SetLength(names, Length(names) + 1); names[High(names)] := name;
end;

function Hex(const x: array of Byte): string; var i: Integer;
begin Result := ''; for i := 0 to High(x) do Result := Result + LowerCase(IntToHex(x[i], 2)); end;

var
  i, k, n, bad, raised: Integer; s, s2, back, dmg: TBytes; why: string; st: TDecodeStatus; ok: Boolean;
  L: TRasterLayout; streams: array of TBytes;
begin
  cells := 0; failures := 0; seed := 2463534242;
  samples := nil; names := nil;
  Add('PGM 8 bits 40x30', MakeGray('P5 40 30 255'#10, 40, 30, 1, 8, True));
  Add('PGM 8 bits 1x1', MakeGray('P5 1 1 255'#10, 1, 1, 1, 8, True));
  Add('PGM 8 bits 1x50 (one column)', MakeGray('P5 1 50 255'#10, 1, 50, 1, 8, True));
  Add('PGM 8 bits 60x1 (one row)', MakeGray('P5 60 1 255'#10, 60, 1, 1, 8, True));
  Add('PGM 16 bits 33x21', MakeGray('P5 33 21 65535'#10, 33, 21, 1, 16, True));
  Add('PGM maxval 100, samples above it', MakeGray('P5 20 20 100'#10, 20, 20, 1, 8, True));
  Add('PPM 8 bits 37x29, comments, CRLF', MakeGray('P6'#13#10'# synthetic'#13#10'37 29'#13#10'255'#10, 37, 29, 3, 8, True));
  Add('PPM 16 bits 25x17', MakeGray('P6 25 17 65535'#10, 25, 17, 3, 16, True));
  Add('PAM 1 channel', MakeGray('P7'#10'WIDTH 20'#10'HEIGHT 9'#10'DEPTH 1'#10'MAXVAL 255'#10'ENDHDR'#10, 20, 9, 1, 8, True));
  Add('PAM 2 channels 16 bits', MakeGray('P7'#10'WIDTH 17'#10'HEIGHT 11'#10'DEPTH 2'#10'MAXVAL 4095'#10'ENDHDR'#10, 17, 11, 2, 16, True));
  Add('PAM RGB_ALPHA', MakeGray('P7'#10'WIDTH 23'#10'HEIGHT 19'#10'DEPTH 4'#10'MAXVAL 255'#10'TUPLTYPE RGB_ALPHA'#10'ENDHDR'#10, 23, 19, 4, 8, True));
  Add('PAM 5 channels', MakeGray('P7'#10'WIDTH 9'#10'HEIGHT 7'#10'DEPTH 5'#10'MAXVAL 255'#10'ENDHDR'#10, 9, 7, 5, 8, True));
  Add('PBM 1x1', MakePbm(1, 1));
  Add('PBM 7x5', MakePbm(7, 5));
  Add('PBM 8x8', MakePbm(8, 8));
  Add('PBM 9x13', MakePbm(9, 13));
  Add('PBM 100x40', MakePbm(100, 40));
  Add('PFM RGB little-endian, NaN and inf', MakePfm(21, 13, 3, True));
  Add('PFM gray big-endian', MakePfm(30, 10, 1, False));
  s := MakeGray('P5 12 12 255'#10, 12, 12, 1, 8, True); Append(s, Bytes('trailing bytes after the image'));
  Add('PGM with a tail', s);
  s := MakePbm(16, 4); Append(s, MakePbm(16, 4));
  Add('two PBM images in one file', s);
  s := Bytes('P5 64 64 255'#10); SetLength(s, Length(s) + 64 * 64);
  for k := 13 to High(s) do s[k] := Byte(Rand);
  Add('PGM of pure noise', s);

  Writeln('round trips');
  all.Init;
  for i := 0 to High(samples) do begin
    ok := EncodeFile(samples[i], s, why);
    if ok then begin
      st := DecodeFile(s, Length(samples[i]), back);
      ok := (st = dsOk) and Same(back, samples[i]);
      EncodeFile(samples[i], s2, why);
      ok := ok and Same(s, s2);
      all.Update(s[0], Length(s));
    end;
    Check(ok, Format('%s: %d -> %d, back, same stream twice', [names[i], Length(samples[i]), Length(s)]));
  end;

  Writeln('refused');
  Check(not EncodeFile(Bytes('P1'#10'2 2'#10'0 1 1 0'#10), s, why) and (why = 'unsupported variant'), 'plain PBM: ' + why);
  Check(not EncodeFile(Bytes('just some text'), s, why), 'text: ' + why);
  s := nil;
  Check(not EncodeFile(s, s2, why), 'empty: ' + why);

  Writeln('limits and versions');
  EncodeFile(samples[0], s, why);
  Check(DecodeFile(s, Length(samples[0]) - 1, back) = dsTooBig, 'a cap one byte below the file: refused');
  Check(DecodeFile(s, Length(samples[0]), back) = dsOk, 'a cap of exactly the file: decoded');
  s2 := Copy(s, 0, Length(s)); s2[0] := STREAM_VERSION + 1;
  Check(DecodeFile(s2, 1 shl 20, back) = dsFutureVersion, 'version ' + IntToStr(STREAM_VERSION + 1) + ': ' + DecodeStatusName(dsFutureVersion));
  s2[0] := 0;
  Check(DecodeFile(s2, 1 shl 20, back) = dsBadStream, 'version 0: damaged');
  s2 := nil;
  Check(DecodeFile(s2, 1 shl 20, back) = dsEmpty, 'empty stream');

  Writeln('damage');
  streams := nil; SetLength(streams, Length(samples));
  for i := 0 to High(samples) do EncodeFile(samples[i], streams[i], why);
  bad := 0; raised := 0;
  for i := 1 to 3000 do begin
    s := streams[i mod Length(samples)];
    dmg := Copy(s, 0, Length(s));
    if i mod 3 = 0 then SetLength(dmg, Integer(Rand mod Cardinal(Length(dmg))))
    else
      for k := 1 to 1 + Integer(Rand mod 3) do
        if Length(dmg) > 0 then dmg[Integer(Rand mod Cardinal(Length(dmg)))] := Byte(Rand);
    try
      n := Length(samples[i mod Length(samples)]) * 2;
      st := DecodeFile(dmg, n, back);
      if (st = dsOk) and (Length(back) > n) then Inc(bad);
    except
      Inc(raised);
    end;
  end;
  Check((bad = 0) and (raised = 0), Format('3000 damaged streams: no exception (%d), nothing over the cap (%d)', [raised, bad]));
  bad := 0;
  for i := 1 to 2000 do begin
    SetLength(dmg, 1 + Integer(Rand mod 60));
    for k := 0 to High(dmg) do dmg[k] := Byte(Rand);
    dmg[0] := 1;
    try
      st := DecodeFile(dmg, 100000, back);
      if (st = dsOk) and (Length(back) > 100000) then Inc(bad);
    except
      Inc(bad);
    end;
  end;
  Check(bad = 0, '2000 random streams with version 1: no exception');

  { the parser and the codec agree on what a PGM is }
  Check(ParseAny(samples[0], L) = psOk, 'ParseAny takes a PGM');

  Writeln('streams ', Hex(all.Final));
  Writeln(cells, ' cells, ', failures, ' failures');
  if (failures > 0) or (cells < 32) then Halt(1);
end.
