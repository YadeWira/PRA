{ Layer 2 as one stream's API: a deflate stream (zlib-framed or bare) ->
  the bytes it holds and a recipe, and back to the SAME bits. Nothing here
  knows of PNG: the codec (ppacodec) uses it for each image stream, and PDA
  (documents) will use it for the deflate streams of PDFs and ZIPs.

  A recipe is what the bytes alone do not say:
    - the framing: bare deflate or a zlib header (its 2 bytes as written),
      whether the 4 bytes after the data are their Adler-32, the bits after
      the last block (endPad), and whatever follows (tail; the Adler-32 is
      there when it is not the right one);
    - how the deflate data is made from the bytes, by its kind:
      0 (RECIPE_ZLIB): zlib's parameters (level, strategy, memLevel,
        windowBits), whose choices (ppazlib), written (ppadeflate.Encode),
        are the stream bit for bit;
      1 (RECIPE_ZLIB_FLOW): the same and a flow (ppazlib.TZlibFlow): the
        flushes (sync, full, partial, Z_BLOCK) and parameter changes
        (deflateParams) zlib made along the stream, at positions of the
        bytes, and which zlib's flushes they were (since 1.2.5.3, up to
        1.2.5.2, up to 1.2.3.3);
      2 (RECIPE_MINIZ): a known encoder, exactly: miniz (ppaminiz: its
        flags and build);
      3 (RECIPE_CORR): a zlib-like predictor's parameters and the
        corrections (ppacorr) that make its choices the stream's: every
        stream ppadeflate reads has one.
  doc/PREFLATE.md has the kinds, the fields, a recipe's bytes (RecipeBytes,
  versioned; codec stream version 3 holds them) and the rule that freezes
  them (tests/recipes: the golden vectors). A kind-0 recipe is written in
  codec stream version 2 exactly as it always wrote an image stream's
  (RecipeBytesV2); version 2 holds no other kind.

  Analyze verifies: it gives a recipe only when Rebuild of it gives the
  stream back, bit for bit. Rebuild checks the recipe first and is False
  on one it cannot use; it raises only when memory runs out. }
unit ppapreflate;

{$I ppa.inc}
{$ifopt R-}{$fatal ppapreflate: range checks ($R+) are mandatory}{$endif}
{$ifopt Q-}{$fatal ppapreflate: overflow checks ($Q+) are mandatory}{$endif}

interface

uses SysUtils, ppadeflate, ppazlib, ppacorr, ppaminiz;

const
  { the recipe kinds: 0, zlib's parameters give the stream exactly; 1,
    zlib's parameters and its flushes and parameter changes; 2, another
    known encoder exactly (miniz); 3, a zlib-like predictor and the
    corrections that make it the stream (ppacorr: any stream) }
  RECIPE_ZLIB = 0;
  RECIPE_ZLIB_FLOW = 1;
  RECIPE_ENCODER = 2;
  RECIPE_CORR = 3;
  { kind 2's encoders: miniz's tdefl (ppaminiz) }
  ENC_MINIZ = 1;
  RECIPE_KIND_LAST = RECIPE_CORR;
  { the version of RecipeBytes' format (doc/PREFLATE.md) }
  RECIPE_FORMAT = 2;

type
  { how the stream is framed: bare deflate, zlib, or zlib when its first two
    bytes are a zlib header deflate can follow (ppadeflate.IsZlibHeader),
    bare otherwise }
  TDeflFraming = (dfRaw, dfZlib, dfAuto);

  { what Analyze made of a stream: a recipe; not a deflate stream (or more
    than maxPlain bytes); a deflate stream no recipe kind gives back }
  TDeflStatus = (dsOk, dsNotDeflate, dsNotTaken);

  TDeflRecipe = record
    kind: Integer;                   { RECIPE_ZLIB, RECIPE_ZLIB_FLOW, RECIPE_ENCODER, RECIPE_CORR }
    prm: TZlibParams;                { zlib's parameters (kind 1: at the start; kind 3: none) }
    flow: TZlibFlow;                 { kind 1: its flushes and parameter changes }
    encoder: Integer;                { kind 2: ENC_MINIZ }
    mz: TMinizParams;                { kind 2, miniz: its flags and build }
    pred: TPredParams;               { kind 3: the predictor's parameters }
    corr: TBytes;                    { kind 3: the corrections (ppacorr), coded }
    { the framing, as ppadeflate.TZStream has it }
    raw: Boolean;
    adlerOk: Boolean;
    header: array[0..1] of Byte;
    endPad: Byte;
    tail: TBytes;
  end;

  { why ReadRecipeV2 or ReadRecipe refused: cut short or a field out of
    range; zlib parameters out of range }
  TRecipeRead = (rrOk, rrBad, rrBadParams);

{ The stream a -> its blocks, tokens and bytes (ppadeflate.Decode), framed
  as framing says. maxPlain caps the bytes it may hold. Never raises on any
  input. }
function Parse(const a: TBytes; framing: TDeflFraming; maxPlain: SizeInt; out z: TZStream): TZResult;

{ The recipe of a stream already parsed (z, from a), of a kind up to
  maxKind: dsOk when one gives a back bit for bit (checked), dsNotTaken
  otherwise. Kind 0 is looked for first, as codec stream version 2 does.
  threads: kind 3's parameter search and the rebuilds' (the same recipe
  with any). }
function FindRecipe(const a: TBytes; const z: TZStream; out recipe: TDeflRecipe;
  maxKind: Integer = RECIPE_KIND_LAST; threads: Integer = 1): TDeflStatus;

{ Parse and FindRecipe: a -> the bytes it holds and its recipe. }
function Analyze(const a: TBytes; framing: TDeflFraming; maxPlain: SizeInt; out plain: TBytes;
  out recipe: TDeflRecipe; maxKind: Integer = RECIPE_KIND_LAST): TDeflStatus;

{ Whether a recipe is one Rebuild can use: a known kind, its parameters in
  range (and a flow's variant, events and their parameters; where they
  are, against the bytes, Rebuild checks). }
function RecipeValid(const recipe: TDeflRecipe): Boolean;

{ The bytes and their recipe -> the stream. threads: one stream's rebuild
  cut into segments on as many (ppazlib's parallel rebuild, kind 0 only;
  the same bits whatever the threads). False, and no stream, on a recipe
  RecipeValid refuses or whose flow does not fit the bytes. }
function Rebuild(const plain: TBytes; const recipe: TDeflRecipe; out stream: TBytes; threads: Integer = 1): Boolean;

{ A kind-0 recipe as codec stream version 2 writes an image stream's
  deflate part: level, strategy, memLevel, windowBits, a byte of flags (1:
  raw, 2: adlerOk), the 2 header bytes, endPad, the tail's length (a
  varint, 7 bits a byte, low first) and the tail. Raises on another kind. }
function RecipeBytesV2(const recipe: TDeflRecipe): TBytes;
{ The same read back from b at pos (moved past it). maxTail caps the tail's
  length. Never raises; on rrBad or rrBadParams, pos and recipe are left
  anywhere. }
function ReadRecipeV2(const b: TBytes; var pos: SizeInt; maxTail: QWord; out recipe: TDeflRecipe): TRecipeRead;

{ Any recipe in RecipeBytes' format (RECIPE_FORMAT, doc/PREFLATE.md), and
  read back: plainLen is the length of the bytes it is for (a flow's
  events are checked against it before anything is kept), maxTail caps the
  tail. ReadRecipe never raises; RecipeBytes raises on a recipe
  RecipeValid refuses or a flow out of order. Codec stream version 3 holds
  it: a format a published stream holds never changes what it gives. }
function RecipeBytes(const recipe: TDeflRecipe): TBytes;
function ReadRecipe(const b: TBytes; var pos: SizeInt; plainLen: SizeInt; maxTail: QWord;
  out recipe: TDeflRecipe): TRecipeRead;

{ The flow search (kind 1) alone, for the tools: zlib's parameters and a
  flow whose choices are z's blocks and tokens, the choices in choices }
function FindZlibFlow(const z: TZStream; out prm: TZlibParams; out flow: TZlibFlow; out choices: TZStream): Boolean;

implementation

function Parse(const a: TBytes; framing: TDeflFraming; maxPlain: SizeInt; out z: TZStream): TZResult;
var raw: Boolean;
begin
  case framing of
    dfRaw: raw := True;
    dfZlib: raw := False;
  else raw := not IsZlibHeader(a);
  end;
  Result := ppadeflate.Decode(a, raw, maxPlain, z);
end;

{ the framing of z into r }
procedure TakeFraming(const z: TZStream; var r: TDeflRecipe);
begin
  r.raw := z.raw; r.adlerOk := z.adlerOk; r.header := z.header;
  r.endPad := z.endPad; r.tail := z.tail;
end;

{ the recipe's framing onto the choices e }
procedure PutFraming(const r: TDeflRecipe; var e: TZStream);
begin
  e.raw := r.raw; e.adlerOk := r.adlerOk; e.header := r.header;
  e.endPad := r.endPad; e.tail := r.tail;
end;

function SameBytes(const a, b: TBytes): Boolean;
begin
  Result := (Length(a) = Length(b)) and (Length(a) > 0) and CompareMem(@a[0], @b[0], Length(a));
end;

{ ---------------------------------------------------------------- the flow search }

const
  MK_DATA = 0; MK_STORED = 1; MK_FIXED = 2;   { a block: data, or a flush's empty stored or fixed block }
  FLOW_TOP = 3;          { the candidates the fixes are tried on }
  FLOW_MAX_FIXES = 96;   { fixes kept on each, at most }
  { a fix is kept when it takes the run this many bytes further, or past
    one more of the stream's blocks, or to the end: one that only matches a
    few more tokens is chance }
  MEND_GAIN = 256;
  { the mending's work, at most: runs, and bytes compared (a few times the
    stream's): the candidate that came furthest, the others less (the
    corpora's mended streams, 14/11/2026: nearly all the first
    candidate's, none past 16 times a large stream (46 MB) or 2.5 MB on a
    small one) }
  MEND_RUNS = 3000;
  MEND_WORK_TIMES = 16;
  MEND_WORK_MORE = 8 shl 20;
  MEND_WORK_TIMES_NEXT = 4;
  MEND_WORK_MORE_NEXT = 2 shl 20;
  SCREEN_TOKENS = 1 shl 16;   { the first pass compares this many tokens (the blocks that hold them) }
  SCREEN_PLAIN = 1 shl 20;    { or bytes }

{ The search for kind 1. The flushes are read off the blocks: a non-final
  empty stored block is a sync or full flush (zlib never stores nothing
  on its own), a non-final empty fixed one a partial flush, a block that
  ends with fewer symbols than memLevel's buffer holds and no marker after
  it a Z_BLOCK (or deflateParams' flush); which of sync and full (does a
  match after it reach back over it?) and, for zlibs before 1.2.5.3, which
  empty block is which (the bits written so far say when _tr_align wrote
  a second one). Every zlib parameter set is then tried with the flow its
  memLevel gives, first on the stream's first blocks (a screen), and in
  full on those that pass. If none gives the stream, the ones that came
  furthest are mended where they part from it, one change at a time, kept
  when it takes them further: a stored block that ended at a Z_BLOCK, a
  sync that was a full flush or the other way, the other zlib versions'
  flushes, and new parameters (deflateParams) at the last flush before it.
  deflateParams without a flush of its own (the same loop and strategy,
  another level) is followed by the rebuild but not looked for here. }
function FindZlibFlow(const z: TZStream; out prm: TZlibParams; out flow: TZlibFlow; out choices: TZStream): Boolean;
type
  TCand = record prm: TZlibParams; prog: SizeInt; noTooFar: Boolean; end;
  { what the fixes change: the zlib version, which syncs are full, Z_BLOCKs
    added, parameter changes added }
  TFixes = record
    variant: Integer;
    full: array of Boolean;              { by block: a stored marker taken as Z_FULL_FLUSH }
    blockAt: array of SizeInt;           { Z_BLOCK added at these positions }
    params: array of TZlibEvent;         { ZE_PARAMS added (after the flushes at their position) }
  end;
var
  n, nb, i, k, t, q: SizeInt;
  bStart, bEnd: array of SizeInt;
  mk: array of Byte;
  crossed: array of Boolean;
  bitEnd: array of Int64;                { the bit each block ends at }
  eob: array of Integer;                 { each block's end-of-block code length (8 for stored, as zlib keeps it) }
  base: TFixes;
  screen: TZStream;
  top: array[0..FLOW_TOP - 1] of TCand;
  nTop: Integer;
  e: TZStream;
  good: SizeInt;
  runs, work: Int64;
  scratch: TZlibScratch;   { the C loop's tables, for all the runs }

  function TokLen(t: SizeInt): SizeInt; inline;
  begin
    Result := z.tokLen[t];
    if Result = 0 then Result := 1 else if Result = LEN_258_AS_284 then Result := 258;
  end;

  function SymEnd(ml: Integer): SizeInt;
  begin
    Result := (SizeInt(1) shl (ml + 6)) - 1;
  end;

  procedure Add(var f: TZlibFlow; pos: SizeInt; kind: Byte; lv: Byte = 0; sg: Byte = 0);
  var j: SizeInt;
  begin
    j := Length(f.events);
    SetLength(f.events, j + 1);
    f.events[j].pos := pos; f.events[j].kind := kind; f.events[j].level := lv; f.events[j].strategy := sg;
  end;

  { the flow memLevel ml and the fixes give: the flushes as the blocks show
    them, as that zlib makes them; then the fixes' Z_BLOCKs (where no flush
    is) and parameter changes (after the flushes at their position) }
  function Build(ml: Integer; const fx: TFixes): TZlibFlow;
  var b, j, c, x, y: SizeInt; needFB, dbl: Boolean; st: TZlibFlow;

    function FlushKind(blk: SizeInt): Byte;
    begin
      if fx.full[blk] then Result := ZE_FULL else Result := ZE_SYNC;
    end;

  begin
    st := Default(TZlibFlow);
    b := 0;
    while b < nb - 1 do begin
      if mk[b] = MK_DATA then begin
        { a block ended by a flush: the marker after it says which; else a
          Z_BLOCK where the buffer was not full (a stored block's symbols
          are not known: the fixes add those) }
        if (mk[b + 1] = MK_DATA) and (z.blocks[b].btype <> btStored) and (z.blocks[b].nTokens <> SymEnd(ml)) then
          Add(st, bEnd[b], ZE_BLOCK);
        Inc(b); Continue;
      end;
      { a run of markers at one position }
      j := b;
      while (j < nb - 1) and (mk[j] <> MK_DATA) do Inc(j);
      if (fx.variant and ZV_VERSION) = ZV_NEW then begin
        for c := b to j - 1 do
          if mk[c] = MK_STORED then Add(st, bStart[c], FlushKind(c)) else Add(st, bStart[c], ZE_PARTIAL);
      end else begin
        { each flush: the block it ends (an empty fixed one when there is
          nothing to end), then its marker; _tr_align's second block when
          the bits say so (1 + last_eob_len + 10 - bi_valid < 9) }
        c := b;
        needFB := (b = 0) or ((z.blocks[b - 1].btype <> btStored) and (z.blocks[b - 1].nTokens = SymEnd(ml)));
        while c < j do begin
          if needFB then begin
            if mk[c] <> MK_FIXED then Break;
            Inc(c);
            if c = j then begin Add(st, bStart[b], ZE_BLOCK); Break; end;
          end;
          if mk[c] = MK_STORED then begin Add(st, bStart[c], FlushKind(c)); Inc(c); end
          else begin
            Add(st, bStart[c], ZE_PARTIAL);
            dbl := (c + 1 < j) and (mk[c + 1] = MK_FIXED) and (1 + eob[c - 1] + 10 - (bitEnd[c] and 7) < 9);
            Inc(c);
            if dbl then Inc(c);
          end;
          needFB := True;
        end;
      end;
      b := j;
    end;
    if (Length(fx.blockAt) = 0) and (Length(fx.params) = 0) then begin
      st.variant := fx.variant;
      Exit(st);
    end;
    { merged by position: the flushes, a Z_BLOCK added where there is none,
      the parameter changes last }
    Result := Default(TZlibFlow);
    Result.variant := fx.variant;
    c := 0; x := 0; y := 0;
    while (c <= High(st.events)) or (x <= High(fx.blockAt)) or (y <= High(fx.params)) do begin
      b := High(SizeInt);
      if c <= High(st.events) then b := st.events[c].pos;
      if (x <= High(fx.blockAt)) and (fx.blockAt[x] < b) then b := fx.blockAt[x];
      if (y <= High(fx.params)) and (fx.params[y].pos < b) then b := fx.params[y].pos;
      if (c <= High(st.events)) and (st.events[c].pos = b) then begin
        while (c <= High(st.events)) and (st.events[c].pos = b) do begin
          Add(Result, b, st.events[c].kind); Inc(c);
        end;
        while (x <= High(fx.blockAt)) and (fx.blockAt[x] = b) do Inc(x);
      end else
        while (x <= High(fx.blockAt)) and (fx.blockAt[x] = b) do begin
          if (Length(Result.events) = 0) or (Result.events[High(Result.events)].pos <> b) then Add(Result, b, ZE_BLOCK);
          Inc(x);
        end;
      while (y <= High(fx.params)) and (fx.params[y].pos = b) do begin
        Add(Result, b, ZE_PARAMS, fx.params[y].level, fx.params[y].strategy); Inc(y);
      end;
    end;
  end;

  { how far zlib's choices e (the first good blocks the same) follow z: the
    plain position of the first token or block that differs }
  function Progress(const e: TZStream; good: SizeInt): SizeInt;
  var t, tEnd: SizeInt;
  begin
    if good >= nb then Exit(n);
    Result := bStart[good];
    if z.blocks[good].btype = btStored then Exit;
    t := z.blocks[good].firstToken; tEnd := t + z.blocks[good].nTokens;
    while (t < tEnd) and (t < Length(e.tokLen)) and (e.tokLen[t] = z.tokLen[t]) and (e.tokVal[t] = z.tokVal[t]) do begin
      Inc(Result, TokLen(t)); Inc(t);
    end;
  end;

  { one try against r (z, or its screen): True when every block is the
    same; else how far it went }
  function TryFlow(const p: TZlibParams; const f: TZlibFlow; const r: TZStream; out prog: SizeInt): Boolean;
  begin
    prog := 0;
    if not ZlibFlowValid(f, p, n) then Exit(False);
    Inc(runs);
    Result := ZlibChoicesFlow(z.plain, p, f, @r, e, good, 1, @scratch);
    if not Result then prog := Progress(e, good);
    if Result then Inc(work, n) else Inc(work, prog);
  end;

  { whether z's token at plain position q is a match of 3 further than
    zlib's TOO_FAR (4096) }
  function FarThreeAt(q: SizeInt): Boolean;
  var b, t, x: SizeInt;
  begin
    Result := False;
    b := 0;
    while (b < nb) and (bEnd[b] <= q) do Inc(b);
    if (b >= nb) or (z.blocks[b].btype = btStored) then Exit;
    x := bStart[b]; t := z.blocks[b].firstToken;
    while (t < z.blocks[b].firstToken + z.blocks[b].nTokens) and (x < q) do begin Inc(x, TokLen(t)); Inc(t); end;
    Result := (x = q) and (t < z.blocks[b].firstToken + z.blocks[b].nTokens) and (z.tokLen[t] = 3) and
      (z.tokVal[t] > 4096);
  end;

  procedure Keep(const p: TZlibParams; prog: SizeInt; noTooFar: Boolean);
  var j, x: Integer;
  begin
    j := nTop;
    while (j > 0) and (top[j - 1].prog < prog) do Dec(j);
    if j >= FLOW_TOP then Exit;
    if nTop < FLOW_TOP then Inc(nTop);
    for x := nTop - 1 downto j + 1 do top[x] := top[x - 1];
    top[j].prm := p; top[j].prog := prog; top[j].noTooFar := noTooFar;
  end;

  function CopyFixes(const a: TFixes): TFixes;
  begin
    Result.variant := a.variant;
    Result.full := Copy(a.full, 0, Length(a.full));
    Result.blockAt := Copy(a.blockAt, 0, Length(a.blockAt));
    Result.params := Copy(a.params, 0, Length(a.params));
  end;

  { the parameters in force at position p by the fixes' changes }
  procedure InForce(const p0: TZlibParams; const fx: TFixes; p: SizeInt; out lv, sg: Integer);
  var j: SizeInt;
  begin
    lv := p0.level; sg := p0.strategy;
    for j := 0 to High(fx.params) do
      if fx.params[j].pos <= p then begin lv := fx.params[j].level; sg := fx.params[j].strategy; end;
  end;

  { mend candidate c where it parts from z, one change at a time }
  function Mend(const c: TCand; first: Boolean): Boolean;
  var fx, f2, best: TFixes; p: TZlibParams; prog, pr, bestProg, last, lastS, at, g0, bestGood: SizeInt;
      it, v, lv, sg, l0, s0: Integer; f: TZlibFlow; j, g: SizeInt; found: Boolean;
      runs0, work0: Int64;

    function Over: Boolean;
    begin
      Result := runs - runs0 > MEND_RUNS;
      if first then Result := Result or (work - work0 > MEND_WORK_TIMES * Int64(n) + MEND_WORK_MORE)
      else Result := Result or (work - work0 > MEND_WORK_TIMES_NEXT * Int64(n) + MEND_WORK_MORE_NEXT);
    end;

    function Further: Boolean;
    begin
      Result := (bestProg > prog) and ((bestProg > prog + MEND_GAIN) or (bestProg >= n) or (bestGood > g0));
    end;

    { a parameter change added at position at (one at a position: it
      replaces the one there) }
    procedure SetParams(var f2: TFixes; at: SizeInt; lv, sg: Integer);
    var j: SizeInt;
    begin
      j := 0;
      while (j <= High(f2.params)) and (f2.params[j].pos <> at) do Inc(j);
      if j > High(f2.params) then begin
        j := 0;
        while (j <= High(f2.params)) and (f2.params[j].pos < at) do Inc(j);
        Insert(Default(TZlibEvent), f2.params, j);
      end;
      f2.params[j].pos := at; f2.params[j].kind := ZE_PARAMS;
      f2.params[j].level := lv; f2.params[j].strategy := sg;
    end;

    { try fixes f2: True when it gives z (flow and prm set); else whether
      it goes further than prog (best kept) }
    function TryFix(const f2: TFixes): Boolean;
    var ff: TZlibFlow;
    begin
      ff := Build(p.memLevel, f2);
      Result := TryFlow(p, ff, z, pr);
      if Result then begin flow := ff; prm := p; choices := e; Exit; end;
      if pr > bestProg then begin bestProg := pr; bestGood := good; best := CopyFixes(f2); end;
    end;

  begin
    Result := False;
    p := c.prm;
    fx := CopyFixes(base);
    if c.noTooFar then fx.variant := fx.variant or ZV_NO_TOO_FAR;
    f := Build(p.memLevel, fx);
    runs0 := runs; work0 := work;
    if TryFlow(p, f, z, prog) then begin flow := f; prm := p; choices := e; Exit(True); end;
    for it := 1 to FLOW_MAX_FIXES do begin
      if Over then Exit;
      g := good; g0 := good; bestGood := good;
      bestProg := prog;
      found := False;
      { a block that ends where z's does not and has no event there: a
        Z_BLOCK (a stored block's symbols are not known) }
      if (g < nb - 1) and (mk[g] = MK_DATA) and (mk[g + 1] = MK_DATA) then begin
        last := -1;
        for j := 0 to High(f.events) do if f.events[j].pos = bEnd[g] then last := j;
        if last < 0 then begin
          f2 := CopyFixes(fx);
          j := 0;
          while (j <= High(f2.blockAt)) and (f2.blockAt[j] < bEnd[g]) do Inc(j);
          Insert(bEnd[g], f2.blockAt, j);
          if TryFix(f2) then Exit(True);
          found := Further;
        end;
      end;
      { zlib built with TOO_FAR = 32767 (pngcrush's): deflate_slow keeps
        a match of 3 however far; where they part at one, the other }
      if not found and (prog < n) and (ZlibFunc(p.level, p.strategy) = FN_SLOW) then begin
        f2 := CopyFixes(fx); f2.variant := fx.variant xor ZV_NO_TOO_FAR;
        if TryFix(f2) then Exit(True);
        found := Further;
      end;
      { the last stored marker before where they part: the other of sync
        and full (one a match reaches back over is a sync) }
      if not found then begin
        lastS := -1;
        for j := 0 to nb - 2 do if (mk[j] = MK_STORED) and (bStart[j] <= prog) and not crossed[j] then lastS := j;
        if lastS >= 0 then
          for v := ZV_NEW to ZV_LAST do begin
            { each zlib's: which it was can also change what full means }
            f2 := CopyFixes(fx);
            f2.full[lastS] := not f2.full[lastS];
            f2.variant := v or (fx.variant and ZV_NO_TOO_FAR);
            if TryFix(f2) then Exit(True);
          end;
        found := Further;
      end;
      { the other zlibs' flushes }
      if not found and (Length(f.events) > 0) then begin
        for v := ZV_NEW to ZV_LAST do
          if v <> fx.variant and ZV_VERSION then begin
            f2 := CopyFixes(fx); f2.variant := v or (fx.variant and ZV_NO_TOO_FAR);
            if TryFix(f2) then Exit(True);
          end;
        found := Further;
      end;
      { new parameters at the last flush before where they part (the one
        that goes furthest), with each zlib's flushes (a change and the
        version can both be needed to go further) }
      if not found then begin
        last := -1;
        for j := 0 to High(f.events) do
          if (f.events[j].kind <> ZE_PARAMS) and (f.events[j].pos <= prog) then last := f.events[j].pos;
        if last >= 0 then begin
          InForce(p, fx, last, l0, s0);
          for v := ZV_NEW to ZV_LAST do
          for sg := Z_DEFAULT_STRATEGY to Z_FIXED do
            for lv := 1 to 9 do begin
              if (lv = l0) and (sg = s0) then Continue;
              if (sg in [Z_HUFFMAN_ONLY, Z_RLE]) and (lv <> 1) then Continue;
              if (sg = Z_FILTERED) and (lv <= 3) then Continue;
              f2 := CopyFixes(fx);
              f2.variant := v or (fx.variant and ZV_NO_TOO_FAR);
              SetParams(f2, last, lv, sg);
              if TryFix(f2) then Exit(True);
              if Over then Exit;
            end;
          found := Further;
        end;
      end;
      { deflateParams without a flush (the same loop: another level, or
        strategy): at the top of the loop where they part, or a byte or
        two either side (zlib changes at the first top past its input
        less MIN_LOOKAHEAD; deflate_slow's chains are the same at any
        level, so where they part is as good as where it changed) }
      if not found and (prog > 0) and (prog < n) then begin
        InForce(p, fx, prog, l0, s0);
        if ZlibFunc(l0, s0) >= FN_FAST then
          for at := prog - 2 to prog + 2 do begin
            if (at <= 0) or (at > n) then Continue;
            for lv := 1 to 9 do
              for sg in [Z_DEFAULT_STRATEGY, Z_FILTERED, Z_FIXED] do begin
                if (lv = l0) and (sg = s0) then Continue;
                if ZlibFunc(lv, sg) <> ZlibFunc(l0, s0) then Continue;
                if (sg = Z_FILTERED) and (lv <= 3) then Continue;
                f2 := CopyFixes(fx);
                SetParams(f2, at, lv, sg);
                if TryFix(f2) then Exit(True);
                if Over then Exit;
              end;
          end;
        found := Further;
      end;
      if not found then Exit;
      fx := best; prog := bestProg;
      f := Build(p.memLevel, fx);
      TryFlow(p, f, z, pr);   { good, for the next round }
    end;
  end;

var
  wbs, mls, lvs: array of Integer;
  stOrder: array[0..4] of Integer = (Z_DEFAULT_STRATEGY, Z_FILTERED, Z_FIXED, Z_HUFFMAN_ONLY, Z_RLE);
  flows: array[1..9] of TZlibFlow;
  ftf: TZlibFlow;
  wi, mi, si, li, hw, lvMin, lvMax, firstMl, best, cnt: Integer;
  p: TZlibParams;
  prog, prog2, coverT: SizeInt;
  equivDone, ok: Boolean;
  bits: Int64;
begin
  Result := False;
  prm := Default(TZlibParams); flow := Default(TZlibFlow); choices := Default(TZStream);
  n := Length(z.plain); nb := Length(z.blocks);
  if nb = 0 then Exit;
  { the blocks: where each starts and ends in the bytes, which are
    markers, the bits each ends at and its end-of-block code's length }
  SetLength(bStart, nb); SetLength(bEnd, nb); SetLength(mk, nb); SetLength(crossed, nb);
  SetLength(bitEnd, nb); SetLength(eob, nb);
  q := 0; bits := 0;
  for i := 0 to nb - 1 do
    with z.blocks[i] do begin
      bStart[i] := q;
      if btype = btStored then Inc(q, storedLen)
      else for t := firstToken to firstToken + nTokens - 1 do Inc(q, TokLen(t));
      bEnd[i] := q;
      mk[i] := MK_DATA;
      if not final and (btype = btStored) and (storedLen = 0) then mk[i] := MK_STORED;
      if not final and (btype = btFixed) and (nTokens = 0) then mk[i] := MK_FIXED;
      Inc(bits, BlockBits(z, z.blocks[i], bits));
      bitEnd[i] := bits;
      case btype of
        btStored: eob[i] := 8;
        btFixed: eob[i] := 7;
      else eob[i] := litLen[256];
      end;
    end;
  if q <> n then Exit;
  { the stored markers a later match reaches back over (a sync, not a full
    flush); those within 64 markers of the match }
  k := -1;   { the last stored marker at or before the token }
  q := 0;
  for i := 0 to nb - 1 do begin
    if mk[i] = MK_STORED then k := i;
    if z.blocks[i].btype = btStored then begin Inc(q, z.blocks[i].storedLen); Continue; end;
    for t := z.blocks[i].firstToken to z.blocks[i].firstToken + z.blocks[i].nTokens - 1 do begin
      if (z.tokLen[t] <> 0) and (k >= 0) then begin
        cnt := 0;
        hw := k;
        while (hw >= 0) and (cnt < 64) do begin
          if (mk[hw] = MK_STORED) then begin
            if q - z.tokVal[t] >= bStart[hw] then Break;
            crossed[hw] := True; Inc(cnt);
          end;
          Dec(hw);
        end;
      end;
      Inc(q, TokLen(t));
    end;
  end;
  { a stored marker no match reaches over: full when the bytes after it
    (to the next marker) are many and hold matches, else sync }
  base := Default(TFixes);
  SetLength(base.full, nb);
  for i := 0 to nb - 2 do
    if (mk[i] = MK_STORED) and not crossed[i] then begin
      k := i + 1; cnt := 0;
      while (k < nb) and (mk[k] = MK_DATA) do begin
        if z.blocks[k].btype <> btStored then
          for t := z.blocks[k].firstToken to z.blocks[k].firstToken + z.blocks[k].nTokens - 1 do
            if z.tokLen[t] <> 0 then begin Inc(cnt); Break; end;
        Inc(k);
      end;
      if k > nb - 1 then k := nb - 1;
      base.full[i] := (cnt > 0) and (bEnd[k] - bEnd[i] >= 4096);
    end;
  { the zlib version: two empty fixed blocks in a row, or one before an
    empty stored block, are a zlib before 1.2.5.3 (it ends an empty block at
    a flush); else the newer first }
  base.variant := ZV_NEW;
  for i := 0 to nb - 3 do
    if (mk[i] = MK_FIXED) and (mk[i + 1] <> MK_DATA) then base.variant := ZV_125;

  { the screen: the first blocks, up to SCREEN_TOKENS tokens or
    SCREEN_PLAIN bytes }
  k := 0;
  while (k < nb) and ((k = 0) or ((z.blocks[k - 1].firstToken + z.blocks[k - 1].nTokens < SCREEN_TOKENS) and
        (bEnd[k - 1] < SCREEN_PLAIN))) do Inc(k);
  screen := Default(TZStream);
  if k >= nb then screen := z
  else begin
    screen.raw := z.raw; screen.header := z.header; screen.plain := z.plain;
    screen.blocks := Copy(z.blocks, 0, k);
    coverT := 0;
    for i := 0 to k - 1 do
      if z.blocks[i].btype <> btStored then coverT := z.blocks[i].firstToken + z.blocks[i].nTokens;
    screen.tokLen := Copy(z.tokLen, 0, coverT); screen.tokVal := Copy(z.tokVal, 0, coverT);
  end;

  { the order: the window the header says first (bare: 15), then the rest
    down to 9, one of those whose window holds the whole input (they all
    choose the same); memLevel by the full blocks' symbols first; levels
    the header's FLEVEL names first }
  wbs := nil;
  if z.raw then hw := 15 else begin hw := (z.header[0] shr 4) + 8; if hw < 9 then hw := 9; end;
  SetLength(wbs, 1); wbs[0] := hw;
  for wi := 15 downto 9 do if wi <> hw then begin SetLength(wbs, Length(wbs) + 1); wbs[High(wbs)] := wi; end;
  firstMl := 8; best := 0;
  for mi := 1 to 9 do begin
    cnt := 0;
    for i := 0 to nb - 2 do
      if (mk[i] = MK_DATA) and (z.blocks[i].btype <> btStored) and (z.blocks[i].nTokens = SymEnd(mi)) then Inc(cnt);
    if cnt > best then begin best := cnt; firstMl := mi; end;
  end;
  mls := nil; SetLength(mls, 1); mls[0] := firstMl;
  for mi in [8, 9, 7, 6, 5, 4, 3, 2, 1] do if mi <> firstMl then begin SetLength(mls, Length(mls) + 1); mls[High(mls)] := mi; end;
  lvMin := 1; lvMax := 9;
  if not z.raw then
    case z.header[1] shr 6 of
      0: begin lvMin := 1; lvMax := 1; end;
      1: begin lvMin := 2; lvMax := 5; end;
      2: begin lvMin := 6; lvMax := 6; end;
    else begin lvMin := 7; lvMax := 9; end;
    end;
  lvs := nil;
  for li := lvMin to lvMax do begin SetLength(lvs, Length(lvs) + 1); lvs[High(lvs)] := li; end;
  for li in [6, 9, 1, 5, 4, 3, 2, 7, 8] do
    if (li < lvMin) or (li > lvMax) then begin SetLength(lvs, Length(lvs) + 1); lvs[High(lvs)] := li; end;
  for mi := 1 to 9 do flows[mi] := Build(mi, base);

  nTop := 0; runs := 0; work := 0;
  equivDone := False;
  for wi := 0 to High(wbs) do begin
    { a window that holds the whole input: the same choices as any other
      that does (no match is too far, nothing slides) }
    if (SizeInt(1) shl wbs[wi]) - 262 >= n then begin
      if equivDone then Continue;
      equivDone := True;
    end;
    for mi := 0 to High(mls) do
      for si := 0 to 4 do
        for li := 0 to High(lvs) do begin
          p.level := lvs[li]; p.strategy := stOrder[si]; p.memLevel := mls[mi]; p.wbits := wbs[wi];
          if (p.strategy in [Z_HUFFMAN_ONLY, Z_RLE]) and (li > 0) then Continue;
          if (p.strategy = Z_FILTERED) and (p.level <= 3) then Continue;
          ftf := flows[p.memLevel];
          ok := TryFlow(p, ftf, screen, prog);
          { parted at a match of 3 further than TOO_FAR: zlib built with
            TOO_FAR = 32767 (pngcrush's) }
          if not ok and (ZlibFunc(p.level, p.strategy) = FN_SLOW) and FarThreeAt(prog) then begin
            ftf.variant := ftf.variant xor ZV_NO_TOO_FAR;
            ok := TryFlow(p, ftf, screen, prog2);
            { kept only where it goes further (a later deflate_fast keeps
              far matches of 3 too) }
            if ok or (prog2 > prog) then prog := prog2
            else begin
              ftf := flows[p.memLevel];
              ok := TryFlow(p, ftf, screen, prog);
            end;
          end;
          if ok and (k >= nb) then begin
            flow := ftf; prm := p; choices := e; Exit(True);
          end;
          { the screen's blocks all the same: the whole stream }
          if (k < nb) and (good >= k) then begin
            { the whole stream, for those the screen passed }
            ok := TryFlow(p, ftf, z, prog);
            if ok then begin flow := ftf; prm := p; choices := e; Exit(True); end;
          end;
          Keep(p, prog, (ftf.variant and ZV_NO_TOO_FAR) <> 0);
        end;
  end;
  { mended where they part }
  for i := 0 to nTop - 1 do
    if Mend(top[i], i = 0) then Exit(True);
end;

{ ---------------------------------------------------------------- recipes }

function FindRecipe(const a: TBytes; const z: TZStream; out recipe: TDeflRecipe; maxKind: Integer;
  threads: Integer): TDeflStatus;
var e: TZStream; back: TBytes; i: SizeInt; markers: Boolean; memo: TLongMemo;
begin
  Result := dsNotTaken;
  recipe := Default(TDeflRecipe);
  recipe.kind := RECIPE_ZLIB;
  TakeFraming(z, recipe);
  { kind 0, as codec stream version 2 has always looked for it; not where a
    flush's marker shows it cannot be (zlib alone never ends a block
    empty before the last) }
  markers := False;
  if maxKind >= RECIPE_ZLIB_FLOW then
    for i := 0 to High(z.blocks) - 1 do
      with z.blocks[i] do
        if ((btype = btStored) and (storedLen = 0)) or ((btype = btFixed) and (nTokens = 0)) then markers := True;
  { the choices zlib makes with them (all of them: the search compared
    every block), written, must be the stream }
  if not markers and FindZlibParams(z, recipe.prm, e) then begin
    PutFraming(recipe, e);
    back := Encode(e);
    if SameBytes(back, a) then Exit(dsOk);
  end;
  if maxKind < RECIPE_ZLIB_FLOW then Exit;
  { kind 2 before kind 1: its search is quick, kind 1's long where it
    fails, and no stream is both (miniz makes no flushes, and a stream zlib
    makes without one is kind 0) }
  if (maxKind >= RECIPE_ENCODER) and not markers then begin
    recipe.kind := RECIPE_ENCODER;
    recipe.encoder := ENC_MINIZ;
    recipe.prm := Default(TZlibParams);
    if FindMinizParams(z, recipe.mz, e) then begin
      PutFraming(recipe, e);
      back := Encode(e);
      if SameBytes(back, a) and Rebuild(z.plain, recipe, back, threads) and SameBytes(back, a) then Exit(dsOk);
    end;
    recipe.encoder := 0;
    recipe.mz := Default(TMinizParams);
  end;
  recipe.kind := RECIPE_ZLIB_FLOW;
  { the recipe itself rebuilt (its parameters, flow and variant: what a
    reader has), not only the search's choices, must be the stream }
  if FindZlibFlow(z, recipe.prm, recipe.flow, e) then begin
    PutFraming(recipe, e);
    back := Encode(e);
    if SameBytes(back, a) and Rebuild(z.plain, recipe, back, threads) and SameBytes(back, a) then Exit(dsOk);
  end;
  if maxKind < RECIPE_CORR then Exit;
  { kind 3: any stream ppadeflate reads, rebuilt and compared }
  recipe.kind := RECIPE_CORR;
  recipe.prm := Default(TZlibParams);
  recipe.flow := Default(TZlibFlow);
  { (CorrEncode raises on a stream its driver cannot code: none known, but
    Analyze never raises but for memory; no recipe then) }
  { (the longest matches kept for all three: CorrMemoInit) }
  if Length(z.plain) < CORR_MEMO_MAX then CorrMemoInit(memo, Length(z.plain))
  else CorrMemoInit(memo, CORR_MEMO_MAX);
  try
    CorrChooseParams(z, recipe.pred, threads, @memo);
    recipe.corr := CorrEncode(z, recipe.pred, -1, @memo);
  except
    on e: EOutOfMemory do raise;
    on e: Exception do Exit(dsNotTaken);
  end;
  e := Default(TZStream);
  PutFraming(recipe, e);
  if CorrRebuild(z.plain, recipe.pred, recipe.corr, e, back, @memo) and SameBytes(back, a) then Result := dsOk;
end;

function Analyze(const a: TBytes; framing: TDeflFraming; maxPlain: SizeInt; out plain: TBytes;
  out recipe: TDeflRecipe; maxKind: Integer): TDeflStatus;
var z: TZStream;
begin
  plain := nil;
  recipe := Default(TDeflRecipe);
  if (Length(a) = 0) or not Parse(a, framing, maxPlain, z).Ok then Exit(dsNotDeflate);
  Result := FindRecipe(a, z, recipe, maxKind);
  if Result = dsOk then plain := z.plain;
end;

function RecipeValid(const recipe: TDeflRecipe): Boolean;
var k: SizeInt;
begin
  if recipe.kind = RECIPE_CORR then Exit(PredValid(recipe.pred) and (Length(recipe.flow.events) = 0));
  if recipe.kind = RECIPE_ENCODER then
    Exit((recipe.encoder = ENC_MINIZ) and MinizValid(recipe.mz) and (Length(recipe.flow.events) = 0));
  if recipe.kind > RECIPE_ZLIB_FLOW then Exit(False);
  with recipe.prm do
    Result := (recipe.kind >= RECIPE_ZLIB) and (recipe.kind <= RECIPE_KIND_LAST) and (level >= 1) and (level <= 9) and
      (strategy >= Z_DEFAULT_STRATEGY) and (strategy <= Z_FIXED) and
      (memLevel >= 1) and (memLevel <= 9) and (wbits >= 8) and (wbits <= 15);
  if not Result then Exit;
  if recipe.kind = RECIPE_ZLIB then Exit(Length(recipe.flow.events) = 0);
  if (recipe.flow.variant and not ZV_NO_TOO_FAR) > ZV_LAST then Exit(False);
  for k := 0 to High(recipe.flow.events) do
    with recipe.flow.events[k] do
      if (kind < ZE_SYNC) or (kind > ZE_PARAMS) or (pos < 0) or
         ((kind = ZE_PARAMS) and ((level < 1) or (level > 9) or (strategy > Z_FIXED))) then Exit(False);
end;

function Rebuild(const plain: TBytes; const recipe: TDeflRecipe; out stream: TBytes; threads: Integer): Boolean;
var e: TZStream; good: SizeInt;
begin
  stream := nil;
  if not RecipeValid(recipe) then Exit(False);
  if recipe.kind = RECIPE_CORR then begin
    e := Default(TZStream);
    PutFraming(recipe, e);
    Exit(CorrRebuild(plain, recipe.pred, recipe.corr, e, stream));
  end;
  if recipe.kind = RECIPE_ENCODER then begin
    if not MinizChoices(plain, recipe.mz, nil, not recipe.raw, e) then Exit(False);
    PutFraming(recipe, e);
    stream := Encode(e);
    Exit(True);
  end;
  if recipe.kind = RECIPE_ZLIB then
    ZlibChoices(plain, recipe.prm, nil, e, threads)
  else begin
    if not ZlibFlowValid(recipe.flow, recipe.prm, Length(plain)) then Exit(False);
    ZlibChoicesFlow(plain, recipe.prm, recipe.flow, nil, e, good, threads);
  end;
  PutFraming(recipe, e);
  stream := Encode(e);
  Result := True;
end;

{ ---------------------------------------------------------------- codec stream version 2's fields }

type
  TOut = record b: TBytes; n: SizeInt; end;

procedure Put(var o: TOut; v: Byte);
begin
  if o.n = Length(o.b) then SetLength(o.b, 2 * o.n + 16);
  o.b[o.n] := v; Inc(o.n);
end;

procedure PutVar(var o: TOut; x: QWord);
begin
  while x >= 128 do begin Put(o, Byte(x and 127) or 128); x := x shr 7; end;
  Put(o, Byte(x));
end;

{ the framing's fields, as version 2 has them }
procedure PutFramingBytes(var o: TOut; const recipe: TDeflRecipe);
var i: SizeInt;
begin
  with recipe do begin
    Put(o, Ord(raw) or (Ord(adlerOk) shl 1));
    Put(o, header[0]); Put(o, header[1]); Put(o, endPad);
    PutVar(o, Length(tail));
    for i := 0 to High(tail) do Put(o, tail[i]);
  end;
end;

function RecipeBytesV2(const recipe: TDeflRecipe): TBytes;
var o: TOut;
begin
  if recipe.kind <> RECIPE_ZLIB then raise Exception.Create('ppapreflate: codec stream version 2 holds kind 0 only');
  o.b := nil; o.n := 0;
  with recipe do begin
    Put(o, prm.level); Put(o, prm.strategy); Put(o, prm.memLevel); Put(o, prm.wbits);
  end;
  PutFramingBytes(o, recipe);
  SetLength(o.b, o.n);
  Result := o.b;
end;

type
  TIn = record
    b: TBytes; pos: SizeInt; ok: Boolean;
    { a byte; past the end, 0 and ok False (as the codec's reader) }
    function Get: Byte;
    { a varint up to max; anything above, or cut short, sets ok False }
    function GetVar(max: QWord): QWord;
  end;

function TIn.Get: Byte;
begin
  if (not ok) or (pos >= Length(b)) then begin ok := False; Exit(0); end;
  Result := b[pos]; Inc(pos);
end;

function TIn.GetVar(max: QWord): QWord;
var x: Byte; shift: Integer;
begin
  Result := 0; shift := 0;
  repeat
    x := Get;
    if not ok then Exit(0);
    if shift > 56 then begin ok := False; Exit(0); end;
    Result := Result or (QWord(x and 127) shl shift);
    Inc(shift, 7);
  until x < 128;
  if Result > max then begin ok := False; Result := 0; end;
end;

{ the framing's fields read back }
function ReadFramingBytes(var r: TIn; maxTail: QWord; var recipe: TDeflRecipe): TRecipeRead;
var flags: Byte; len: QWord;
begin
  flags := r.Get;
  if flags > 3 then Exit(rrBad);
  recipe.raw := (flags and 1) <> 0;
  recipe.adlerOk := (flags and 2) <> 0;
  recipe.header[0] := r.Get; recipe.header[1] := r.Get; recipe.endPad := r.Get;
  len := r.GetVar(maxTail);
  if not r.ok or (len > QWord(Length(r.b) - r.pos)) then Exit(rrBad);
  recipe.tail := Copy(r.b, r.pos, len);
  Inc(r.pos, len);
  Result := rrOk;
end;

function ReadRecipeV2(const b: TBytes; var pos: SizeInt; maxTail: QWord; out recipe: TDeflRecipe): TRecipeRead;
var r: TIn;
begin
  r.b := b; r.pos := pos; r.ok := True;
  recipe := Default(TDeflRecipe);
  recipe.kind := RECIPE_ZLIB;
  recipe.prm.level := r.Get; recipe.prm.strategy := r.Get; recipe.prm.memLevel := r.Get; recipe.prm.wbits := r.Get;
  pos := r.pos;
  { as version 2 read them: bytes cut short read as 0, a level out of range }
  if not RecipeValid(recipe) then Exit(rrBadParams);
  Result := ReadFramingBytes(r, maxTail, recipe);
  pos := r.pos;
end;

{ ---------------------------------------------------------------- RecipeBytes (RECIPE_FORMAT 2) }

function RecipeBytes(const recipe: TDeflRecipe): TBytes;
var o: TOut; k, last: SizeInt;
begin
  { a recipe Analyze made always passes; another is a caller's bug, said
    as such rather than as a range check deep in the writer }
  if not RecipeValid(recipe) then raise Exception.Create('ppapreflate: RecipeBytes of a recipe RecipeValid refuses');
  for k := 1 to High(recipe.flow.events) do
    if recipe.flow.events[k].pos < recipe.flow.events[k - 1].pos then
      raise Exception.Create('ppapreflate: RecipeBytes of a flow out of order');
  o.b := nil; o.n := 0;
  Put(o, RECIPE_FORMAT);
  Put(o, recipe.kind);
  if recipe.kind = RECIPE_CORR then begin
    with recipe.pred do begin
      Put(o, predVersion);
      PutVar(o, chain); PutVar(o, nice); PutVar(o, lazy); PutVar(o, good);
      Put(o, hbits); PutVar(o, maxDist); Put(o, flags); PutVar(o, symEnd); Put(o, tree);
    end;
    PutFramingBytes(o, recipe);
    PutVar(o, Length(recipe.corr));
    for k := 0 to High(recipe.corr) do Put(o, recipe.corr[k]);
    SetLength(o.b, o.n);
    Exit(o.b);
  end;
  if recipe.kind = RECIPE_ENCODER then begin
    Put(o, recipe.encoder);
    Put(o, recipe.mz.variant);
    PutVar(o, recipe.mz.flags);
    PutFramingBytes(o, recipe);
    SetLength(o.b, o.n);
    Exit(o.b);
  end;
  with recipe do begin
    Put(o, prm.level); Put(o, prm.strategy); Put(o, prm.memLevel); Put(o, prm.wbits);
  end;
  if recipe.kind = RECIPE_ZLIB_FLOW then begin
    Put(o, recipe.flow.variant);
    PutVar(o, Length(recipe.flow.events));
    last := 0;
    for k := 0 to High(recipe.flow.events) do
      with recipe.flow.events[k] do begin
        PutVar(o, pos - last); last := pos;
        Put(o, kind);
        if kind = ZE_PARAMS then Put(o, level or (strategy shl 4));
      end;
  end;
  PutFramingBytes(o, recipe);
  SetLength(o.b, o.n);
  Result := o.b;
end;

function ReadRecipe(const b: TBytes; var pos: SizeInt; plainLen: SizeInt; maxTail: QWord;
  out recipe: TDeflRecipe): TRecipeRead;
var r: TIn; cnt, k: QWord; at: QWord; x, s: Byte;
begin
  r.b := b; r.pos := pos; r.ok := True;
  recipe := Default(TDeflRecipe);
  Result := rrBad;
  if (r.Get <> RECIPE_FORMAT) or not r.ok then Exit;
  recipe.kind := r.Get;
  if recipe.kind = RECIPE_CORR then begin
    with recipe.pred do begin
      predVersion := r.Get;
      if not r.ok or (predVersion <> PRED_VERSION) then Exit;
      chain := r.GetVar(PRED_MAX_CHAIN); nice := r.GetVar(258); lazy := r.GetVar(258); good := r.GetVar(258);
      hbits := r.Get; maxDist := r.GetVar(32768); flags := r.Get; symEnd := r.GetVar(PRED_MAX_SYMEND);
      tree := r.Get;
    end;
    if not r.ok then Exit;
    if not PredValid(recipe.pred) then Exit(rrBadParams);
    Result := ReadFramingBytes(r, maxTail, recipe);
    if Result <> rrOk then Exit;
    Result := rrBad;
    cnt := r.GetVar(QWord(Length(r.b) - r.pos));
    if not r.ok or (cnt > QWord(Length(r.b) - r.pos)) then Exit;
    recipe.corr := Copy(r.b, r.pos, cnt);
    Inc(r.pos, cnt);
    pos := r.pos;
    Exit(rrOk);
  end;
  if recipe.kind = RECIPE_ENCODER then begin
    recipe.encoder := r.Get;
    recipe.mz.variant := r.Get;
    recipe.mz.flags := r.GetVar(MZ_FLAGS);
    if not r.ok or (recipe.encoder <> ENC_MINIZ) then Exit;
    if not RecipeValid(recipe) then Exit(rrBadParams);
    Result := ReadFramingBytes(r, maxTail, recipe);
    pos := r.pos;
    Exit;
  end;
  recipe.prm.level := r.Get; recipe.prm.strategy := r.Get; recipe.prm.memLevel := r.Get; recipe.prm.wbits := r.Get;
  if not r.ok then Exit;
  if (recipe.kind < RECIPE_ZLIB) or (recipe.kind > RECIPE_ZLIB_FLOW) then Exit;
  if not RecipeValid(recipe) then Exit(rrBadParams);
  if recipe.kind = RECIPE_ZLIB_FLOW then begin
    recipe.flow.variant := r.Get;
    if not r.ok or ((recipe.flow.variant and not ZV_NO_TOO_FAR) > ZV_LAST) or (plainLen < 0) then Exit;
    { the count checked before anything is kept for it }
    cnt := r.GetVar(2 * QWord(plainLen) + 2);
    { each event takes 2 bytes at least: no more than the bytes left hold }
    if not r.ok or (cnt > QWord(Length(r.b) - r.pos) div 2) then Exit;
    SetLength(recipe.flow.events, cnt);
    at := 0;
    k := 0;
    while k < cnt do begin
      at := at + r.GetVar(QWord(plainLen));
      x := r.Get;
      if not r.ok or (at > QWord(plainLen)) then Exit;
      if (x < ZE_SYNC) or (x > ZE_PARAMS) then Exit;
      with recipe.flow.events[k] do begin
        pos := at;
        kind := x;
        if kind = ZE_PARAMS then begin
          s := r.Get;
          if not r.ok then Exit;
          level := s and 15; strategy := s shr 4;
        end;
      end;
      Inc(k);
    end;
    if not RecipeValid(recipe) or not ZlibFlowValid(recipe.flow, recipe.prm, plainLen) then Exit(rrBadParams);
  end;
  Result := ReadFramingBytes(r, maxTail, recipe);
  pos := r.pos;
end;

end.
