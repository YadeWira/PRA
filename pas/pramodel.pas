{ Layer 4: the pieces every model is made of.

  Everything here is 32-bit integer arithmetic with no floating point, so
  that every platform makes the same bytes and so that a ZPAQL decoder can
  reproduce it later. The checked build ($Q+) is what proves the 32-bit
  discipline: a product that would need more than 32 bits raises there.

  - squash / stretch: between the logistic domain (-2047..2047, 8 fractional
    bits) and 12-bit probabilities, by table (lpaq's interpolation points).
  - TCounter: an adaptive probability, 16 bits, that adapts fast at first
    (1/1.5, 1/2.5, ...) and then at a fixed rate 1/(limit + 1.5).
  - TCounterTable: counters addressed by a hash; collisions share a counter
    (no check bits: losing a little compression, never correctness, since
    the decoder makes the same collisions).
  - TMixer: a logistic mixer, one weight vector per selector. }
unit pramodel;

{$I pra.inc}
{$ifdef PRA_FAST}
  {$R-}{$Q-}
{$else}
  {$ifopt R-}{$fatal pramodel: range checks ($R+) are mandatory}{$endif}
  {$ifopt Q-}{$fatal pramodel: overflow checks ($Q+) are mandatory}{$endif}
{$endif}

interface

const
  MAX_INPUTS = 12;

type
  TCounter = record
    p: Word;      { P(1) * 65536 }
    n: Byte;
  end;
  PCounter = ^TCounter;

  TCounterTable = record
    c: array of TCounter;
    mask: Integer;
    procedure Init(bits: Integer);
    { the counter at hash h }
    function At(h: Cardinal): PCounter; inline;
  end;

  TMixer = record
    w: array of Integer;          { 16 fractional bits, per selector and input }
    x: array[0..MAX_INPUTS - 1] of Integer;
    n, inputs, sets, base, pr, rate: Integer;
    procedure Init(nInputs, nSets, learningRate: Integer);
    { a stretched input, -2047..2047 }
    procedure Add(st: Integer); inline;
    { the mixed probability, 12 bits (1..4095), with the weights of `selector` }
    function Mix(selector: Integer): Integer;
    procedure Update(bit: Integer);
  end;

  { An adaptive probability map (SSE): refines a probability in a context,
    interpolating between the two nearest of 33 points of its stretch. }
  TAPM = record
    t: array of Integer;          { 16-bit probabilities }
    idx, rate: Integer;
    procedure Init(contexts, learningRate: Integer);
    { p and the result: 12 bits }
    function Refine(p, ctx: Integer): Integer;
    procedure Update(bit: Integer);
  end;

function Squash(d: Integer): Integer;       { -2047..2047 -> 0..4095 }
function Stretch(p: Integer): Integer; inline;  { 0..4095 -> -2047..2047 }
procedure CounterInit(var c: TCounter); inline;
procedure CounterUpdate(var c: TCounter; bit, limit: Integer); inline;
{ a 16-bit probability as a stretched input }
function St16(p16: Integer): Integer; inline;
{ hashing: wrapping arithmetic is the algorithm (not inline: inlined, it
  would be checked with the caller's $Q+) }
function Hash2(a, b: Cardinal): Cardinal;
function Hash3(a, b, c: Cardinal): Cardinal;
function Hash4(a, b, c, d: Cardinal): Cardinal;
{ the number of bits of v >= 0: 0 for 0, 1 for 1, 2 for 2..3 ... }
function BitLen(v: Integer): Integer; inline;

implementation

const
  MAX_LIMIT = 1023;
  { lpaq1's interpolation points of 4096 / (1 + e^-x), x = -8..8 by 1/2 }
  SQUASH_POINTS: array[0..32] of Integer = (
    1, 2, 3, 6, 10, 16, 27, 45, 73, 120, 194, 310, 488, 747, 1101, 1546,
    2047, 2549, 2994, 3348, 3607, 3785, 3901, 3975, 4022, 4050, 4068, 4079,
    4085, 4089, 4092, 4093, 4094);

var
  STRETCH_T: array[0..4095] of SmallInt;
  { RECIP[n] = 1024 / (n + 1.5): the rate after n updates, 10 fractional bits }
  RECIP: array[0..MAX_LIMIT] of Integer;

function Squash(d: Integer): Integer;
var w: Integer;
begin
  if d > 2047 then Exit(4095);
  if d < -2047 then Exit(1);
  w := d and 127;
  d := SarLongint(d, 7) + 16;
  Result := (SQUASH_POINTS[d] * (128 - w) + SQUASH_POINTS[d + 1] * w + 64) shr 7;
  if Result < 1 then Result := 1;
end;

function Stretch(p: Integer): Integer;
begin
  Result := STRETCH_T[p];
end;

function St16(p16: Integer): Integer;
begin
  Result := STRETCH_T[p16 shr 4];
end;

procedure CounterInit(var c: TCounter);
begin
  c.p := 32768; c.n := 0;
end;

procedure CounterUpdate(var c: TCounter; bit, limit: Integer);
var target: Integer;
begin
  if bit <> 0 then target := 65535 else target := 0;
  { |target - p| < 2^16, RECIP <= 683: below 2^26 }
  c.p := c.p + SarLongint((target - c.p) * RECIP[c.n], 10);
  if c.n < limit then Inc(c.n);
end;

{$push}{$Q-}{$R-}
function Hash2(a, b: Cardinal): Cardinal;
begin
  Result := (a * $9E3779B1) xor (b * $85EBCA77);
  Result := Result xor (Result shr 15);
  Result := Result * $C2B2AE3D;
  Result := Result xor (Result shr 13);
end;

function Hash3(a, b, c: Cardinal): Cardinal;
begin
  Result := Hash2(Hash2(a, b), c);
end;

function Hash4(a, b, c, d: Cardinal): Cardinal;
begin
  Result := Hash2(Hash2(Hash2(a, b), c), d);
end;
{$pop}

function BitLen(v: Integer): Integer;
begin
  Result := 0;
  while v > 0 do begin Inc(Result); v := v shr 1; end;
end;

{ ---------- counters ---------- }

procedure TCounterTable.Init(bits: Integer);
var i: Integer;
begin
  c := nil;
  SetLength(c, 1 shl bits);
  mask := (1 shl bits) - 1;
  for i := 0 to High(c) do CounterInit(c[i]);
end;

function TCounterTable.At(h: Cardinal): PCounter;
begin
  Result := @c[Integer(h and Cardinal(mask))];
end;

{ ---------- mixer ---------- }

const
  W_MAX = 1 shl 19;   { |weight| <= 8.0: |x * w| < 2^30 }
  INIT_W = 6000;      { about 0.09: measured, 10 to 12 inputs }   { |weight| <= 8.0: |x * w| < 2^30 }

procedure TMixer.Init(nInputs, nSets, learningRate: Integer);
var i: Integer;
begin
  inputs := nInputs; sets := nSets; rate := learningRate;
  w := nil;
  SetLength(w, nInputs * nSets);
  for i := 0 to High(w) do w[i] := INIT_W;
  n := 0; base := 0; pr := 2048;
end;

procedure TMixer.Add(st: Integer);
begin
  x[n] := st;
  Inc(n);
end;

function TMixer.Mix(selector: Integer): Integer;
var i, dot: Integer;
begin
  base := selector * inputs;
  dot := 0;
  { each term below 2^30, shifted to 2^14: a sum of 8 fits easily }
  for i := 0 to n - 1 do dot := dot + SarLongint(x[i] * w[base + i], 16);
  pr := Squash(dot);
  Result := pr;
end;

procedure TMixer.Update(bit: Integer);
var i, err, wi: Integer;
begin
  { err below 2^12, x below 2^11, rate below 2^7: the product below 2^30 }
  err := ((bit shl 12) - pr) * rate;
  for i := 0 to n - 1 do begin
    wi := w[base + i] + SarLongint(x[i] * err, 14);
    if wi > W_MAX then wi := W_MAX else if wi < -W_MAX then wi := -W_MAX;
    w[base + i] := wi;
  end;
  n := 0;
end;

{ ---------- APM ---------- }

procedure TAPM.Init(contexts, learningRate: Integer);
var c, j: Integer;
begin
  t := nil;
  SetLength(t, contexts * 33);
  for c := 0 to contexts - 1 do
    for j := 0 to 32 do t[c * 33 + j] := Squash((j - 16) * 128) * 16;
  idx := 0; rate := learningRate;
end;

function TAPM.Refine(p, ctx: Integer): Integer;
var st, wt: Integer;
begin
  st := Stretch(p) + 2048;            { 1..4095 }
  wt := st and 127;
  idx := ctx * 33 + st shr 7;
  { the nearer point gets the update }
  Result := (t[idx] * (128 - wt) + t[idx + 1] * wt) shr 11;
  if wt >= 64 then Inc(idx);
  if Result < 1 then Result := 1 else if Result > 4095 then Result := 4095;
end;

procedure TAPM.Update(bit: Integer);
var target: Integer;
begin
  if bit <> 0 then target := 65535 else target := 0;
  t[idx] := t[idx] + SarLongint(target - t[idx], rate);
end;

procedure InitTables;
var p, d, k: Integer;
begin
  { stretch: the inverse of squash, the smallest d whose squash reaches p }
  d := -2047;
  for p := 0 to 4095 do begin
    while (d < 2047) and (Squash(d) < p) do Inc(d);
    STRETCH_T[p] := d;
  end;
  for k := 0 to MAX_LIMIT do RECIP[k] := (2048 + (2 * k + 3) div 2) div (2 * k + 3);
end;

initialization
  InitTables;
end.
