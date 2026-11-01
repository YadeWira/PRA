{ Layer 5: the codec stream. A whole file in, a stream out, and back.

  Stream, version 1 (doc/CODEC.md):

      version     1 B    1
      header      varint length, then the bytes
      layout      format 1 B, width, height, channels (varints), bits 1 B,
                  flags 1 B (bit 0 big-endian, bit 1 float, bit 2 bottom-up),
                  maxval (varint)
      tail        varint length, then the bytes
      pixels      the arithmetic-coded pixels, to the end

  The pixels: samples of 8 or 16 bits (a 32-bit float is made monotonic and
  split into two 16-bit halves). Each sample is predicted (MED, plus the
  error of the reference channel at the same pixel for colour), and the
  residual, taken modulo 2^bits, is coded as its bit length, the bits below
  the top one and the sign, every decision through counters in six
  contexts and a mixer. 1-bit images (PBM) have their own model of the
  neighbouring pixels.

  EncodeFile verifies: it decodes its own stream and compares it with the
  input, and gives up (False) if they differ. }
unit pracodec;

{$I pra.inc}
{$ifdef PRA_FAST}
  {$R-}{$Q-}
{$else}
  {$ifopt R-}{$fatal pracodec: range checks ($R+) are mandatory}{$endif}
  {$ifopt Q-}{$fatal pracodec: overflow checks ($Q+) are mandatory}{$endif}
{$endif}

interface

uses SysUtils, praraster;

const
  { The first byte of a stream. An image: 2, its header and tail coded
    (prabytes); 1, kept as they are. A file of several images: 3, its parts
    (praparts). The decoder reads all three. }
  IMAGE_STREAM = 2;
  PARTS_STREAM = 3;
  STREAM_VERSION = PARTS_STREAM;
  PRA_VERSION = '0.1.0';

var
  { A band is coded on its own, with fresh models, so bands are coded and
    decoded at once on as many threads. The encoder makes each at least
    this many bytes of pixels: 2 MiB loses 0.04% against one band on the
    tuning set, 1 MiB 0.17% (doc/CODEC.md). The stream records how many
    there are: the decoder never looks at this. The tests lower it, to code
    small images in many bands. }
  BandBytes: Int64 = 1 shl 21;

type
  TDecodeStatus = (dsOk, dsEmpty, dsFutureVersion, dsBadStream, dsTooBig);

{ The stream of d, verified; False if no parser takes d or it did not come
  back (then `why` says why). }
function EncodeFile(const d: TBytes; out s: TBytes; out why: string; threads: Integer = 1): Boolean;
{ The file of s, at most maxOut bytes. threads: how many bands at once;
  the stream is the same whatever it is. }
function DecodeFile(const s: TBytes; maxOut: Int64; out d: TBytes; threads: Integer = 1): TDecodeStatus;
function DecodeStatusName(st: TDecodeStatus): string;

{ for the tests and tools: the parser that took the file }
function ParseAny(const d: TBytes; out L: TRasterLayout): TParseStatus;
{ the file's format, of one image or of several (rfICO, rfCUR, rfDCX) }
function FileFormat(const d: TBytes): TRasterFormat;
{ the stream of one image whose layout is given (a part of a file of
  several: praparts) }
function EncodeImage(const d: TBytes; const L: TRasterLayout; out s: TBytes; out why: string; threads: Integer = 1): Boolean;

implementation

uses Math, praarith, pramodel, pralimits, prapnm, prabmp, prahdr, praother, prarle, prabytes, praparts, praplain, prasci;

{ ---------- byte sink and source ---------- }

type
  TSink = record
    b: TBytes;
    n: SizeInt;
    procedure Init;
    procedure Put(x: Byte);
    procedure PutBytes(const src: TBytes; first, len: SizeInt);
    procedure PutVarint(v: Int64);
    function Done: TBytes;
  end;

  TSource = record
    b: TBytes;
    p: SizeInt;
    ok: Boolean;
    function Get: Byte;
    function GetVarint(maxv: Int64): Int64;
  end;

procedure TSink.Init;
begin b := nil; SetLength(b, 256); n := 0; end;

procedure TSink.Put(x: Byte);
begin
  if n >= Length(b) then SetLength(b, 2 * Length(b));
  b[n] := x; Inc(n);
end;

procedure TSink.PutBytes(const src: TBytes; first, len: SizeInt);
begin
  if len <= 0 then Exit;
  while n + len > Length(b) do SetLength(b, 2 * Length(b));
  Move(src[first], b[n], len);
  Inc(n, len);
end;

procedure TSink.PutVarint(v: Int64);
begin
  while v >= 128 do begin Put(Byte(v and 127) or 128); v := v shr 7; end;
  Put(Byte(v));
end;

function TSink.Done: TBytes;
begin Result := Copy(b, 0, n); end;

function TSource.Get: Byte;
begin
  if p < Length(b) then begin Result := b[p]; Inc(p); end
  else begin Result := 0; ok := False; end;
end;

function TSource.GetVarint(maxv: Int64): Int64;
var shift: Integer; x: Byte;
begin
  Result := 0; shift := 0;
  repeat
    x := Get;
    if shift > 56 then begin ok := False; Exit(0); end;
    Result := Result or (Int64(x and 127) shl shift);
    Inc(shift, 7);
  until (x and 128) = 0;
  if Result > maxv then begin ok := False; Result := 0; end;
end;

{ ---------- the bytes kept: header and tail ---------- }

const
  SECTION_STORED = 0;
  SECTION_CODED = 1;

function VarintLength(v: Int64): Integer;
begin
  Result := 1;
  while v >= 128 do begin v := v shr 7; Inc(Result); end;
end;

{ len bytes of d: their length, then (when there are any) how they are
  kept, 1 B, and either the bytes or the coded bytes' length and those;
  whichever is smaller }
procedure PutSection(var o: TSink; const d: TBytes; first, len: SizeInt);
var c, back: TBytes;
begin
  o.PutVarint(len);
  if len = 0 then Exit;
  c := PackBytes(d, first, len);
  { coded only if it comes back }
  back := nil; SetLength(back, len);
  if VarintLength(Length(c)) + Length(c) < len then UnpackBytes(c, 0, Length(c), back, 0, len);
  if (VarintLength(Length(c)) + Length(c) < len) and CompareMem(@back[0], @d[first], len) then begin
    o.Put(SECTION_CODED); o.PutVarint(Length(c)); o.PutBytes(c, 0, Length(c));
  end else begin
    o.Put(SECTION_STORED); o.PutBytes(d, first, len);
  end;
end;

{ the len bytes of a section whose length was read (and checked against
  the limits): stream version 1 keeps them as they are }
function GetSection(var src: TSource; ver: Integer; len: Int64; out b: TBytes): Boolean;
var m, coded: Int64;
begin
  b := nil; Result := False;
  if len = 0 then Exit(True);
  if ver = 1 then m := SECTION_STORED else m := src.Get;
  if not src.ok then Exit;
  case m of
    SECTION_STORED: begin
      if len > Length(src.b) - src.p then Exit;
      b := Copy(src.b, src.p, len); Inc(src.p, len);
    end;
    SECTION_CODED: begin
      coded := src.GetVarint(Length(src.b) - src.p);
      if not src.ok or (coded < 1) then Exit;
      SetLength(b, len);
      UnpackBytes(src.b, src.p, coded, b, 0, len);
      Inc(src.p, coded);
    end;
  else Exit;
  end;
  Result := True;
end;

{ ---------- the pixel model ---------- }

const
  { at most this many bands (BandBytes says how large the encoder makes them) }
  MAX_BANDS = 256;

const
  N_MODELS = 10;
  N_CLASSES = 66;              { mixer classes: tree nodes 1..31, mantissa 32..63, sign 65 }
  CLASS_SIGN = 65;
  CLASS_PAD = 64;
  { the counter table: 2^(bit length of the sub-samples + 4), between 2^12
    and 2^22. Part of the format: the decoder computes it from the layout. }
  TABLE_BITS_MIN = 12;
  TABLE_BITS_MAX = 22;
  COUNTER_LIMIT = 127;
  MIXER_RATE = 8;
  MAX_SUB_SEL = 8;
  N_SEL2 = 256;

var
  NODE_H: array[0..511] of Cardinal;

type
  { One binary decision: the counters of the nm contexts (hm, combined with
    the decision's node), two mixers (one selected by the decision's class
    and the sub-channel, the other by the class and the local activity),
    averaged in the logistic domain, and an APM. }
  TPixelCoder = record
    encoding: Boolean;
    enc: TArithEncoder;
    dec: TArithDecoder;
    t: TCounterTable;
    mx, mx2: TMixer;
    apm: TAPM;
    hm: array[0..N_MODELS - 1] of Cardinal;
    nm: Integer;
    sel: Integer;                 { mx: the sub-channel }
    sel2: Integer;                { mx2 and the APM: the activity; -1: neither }
    apmCtx: Integer;
    function Code(b, node, cls: Integer): Integer;
  end;

function TPixelCoder.Code(b, node, cls: Integer): Integer;
var i, p: Integer; nh, msk: Cardinal; tc: PCounter; c: array[0..N_MODELS - 1] of PCounter;
begin
  { the counters straight from the table (the mask keeps them inside), their
    stretch into mx's inputs, which mx2 reads too }
  tc := @t.c[0]; msk := Cardinal(t.mask); nh := NODE_H[node];
  for i := 0 to nm - 1 do begin
    c[i] := @tc[(hm[i] xor nh) and msk];
    mx.x[i] := STRETCH_T[c[i]^.p shr 4];
  end;
  mx.x[nm] := 256;
  mx.n := nm + 1;
  p := mx.Mix(cls + N_CLASSES * sel);
  if sel2 >= 0 then begin
    mx2.ext := @mx.x[0]; mx2.n := mx.n;
    p := Squash(SarLongint(Stretch(p) + Stretch(mx2.Mix(sel2 * N_CLASSES + cls)), 1));
    p := (p + 3 * apm.Refine(p, cls + N_CLASSES * apmCtx)) shr 2;
  end;
  p := p shl 4;
  if encoding then enc.Encode(b, p) else b := dec.Decode(p);
  for i := 0 to nm - 1 do CounterUpdate(c[i]^, b, COUNTER_LIMIT);
  if sel2 >= 0 then begin mx2.Update(b); apm.Update(b); end;
  mx.Update(b);
  Result := b;
end;

{ ---------- samples ---------- }

type
  TPlan = record
    nsub: Integer;                    { sub-channels a pixel }
    B: Integer;                       { bits a sub-sample: 8 or 16 }
    kbits: Integer;                   { bits of the bit-length tree }
    order: array of Integer;          { the order sub-channels are coded in }
    predRef, ctxRef: array of Integer;
    cw: Integer;                      { pixels coded a row: the padding samples too, when there is one channel }
    pad: Integer;                     { bytes after them in each row, coded on their own }
  end;

procedure MakePlan(const L: TRasterLayout; out P: TPlan);
var c, i: Integer;
begin
  if L.bits = 32 then begin P.nsub := 2 * L.channels; P.B := 16; end
  else begin P.nsub := L.channels; P.B := L.bits; end;
  P.kbits := BitLen(P.B);
  { one channel: every sample of the row, the padding ones too (they are
    zeros, or whatever the writer left: either way they come back) }
  if (L.channels = 1) and ((L.rowBytes * 8) mod L.bits = 0) then begin
    P.cw := Integer((L.rowBytes * 8) div L.bits); P.pad := 0;
  end else begin
    P.cw := Integer(L.width);
    P.pad := Integer(L.rowBytes - L.width * L.channels * (L.bits div 8));
  end;
  P.order := nil; P.predRef := nil; P.ctxRef := nil;
  SetLength(P.order, P.nsub); SetLength(P.predRef, P.nsub); SetLength(P.ctxRef, P.nsub);
  for i := 0 to P.nsub - 1 do begin P.order[i] := i; P.predRef[i] := -1; P.ctxRef[i] := -1; end;
  if L.bits = 32 then begin
    { the high halves first (green first), then the low halves }
    i := 0;
    if L.channels >= 3 then begin
      P.order[0] := 2; P.order[1] := 0; P.order[2] := 4; i := 3;
      P.predRef[0] := 2; P.predRef[4] := 2; P.ctxRef[0] := 2; P.ctxRef[4] := 2;
      for c := 3 to L.channels - 1 do begin P.order[i] := 2 * c; Inc(i); end;
    end else
      for c := 0 to L.channels - 1 do begin P.order[i] := 2 * c; Inc(i); end;
    for c := 0 to L.channels - 1 do begin
      P.order[i] := 2 * c + 1; Inc(i);
      P.ctxRef[2 * c + 1] := 2 * c;
    end;
  end else if L.channels >= 3 then begin
    P.order[0] := 1; P.order[1] := 0; P.order[2] := 2;
    P.predRef[0] := 1; P.predRef[2] := 1; P.ctxRef[0] := 1; P.ctxRef[2] := 1;
  end;
end;

function FloatOrder(v: Cardinal): Cardinal; inline;
begin
  if (v and $80000000) <> 0 then Result := not v else Result := v or $80000000;
end;

function FloatUnorder(v: Cardinal): Cardinal; inline;
begin
  if (v and $80000000) <> 0 then Result := v and $7FFFFFFF else Result := not v;
end;

{ row y of the pixels <-> its sub-samples }
procedure LoadRow(const d: TBytes; const L: TRasterLayout; const P: TPlan; y: Integer; var row: array of Integer);
var x, c: Integer; o: Int64; v: Cardinal;
begin
  o := L.dataOffset + Int64(y) * L.rowBytes;
  for x := 0 to P.cw - 1 do
    for c := 0 to L.channels - 1 do begin
      case L.bits of
        2, 4: row[x] := (d[o + (x * L.bits) shr 3] shr (8 - L.bits - (x * L.bits) and 7)) and ((1 shl L.bits) - 1);
        8: begin row[x * P.nsub + c] := d[o]; Inc(o); end;
        16: begin
          if L.bigEndian then row[x * P.nsub + c] := (d[o] shl 8) or d[o + 1]
          else row[x * P.nsub + c] := (d[o + 1] shl 8) or d[o];
          Inc(o, 2);
        end;
        32: begin
          if L.bigEndian then v := (Cardinal(d[o]) shl 24) or (Cardinal(d[o + 1]) shl 16) or (Cardinal(d[o + 2]) shl 8) or d[o + 3]
          else v := (Cardinal(d[o + 3]) shl 24) or (Cardinal(d[o + 2]) shl 16) or (Cardinal(d[o + 1]) shl 8) or d[o];
          v := FloatOrder(v);
          row[x * P.nsub + 2 * c] := v shr 16;
          row[x * P.nsub + 2 * c + 1] := v and $FFFF;
          Inc(o, 4);
        end;
      end;
    end;
end;

procedure StoreRow(var d: TBytes; const L: TRasterLayout; const P: TPlan; y: Integer; const row: array of Integer);
var x, c: Integer; o: Int64; v: Cardinal;
begin
  o := L.dataOffset + Int64(y) * L.rowBytes;
  for x := 0 to P.cw - 1 do
    for c := 0 to L.channels - 1 do begin
      case L.bits of
        { the row's bytes start at zero (a fresh buffer): the samples are or'ed in }
        2, 4: d[o + (x * L.bits) shr 3] := d[o + (x * L.bits) shr 3]
                or (row[x] shl (8 - L.bits - (x * L.bits) and 7));
        8: begin d[o] := row[x * P.nsub + c]; Inc(o); end;
        16: begin
          if L.bigEndian then begin d[o] := row[x * P.nsub + c] shr 8; d[o + 1] := row[x * P.nsub + c] and 255; end
          else begin d[o + 1] := row[x * P.nsub + c] shr 8; d[o] := row[x * P.nsub + c] and 255; end;
          Inc(o, 2);
        end;
        32: begin
          v := FloatUnorder((Cardinal(row[x * P.nsub + 2 * c]) shl 16) or Cardinal(row[x * P.nsub + 2 * c + 1]));
          if L.bigEndian then begin
            d[o] := v shr 24; d[o + 1] := (v shr 16) and 255; d[o + 2] := (v shr 8) and 255; d[o + 3] := v and 255;
          end else begin
            d[o + 3] := v shr 24; d[o + 2] := (v shr 16) and 255; d[o + 1] := (v shr 8) and 255; d[o] := v and 255;
          end;
          Inc(o, 4);
        end;
      end;
    end;
  { the padding bytes after the samples are CodeSamples' own }
end;

function Med(a, b, c: Integer): Integer; inline;
var mn, mxv: Integer;
begin
  if a < b then begin mn := a; mxv := b; end else begin mn := b; mxv := a; end;
  if c >= mxv then Result := mn
  else if c <= mn then Result := mxv
  else Result := a + b - c;
end;

{ a signed bucket of e: 0, or the sign times its bit length up to 7 }
function SBucket(e: Integer): Integer; inline;
var k: Integer;
begin
  if e = 0 then Exit(0);
  k := BitLen(Abs(e)); if k > 7 then k := 7;
  if e < 0 then Result := -k else Result := k;
end;

function Cap(v, m: Integer): Integer; inline;
begin
  if v > m then Result := m else Result := v;
end;

{ ---------- multi-bit samples ---------- }

const
  N_PRED = 12;
  MAX_COST = 4095;

var
  { INV_SQ[c] = 2^30 div c^2: a predictor's weight by its cost }
  INV_SQ: array[1..MAX_COST] of Integer;

procedure CodeSamples(var pc: TPixelCoder; var d: TBytes; const L: TRasterLayout);
var
  P: TPlan;
  rows: array[0..2] of array of Integer;     { samples: this row and the two above }
  errs: array[0..1] of array of Integer;     { residuals: this row and the one above }
  eP: array[0..1] of array of Integer;       { each predictor's error, for blending }
  pr, cost: array[0..N_PRED - 1] of Integer;
  cur, up, up2, ecur, eup, y, x, i, s, w, ns, idx, half, full, k, j, m, bit, t: Integer;
  pred, r, v, ref, eref, kref, xr, blend: Integer;
  W_, N_, NW_, NE_, WW_, NN_, NNE_, eW, eN, eNW, eNE, act, qa, qc, dh, dv: Integer;
  rW, rN, rNW, i2, b0, cW, cN, cNW, cNE, cmin, tq, wq, sw, acc, dd: Integer;
  o: Int64;
begin
  MakePlan(L, P);
  ns := P.nsub; w := P.cw;
  for i := 0 to 2 do begin rows[i] := nil; SetLength(rows[i], w * ns); end;
  for i := 0 to 1 do begin errs[i] := nil; SetLength(errs[i], w * ns); end;
  { blending: 8-bit samples without a reference channel (gray, and green) }
  blend := Ord(L.bits = 8);
  for i := 0 to 1 do begin eP[i] := nil; SetLength(eP[i], w * ns * N_PRED * blend); end;
  half := 1 shl (P.B - 1); full := 1 shl P.B;
  pc.nm := N_MODELS;
  for y := 0 to Integer(L.height) - 1 do begin
    cur := y mod 3; up := (y + 2) mod 3; up2 := (y + 1) mod 3;
    ecur := y mod 2; eup := (y + 1) mod 2;
    if pc.encoding then LoadRow(d, L, P, y, rows[cur]);
    for x := 0 to w - 1 do
      for i := 0 to ns - 1 do begin
        s := P.order[i];
        idx := x * ns + s;
        ref := P.predRef[s];
        { the neighbours, the missing ones replaced by the nearest there is }
        if y > 0 then begin
          N_ := rows[up][idx]; eN := errs[eup][idx];
          if x > 0 then begin NW_ := rows[up][idx - ns]; eNW := errs[eup][idx - ns]; end else begin NW_ := N_; eNW := eN; end;
          if x < w - 1 then begin NE_ := rows[up][idx + ns]; eNE := errs[eup][idx + ns]; end else begin NE_ := N_; eNE := eN; end;
          if y > 1 then NN_ := rows[up2][idx] else NN_ := N_;
          if (y > 1) and (x < w - 1) then NNE_ := rows[up2][idx + ns] else NNE_ := NN_;
        end;
        if x > 0 then begin
          W_ := rows[cur][idx - ns]; eW := errs[ecur][idx - ns];
          if x > 1 then WW_ := rows[cur][idx - 2 * ns] else WW_ := W_;
        end;
        if y = 0 then begin
          if x = 0 then begin W_ := 0; WW_ := 0; eW := 0; end;
          N_ := W_; NW_ := W_; NE_ := W_; NN_ := W_; NNE_ := W_; eN := eW; eNW := eW; eNE := eW;
        end else if x = 0 then begin
          W_ := N_; WW_ := N_; NW_ := N_; eW := eN;
        end;
        qc := 0;
        if ref >= 0 then begin
          { MED on the difference to the reference channel, which is already coded }
          xr := rows[cur][x * ns + ref];
          if y > 0 then begin
            rN := N_ - rows[up][x * ns + ref];
            if x > 0 then rNW := NW_ - rows[up][(x - 1) * ns + ref] else rNW := rN;
          end;
          if x > 0 then rW := W_ - rows[cur][(x - 1) * ns + ref] else rW := rN;
          if y = 0 then begin
            if x = 0 then rW := 0;
            rN := rW; rNW := rW;
          end;
          pred := Med(rW, rN, rNW) + xr;
        end else if blend <> 0 then begin
          { several predictors, each weighted by 1 / its local error squared }
          pr[0] := W_; pr[1] := N_; pr[2] := NE_; pr[3] := NW_; pr[4] := W_ + N_ - NW_;
          pr[5] := W_ + NE_ - N_; pr[6] := N_ + NE_ - NNE_; pr[7] := (W_ + N_ + 1) shr 1;
          pr[8] := Med(W_, N_, NW_); pr[9] := 2 * N_ - NN_; pr[10] := (W_ + NE_ + 1) shr 1; pr[11] := 2 * W_ - WW_;
          cmin := MaxInt;
          for i2 := 0 to N_PRED - 1 do begin
            b0 := idx * N_PRED + i2;
            cW := 0; cN := 0; cNW := 0; cNE := 0;
            if y > 0 then begin
              cN := eP[eup][b0];
              if x > 0 then cNW := eP[eup][b0 - ns * N_PRED] else cNW := cN;
              if x < w - 1 then cNE := eP[eup][b0 + ns * N_PRED] else cNE := cN;
            end;
            if x > 0 then cW := eP[ecur][b0 - ns * N_PRED] else cW := cN;
            if y = 0 then begin cN := cW; cNW := cW; cNE := cW; end;
            cost[i2] := 1 + cW + cN + cNW + cNE;
            if cost[i2] < cmin then cmin := cost[i2];
          end;
          { weights 2^30 / cost^2 from a table, shifted so that the best is
            below 2048 (no division but the last); differences up to 2^10:
            well inside 32 bits }
          if cmin > MAX_COST then cmin := MAX_COST;
          tq := BitLen(INV_SQ[cmin]) - 11;
          if tq < 0 then tq := 0;
          sw := 0; acc := 0;
          for i2 := 0 to N_PRED - 1 do begin
            if cost[i2] > MAX_COST then wq := INV_SQ[MAX_COST] shr tq else wq := INV_SQ[cost[i2]] shr tq;
            acc := acc + wq * (pr[i2] - pr[8]);
            sw := sw + wq;
          end;
          if sw = 0 then sw := 1;
          pred := pr[8] + acc div sw;
          qc := Cap(BitLen(cmin), 15);
        end else
          pred := Med(W_, N_, NW_);
        if pred < 0 then pred := 0 else if pred >= full then pred := full - 1;
        ref := P.ctxRef[s];
        if ref >= 0 then begin
          eref := errs[ecur][x * ns + ref];
          kref := BitLen(Abs(eref)) * 2;
          if eref < 0 then Inc(kref);
        end else kref := 63;
        { the contexts }
        act := Abs(eW) + Abs(eN) + (Abs(eNW) + Abs(eNE)) shr 1;
        qa := BitLen(act);
        dh := Abs(W_ - WW_) + Abs(N_ - NW_) + Abs(NE_ - N_);
        dv := Abs(W_ - NW_) + Abs(N_ - NN_);
        pc.hm[0] := Hash4(1, s, qa, qc);
        pc.hm[1] := Hash4(2, s, SBucket(eW) + 16, SBucket(eN) + 16);
        pc.hm[2] := Hash4(3, s, kref, qa shr 1);
        pc.hm[3] := Hash4(4, s, (SBucket(eNW) + 16) or ((SBucket(eNE) + 16) shl 5), qa shr 2);
        pc.hm[4] := Hash4(5, s, Cap(BitLen(dh), 15), Cap(BitLen(dv), 15));
        pc.hm[5] := Hash2(6, s);
        pc.hm[6] := Hash4(9, s, (SBucket(W_ - pred) + 16) or ((SBucket(N_ - pred) + 16) shl 5), qa shr 1);
        pc.hm[7] := Hash4(10, s, (SBucket(NE_ - pred) + 16) or ((SBucket(W_ + N_ - NW_ - pred) + 16) shl 5), kref);
        pc.hm[8] := Hash4(7, s, W_, N_);
        pc.hm[9] := Hash4(8, s, Hash3(W_, NW_, N_), NE_);
        pc.sel := Cap(s, MAX_SUB_SEL - 1);
        pc.sel2 := Cap(qa, 15) + 16 * Cap(BitLen(Abs(eW - eN)), 15);
        pc.apmCtx := Cap(qa, 15);
        { the residual, modulo 2^B, in [-half, half) }
        if pc.encoding then begin
          r := rows[cur][idx] - pred;
          if r >= half then r := r - full else if r < -half then r := r + full;
          m := Abs(r); k := BitLen(m);
        end else begin r := 0; m := 0; k := 0; end;
        { its bit length, by a binary tree }
        t := 1;
        for j := P.kbits - 1 downto 0 do begin
          bit := pc.Code((k shr j) and 1, t, t);
          t := 2 * t + bit;
        end;
        k := t - (1 shl P.kbits);
        if k > P.B then k := P.B;             { only a damaged stream gets here }
        if k = 0 then r := 0
        else if k = P.B then r := -half
        else begin
          { the bits below the top one, then the sign }
          v := 1;
          for j := 1 to k - 1 do begin
            if j = 1 then t := 32 + k else t := 48 + k;
            bit := pc.Code((m shr (k - 1 - j)) and 1, 64 + k * 16 + j, t);
            v := 2 * v + bit;
          end;
          if pc.Code(Ord(r < 0), 400, CLASS_SIGN) <> 0 then r := -v else r := v;
        end;
        v := pred + r;
        if v >= full then v := v - full else if v < 0 then v := v + full;
        rows[cur][idx] := v;
        errs[ecur][idx] := r;
        if (blend <> 0) and (P.predRef[s] < 0) then
          for i2 := 0 to N_PRED - 1 do eP[ecur][idx * N_PRED + i2] := Abs(v - pr[i2]);
      end;
    if not pc.encoding then StoreRow(d, L, P, y, rows[cur]);
    { the row's padding bytes: one context a position, through a byte tree }
    if P.pad > 0 then begin
      pc.nm := 1; pc.sel2 := -1; pc.sel := 0;
      o := L.dataOffset + Int64(y) * L.rowBytes + L.rowBytes - P.pad;
      for i := 0 to P.pad - 1 do begin
        pc.hm[0] := Hash2(77, i);
        if pc.encoding then v := d[o + i] else v := 0;
        t := 1;
        for j := 7 downto 0 do t := 2 * t + pc.Code((v shr j) and 1, t, CLASS_PAD);
        if not pc.encoding then d[o + i] := t - 256;
      end;
      pc.nm := N_MODELS;
    end;
  end;
end;

{ ---------- indices ---------- }

{ One channel of 2, 4 or 8 bits taken as symbols, not intensities (palette
  indices, an image of a few gray levels): each value coded whole, by a
  binary tree, in contexts of the exact neighbouring values. }
procedure CodeIndices(var pc: TPixelCoder; var d: TBytes; const L: TRasterLayout);
var
  P: TPlan;
  rows: array[0..2] of array of Integer;
  cur, up, up2, y, x, w, j, t, v, W_, N_, NW_, NE_, WW_, NN_, flags: Integer;
begin
  MakePlan(L, P);
  w := P.cw;
  for x := 0 to 2 do begin rows[x] := nil; SetLength(rows[x], w); end;
  pc.nm := 8;
  for y := 0 to Integer(L.height) - 1 do begin
    cur := y mod 3; up := (y + 2) mod 3; up2 := (y + 1) mod 3;
    if pc.encoding then LoadRow(d, L, P, y, rows[cur]);
    for x := 0 to w - 1 do begin
      if x > 0 then W_ := rows[cur][x - 1] else W_ := 256;
      if x > 1 then WW_ := rows[cur][x - 2] else WW_ := 256;
      if y > 0 then begin
        N_ := rows[up][x];
        if x > 0 then NW_ := rows[up][x - 1] else NW_ := 256;
        if x < w - 1 then NE_ := rows[up][x + 1] else NE_ := 256;
        if y > 1 then NN_ := rows[up2][x] else NN_ := 256;
      end else begin N_ := 256; NW_ := 256; NE_ := 256; NN_ := 256; end;
      pc.hm[0] := Hash2(31, W_);
      pc.hm[1] := Hash2(32, N_);
      pc.hm[2] := Hash3(33, W_, N_);
      pc.hm[3] := Hash4(34, W_, N_, NW_);
      pc.hm[4] := Hash4(35, W_, N_, NE_);
      pc.hm[5] := Hash4(36, Hash3(W_, WW_, NW_), N_, NE_);
      pc.hm[6] := Hash4(37, N_, NN_, NE_);
      pc.hm[7] := Hash2(38, 0);
      flags := Ord(W_ = N_) or (Ord(N_ = NE_) shl 1) or (Ord(W_ = NW_) shl 2) or (Ord(W_ = WW_) shl 3);
      pc.sel := 0; pc.sel2 := flags; pc.apmCtx := flags;
      if pc.encoding then v := rows[cur][x] else v := 0;
      t := 1;
      for j := P.B - 1 downto 0 do
        t := 2 * t + pc.Code((v shr j) and 1, t, Cap(P.B - 1 - j, 7) + 8 * (flags and 7));
      rows[cur][x] := t - (1 shl P.B);
    end;
    if not pc.encoding then StoreRow(d, L, P, y, rows[cur]);
  end;
  pc.nm := N_MODELS;
end;

{ ---------- 1-bit images ---------- }

procedure CodeBits(var pc: TPixelCoder; var d: TBytes; const L: TRasterLayout);
var
  rows: array[0..2] of array of Byte;
  cur, up, up2, w, x, b, t1, t2, i, y: Integer;
  o: Int64;

  function Px(r, xx: Integer): Integer; inline;
  begin
    if (xx < 0) or (xx >= w) then Result := 0 else Result := rows[r][xx];
  end;

begin
  { every bit of the row, the padding bits too }
  w := Integer(L.rowBytes) * 8;
  for i := 0 to 2 do begin rows[i] := nil; SetLength(rows[i], w); end;
  pc.nm := 3;
  for y := 0 to Integer(L.height) - 1 do begin
    cur := y mod 3; up := (y + 2) mod 3; up2 := (y + 1) mod 3;
    if y = 0 then begin FillChar(rows[up][0], w, 0); FillChar(rows[up2][0], w, 0); end
    else if y = 1 then FillChar(rows[up2][0], w, 0);
    o := L.dataOffset + Int64(y) * L.rowBytes;
    if pc.encoding then
      for x := 0 to w - 1 do rows[cur][x] := (d[o + x shr 3] shr (7 - x and 7)) and 1;
    for x := 0 to w - 1 do begin
      t1 := Px(cur, x - 1) or (Px(cur, x - 2) shl 1) or (Px(up, x - 1) shl 2) or (Px(up, x) shl 3)
         or (Px(up, x + 1) shl 4) or (Px(cur, x - 3) shl 5) or (Px(up, x - 2) shl 6) or (Px(up, x + 2) shl 7)
         or (Px(up2, x) shl 8) or (Px(cur, x - 4) shl 9);
      t2 := t1 or (Px(up2, x - 1) shl 10) or (Px(up2, x + 1) shl 11) or (Px(up, x - 3) shl 12)
         or (Px(up, x + 3) shl 13) or (Px(cur, x - 5) shl 14) or (Px(cur, x - 6) shl 15);
      pc.hm[0] := Hash2(11, t1);
      pc.hm[1] := Hash2(12, t2);
      pc.hm[2] := Hash4(13, t2, (Px(up2, x - 2) or (Px(up2, x + 2) shl 1) or (Px(cur, x - 7) shl 2)
         or (Px(cur, x - 8) shl 3) or (Px(up, x - 4) shl 4) or (Px(up, x + 4) shl 5)), 0);
      pc.sel := 0;
      b := pc.Code(rows[cur][x], 0, t1 and 31);
      rows[cur][x] := b;
    end;
    if not pc.encoding then
      for x := 0 to Integer(L.rowBytes) - 1 do begin
        b := 0;
        for i := 0 to 7 do b := (b shl 1) or rows[cur][8 * x + i];
        d[o + x] := b;
      end;
  end;
end;

{ ---------- the pixels ---------- }

procedure InitCoder(var pc: TPixelCoder; const L: TRasterLayout);
var n: Int64; bits: Integer;
begin
  n := L.width * L.height * L.channels;
  if L.bits = 32 then n := 2 * n;
  bits := 4;
  while (n > 0) and (bits < TABLE_BITS_MAX) do begin Inc(bits); n := n shr 1; end;
  if bits < TABLE_BITS_MIN then bits := TABLE_BITS_MIN;
  pc.t.Init(bits);
  pc.sel := 0; pc.sel2 := -1; pc.apmCtx := 0;
  if L.bits = 1 then pc.mx.Init(4, 32, MIXER_RATE)
  else begin
    pc.mx.Init(N_MODELS + 1, N_CLASSES * MAX_SUB_SEL, MIXER_RATE);
    pc.mx2.Init(N_MODELS + 1, N_CLASSES * N_SEL2, MIXER_RATE);
    pc.apm.Init(N_CLASSES * 16, 6);
  end;
end;

const
  { the encoder tries both modes on this many samples' worth of rows }
  TRIAL_SAMPLES = 65536;
  MODE_SAMPLES = 0;     { predicted intensities }
  MODE_INDICES = 1;     { symbols: CodeIndices }

{ whether the layout gets a mode byte: one channel of 2 to 8 bits, which
  may be intensities or palette indices }
function HasMode(const L: TRasterLayout): Boolean;
begin
  Result := (L.channels = 1) and (L.bits >= 2) and (L.bits <= 8);
end;

function EncodePixels(const d: TBytes; const L: TRasterLayout; mode: Integer = MODE_SAMPLES): TBytes;
var pc: TPixelCoder; dd: TBytes;
begin
  pc.encoding := True;
  InitCoder(pc, L);
  pc.enc.Init;
  dd := d;
  if L.bits = 1 then CodeBits(pc, dd, L)
  else if mode = MODE_INDICES then CodeIndices(pc, dd, L)
  else CodeSamples(pc, dd, L);
  Result := pc.enc.Finish;
end;

procedure DecodePixels(const s: TBytes; first: SizeInt; var d: TBytes; const L: TRasterLayout; mode: Integer = MODE_SAMPLES);
var pc: TPixelCoder;
begin
  pc.encoding := False;
  InitCoder(pc, L);
  pc.dec.Init(s, first);
  if L.bits = 1 then CodeBits(pc, d, L)
  else if mode = MODE_INDICES then CodeIndices(pc, d, L)
  else CodeSamples(pc, d, L);
end;

{ ---------- the stream ---------- }

function ParseAny(const d: TBytes; out L: TRasterLayout): TParseStatus;
begin
  Result := ParsePnm(d, L);
  if Result = psNotThis then Result := ParseBmp(d, L);
  if Result = psNotThis then Result := ParseHdr(d, L);
  if Result = psNotThis then Result := ParseFarbfeld(d, L);
  if Result = psNotThis then Result := ParseSun(d, L);
  if Result = psNotThis then Result := ParsePcx(d, L);
  if Result = psNotThis then Result := ParseSgi(d, L);
  if Result = psNotThis then Result := ParseVips(d, L);
  if Result = psNotThis then Result := ParseDds(d, L);
  if Result = psNotThis then Result := ParseIff(d, L);
  if Result = psNotThis then Result := ParseViff(d, L);
  if Result = psNotThis then Result := ParseDpx(d, L);
  if Result = psNotThis then Result := ParseCineon(d, L);
  if Result = psNotThis then Result := ParseFits(d, L);
  if Result = psNotThis then Result := ParseVicar(d, L);
  if Result = psNotThis then Result := ParseExr(d, L);
  { DICOM: a magic after a 128-byte preamble, or (old files) none }
  if Result = psNotThis then Result := ParseDicom(d, L);
  { no magic of their own: last, those whose fields say most first, those
    that have to fill the file (MTV, WBMP) before TGA }
  if Result = psNotThis then Result := ParseXwd(d, L);
  if Result = psNotThis then Result := ParseMtv(d, L);
  if Result = psNotThis then Result := ParseWbmp(d, L);
  if Result = psNotThis then Result := ParseTga(d, L);
end;

{ the layouts this version can code }
function Codable(const L: TRasterLayout): Boolean;
begin
  case L.bits of
    1, 2, 4: Result := L.channels = 1;
    8, 16: Result := not L.isFloat;
    32: Result := L.isFloat;
  else Result := False;
  end;
  { every sample of a row in rowBytes; what is left is padding }
  if Result then Result := L.rowBytes * 8 >= L.width * L.channels * L.bits;
end;

{ bytes a pixel of a coded file's raw pixels }
function PixelBytes(const L: TRasterLayout): Integer;
begin
  Result := (L.channels * L.bits + 7) div 8;
end;

{ a coded file's pixels (an HDR file's RGBE, a TGA's decoded packets): the
  layout of the raw pixels, as an image of its own }
function RawLayout(const L: TRasterLayout): TRasterLayout;
begin
  Result := L;
  Result.coding := CODING_RAW;
  Result.dataOffset := 0;
  Result.rowBytes := (L.width * L.channels * L.bits + 7) div 8;
  if L.format = rfSUN then Result.rowBytes := (Result.rowBytes + 1) and not 1;
  { a BMP's run-length rows: padded to 4 bytes, as the run-length codes them }
  if L.coding = CODING_BMP_RLE then Result.rowBytes := (L.width * L.bits + 31) div 32 * 4;
  { 10 bits packed: a row of words, three 16-bit samples each }
  if L.coding = CODING_PACK10 then Result.rowBytes := Pack10Words(L.width, L.channels) * 6;
  Result.dataLength := Result.rowBytes * L.height;
end;

{ ---------- run-length codings with their choices coded (prarle) ---------- }

function SideCoded(const L: TRasterLayout): Boolean;
begin
  Result := L.coding in [CODING_TGA_RLE, CODING_SUN_RLE, CODING_PCX, CODING_SGI_RLE, CODING_PLANES,
                         CODING_BMP_RLE, CODING_PLAIN, CODING_PACK10, CODING_EXR, CODING_PACKBITS,
                         CODING_PLANES_PACKBITS, CODING_ILBM];
end;

{ the raw pixels and the coded choices of the coded pixels in d }
function CodedScan(const d: TBytes; const L: TRasterLayout; out raw, side: TBytes): Boolean;
var used: Int64; dec: TBytes; bpp, planes, bpl, lines: Integer; R: TRasterLayout; methodB, wordsBE: Boolean;
  ix: TIffParams;
begin
  raw := nil; side := nil; Result := False;
  R := RawLayout(L);
  case L.coding of
    CODING_TGA_RLE: Result := TgaRleScan(d, L, PixelBytes(L), raw, side, used) = psOk;
    CODING_SUN_RLE: Result := ByteRleScan(brSun, d, L.dataOffset, R.dataLength, R.rowBytes, raw, side, used) = psOk;
    CODING_SGI_RLE: Result := SgiRleScan(d, L.dataOffset, L.width, L.height, L.channels, L.bits div 8,
                                         raw, side, used) = psOk;
    CODING_BMP_RLE: Result := BmpRleScan(d, L.dataOffset, L.width, L.height, L.bits, raw, side, used) = psOk;
    CODING_PLAIN: Result := PlainScan(d, L.dataOffset, R, raw, side, used) = psOk;
    CODING_PACK10: begin
      used := L.dataLength;
      Result := Pack10Params(L.format, d, 0, L.dataOffset, methodB, wordsBE)
        and Pack10Scan(d, L.dataOffset, L, methodB, wordsBE, raw, side);
    end;
    CODING_EXR: begin
      used := L.dataLength;
      Result := ExrScan(d, L.dataOffset, L, raw);
    end;
    CODING_PACKBITS: Result := PackBitsScan(d, L.dataOffset, R.dataLength, R.rowBytes, raw, side, used) = psOk;
    CODING_ILBM: Result := IffParams(d, 0, L.dataOffset, ix) and IffScan(d, L.dataOffset, ix, R, raw, side, used);
    CODING_PLANES_PACKBITS: begin
      { the planes' rows: a channel's samples in a row }
      Result := PackBitsScan(d, L.dataOffset, R.dataLength, R.rowBytes div L.channels, dec, side, used) = psOk;
      if Result then raw := SgiToPixels(dec, L.width, L.height, L.channels, L.bits div 8);
    end;
    CODING_PLANES: begin
      used := R.dataLength;
      Result := L.dataOffset + used <= Length(d);
      if Result then raw := SgiToPixels(Copy(d, L.dataOffset, used), L.width, L.height, L.channels, L.bits div 8);
    end;
    CODING_PCX: begin
      if not PcxParams(d, 0, bpp, planes, bpl, lines) then Exit;
      Result := ByteRleScan(brPcx, d, L.dataOffset, Int64(lines) * planes * bpl, planes * bpl, dec, side, used) = psOk;
      if Result then raw := PcxToPixels(dec, bpp, planes, bpl, lines);
    end;
  end;
  Result := Result and (used = L.dataLength);
end;

{ the coded pixels again (hdr: the file's header, which PCX needs) }
function CodedRebuild(const hdr: TBytes; hdrFirst: SizeInt; const raw, side: TBytes; const L: TRasterLayout;
                      out coded: TBytes): Boolean;
var bpp, planes, bpl, lines: Integer; R: TRasterLayout; methodB, wordsBE: Boolean; ymin: Int64; ix: TIffParams;
begin
  coded := nil; Result := False;
  R := RawLayout(L);
  if Length(raw) <> R.dataLength then Exit;
  case L.coding of
    CODING_TGA_RLE: Result := TgaRleRebuild(raw, side, L, PixelBytes(L), L.dataLength, coded);
    CODING_SUN_RLE: Result := ByteRleRebuild(brSun, raw, side, R.rowBytes, L.dataLength, coded);
    CODING_SGI_RLE: Result := SgiRleRebuild(raw, side, L.width, L.height, L.channels, L.bits div 8, L.dataLength, coded);
    CODING_BMP_RLE: Result := BmpRleRebuild(raw, side, L.width, L.height, L.bits, L.dataLength, coded);
    CODING_PLAIN: Result := PlainRebuild(raw, side, R, L.dataLength, coded);
    CODING_PACK10:
      Result := Pack10Params(L.format, hdr, hdrFirst, Length(hdr) - hdrFirst, methodB, wordsBE)
        and Pack10Rebuild(raw, side, L, methodB, wordsBE, coded) and (Length(coded) = L.dataLength);
    CODING_EXR:
      Result := ExrYMin(hdr, hdrFirst, Length(hdr) - hdrFirst, ymin) and ExrRebuild(raw, L.dataOffset, L, ymin, coded)
        and (Length(coded) = L.dataLength);
    CODING_PACKBITS: Result := PackBitsRebuild(raw, side, R.rowBytes, L.dataLength, coded);
    CODING_ILBM: Result := IffParams(hdr, hdrFirst, Length(hdr) - hdrFirst, ix) and IffRebuild(raw, side, ix, L.dataLength, coded);
    CODING_PLANES_PACKBITS:
      Result := PackBitsRebuild(SgiFromPixels(raw, L.width, L.height, L.channels, L.bits div 8), side,
                                R.rowBytes div L.channels, L.dataLength, coded);
    CODING_PLANES: begin
      coded := SgiFromPixels(raw, L.width, L.height, L.channels, L.bits div 8);
      Result := Length(coded) = L.dataLength;
    end;
    CODING_PCX: begin
      if not PcxParams(hdr, hdrFirst, bpp, planes, bpl, lines) then Exit;
      Result := ByteRleRebuild(brPcx, PcxFromPixels(raw, bpp, planes, bpl, lines), side, planes * bpl,
                               L.dataLength, coded);
    end;
  end;
end;

{ the decoder, before anything is allocated: can the raw pixels be in
  dataLength coded bytes at all; and do they agree with the header }
function CodedFits(const hdr: TBytes; hdrFirst: SizeInt; const L: TRasterLayout): Boolean;
var bpp, planes, bpl, lines, w, ch, bits: Integer; R: TRasterLayout; methodB, wordsBE: Boolean; ymin: Int64;
  ix: TIffParams;
begin
  R := RawLayout(L);
  case L.coding of
    CODING_TGA_RLE: Result := TgaRleFits(L.width, L.height, PixelBytes(L), L.dataLength);
    CODING_SUN_RLE: Result := ByteRleFits(brSun, R.dataLength, L.dataLength);
    CODING_SGI_RLE: Result := (L.bits in [8, 16])
      and SgiRleFits(L.width, L.height, L.channels, L.bits div 8, L.dataLength);
    CODING_PLANES: Result := (L.bits in [8, 16]) and (L.dataLength = R.dataLength) and (R.dataLength <= MAX_RAW);
    CODING_BMP_RLE: Result := (L.channels = 1) and BmpRleFits(L.width, L.height, L.bits, L.dataLength);
    CODING_PLAIN: Result := PlainFits(L, L.dataLength);
    CODING_PACK10: Result := (L.bits = 16) and Pack10Params(L.format, hdr, hdrFirst, Length(hdr) - hdrFirst, methodB, wordsBE)
      and Pack10Fits(L, L.dataLength) and (L.dataLength = Pack10Words(L.width, L.channels) * 4 * L.height);
    CODING_EXR: Result := ExrYMin(hdr, hdrFirst, Length(hdr) - hdrFirst, ymin) and ExrFits(L, L.dataLength)
      and (L.dataLength = L.height * (16 + L.width * L.channels * (L.bits div 8)));
    CODING_PACKBITS: Result := (R.rowBytes >= 1) and PackBitsFits(R.dataLength, L.dataLength);
    CODING_PLANES_PACKBITS: Result := (L.bits in [8, 16]) and PackBitsFits(R.dataLength, L.dataLength);
    CODING_ILBM: begin
      { the pixels have to be the ones the header's planes make }
      Result := IffParams(hdr, hdrFirst, Length(hdr) - hdrFirst, ix) and (L.bits = 8) and (L.height = ix.h)
        and (IffDecodedLength(ix) <= MAX_RAW);
      if Result then
        if ix.kind = ikPBM then Result := (L.width = ix.rb) and (L.channels = 1)
        else if ix.planes > 8 then Result := (L.width = ix.rb * 8) and (L.channels = ix.planes div 8)
        else Result := (L.width = ix.rb * 8) and (L.channels = 1);
      if Result then
        if ix.compression = 1 then Result := PackBitsFits(IffDecodedLength(ix), L.dataLength)
        else Result := L.dataLength = IffDecodedLength(ix);
    end;
    CODING_PCX: begin
      { the pixels' layout has to be the one the header gives (PcxFromPixels
        reads them by it), and the decoded lines have to fit }
      Result := PcxParams(hdr, hdrFirst, bpp, planes, bpl, lines) and (lines = L.height);
      if Result then begin
        PcxPixels(bpp, planes, bpl, w, ch, bits);
        Result := (w = L.width) and (ch = L.channels) and (bits = L.bits)
          and ByteRleFits(brPcx, Int64(lines) * planes * bpl, L.dataLength);
      end;
    end;
  else Result := False;
  end;
end;

{ What the stream says before its pixels: ReadStream reads it (the decoder,
  and the encoder checking what it wrote), with every limit applied before
  anything is allocated. }
type
  TStreamHead = record
    L: TRasterLayout;
    modes: TBytes;                 { HDR: each line's coder }
    side: TBytes;                  { TGA run-length: the packets, coded }
    mode: Integer;                 { one channel of 2-8 bits: samples or indices }
    hdr, tail: TBytes;             { the bytes kept: before and after the pixels }
    pixFirst: SizeInt;
    tailLen: Int64;
    bands: Integer;
    bandFirst, bandLen: array of SizeInt;  { where each band's bytes are in the stream }
  end;

function ReadStream(const s: TBytes; maxOut: Int64; out h: TStreamHead): TDecodeStatus;
var
  src: TSource; hdrLen, run, y, rest, sideLen: Int64; flags, f, ver, m, k: Integer; Lp: TRasterLayout;
  st: TParseStatus; stride: Int64;
begin
  h.modes := nil; h.side := nil; h.mode := MODE_SAMPLES; h.L.Clear;
  h.bands := 0; h.bandFirst := nil; h.bandLen := nil;
  h.hdr := nil; h.tail := nil; h.pixFirst := 0; h.tailLen := 0;
  if Length(s) = 0 then Exit(dsEmpty);
  src.b := s; src.p := 0; src.ok := True;
  ver := src.Get;
  if ver > STREAM_VERSION then Exit(dsFutureVersion);
  if (ver < 1) or (ver > IMAGE_STREAM) then Exit(dsBadStream);
  hdrLen := src.GetVarint(MAX_TEXT_HEADER);
  if not src.ok then Exit(dsBadStream);
  if hdrLen > maxOut then Exit(dsTooBig);
  if not GetSection(src, ver, hdrLen, h.hdr) then Exit(dsBadStream);
  f := src.Get;
  if (f <= Ord(Low(TRasterFormat))) or (f > Ord(High(TRasterFormat)))
     or (TRasterFormat(f) in [rfICO, rfCUR, rfDCX]) then Exit(dsBadStream);
  h.L.format := TRasterFormat(f);
  h.L.width := src.GetVarint(MAX_DIMENSION);
  h.L.height := src.GetVarint(MAX_DIMENSION);
  h.L.channels := src.GetVarint(MAX_CHANNELS);
  h.L.bits := src.Get;
  flags := src.Get;
  h.L.maxval := src.GetVarint(High(Cardinal));
  if not src.ok or (flags > 15) then Exit(dsBadStream);
  { how the file stores its pixels: by the format, and flag bit 3 (TGA and
    Sun Raster run-length) }
  case h.L.format of
    rfHDR: h.L.coding := CODING_HDR;
    rfPCX: h.L.coding := CODING_PCX;
    rfTGA: if (flags and 8) <> 0 then h.L.coding := CODING_TGA_RLE;
    rfSUN: if (flags and 8) <> 0 then h.L.coding := CODING_SUN_RLE;
    rfSGI: if (flags and 8) <> 0 then h.L.coding := CODING_SGI_RLE else h.L.coding := CODING_PLANES;
    rfVIFF: if h.L.channels > 1 then h.L.coding := CODING_PLANES;
    rfBMP: if (flags and 8) <> 0 then h.L.coding := CODING_BMP_RLE;
    rfPBM, rfPGM, rfPPM: if (flags and 8) <> 0 then h.L.coding := CODING_PLAIN;
    rfDPX, rfCineon: if (flags and 8) <> 0 then h.L.coding := CODING_PACK10;
    rfFITS, rfVICAR, rfDICOM: if (flags and 8) <> 0 then h.L.coding := CODING_PLANES;
    rfEXR: h.L.coding := CODING_EXR;
    rfTIFF: if (flags and 8) <> 0 then h.L.coding := CODING_PACKBITS;
    rfIFF: h.L.coding := CODING_ILBM;
    { PSD: PackBits or not, planes or not }
    rfPSD:
      if (flags and 8) <> 0 then begin
        if h.L.channels > 1 then h.L.coding := CODING_PLANES_PACKBITS else h.L.coding := CODING_PACKBITS;
      end else if h.L.channels > 1 then h.L.coding := CODING_PLANES;
  end;
  if ((flags and 8) <> 0) and not (h.L.coding in [CODING_TGA_RLE, CODING_SUN_RLE, CODING_SGI_RLE,
                                                   CODING_BMP_RLE, CODING_PLAIN, CODING_PACK10, CODING_PACKBITS,
                                                   CODING_PLANES_PACKBITS])
     and not ((h.L.coding = CODING_PLANES) and (h.L.format in [rfFITS, rfVICAR, rfDICOM])) then Exit(dsBadStream);
  if SideCoded(h.L) then begin
    { the coded length within the cap, the image within what that length
      can hold, and the coder's choices }
    h.L.dataLength := src.GetVarint(maxOut);
    sideLen := src.GetVarint(Length(s));
    if not src.ok or (sideLen > Length(s) - src.p) then Exit(dsBadStream);
    if (h.L.width < 1) or (h.L.height < 1) or (h.L.width > MAX_DIMENSION) or (h.L.height > MAX_DIMENSION)
       or (h.L.channels < 1) then Exit(dsBadStream);
    { what the codings make: EXR's lines of any channels, half or float;
      the others up to 4 channels of 1 to 16 bits }
    if h.L.coding = CODING_EXR then begin
      if (h.L.channels > MAX_CHANNELS) or not (h.L.bits in [16, 32]) or (((flags and 2) <> 0) <> (h.L.bits = 32)) then Exit(dsBadStream);
    end else if h.L.coding in [CODING_PLANES, CODING_PLANES_PACKBITS] then begin
      { planes: any channels (PSD's composite), 8 or 16 bits }
      if (h.L.channels > MAX_CHANNELS) or not (h.L.bits in [8, 16]) then Exit(dsBadStream);
    end else if (h.L.channels > 4) or not (h.L.bits in [1, 2, 4, 8, 16]) then Exit(dsBadStream);
    if not CodedFits(h.hdr, 0, h.L) then Exit(dsBadStream);
    h.side := Copy(s, src.p, sideLen);
    Inc(src.p, sideLen);
    h.L.rowBytes := RawLayout(h.L).rowBytes;
  end;
  if h.L.coding = CODING_HDR then begin
    { the scanlines' length within the cap, and the image within what that
      length can hold, before anything is allocated }
    h.L.dataLength := src.GetVarint(maxOut);
    if not src.ok then Exit(dsBadStream);
    if (h.L.channels <> 4) or (h.L.bits <> 8) or not HdrFits(h.L.width, h.L.height, h.L.dataLength) then Exit(dsBadStream);
    h.L.rowBytes := h.L.width * 4;
    SetLength(h.modes, h.L.height);
    y := 0;
    while src.ok and (y < h.L.height) do begin
      m := src.Get;
      run := src.GetVarint(h.L.height - y);
      if (m > HDR_STB) or (run < 1) then Exit(dsBadStream);
      for k := 0 to Integer(run) - 1 do h.modes[y + k] := m;
      Inc(y, run);
    end;
  end;
  h.tailLen := src.GetVarint(High(Int64) shr 1);
  if not src.ok then Exit(dsBadStream);
  { the cap before the tail is decoded }
  if h.tailLen > maxOut - hdrLen then Exit(dsTooBig);
  if not GetSection(src, ver, h.tailLen, h.tail) then Exit(dsBadStream);
  h.L.bigEndian := (flags and 1) <> 0;
  h.L.isFloat := (flags and 2) <> 0;
  h.L.bottomUp := (flags and 4) <> 0;
  h.L.dataOffset := hdrLen;
  { the limits, before anything is decoded: the pixels have to fit in maxOut }
  if hdrLen + h.tailLen > maxOut then Exit(dsTooBig);
  if h.L.coding <> CODING_RAW then begin
    if h.L.dataLength > maxOut - hdrLen - h.tailLen then Exit(dsTooBig);
  end else begin
    { XWD's rows are as long as its header says }
    stride := HeaderStride(h.L.format, h.hdr, 0, hdrLen);
    if stride >= 0 then st := SizeRowsStride(h.L, maxOut - hdrLen - h.tailLen, stride)
    else st := SizeRows(h.L, maxOut - hdrLen - h.tailLen);
    case st of
      psOk: ;
      psTruncated: Exit(dsTooBig);
    else Exit(dsBadStream);
    end;
  end;
  if not Codable(h.L) then Exit(dsBadStream);
  if HasMode(h.L) then begin
    h.mode := src.Get;
    if not src.ok or (h.mode > MODE_INDICES) then Exit(dsBadStream);
  end;
  { the bands: how many, and how long each one but the last is }
  if h.L.coding <> CODING_RAW then Lp := RawLayout(h.L) else Lp := h.L;
  h.bands := src.GetVarint(MAX_BANDS);
  if not src.ok or (h.bands < 1) or (h.bands > Lp.height) then Exit(dsBadStream);
  SetLength(h.bandFirst, h.bands); SetLength(h.bandLen, h.bands);
  { a band is never longer than the stream (and bandLen is 32-bit on i386) }
  for k := 0 to h.bands - 2 do h.bandLen[k] := src.GetVarint(Length(s));
  if not src.ok then Exit(dsBadStream);
  h.pixFirst := src.p;
  rest := Length(s) - src.p;
  for k := 0 to h.bands - 2 do begin
    if h.bandLen[k] > rest then Exit(dsBadStream);
    h.bandFirst[k] := Length(s) - rest;
    Dec(rest, h.bandLen[k]);
  end;
  h.bandFirst[h.bands - 1] := Length(s) - rest;
  h.bandLen[h.bands - 1] := rest;
  Result := dsOk;
end;

{ ---------- verifying while encoding ---------- }

type
  { Decodes the pixels from the encoder's bytes as they come out (a
    TLiveStream), on its own thread: the check runs beside the encoding.
    A bare thread (BeginThread, WaitForThreadTerminate): TThread.WaitFor
    called from the main thread waits in steps of 100 ms in FreePascal 3.2,
    which made every small file 100 ms slower (measured 01/11/2026). }
  TVerifier = record
    live: TLiveStream;
    L: TRasterLayout;
    mode: Integer;
    back: TBytes;
    failed: Boolean;
  end;
  PVerifier = ^TVerifier;

function VerifierRun(p: Pointer): PtrInt;
var v: PVerifier; pc: TPixelCoder;
begin
  v := p;
  v^.failed := False;
  try
    pc.encoding := False;
    InitCoder(pc, v^.L);
    pc.dec.InitLive(v^.live);
    if v^.L.bits = 1 then CodeBits(pc, v^.back, v^.L)
    else if v^.mode = MODE_INDICES then CodeIndices(pc, v^.back, v^.L)
    else CodeSamples(pc, v^.back, v^.L);
  except
    v^.failed := True;
  end;
  Result := 0;
end;

function EncodePixelsLive(const d: TBytes; const L: TRasterLayout; mode: Integer; live: TLiveStream): TBytes;
var pc: TPixelCoder; dd: TBytes;
begin
  pc.encoding := True;
  InitCoder(pc, L);
  pc.enc.InitLive(live);
  dd := d;
  try
    if L.bits = 1 then CodeBits(pc, dd, L)
    else if mode = MODE_INDICES then CodeIndices(pc, dd, L)
    else CodeSamples(pc, dd, L);
  except
    { the reader must not wait for bytes that will never come }
    live.Finish;
    raise;
  end;
  Result := pc.enc.Finish;
end;

{ ---------- bands ---------- }

{ how many bands the encoder makes of an image (the stream records it) }
function BandCount(const Lp: TRasterLayout): Integer;
var n: Int64;
begin
  n := (Lp.rowBytes * Lp.height) div BandBytes;
  if n > MAX_BANDS then n := MAX_BANDS;
  if n > Lp.height then n := Lp.height;
  if n < 1 then n := 1;
  Result := n;
end;

{ band b of n: its rows, [first, first + rows) }
procedure BandRows(const Lp: TRasterLayout; n, b: Integer; out first, rows: Int64);
var per: Int64;
begin
  per := (Lp.height + n - 1) div n;
  first := per * b;
  rows := Lp.height - first;
  if rows > per then rows := per;
  if rows < 0 then rows := 0;
end;

{ the layout of a band: the same rows, from its own first one }
function BandLayout(const Lp: TRasterLayout; n, b: Integer): TRasterLayout;
var first, rows: Int64;
begin
  BandRows(Lp, n, b, first, rows);
  Result := Lp;
  Result.dataOffset := Lp.dataOffset + first * Lp.rowBytes;
  Result.height := rows;
  Result.dataLength := rows * Lp.rowBytes;
end;

{ n jobs over `threads` threads (this one included): each takes the next
  job until none is left. A job catches its own exceptions. }
type
  TJobProc = procedure(ctx: Pointer; k: Integer);
  TJobPool = record
    proc: TJobProc;
    ctx: Pointer;
    count: Integer;
    next: LongInt;
  end;
  PJobPool = ^TJobPool;

function PoolWorker(p: Pointer): PtrInt;
var pool: PJobPool; k: LongInt;
begin
  pool := p;
  repeat
    k := InterlockedIncrement(pool^.next) - 1;
    if k >= pool^.count then Break;
    pool^.proc(pool^.ctx, k);
  until False;
  Result := 0;
end;

procedure RunJobs(count, threads: Integer; proc: TJobProc; ctx: Pointer);
var pool: TJobPool; ids: array of TThreadID; i: Integer;
begin
  pool.proc := proc; pool.ctx := ctx; pool.count := count; pool.next := 0;
  if threads > count then threads := count;
  ids := nil; SetLength(ids, threads - 1);
  for i := 0 to High(ids) do ids[i] := BeginThread(@PoolWorker, @pool);
  PoolWorker(@pool);
  for i := 0 to High(ids) do begin WaitForThreadTerminate(ids[i], 0); CloseThread(ids[i]); end;
end;

{ encoding: each band coded, and decoded beside it by its own verifier }
type
  TEncodeBands = record
    px, back: TBytes;
    Lp: TRasterLayout;
    mode, n: Integer;
    outs: array of TBytes;
    failed: array of Boolean;
  end;
  PEncodeBands = ^TEncodeBands;

procedure EncodeBandJob(ctx: Pointer; k: Integer);
var e: PEncodeBands; Lb: TRasterLayout; live: TLiveStream; v: TVerifier; tid: TThreadID; ok: Boolean;
begin
  e := ctx;
  e^.failed[k] := True;
  Lb := BandLayout(e^.Lp, e^.n, k);
  live := TLiveStream.Create;
  v.live := live; v.L := Lb; v.mode := e^.mode; v.back := e^.back; v.failed := True;
  tid := BeginThread(@VerifierRun, @v);
  ok := True;
  try
    { on an exception EncodePixelsLive finishes the stream: the verifier ends }
    e^.outs[k] := EncodePixelsLive(e^.px, Lb, e^.mode, live);
  except
    ok := False;
  end;
  WaitForThreadTerminate(tid, 0);
  CloseThread(tid);
  live.Free;
  e^.failed[k] := not ok or v.failed;
end;

{ decoding: each band from its own copy of its bytes, so that what the
  arithmetic decoder reads past a band's end is zeros, as it was for the
  verifier }
type
  TDecodeBands = record
    bytes: array of TBytes;
    out_: TBytes;
    Lp: TRasterLayout;
    mode, n: Integer;
    failed: array of Boolean;
  end;
  PDecodeBands = ^TDecodeBands;

procedure DecodeBandJob(ctx: Pointer; k: Integer);
var e: PDecodeBands;
begin
  e := ctx;
  e^.failed[k] := True;
  try
    DecodePixels(e^.bytes[k], 0, e^.out_, BandLayout(e^.Lp, e^.n, k), e^.mode);
    e^.failed[k] := False;
  except
  end;
end;

{ ---------- the stream ---------- }

function SameBytes(const a: TBytes; aFirst: SizeInt; const b: TBytes; bFirst, len: SizeInt): Boolean;
begin
  if (len < 0) or (aFirst < 0) or (bFirst < 0) or (aFirst + len > Length(a)) or (bFirst + len > Length(b)) then Exit(False);
  Result := (len = 0) or CompareMem(@a[aFirst], @b[bFirst], len);
end;

function EncodeImage(const d: TBytes; const L: TRasterLayout; out s: TBytes; out why: string; threads: Integer): Boolean;
var
  Lp, Lt: TRasterLayout; o: TSink; tailFirst, used, trialRows: Int64; flags: Byte;
  px, rgbe, modes, side, prefix, lines, back: TBytes; y, run, m, k: Integer; at: SizeInt;
  h: TStreamHead; ok: Boolean; eb: TEncodeBands;
begin
  s := nil; why := '';
  if not Codable(L) then begin why := 'layout not handled by this version'; Exit(False); end;
  { everything before the pixels }
  o.Init;
  o.Put(IMAGE_STREAM);
  PutSection(o, d, 0, L.dataOffset);
  o.Put(Ord(L.format));
  o.PutVarint(L.width); o.PutVarint(L.height); o.PutVarint(L.channels);
  o.Put(L.bits);
  flags := 0;
  if L.bigEndian then flags := flags or 1;
  if L.isFloat then flags := flags or 2;
  if L.bottomUp then flags := flags or 4;
  if L.coding in [CODING_TGA_RLE, CODING_SUN_RLE, CODING_SGI_RLE, CODING_BMP_RLE, CODING_PLAIN, CODING_PACK10,
                  CODING_PACKBITS, CODING_PLANES_PACKBITS] then flags := flags or 8;
  if (L.coding = CODING_PLANES) and (L.format in [rfFITS, rfVICAR, rfDICOM]) then flags := flags or 8;
  o.Put(flags);
  o.PutVarint(L.maxval);
  rgbe := nil; modes := nil; side := nil;
  if SideCoded(L) then begin
    { the coded length and the coder's choices; the pixels go to the pixel coder }
    if not CodedScan(d, L, rgbe, side) then begin why := 'run-length coding'; Exit(False); end;
    o.PutVarint(L.dataLength);
    o.PutVarint(Length(side));
    o.PutBytes(side, 0, Length(side));
  end;
  if L.coding = CODING_HDR then begin
    { the scanlines' length, and each line's coder, as runs of one mode }
    if HdrDecode(d, L, rgbe, modes, used) <> psOk then begin why := 'HDR scanlines'; Exit(False); end;
    o.PutVarint(L.dataLength);
    y := 0;
    while y < L.height do begin
      run := 1;
      while (y + run < L.height) and (modes[y + run] = modes[y]) do Inc(run);
      o.Put(modes[y]); o.PutVarint(run);
      Inc(y, run);
    end;
  end;
  tailFirst := L.dataOffset + L.dataLength;
  PutSection(o, d, tailFirst, Length(d) - tailFirst);
  { what the pixel coder codes: the file's pixels, or a coded file's raw
    pixels (an HDR file's RGBE, a TGA's decoded packets) }
  m := MODE_SAMPLES;
  if L.coding <> CODING_RAW then begin Lp := RawLayout(L); px := rgbe; end
  else begin Lp := L; px := d; end;
  if HasMode(Lp) then begin
    { both ways, and the smaller one: on the whole image when it is small,
      on its first rows (at least TRIAL_SAMPLES) otherwise. Only the
      encoder chooses; the decoder reads the mode byte. }
    trialRows := (TRIAL_SAMPLES + Lp.rowBytes * 8 div Lp.bits - 1) div (Lp.rowBytes * 8 div Lp.bits);
    Lt := Lp;
    if trialRows < Lp.height then Lt.height := trialRows;
    if Length(EncodePixels(px, Lt, MODE_INDICES)) < Length(EncodePixels(px, Lt, MODE_SAMPLES)) then m := MODE_INDICES;
    o.Put(m);
  end;
  { the bands }
  eb.px := px; eb.Lp := Lp; eb.mode := m;
  eb.n := BandCount(Lp);
  o.PutVarint(eb.n);
  { the pixels, and their check beside them: each band decoded by a second
    thread as its bytes come out, into one buffer (the bands are rows apart) }
  eb.back := nil; SetLength(eb.back, Length(px));
  eb.outs := nil; SetLength(eb.outs, eb.n);
  eb.failed := nil; SetLength(eb.failed, eb.n);
  RunJobs(eb.n, threads, @EncodeBandJob, @eb);
  ok := True;
  for k := 0 to eb.n - 1 do if eb.failed[k] then ok := False;
  back := eb.back;
  { the bands' lengths, all but the last }
  if ok then
    for k := 0 to eb.n - 2 do o.PutVarint(Length(eb.outs[k]));
  prefix := o.Done;
  { the one guarantee: it has to come back. The pixels first ... }
  if ok then
    if L.coding = CODING_HDR then begin
      lines := HdrEncode(back, modes, L);
      ok := (Length(lines) = L.dataLength) and SameBytes(lines, 0, d, L.dataOffset, L.dataLength);
    end else if SideCoded(L) then begin
      ok := CodedRebuild(d, 0, back, side, L, lines)
        and SameBytes(lines, 0, d, L.dataOffset, L.dataLength);
    end else
      ok := SameBytes(back, L.dataOffset, d, L.dataOffset, L.dataLength);
  { ... then everything else, read back from the stream as the decoder reads it }
  if ok then begin
    s := prefix;
    for k := 0 to eb.n - 1 do begin
      at := Length(s);
      SetLength(s, at + Length(eb.outs[k]));
      if Length(eb.outs[k]) > 0 then Move(eb.outs[k][0], s[at], Length(eb.outs[k]));
    end;
    ok := (ReadStream(s, Length(d), h) = dsOk) and (h.pixFirst = Length(prefix)) and (h.mode = m)
      and (h.bands = eb.n)
      and (h.L.format = L.format) and (h.L.width = L.width) and (h.L.height = L.height)
      and (h.L.channels = L.channels) and (h.L.bits = L.bits) and (h.L.bigEndian = L.bigEndian)
      and (h.L.isFloat = L.isFloat) and (h.L.dataOffset = L.dataOffset) and (h.L.dataLength = L.dataLength)
      and (h.L.dataOffset + h.L.dataLength + h.tailLen = Length(d))
      and SameBytes(h.hdr, 0, d, 0, L.dataOffset)
      and SameBytes(h.tail, 0, d, tailFirst, h.tailLen)
      and (h.L.coding = L.coding)
      and ((L.coding <> CODING_HDR) or SameBytes(h.modes, 0, modes, 0, L.height))
      and (Length(h.side) = Length(side)) and SameBytes(h.side, 0, side, 0, Length(side));
  end;
  if not ok then begin s := nil; why := 'did not come back the same'; Exit(False); end;
  Result := True;
end;

{ ---------- files of several images ---------- }

{ Version 3: the count of parts (varint), then each: its kind, 1 B (0
  bytes, 1 image, 2 a copy), and either a section (the bytes, prabytes),
  or the image's length in the file (varint), its stream's length (varint)
  and its stream (version 2), or the copy's length and where in the file
  its bytes were already (varints). An image that cannot be coded becomes
  bytes; a part the same as an earlier one, a copy (a PSD layer that is
  its composite). }
const
  PART_BYTES = 0;
  PART_IMAGE = 1;
  PART_COPY = 2;        { its length, then where the same bytes are, earlier }
  MIN_COPY = 64;

type
  PTBytes = ^TBytes;

{ orig: the encoder's check of the frame, the images (each verified when
  it was coded) taken from the original instead of decoded again }
function DecodeParts(const s: TBytes; maxOut: Int64; out d: TBytes; threads: Integer;
                     orig: PTBytes = nil): TDecodeStatus;
var src: TSource; n, k: SizeInt; len, slen, total, from: Int64; kind: Integer; part: TBytes; st: TDecodeStatus;
begin
  d := nil;
  src.b := s; src.p := 1; src.ok := True;
  { a part takes at least two bytes of the stream }
  n := src.GetVarint(Length(s));
  if not src.ok or (n < 1) then Exit(dsBadStream);
  total := 0;
  for k := 1 to n do begin
    kind := src.Get;
    len := src.GetVarint(High(Int64) shr 1);
    if not src.ok or (kind > PART_COPY) then Exit(dsBadStream);
    if len > maxOut - total then Exit(dsTooBig);
    if kind = PART_COPY then begin
      from := src.GetVarint(total);
      if not src.ok or (len < 1) or (len > total - from) then begin d := nil; Exit(dsBadStream); end;
      part := Copy(d, from, len);
    end else if kind = PART_BYTES then begin
      if not GetSection(src, IMAGE_STREAM, len, part) then Exit(dsBadStream);
    end else begin
      slen := src.GetVarint(Length(s) - src.p);
      if not src.ok or (slen < 1) or (s[src.p] = PARTS_STREAM) then Exit(dsBadStream);
      if orig <> nil then begin
        if total + len > Length(orig^) then Exit(dsBadStream);
        part := Copy(orig^, total, len);
      end else begin
        st := DecodeFile(Copy(s, src.p, slen), len, part, threads);
        if st <> dsOk then begin d := nil; Exit(st); end;
      end;
      if Length(part) <> len then begin d := nil; Exit(dsBadStream); end;
      Inc(src.p, slen);
    end;
    { the parts joined: room grown by halves, each part within the cap }
    if total + len > Length(d) then SetLength(d, Max(total + len, Min(maxOut, Length(d) + Length(d) div 2)));
    if len > 0 then Move(part[0], d[total], len);
    Inc(total, len);
  end;
  if src.p <> Length(s) then begin d := nil; Exit(dsBadStream); end;
  SetLength(d, total);
  Result := dsOk;
end;

function EncodeParts(const d: TBytes; const parts: TParts; out s: TBytes; out why: string; threads: Integer): Boolean;
var
  o: TSink; k, j, n, images, m: Integer; img, back: TBytes; w: string;
  subs: array of TBytes; first, len, copyFrom: array of Int64;
  hashes: array of QWord; h: QWord; q: Int64;
begin
  { the same bytes as an earlier part (a hash of each, then the bytes
    compared): a copy }
  hashes := nil; SetLength(hashes, Length(parts));
  for k := 0 to High(parts) do begin
    h := 1469598103934665603;
    {$push}{$Q-}{$R-}
    q := parts[k].first;
    while q < parts[k].first + parts[k].len do begin h := (h xor d[q]) * 1099511628211; Inc(q); end;
    {$pop}
    hashes[k] := h;
  end;
  { each image coded; one whose stream is not smaller than it (a mipmap of
    a few pixels) becomes bytes, and bytes next to bytes are one part }
  subs := nil; first := nil; len := nil; copyFrom := nil; n := 0;
  SetLength(subs, Length(parts)); SetLength(first, Length(parts)); SetLength(len, Length(parts));
  SetLength(copyFrom, Length(parts));
  for k := 0 to High(parts) do begin
    subs[n] := nil; copyFrom[n] := -1;
    if parts[k].len >= MIN_COPY then
      for m := 0 to k - 1 do
        if (hashes[m] = hashes[k]) and (parts[m].len = parts[k].len)
           and CompareMem(@d[parts[m].first], @d[parts[k].first], parts[k].len) then begin
          copyFrom[n] := parts[m].first; Break;
        end;
    if copyFrom[n] >= 0 then begin
      first[n] := parts[k].first; len[n] := parts[k].len; Inc(n); Continue;
    end;
    if parts[k].kind = pkImage then begin
      img := Copy(d, parts[k].first, parts[k].len);
      if not EncodeImage(img, parts[k].L, subs[n], w, threads) or (Length(subs[n]) >= parts[k].len) then
        subs[n] := nil;
    end;
    if (subs[n] = nil) and (n > 0) and (subs[n - 1] = nil) and (copyFrom[n - 1] < 0) then Inc(len[n - 1], parts[k].len)
    else begin first[n] := parts[k].first; len[n] := parts[k].len; Inc(n); end;
  end;
  images := 0;
  o.Init;
  o.Put(PARTS_STREAM);
  o.PutVarint(n);
  for j := 0 to n - 1 do
    if copyFrom[j] >= 0 then begin
      o.Put(PART_COPY);
      o.PutVarint(len[j]);
      o.PutVarint(copyFrom[j]);
      Inc(images);
    end else if subs[j] <> nil then begin
      o.Put(PART_IMAGE);
      o.PutVarint(len[j]);
      o.PutVarint(Length(subs[j]));
      o.PutBytes(subs[j], 0, Length(subs[j]));
      Inc(images);
    end else begin
      o.Put(PART_BYTES);
      PutSection(o, d, first[j], len[j]);
    end;
  if images = 0 then begin why := 'no image PRA codes in it'; Exit(False); end;
  s := o.Done;
  { each image came back already, each section too: what is left to check
    is the parts' frame }
  Result := (DecodeParts(s, Length(d), back, threads, @d) = dsOk) and (Length(back) = Length(d))
    and ((Length(d) = 0) or CompareMem(@back[0], @d[0], Length(d)));
  if not Result then begin s := nil; why := 'did not come back the same'; end;
end;

function FileFormat(const d: TBytes): TRasterFormat;
var L: TRasterLayout; st: TParseStatus; parts: TParts; fmt: TRasterFormat;
begin
  st := ParseAny(d, L);
  if SplitFile(d, st, L, parts, fmt) then Exit(fmt);
  if st = psOk then Result := L.format else Result := rfNone;
end;

function EncodeFile(const d: TBytes; out s: TBytes; out why: string; threads: Integer): Boolean;
var L: TRasterLayout; st: TParseStatus; parts: TParts; fmt: TRasterFormat;
begin
  s := nil; why := '';
  st := ParseAny(d, L);
  { several images; if none of them is worth coding as one (a few pixels
    each), the first one with the rest as its tail }
  if SplitFile(d, st, L, parts, fmt) and EncodeParts(d, parts, s, why, threads) then Exit(True);
  if st <> psOk then begin
    if why = '' then why := StatusName(st);
    Exit(False);
  end;
  Result := EncodeImage(d, L, s, why, threads);
end;

function DecodeFile(const s: TBytes; maxOut: Int64; out d: TBytes; threads: Integer): TDecodeStatus;
var h: TStreamHead; rgbe, lines: TBytes; tailFirst: Int64; db: TDecodeBands; k: Integer;
begin
  d := nil;
  if (Length(s) > 0) and (s[0] = PARTS_STREAM) then Exit(DecodeParts(s, maxOut, d, threads));
  Result := ReadStream(s, maxOut, h);
  if Result <> dsOk then Exit;
  SetLength(d, h.L.dataOffset + h.L.dataLength + h.tailLen);
  if h.L.dataOffset > 0 then Move(h.hdr[0], d[0], h.L.dataOffset);
  tailFirst := h.L.dataOffset + h.L.dataLength;
  if h.tailLen > 0 then Move(h.tail[0], d[tailFirst], h.tailLen);
  { the bands, each from its own bytes, into the pixels (or an HDR file's RGBE) }
  db.n := h.bands; db.mode := h.mode;
  if h.L.coding <> CODING_RAW then begin
    db.Lp := RawLayout(h.L);
    rgbe := nil; SetLength(rgbe, db.Lp.dataLength);
    db.out_ := rgbe;
  end else begin
    db.Lp := h.L;
    db.out_ := d;
  end;
  db.bytes := nil; SetLength(db.bytes, db.n);
  for k := 0 to db.n - 1 do db.bytes[k] := Copy(s, h.bandFirst[k], h.bandLen[k]);
  db.failed := nil; SetLength(db.failed, db.n);
  RunJobs(db.n, threads, @DecodeBandJob, @db);
  for k := 0 to db.n - 1 do
    if db.failed[k] then begin d := nil; Exit(dsBadStream); end;
  if h.L.coding = CODING_HDR then begin
    { the scanlines coded again, line by line }
    lines := HdrEncode(db.out_, h.modes, h.L);
    if Length(lines) <> h.L.dataLength then begin d := nil; Exit(dsBadStream); end;
    if Length(lines) > 0 then Move(lines[0], d[h.L.dataOffset], Length(lines));
  end else if SideCoded(h.L) then begin
    { the coded pixels again, from the pixels and the coder's choices }
    if not CodedRebuild(h.hdr, 0, db.out_, h.side, h.L, lines) then begin
      d := nil; Exit(dsBadStream);
    end;
    if Length(lines) > 0 then Move(lines[0], d[h.L.dataOffset], Length(lines));
  end;
  Result := dsOk;
end;

function DecodeStatusName(st: TDecodeStatus): string;
begin
  case st of
    dsOk: Result := 'ok';
    dsEmpty: Result := 'empty stream';
    dsFutureVersion: Result := 'stream from a newer version';
    dsBadStream: Result := 'damaged stream';
  else Result := 'larger than allowed';
  end;
end;

var k: Integer;
initialization
  for k := 0 to High(NODE_H) do NODE_H[k] := Hash2(Cardinal(k) + 1000, $5EED);
  for k := 1 to MAX_COST do INV_SQ[k] := (1 shl 30) div (k * k);
end.
