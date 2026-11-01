{ Layer 4: the model's pieces (pramodel).
  - the mixer's loops: the SSE4.1 assembly against its Pascal twin, on
    random inputs, weights and errors at every edge (the clamp, the largest
    products), lane counts 4 to 12: the same results, bit for bit;
  - squash and stretch: monotonic, and stretch inverts squash;
  - a counter moves toward what it sees, and stays inside 16 bits. }
program test_model;
{$I ../pra.inc}
uses SysUtils, pramodel;

var cells, failures: Integer;
procedure Check(ok: Boolean; const what: string);
begin Inc(cells); if ok then Writeln('  ', what:66, '  ok') else begin Inc(failures); Writeln('  ', what:66, '  FAIL'); end; end;

var seed: Cardinal;
function Rand: Cardinal;
begin seed := seed xor (seed shl 13); seed := seed xor (seed shr 17); seed := seed xor (seed shl 5); Result := seed; end;
function RandIn(lo, hi: Integer): Integer;
begin Result := lo + Integer(Rand mod Cardinal(hi - lo + 1)); end;

const W_MAX = 1 shl 19;
var
  x, w1, w2: array[0..11] of Integer; i, k, n, err, d1, d2, bad, badT, p, last: Integer;
  mono, inverse: Boolean; c: TCounter;
begin
  cells := 0; failures := 0; seed := 1234567;

  Writeln('mixer loops');
  {$ifdef CPUX86_64}
  if UseSse41 then begin
    bad := 0; badT := 0;
    for k := 1 to 200000 do begin
      n := 4 * RandIn(1, 3);
      for i := 0 to n - 1 do begin
        case Rand mod 4 of
          0: x[i] := RandIn(-2047, 2047);
          1: if Rand and 1 = 0 then x[i] := 2047 else x[i] := -2047;
          2: x[i] := 0;
        else x[i] := RandIn(-300, 300);
        end;
        case Rand mod 4 of
          0: w1[i] := RandIn(-W_MAX, W_MAX);
          1: if Rand and 1 = 0 then w1[i] := W_MAX else w1[i] := -W_MAX;
        else w1[i] := RandIn(-70000, 70000);
        end;
        w2[i] := w1[i];
      end;
      d1 := DotPas(@x[0], @w1[0], n);
      d2 := DotSse41(@x[0], @w2[0], n);
      if d1 <> d2 then Inc(bad);
      err := RandIn(-4095, 4095) * RandIn(1, 127);
      TrainPas(@x[0], @w1[0], n, err);
      TrainSse41(@x[0], @w2[0], n, err);
      for i := 0 to n - 1 do if w1[i] <> w2[i] then Inc(badT);
    end;
    Check(bad = 0, '200000 dot products: SSE4.1 = Pascal');
    Check(badT = 0, '200000 trainings, clamp included: SSE4.1 = Pascal');
  end else begin
    Check(True, 'no SSE4.1 here: the Pascal loops only');
    Check(True, '  (nothing to compare)');
  end;
  {$else}
  Check(True, 'not x86-64: the Pascal loops only');
  Check(True, '  (nothing to compare)');
  {$endif}

  Writeln('squash and stretch');
  mono := True; last := Squash(-2048);
  for i := -2047 to 2047 do begin
    p := Squash(i);
    if (p < last) or (p < 1) or (p > 4095) then mono := False;
    last := p;
  end;
  Check(mono, 'squash: monotonic, inside 1..4095');
  mono := True; inverse := True; last := Stretch(0);
  for i := 1 to 4095 do begin
    if Stretch(i) < last then mono := False;
    last := Stretch(i);
    if Squash(Stretch(i)) < i - 40 then inverse := False;
  end;
  Check(mono, 'stretch: monotonic');
  Check(inverse, 'squash(stretch(p)) stays near p');

  Writeln('counters');
  CounterInit(c);
  for i := 1 to 1000 do CounterUpdate(c, 1, 127);
  Check(c.p > 64000, Format('1000 ones: P(1) = %d / 65536', [c.p]));
  for i := 1 to 1000 do CounterUpdate(c, 0, 127);
  Check(c.p < 1500, Format('then 1000 zeros: P(1) = %d / 65536', [c.p]));

  Writeln(cells, ' cells, ', failures, ' failures');
  if (failures > 0) or (cells < 7) then Halt(1);
end.
