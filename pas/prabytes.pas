{ Layer 4: the bytes a parser keeps as they are (a file's header and its
  tail), coded with a small context-mixing model of their own.

  A header is a few dozen to a few thousand bytes of structs, names and
  palettes: fields of 2 and 4 bytes, mostly zeros, colours of 3 or 4. The
  contexts are the last bytes (orders 0 to 3, and 5 hashed), the byte one
  4-byte field above with the position in the field, the byte one colour
  above, and both of those with the last byte. One mixer, selected by the
  bits of the byte so far and the position in a field, then an APM.

  Integers only, like the pixel model: the same bytes on every platform. }
unit prabytes;

{$I pra.inc}
{$ifdef PRA_FAST}
  {$R-}{$Q-}
{$else}
  {$ifopt R-}{$fatal prabytes: range checks ($R+) are mandatory}{$endif}
  {$ifopt Q-}{$fatal prabytes: overflow checks ($Q+) are mandatory}{$endif}
{$endif}

interface

uses SysUtils;

{ d[first..first+len) coded }
function PackBytes(const d: TBytes; first, len: SizeInt): TBytes;
{ the len bytes coded in s[first..first+coded), into d[at..at+len). The
  coded bytes are read from a copy of their own: past their end the
  decoder reads zeros, as the encoder's verification did. }
procedure UnpackBytes(const s: TBytes; first, coded: SizeInt; var d: TBytes; at, len: SizeInt);

implementation

uses praarith, pramodel;

const
  N_CTX = 8;
  COUNTER_LIMIT = 127;
  MIXER_RATE = 48;

var
  NODE: array[0..255] of Cardinal;

type
  TByteCoder = record
    encoding: Boolean;
    enc: TArithEncoder;
    dec: TArithDecoder;
    t: TCounterTable;
    mx: TMixer;
    apm: TAPM;
    h: array[0..N_CTX - 1] of Cardinal;
    slot: array[0..N_CTX - 1] of Integer;   { the nibble's 16 counters }
    procedure Init(len: SizeInt);
    procedure Contexts(const d: TBytes; first, i: SizeInt);
    { at the start of each nibble: its slots, from the contexts and the
      bits of the byte so far (c0: 1, or 16 to 31) }
    procedure Slots(c0: Integer);
    function Code(b, c0, field: Integer): Integer;
  end;

procedure TByteCoder.Init(len: SizeInt);
var bits: Integer;
begin
  { the table by the bytes: about 8 counters a context and byte, 2^12 to 2^22 }
  if len > 1 shl 20 then len := 1 shl 20;
  bits := BitLen(Integer(len)) + 6;
  if bits < 12 then bits := 12;
  if bits > 22 then bits := 22;
  t.Init(bits);
  mx.Init(N_CTX + 1, 256 * 4, MIXER_RATE);
  apm.Init(256 * 4, 6);
end;

procedure TByteCoder.Contexts(const d: TBytes; first, i: SizeInt);
var b1, b2, b3, b4, b5, pos: Cardinal;

  function At(k: SizeInt): Cardinal;
  begin if i - k >= 0 then Result := d[first + i - k] else Result := 0; end;

begin
  b1 := At(1); b2 := At(2); b3 := At(3); b4 := At(4); b5 := At(5);
  pos := Cardinal(i and 3);
  h[0] := 0;
  h[1] := Hash2(1, b1);
  h[2] := Hash3(2, b1, b2);
  h[3] := Hash4(3, b1, b2, b3);
  h[4] := Hash4(4, b1 or (b2 shl 8) or (b3 shl 16) or (b4 shl 24), b5, 0);
  h[5] := Hash3(5, b4, pos);
  h[6] := Hash2(6, b3);
  h[7] := Hash4(7, b1, b4, pos);
end;

procedure TByteCoder.Slots(c0: Integer);
var k: Integer;
begin
  for k := 0 to N_CTX - 1 do slot[k] := Integer((h[k] xor NODE[c0]) and Cardinal(t.mask) and not Cardinal(15));
end;

function TByteCoder.Code(b, c0, field: Integer): Integer;
var k, p, j, n: Integer; c: array[0..N_CTX - 1] of PCounter;
begin
  { the bits of the nibble so far, after a leading 1: 1 to 15 }
  if c0 >= 16 then begin
    n := BitLen(c0) - 5;
    j := (1 shl n) or (c0 and ((1 shl n) - 1));
  end else j := c0;
  for k := 0 to N_CTX - 1 do begin
    c[k] := @t.c[slot[k] + j];
    mx.x[k] := STRETCH_T[c[k]^.p shr 4];
  end;
  mx.x[N_CTX] := 256;
  mx.n := N_CTX + 1;
  p := mx.Mix(c0 + 256 * field);
  p := (p + 3 * apm.Refine(p, c0 + 256 * field)) shr 2;
  if encoding then enc.Encode(b, p shl 4) else b := dec.Decode(p shl 4);
  for k := 0 to N_CTX - 1 do CounterUpdate(c[k]^, b, COUNTER_LIMIT);
  apm.Update(b);
  mx.Update(b);
  Result := b;
end;

function PackBytes(const d: TBytes; first, len: SizeInt): TBytes;
var bc: TByteCoder; i: SizeInt; k, c0, v: Integer;
begin
  bc.encoding := True;
  bc.Init(len);
  bc.enc.Init;
  for i := 0 to len - 1 do begin
    bc.Contexts(d, first, i);
    v := d[first + i]; c0 := 1;
    for k := 7 downto 0 do begin
      if (k and 3) = 3 then bc.Slots(c0);
      c0 := (c0 shl 1) or bc.Code((v shr k) and 1, c0, Integer(i and 3));
    end;
  end;
  Result := bc.enc.Finish;
end;

procedure UnpackBytes(const s: TBytes; first, coded: SizeInt; var d: TBytes; at, len: SizeInt);
var bc: TByteCoder; i: SizeInt; k, c0: Integer;
begin
  bc.encoding := False;
  bc.Init(len);
  bc.dec.Init(Copy(s, first, coded));
  for i := 0 to len - 1 do begin
    bc.Contexts(d, at, i);
    c0 := 1;
    for k := 7 downto 0 do begin
      if (k and 3) = 3 then bc.Slots(c0);
      c0 := (c0 shl 1) or bc.Code(0, c0, Integer(i and 3));
    end;
    d[at + i] := Byte(c0);
  end;
end;

procedure InitNodes;
var k: Integer; x: Cardinal;
begin
  x := 2463534242;
  for k := 0 to 255 do begin
    x := x xor (x shl 13); x := x xor (x shr 17); x := x xor (x shl 5);
    NODE[k] := x;
  end;
end;

initialization
  InitNodes;
end.
