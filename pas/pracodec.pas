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
  STREAM_VERSION = 1;
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

implementation

uses praarith, pramodel, pralimits, prapnm, prabmp, prahdr, praother, prarle;

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
  { no magic of their own: last, WBMP (which has to fill the file) first }
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
  Result.dataLength := Result.rowBytes * L.height;
end;

{ ---------- run-length codings with their choices coded (prarle) ---------- }

function SideCoded(const L: TRasterLayout): Boolean;
begin
  Result := L.coding in [CODING_TGA_RLE, CODING_SUN_RLE, CODING_PCX];
end;

{ the raw pixels and the coded choices of the coded pixels in d }
function CodedScan(const d: TBytes; const L: TRasterLayout; out raw, side: TBytes): Boolean;
var used: Int64; dec: TBytes; bpp, planes, bpl, lines: Integer; R: TRasterLayout;
begin
  raw := nil; side := nil; Result := False;
  R := RawLayout(L);
  case L.coding of
    CODING_TGA_RLE: Result := TgaRleScan(d, L, PixelBytes(L), raw, side, used) = psOk;
    CODING_SUN_RLE: Result := ByteRleScan(brSun, d, L.dataOffset, R.dataLength, R.rowBytes, raw, side, used) = psOk;
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
var bpp, planes, bpl, lines: Integer; R: TRasterLayout;
begin
  coded := nil; Result := False;
  R := RawLayout(L);
  if Length(raw) <> R.dataLength then Exit;
  case L.coding of
    CODING_TGA_RLE: Result := TgaRleRebuild(raw, side, L, PixelBytes(L), L.dataLength, coded);
    CODING_SUN_RLE: Result := ByteRleRebuild(brSun, raw, side, R.rowBytes, L.dataLength, coded);
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
var bpp, planes, bpl, lines, w, ch, bits: Integer; R: TRasterLayout;
begin
  R := RawLayout(L);
  case L.coding of
    CODING_TGA_RLE: Result := TgaRleFits(L.width, L.height, PixelBytes(L), L.dataLength);
    CODING_SUN_RLE: Result := ByteRleFits(brSun, R.dataLength, L.dataLength);
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
    hdrFirst, tailSrc, pixFirst: SizeInt;
    tailLen: Int64;
    bands: Integer;
    bandFirst, bandLen: array of SizeInt;  { where each band's bytes are in the stream }
  end;

function ReadStream(const s: TBytes; maxOut: Int64; out h: TStreamHead): TDecodeStatus;
var
  src: TSource; hdrLen, run, y, rest, sideLen: Int64; flags, f, ver, m, k: Integer; Lp: TRasterLayout;
begin
  h.modes := nil; h.side := nil; h.mode := MODE_SAMPLES; h.L.Clear;
  h.bands := 0; h.bandFirst := nil; h.bandLen := nil;
  h.hdrFirst := 0; h.tailSrc := 0; h.pixFirst := 0; h.tailLen := 0;
  if Length(s) = 0 then Exit(dsEmpty);
  src.b := s; src.p := 0; src.ok := True;
  ver := src.Get;
  if ver > STREAM_VERSION then Exit(dsFutureVersion);
  if ver <> 1 then Exit(dsBadStream);
  hdrLen := src.GetVarint(MAX_TEXT_HEADER);
  if not src.ok or (hdrLen > Length(s) - src.p) then Exit(dsBadStream);
  h.hdrFirst := src.p; Inc(src.p, hdrLen);
  f := src.Get;
  if (f <= Ord(Low(TRasterFormat))) or (f > Ord(High(TRasterFormat))) then Exit(dsBadStream);
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
  end;
  if ((flags and 8) <> 0) and not (h.L.coding in [CODING_TGA_RLE, CODING_SUN_RLE]) then Exit(dsBadStream);
  if SideCoded(h.L) then begin
    { the coded length within the cap, the image within what that length
      can hold, and the coder's choices }
    h.L.dataLength := src.GetVarint(maxOut);
    sideLen := src.GetVarint(Length(s));
    if not src.ok or (sideLen > Length(s) - src.p) then Exit(dsBadStream);
    if (h.L.width < 1) or (h.L.height < 1) or (h.L.width > MAX_DIMENSION) or (h.L.height > MAX_DIMENSION)
       or (h.L.channels < 1) or (h.L.channels > 4) or not (h.L.bits in [1, 2, 4, 8, 16]) then Exit(dsBadStream);
    if not CodedFits(s, h.hdrFirst, h.L) then Exit(dsBadStream);
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
  if not src.ok or (h.tailLen > Length(s) - src.p) then Exit(dsBadStream);
  h.tailSrc := src.p; Inc(src.p, h.tailLen);
  h.L.bigEndian := (flags and 1) <> 0;
  h.L.isFloat := (flags and 2) <> 0;
  h.L.bottomUp := (flags and 4) <> 0;
  h.L.dataOffset := hdrLen;
  { the limits, before anything is decoded: the pixels have to fit in maxOut }
  if hdrLen + h.tailLen > maxOut then Exit(dsTooBig);
  if h.L.coding <> CODING_RAW then begin
    if h.L.dataLength > maxOut - hdrLen - h.tailLen then Exit(dsTooBig);
  end else
    case SizeRows(h.L, maxOut - hdrLen - h.tailLen) of
      psOk: ;
      psTruncated: Exit(dsTooBig);
    else Exit(dsBadStream);
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
  for k := 0 to h.bands - 2 do h.bandLen[k] := src.GetVarint(High(Int64) shr 1);
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

function EncodeFile(const d: TBytes; out s: TBytes; out why: string; threads: Integer): Boolean;
var
  L, Lp, Lt: TRasterLayout; st: TParseStatus; o: TSink; tailFirst, used, trialRows: Int64; flags: Byte;
  px, rgbe, modes, side, prefix, lines, back: TBytes; y, run, m, k: Integer; at: SizeInt;
  h: TStreamHead; ok: Boolean; eb: TEncodeBands;
begin
  s := nil; why := '';
  st := ParseAny(d, L);
  if st <> psOk then begin why := StatusName(st); Exit(False); end;
  if not Codable(L) then begin why := 'layout not handled by this version'; Exit(False); end;
  { everything before the pixels }
  o.Init;
  o.Put(STREAM_VERSION);
  o.PutVarint(L.dataOffset);
  o.PutBytes(d, 0, L.dataOffset);
  o.Put(Ord(L.format));
  o.PutVarint(L.width); o.PutVarint(L.height); o.PutVarint(L.channels);
  o.Put(L.bits);
  flags := 0;
  if L.bigEndian then flags := flags or 1;
  if L.isFloat then flags := flags or 2;
  if L.bottomUp then flags := flags or 4;
  if L.coding in [CODING_TGA_RLE, CODING_SUN_RLE] then flags := flags or 8;
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
  o.PutVarint(Length(d) - tailFirst);
  o.PutBytes(d, tailFirst, Length(d) - tailFirst);
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
      and SameBytes(s, h.hdrFirst, d, 0, L.dataOffset)
      and SameBytes(s, h.tailSrc, d, tailFirst, h.tailLen)
      and (h.L.coding = L.coding)
      and ((L.coding <> CODING_HDR) or SameBytes(h.modes, 0, modes, 0, L.height))
      and (Length(h.side) = Length(side)) and SameBytes(h.side, 0, side, 0, Length(side));
  end;
  if not ok then begin s := nil; why := 'did not come back the same'; Exit(False); end;
  Result := True;
end;

function DecodeFile(const s: TBytes; maxOut: Int64; out d: TBytes; threads: Integer): TDecodeStatus;
var h: TStreamHead; rgbe, lines: TBytes; tailFirst: Int64; db: TDecodeBands; k: Integer;
begin
  d := nil;
  Result := ReadStream(s, maxOut, h);
  if Result <> dsOk then Exit;
  SetLength(d, h.L.dataOffset + h.L.dataLength + h.tailLen);
  if h.L.dataOffset > 0 then Move(s[h.hdrFirst], d[0], h.L.dataOffset);
  tailFirst := h.L.dataOffset + h.L.dataLength;
  if h.tailLen > 0 then Move(s[h.tailSrc], d[tailFirst], h.tailLen);
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
    if not CodedRebuild(s, h.hdrFirst, db.out_, h.side, h.L, lines) then begin
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
