{ The .pra format: round trip with the samples, each header and descriptor
  error with ITS name, and the writer and the reader accepting and rejecting
  exactly the same. Adapted from PJA's test of the .pja format.

    test_format <directory> [directory...]     (tests/pnm) }
program test_format;
{$I ../pra.inc}
uses SysUtils, Classes, pralimits, prablake3, praformat, prapack;

var cells, failures: Integer;
procedure Check(ok: Boolean; const what: string);
begin Inc(cells); if ok then Writeln('  ', what:62, '  ok') else begin Inc(failures); Writeln('  ', what:62, '  FAIL'); end; end;
procedure CheckR(const r: TPraResult; const expected, what: string);
begin
  Inc(cells);
  if r.Text = expected then Writeln('  ', what:62, '  ok')
  else begin Inc(failures); Writeln('  ', what:62, '  FAIL: gave ', r.Text, ', expected ', expected); end;
end;

function Same(const x, y: TBytes): Boolean;
begin Result := (Length(x) = Length(y)) and ((Length(x) = 0) or CompareMem(@x[0], @y[0], Length(x))); end;
function ReadAll(const f: string): TBytes; var s: TFileStream;
begin s := TFileStream.Create(f, fmOpenRead or fmShareDenyNone); try Result := nil; SetLength(Result, s.Size);
  if s.Size > 0 then s.ReadBuffer(Result[0], s.Size); finally s.Free; end; end;
function Filled(n: SizeInt; v: Byte): TBytes;
begin Result := nil; SetLength(Result, n); if n > 0 then FillChar(Result[0], n, v); end;
function WithByte(const x: TBytes; i: SizeInt; v: Byte): TBytes;
begin Result := Copy(x, 0, Length(x)); Result[i] := v; end;

{ A .pra built by hand, without going through the writer: so the reader sees
  descriptors the writer refuses to produce: `ext` (whatever it holds) with
  its check, or with a wrong one. }
function ByHand(origSize: QWord; const hash: THash16; const payload: TBytes; stored: Boolean = False;
                ver: Byte = VERSION; const ext: string = ''; badCheck: Boolean = False): TBytes;
var k, at: Integer; c: THash16;
begin
  Result := nil;
  at := HEADER_SIZE + DESCRIPTOR_SIZE;
  at := at + 1 + Length(ext) + EXT_CHECK;
  SetLength(Result, at + Length(payload));
  for k := 0 to 3 do Result[k] := MAGIC[k];
  Result[4] := ver;
  if stored then Result[5] := FLAG_STORED;
  for k := 0 to 7 do Result[8 + k] := Byte((origSize shr (8 * k)) and $FF);
  Move(hash[0], Result[16], 16);
  begin
    Result[32] := Length(ext);
    for k := 1 to Length(ext) do Result[32 + k] := Ord(ext[k]);
    c := ExtensionCheck(ext);
    if badCheck then c[0] := c[0] xor 1;
    Move(c[0], Result[33 + Length(ext)], EXT_CHECK);
  end;
  if Length(payload) > 0 then Move(payload[0], Result[at], Length(payload));
end;

var
  files: TStringList; sr: TSearchRec; f: string; d: Integer;
  orig, b, other, back: TBytes; h, h2, hx: THash16; p: TPra; r, rw: TPraResult; pr: TPackResult;
  i, n, k, symmetric: Integer;
  cases: array of record orig_size: QWord; len: SizeInt; expected: string; end;
begin
  cells := 0; failures := 0;
  files := TStringList.Create; files.Sorted := True;
  for d := 1 to ParamCount do
    if FindFirst(ParamStr(d) + '/*', faAnyFile, sr) = 0 then begin
      repeat if (sr.Attr and faDirectory) = 0 then files.Add(ParamStr(d) + '/' + sr.Name); until FindNext(sr) <> 0;
      FindClose(sr);
    end;
  Check(files.Count >= 10, Format('samples: %d files', [files.Count]));

  Writeln('--- round trip through Pack and Unpack, with each file');
  for f in files do begin
    orig := ReadAll(f);
    pr := Pack(orig, b);
    Check(pr.Ok, ExtractFileName(f) + ': Pack ' + pr.Text);
    if not pr.Ok then Continue;
    r := Open(b, p); h := Blake3_128(orig);
    Check(r.Ok and (p.orig_size = QWord(Length(orig))) and CompareMem(@p.hash, @h, 16)
       and (Length(b) = WrittenLength(Length(p.payload), Length(p.ext))), '  opens: orig_size, hash, length');
    pr := Unpack(b, High(QWord), back, hx);
    Check(pr.Ok and Same(back, orig), '  Unpack gives the original byte for byte');
  end;
  { a sample the codec does shrink, so that its .pra is a codec stream }
  f := files[0];
  for k := 0 to files.Count - 1 do
    if ExtractFileName(files[k]) = 'color.ppm' then f := files[k];
  orig := ReadAll(f); Pack(orig, b); Open(b, p); h := p.hash;
  Check(not p.stored, 'the header and descriptor cases run on a codec stream');

  Writeln('--- Unpack: the caller''s cap and what does not verify');
  pr := Unpack(b, Length(orig) - 1, back, hx);
  Check((pr.err = ukTooLarge) and (Length(back) = 0), 'a cap one byte below the original: TooLarge, nothing');
  pr := Unpack(b, Length(orig), back, hx);
  Check(pr.Ok, 'a cap equal to the original: fine');
  other := WithByte(b, 16, b[16] xor 1);
  pr := Unpack(other, High(QWord), back, hx);
  Check((pr.err = ukHashMismatch) and Same(back, orig) and (hx[0] = b[16] xor 1),
     'one bit of the hash: HashMismatch, with the decoded and the expected');
  other := Copy(b, 0, Length(b)); other[8] := other[8] xor 1;
  pr := Unpack(other, High(QWord), back, hx);
  Check((not pr.Ok) and (Length(back) = 0), 'orig_size one off: ' + pr.Text + ', nothing');

  Writeln('--- header: each error with its name');
  for n := 0 to HEADER_SIZE - 1 do
    CheckR(Open(Copy(b, 0, n), p), 'ShortFile', Format('%d bytes', [n]));
  CheckR(Open(Copy(b, 0, HEADER_SIZE + DESCRIPTOR_SIZE - 1), p), 'ShortFile', 'header and 23 bytes of descriptor');
  CheckR(Open(Copy(b, 0, HEADER_SIZE + DESCRIPTOR_SIZE), p), 'ShortFile', 'header and descriptor, no extension field');
  CheckR(Open(WithByte(b, 0, Ord('X')), p), 'NotPra', 'magic: first byte');
  CheckR(Open(WithByte(b, 3, $02), p), 'NotPra', 'magic: the trailing $01');
  CheckR(Open(WithByte(b, 4, 2), p), 'FutureVersion(2)', 'version 2');
  CheckR(Open(WithByte(b, 4, 255), p), 'FutureVersion(255)', 'version 255');
  CheckR(Open(WithByte(b, 4, 0), p), 'OldVersion(0)', 'version 0');
  for k := 1 to 7 do
    CheckR(Open(WithByte(b, 5, 1 shl k), p), 'UnknownFlag', Format('flag bit %d', [k]));
  CheckR(Open(WithByte(b, 5, FLAG_STORED), p), 'BadOrigSize', 'the stored flag on a codec stream: its length is not orig_size');
  CheckR(Open(WithByte(b, 6, 1), p), 'ReservedNotZero', 'reserved byte 6');
  CheckR(Open(WithByte(b, 7, $80), p), 'ReservedNotZero', 'reserved byte 7');
  CheckR(Open(Filled(200, $41), p), 'NotPra', 'garbage 0x41');
  CheckR(Open(Filled(200, 0), p), 'NotPra', 'zeros');

  Writeln('--- the extension');
  pr := Pack(orig, b, 'PPMx');
  r := Open(b, p);
  Check(pr.Ok and r.Ok and (p.ext = 'PPMx') and (Length(b) = WrittenLength(Length(p.payload), 4)),
     'Pack keeps it as it is written: .PPMx');
  pr := Unpack(b, High(QWord), back, hx);
  Check(pr.Ok and (pr.ext = 'PPMx') and Same(back, orig), '  Unpack gives it, and the original');
  for k := 0 to 4 + EXT_CHECK - 1 do
    CheckR(Open(WithByte(b, HEADER_SIZE + DESCRIPTOR_SIZE + 1 + k, b[HEADER_SIZE + DESCRIPTOR_SIZE + 1 + k] xor 4), p),
           'BadExtension', Format('  a bit of its byte %d', [k]));
  CheckR(Open(WithByte(b, HEADER_SIZE + DESCRIPTOR_SIZE, 3), p), 'BadExtension', '  its length one short: the check gives it away');
  CheckR(Open(WithByte(b, HEADER_SIZE + DESCRIPTOR_SIZE, MAX_EXT + 1), p), 'BadExtension', '  a length above MAX_EXT');
  CheckR(Open(Copy(b, 0, HEADER_SIZE + DESCRIPTOR_SIZE), p), 'ShortFile', '  no extension field at all');
  CheckR(Open(Copy(b, 0, HEADER_SIZE + DESCRIPTOR_SIZE + 1 + 4 + EXT_CHECK - 1), p), 'ShortFile', '  its check cut short');
  pr := Pack(orig, b, '../x');
  r := Open(b, p);
  Check(pr.Ok and r.Ok and (p.ext = ''), 'Pack leaves out an extension the format does not keep (../x)');
  pr := Pack(orig, b, 'abcdefghijklmnop');
  r := Open(b, p);
  Check(pr.Ok and r.Ok and (p.ext = ''), '  and one of 16 characters');
  other := Filled(100, $AB);
  for i := 0 to 5 do begin
    case i of
      0: begin f := 'abcdefghijklmno'; n := 0; end;    { 15: the longest }
      1: begin f := 'a.b'; n := 1; end;
      2: begin f := 'a/b'; n := 1; end;
      3: begin f := 'a b'; n := 1; end;
      4: begin f := 'abcdefghijklmnop'; n := 1; end;
    else begin f := #200; n := 1; end;
    end;
    rw := WritePra(other, h, 1000, b, False, f);
    r := Open(ByHand(1000, h, other, False, VERSION, f), p);
    if n = 0 then begin
      CheckR(rw, 'None', Format('extension %s: the writer', [f])); CheckR(r, 'None', '  and the reader');
    end else begin
      CheckR(rw, 'BadExtension', Format('extension %s: the writer', [f])); CheckR(r, 'BadExtension', '  and the reader');
      Check((p.ext = '') and (Length(p.payload) = 0), '  and the reader leaves nothing read');
    end;
  end;
  CheckR(Open(ByHand(1000, h, other, False, VERSION, 'ppm', True), p), 'BadExtension', 'a wrong check');

  Writeln('--- descriptor: the edges, in the writer AND in the reader');
  { Each case is asked of the writer and built by hand for the reader: they
    must give the SAME verdict. It is the rule the previous container broke. }
  SetLength(cases, 12);
  cases[0].orig_size := 0;     cases[0].len := 100; cases[0].expected := 'BadOrigSize';
  cases[1].orig_size := 1;     cases[1].len := 100; cases[1].expected := 'None';
  cases[2].orig_size := 100 * MAX_EXPANSION_RATIO;     cases[2].len := 100; cases[2].expected := 'None';
  cases[3].orig_size := 100 * MAX_EXPANSION_RATIO + 1; cases[3].len := 100; cases[3].expected := 'RatioExceeded';
  cases[4].orig_size := 100;   cases[4].len := MIN_PAYLOAD - 1; cases[4].expected := 'PayloadOutOfRange';
  cases[5].orig_size := 100;   cases[5].len := MIN_PAYLOAD; cases[5].expected := 'None';
  cases[6].orig_size := 0;     cases[6].len := 0; cases[6].expected := 'PayloadOutOfRange';
  cases[7].orig_size := MIN_PAYLOAD * MAX_EXPANSION_RATIO;     cases[7].len := MIN_PAYLOAD; cases[7].expected := 'None';
  cases[8].orig_size := MIN_PAYLOAD * MAX_EXPANSION_RATIO + 1; cases[8].len := MIN_PAYLOAD; cases[8].expected := 'RatioExceeded';
  cases[9].orig_size := QWord(High(Int64));     cases[9].len := 100;  cases[9].expected := 'RatioExceeded';
  cases[10].orig_size := QWord(High(Int64)) + 1; cases[10].len := 100; cases[10].expected := 'BadOrigSize';
  cases[11].orig_size := High(QWord);           cases[11].len := 100; cases[11].expected := 'BadOrigSize';
  symmetric := 0;
  for i := 0 to High(cases) do begin
    other := Filled(cases[i].len, $AB);
    rw := WritePra(other, h, cases[i].orig_size, b);
    r := Open(ByHand(cases[i].orig_size, h, other), p);
    CheckR(rw, cases[i].expected, Format('write orig_size %u, payload %d', [cases[i].orig_size, cases[i].len]));
    CheckR(r, cases[i].expected, '  and the reader, the same');
    if rw.Text = r.Text then Inc(symmetric);
    if not rw.Ok then Check(Length(b) = 0, '  and the writer hands out nothing');
    if not r.Ok then Check((p.orig_size = 0) and (Length(p.payload) = 0), '  and the reader leaves nothing read');
  end;
  Check(symmetric = Length(cases), Format('writer and reader agree on %d of %d', [symmetric, Length(cases)]));

  Writeln('--- stored as is');
  { the descriptor of a stored payload, in the writer and the reader }
  other := Filled(100, $5C);
  for i := 0 to 3 do begin
    case i of
      0: begin n := 100; f := 'None'; end;
      1: begin n := 99; f := 'BadOrigSize'; end;
      2: begin n := 101; f := 'BadOrigSize'; end;
    else begin n := 0; f := 'BadOrigSize'; end;
    end;
    rw := WritePra(other, h, n, b, True);
    r := Open(ByHand(n, h, other, True), p);
    CheckR(rw, f, Format('stored, 100 B payload, orig_size %d: the writer', [n]));
    CheckR(r, f, '  and the reader');
  end;
  CheckR(WritePra(nil, h, 0, b, True), 'PayloadOutOfRange', 'stored, empty');
  WritePra(other, h, 100, b, True);
  r := Open(b, p);
  Check(r.Ok and p.stored and Same(p.payload, other), 'stored: comes back flagged, the payload as it was');
  { a file the codec does not make smaller is stored, and comes back }
  f := '';
  for k := 0 to files.Count - 1 do
    if ExtractFileName(files[k]) = 'noise.pgm' then f := files[k];
  Check(f <> '', 'the sample the codec cannot shrink (noise.pgm) is there');
  if f <> '' then begin
    orig := ReadAll(f);
    pr := Pack(orig, b);
    r := Open(b, p);
    Check(pr.Ok and r.Ok and p.stored and Same(p.payload, orig), '  Pack stores it as it is');
    Check(Length(b) = WrittenLength(Length(orig)), '  37 bytes more than the original, with no extension');
    pr := Unpack(b, High(QWord), back, hx);
    Check(pr.Ok and Same(back, orig), '  Unpack gives it back');
    other := WithByte(b, Length(b) - 1, b[Length(b) - 1] xor 1);
    pr := Unpack(other, High(QWord), back, hx);
    Check(pr.err = ukHashMismatch, '  a bit of it changed: HashMismatch');
    pr := Unpack(b, Length(orig) - 1, back, hx);
    Check(pr.err = ukTooLarge, '  above the caller''s cap: TooLarge');
  end;

  Writeln('--- what PRA does not take');
  pr := Pack(Filled(100, $41), b);
  Check((pr.err = ukNotRaster) and (Length(b) = 0), 'text: NotRaster, nothing: ' + pr.Text);
  pr := Pack(nil, b);
  Check((pr.err = ukNotRaster) and (Length(b) = 0), 'empty: NotRaster');

  Writeln('--- the hash is just data');
  { The format recomputes nothing over the payload: the hash is of the
    original, and whoever decodes checks it. Any value is stored and comes
    back. }
  FillChar(h2, SizeOf(h2), $FF);
  WritePra(Filled(100, 1), h2, 1000, b);
  r := Open(b, p);
  Check(r.Ok and CompareMem(@p.hash, @h2, 16), 'an all-0xFF hash comes back the same');

  Writeln('--- WrittenLength');
  Check(WrittenLength(0) = HEADER_SIZE + DESCRIPTOR_SIZE + 1 + EXT_CHECK, 'payload 0');
  Check(WrittenLength(1000) = HEADER_SIZE + DESCRIPTOR_SIZE + 1 + EXT_CHECK + 1000, 'payload 1000');
  Check(WrittenLength(1000, 3) = HEADER_SIZE + DESCRIPTOR_SIZE + 1 + 3 + EXT_CHECK + 1000, 'payload 1000, extension of 3');
  Check(WrittenLength(0, MAX_EXT + 1) = -1, 'an extension too long');
  Check(WrittenLength(-1) = -1, 'negative length');
  Check(WrittenLength(High(SizeInt)) = -1, 'a length that does not fit');

  files.Free;
  Writeln; Writeln(cells, ' cells, ', failures, ' failures');
  if cells < 100 then begin Writeln('FAIL: expected at least 100 cells'); Halt(2); end;
  if failures > 0 then Halt(1);
end.
