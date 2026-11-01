{ Layer 3: the Netpbm parser (prapnm).
  - every variant it takes: the layout it reports, byte for byte;
  - hostile headers: each gives its status, never an exception;
  - fuzzing: valid headers mutated at random and random bytes after a
    magic. Whatever the status, no exception, and on psOk the pixels lie
    inside the file. }
program test_pnm;
{$I ../pra.inc}
uses SysUtils, praraster, prapnm;

var cells, failures: Integer;
procedure Check(ok: Boolean; const what: string);
begin Inc(cells); if ok then Writeln('  ', what:66, '  ok') else begin Inc(failures); Writeln('  ', what:66, '  FAIL'); end; end;

{ header text (with #10 etc.), then `data` pixel bytes and `tail` more }
function Make(const header: string; data, tail: Integer): TBytes;
var i: Integer;
begin
  Result := nil;
  SetLength(Result, Length(header) + data + tail);
  for i := 1 to Length(header) do Result[i - 1] := Ord(header[i]);
  for i := Length(header) to High(Result) do Result[i] := Byte(i * 37);
end;

function Parse(const header: string; data, tail: Integer; out L: TRasterLayout): TParseStatus;
begin
  Result := ParsePnm(Make(header, data, tail), L);
end;

procedure Expect(const header: string; data, tail: Integer; want: TParseStatus; const what: string);
var L: TRasterLayout; got: TParseStatus;
begin
  got := Parse(header, data, tail, L);
  Check(got = want, Format('%s: %s', [what, StatusName(got)]));
end;

procedure ExpectLayout(const header: string; data, tail: Integer; f: TRasterFormat;
  w, h, ch, bits: Int64; rowBytes: Int64; const what: string);
var L: TRasterLayout; got: TParseStatus;
begin
  got := Parse(header, data, tail, L);
  Check((got = psOk) and (L.format = f) and (L.width = w) and (L.height = h) and (L.channels = ch)
    and (L.bits = bits) and (L.rowBytes = rowBytes) and (L.dataOffset = Length(header))
    and (L.dataLength = data),
    Format('%s: %s %dx%dx%d %d bits, rows of %d B', [what, FormatName(L.format), L.width, L.height,
      L.channels, L.bits, L.rowBytes]));
end;

{ a plain file given as text: status, and where its numbers are }
procedure ExpectPlain(const text: string; want: TParseStatus; offset, len: Int64; const what: string);
var L: TRasterLayout; got: TParseStatus; d: TBytes; i: Integer;
begin
  d := nil; SetLength(d, Length(text));
  for i := 1 to Length(text) do d[i - 1] := Ord(text[i]);
  got := ParsePnm(d, L);
  if want = psOk then
    Check((got = psOk) and (L.coding = CODING_PLAIN) and (L.dataOffset = offset) and (L.dataLength = len),
      Format('%s: %s, numbers at %d, %d B', [what, StatusName(got), L.dataOffset, L.dataLength]))
  else Check(got = want, Format('%s: %s', [what, StatusName(got)]));
end;

var seed: Cardinal;
function Rand: Cardinal;
begin seed := seed xor (seed shl 13); seed := seed xor (seed shr 17); seed := seed xor (seed shl 5); Result := seed; end;

const
  LF = #10;
  VALID: array[0..5] of string = (
    'P5 3 2 255' + LF,
    'P6' + LF + '# comment' + LF + '4 3' + LF + '65535' + LF,
    'P4 10 3' + LF,
    'P7' + LF + 'WIDTH 2' + LF + 'HEIGHT 2' + LF + 'DEPTH 4' + LF + 'MAXVAL 255' + LF + 'ENDHDR' + LF,
    'PF' + LF + '2 2' + LF + '-1.0' + LF,
    'Pf' + LF + '3 1' + LF + '1.0' + LF);
var
  L: TRasterLayout; d: TBytes; i, k, n, bad, oks: Integer; st: TParseStatus;
begin
  cells := 0; failures := 0; seed := 2463534242;

  Writeln('variants');
  ExpectLayout('P5 3 2 255' + LF, 6, 0, rfPGM, 3, 2, 1, 8, 3, 'P5, 8 bits');
  ExpectLayout('P5 3 2 65535' + LF, 12, 0, rfPGM, 3, 2, 1, 16, 6, 'P5, 16 bits');
  ExpectLayout('P5 3 2 256' + LF, 12, 0, rfPGM, 3, 2, 1, 16, 6, 'P5, maxval 256 is two bytes a sample');
  ExpectLayout('P6' + #13#10 + '# made by hand' + #13#10 + '4 3' + #13#10 + '255' + #10, 36, 0, rfPPM, 4, 3, 3, 8, 12,
    'P6 with CRLF and a comment');
  ExpectLayout('P6 2#x' + LF + ' 2 # y' + LF + '255' + LF, 12, 0, rfPPM, 2, 2, 3, 8, 6, 'P6, comment right after a number');
  ExpectLayout('P6' + #9 + '1' + #11 + '1' + #12 + '7' + #13, 3, 0, rfPPM, 1, 1, 3, 8, 3, 'P6, TAB VT FF CR as whitespace');
  ExpectLayout('P4 10 3' + LF, 6, 0, rfPBM, 10, 3, 1, 1, 2, 'P4, width 10: rows of 2 bytes');
  ExpectLayout('P4 8 1' + LF, 1, 0, rfPBM, 8, 1, 1, 1, 1, 'P4, width 8');
  ExpectLayout('P4 1 1' + LF, 1, 0, rfPBM, 1, 1, 1, 1, 1, 'P4, 1x1');
  ExpectLayout('P5 3 2 255' + LF, 6, 5, rfPGM, 3, 2, 1, 8, 3, 'P5 followed by 5 bytes: they are the tail');
  ExpectLayout('P7' + LF + 'WIDTH 2' + LF + 'HEIGHT 2' + LF + 'DEPTH 4' + LF + 'MAXVAL 255' + LF +
    'TUPLTYPE RGB_ALPHA' + LF + 'ENDHDR' + LF, 16, 0, rfPAM, 2, 2, 4, 8, 8, 'P7 RGB_ALPHA');
  ExpectLayout('P7' + LF + '# comment' + LF + '  WIDTH   3  ' + LF + LF + 'HEIGHT 1' + LF + 'DEPTH 2' + LF +
    'MAXVAL 1000' + LF + 'ENDHDR' + LF, 12, 0, rfPAM, 3, 1, 2, 16, 12, 'P7, comment, blanks, blank line, 16 bits');
  ExpectLayout('PF' + LF + '2 2' + LF + '-1.0' + LF, 48, 0, rfPFM, 2, 2, 3, 32, 24, 'PF, three floats a pixel');
  ExpectLayout('Pf' + LF + '3 1' + LF + '1.5e0' + LF, 12, 0, rfPFM, 3, 1, 1, 32, 12, 'Pf, one float a pixel');
  ParsePnm(Make('PF' + LF + '2 2' + LF + '-1.0' + LF, 48, 0), L);
  Check(not L.bigEndian and L.isFloat and L.bottomUp, 'PF, negative scale: little-endian, bottom-up, float');
  ParsePnm(Make('Pf' + LF + '3 1' + LF + '1.0' + LF, 12, 0), L);
  Check(L.bigEndian, 'Pf, positive scale: big-endian');
  ParsePnm(Make('P5 3 2 255' + LF, 6, 0), L);
  Check((L.maxval = 255) and L.bigEndian and not L.isFloat and not L.bottomUp, 'P5: maxval 255, top-down, integers');

  Writeln('hostile headers');
  Expect('', 0, 0, psNotThis, 'empty');
  Expect('P', 0, 0, psNotThis, 'one byte');
  Expect('BM', 10, 0, psNotThis, 'a BMP');
  Expect('P8 1 1 255' + LF, 1, 0, psNotThis, 'P8');
  Expect('P5abc', 10, 0, psNotThis, '"P5" then garbage');
  ExpectPlain('P1' + LF + '1 1' + LF + '0' + LF, psOk, 6, 2, 'P1, plain PBM');
  ExpectPlain('P2 1 1 255' + LF + '0' + LF, psOk, 10, 2, 'P2, plain PGM');
  ExpectPlain('P3 1 1 255' + LF + '0 0 0' + LF, psOk, 10, 6, 'P3, plain PPM');
  ExpectPlain('P1' + LF + '3 1' + LF + '101' + LF, psOk, 6, 4, 'P1, digits run together');
  ExpectPlain('P2 2 1 255' + LF + '1 #a comment' + LF + '2' + LF, psOk, 10, 15, 'P2, a comment between numbers');
  ExpectPlain('P2 1 1 1000' + LF + '65535' + LF, psOk, 11, 6, 'P2, maxval 1000: 16 bits, 65535 fits');
  ExpectPlain('P2 3 1 255' + LF + '1 2', psTruncated, 0, 0, 'P2, two numbers of three');
  ExpectPlain('P2 2 1 255' + LF + '12' + LF, psTruncated, 0, 0, 'P2, "12": one number, not two');
  ExpectPlain('P2 1 1 255' + LF + '256' + LF, psUnsupported, 0, 0, 'P2, 256 in 8 bits');
  ExpectPlain('P1' + LF + '2 1' + LF + '02' + LF, psUnsupported, 0, 0, 'P1, a digit 2');
  ExpectPlain('P2 1 1 255' + LF + '00000000000000000007' + LF, psUnsupported, 0, 0, 'P2, 19 zeros before a number');
  ExpectPlain('P2 1 1 255' + LF + 'x' + LF, psMalformed, 0, 0, 'P2, a letter for a number');
  Expect('P1x', 0, 0, psNotThis, '"P1x"');
  Expect('P5 3 2 255' + LF, 5, 0, psTruncated, 'P5 one byte short');
  Expect('P5 3 2 255' + LF, 0, 0, psTruncated, 'P5 with no pixels');
  Expect('P5 3 2 255', 0, 0, psMalformed, 'P5 ending right after maxval');
  Expect('P5 3 2 255x', 6, 0, psMalformed, 'P5, maxval not followed by whitespace');
  Expect('P5 3 2 0' + LF, 6, 0, psMalformed, 'maxval 0');
  Expect('P5 3 2 65536' + LF, 12, 0, psMalformed, 'maxval 65536');
  Expect('P5 0 2 255' + LF, 6, 0, psMalformed, 'width 0');
  Expect('P5 3 0 255' + LF, 6, 0, psMalformed, 'height 0');
  Expect('P5 -3 2 255' + LF, 6, 0, psMalformed, 'negative width');
  Expect('P5 16777217 1 255' + LF, 6, 0, psMalformed, 'width 2^24 + 1');
  Expect('P5 99999999999999999999999 2 255' + LF, 6, 0, psMalformed, 'a width that overflows 64 bits');
  Expect('P5 16777216 16777216 255' + LF, 100, 0, psTruncated, '2^24 x 2^24 with 100 bytes: truncated, no overflow');
  Expect('P6 16777216 16777216 65535' + LF, 0, 0, psTruncated, '2^24 x 2^24 x 3 x 16 bits: truncated');
  Expect('P5 3' + LF, 0, 0, psMalformed, 'no height');
  Expect('P5 3 2 # comment to the end', 0, 0, psMalformed, 'header ends inside a comment');
  Expect('P7' + LF + 'WIDTH 2' + LF + 'HEIGHT 2' + LF + 'MAXVAL 255' + LF + 'ENDHDR' + LF, 8, 0, psMalformed,
    'P7 without DEPTH');
  Expect('P7' + LF + 'WIDTH 2' + LF + 'HEIGHT 2' + LF + 'DEPTH 1' + LF + 'MAXVAL 255' + LF, 8, 0, psMalformed,
    'P7 without ENDHDR');
  Expect('P7' + LF + 'WIDTH 2' + LF + 'HEIGHT 2' + LF + 'DEPTH 257' + LF + 'MAXVAL 255' + LF + 'ENDHDR' + LF, 8, 0,
    psMalformed, 'P7, DEPTH 257');
  Expect('P7' + LF + 'WIDTH 2 x' + LF + 'HEIGHT 2' + LF + 'DEPTH 1' + LF + 'MAXVAL 255' + LF + 'ENDHDR' + LF, 4, 0,
    psMalformed, 'P7, junk after a value');
  Expect('P7' + LF + 'COLOR 2' + LF + 'ENDHDR' + LF, 4, 0, psMalformed, 'P7, unknown keyword');
  Expect('P7 WIDTH 2' + LF, 4, 0, psMalformed, 'P7 not followed by a newline');
  Expect('PF' + LF + '2 2' + LF + 'abc' + LF, 48, 0, psMalformed, 'PF, scale "abc"');
  Expect('PF' + LF + '2 2' + LF + '-1.0' + LF, 47, 0, psTruncated, 'PF one byte short');

  Writeln('fuzzing');
  bad := 0; oks := 0;
  for i := 1 to 20000 do begin
    d := Make(VALID[i mod Length(VALID)], 64, Integer(Rand mod 8));
    n := 1 + Integer(Rand mod 4);
    for k := 1 to n do d[Integer(Rand mod Cardinal(Length(d)))] := Byte(Rand);
    try
      st := ParsePnm(d, L);
      if st = psOk then begin
        Inc(oks);
        if (L.dataOffset < 2) or (L.dataLength < 1) or (L.dataOffset + L.dataLength > Length(d))
           or (L.rowBytes * L.height <> L.dataLength) then Inc(bad);
      end;
    except
      Inc(bad);
    end;
  end;
  Check(bad = 0, Format('20000 mutated headers: no exception, pixels inside (%d ok)', [oks]));
  bad := 0;
  for i := 1 to 20000 do begin
    SetLength(d, 3 + Integer(Rand mod 40));
    d[0] := Ord('P'); d[1] := Ord(VALID[i mod Length(VALID)][2]); d[2] := 32;
    for k := 3 to High(d) do d[k] := Byte(Rand);
    try
      st := ParsePnm(d, L);
      if (st = psOk) and (L.dataOffset + L.dataLength > Length(d)) then Inc(bad);
    except
      Inc(bad);
    end;
  end;
  Check(bad = 0, '20000 random headers after a magic: no exception');

  Writeln(cells, ' cells, ', failures, ' failures');
  if (failures > 0) or (cells < 59) then Halt(1);
end.
