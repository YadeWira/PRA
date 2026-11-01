{ Layer 3: the Netpbm family's parser. Binary PBM (P4), PGM (P5) and PPM
  (P6), PAM (P7) and PFM (PF, Pf).

  Netpbm: netpbm.sourceforge.net/doc (pbm, pgm, ppm, pam, pfm). The header
  is ASCII: tokens separated by whitespace (space, TAB, CR, LF, VT, FF), and
  in P4/P5/P6 a '#' starts a comment that runs to the end of the line. After
  the last token comes exactly ONE whitespace byte, then the raster.

  - P4: 1 bit per pixel, rows padded to a whole byte; no maxval.
  - P5/P6: one or three samples a pixel, one byte each if maxval < 256,
    otherwise two, most significant first.
  - P7: lines of "KEYWORD value" ending with ENDHDR; DEPTH samples a pixel.
  - PF/Pf: three or one 32-bit float a pixel, rows from the bottom up; the
    scale's sign gives the byte order (negative: little-endian).

  Samples above maxval are not an error here: the codec models the bytes as
  they are, and maxval is only a hint. The plain (text) variants P1, P2
  and P3: the header as theirs, then the numbers as text (praplain, which
  keeps the writer's formatting); the header ends right after its last
  number. }
unit prapnm;

{$I pra.inc}
{$ifopt R-}{$fatal prapnm: range checks ($R+) are mandatory}{$endif}
{$ifopt Q-}{$fatal prapnm: overflow checks ($Q+) are mandatory}{$endif}

interface

uses SysUtils, praraster;

{ Parses the header at the start of d. On psOk, L describes the file. }
function ParsePnm(const d: TBytes; out L: TRasterLayout): TParseStatus;

implementation

uses pralimits, praplain;

function IsSpace(b: Byte): Boolean; inline;
begin
  Result := (b = 32) or ((b >= 9) and (b <= 13));
end;

function IsDigit(b: Byte): Boolean; inline;
begin
  Result := (b >= Ord('0')) and (b <= Ord('9'));
end;

{ The header scanner: positions in d, never past `limit` (the end of the
  data or MAX_TEXT_HEADER, whichever comes first). }
type
  TScan = record
    p, limit: SizeInt;
  end;

procedure SkipSpaceAndComments(const d: TBytes; var s: TScan);
begin
  while s.p < s.limit do begin
    if IsSpace(d[s.p]) then Inc(s.p)
    else if d[s.p] = Ord('#') then begin
      while (s.p < s.limit) and (d[s.p] <> 10) and (d[s.p] <> 13) do Inc(s.p);
    end else Break;
  end;
end;

{ A decimal number of at least one digit, at most maxv; False otherwise.
  Checked before multiplying: it cannot overflow. }
function ReadNumber(const d: TBytes; var s: TScan; maxv: Int64; out v: Int64): Boolean;
var digit: Integer; any: Boolean;
begin
  v := 0; any := False;
  while (s.p < s.limit) and IsDigit(d[s.p]) do begin
    digit := d[s.p] - Ord('0');
    if v > (maxv - digit) div 10 then Exit(False);
    v := v * 10 + digit;
    any := True;
    Inc(s.p);
  end;
  Result := any;
end;

{ The one whitespace byte that ends a header. }
function TakeOneSpace(const d: TBytes; var s: TScan): Boolean;
begin
  Result := (s.p < s.limit) and IsSpace(d[s.p]);
  if Result then Inc(s.p);
end;

function Finish(const d: TBytes; var L: TRasterLayout; p: SizeInt): TParseStatus;
begin
  L.dataOffset := p;
  Result := SizeRows(L, Length(d) - p);
end;

{ P4, P5, P6, and plain P1, P2, P3 }
function ParseClassic(const d: TBytes; var s: TScan; var L: TRasterLayout; plain: Boolean): TParseStatus;
var v, used: Int64;
begin
  SkipSpaceAndComments(d, s);
  if not ReadNumber(d, s, MAX_DIMENSION, L.width) then Exit(psMalformed);
  SkipSpaceAndComments(d, s);
  if not ReadNumber(d, s, MAX_DIMENSION, L.height) then Exit(psMalformed);
  if L.format = rfPBM then begin
    L.channels := 1; L.bits := 1; L.maxval := 1;
  end else begin
    SkipSpaceAndComments(d, s);
    if not ReadNumber(d, s, 65535, v) or (v < 1) then Exit(psMalformed);
    L.maxval := v;
    if L.format = rfPPM then L.channels := 3 else L.channels := 1;
    if v < 256 then L.bits := 8 else L.bits := 16;
  end;
  if plain then begin
    { the numbers' text (praplain) }
    L.coding := CODING_PLAIN;
    L.dataOffset := s.p;
    Result := SizeRows(L, High(Int64) shr 2);
    if Result = psOk then
      Result := PlainLength(d, s.p, L.width * L.height * L.channels, L.bits = 1, (1 shl L.bits) - 1, used);
    if Result = psOk then L.dataLength := used;
    Exit;
  end;
  if not TakeOneSpace(d, s) then Exit(psMalformed);
  Result := Finish(d, L, s.p);
end;

{ P7: lines up to ENDHDR }
function ParsePam(const d: TBytes; var s: TScan; var L: TRasterLayout): TParseStatus;
var
  kw: string; v: Int64; haveW, haveH, haveD, haveM: Boolean; lineEnd: SizeInt;
begin
  haveW := False; haveH := False; haveD := False; haveM := False;
  if not ((s.p < s.limit) and (d[s.p] = 10)) then Exit(psMalformed);
  Inc(s.p);
  repeat
    lineEnd := s.p;
    while (lineEnd < s.limit) and (d[lineEnd] <> 10) do Inc(lineEnd);
    if lineEnd >= s.limit then Exit(psMalformed);       { no ENDHDR }
    while (s.p < lineEnd) and IsSpace(d[s.p]) do Inc(s.p);
    if (s.p < lineEnd) and (d[s.p] <> Ord('#')) then begin
      kw := '';
      while (s.p < lineEnd) and not IsSpace(d[s.p]) do begin
        kw := kw + Chr(d[s.p]); Inc(s.p);
      end;
      if kw = 'ENDHDR' then Break;
      if kw = 'TUPLTYPE' then begin
        s.p := lineEnd + 1; Continue;
      end;
      while (s.p < lineEnd) and IsSpace(d[s.p]) do Inc(s.p);
      if kw = 'WIDTH' then begin
        if not ReadNumber(d, s, MAX_DIMENSION, L.width) then Exit(psMalformed); haveW := True;
      end else if kw = 'HEIGHT' then begin
        if not ReadNumber(d, s, MAX_DIMENSION, L.height) then Exit(psMalformed); haveH := True;
      end else if kw = 'DEPTH' then begin
        if not ReadNumber(d, s, MAX_CHANNELS, v) then Exit(psMalformed);
        L.channels := v; haveD := True;
      end else if kw = 'MAXVAL' then begin
        if not ReadNumber(d, s, 65535, v) or (v < 1) then Exit(psMalformed);
        L.maxval := v; haveM := True;
      end else Exit(psMalformed);
      { nothing but blanks after the value }
      while (s.p < lineEnd) and IsSpace(d[s.p]) do Inc(s.p);
      if s.p <> lineEnd then Exit(psMalformed);
    end;
    s.p := lineEnd + 1;
  until False;
  if not (haveW and haveH and haveD and haveM) then Exit(psMalformed);
  if L.maxval < 256 then L.bits := 8 else L.bits := 16;
  Result := Finish(d, L, lineEnd + 1);
end;

{ PF, Pf }
function ParsePfm(const d: TBytes; var s: TScan; var L: TRasterLayout): TParseStatus;
var first: SizeInt; digits: Boolean; b: Byte;
begin
  SkipSpaceAndComments(d, s);
  if not ReadNumber(d, s, MAX_DIMENSION, L.width) then Exit(psMalformed);
  SkipSpaceAndComments(d, s);
  if not ReadNumber(d, s, MAX_DIMENSION, L.height) then Exit(psMalformed);
  SkipSpaceAndComments(d, s);
  { the scale: a decimal number, only its sign matters }
  first := s.p; digits := False;
  while s.p < s.limit do begin
    b := d[s.p];
    if IsDigit(b) then digits := True
    else if not (Chr(b) in ['+', '-', '.', 'e', 'E']) then Break;
    Inc(s.p);
  end;
  if not digits then Exit(psMalformed);
  L.bigEndian := d[first] <> Ord('-');
  L.bits := 32; L.isFloat := True; L.bottomUp := True;
  if not TakeOneSpace(d, s) then Exit(psMalformed);
  Result := Finish(d, L, s.p);
end;

function ParsePnm(const d: TBytes; out L: TRasterLayout): TParseStatus;
var s: TScan;
begin
  L.Clear;
  if (Length(d) < 2) or (d[0] <> Ord('P')) then Exit(psNotThis);
  case Chr(d[1]) of
    '4': L.format := rfPBM;
    '5': L.format := rfPGM;
    '6': L.format := rfPPM;
    '7': L.format := rfPAM;
    'F': begin L.format := rfPFM; L.channels := 3; end;
    'f': begin L.format := rfPFM; L.channels := 1; end;
    '1': L.format := rfPBM;
    '2': L.format := rfPGM;
    '3': L.format := rfPPM;
  else Exit(psNotThis);
  end;
  s.p := 2;
  s.limit := Length(d);
  if s.limit > MAX_TEXT_HEADER then s.limit := MAX_TEXT_HEADER;
  case L.format of
    rfPAM: Result := ParsePam(d, s, L);
    rfPFM: Result := ParsePfm(d, s, L);
  else Result := ParseClassic(d, s, L, d[1] in [Ord('1'), Ord('2'), Ord('3')]);
  end;
  { "P5" and garbage is not a broken PGM: tell it apart by the first byte
    after the magic, which in every real header is whitespace }
  if (Result = psMalformed) and ((Length(d) < 3) or not IsSpace(d[2])) then Result := psNotThis;
  if Result <> psOk then L.format := rfNone;
end;

end.
