{ The two checksums the PNG family carries: CRC-32 (ISO 3309, the one every
  chunk ends with) and Adler-32 (the one every zlib stream ends with).

  This is the Pascal reference version: one table lookup per byte. A faster
  one, if it is ever needed, is measured against this one. }
unit ppacrc;

{$I ppa.inc}
{$ifopt R-}{$fatal ppacrc: range checks ($R+) are mandatory}{$endif}
{$ifopt Q-}{$fatal ppacrc: overflow checks ($Q+) are mandatory}{$endif}

interface

uses SysUtils;

const
  CRC32_INIT = $FFFFFFFF;

{ Running CRC-32: start with CRC32_INIT, feed with Crc32Update, finish with
  Crc32Final. }
function Crc32Update(crc: LongWord; const a: TBytes; first, len: SizeInt): LongWord;
function Crc32Byte(crc: LongWord; b: Byte): LongWord; inline;
function Crc32Final(crc: LongWord): LongWord; inline;
{ The CRC-32 of a[first..first+len-1] }
function Crc32(const a: TBytes; first, len: SizeInt): LongWord;

{ Adler-32 of a[first..first+len-1], starting from `adler` (1 for a new stream) }
function Adler32(adler: LongWord; const a: TBytes; first, len: SizeInt): LongWord;

implementation

var
  CrcTable: array[0..255] of LongWord;
  CrcTable4: array[0..3, 0..255] of LongWord;

procedure MakeTable;
var n, k: Integer; c: LongWord;
begin
  for n := 0 to 255 do begin
    c := LongWord(n);
    for k := 0 to 7 do
      if (c and 1) <> 0 then c := $EDB88320 xor (c shr 1) else c := c shr 1;
    CrcTable[n] := c;
  end;
  for n := 0 to 255 do begin
    CrcTable4[0][n] := CrcTable[n];
    for k := 1 to 3 do CrcTable4[k][n] := (CrcTable4[k - 1][n] shr 8) xor CrcTable[CrcTable4[k - 1][n] and $FF];
  end;
end;

function Crc32Byte(crc: LongWord; b: Byte): LongWord; inline;
begin
  Result := CrcTable[(crc xor b) and $FF] xor (crc shr 8);
end;

{ slicing by 4 (CrcTable4[k][n]: n's CRC followed by k zero bytes), the
  bounds checked once }
function Crc32Update(crc: LongWord; const a: TBytes; first, len: SizeInt): LongWord;
var p: PByte; n: SizeInt; c: LongWord;
begin
  Result := crc;
  if len <= 0 then Exit;
  if (first < 0) or (first + len > Length(a)) then raise ERangeError.Create('Crc32Update');
  p := @a[first]; n := len; c := crc;
  {$push}{$R-}{$Q-}
  while n >= 4 do begin
    c := c xor (LongWord(p[0]) or (LongWord(p[1]) shl 8) or (LongWord(p[2]) shl 16) or (LongWord(p[3]) shl 24));
    c := CrcTable4[3][c and $FF] xor CrcTable4[2][(c shr 8) and $FF] xor
         CrcTable4[1][(c shr 16) and $FF] xor CrcTable4[0][c shr 24];
    Inc(p, 4); Dec(n, 4);
  end;
  while n > 0 do begin
    c := CrcTable4[0][(c xor p^) and $FF] xor (c shr 8);
    Inc(p); Dec(n);
  end;
  {$pop}
  Result := c;
end;

function Crc32Final(crc: LongWord): LongWord; inline;
begin
  Result := crc xor $FFFFFFFF;
end;

function Crc32(const a: TBytes; first, len: SizeInt): LongWord;
begin
  Result := Crc32Final(Crc32Update(CRC32_INIT, a, first, len));
end;

function Adler32(adler: LongWord; const a: TBytes; first, len: SizeInt): LongWord;
const
  ADLER_BASE = 65521;
  { the most bytes before s2 can overflow 32 bits (zlib's NMAX) }
  NMAX = 5552;
var s1, s2: LongWord; n: SizeInt; p: PByte;
begin
  s1 := adler and $FFFF; s2 := adler shr 16;
  if len > 0 then begin
    if (first < 0) or (first + len > Length(a)) then raise ERangeError.Create('Adler32');
    p := @a[first];
    { NMAX bytes at most between reductions: no sum leaves 32 bits }
    {$push}{$R-}{$Q-}
    while len > 0 do begin
      if len < NMAX then n := len else n := NMAX;
      Dec(len, n);
      while n >= 4 do begin
        Inc(s1, p[0]); Inc(s2, s1); Inc(s1, p[1]); Inc(s2, s1);
        Inc(s1, p[2]); Inc(s2, s1); Inc(s1, p[3]); Inc(s2, s1);
        Inc(p, 4); Dec(n, 4);
      end;
      while n > 0 do begin Inc(s1, p^); Inc(s2, s1); Inc(p); Dec(n); end;
      s1 := s1 mod ADLER_BASE; s2 := s2 mod ADLER_BASE;
    end;
    {$pop}
  end;
  Result := (s2 shl 16) or s1;
end;

initialization
  MakeTable;
end.
