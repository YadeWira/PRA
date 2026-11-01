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
  MAX_LIMIT = 1023;

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
    { the inputs of another mixer (its x), instead of this one's: two mixers
      over the same inputs fill them once. nil: x. }
    ext: PInteger;
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

var
  { The tables, in the interface so that the small functions using them can
    be inlined in other units (FreePascal does not inline a function that
    uses its unit's private symbols: measured 01/11/2026, they stayed calls). }
  STRETCH_T: array[0..4095] of SmallInt;
  { RECIP[n] = 1024 / (n + 1.5): the rate after n updates, 10 fractional bits }
  RECIP: array[0..MAX_LIMIT] of Integer;

  { Set at start-up from cpuid (x86-64 with SSE4.1); PRA_NOASM=1 forces the
    Pascal path. Either path gives the same bits: only the speed changes. }
  UseSse41: Boolean = False;

{ The mixer's two loops, over n lanes (a multiple of 4, the lanes past the
  inputs holding x = 0), each in Pascal and, on x86-64, in SSE4.1:
    Dot   = sum of (x[i] * w[i]) asr 16
    Train: w[i] := clamp(w[i] + (x[i] * err) asr 14, -W_MAX, W_MAX) }
function DotPas(x, w: PInteger; n: Integer): Integer;
procedure TrainPas(x, w: PInteger; n, err: Integer);
{$ifdef CPUX86_64}
function DotSse41(x, w: PInteger; n: Integer): Integer;
procedure TrainSse41(x, w: PInteger; n, err: Integer);
{$endif}

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

uses SysUtils;

const
  { lpaq1's interpolation points of 4096 / (1 + e^-x), x = -8..8 by 1/2 }
  SQUASH_POINTS: array[0..32] of Integer = (
    1, 2, 3, 6, 10, 16, 27, 45, 73, 120, 194, 310, 488, 747, 1101, 1546,
    2047, 2549, 2994, 3348, 3607, 3785, 3901, 3975, 4022, 4050, 4068, 4079,
    4085, 4089, 4092, 4093, 4094);

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
  INIT_W = 6000;      { about 0.09: measured, 10 to 12 inputs }

procedure TMixer.Init(nInputs, nSets, learningRate: Integer);
var i: Integer;
begin
  inputs := nInputs; sets := nSets; rate := learningRate;
  w := nil;
  { 3 more: the last selector's lanes up to a multiple of 4 }
  SetLength(w, nInputs * nSets + 3);
  for i := 0 to High(w) do w[i] := INIT_W;
  n := 0; base := 0; pr := 2048; ext := nil;
end;

procedure TMixer.Add(st: Integer);
begin
  x[n] := st;
  Inc(n);
end;

function DotPas(x, w: PInteger; n: Integer): Integer;
var i: Integer;
begin
  Result := 0;
  { each term below 2^30, shifted to 2^14: a sum of 12 fits easily }
  for i := 0 to n - 1 do Result := Result + SarLongint(x[i] * w[i], 16);
end;

procedure TrainPas(x, w: PInteger; n, err: Integer);
var i, wi: Integer;
begin
  for i := 0 to n - 1 do begin
    wi := w[i] + SarLongint(x[i] * err, 14);
    if wi > W_MAX then wi := W_MAX else if wi < -W_MAX then wi := -W_MAX;
    w[i] := wi;
  end;
end;

{$ifdef CPUX86_64}
{$asmmode intel}
function CpuHasSse41: Boolean;
var c: LongWord;
begin
  asm
    push rbx
    mov eax, 1
    cpuid
    mov c, ecx
    pop rbx
  end ['rax', 'rcx', 'rdx'];
  Result := (c and (1 shl 19)) <> 0;
end;

{ four lanes at a time: pmulld (the low 32 bits of each product, which is
  the whole product: below 2^30), psrad (arithmetic, as SarLongint), paddd }
function DotSse41(x, w: PInteger; n: Integer): Integer;
var px, pw: PInteger; k, r: Integer;
begin
  { through locals: FPC keeps register parameters out of reach of asm }
  px := x; pw := w; k := n shr 2;
  asm
    mov rax, px
    mov rdx, pw
    mov ecx, k
    pxor xmm2, xmm2
  @loop:
    movdqu xmm0, [rax]
    movdqu xmm1, [rdx]
    pmulld xmm0, xmm1
    psrad xmm0, 16
    paddd xmm2, xmm0
    add rax, 16
    add rdx, 16
    dec ecx
    jnz @loop
    pshufd xmm0, xmm2, $4E
    paddd xmm2, xmm0
    pshufd xmm0, xmm2, $B1
    paddd xmm2, xmm0
    movd r, xmm2
  end ['rax', 'rcx', 'rdx', 'xmm0', 'xmm1', 'xmm2'];
  Result := r;
end;

procedure TrainSse41(x, w: PInteger; n, err: Integer);
const
  W_HI: array[0..3] of Integer = (W_MAX, W_MAX, W_MAX, W_MAX);
  W_LO: array[0..3] of Integer = (-W_MAX, -W_MAX, -W_MAX, -W_MAX);
var px, pw: PInteger; k, e: Integer;
begin
  px := x; pw := w; k := n shr 2; e := err;
  asm
    mov rax, px
    mov rdx, pw
    mov ecx, k
    movd xmm4, e
    pshufd xmm4, xmm4, 0
    movdqu xmm6, [rip + W_HI]
    movdqu xmm7, [rip + W_LO]
  @loop:
    movdqu xmm0, [rax]
    pmulld xmm0, xmm4
    psrad xmm0, 14
    movdqu xmm1, [rdx]
    paddd xmm1, xmm0
    pminsd xmm1, xmm6
    pmaxsd xmm1, xmm7
    movdqu [rdx], xmm1
    add rax, 16
    add rdx, 16
    dec ecx
    jnz @loop
  end ['rax', 'rcx', 'rdx', 'xmm0', 'xmm1', 'xmm4', 'xmm6', 'xmm7'];
end;
{$asmmode default}
{$endif}

function TMixer.Mix(selector: Integer): Integer;
var dot, n4, i: Integer; px: PInteger;
begin
  base := selector * inputs;
  { the lanes past the inputs, up to a multiple of 4, hold x = 0: their
    weights (the next selector's, or the padding at the end) neither add
    nor move. With ext, the other mixer's Mix padded them already. }
  n4 := (n + 3) and not 3;
  if ext = nil then begin
    for i := n to n4 - 1 do x[i] := 0;
    px := @x[0];
  end else px := ext;
  if (base < 0) or (base + n4 > Length(w)) then raise ERangeError.Create('TMixer.Mix: selector');
  {$ifdef CPUX86_64}
  if UseSse41 then dot := DotSse41(px, @w[base], n4) else
  {$endif}
  dot := DotPas(px, @w[base], n4);
  pr := Squash(dot);
  Result := pr;
end;

procedure TMixer.Update(bit: Integer);
var err, n4: Integer; px: PInteger;
begin
  { err below 2^12, x below 2^11, rate below 2^7: the product below 2^30 }
  err := ((bit shl 12) - pr) * rate;
  n4 := (n + 3) and not 3;
  if ext = nil then px := @x[0] else px := ext;
  {$ifdef CPUX86_64}
  if UseSse41 then TrainSse41(px, @w[base], n4, err) else
  {$endif}
  TrainPas(px, @w[base], n4, err);
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
  {$ifdef CPUX86_64}
  UseSse41 := CpuHasSse41 and (GetEnvironmentVariable('PRA_NOASM') <> '1');
  {$endif}
end.
