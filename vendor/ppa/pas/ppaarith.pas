{ Codec layer 4: binary arithmetic coder, adaptive bit counters, and the
  logistic mixing the model builds on.

  The coder is PJA's (pjaarith): carryless, the interval in 32 bits
  [x1, x2] (the lpaq form), a byte emitted whenever both ends agree on the
  top one, probabilities in 16 bits, p = P(bit = 1) * 65536 in [1, 65535].
  The decoder cannot fail: past the end of the data it reads zeros, and a
  damaged stream decodes to something else, which the layers above catch.

  Everything is integer arithmetic, no floating point: the model must give
  the same bits on every platform, and its ZPAQL decoder (for zpaq-std)
  only has 32-bit integers. The tables (stretch, squash, the counters'
  rates) are computed with integers too.

  This is the Pascal reference version. }
unit ppaarith;

{$I ppa.inc}
{$ifdef PPA_FAST}
  {$R-}{$Q-}
{$else}
  {$ifopt R-}{$fatal ppaarith: range checks ($R+) are mandatory}{$endif}
  {$ifopt Q-}{$fatal ppaarith: overflow checks ($Q+) are mandatory}{$endif}
{$endif}

interface

uses SysUtils;

const
  PROB_ONE = 65536;
  MAX_LIMIT = 255;
  { stretch(p) is in [-STRETCH_MAX, STRETCH_MAX], 8 fractional bits }
  STRETCH_MAX = 2047;

type
  TArithEncoder = record
    x1, x2: Cardinal;
    d: TBytes;
    n: SizeInt;
    procedure Init;
    procedure Encode(bit: Integer; p: Integer);
    { The low `count` bits of v, most significant first, at probability 1/2. }
    procedure Direct(v: Cardinal; count: Integer);
    function Finish: TBytes;
  end;

  TArithDecoder = record
    x1, x2, x: Cardinal;
    d: TBytes;
    p: SizeInt;
    procedure Init(const data: TBytes; first: SizeInt = 0);
    function Decode(prob: Integer): Integer;
    function Direct(count: Integer): Cardinal;
  end;

  { The counter of a context: starts at 1/2, adapts fast at first (1/2,
    1/3, 1/4...) and then at a fixed rate of about 1/limit. }
  TAdaptiveBit = record
    p: Word;      { P(1) * 65536 }
    n: Byte;      { how many updates so far, up to the limit }
    procedure Init;
    procedure Update(bit: Integer; limit: Integer); inline;
  end;

var
  { RECIPROCAL[n] = 65536 / (n + 1.5), rounded: the rate after n bits }
  RECIPROCAL: array[0..MAX_LIMIT] of Integer;

var
  { the tables behind Stretch and Squash, in the interface so that the
    model can index them inline }
  STRETCH_TAB: array[0..4095] of SmallInt;
  { squash at x = -2048 .. 2047, step 1, as a 16-bit probability }
  SQUASH_TAB: array[0..4095] of Word;

{ ln(p / (1 - p)) * 256, p in 1/4096 (12 bits), clamped to +-STRETCH_MAX }
function Stretch(p16: Integer): Integer;
{ the inverse: a 16-bit probability in [1, 65535] }
function Squash(x: Integer): Integer;

implementation

function Split(x1, x2: Cardinal; p: Integer): Cardinal; inline;
begin
  Result := x1 + Cardinal((QWord(x2 - x1) * Cardinal(p)) shr 16);
end;

function Clamp(p: Integer): Integer; inline;
begin
  if p < 1 then Result := 1 else if p > PROB_ONE - 1 then Result := PROB_ONE - 1 else Result := p;
end;

{ ---------- encoder ---------- }

procedure TArithEncoder.Init;
begin
  x1 := 0; x2 := $FFFFFFFF;
  d := nil; SetLength(d, 4096); n := 0;
end;

procedure TArithEncoder.Encode(bit: Integer; p: Integer);
var xm: Cardinal;
begin
  xm := Split(x1, x2, Clamp(p));
  if bit <> 0 then x2 := xm else x1 := xm + 1;
  while ((x1 xor x2) and $FF000000) = 0 do begin
    if n >= Length(d) then SetLength(d, 2 * Length(d));
    d[n] := Byte(x2 shr 24);
    Inc(n);
    x1 := x1 shl 8;
    x2 := (x2 shl 8) or 255;
  end;
end;

procedure TArithEncoder.Direct(v: Cardinal; count: Integer);
var k: Integer;
begin
  for k := count - 1 downto 0 do Encode((v shr k) and 1, PROB_ONE div 2);
end;

function TArithEncoder.Finish: TBytes;
var k: Integer;
begin
  { all of x1: whatever tail the decoder reads falls inside [x1, x2] }
  for k := 0 to 3 do begin
    if n >= Length(d) then SetLength(d, 2 * Length(d));
    d[n] := Byte(x1 shr 24);
    Inc(n);
    x1 := x1 shl 8;
  end;
  Result := Copy(d, 0, n);
end;

{ ---------- decoder ---------- }

procedure TArithDecoder.Init(const data: TBytes; first: SizeInt);
var k: Integer; b: Byte;
begin
  d := data; p := first;
  x1 := 0; x2 := $FFFFFFFF; x := 0;
  for k := 0 to 3 do begin
    if (p >= 0) and (p < Length(d)) then b := d[p] else b := 0;
    Inc(p);
    x := (x shl 8) or b;
  end;
end;

function TArithDecoder.Decode(prob: Integer): Integer;
var xm: Cardinal; b: Byte;
begin
  xm := Split(x1, x2, Clamp(prob));
  if x <= xm then begin Result := 1; x2 := xm; end
  else begin Result := 0; x1 := xm + 1; end;
  while ((x1 xor x2) and $FF000000) = 0 do begin
    x1 := x1 shl 8;
    x2 := (x2 shl 8) or 255;
    if (p >= 0) and (p < Length(d)) then b := d[p] else b := 0;
    Inc(p);
    x := (x shl 8) or b;
  end;
end;

function TArithDecoder.Direct(count: Integer): Cardinal;
var k: Integer;
begin
  Result := 0;
  for k := 1 to count do Result := (Result shl 1) or Cardinal(Decode(PROB_ONE div 2));
end;

{ ---------- counter ---------- }

procedure TAdaptiveBit.Init;
begin p := PROB_ONE div 2; n := 0; end;

procedure TAdaptiveBit.Update(bit: Integer; limit: Integer);
var target: Integer; q: Int64;
begin
  if bit <> 0 then target := PROB_ONE - 1 else target := 1;
  { div PROB_ONE, truncating toward zero, without a division and without a
    branch: a negative product gets 65535 added before the shift }
  q := Int64(target - p) * RECIPROCAL[n];
  q := SarInt64(q + (SarInt64(q, 63) and $FFFF), 16);
  p := p + q;
  if (n < limit) and (n < MAX_LIMIT) then Inc(n);
end;

{ ---------- stretch and squash ---------- }

function Stretch(p16: Integer): Integer;
begin
  Result := STRETCH_TAB[p16 shr 4];
end;

function Squash(x: Integer): Integer;
begin
  if x > STRETCH_MAX then x := STRETCH_MAX;
  if x < -STRETCH_MAX - 1 then x := -STRETCH_MAX - 1;
  Result := SQUASH_TAB[x + 2048];
end;

{ The tables, with integers only. squash(x) = 65536 / (1 + e^(-x/256)) is
  made from e^(-k/256) for k = 0..2047, by repeated multiplication with
  e^(-1/256) in 32-bit fixed point (and rounding at each step: the table is
  the same on every platform, whatever its exact values are). stretch is
  squash's inverse, found by walking it. }
procedure MakeTables;
const
  { e^(-1/256) * 2^30, rounded }
  E_STEP = 1069547520;
var
  k, x, p: Integer; e: QWord; ex: array[0..2048] of QWord;
begin
  for k := 0 to MAX_LIMIT do RECIPROCAL[k] := (2 * PROB_ONE + (2 * k + 3) div 2) div (2 * k + 3);
  { ex[k] = e^(-k/256) * 2^30 }
  e := QWord(1) shl 30;
  for k := 0 to 2048 do begin
    ex[k] := e;
    e := (e * E_STEP + (QWord(1) shl 29)) shr 30;
  end;
  for x := -2048 to 2047 do begin
    { 65536 / (1 + e^(-x/256)); for x < 0, e^(-x/256) = 2^60 / ex[-x] }
    if x >= 0 then p := Integer((QWord(PROB_ONE) shl 30) div ((QWord(1) shl 30) + ex[x]))
    else p := Integer((QWord(PROB_ONE) * ex[-x]) div (ex[-x] + (QWord(1) shl 30)));
    if p < 1 then p := 1;
    if p > PROB_ONE - 1 then p := PROB_ONE - 1;
    SQUASH_TAB[x + 2048] := p;
  end;
  { stretch: for each 12-bit probability the x whose squash is nearest from below }
  x := -2048;
  for p := 0 to 4095 do begin
    while (x < 2047) and (SQUASH_TAB[x + 2048 + 1] <= p * 16 + 8) do Inc(x);
    STRETCH_TAB[p] := x;
  end;
end;

initialization
  MakeTables;
end.
