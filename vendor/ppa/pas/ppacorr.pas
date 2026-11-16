{ Recipe kind 3 (doc/PREFLATE.md): a zlib-like predictor, and the
  corrections that make what it predicts the stream, bit for bit.

  The predictor follows the stream's own parse (a forced parse). At each
  token it proposes one from the bytes alone, as zlib's deflate_slow (or
  deflate_fast) would from the same place: hash chains over every position,
  longest_match with a chain, nice, good and lazy of the recipe's, the
  lazy match one position ahead; or, for an optimal parser, the longest
  match there (PF_LONGEST). Then the stream's real token is taken, and the
  predictor goes on from where that token ends. Only where the two differ
  is something coded: whether it is a literal, the length against the
  longest match there (a shorter one as its length symbol and its place in
  it), the distance as its rank among the candidates at least that long
  (runs of one byte skipped). Every other choice an encoder makes is coded
  the same way, against a guess: where a block ends (zlib's symbol count),
  its type (stored first, then fixed against dynamic by zlib's sizes), a
  stored block's length and pad bits, whether it is the last, a dynamic
  block's code lengths (the trees of zlib, libdeflate, miniz or zopfli over
  the block's own symbol counts: TPredParams.tree), HLIT, HDIST, how the
  lengths are run-length coded (zlib's on each tree or on both at once,
  libdeflate's, miniz's, zopfli's, or each symbol explicitly), the
  code-length code and HCLEN, a 258 written as 284. Every field of
  ppadeflate's TDeflateBlock and every token can be coded whatever it is
  (a verbatim escape where a guess has no room: a match's distance outside
  the rank walk, any code length), so every stream Decode reads has a
  kind-3 recipe.

  The corrections are binary decisions and small numbers, coded with
  ppaarith's arithmetic coder and adaptive bits of this unit's own; a
  token's main decisions mix several of them, each with its own context
  (an integer logistic mixer). Encoder and decoder run the same driver
  (Drive): the encoder gives it the stream's choices and it codes them,
  the decoder gets them back from it; the rebuild writes each block as soon
  as it has it (ppadeflate's TDeflWriter), so it holds one block's tokens,
  never the stream's.

  A recipe decodes only with the predictor and models that made it: they
  are frozen by PRED_VERSION (doc/PREFLATE.md, the versioning rule).

  The searches and the rank walk (the hot loops) are also in C
  (ppacorrc.c); this is their reference, and both give the same
  corrections. Our own code: the idea of a forced parse and of coding a
  distance as its rank among the candidates is preflate's (Dirk Steinke),
  none of its code; the tree builders reproduce libdeflate's, miniz's and
  zopfli's (NOTICE). }
unit ppacorr;

{$I ppa.inc}
{ PPA_FAST: the release build, without range and overflow checks. Every
  value a recipe gives is checked before it indexes anything or reaches
  the writer; the checked build is the reference. }
{$ifdef PPA_FAST}
  {$R-}{$Q-}
{$else}
  {$ifopt R-}{$fatal ppacorr: range checks ($R+) are mandatory}{$endif}
  {$ifopt Q-}{$fatal ppacorr: overflow checks ($Q+) are mandatory}{$endif}
{$endif}

interface

uses SysUtils, ppadeflate;

const
  { the predictor and the models (doc/PREFLATE.md): a recipe of another
    version is refused }
  PRED_VERSION = 2;
  { TPredParams.flags: deflate_slow's filters: a match of 5 or fewer dropped
    (Z_FILTERED); a match of 3 further than 4096 dropped (TOO_FAR) }
  PF_FILTERED = 1;
  PF_TOOFAR = 2;
  { the search is the longest match on the rank walk's candidates (its
    skips over runs), not zlib's longest_match: an optimal parser's guess }
  PF_LONGEST = 4;
  PF_ALL = 7;
  PRED_MAX_CHAIN = 4096;
  PRED_MAX_SYMEND = 1 shl 20;
  PRED_TREE_LAST = 4;

type
  TPredParams = record
    predVersion: Integer; { PRED_VERSION }
    chain: Integer;       { 1..PRED_MAX_CHAIN: candidates a search may look at }
    nice: Integer;        { 3..258: a match this long ends the search }
    lazy: Integer;        { 0: no lazy match (deflate_fast); 3..258: max_lazy }
    good: Integer;        { 3..258: chain / 4 when the match to beat is this long }
    hbits: Integer;       { 8..16: the hash's bits (zlib: memLevel + 7) }
    maxDist: Integer;     { 1..32768: the farthest a predicted match reaches }
    flags: Integer;       { PF_* }
    symEnd: Integer;      { 0..PRED_MAX_SYMEND: a block's predicted symbols (0: none) }
    tree: Integer;        { 0..PRED_TREE_LAST: the code lengths' builder (zlib, libdeflate, miniz, package-merge, zopfli) }
  end;

type
  { The predictor's longest match at each position below n, kept: it is
    the plain's and the position's alone (its chains are of every position
    before, whatever the parameters), so the parameter search's candidates
    (all at the same positions, the stream's tokens), the recipe's encoding
    and its rebuild can share it, and the same corrections give the same
    stream with it or without. long and lx1: by position, for the walk's
    two lengths, the match's length in the high 16 bits and its distance
    in the low 16, all ones where not known yet. Threads can share one:
    each writes what any would. }
  TLongMemo = record
    n: SizeInt;
    long, lx1: array of LongWord;
  end;
  PLongMemo = ^TLongMemo;

const
  { positions a recipe's memo covers, at most (8 bytes each) }
  CORR_MEMO_MAX = 1 shl 22;

{ m for the positions below n (none known yet) }
procedure CorrMemoInit(out m: TLongMemo; n: SizeInt);

{ Whether p is one CorrRebuild can use. }
function PredValid(const p: TPredParams): Boolean;

{ The corrections of z's blocks and tokens against the predictor p. With
  stopTokens >= 0, only up to token stopTokens (or plain byte stopTokens *
  16): the parameter search's measure, not a recipe. }
function CorrEncode(const z: TZStream; const p: TPredParams; stopTokens: SizeInt = -1; memo: PLongMemo = nil): TBytes;

{ plain and its corrections -> the stream, framed as frame says (raw,
  header, adlerOk, endPad, tail; its blocks and tokens are not read).
  False, and no stream, on corrections that do not give a stream within
  the caps (a block count, distances, lengths, pad bits); never raises but
  for memory. }
function CorrRebuild(const plain: TBytes; const p: TPredParams; const corr: TBytes;
  const frame: TZStream; out stream: TBytes; memo: PLongMemo = nil): Boolean;

{ The parameters whose corrections of z's first blocks are the smallest;
  the candidates measured on as many threads (the same parameters with
  any). memo: one for z.plain to share (nil: its own). }
procedure CorrChooseParams(const z: TZStream; out p: TPredParams; threads: Integer = 1; memo: PLongMemo = nil);

var
  { the search and the rank walk in C (ppacorrc.c); False: in Pascal, the
    reference. PPA_NOC=1 in the environment makes it False }
  UseCorrC: Boolean = True;
  { measuring only (never changes a recipe): with CorrStatOn, CorrEncode
    adds the bits each kind of correction cost to CorrStat: 0 block types,
    1 block ends, 2 a token's hit, 3 literal or match, 4 a missed match's
    length (predicted the longest), 5 a rank's bucket, 6 its low bits or
    the escape, 7 258 as 284, 8 code lengths, 9 HLIT, HDIST, HCLEN, 10 the
    run-length coding, 11 the code-length code, 12 the last block, 13 a
    stored block's length and pad, 14 a length shorter or longer than the
    reference, 15 a length's first bit in the other cases }
  CorrStatOn: Boolean = False;
  CorrStat: array[0..15] of Double;

{ miniz's code lengths of the counts freq[0..n-1] (at most maxLen bits;
  tdefl_optimize_huffman_table) into lens[0..n-1], and its run-length
  coding of the lengths lens[0..total-1] (tdefl_start_dynamic_block) into
  seq (ppadeflate's clenSeq: symbol | extra << 5; room for total + 1).
  ppaminiz writes miniz's own blocks with them. }
procedure LensMiniz(const freq: array of Integer; n, maxLen: Integer; var lens: array of Byte);
procedure SeqMiniz(const lens: array of Byte; total: Integer; var seq: array of Word; var nSeq: Integer);

implementation

uses ppaarith, ppazlib, ppathreads;

{$L ppacorrc.o}

const
  MIN_MATCH = 3;
  MAX_MATCH = 258;
  TOO_FAR = 4096;
  WINDOW = 32768;
  { prev[] covers twice the window: a position's link is kept until the
    one 65536 later is inserted, and nothing past the next two positions
    is ever inserted early }
  PREV_SIZE = 65536;
  PREV_MASK = PREV_SIZE - 1;
  { candidates the rank walk looks at, at most; past them a distance is
    escaped (written as is) }
  RANK_HOPS = 4096;
  { the walk for the context of the longest match one position on }
  LX1_HOPS = 256;
  { the longest match's walk for its first 3 bytes, and for longer ones }
  HOPS3 = 256;
  LONG_HOPS = 4096;
  RANK_ESC = 13;          { the escape's bucket: ranks are buckets 0..12 }
  { blocks a rebuild makes, at most: 2 a byte and some (zlib's flushes can
    make two empty blocks at a position) }
  BLOCKS_MORE = 4096;
  NIL_POS = -1;

  LEN_BASE: array[257..285] of Word = (
    3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
    35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258);
  LEN_EXTRA: array[257..285] of Byte = (
    0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
    3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0);
  DIST_BASE: array[0..29] of Word = (
    1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
    257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145,
    8193, 12289, 16385, 24577);
  DIST_EXTRA: array[0..29] of Byte = (
    0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
    7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13);
  CLEN_ORDER: array[0..18] of Byte = (
    16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15);

var
  LenSym: array[3..258] of Word;
  DistSym: array[1..32768] of Byte;

{ ---------------------------------------------------------------- the predictor's state }

type
  { ppacorrc.c's pcstate_t, field for field }
  TPredState = record
    plain: PByte; n: SizeInt;
    head: PLongInt; prev: PLongInt;   { head: 2^hbits; prev: PREV_SIZE, by position and PREV_MASK }
    ins: SizeInt;                     { the positions before ins are inserted }
    hmask, hshift: SizeInt;
    chain, nice, good, maxDist: SizeInt;
    hops: SizeInt;
    { the C search's own links (unused here): each position's order in its
      hash chain, each hash's count, the chains of 4 bytes' hash }
    ord, hcnt, head4, link4: PLongInt;
    { where each position's run of one byte starts (by position and
      PREV_MASK): the rank walk's skips }
    runs: PLongInt;
    { the rank walk's and the longest match's own chains of 3 bytes (a
      hash of 16 bits, Hash3x): head3 by hash, link3 by position and
      PREV_MASK }
    head3, link3: PLongInt;
  end;

function pc_search(var s: TPredState; q, prevLen: SizeInt; out dist: SizeInt): SizeInt; cdecl; external name 'pc_search';
function pc_rank(var s: TPredState; q, len, target, wantRank: SizeInt): SizeInt; cdecl; external name 'pc_rank';

function Hash3(const s: TPredState; q: SizeInt): SizeInt; inline;
begin
  Result := (((SizeInt(s.plain[q]) shl s.hshift) xor s.plain[q + 1]) shl s.hshift xor s.plain[q + 2]) and s.hmask;
end;

{ every position up to k (those with 3 bytes) into the chains }
{ the hash of the 4 bytes at q (q + 4 <= n): their value, the first
  lowest, times 2654435761, the top 16 of the low 32 bits }
function Hash4(const s: TPredState; q: SizeInt): SizeInt; inline;
var v: LongWord;
begin
  v := LongWord(s.plain[q]) or (LongWord(s.plain[q + 1]) shl 8) or (LongWord(s.plain[q + 2]) shl 16) or
    (LongWord(s.plain[q + 3]) shl 24);
  {$push}{$Q-}{$R-}
  v := v * LongWord(2654435761);
  {$pop}
  Result := v shr 16;
end;

{ the hash of the 3 bytes at q: their value, the first lowest, times
  2654435761, the top 16 of the low 32 bits }
function Hash3x(const s: TPredState; q: SizeInt): SizeInt; inline;
var v: LongWord;
begin
  v := LongWord(s.plain[q]) or (LongWord(s.plain[q + 1]) shl 8) or (LongWord(s.plain[q + 2]) shl 16);
  {$push}{$Q-}{$R-}
  v := v * LongWord(2654435761);
  {$pop}
  Result := v shr 16;
end;

procedure InsertUpTo(var s: TPredState; k: SizeInt);
var h: SizeInt;
begin
  if k > s.n - MIN_MATCH then k := s.n - MIN_MATCH;
  while s.ins <= k do begin
    h := Hash3(s, s.ins);
    s.prev[s.ins and PREV_MASK] := s.head[h];
    s.head[h] := s.ins;
    h := Hash3x(s, s.ins);
    s.link3[s.ins and PREV_MASK] := s.head3[h];
    s.head3[h] := s.ins;
    if s.ins + 3 < s.n then begin
      h := Hash4(s, s.ins);
      s.link4[s.ins and PREV_MASK] := s.head4[h];
      s.head4[h] := s.ins;
    end;
    if (s.ins > 0) and (s.plain[s.ins] = s.plain[s.ins - 1]) then s.runs[s.ins and PREV_MASK] := s.runs[(s.ins - 1) and PREV_MASK]
    else s.runs[s.ins and PREV_MASK] := s.ins;
    Inc(s.ins);
  end;
end;

{ the newest position before q with q's hash (q + 3 <= n) }
function Chain3Start(var s: TPredState; q: SizeInt): SizeInt;
begin
  if q < s.ins then Exit(s.link3[q and PREV_MASK]);
  InsertUpTo(s, q - 1);
  Result := s.head3[Hash3x(s, q)];
end;

function ChainStart(var s: TPredState; q: SizeInt): SizeInt;
begin
  if q < s.ins then Exit(s.prev[q and PREV_MASK]);
  InsertUpTo(s, q - 1);
  Result := s.head[Hash3(s, q)];
end;

{ zlib's longest_match at q from the newest position with q's hash: a
  match longer than prevLen (its length, dist its distance), or 0. Chains
  as zlib's: position 0 is never a candidate (NIL), candidates up to
  maxDist back, chain / 4 when prevLen >= good, nice capped to what is
  left }
function SearchPas(var s: TPredState; q, prevLen: SizeInt; out dist: SizeInt): SizeInt;
var cur, limit, chainLen, bestLen, nice, look, len, maxLen: SizeInt; pl: PByte;
begin
  Result := 0; dist := 0;
  look := s.n - q;
  if (look < MIN_MATCH) or (prevLen >= look) then Exit;
  cur := ChainStart(s, q);
  if (cur <= 0) or (q - cur > s.maxDist) then Exit;
  if q > s.maxDist then limit := q - s.maxDist else limit := 0;
  chainLen := s.chain;
  if prevLen >= s.good then chainLen := chainLen shr 2;
  if chainLen < 1 then chainLen := 1;
  nice := s.nice; if nice > look then nice := look;
  maxLen := MAX_MATCH; if maxLen > look then maxLen := look;
  bestLen := prevLen;
  pl := s.plain;
  repeat
    if (pl[cur + bestLen] = pl[q + bestLen]) and (pl[cur + bestLen - 1] = pl[q + bestLen - 1]) and
       (pl[cur] = pl[q]) and (pl[cur + 1] = pl[q + 1]) then begin
      len := 2;
      while (len < maxLen) and (pl[cur + len] = pl[q + len]) do Inc(len);
      if len > bestLen then begin
        bestLen := len; dist := q - cur;
        if len >= nice then Break;
      end;
    end;
    cur := s.prev[cur and PREV_MASK];
    Dec(chainLen);
  until (cur <= limit) or (chainLen = 0);
  if bestLen > prevLen then Result := bestLen else dist := 0;
end;

{ the bytes from c that are c's, at most cap }
function RunFrom(pl: PByte; c, cap: SizeInt): SizeInt; inline;
var b: Byte;
begin
  Result := 1; b := pl[c];
  while (Result < cap) and (pl[c + Result] = b) do Inc(Result);
end;

{ The rank walk: the candidates before q (its whole chain, up to WINDOW
  back, position 0 included, at most hops of them) whose match is at least
  len long, newest first. wantRank = 1: the distance of the one of rank
  target; 0: the rank of distance target. -1 when there is none.

  Runs of one byte are skipped where they cannot hold a candidate: when q
  starts with a run of rq bytes (3 <= rq < len), a candidate in a run of
  the same byte matches min(its run, rq) bytes unless its run is rq too;
  so from a position of that run with rc <> rq bytes left, the walk goes
  to the run's position with rq left (rc < rq) or below the run (rc > rq).
  Every position of the run is in q's chain (its 3 bytes are q's), the
  skipped ones are not candidates, and each skip is a hop. }
function RankPas(var s: TPredState; q, len, target, wantRank: SizeInt): SizeInt;
var cur, hops, nRank, k, rq, rc, rs: SizeInt; pl: PByte;
begin
  Result := -1;
  if (len < MIN_MATCH) or (q + len > s.n) then Exit;
  cur := Chain3Start(s, q);
  hops := 0; nRank := 0;
  pl := s.plain;
  rq := RunFrom(pl, q, len);
  while (cur >= 0) and (q - cur <= WINDOW) and (hops < s.hops) do begin
    if (rq >= MIN_MATCH) and (rq < len) and (pl[cur] = pl[q]) then begin
      rc := RunFrom(pl, cur, rq + 1);
      if (rc >= MIN_MATCH) and (rc <> rq) then begin
        Inc(hops);
        rs := s.runs[cur and PREV_MASK];
        if (rc < rq) and (cur - (rq - rc) >= rs) then begin cur := cur - (rq - rc); Continue; end;
        if q - rs > WINDOW then Break;
        cur := s.link3[rs and PREV_MASK];
        Continue;
      end;
    end;
    if pl[cur + len - 1] = pl[q + len - 1] then begin
      k := 0;
      while (k < len) and (pl[cur + k] = pl[q + k]) do Inc(k);
      if k = len then begin
        if wantRank <> 0 then begin
          if nRank = target then Exit(q - cur);
        end else if q - cur = target then Exit(nRank);
        Inc(nRank);
      end;
    end;
    cur := s.link3[cur and PREV_MASK];
    Inc(hops);
  end;
end;

{ The longest match at q (dist: the nearest of that length), at most 258
  and the bytes left, up to WINDOW back, position 0 included; 0 when
  shorter than 3. The nearest 3 bytes the same are looked for on the
  3-byte chain (HOPS3 positions at most); if they match 4 or more, longer
  matches on the 4-byte chain below them (hops positions at most, the
  same skips over runs as the rank walk's). Inside a run of q's byte, a
  position with rc bytes of it left matches min(rc, rq) (rc <> rq): the
  run's best is rq when one has more than rq left, else the run's start,
  and only its position with rq left can match more. }
function LongestPas(var s: TPredState; q, maxHops: SizeInt; out dist: SizeInt): SizeInt;
var cur, hops, best, maxLen, k, rq, rc, rs, lo: SizeInt; pl: PByte;
begin
  Result := 0; dist := 0;
  maxLen := s.n - q; if maxLen > MAX_MATCH then maxLen := MAX_MATCH;
  if maxLen < MIN_MATCH then Exit;
  pl := s.plain;
  best := 0;
  { the nearest 3 bytes the same, on the 3-byte chain }
  cur := Chain3Start(s, q);
  hops := 0;
  while (cur >= 0) and (q - cur <= WINDOW) and (hops < HOPS3) do begin
    if (pl[cur] = pl[q]) and (pl[cur + 1] = pl[q + 1]) and (pl[cur + 2] = pl[q + 2]) then begin
      k := MIN_MATCH;
      while (k < maxLen) and (pl[cur + k] = pl[q + k]) do Inc(k);
      best := k; dist := q - cur;
      Break;
    end;
    cur := s.link3[cur and PREV_MASK];
    Inc(hops);
  end;
  if (maxLen < 4) or (best >= maxLen) then begin
    if best >= MIN_MATCH then Result := best else dist := 0;
    Exit;
  end;
  { longer: on the 4-byte chain (below that one if it matched 4) }
  if q < s.ins then cur := s.link4[q and PREV_MASK] else cur := s.head4[Hash4(s, q)];
  if best >= 4 then
    while cur >= q - dist do cur := s.link4[cur and PREV_MASK];
  hops := 0;
  rq := RunFrom(pl, q, maxLen);
  while (cur >= 0) and (q - cur <= WINDOW) and (hops < maxHops) do begin
    if (rq >= 4) and (rq < maxLen) and (pl[cur] = pl[q]) then begin
      rc := RunFrom(pl, cur, rq + 1);
      if (rc >= 4) and (rc <> rq) then begin
        Inc(hops);
        rs := s.runs[cur and PREV_MASK];
        if rc > rq then begin
          if rq > best then begin best := rq; dist := q - cur; end;
        end else if cur - (rq - rc) >= rs then begin
          cur := cur - (rq - rc); Continue;
        end else begin
          lo := q - WINDOW; if lo < rs then lo := rs;
          k := rc + cur - lo;
          if k > best then begin best := k; dist := q - lo; end;
        end;
        if q - rs > WINDOW then Break;
        cur := s.link4[rs and PREV_MASK];
        Continue;
      end;
    end;
    if pl[cur + best] = pl[q + best] then begin
      k := 0;
      while (k < maxLen) and (pl[cur + k] = pl[q + k]) do Inc(k);
      if k > best then begin
        best := k; dist := q - cur;
        if best >= maxLen then Break;
      end;
    end;
    cur := s.link4[cur and PREV_MASK];
    Inc(hops);
  end;
  if best >= MIN_MATCH then Result := best else dist := 0;
end;

function pc_longest(var s: TPredState; q, maxHops: SizeInt; out dist: SizeInt): SizeInt; cdecl; external name 'pc_longest';

function Longest(var s: TPredState; q, maxHops: SizeInt; out dist: SizeInt): SizeInt; inline;
begin
  if UseCorrC then Result := pc_longest(s, q, maxHops, dist) else Result := LongestPas(s, q, maxHops, dist);
end;

function Search(var s: TPredState; q, prevLen: SizeInt; out dist: SizeInt): SizeInt; inline;
begin
  if UseCorrC then Result := pc_search(s, q, prevLen, dist) else Result := SearchPas(s, q, prevLen, dist);
end;

function Rank(var s: TPredState; q, len, target, wantRank: SizeInt): SizeInt; inline;
begin
  if UseCorrC then Result := pc_rank(s, q, len, target, wantRank) else Result := RankPas(s, q, len, target, wantRank);
end;

{ ---------------------------------------------------------------- the models }

type
  { an adaptive bit: P(1) in 22 bits; fast at first (1/1.5, 1/2.5, ...),
    then at about 1/RATE_LIMIT }
  TPBit = record
    p: LongWord;
    n: Word;
  end;
  PPBit = ^TPBit;

const
  P_ONE = 1 shl 22;
  RATE_LIMIT = 127;
  { a mixer's inputs at most (the contexts; one more, the bias) }
  MIX_IN = 7;
  { its weights in 16.16, at first }
  MIX_W0 = 30000;
  { the learning rate: a weight moves by stretch * error >> MIX_SHIFT }
  MIX_SHIFT = 14;
  RANK_BITS = 12;          { a rank's bucket below RANK_ESC: at most 12 low bits }
  SEL_EXPLICIT = 5;
  GOLOMB_STRIDE = 80;      { DoGolomb's low bits: 64 by the bits so far, then 16 by position }        { the run-length codings guessed (DoTree), then explicit }

var
  RATE: array[0..RATE_LIMIT] of LongWord;   { 65536 / (n + 1.5) }

type
  TMixW = array[0..MIX_IN] of LongInt;

  { every adaptive bit of the corrections }
  TModels = record
    stored: array[0..3] of TPBit;          { by the previous block's type (3: none) }
    stLenMax, padZero, final: TPBit;
    blockEnd: array[0..3, 0..15] of TPBit; { 0, 1 first token, 2 at symEnd, 3 at the previous block's count; the count's bits }
    dyn: array[0..1] of TPBit;             { by zlib's choice }
    { a token: as predicted (hit), a literal, the length's reference }
    hit0: array[0..15] of TPBit;           { predicted length's bucket x the last token missed }
    hit1: array[0..127] of TPBit;          { the last 4 tokens' hits x predicted bucket }
    hit2: array[0..143] of TPBit;          { the longest match's bucket x the lazy one's (8: none) x a match predicted }
    hit3: array[0..63] of TPBit;           { the last token's length bucket x predicted bucket }
    hit4: array[0..511] of TPBit;          { the byte x a match predicted }
    hit5: array[0..71] of TPBit;           { the longest match's cost against literals x predicted bucket }
    lit4: array[0..71] of TPBit;
    hit6: array[0..127] of TPBit;
    lit5: array[0..63] of TPBit;
    eq4: array[0..35] of TPBit;
    lit0: array[0..15] of TPBit;
    lit1: array[0..127] of TPBit;
    lit2: array[0..71] of TPBit;
    lit3: array[0..255] of TPBit;
    eq0: array[0..63] of TPBit;            { case x reference's bucket x last missed }
    eq1: array[0..511] of TPBit;           { the last 4 hits x case x bucket }
    eq2: array[0..287] of TPBit;           { the lazy one's bucket x case x bucket }
    eq3: array[0..3, 0..258] of TPBit;     { case x the reference }
    eqP: array[0..63] of TPBit;            { as predicted when not the longest }
    dir0: array[0..31] of TPBit;
    dir1: array[0..3, 0..258] of TPBit;
    sDown: array[0..28, 0..7] of TPBit;     { a shorter length's symbol: steps down from the reference's }
    sTop: array[0..2, 0..28] of TPBit;      { the top length of its symbol (by steps, symbol) }
    sOff: array[0..28, 0..63] of TPBit;     { else how far below it }
    lexp: array[0..2, 0..7, 0..9] of TPBit;     { shorter, longer, no reference x bucket x the exponent's unary }
    lmant: array[0..2, 0..9, 0..GOLOMB_STRIDE - 1] of TPBit;  { x exponent x the bits so far }
    as284: TPBit;
    rankK: array[0..2, 0..RANK_ESC - 1] of TPBit;
    rankM: array[1..RANK_ESC - 1, 0..RANK_BITS - 1] of TPBit;
    escE: array[0..15] of TPBit;
    escM: array[0..15, 0..GOLOMB_STRIDE - 1] of TPBit;   { exponents 0..15: up to 32768 }
    { a block's header }
    treeSame: array[0..1] of TPBit;
    lenSame: array[0..31] of TPBit;        { predicted length x symbol used }
    lenVal: array[0..15, 1..15] of TPBit;
    hlitSame, hdistSame, hclenSame: TPBit;
    selK: array[0..SEL_EXPLICIT, 0..SEL_EXPLICIT - 1] of TPBit;   { by the previous block's, which }
    seqLit: array[0..23] of TPBit;
    seq16, seq18: TPBit;
    seqMax: array[16..18] of TPBit;
    clenSame: TPBit;
    clenS: array[0..7] of TPBit;
  end;

  TMixers = record
    hit: array[0..7] of TMixW;
    lit: array[0..7] of TMixW;
    eq: array[0..3] of TMixW;
    dir: array[0..3] of TMixW;
  end;

  { one run of the driver: encoding (the stream's choices given) or
    decoding (got back) }
  TCoder = record
    enc: Boolean;
    cat: Integer;
    ae: TArithEncoder;
    ad: TArithDecoder;
    inp: array[0..MIX_IN - 1] of PPBit;   { MixBit's contexts }
    function Bit(var m: TPBit; b: Integer): Integer;
    { b through the mixer w of the contexts inp[0..nInputs - 1] }
    function MixBit(var w: TMixW; nInputs: Integer; b: Integer): Integer;
    function Direct(v: SizeInt; bits: Integer): SizeInt;
    { v in [0, 2^bits) through a binary tree of models t[1..2^bits - 1] }
    function Tree(var t: array of TPBit; bits: Integer; v: Integer): Integer;
  end;

procedure InitModels(var m: TModels; var mx: TMixers);
var p: PByte; i, j: SizeInt;
begin
  { every TPBit at 1/2, none updated; every weight MIX_W0 }
  p := @m;
  for i := 0 to SizeOf(m) div SizeOf(TPBit) - 1 do begin
    PLongWord(p + i * SizeOf(TPBit))^ := P_ONE div 2;
    PWord(p + i * SizeOf(TPBit) + SizeOf(LongWord))^ := 0;
  end;
  p := @mx;
  for i := 0 to SizeOf(mx) div SizeOf(TMixW) - 1 do
    for j := 0 to MIX_IN do PLongInt(p + i * SizeOf(TMixW) + j * SizeOf(LongInt))^ := MIX_W0;
end;

procedure Update(var m: TPBit; b: Integer); inline;
begin
  if b <> 0 then Inc(m.p, ((QWord(P_ONE) - m.p) * RATE[m.n]) shr 16)
  else Dec(m.p, (QWord(m.p) * RATE[m.n]) shr 16);
  if m.n < RATE_LIMIT then Inc(m.n);
end;

function TCoder.Bit(var m: TPBit; b: Integer): Integer;
var pr: Integer;
begin
  pr := m.p shr 6;
  if pr < 1 then pr := 1 else if pr > 65535 then pr := 65535;
  if enc then begin
    ae.Encode(b, pr); Result := b;
    if CorrStatOn then if b <> 0 then CorrStat[cat] := CorrStat[cat] - Ln(pr / 65536) / Ln(2) else CorrStat[cat] := CorrStat[cat] - Ln(1 - pr / 65536) / Ln(2);
  end else
    Result := ad.Decode(pr);
  Update(m, Result);
end;

function TCoder.MixBit(var w: TMixW; nInputs: Integer; b: Integer): Integer;
var st: array[0..MIX_IN] of Integer; i, t, pr, err: Integer; dot: Int64;
begin
  dot := 0;
  for i := 0 to nInputs - 1 do begin
    st[i] := STRETCH_TAB[inp[i]^.p shr 10];
    dot := dot + Int64(w[i]) * st[i];
  end;
  st[nInputs] := 256;
  dot := dot + Int64(w[nInputs]) * 256;
  t := SarInt64(dot, 16);
  if t > STRETCH_MAX then t := STRETCH_MAX else if t < -STRETCH_MAX then t := -STRETCH_MAX;
  pr := SQUASH_TAB[t + 2048];
  if enc then begin
    ae.Encode(b, pr); Result := b;
    if CorrStatOn then if b <> 0 then CorrStat[cat] := CorrStat[cat] - Ln(pr / 65536) / Ln(2) else CorrStat[cat] := CorrStat[cat] - Ln(1 - pr / 65536) / Ln(2);
  end else
    Result := ad.Decode(pr);
  err := (Result shl 16) - pr;
  for i := 0 to nInputs do w[i] := w[i] + LongInt(SarInt64(Int64(st[i]) * err, MIX_SHIFT));
  for i := 0 to nInputs - 1 do Update(inp[i]^, Result);
end;

function TCoder.Direct(v: SizeInt; bits: Integer): SizeInt;
begin
  if bits = 0 then Exit(0);
  if enc then begin ae.Direct(Cardinal(v), bits); Result := v; if CorrStatOn then CorrStat[cat] := CorrStat[cat] + bits; end
  else Result := SizeInt(ad.Direct(bits));
end;

function TCoder.Tree(var t: array of TPBit; bits: Integer; v: Integer): Integer;
var node, k, b: Integer;
begin
  node := 1;
  for k := bits - 1 downto 0 do begin
    b := Bit(t[node - 1], (v shr k) and 1);
    node := 2 * node + b;
  end;
  Result := node - (1 shl bits);
end;
{ ---------------------------------------------------------------- tree builders }

{ What other encoders make of a block's symbol counts: the code lengths
  (TB_LIBDEFLATE, TB_MINIZ, TB_PM; zlib's are ppazlib's) and the run-length
  coding of the lengths (zlib's on each tree and on both, libdeflate's,
  miniz's, zopfli's). Our own code from the encoders' descriptions; the
  results are what libdeflate 1.x, miniz 1.x/3.x and zopfli give. }

type
  TFreqs = array[0..287] of Integer;
  TLens = array[0..287] of Byte;

{ the used symbols of freq[0..n-1], by count then symbol, rarest first }
procedure SortedSyms(const freq: array of Integer; n: Integer; out syms: TFreqs; out nu: Integer);
var i, j, s: Integer;
begin
  nu := 0;
  for s := 0 to n - 1 do
    if freq[s] > 0 then begin
      j := nu;
      while (j > 0) and (freq[syms[j - 1]] > freq[s]) do begin syms[j] := syms[j - 1]; Dec(j); end;
      syms[j] := s; Inc(nu);
    end;
end;

{ lens of the sorted symbols: counts[len] of them for each len, the
  longest to the rarest }
procedure AssignSorted(const syms: TFreqs; nu: Integer; const counts: array of Integer; maxLen: Integer;
  var lens: array of Byte);
var len, i, c: Integer;
begin
  i := 0;
  for len := maxLen downto 1 do
    for c := 1 to counts[len] do begin
      if i < nu then lens[syms[i]] := len;
      Inc(i);
    end;
end;

{ libdeflate's deflate_make_huffman_code: the two-queue Huffman tree of the
  sorted counts, its depths limited to maxLen as it goes (a node too deep
  takes the deepest length still free), the lengths given in sorted order;
  fewer than 2 symbols used: 0 and the used one (or 1) get 1 }
procedure LensLibdeflate(const freq: array of Integer; n, maxLen: Integer; var lens: array of Byte);
var syms: TFreqs; nu, i, b, e, last, node, d: Integer;
  lf, nf, par, dep: array[0..287] of Integer;
  counts: array[0..15] of Integer;
begin
  for i := 0 to n - 1 do lens[i] := 0;
  SortedSyms(freq, n, syms, nu);
  if nu < 2 then begin
    if nu = 1 then i := syms[0] else i := 0;
    lens[0] := 1;
    if i = 0 then lens[1] := 1 else lens[i] := 1;
    Exit;
  end;
  for i := 0 to nu - 1 do lf[i] := freq[syms[i]];
  last := nu - 1; i := 0; b := 0; e := 0;
  repeat
    if (i + 1 <= last) and ((b = e) or (lf[i + 1] <= nf[b])) then begin
      nf[e] := lf[i] + lf[i + 1]; Inc(i, 2);
    end else if (b + 2 <= e) and ((i > last) or (nf[b + 1] < lf[i])) then begin
      nf[e] := nf[b] + nf[b + 1]; par[b] := e; par[b + 1] := e; Inc(b, 2);
    end else begin
      nf[e] := lf[i] + nf[b]; par[b] := e; Inc(i); Inc(b);
    end;
    Inc(e);
  until e >= last;
  for i := 0 to maxLen do counts[i] := 0;
  counts[1] := 2;
  dep[nu - 2] := 0;
  for node := nu - 3 downto 0 do begin
    dep[node] := dep[par[node]] + 1;
    d := dep[node];
    if d >= maxLen then begin
      d := maxLen;
      repeat Dec(d) until counts[d] <> 0;
    end;
    Dec(counts[d]); Inc(counts[d + 1], 2);
  end;
  AssignSorted(syms, nu, counts, maxLen, lens);
end;

{ miniz's tdefl_optimize_huffman_table: Moffat and Katajainen's in-place
  lengths of the sorted counts (16-bit sums, as miniz keeps them), then
  tdefl_huffman_enforce_max_code_size, the lengths given in sorted order;
  one symbol used: it gets 1 }
procedure LensMiniz(const freq: array of Integer; n, maxLen: Integer; var lens: array of Byte);
const MAXC = 32;
var syms: TFreqs; nu, i, rt, leaf, next, avbl, used, dpth: Integer; total: LongWord;
  a: array[0..287] of Word;
  counts: array[0..MAXC] of Integer;
begin
  for i := 0 to n - 1 do lens[i] := 0;
  SortedSyms(freq, n, syms, nu);
  if nu = 0 then Exit;
  if nu = 1 then begin lens[syms[0]] := 1; Exit; end;
  for i := 0 to nu - 1 do a[i] := Word(freq[syms[i]]);
  {$push}{$R-}{$Q-}
  a[0] := Word(a[0] + a[1]);
  rt := 0; leaf := 2;
  for next := 1 to nu - 2 do begin
    if (leaf >= nu) or (a[rt] < a[leaf]) then begin
      a[next] := a[rt]; a[rt] := Word(next); Inc(rt);
    end else begin
      a[next] := a[leaf]; Inc(leaf);
    end;
    if (leaf >= nu) or ((rt < next) and (a[rt] < a[leaf])) then begin
      a[next] := Word(a[next] + a[rt]); a[rt] := Word(next); Inc(rt);
    end else begin
      a[next] := Word(a[next] + a[leaf]); Inc(leaf);
    end;
  end;
  {$pop}
  a[nu - 2] := 0;
  for next := nu - 3 downto 0 do a[next] := a[a[next]] + 1;
  avbl := 1; used := 0; dpth := 0; rt := nu - 2; next := nu - 1;
  while avbl > 0 do begin
    while (rt >= 0) and (a[rt] = dpth) do begin Inc(used); Dec(rt); end;
    while avbl > used do begin a[next] := dpth; Dec(next); Dec(avbl); end;
    avbl := 2 * used; Inc(dpth); used := 0;
  end;
  for i := 0 to MAXC do counts[i] := 0;
  for i := 0 to nu - 1 do
    if a[i] <= MAXC then Inc(counts[a[i]]) else Inc(counts[MAXC]);
  for i := maxLen + 1 to MAXC do Inc(counts[maxLen], counts[i]);
  total := 0;
  for i := maxLen downto 1 do Inc(total, LongWord(counts[i]) shl (maxLen - i));
  while total <> (LongWord(1) shl maxLen) do begin
    Dec(counts[maxLen]);
    for i := maxLen - 1 downto 1 do
      if counts[i] <> 0 then begin Dec(counts[i]); Inc(counts[i + 1], 2); Break; end;
    Dec(total);
  end;
  AssignSorted(syms, nu, counts, maxLen, lens);
end;

{ optimal lengths of at most maxLen bits (package-merge; of equal weights a
  package before a leaf, as zopfli's boundary package-merge takes them),
  given in sorted order; one symbol used: 1; two: 1 and 1 }
procedure LensPM(const freq: array of Integer; n, maxLen: Integer; var lens: array of Byte);
var syms: TFreqs; nu, i, j, lv, np, k, x, y, m: Integer;
  w: array[0..287] of Int64;
  lw: array[0..15, 0..575] of Int64;      { each level's list: weights }
  isLeaf: array[0..15, 0..575] of Boolean;
  ln: array[0..15] of Integer;
  cnt: array[0..15] of Integer;           { the leaves used at each level }
  counts: array[0..15] of Integer;
begin
  for i := 0 to n - 1 do lens[i] := 0;
  SortedSyms(freq, n, syms, nu);
  if nu = 0 then Exit;
  if nu <= 2 then begin for i := 0 to nu - 1 do lens[syms[i]] := 1; Exit; end;
  if nu - 1 < maxLen then m := nu - 1 else m := maxLen;
  for i := 0 to nu - 1 do w[i] := freq[syms[i]];
  for i := 0 to nu - 1 do begin lw[1, i] := w[i]; isLeaf[1, i] := True; end;
  ln[1] := nu;
  for lv := 2 to m do begin
    np := ln[lv - 1] div 2;
    x := 0; y := 0; k := 0;
    while (x < np) or (y < nu) do begin
      if (x < np) and ((y >= nu) or (lw[lv - 1, 2 * x] + lw[lv - 1, 2 * x + 1] <= w[y])) then begin
        lw[lv, k] := lw[lv - 1, 2 * x] + lw[lv - 1, 2 * x + 1]; isLeaf[lv, k] := False; Inc(x);
      end else begin
        lw[lv, k] := w[y]; isLeaf[lv, k] := True; Inc(y);
      end;
      Inc(k);
    end;
    ln[lv] := k;
  end;
  { the first 2n - 2 of the last list, and down: the leaves each level uses }
  k := 2 * nu - 2;
  for lv := m downto 1 do begin
    if k > ln[lv] then k := ln[lv];
    cnt[lv] := 0;
    for j := 0 to k - 1 do if isLeaf[lv, j] then Inc(cnt[lv]);
    k := 2 * (k - cnt[lv]);
  end;
  for i := 0 to 15 do counts[i] := 0;
  for i := 0 to nu - 1 do begin
    j := 0;
    for lv := 1 to m do if i < cnt[lv] then Inc(j);
    Inc(counts[j]);
  end;
  AssignSorted(syms, nu, counts, m, lens);
end;

const
  TB_ZLIB = 0;
  TB_LIBDEFLATE = 1;
  TB_MINIZ = 2;
  TB_PM = 3;
  TB_ZOPFLI = 4;
  TB_LAST = TB_ZOPFLI;

{ zopfli's OptimizeHuffmanForRle: counts[0..length-1] evened out where
  that makes runs (the strides that are not already runs, of 4 or more
  counts within 4 of their average, take their rounded mean) }
procedure EvenForRle(length: Integer; var counts: array of Int64);
var i, k, stride: Integer; symbol, sum, limit, cnt: Int64; good: array[0..287] of Boolean;
begin
  while (length > 0) and (counts[length - 1] = 0) do Dec(length);
  if length = 0 then Exit;
  for i := 0 to length - 1 do good[i] := False;
  symbol := counts[0]; stride := 0;
  for i := 0 to length do
    if (i = length) or (counts[i] <> symbol) then begin
      if ((symbol = 0) and (stride >= 5)) or ((symbol <> 0) and (stride >= 7)) then
        for k := 0 to stride - 1 do good[i - k - 1] := True;
      stride := 1;
      if i <> length then symbol := counts[i];
    end else Inc(stride);
  stride := 0; limit := counts[0]; sum := 0;
  for i := 0 to length do begin
    if (i = length) or good[i] or (Abs(counts[i] - limit) >= 4) then begin
      if (stride >= 4) or ((stride >= 3) and (sum = 0)) then begin
        cnt := (sum + stride div 2) div stride;
        if cnt < 1 then cnt := 1;
        if sum = 0 then cnt := 0;
        for k := 0 to stride - 1 do counts[i - k - 1] := cnt;
      end;
      stride := 0; sum := 0;
      if i < length - 3 then limit := (counts[i] + counts[i + 1] + counts[i + 2] + counts[i + 3] + 2) div 4
      else if i < length then limit := counts[i]
      else limit := 0;
    end;
    Inc(stride);
    if i <> length then Inc(sum, counts[i]);
  end;
end;

{ zopfli's PatchDistanceCodesForBuggyDecoders: two distance codes at least }
procedure PatchDist(var dl: TLens);
var i, nd: Integer;
begin
  nd := 0;
  for i := 0 to 29 do if dl[i] <> 0 then Inc(nd);
  if nd = 0 then begin dl[0] := 1; dl[1] := 1; end
  else if nd = 1 then begin if dl[0] <> 0 then dl[1] := 1 else dl[0] := 1; end;
end;

function SeqZopfli(const lens: array of Byte; total: Integer; u16, u17, u18: Boolean; var seq: array of Word;
  var nSeq: Integer): SizeInt; forward;

{ zopfli's CalculateTreeSize: the smallest of its 8 codings, in bits }
function ZopfliTreeSize(const ll, dl: array of Byte): SizeInt;
var lens: array[0..315] of Byte; seq: array[0..316] of Word; hl, hd, i, k, nSeq: Integer; sz: SizeInt;
begin
  hl := 286; while (hl > 257) and (ll[hl - 1] = 0) do Dec(hl);
  hd := 30; while (hd > 1) and (dl[hd - 1] = 0) do Dec(hd);
  for i := 0 to hl - 1 do lens[i] := ll[i];
  for i := 0 to hd - 1 do lens[hl + i] := dl[i];
  Result := 0;
  for k := 0 to 7 do begin
    sz := SeqZopfli(lens, hl + hd, (k and 1) <> 0, (k and 2) <> 0, (k and 4) <> 0, seq, nSeq);
    if (Result = 0) or (sz < Result) then Result := sz;
  end;
end;

{ zopfli's TryOptimizeHuffmanForRle: the lengths of the counts evened out
  for runs, when the tree and the symbols then take fewer bits }
procedure ZopfliRle(const lf: TFreqs; const df: array of Integer; var ll: TLens; var dl: TLens);
var c2: array[0..287] of Int64; d2: array[0..31] of Int64; f: TFreqs; fd: array[0..31] of Integer;
  ll2, dl2: TLens; i: Integer; s1, s2: SizeInt;

  function DataBits(const l1, l2: TLens): SizeInt;
  var i: Integer;
  begin
    Result := l1[256];
    for i := 0 to 285 do if i <> 256 then Inc(Result, SizeInt(l1[i]) * lf[i]);
    for i := 0 to 29 do Inc(Result, SizeInt(l2[i]) * df[i]);
  end;

begin
  for i := 0 to 287 do c2[i] := lf[i];
  for i := 0 to 31 do d2[i] := df[i];
  EvenForRle(288, c2); EvenForRle(32, d2);
  for i := 0 to 287 do f[i] := Integer(c2[i]);
  for i := 0 to 31 do fd[i] := Integer(d2[i]);
  FillChar(ll2, SizeOf(ll2), 0); FillChar(dl2, SizeOf(dl2), 0);
  LensPM(f, 288, 15, ll2);
  LensPM(fd, 32, 15, dl2);
  PatchDist(dl2);
  s1 := ZopfliTreeSize(ll, dl) + DataBits(ll, dl);
  s2 := ZopfliTreeSize(ll2, dl2) + DataBits(ll2, dl2);
  if s2 < s1 then begin ll := ll2; dl := dl2; end;
end;

{ a block's literal/length and distance code lengths by builder tb, from
  its symbol counts (lfreq[256] counted), into b.litLen and b.distLen }
procedure TreesBy(tb: Integer; const lfreq, dfreq: array of Integer; var b: TDeflateBlock);
var lf: TFreqs; df: array[0..31] of Integer; i: Integer; fx: Boolean; dl, ll: TLens;
begin
  if tb = TB_ZLIB then begin ZlibTrees(lfreq, dfreq, b, fx); Exit; end;
  for i := 0 to 287 do if i <= 285 then lf[i] := lfreq[i] else lf[i] := 0;
  for i := 0 to 31 do if i <= 29 then df[i] := dfreq[i] else df[i] := 0;
  FillChar(b.litLen, SizeOf(b.litLen), 0); FillChar(b.distLen, SizeOf(b.distLen), 0);
  FillChar(dl, SizeOf(dl), 0);
  case tb of
    TB_LIBDEFLATE: begin
      LensLibdeflate(lf, 288, 14, b.litLen);
      LensLibdeflate(df, 30, 15, dl);
    end;
    TB_MINIZ: begin
      LensMiniz(lf, 288, 15, b.litLen);
      LensMiniz(df, 32, 15, dl);
    end;
  else begin
      FillChar(ll, SizeOf(ll), 0);
      LensPM(lf, 288, 15, ll);
      LensPM(df, 30, 15, dl);
      PatchDist(dl);
      if tb = TB_ZOPFLI then ZopfliRle(lf, df, ll, dl);
      for i := 0 to 287 do b.litLen[i] := ll[i];
    end;
  end;
  for i := 0 to 29 do b.distLen[i] := dl[i];
end;

{ the code-length code by builder tb over the run-length symbols' counts }
procedure ClenBy(tb: Integer; const sfreq: array of Integer; out clen: array of Byte);
var f: TFreqs; i, h: Integer; l: TLens;
begin
  if tb = TB_ZLIB then begin ZlibBlTree(sfreq, clen, h); Exit; end;
  for i := 0 to 287 do if i <= 18 then f[i] := sfreq[i] else f[i] := 0;
  FillChar(l, SizeOf(l), 0);
  case tb of
    TB_LIBDEFLATE: LensLibdeflate(f, 19, 7, l);
    TB_MINIZ: LensMiniz(f, 19, 7, l);
  else LensPM(f, 19, 7, l);
  end;
  for i := 0 to 18 do clen[i] := l[i];
end;

{ run-length codings of lens[0..total-1] (both trees at once) into seq
  (ppadeflate's clenSeq: symbol | extra << 5) }

{ libdeflate's deflate_compute_precode_items }
procedure SeqLibdeflate(const lens: array of Byte; total: Integer; var seq: array of Word; var nSeq: Integer);
var rs, re, x: Integer; len: Byte;
begin
  nSeq := 0; rs := 0;
  while rs < total do begin
    len := lens[rs]; re := rs;
    repeat Inc(re) until (re = total) or (lens[re] <> len);
    if len = 0 then begin
      while re - rs >= 11 do begin
        x := re - rs - 11; if x > $7F then x := $7F;
        seq[nSeq] := 18 or (x shl 5); Inc(nSeq); Inc(rs, 11 + x);
      end;
      if re - rs >= 3 then begin
        x := re - rs - 3; if x > 7 then x := 7;
        seq[nSeq] := 17 or (x shl 5); Inc(nSeq); Inc(rs, 3 + x);
      end;
    end else if re - rs >= 4 then begin
      seq[nSeq] := len; Inc(nSeq); Inc(rs);
      repeat
        x := re - rs - 3; if x > 3 then x := 3;
        seq[nSeq] := 16 or (x shl 5); Inc(nSeq); Inc(rs, 3 + x);
      until re - rs < 3;
    end;
    while rs <> re do begin seq[nSeq] := len; Inc(nSeq); Inc(rs); end;
  end;
end;

{ miniz's tdefl_start_dynamic_block }
procedure SeqMiniz(const lens: array of Byte; total: Integer; var seq: array of Word; var nSeq: Integer);
var i, zc, rc, prev, cs: Integer;

  procedure FlushPrev;
  begin
    if rc = 0 then Exit;
    if rc < 3 then while rc > 0 do begin seq[nSeq] := prev; Inc(nSeq); Dec(rc); end
    else begin seq[nSeq] := 16 or ((rc - 3) shl 5); Inc(nSeq); end;
    rc := 0;
  end;

  procedure FlushZero;
  begin
    if zc = 0 then Exit;
    if zc < 3 then while zc > 0 do begin seq[nSeq] := 0; Inc(nSeq); Dec(zc); end
    else if zc <= 10 then begin seq[nSeq] := 17 or ((zc - 3) shl 5); Inc(nSeq); end
    else begin seq[nSeq] := 18 or ((zc - 11) shl 5); Inc(nSeq); end;
    zc := 0;
  end;

begin
  nSeq := 0; zc := 0; rc := 0; prev := $FF;
  for i := 0 to total - 1 do begin
    cs := lens[i];
    if cs = 0 then begin
      FlushPrev;
      Inc(zc);
      if zc = 138 then FlushZero;
    end else begin
      FlushZero;
      if cs <> prev then begin
        FlushPrev;
        seq[nSeq] := cs; Inc(nSeq);
      end else begin
        Inc(rc);
        if rc = 6 then FlushPrev;
      end;
    end;
    prev := cs;
  end;
  if rc <> 0 then FlushPrev else FlushZero;
end;

{ zopfli's EncodeTree with use16, use17, use18; its size in bits (the
  code-length code by package-merge over the counts) }
function SeqZopfli(const lens: array of Byte; total: Integer; u16, u17, u18: Boolean; var seq: array of Word;
  var nSeq: Integer): SizeInt;
var i, j, cnt, c2, hclen: Integer; sym: Byte; cc: array[0..18] of Integer; cl: array[0..18] of Byte;
const ORD: array[0..18] of Byte = (16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15);
begin
  nSeq := 0;
  FillChar(cc, SizeOf(cc), 0);
  i := 0;
  while i < total do begin
    sym := lens[i]; cnt := 1;
    if u16 or ((sym = 0) and (u17 or u18)) then begin
      j := i + 1;
      while (j < total) and (lens[j] = sym) do begin Inc(cnt); Inc(j); end;
    end;
    Inc(i, cnt);
    if (sym = 0) and (cnt >= 3) then begin
      if u18 then
        while cnt >= 11 do begin
          if cnt > 138 then c2 := 138 else c2 := cnt;
          seq[nSeq] := 18 or ((c2 - 11) shl 5); Inc(nSeq); Inc(cc[18]); Dec(cnt, c2);
        end;
      if u17 then
        while cnt >= 3 do begin
          if cnt > 10 then c2 := 10 else c2 := cnt;
          seq[nSeq] := 17 or ((c2 - 3) shl 5); Inc(nSeq); Inc(cc[17]); Dec(cnt, c2);
        end;
    end;
    if u16 and (cnt >= 4) then begin
      Dec(cnt);
      Inc(cc[sym]); seq[nSeq] := sym; Inc(nSeq);
      while cnt >= 3 do begin
        if cnt > 6 then c2 := 6 else c2 := cnt;
        seq[nSeq] := 16 or ((c2 - 3) shl 5); Inc(nSeq); Inc(cc[16]); Dec(cnt, c2);
      end;
    end;
    Inc(cc[sym], cnt);
    while cnt > 0 do begin seq[nSeq] := sym; Inc(nSeq); Dec(cnt); end;
  end;
  ClenBy(TB_PM, cc, cl);
  hclen := 15;
  while (hclen > 0) and (cc[ORD[hclen + 4 - 1]] = 0) do Dec(hclen);
  Result := 14 + (hclen + 4) * 3 + 2 * cc[16] + 3 * cc[17] + 7 * cc[18];
  for i := 0 to 18 do Inc(Result, SizeInt(cl[i]) * cc[i]);
end;

{ zopfli's AddDynamicTree: the smallest of its 8 codings (the first of as
  small) }
procedure SeqZopfliBest(const lens: array of Byte; total: Integer; var seq: array of Word; var nSeq: Integer);
var k, best: Integer; sz, bestSz: SizeInt;
begin
  best := 0; bestSz := 0;
  for k := 0 to 7 do begin
    sz := SeqZopfli(lens, total, (k and 1) <> 0, (k and 2) <> 0, (k and 4) <> 0, seq, nSeq);
    if (bestSz = 0) or (sz < bestSz) then begin bestSz := sz; best := k; end;
  end;
  SeqZopfli(lens, total, (best and 1) <> 0, (best and 2) <> 0, (best and 4) <> 0, seq, nSeq);
end;

{ ---------------------------------------------------------------- the driver }

function MaxI(a, b: SizeInt): SizeInt; inline;
begin
  if a > b then Result := a else Result := b;
end;

function MinI(a, b: SizeInt): SizeInt; inline;
begin
  if a < b then Result := a else Result := b;
end;

function LenBucket(l: SizeInt): Integer;
begin
  case l of
    0: Result := 0;
    3: Result := 1;
    4..5: Result := 2;
    6..8: Result := 3;
    9..16: Result := 4;
    17..64: Result := 5;
    65..257: Result := 6;
  else Result := 7;
  end;
end;

{ whether lens[0..n-1] is a code no symbol of which is longer than 15
  bits and that is not over-subscribed (what ppadeflate's decoder takes) }
function KraftOk(const lens: array of Byte; n: Integer): Boolean;
var count: array[0..15] of Integer; i, left: Integer;
begin
  Result := False;
  FillChar(count, SizeOf(count), 0);
  for i := 0 to n - 1 do begin
    if lens[i] > 15 then Exit;
    Inc(count[lens[i]]);
  end;
  left := 1;
  for i := 1 to 15 do begin
    left := left * 2 - count[i];
    if left < 0 then Exit;
  end;
  Result := True;
end;

function PredValid(const p: TPredParams): Boolean;
begin
  Result := (p.predVersion = PRED_VERSION) and (p.chain >= 1) and (p.chain <= PRED_MAX_CHAIN) and
    (p.nice >= MIN_MATCH) and (p.nice <= MAX_MATCH) and
    ((p.lazy = 0) or ((p.lazy >= MIN_MATCH) and (p.lazy <= MAX_MATCH))) and
    (p.good >= MIN_MATCH) and (p.good <= MAX_MATCH) and (p.hbits >= 8) and (p.hbits <= 16) and
    (p.maxDist >= 1) and (p.maxDist <= WINDOW) and (p.flags >= 0) and (p.flags <= PF_ALL) and
    (p.symEnd >= 0) and (p.symEnd <= PRED_MAX_SYMEND) and (p.tree >= 0) and (p.tree <= PRED_TREE_LAST);
end;

type
  TDriveOut = record
    { decoding: where the blocks go }
    w: TDeflWriter;
    frame: TZStream;     { the plain, the framing; tokens of the block in hand }
  end;

const
  MEMO_NONE = High(LongWord);
  LOCAL_MEMO = 8;

procedure CorrMemoInit(out m: TLongMemo; n: SizeInt);
begin
  m.n := n;
  m.long := nil; m.lx1 := nil;
  if n <= 0 then Exit;
  SetLength(m.long, n); SetLength(m.lx1, n);
  FillDWord(m.long[0], n, MEMO_NONE); FillDWord(m.lx1[0], n, MEMO_NONE);
end;

{ The one driver of encoding and decoding. Encoding: z is the stream
  (blocks, tokens, plain), its choices coded into c.ae; stopTokens as
  CorrEncode's. Decoding: z.plain is the plain, the blocks are written
  into o.w as they come. False: corrections that give no stream. }
function Drive(var c: TCoder; const z: TZStream; const prm: TPredParams; stopTokens: SizeInt;
  var o: TDriveOut; memo: PLongMemo = nil): Boolean;
var
  m: TModels;
  mx: TMixers;
  s: TPredState;
  head, prev, ordA, hcnt, head4, link4, runsA, head3, link3: array of LongInt;
  plain: PByte;
  n, p, bi, nBlocks, maxBlocks, t, rt, nTokB, cap: SizeInt;
  rb, b: TDeflateBlock;
  prevType, lastTokens, lastMiss, lastSel, lastTreeSame, hist, lastLB: Integer;
  cachePos, cacheLen, cacheDist: SizeInt;
  lfreq: array[0..285] of Integer;
  dfreq: array[0..29] of Integer;
  isStored, isEnd, isDyn, fixedNoBigger, final: Boolean;
  maxLen, len, k, lg: SizeInt;
  tokLen, tokVal: array of Word;   { decoding: the block's tokens }
  { LongestM's last few, by position (and LX1_HOPS or not) }
  localPos: array[0..2 * LOCAL_MEMO - 1] of SizeInt;
  localVal: array[0..2 * LOCAL_MEMO - 1] of LongWord;
  cLit: array[0..255] of Byte;     { the previous block's code lengths (12 for none) }
  cLen: array[257..285] of Byte;
  cDist: array[0..29] of Byte;
  pb: TDeflateBlock;

  procedure SetCosts(const bb: TDeflateBlock);
  var i: Integer;
  begin
    for i := 0 to 255 do
      if bb.btype = btFixed then begin if i < 144 then cLit[i] := 8 else cLit[i] := 9; end
      else if bb.litLen[i] = 0 then cLit[i] := 12 else cLit[i] := bb.litLen[i];
    for i := 257 to 285 do
      if bb.btype = btFixed then begin if i < 280 then cLen[i] := 7 else cLen[i] := 8; end
      else if bb.litLen[i] = 0 then cLen[i] := 12 else cLen[i] := bb.litLen[i];
    for i := 0 to 29 do
      if bb.btype = btFixed then cDist[i] := 5
      else if bb.distLen[i] = 0 then cDist[i] := 12 else cDist[i] := bb.distLen[i];
  end;

  procedure Grow(need: SizeInt);
  begin
    if need > Length(tokLen) then begin
      cap := 2 * Length(tokLen) + 1024;
      if cap < need then cap := need;
      SetLength(tokLen, cap); SetLength(tokVal, cap);
    end;
  end;

  { Longest, through the memo where it has q, else the last few asked
    (a position is asked again: p + 1's is the next literal's p, and a
    missed match's reference is often the prediction's own) }
  function LongestM(q, hops: SizeInt; out dist: SizeInt): SizeInt;
  var v: LongWord; pv: PLongWord; slot: SizeInt;
  begin
    if (memo <> nil) and (q < memo^.n) then begin
      if hops = LX1_HOPS then pv := @memo^.lx1[q] else pv := @memo^.long[q];
      v := pv^;
      if v = MEMO_NONE then begin
        Result := Longest(s, q, hops, dist);
        pv^ := (LongWord(Result) shl 16) or LongWord(dist);
      end else begin
        Result := v shr 16; dist := v and $FFFF;
      end;
      Exit;
    end;
    slot := (q and (LOCAL_MEMO - 1)) * 2 + Ord(hops = LX1_HOPS);
    if localPos[slot] = q then begin
      Result := localVal[slot] shr 16; dist := localVal[slot] and $FFFF;
      Exit;
    end;
    Result := Longest(s, q, hops, dist);
    localPos[slot] := q;
    localVal[slot] := (LongWord(Result) shl 16) or LongWord(dist);
  end;

  { the predicted token at p: pl 0 a literal, else a match (pl, pd); av
    the longest match the search found at p (0: none), l2 the lazy one at
    p + 1 (-1: not looked for) }
  procedure Predict(out pl, pd, av, ad, l2: SizeInt);
  var l1, d1, d2: SizeInt;
  begin
    pl := 0; pd := 0; l2 := -1;
    if cachePos = p then begin l1 := cacheLen; d1 := cacheDist; end
    else begin
      if (prm.flags and PF_LONGEST) <> 0 then l1 := LongestM(p, LONG_HOPS, d1)
      else l1 := Search(s, p, MIN_MATCH - 1, d1);
      if (prm.lazy > 0) and (l1 > 0) and (l1 <= 5) and (((prm.flags and PF_FILTERED) <> 0) or
         ((l1 = MIN_MATCH) and (d1 > TOO_FAR) and ((prm.flags and PF_TOOFAR) <> 0))) then l1 := 0;
    end;
    av := l1; ad := d1;
    cachePos := -1;
    if l1 < MIN_MATCH then Exit;
    if (prm.lazy = 0) or (l1 >= prm.lazy) then begin pl := l1; pd := d1; Exit; end;
    if (prm.flags and PF_LONGEST) <> 0 then begin
      l2 := LongestM(p + 1, LONG_HOPS, d2);
      if l2 <= l1 then l2 := 0;
    end else
      l2 := Search(s, p + 1, l1, d2);
    if (l2 > 0) and (l2 <= 5) and ((prm.flags and PF_FILTERED) <> 0) then l2 := 0;
    if l2 > l1 then begin
      cachePos := p + 1; cacheLen := l2; cacheDist := d2;
      Exit;   { a literal }
    end;
    pl := l1; pd := d1;
  end;

  { v >= 1 as an exponent (unary, models ue[0..maxE]) and its low bits
    (models um: GOLOMB_STRIDE for each exponent 0..maxE, by the bits so far,
    the first 6, then by position): False past maxE }
  function DoGolomb(var ue: array of TPBit; um: PPBit; maxE: Integer; var v: SizeInt): Boolean;
  var e, k, node, b: SizeInt;
  begin
    Result := False;
    e := 0;
    if c.enc then while (SizeInt(2) shl e) <= v do Inc(e);
    k := 0;
    while c.Bit(ue[k], Ord(k < e)) <> 0 do begin
      Inc(k);
      if k > maxE then Exit;
    end;
    e := k;
    node := 1;
    for k := e - 1 downto 0 do begin
      if node < 64 then b := c.Bit(um[e * GOLOMB_STRIDE + node], (v shr k) and 1)
      else b := c.Bit(um[e * GOLOMB_STRIDE + 64 + k], (v shr k) and 1);
      node := 2 * node + b;
    end;
    v := node;
    Result := True;
  end;

  { one token at p: coded against the prediction; decoding, into the
    block's tokens. False on one that cannot be }
  function DoToken(realLen, realVal: SizeInt): Boolean;
  var sR, sL, bot, top, node, b1, k, ad, cb, ls, mc, lx1: SizeInt;
    pl, pd, av, l2, bk, bk2, bkR, hit, rl, rd, as284, L, D, ref, cs, kk, rk, rbk, v, lb, dir, i: SizeInt;
  begin
    Result := False;
    Predict(pl, pd, av, ad, l2);
    bk := LenBucket(pl);
    { the longest match against its bytes as literals, in the previous
      block's code lengths }
    cb := 0;
    if av >= MIN_MATCH then begin
      mc := cLen[LenSym[av]] + LEN_EXTRA[LenSym[av]] + cDist[DistSym[ad]] + DIST_EXTRA[DistSym[ad]];
      k := av; if k > 32 then k := 32;
      ls := 0;
      for i := 0 to k - 1 do Inc(ls, cLit[plain[p + i]]);
      ls := ls - mc;
      if ls < -8 then cb := 1 else if ls < -3 then cb := 2 else if ls < 0 then cb := 3
      else if ls < 2 then cb := 4 else if ls < 4 then cb := 5 else if ls < 8 then cb := 6
      else if ls < 16 then cb := 7 else cb := 8;
    end;
    if l2 < 0 then bk2 := 8 else bk2 := LenBucket(l2);
    as284 := 0; rl := 0; rd := 0;
    if c.enc then begin
      rl := realLen; rd := realVal;
      if rl = LEN_258_AS_284 then begin rl := MAX_MATCH; as284 := 1; end;
    end;
    c.cat := 2;
    c.inp[0] := @m.hit0[bk * 2 + lastMiss];
    c.inp[1] := @m.hit1[hist * 8 + bk];
    c.inp[2] := @m.hit2[(LenBucket(av) * 9 + bk2) * 2 + Ord(pl > 0)];
    c.inp[3] := @m.hit3[lastLB * 8 + bk];
    c.inp[4] := @m.hit4[plain[p] + 256 * Ord(pl > 0)];
    c.inp[5] := @m.hit5[cb * 8 + bk];
    if l2 >= 0 then lx1 := l2
    else if (p + 1 < n) and (av > 0) then begin
      lx1 := LongestM(p + 1, LX1_HOPS, k);
    end else lx1 := 0;
    c.inp[6] := @m.hit6[(LenBucket(lx1) * 8 + LenBucket(av)) * 2 + Ord(pl > 0)];
    hit := c.MixBit(mx.hit[bk], 7, Ord((rl = pl) and ((pl = 0) or (rd = pd))));
    if hit <> 0 then begin
      L := pl; D := pd;
    end else begin
      L := -1; D := 0;
      if pl > 0 then begin
        c.cat := 3;
        c.inp[0] := @m.lit0[bk * 2 + lastMiss];
        c.inp[1] := @m.lit1[hist * 8 + bk];
        c.inp[2] := @m.lit2[bk2 * 8 + bk];
        c.inp[3] := @m.lit3[plain[p]];
        c.inp[4] := @m.lit4[cb * 8 + bk];
        c.inp[5] := @m.lit5[LenBucket(lx1) * 8 + bk];
        if c.MixBit(mx.lit[bk], 6, Ord(rl = 0)) <> 0 then L := 0;
      end;
      if L <> 0 then begin
        { a match: its length against a reference, the longest match
          there (the predicted length when longer), then its distance's
          rank among the candidates at least that long }
        ref := LongestM(p, LONG_HOPS, k);
        if ref < pl then ref := pl;
        if ref = 0 then cs := 3
        else if pl = ref then cs := 0
        else if pl > 0 then cs := 1
        else cs := 2;
        bkR := LenBucket(ref);
        if cs = 0 then c.cat := 4 else c.cat := 15;
        dir := 2;
        if ref > 0 then begin
          c.inp[0] := @m.eq0[(cs * 8 + bkR) * 2 + lastMiss];
          c.inp[1] := @m.eq1[hist * 32 + cs * 8 + bkR];
          c.inp[2] := @m.eq2[bk2 * 32 + cs * 8 + bkR];
          c.inp[3] := @m.eq3[cs, ref];
          c.inp[4] := @m.eq4[cb * 4 + cs];
          if c.MixBit(mx.eq[cs], 5, Ord(rl = ref)) <> 0 then L := ref
          else if (cs = 1) and (c.Bit(m.eqP[bkR * 8 + bk], Ord(rl = pl)) <> 0) then L := pl
          else begin
            c.inp[0] := @m.dir0[cs * 8 + bkR];
            c.inp[1] := @m.dir1[cs, ref];
            dir := c.MixBit(mx.dir[cs], 2, Ord(rl > ref));
          end;
        end;
        if (L < 0) and (dir = 0) then begin
          { shorter: its length symbol, below the reference's, then where
            in the symbol's lengths (the top one most often) }
          c.cat := 14;
          sR := LenSym[ref]; sL := sR;
          if c.enc then sL := LenSym[rl];
          k := 0;
          while (sR - k > 257) and (c.Bit(m.sDown[sR - 257, MinI(k, 7)], Ord(sR - k > sL)) <> 0) do Inc(k);
          sL := sR - k;
          bot := LEN_BASE[sL]; top := bot + (1 shl LEN_EXTRA[sL]) - 1;
          if sL = 285 then top := bot;
          if top >= ref then top := ref - 1;
          if top < bot then Exit;
          L := top;
          if top > bot then begin
            if c.Bit(m.sTop[MinI(k, 2), sL - 257], Ord(rl = top)) = 0 then begin
              v := 0; node := 1;
              for i := 4 downto 0 do
                if (top - 1 - bot) shr i <> 0 then begin
                  b1 := c.Bit(m.sOff[sL - 257, node], ((top - 1 - rl) shr i) and 1);
                  node := 2 * node + b1;
                  v := 2 * v + b1;
                end;
              L := top - 1 - v;
              if L < bot then Exit;
            end;
          end;
        end;
        if L < 0 then begin
          c.cat := 14;
          case dir of
            0: v := ref - rl;
            1: v := rl - ref;
          else v := rl - MIN_MATCH + 1;
          end;
          if not DoGolomb(m.lexp[dir, bkR], @m.lmant[dir, 0, 0], 9, v) then Exit;
          case dir of
            0: L := ref - v;
            1: L := ref + v;
          else L := MIN_MATCH - 1 + v;
          end;
          if (L < MIN_MATCH) or (L > MAX_MATCH) then Exit;
        end;
        if L > n - p then Exit;
        if L <= 8 then lb := 0 else if L <= 32 then lb := 1 else lb := 2;
        rbk := RANK_ESC; rk := -1;
        if c.enc then begin
          rk := Rank(s, p, L, rd, 0);
          if rk >= 0 then begin
            rbk := 0;
            while (SizeInt(2) shl rbk) <= rk + 1 do Inc(rbk);
          end;
        end;
        { the bucket, unary: bucket k holds ranks 2^k - 1 .. 2^(k+1) - 2 }
        kk := 0; c.cat := 5;
        while (kk < RANK_ESC) and (c.Bit(m.rankK[lb, kk], Ord(rbk = kk)) = 0) do Inc(kk);
        c.cat := 6;
        if kk = RANK_ESC then begin
          v := rd;
          if not DoGolomb(m.escE, @m.escM[0, 0], 15, v) then Exit;
          D := v;
          if (D > p) or (D > WINDOW) then Exit;
          for i := 0 to L - 1 do
            if plain[p - D + i] <> plain[p + i] then Exit;
        end else begin
          v := 0;
          for i := kk - 1 downto 0 do
            v := 2 * v + c.Bit(m.rankM[kk, i], ((rk + 1 - (SizeInt(1) shl kk)) shr i) and 1);
          rk := (SizeInt(1) shl kk) - 1 + v;
          if c.enc then D := rd
          else begin
            D := Rank(s, p, L, rk, 1);
            if D <= 0 then Exit;
          end;
        end;
      end;
    end;
    c.cat := 7; if L = MAX_MATCH then as284 := c.Bit(m.as284, as284);
    lastMiss := 1 - hit;
    hist := ((hist shl 1) or hit) and 15;
    lastLB := LenBucket(L);
    { the token }
    if L = 0 then begin
      if not c.enc then begin
        Grow(nTokB + 1);
        tokLen[nTokB] := 0; tokVal[nTokB] := plain[p];
      end;
      Inc(lfreq[plain[p]]);
      Inc(p);
    end else begin
      if not c.enc then begin
        Grow(nTokB + 1);
        if as284 <> 0 then tokLen[nTokB] := LEN_258_AS_284 else tokLen[nTokB] := L;
        tokVal[nTokB] := D;
      end;
      if as284 <> 0 then Inc(lfreq[284]) else Inc(lfreq[LenSym[L]]);
      Inc(dfreq[DistSym[D]]);
      Inc(p, L);
    end;
    Inc(nTokB);
    Result := True;
  end;
  { the explicit run-length coding of lens[0..total-1] }
  function DoSeqExplicit(const lens: array of Byte; total: Integer; var seq: array of Word; var nSeq: Integer;
    const rseq: array of Word): Boolean;
  var i, v, zr, pr, cls, rcls, rcnt, ctx, cnt, lo, hi, prevCls, bits: Integer; a16, a17, a18: Boolean;
  begin
    Result := False;
    i := 0; nSeq := 0; prevCls := 0;
    while i < total do begin
      v := lens[i];
      zr := 0;
      if v = 0 then while (i + zr < total) and (zr < 138) and (lens[i + zr] = 0) do Inc(zr);
      pr := 0;
      if i > 0 then while (i + pr < total) and (pr < 6) and (lens[i + pr] = lens[i - 1]) do Inc(pr);
      a16 := pr >= 3; a17 := zr >= 3; a18 := zr >= 11;
      rcls := 0; rcnt := 1;
      if c.enc then begin
        if nSeq > High(rseq) then Exit;
        rcls := rseq[nSeq] and $1F;
        if rcls < 16 then rcls := 0;
        case rcls of
          16: rcnt := 3 + rseq[nSeq] shr 5;
          17: rcnt := 3 + rseq[nSeq] shr 5;
          18: rcnt := 11 + rseq[nSeq] shr 5;
        end;
      end;
      cls := 0;
      if a16 or a17 then begin
        if a18 then ctx := 2 else ctx := 1;
        ctx := (prevCls * 2 + Ord(v = 0)) * 3 + ctx;
        if c.Bit(m.seqLit[ctx], Ord(rcls = 0)) = 0 then begin
          if a16 and a17 then begin
            if c.Bit(m.seq16, Ord(rcls = 16)) <> 0 then cls := 16
            else if a18 and (c.Bit(m.seq18, Ord(rcls = 18)) <> 0) then cls := 18
            else cls := 17;
          end else if a16 then cls := 16
          else if a18 and (c.Bit(m.seq18, Ord(rcls = 18)) <> 0) then cls := 18
          else cls := 17;
        end;
      end;
      if cls = 0 then begin
        seq[nSeq] := v; Inc(nSeq); Inc(i);
        prevCls := 0;
        Continue;
      end;
      case cls of
        16: begin lo := 3; hi := pr; bits := 2; end;
        17: begin lo := 3; hi := zr; if hi > 10 then hi := 10; bits := 3; end;
      else begin lo := 11; hi := zr; bits := 7; end;
      end;
      if c.Bit(m.seqMax[cls], Ord(rcnt = hi)) <> 0 then cnt := hi
      else begin
        cnt := lo + c.Direct(rcnt - lo, bits);
        if cnt > hi then Exit;
      end;
      seq[nSeq] := Word(cls or ((cnt - lo) shl 5)); Inc(nSeq);
      Inc(i, cnt);
      prevCls := cls - 15;
      if prevCls > 1 then prevCls := 1;
    end;
    Result := True;
  end;

  function SameHeader(const x, y: TDeflateBlock): Boolean;
  var i: Integer;
  begin
    Result := (x.hlit = y.hlit) and (x.hdist = y.hdist) and (x.hclen = y.hclen) and
      (Length(x.clenSeq) = Length(y.clenSeq));
    if not Result then Exit;
    for i := 0 to 18 do if x.clen[i] <> y.clen[i] then Exit(False);
    for i := 0 to 287 do if x.litLen[i] <> y.litLen[i] then Exit(False);
    for i := 0 to 31 do if x.distLen[i] <> y.distLen[i] then Exit(False);
    for i := 0 to High(x.clenSeq) do if x.clenSeq[i] <> y.clenSeq[i] then Exit(False);
  end;

  function SameSeq2(const a: array of Word; na: Integer; const b: array of Word; nb: Integer): Boolean;
  var i: Integer;
  begin
    if na <> nb then Exit(False);
    for i := 0 to na - 1 do if a[i] <> b[i] then Exit(False);
    Result := True;
  end;

  function SameSeq(const a: array of Word; na: Integer; const b: array of Word): Boolean;
  var i: Integer;
  begin
    if na <> Length(b) then Exit(False);
    for i := 0 to na - 1 do if a[i] <> b[i] then Exit(False);
    Result := True;
  end;

  { a dynamic block's header, coded against zlib's trees over its symbol
    counts (pb): into b }
  function DoTree: Boolean;
  var
    A, P: array[0..315] of Byte;
    i, k, last, hlit, hdist, total, sel, nSeq, n1, hclen: Integer;
    sc: array[0..SEL_EXPLICIT - 1, 0..316] of Word;
    nc: array[0..SEL_EXPLICIT - 1] of Integer;
    dup: Boolean;
    lens: array[0..315] of Byte;
    dl: array[0..29] of Byte;
    seq, s1: array[0..316] of Word;
    kf: Integer;
    rseq: array of Word;
    same: Boolean;
    sfreq: array[0..18] of Integer;
    pclen: array[0..18] of Byte;
  begin
    Result := False;
    for i := 0 to 285 do P[i] := pb.litLen[i];
    for i := 0 to 29 do P[286 + i] := pb.distLen[i];
    if c.enc then begin
      for i := 0 to 285 do A[i] := rb.litLen[i];
      for i := 0 to 29 do A[286 + i] := rb.distLen[i];
    end else FillChar(A, SizeOf(A), 0);
    same := True;
    if c.enc then for i := 0 to 315 do if A[i] <> P[i] then same := False;
    c.cat := 8; same := c.Bit(m.treeSame[lastTreeSame], Ord(same)) <> 0;
    lastTreeSame := Ord(same);
    if same then A := P
    else
      for i := 0 to 315 do begin
        if i < 286 then kf := Ord(lfreq[i] > 0) else kf := Ord(dfreq[i - 286] > 0);
        if c.Bit(m.lenSame[P[i] * 2 + kf], Ord(A[i] = P[i])) <> 0 then A[i] := P[i]
        else A[i] := c.Tree(m.lenVal[P[i]], 4, A[i]);
      end;
    { HLIT and HDIST: at least what the lengths need }
    last := 256;
    for i := 0 to 285 do if A[i] <> 0 then last := i;
    if last < 256 then last := 256;
    hlit := last + 1;
    c.cat := 9; if c.Bit(m.hlitSame, Ord(rb.hlit = hlit)) = 0 then begin
      hlit := 257 + c.Direct(rb.hlit - 257, 5);
      if (hlit <= last) or (hlit > 286) then Exit;
    end;
    last := 0;
    for i := 0 to 29 do if A[286 + i] <> 0 then last := i;
    hdist := last + 1;
    if c.Bit(m.hdistSame, Ord(rb.hdist = hdist)) = 0 then begin
      hdist := 1 + c.Direct(rb.hdist - 1, 5);
      if (hdist <= last) or (hdist > 30) then Exit;
    end;
    total := hlit + hdist;
    for i := 0 to hlit - 1 do lens[i] := A[i];
    for i := 0 to hdist - 1 do lens[hlit + i] := A[286 + i];
    { the run-length coding: zlib's on each tree (0), on both at once (1),
      libdeflate's (2), miniz's (3), zopfli's (4), or explicit (5); a
      guess the same as an earlier one is skipped }
    nc[0] := 0; ZlibSendTree(lens, hlit, sc[0], nc[0]);
    for i := 0 to hdist - 1 do dl[i] := lens[hlit + i];
    n1 := 0; ZlibSendTree(dl, hdist, s1, n1);
    for i := 0 to n1 - 1 do sc[0, nc[0] + i] := s1[i];
    Inc(nc[0], n1);
    nc[1] := 0; ZlibSendTree(lens, total, sc[1], nc[1]);
    SeqLibdeflate(lens, total, sc[2], nc[2]);
    SeqMiniz(lens, total, sc[3], nc[3]);
    SeqZopfliBest(lens, total, sc[4], nc[4]);
    sel := SEL_EXPLICIT;
    rseq := nil;
    if c.enc then begin
      rseq := rb.clenSeq;
      for k := SEL_EXPLICIT - 1 downto 0 do if SameSeq(sc[k], nc[k], rseq) then sel := k;
    end;
    c.cat := 10;
    k := 0;
    while k < SEL_EXPLICIT do begin
      dup := False;
      for i := 0 to k - 1 do if SameSeq2(sc[i], nc[i], sc[k], nc[k]) then dup := True;
      if not dup and (c.Bit(m.selK[lastSel, k], Ord(sel = k)) <> 0) then Break;
      Inc(k);
    end;
    sel := k;
    lastSel := sel;
    if sel < SEL_EXPLICIT then begin
      nSeq := nc[sel]; for i := 0 to nSeq - 1 do seq[i] := sc[sel, i];
    end else if not DoSeqExplicit(lens, total, seq, nSeq, rseq) then Exit;
    { the code-length code: zlib's over the symbols' counts }
    FillChar(sfreq, SizeOf(sfreq), 0);
    for i := 0 to nSeq - 1 do Inc(sfreq[seq[i] and $1F]);
    ClenBy(prm.tree, sfreq, pclen);
    same := True;
    if c.enc then for i := 0 to 18 do if rb.clen[i] <> pclen[i] then same := False;
    c.cat := 11; if c.Bit(m.clenSame, Ord(same)) <> 0 then
      for i := 0 to 18 do b.clen[i] := pclen[i]
    else
      for i := 0 to 18 do
        if c.Bit(m.clenS[pclen[i]], Ord(rb.clen[i] = pclen[i])) <> 0 then b.clen[i] := pclen[i]
        else b.clen[i] := c.Direct(rb.clen[i], 3);
    { HCLEN: at least what clen needs }
    hclen := 19;
    while (hclen > 4) and (b.clen[CLEN_ORDER[hclen - 1]] = 0) do Dec(hclen);
    c.cat := 9; if c.Bit(m.hclenSame, Ord(rb.hclen = hclen)) = 0 then begin
      i := 4 + c.Direct(rb.hclen - 4, 4);
      if (i < hclen) or (i > 19) then Exit;
      hclen := i;
    end;
    b.hlit := hlit; b.hdist := hdist; b.hclen := hclen;
    FillChar(b.litLen, SizeOf(b.litLen), 0);
    FillChar(b.distLen, SizeOf(b.distLen), 0);
    for i := 0 to hlit - 1 do b.litLen[i] := A[i];
    for i := 0 to hdist - 1 do b.distLen[i] := A[286 + i];
    SetLength(b.clenSeq, nSeq);
    for i := 0 to nSeq - 1 do b.clenSeq[i] := seq[i];
    { codes ppadeflate.Decode reads, and every symbol written has a code:
      the code-length code and the two trees not over-subscribed, the
      code-length symbols used, the block's literals, lengths, distances
      and its end (a decoder's corrections can give any lengths) }
    if not KraftOk(b.clen, 19) or not KraftOk(b.litLen, hlit) or not KraftOk(b.distLen, hdist) then Exit;
    for i := 0 to 18 do if (sfreq[i] > 0) and (b.clen[i] = 0) then Exit;
    for i := 0 to 285 do if (lfreq[i] > 0) and (b.litLen[i] = 0) then Exit;
    for i := 0 to 29 do if (dfreq[i] > 0) and (b.distLen[i] = 0) then Exit;
    Result := True;
  end;

begin
  Result := False;
  InitModels(m, mx);
  plain := nil;
  if Length(z.plain) > 0 then plain := @z.plain[0];
  n := Length(z.plain);
  { the predictor }
  head := nil; SetLength(head, SizeInt(1) shl prm.hbits);
  for k := 0 to High(head) do head[k] := NIL_POS;
  prev := nil; SetLength(prev, PREV_SIZE);
  runsA := nil; SetLength(runsA, PREV_SIZE);
  s := Default(TPredState);
  s.plain := plain; s.n := n; s.head := @head[0]; s.prev := @prev[0]; s.runs := @runsA[0]; s.ins := 0;
  s.hmask := (SizeInt(1) shl prm.hbits) - 1; s.hshift := (prm.hbits + MIN_MATCH - 1) div MIN_MATCH;
  s.chain := prm.chain; s.nice := prm.nice; s.good := prm.good; s.maxDist := prm.maxDist;
  s.hops := RANK_HOPS;
  SetLength(link4, PREV_SIZE); SetLength(link3, PREV_SIZE);
  SetLength(head4, 1 shl 16); SetLength(head3, 1 shl 16);
  for k := 0 to High(head4) do begin head4[k] := NIL_POS; head3[k] := NIL_POS; end;
  s.head4 := @head4[0]; s.link4 := @link4[0]; s.head3 := @head3[0]; s.link3 := @link3[0];
  if UseCorrC then begin
    SetLength(ordA, PREV_SIZE);
    SetLength(hcnt, SizeInt(1) shl prm.hbits);
    s.ord := @ordA[0]; s.hcnt := @hcnt[0];
  end;
  cachePos := -1; cacheLen := 0; cacheDist := 0;
  for k := 0 to High(localPos) do localPos[k] := -1;
  tokLen := nil; tokVal := nil;
  p := 0; bi := 0; nBlocks := 0;
  maxBlocks := 2 * n + BLOCKS_MORE;
  prevType := 3; lastTokens := -1; lastMiss := 0; lastSel := 0; lastTreeSame := 0; hist := 15; lastLB := 0;
  rb := Default(TDeflateBlock);
  b := Default(TDeflateBlock); b.btype := btFixed;
  SetCosts(b);
  repeat
    if c.enc then begin
      if bi > High(z.blocks) then Exit;
      rb := z.blocks[bi];
    end else if nBlocks >= maxBlocks then Exit;
    b := Default(TDeflateBlock);
    c.cat := 0; isStored := c.Bit(m.stored[prevType], Ord(rb.btype = btStored)) <> 0;
    if isStored then begin
      b.btype := btStored;
      maxLen := n - p; if maxLen > 65535 then maxLen := 65535;
      c.cat := 13; if c.Bit(m.stLenMax, Ord(rb.storedLen = maxLen)) <> 0 then len := maxLen
      else begin
        len := c.Direct(rb.storedLen, 16);
        if len > n - p then Exit;
      end;
      if c.Bit(m.padZero, Ord(rb.pad = 0)) = 0 then begin
        b.pad := c.Direct(rb.pad, 7);
        if not c.enc and (b.pad shr WriterStoredPadBits(o.w) <> 0) then Exit;
      end;
      b.plainPos := p; b.storedLen := len;
      Inc(p, len);
      prevType := 0;
    end else begin
      FillChar(lfreq, SizeOf(lfreq), 0); FillChar(dfreq, SizeOf(dfreq), 0);
      lfreq[256] := 1;
      nTokB := 0;
      t := 0;
      repeat
        if p >= n then isEnd := True
        else begin
          if t = 0 then k := 1
          else if (prm.symEnd > 0) and (t = prm.symEnd) then k := 2
          else if t = lastTokens then k := 3
          else k := 0;
          lg := 0;
          while (lg < 15) and ((SizeInt(1) shl lg) <= t) do Inc(lg);
          c.cat := 1; isEnd := c.Bit(m.blockEnd[k, lg], Ord(t = rb.nTokens)) <> 0;
        end;
        if isEnd then Break;
        if c.enc then begin
          rt := rb.firstToken + t;
          { the parameter search's measure: far enough }
          if (stopTokens >= 0) and ((rt >= stopTokens) or (p >= 16 * stopTokens)) then Exit(True);
          if not DoToken(z.tokLen[rt], z.tokVal[rt]) then Exit;
        end else if not DoToken(0, 0) then Exit;
        Inc(t);
      until False;
      if c.enc and (t <> rb.nTokens) then Exit;
      lastTokens := t;
      pb := Default(TDeflateBlock);
      ZlibTrees(lfreq, dfreq, pb, fixedNoBigger);
      if prm.tree <> TB_ZLIB then TreesBy(prm.tree, lfreq, dfreq, pb);
      c.cat := 0; isDyn := c.Bit(m.dyn[Ord(fixedNoBigger)], Ord(rb.btype = btDynamic)) <> 0;
      if isDyn then begin
        b.btype := btDynamic;
        if not DoTree then Exit;
        if c.enc and not SameHeader(b, rb) then Exit;
        prevType := 2;
      end else begin
        b.btype := btFixed;
        prevType := 1;
      end;
      b.nTokens := t;
      SetCosts(b);
    end;
    final := False;
    c.cat := 12; if p >= n then final := c.Bit(m.final, Ord(rb.final)) <> 0;
    b.final := final;
    if c.enc then begin
      if rb.final <> final then Exit;
      Inc(bi);
      if (stopTokens >= 0) and (p >= 16 * stopTokens) and not final then Exit(True);
    end else begin
      b.firstToken := 0;
      o.frame.tokLen := tokLen; o.frame.tokVal := tokVal;
      WriterBlock(o.w, o.frame, b);
      o.frame.tokLen := nil; o.frame.tokVal := nil;
    end;
    Inc(nBlocks);
  until final;
  if c.enc and (bi <> Length(z.blocks)) then Exit;
  if p <> n then Exit;
  Result := True;
end;

function CorrEncode(const z: TZStream; const p: TPredParams; stopTokens: SizeInt; memo: PLongMemo): TBytes;
var c: TCoder; o: TDriveOut;
begin
  if not PredValid(p) then raise Exception.Create('ppacorr: CorrEncode with parameters PredValid refuses');
  c := Default(TCoder);
  c.enc := True;
  c.ae.Init;
  o := Default(TDriveOut);
  if not Drive(c, z, p, stopTokens, o, memo) then raise Exception.Create('ppacorr: a stream the driver cannot code');
  Result := c.ae.Finish;
end;

function CorrRebuild(const plain: TBytes; const p: TPredParams; const corr: TBytes;
  const frame: TZStream; out stream: TBytes; memo: PLongMemo): Boolean;
var c: TCoder; o: TDriveOut; z: TZStream;
begin
  stream := nil;
  Result := False;
  if not PredValid(p) then Exit;
  c := Default(TCoder);
  c.enc := False;
  c.ad.Init(corr, 0);
  o := Default(TDriveOut);
  o.frame := Default(TZStream);
  o.frame.raw := frame.raw; o.frame.header := frame.header; o.frame.adlerOk := frame.adlerOk;
  o.frame.endPad := frame.endPad; o.frame.tail := frame.tail; o.frame.plain := plain;
  WriterBegin(o.w, o.frame);
  z := Default(TZStream);
  z.plain := plain;
  if not Drive(c, z, p, -1, o, memo) then Exit;
  if o.frame.endPad shr WriterEndPadBits(o.w) <> 0 then Exit;
  stream := WriterFinish(o.w, o.frame);
  Result := True;
end;

{ ---------------------------------------------------------------- the parameters }

{ a[0..n-1] in increasing order (Shell's sort) }
procedure SortSizes(var a: array of SizeInt; n: SizeInt);
var gap, i, j, v: SizeInt;
begin
  gap := 1;
  while gap < n div 3 do gap := 3 * gap + 1;
  while gap > 0 do begin
    for i := gap to n - 1 do begin
      v := a[i]; j := i;
      while (j >= gap) and (a[j - gap] > v) do begin a[j] := a[j - gap]; Dec(j, gap); end;
      a[j] := v;
    end;
    gap := gap div 3;
  end;
end;

{ What the stream's first tokens (up to token stop) say of its encoder,
  from zlib's chains (hash of 3 bytes in 15 bits, every position): the
  hops a match's distance is down its chain (the 99th percentile of the
  matches found within PRED_MAX_CHAIN, +1), whether literals stand where
  a match of 4 or more was there (a lazy encoder; lazyMin: more than the
  longest such match) }
procedure Estimate(const z: TZStream; stop: SizeInt; out chainEst, lazyMin: SizeInt; out lazyLits: Boolean);
const HB = 15;
var
  s: TPredState; head, prev, runsA, head4, link4, head3, link3: array of LongInt;
  hist: array[0..PRED_MAX_CHAIN] of SizeInt;
  t, q, L, D, cur, hops, nM, nLit, nLazy, acc, k, dd: SizeInt;
begin
  chainEst := PRED_MAX_CHAIN; lazyMin := MIN_MATCH; lazyLits := False;
  if Length(z.plain) < MIN_MATCH then Exit;
  head := nil; SetLength(head, SizeInt(1) shl HB);
  for k := 0 to High(head) do head[k] := NIL_POS;
  prev := nil; SetLength(prev, PREV_SIZE);
  runsA := nil; SetLength(runsA, PREV_SIZE);
  link4 := nil; SetLength(link4, PREV_SIZE); link3 := nil; SetLength(link3, PREV_SIZE);
  head4 := nil; SetLength(head4, 1 shl 16); head3 := nil; SetLength(head3, 1 shl 16);
  for k := 0 to High(head4) do begin head4[k] := NIL_POS; head3[k] := NIL_POS; end;
  s := Default(TPredState);
  s.plain := @z.plain[0]; s.n := Length(z.plain); s.head := @head[0]; s.prev := @prev[0]; s.runs := @runsA[0];
  s.head4 := @head4[0]; s.link4 := @link4[0]; s.head3 := @head3[0]; s.link3 := @link3[0];
  s.hmask := (SizeInt(1) shl HB) - 1; s.hshift := (HB + MIN_MATCH - 1) div MIN_MATCH;
  s.hops := RANK_HOPS;
  FillChar(hist, SizeOf(hist), 0);
  nM := 0; nLit := 0; nLazy := 0; q := 0;
  for t := 0 to High(z.tokLen) do begin
    if (t >= stop) or (q >= 16 * stop) then Break;
    L := z.tokLen[t];
    if L = LEN_258_AS_284 then L := MAX_MATCH;
    if L = 0 then begin
      Inc(nLit);
      if q + MIN_MATCH < s.n then begin
        k := LongestPas(s, q, LONG_HOPS, dd);
        if (k >= 4) and (dd <= TOO_FAR) and (t < High(z.tokLen)) and (z.tokLen[t + 1] > k) then begin
          Inc(nLazy);
          if k + 1 > lazyMin then lazyMin := k + 1;
        end;
      end;
      Inc(q);
    end else begin
      D := z.tokVal[t];
      if q + MIN_MATCH <= s.n then begin
        cur := ChainStart(s, q);
        hops := 0;
        while (cur > 0) and (q - cur < D) and (hops < PRED_MAX_CHAIN) do begin
          cur := s.prev[cur and PREV_MASK]; Inc(hops);
        end;
        if q - cur = D then begin Inc(hist[hops]); Inc(nM); end;
      end;
      Inc(q, L);
    end;
  end;
  if nM > 0 then begin
    acc := 0; k := 0;
    while (k < PRED_MAX_CHAIN) and (acc + hist[k] < nM - nM div 100) do begin Inc(acc, hist[k]); Inc(k); end;
    chainEst := k + 1;
  end;
  lazyLits := (nLazy > 0) and (nLazy * 100 >= nLit);
end;

{ The builder whose code lengths are the stream's most often: on its
  first 256 dynamic blocks, each builder's lengths (and code-length code)
  from the block's own counts against the block's; the fewest differences,
  zlib's of as few }
function ChooseTree(const z: TZStream): Integer;
var score: array[0..PRED_TREE_LAST] of Int64; bi, t, L, nb, i, tb: SizeInt;
  lf: array[0..285] of Integer; df: array[0..29] of Integer; sf: array[0..18] of Integer;
  pb: TDeflateBlock; cl: array[0..18] of Byte; fx: Boolean;
begin
  FillChar(score, SizeOf(score), 0);
  nb := 0;
  for bi := 0 to High(z.blocks) do
    with z.blocks[bi] do begin
      if btype <> btDynamic then Continue;
      Inc(nb);
      if nb > 256 then Break;
      FillChar(lf, SizeOf(lf), 0); FillChar(df, SizeOf(df), 0);
      lf[256] := 1;
      for t := firstToken to firstToken + nTokens - 1 do begin
        L := z.tokLen[t];
        if L = 0 then Inc(lf[z.tokVal[t] and 255])
        else begin
          if L = LEN_258_AS_284 then Inc(lf[284]) else Inc(lf[LenSym[L]]);
          Inc(df[DistSym[z.tokVal[t]]]);
        end;
      end;
      FillChar(sf, SizeOf(sf), 0);
      for i := 0 to High(clenSeq) do Inc(sf[clenSeq[i] and $1F]);
      for tb := 0 to PRED_TREE_LAST do begin
        pb := Default(TDeflateBlock);
        if tb = TB_ZLIB then ZlibTrees(lf, df, pb, fx) else TreesBy(tb, lf, df, pb);
        for i := 0 to 285 do if pb.litLen[i] <> litLen[i] then Inc(score[tb]);
        for i := 0 to 29 do if pb.distLen[i] <> distLen[i] then Inc(score[tb]);
        ClenBy(tb, sf, cl);
        for i := 0 to 18 do if cl[i] <> clen[i] then Inc(score[tb]);
      end;
    end;
  Result := 0;
  for tb := 1 to PRED_TREE_LAST do if score[tb] < score[Result] then Result := tb;
end;

procedure CorrChooseParams(const z: TZStream; out p: TPredParams; threads: Integer; memo: PLongMemo);
const
  { zlib's good lazy nice chain, by level }
  CONFIG: array[1..9, 0..3] of Integer = (
    (4, 4, 8, 4), (4, 5, 16, 8), (4, 6, 32, 32),
    (4, 4, 16, 16), (8, 16, 32, 32), (8, 16, 128, 128),
    (8, 32, 128, 256), (32, 128, 258, 1024), (32, 258, 258, 4096));
  { the first tokens every candidate is measured on; the few best on more }
  SEARCH1 = 1 shl 13;
  SEARCH2 = 1 shl 16;
  SEARCH_KEEP = 3;
var
  cands: array of TPredParams; costs: array of SizeInt;
  best, cand: TPredParams; cost: SizeInt;
  lv, f, i, j, k, hb, cnt, bestCnt, nC, chainEst, lazyMin, from, stop: SizeInt;
  nonStored, lazyLits: Boolean;
  counts: array of SizeInt;
  own: TLongMemo;

  procedure Add(const q: TPredParams);
  var i: SizeInt;
  begin
    if not PredValid(q) then Exit;
    for i := 0 to nC - 1 do
      if CompareByte(cands[i], q, SizeOf(q)) = 0 then Exit;
    if nC = Length(cands) then SetLength(cands, 2 * nC + 16);
    cands[nC] := q; Inc(nC);
  end;

  { costs[from + i]: candidate from + i's, on the first stop tokens }
  procedure Measure1(i: SizeInt);
  begin
    costs[from + i] := Length(CorrEncode(z, cands[from + i], stop, memo));
  end;

begin
  p := Default(TPredParams);
  p.predVersion := PRED_VERSION; p.chain := 128; p.nice := 128; p.lazy := 16; p.good := 8;
  p.hbits := 15; p.maxDist := WINDOW - 262; p.flags := PF_TOOFAR;
  { the symbols a block holds: the commonest count of the blocks that end
    before the last (twice at least) }
  counts := nil;
  SetLength(counts, Length(z.blocks));
  k := 0;
  for i := 0 to High(z.blocks) - 1 do
    if (z.blocks[i].btype <> btStored) and (z.blocks[i].nTokens > 0) then begin
      counts[k] := z.blocks[i].nTokens; Inc(k);
    end;
  SortSizes(counts, k);
  bestCnt := 1;
  i := 0;
  while i < k do begin
    f := i;
    while (f < k) and (counts[f] = counts[i]) do Inc(f);
    cnt := f - i;
    { the commonest; of as common, the smallest (the first in order) }
    if cnt > bestCnt then begin bestCnt := cnt; p.symEnd := counts[i]; end;
    i := f;
  end;
  if p.symEnd > PRED_MAX_SYMEND then p.symEnd := 0;
  nonStored := False;
  for i := 0 to High(z.blocks) do if (z.blocks[i].btype <> btStored) and (z.blocks[i].nTokens > 0) then nonStored := True;
  if not nonStored then Exit;
  p.tree := ChooseTree(z);
  Estimate(z, SEARCH2, chainEst, lazyMin, lazyLits);
  { the candidates: zlib's levels (deflate_fast at 1-3), the filtered
    strategy; the chain the stream shows, lazy or greedy as it shows; no
    limits (lazy and greedy); the longest match (greedy, lazy) }
  nC := 0; cands := nil;
  for lv := 1 to 9 do
    for f := 0 to 1 do begin
      if (f = 1) and (lv <= 3) then Continue;
      cand := p;
      cand.good := CONFIG[lv, 0]; cand.nice := CONFIG[lv, 2]; cand.chain := CONFIG[lv, 3];
      if lv <= 3 then begin cand.lazy := 0; cand.flags := 0; cand.good := MIN_MATCH + 1; end
      else begin
        cand.lazy := CONFIG[lv, 1];
        cand.flags := PF_TOOFAR;
        if f = 1 then cand.flags := PF_TOOFAR or PF_FILTERED;
      end;
      Add(cand);
    end;
  cand := p; cand.chain := chainEst; cand.nice := MAX_MATCH; cand.good := MAX_MATCH; cand.flags := PF_TOOFAR;
  if lazyLits then cand.lazy := MaxI(lazyMin, 16) else cand.lazy := 0;
  Add(cand);
  cand.lazy := MAX_MATCH; Add(cand);
  cand := p; cand.chain := PRED_MAX_CHAIN; cand.nice := MAX_MATCH; cand.lazy := MAX_MATCH; cand.good := MAX_MATCH;
  cand.flags := 0; cand.maxDist := WINDOW;
  Add(cand);
  cand.lazy := 0; Add(cand);
  cand.flags := PF_LONGEST; Add(cand);
  cand.lazy := MAX_MATCH; Add(cand);
  { (the longest matches the candidates share: positions up to SEARCH2's) }
  if memo = nil then begin
    CorrMemoInit(own, MinI(Length(z.plain), 16 * SEARCH2 + 2 * MAX_MATCH));
    memo := @own;
  end;
  SetLength(costs, nC);
  from := 0; stop := SEARCH1;
  ParallelFor(nC, threads, @Measure1);
  { the best one's hash, window, TOO_FAR, nice and lazy, as candidates too }
  k := 0;
  for i := 1 to nC - 1 do if costs[i] < costs[k] then k := i;
  best := cands[k];
  cand := best;
  if cand.lazy > 0 then begin cand.flags := cand.flags xor PF_TOOFAR; Add(cand); end;
  { the hash, the window and nice are zlib's search's alone }
  if (best.flags and PF_LONGEST) = 0 then begin
    cand := best;
    for hb := 16 downto 12 do begin cand.hbits := hb; Add(cand); end;
    cand := best;
    if cand.maxDist <> WINDOW then cand.maxDist := WINDOW else cand.maxDist := WINDOW - 262;
    Add(cand);
    cand := best;
    if cand.nice < MAX_MATCH then begin cand.nice := MAX_MATCH; Add(cand); end;
    cand := best;
    if cand.nice > 32 then begin cand.nice := cand.nice div 2; Add(cand); end;
  end;
  cand := best;
  if cand.lazy > 0 then begin
    if cand.lazy > 16 then begin cand.lazy := 16; Add(cand); end;
    cand := best;
    if cand.lazy < MAX_MATCH then begin cand.lazy := MAX_MATCH; Add(cand); end;
  end;
  from := Length(costs);
  SetLength(costs, nC);
  ParallelFor(nC - from, threads, @Measure1);
  { the SEARCH_KEEP cheapest to the front, in order (ties: the earlier) }
  for i := 0 to MinI(SEARCH_KEEP, nC) - 1 do begin
    k := i;
    for j := i + 1 to nC - 1 do if costs[j] < costs[k] then k := j;
    cand := cands[k]; cost := costs[k];
    for j := k downto i + 1 do begin cands[j] := cands[j - 1]; costs[j] := costs[j - 1]; end;
    cands[i] := cand; costs[i] := cost;
  end;
  best := cands[0];
  { on the first SEARCH2 tokens, when there are more than SEARCH1 }
  if (Length(z.tokLen) > SEARCH1) or (Length(z.plain) > 16 * SEARCH1) then begin
    k := MinI(SEARCH_KEEP, nC);
    from := 0; stop := SEARCH2;
    ParallelFor(k, threads, @Measure1);
    { the cheapest (ties: the earlier) }
    j := 0;
    for i := 1 to k - 1 do if costs[i] < costs[j] then j := i;
    best := cands[j];
  end;
  p := best;
end;

procedure MakeTables;
var s, l, i: Integer;
begin
  for s := 257 to 284 do
    for l := LEN_BASE[s] to LEN_BASE[s] + (1 shl LEN_EXTRA[s]) - 1 do
      if l <= 258 then LenSym[l] := s;
  LenSym[258] := 285;
  for s := 0 to 29 do
    for i := DIST_BASE[s] to DIST_BASE[s] + (1 shl DIST_EXTRA[s]) - 1 do
      DistSym[i] := s;
  for i := 0 to RATE_LIMIT do RATE[i] := 131072 div (2 * i + 3);
end;

initialization
  UseCorrC := GetEnvironmentVariable('PPA_NOC') <> '1';
  MakeTables;
end.
