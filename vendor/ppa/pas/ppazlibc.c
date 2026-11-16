/* Layer 2b's predictor, its hot spot in C: zlib's longest_match, bit for
   bit what ppazlib's Pascal LongestMatch does (the suite runs the predictor
   both ways and demands the same choices; PPA_NOC=1 picks the Pascal one).
   Positions are absolute into the input; a byte past its end reads as 0, as
   the Pascal's Win does. Takes no memory and calls no library. */
#include <stdint.h>

#define MAX_MATCH 258

static inline uint8_t win(const uint8_t *p, intptr_t n, intptr_t i) { return i < n ? p[i] : 0; }

/* how many bytes a and b have equal from the start, up to top: 4 at a time
   on little-endian machines, with a count of trailing zeros of 32 bits (a
   64-bit one would call libgcc on 32-bit x86, and this object calls no
   library); the same count either way */
static inline intptr_t common(const uint8_t *a, const uint8_t *b, intptr_t from, intptr_t top) {
  intptr_t len = from;
#if (defined(__GNUC__) || defined(__clang__)) && defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
  while (len + 4 <= top) {
    uint32_t x, y, d;
    __builtin_memcpy(&x, a + len, 4);
    __builtin_memcpy(&y, b + len, 4);
    d = x ^ y;
    if (d) return len + (__builtin_ctz(d) >> 3);
    len += 4;
  }
#endif
  while (len < top && a[len] == b[len]) len++;
  return len;
}

/* What the loop keeps of each position in the window (pos[str & wmask]),
   in 8 bytes, so that the window's 32 KB positions take 256 KB, a core's
   own cache, and a step along a chain reads one line: the links back as
   distances (the window is at most 32 KB: a distance fits in 15 bits; 0:
   none, or further than the window, where no match reaches; LINK_UNKNOWN:
   a skip table's collision) and the position's order in its hash chain,
   modulo 2^16 (two positions a chain step apart are less than the window
   apart, so the difference of their orders is less than 2^15: exact).
   prev: zlib's hash chain; d4, d8: the last position before with the same
   k1 (4 or 6) and 8 bytes (longest_skip). */
typedef struct { uint16_t prev, d4, d8, ord; } zpos_t;
#define LINK_UNKNOWN 0xFFFFu

/* the position a link of `from` names: 0 none, -1 not known */
static inline intptr_t link_at(uint16_t d, intptr_t from) {
  return d == 0 ? 0 : d == LINK_UNKNOWN ? -1 : from - d;
}
/* zlib's prev[from & wmask] (0: none, or out of the window) */
static inline intptr_t prev_of(const zpos_t *pos, intptr_t wmask, intptr_t from) {
  const uint16_t d = pos[from & wmask].prev;
  return d ? from - d : 0;
}

/* the longest match for the string at scan, walking the hash chain from
   cur; returns the best length (not yet capped to the lookahead) and sets
   *matchStart where it improves on bestLen */
static intptr_t ppaz_longest(const uint8_t *plain, intptr_t n, const zpos_t *pos, intptr_t wmask,
                             intptr_t scan, intptr_t cur, intptr_t limit, intptr_t chain,
                             intptr_t bestLen, intptr_t nice, intptr_t *matchStart) {
  uint8_t e1 = win(plain, n, scan + bestLen - 1), e = win(plain, n, scan + bestLen);
  const uint8_t s0 = win(plain, n, scan), s1 = win(plain, n, scan + 1);
  const intptr_t avail = n - scan;   /* bytes from scan to the end */
  do {
    const intptr_t m = cur;
    if (win(plain, n, m + bestLen) == e && win(plain, n, m + bestLen - 1) == e1 &&
        win(plain, n, m) == s0 && win(plain, n, m + 1) == s1) {
      const intptr_t top = avail < MAX_MATCH ? avail : MAX_MATCH;
      intptr_t len = common(plain + m, plain + scan, 3, top);
      if (len >= avail && len < MAX_MATCH) len = MAX_MATCH;   /* reaches the end: capped by the caller */
      if (len > bestLen) {
        *matchStart = cur;
        bestLen = len;
        if (len >= nice) break;
        e1 = win(plain, n, scan + bestLen - 1);
        e = win(plain, n, scan + bestLen);
      }
    }
    cur = prev_of(pos, wmask, cur);
    chain--;
  } while (cur > limit && chain != 0);
  return bestLen;
}

/* longest_match again, the same result, with the hash chain skipped where
   no candidate can do better: a candidate improves on bestLen only with at
   least bestLen + 1 bytes the same, so only the positions with the same 3
   bytes count while bestLen is 2, the same k1 (4, or 6 for a filtered
   deflate_slow) from k1 - 1 on, the same 8 from 7 on, 16 from 15 on.
   zpos_t's d4 and d8 (and d16) link each position to the last one before
   it with the same k1, 8 (and 16) bytes (0: none; LINK_UNKNOWN: not
   known, a table's collision); the same 3 bytes are found on zlib's own
   chain, walked (a table for them cost more to keep than it saved: 4.5%
   of the time on photographs); ord
   numbers each position in its hash chain, so a jump from the scan to q
   costs zlib's walk ord[scan] - ord[q] steps (curMatch, the first, is step
   0) and the chain's length still ends the search where zlib's ends. A
   candidate the walk reaches with fewer bytes the same than the chain it
   is on is not possible: one newer with more would have been met first.
   Where a link is not known, zlib's chain is walked from there to the next
   position with the key. */
static inline int skip_level(intptr_t bestLen, int lmax, int k1) {
  const int l = bestLen >= 15 ? 3 : bestLen >= 7 ? 2 : bestLen >= k1 - 1 ? 1 : 0;
  return l < lmax ? l : lmax;
}
/* the keys' lengths by level; level 1's is k1: 4, or 6 for deflate_slow's
   filtered strategy, whose search starts at 5 bytes (zd_longest) */
static inline intptr_t skip_key(int lv, int k1) { return lv == 3 ? 16 : lv == 2 ? 8 : lv == 1 ? k1 : 3; }
#if (defined(__GNUC__) || defined(__clang__)) && defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
#define ZK_LE 1
#endif

/* the bytes of the key of level lv at a and b the same (lv 0: 3 bytes, 1:
   k1, 2: 8, 3: 16; both have that many bytes to read, and 8 with k1 6) */
static inline int same_key(const uint8_t *plain, intptr_t a, intptr_t b, int lv, int k1) {
#ifdef ZK_LE
  if (lv >= 2 || (lv == 1 && k1 == 6)) {
    uint64_t x, y; __builtin_memcpy(&x, plain + a, 8); __builtin_memcpy(&y, plain + b, 8);
    if (lv == 1) return ((x ^ y) & 0xFFFFFFFFFFFFull) == 0;
    if (lv == 2 || x != y) return x == y;
    __builtin_memcpy(&x, plain + a + 8, 8); __builtin_memcpy(&y, plain + b + 8, 8); return x == y;
  }
  { uint32_t x, y; __builtin_memcpy(&x, plain + a, 4); __builtin_memcpy(&y, plain + b, 4);
    return lv == 1 ? x == y : ((x ^ y) & 0xFFFFFFu) == 0; }
#else
  const int k = (int)skip_key(lv, k1);
  for (int i = 0; i < k; i++) if (plain[a + i] != plain[b + i]) return 0;
  return 1;
#endif
}

/* the link of level lv (1..3) at position from */
static inline intptr_t link_of(const zpos_t *pos, const uint16_t *d16, intptr_t wmask, int lv, intptr_t from) {
  const intptr_t i = from & wmask;
  return link_at(lv == 1 ? pos[i].d4 : lv == 2 ? pos[i].d8 : d16[i], from);
}
/* zlib's chain steps from a position of order o0 back to q, less one, as
   the walk counts them (o0 - ord - 1 modulo 2^16) */
static inline uint32_t steps(const zpos_t *pos, intptr_t wmask, uint16_t o0, intptr_t q) {
  return (uint16_t)(o0 - pos[q & wmask].ord - 1);
}

static inline __attribute__((always_inline)) intptr_t longest_skip(const uint8_t *plain, intptr_t n, const zpos_t *pos, const uint16_t *d16,
                             intptr_t wmask, intptr_t scan, intptr_t cur, intptr_t limit,
                             intptr_t chain, intptr_t bestLen, intptr_t nice, intptr_t *matchStart, int k1) {
  if (bestLen < 2 || scan + (k1 == 6 ? 8 : 4) > n)
    return ppaz_longest(plain, n, pos, wmask, scan, cur, limit, chain, bestLen, nice, matchStart);
  const uint16_t o0 = pos[scan & wmask].ord;
  const intptr_t avail = n - scan;
  const intptr_t top = avail < MAX_MATCH ? avail : MAX_MATCH;
  /* the 16 bytes' links where they are kept (zlib's levels 8 and 9) */
  const int lmax = d16 && scan + 16 <= n ? 3 : scan + 8 <= n ? 2 : 1;
  int lv = skip_level(bestLen, lmax, k1);
  intptr_t from = scan;                 /* the position whose link q is */
  intptr_t q = lv ? link_of(pos, d16, wmask, lv, scan) : -1;
  for (;;) {
    if (q < 0) {
      /* not known (a table's collision): zlib's chain from `from`, every
         position on it a candidate, to the first with the key; the ones
         before it cannot do better (their key differs, and the key is no
         longer than bestLen + 1) */
      q = prev_of(pos, wmask, from);
      while (q != 0 && (q > limit || q == cur) && steps(pos, wmask, o0, q) < (uint32_t)chain &&
             !same_key(plain, q, scan, lv, k1))
        q = prev_of(pos, wmask, q);
    }
    if (q == 0 || (q <= limit && q != cur)) break;          /* none left (zlib takes curMatch anyway) */
    if (steps(pos, wmask, o0, q) >= (uint32_t)chain) break;   /* past zlib's chain */
    /* as zlib: a candidate without the byte at bestLen the same cannot do better */
    if (bestLen >= top || plain[q + bestLen] == plain[scan + bestLen]) {
      intptr_t len = common(plain + q, plain + scan, 0, top);
      if (len >= avail && len < MAX_MATCH) len = MAX_MATCH;
      if (len > bestLen) {
        *matchStart = q;
        bestLen = len;
        if (len >= nice) break;
        const int l2 = skip_level(bestLen, lmax, k1);
        if (l2 > lv) {
          /* a longer chain from here: q's own if q has its key, else the
             scan's, whose first is older than q */
          lv = l2;
          from = len >= skip_key(lv, k1) ? q : scan;
          q = link_of(pos, d16, wmask, lv, from);   /* lv > 0 here */
          continue;
        }
      }
    }
    from = q;
    q = lv ? link_of(pos, d16, wmask, lv, q) : -1;
  }
  return bestLen;
}

/* ---- zlib's deflate_slow and deflate_fast, the loop around longest_match:
   bit for bit what ppazlib's Pascal DeflateSlow and DeflateFast do, with
   the chains skipped as above. Runs until a block is full (returns
   ZD_FLUSH: Pascal flushes it and calls again), the input ends (ZD_DONE)
   or the choices part from the reference (ZD_STOP). ppazlib.pas's
   TZDeflate is this struct, field for field. */
enum { ZD_DONE = 0, ZD_FLUSH = 1, ZD_STOP = 2, ZD_SEGEND = 3 };
#define MIN_MATCH 3
#define FILTERED_MIN 5   /* deflate_slow's filtered strategy drops a match this long or shorter */

typedef struct {
  const uint8_t *plain; intptr_t n;
  intptr_t wsize, wmask, maxDist, hashMask, hashShift;
  uint32_t *head;                /* zlib's head[], positions (0: none) */
  zpos_t *pos;                   /* each position in the window: zpos_t */
  uint16_t *cnt;                 /* each hash chain's insertions, modulo 2^16 */
  uint32_t *t4, *t8;
  intptr_t insH;
  intptr_t strstart, matchStart, prevMatch, winBase;
  intptr_t matchLength, prevLength, matchAvailable;
  intptr_t goodMatch, maxLazy, niceMatch, maxChain, filtered, fast;
  uint16_t *tokLen, *tokVal; intptr_t nTok;
  const uint16_t *refLen, *refVal; intptr_t refN, checkNow, stop;
  int32_t *lfreq, *dfreq; intptr_t symNext, symEnd;
  const uint8_t *lengthCode, *distCode;
  intptr_t pending;              /* after a flush: the literal's strstart++ still to do */
  intptr_t skipBits;             /* the tables t4, t8 (t16): 2^skipBits positions each */
  uint16_t *d16; uint32_t *t16; /* the same 16 bytes (as d8), where the chains are long (levels 8, 9); else 0 */
  /* a segment (ppazlib's parallel rebuild, deflate_slow only): stop at the
     top of the loop once strstart reaches stopAt (0: never); after each
     match, where the parse is as it starts (no match pending, none found
     yet), its position and the tokens so far, up to maxSync of them; endLit:
     the literal deflate_slow emits after its loop was emitted */
  intptr_t stopAt;
  intptr_t *syncPos, *syncTok; intptr_t nSync, maxSync;
  intptr_t endLit;
  intptr_t syncLo, syncHi;       /* only the positions up to syncLo and from syncHi are kept */
  intptr_t key1;                 /* the key of d4 (t4): 4 bytes, or 6 (filtered deflate_slow: skip_key) */
  /* a flow (ppazlib's ZlibChoicesFlow: flushes): the lookahead ends at lim
     (a flush's position, else n; the bytes past it are still read, as the
     Pascal reads them: they only decide a match that reaches lim, which is
     cut to it); no match starts at or before lo (Z_FULL_FLUSH forgot
     them; 0: NIL) */
  intptr_t lim, lo;
  intptr_t tooFar;               /* deflate_slow drops a match of 3 further than this (TOO_FAR, or pngcrush's 32767) */
} zdeflate_t;

static inline uint64_t zd_load8(const uint8_t *p) { uint64_t v; __builtin_memcpy(&v, p, 8); return v; }
static inline uint32_t zd_load4(const uint8_t *p) { uint32_t v; __builtin_memcpy(&v, p, 4); return v; }
static inline uint32_t zd_load2(const uint8_t *p) { uint16_t v; __builtin_memcpy(&v, p, 2); return v; }

#ifndef ZD_PF
#define ZD_PF 4
#endif
/* The skip tables t4 (k1 bytes: 4 or 6), t8 and t16: 2^skipBits slots in
   sets of two, the newest position whose key hashes there first, at most
   one position of each key (the newest of it). A key's newest position is
   in its set or was pushed out, older than both there; so where neither
   has the key, there is none in the window when the older of the two is
   out of it (or empty), and it is not known otherwise. Two ways and not
   one: a collision makes the search walk zlib's chain to the key, and two
   ways have far fewer. The keys are read as the bytes in memory (the
   order a machine loads them in only changes the slots). */
static inline uint32_t zd_hk(const uint8_t *p, intptr_t str, int K, int sb) {
  const int b = sb - 1;   /* the set's bits */
  switch (K) {
  case 4: return (zd_load4(p + str) * 2246822519u) >> (32 - b);
  case 6: return (uint32_t)(((zd_load4(p + str) | (uint64_t)zd_load2(p + str + 4) << 32) * 0xD6E8FEB86659FD93ull) >> (64 - b));
  case 8: return (uint32_t)((zd_load8(p + str) * 0x9E3779B97F4A7C15ull) >> (64 - b));
  default: return (uint32_t)(((zd_load8(p + str) ^ (zd_load8(p + str + 8) * 0xC2B2AE3D27D4EB4Full)) * 0x9E3779B97F4A7C15ull) >> (64 - b));
  }
}
/* the K bytes at a and at b the same */
static inline int zd_eq(const uint8_t *p, intptr_t a, intptr_t b, int K) {
  switch (K) {
  case 4: return zd_load4(p + a) == zd_load4(p + b);
  case 6: return zd_load4(p + a) == zd_load4(p + b) && zd_load2(p + a + 4) == zd_load2(p + b + 4);
  case 8: return zd_load8(p + a) == zd_load8(p + b);
  default: return zd_load8(p + a) == zd_load8(p + b) && zd_load8(p + a + 8) == zd_load8(p + b + 8);
  }
}
/* str into its set of t (K bytes to read at str): its link back, as
   zpos_t keeps it */
static inline uint16_t zd_put(const uint8_t *p, uint32_t *t, intptr_t str, intptr_t w, int K, int sb) {
  uint32_t *const set = t + 2 * (intptr_t)zd_hk(p, str, K, sb);
  const intptr_t a = set[0], b = set[1];
  const int liveA = a != 0 && str - a < w;
  set[0] = (uint32_t)str;
  if (liveA && zd_eq(p, a, str, K)) return (uint16_t)(str - a);           /* b stays */
  set[1] = (uint32_t)a;
  if (!liveA) return 0;                                                   /* b is older still */
  if (b != 0 && str - b < w) return zd_eq(p, b, str, K) ? (uint16_t)(str - b) : LINK_UNKNOWN;
  return 0;
}
/* k1 (4 or 6) and h16 (t16 kept or not) are constants in each copy of
   the loop (ppaz_deflate) */
static inline __attribute__((always_inline)) void zd_skip(zdeflate_t *s, intptr_t str, const int k1, const int h16) {
  const uint8_t *p = s->plain;
  const intptr_t i = str & s->wmask, n = s->n;
  const int sb = (int)s->skipBits;
  zpos_t *const ps = &s->pos[i];
  const intptr_t w = s->wsize;
  ps->ord = s->cnt[s->insH]++;
  /* the tables' sets a few positions ahead fetched meanwhile (a hint:
     nothing depends on it) */
  if (str + ZD_PF + 16 <= n) {
    __builtin_prefetch(s->t4 + 2 * (intptr_t)zd_hk(p, str + ZD_PF, k1, sb));
    __builtin_prefetch(s->t8 + 2 * (intptr_t)zd_hk(p, str + ZD_PF, 8, sb));
    if (h16) __builtin_prefetch(s->t16 + 2 * (intptr_t)zd_hk(p, str + ZD_PF, 16, sb));
  }
  ps->d4 = str + k1 <= n ? zd_put(p, s->t4, str, w, k1, sb) : LINK_UNKNOWN;
  ps->d8 = str + 8 <= n ? zd_put(p, s->t8, str, w, 8, sb) : LINK_UNKNOWN;
  if (h16) s->d16[i] = str + 16 <= n ? zd_put(p, s->t16, str, w, 16, sb) : LINK_UNKNOWN;
}

static inline __attribute__((always_inline)) intptr_t zd_insert(zdeflate_t *s, intptr_t str, const int k1, const int h16) {
  s->insH = ((s->insH << s->hashShift) ^ win(s->plain, s->n, str + MIN_MATCH - 1)) & s->hashMask;
  const intptr_t r = s->head[s->insH];
  s->pos[str & s->wmask].prev = (r == 0 || str - r >= s->wsize) ? 0 : (uint16_t)(str - r);
  s->head[s->insH] = (uint32_t)str;
  if (str + 2 < s->n) zd_skip(s, str, k1, h16);
  return r;
}

static inline __attribute__((always_inline)) intptr_t zd_longest(zdeflate_t *s, intptr_t cur, const int fast,
                                                                   const int k1, const int h16) {
  const intptr_t look = s->lim - s->strstart;
  intptr_t chain = s->maxChain, nice = s->niceMatch;
  intptr_t limit = s->strstart > s->maxDist ? s->strstart - s->maxDist : 0;
  if (limit < s->lo) limit = s->lo;
  if (s->prevLength >= s->goodMatch) chain >>= 2;
  if (nice > look) nice = look;
  /* deflate_slow with the filtered strategy drops a match of 5 bytes or
     fewer: only one of 6 or more can count, so the search may start as if
     it had one of 5. Where the longest is 6 or more it is the same match,
     the first of its length on the chain (a candidate improves on the best
     only with more bytes, wherever the best started); where it is not, the
     caller drops what it gets, as it dropped zlib's. Not from a best of 0:
     zlib's longest_match then also wants the byte before each candidate
     the same as the byte before the scan (scan_end1 is scan[-1]), and
     skips a candidate without it however long. deflate_slow starts with a
     prev_length of 0 right after deflate_fast ended on a match or
     deflate_rle ran (a flow's change of loop, recipe kind 1); kind 0 never
     has it */
  intptr_t best0 = s->prevLength;
  if (s->filtered && !fast && best0 > 0 && best0 < FILTERED_MIN) best0 = FILTERED_MIN;
  const intptr_t best = longest_skip(s->plain, s->n, s->pos, h16 ? s->d16 : 0, s->wmask, s->strstart,
                                     cur, limit, chain, best0, nice, &s->matchStart, k1);
  return best <= look ? best : look;
}

static inline void zd_token(zdeflate_t *s, intptr_t len, intptr_t dist) {
  s->tokLen[s->nTok] = (uint16_t)len; s->tokVal[s->nTok] = (uint16_t)dist;
  if (s->checkNow && (s->nTok >= s->refN || s->refLen[s->nTok] != len || s->refVal[s->nTok] != dist)) s->stop = 1;
  s->nTok++;
}
static inline int zd_lit(zdeflate_t *s, int c) {
  zd_token(s, 0, c);
  s->lfreq[c]++;
  return ++s->symNext == s->symEnd;
}
static inline int zd_dist(zdeflate_t *s, intptr_t dist, intptr_t lenMinus3) {
  zd_token(s, lenMinus3 + MIN_MATCH, dist);
  s->lfreq[s->lengthCode[lenMinus3] + 257]++;
  s->dfreq[s->distCode[dist - 1]]++;
  return ++s->symNext == s->symEnd;
}

static inline __attribute__((always_inline)) intptr_t zd_run(zdeflate_t *s, const int fast, const int k1, const int h16) {
  if (s->pending) { s->strstart++; s->pending = 0; }
  for (;;) {
    if (s->stop) return ZD_STOP;
    if (s->stopAt && s->strstart >= s->stopAt) return ZD_SEGEND;
    while (s->strstart - s->winBase >= s->wsize + s->maxDist) s->winBase += s->wsize;
    const intptr_t look = s->lim - s->strstart;
    if (look == 0) break;
    intptr_t hashHead = 0;
    if (look >= MIN_MATCH) hashHead = zd_insert(s, s->strstart, k1, h16);
    if (fast) {
      int bflush;
      if (hashHead > s->lo && s->strstart - hashHead <= s->maxDist) s->matchLength = zd_longest(s, hashHead, fast, k1, h16);
      if (s->matchLength >= MIN_MATCH) {
        bflush = zd_dist(s, s->strstart - s->matchStart, s->matchLength - MIN_MATCH);
        if (s->matchLength <= s->maxLazy && look - s->matchLength >= MIN_MATCH) {
          s->matchLength--;
          do { s->strstart++; zd_insert(s, s->strstart, k1, h16); s->matchLength--; } while (s->matchLength != 0);
          s->strstart++;
        } else {
          s->strstart += s->matchLength;
          s->matchLength = 0;
          s->insH = win(s->plain, s->n, s->strstart);
          s->insH = ((s->insH << s->hashShift) ^ win(s->plain, s->n, s->strstart + 1)) & s->hashMask;
        }
      } else {
        bflush = zd_lit(s, s->plain[s->strstart]);
        s->strstart++;
      }
      if (bflush) return ZD_FLUSH;
      continue;
    }
    s->prevLength = s->matchLength; s->prevMatch = s->matchStart;
    s->matchLength = MIN_MATCH - 1;
    if (hashHead > s->lo && s->prevLength < s->maxLazy && s->strstart - hashHead <= s->maxDist) {
      s->matchLength = zd_longest(s, hashHead, fast, k1, h16);
      if (s->matchLength <= FILTERED_MIN && (s->filtered || (s->matchLength == MIN_MATCH && s->strstart - s->matchStart > s->tooFar)))
        s->matchLength = MIN_MATCH - 1;
    }
    if (s->prevLength >= MIN_MATCH && s->matchLength <= s->prevLength) {
      const intptr_t maxInsert = s->strstart + look - MIN_MATCH;
      const int bflush = zd_dist(s, s->strstart - 1 - s->prevMatch, s->prevLength - MIN_MATCH);
      s->prevLength -= 2;
      do {
        s->strstart++;
        if (s->strstart <= maxInsert) zd_insert(s, s->strstart, k1, h16);
        s->prevLength--;
      } while (s->prevLength != 0);
      s->matchAvailable = 0;
      s->matchLength = MIN_MATCH - 1;
      s->strstart++;
      if (s->syncPos && s->nSync < s->maxSync && (s->strstart <= s->syncLo || s->strstart >= s->syncHi)) {
        s->syncPos[s->nSync] = s->strstart; s->syncTok[s->nSync] = s->nTok; s->nSync++;
      }
      if (bflush) return ZD_FLUSH;
    } else if (s->matchAvailable) {
      if (zd_lit(s, s->plain[s->strstart - 1])) { s->pending = 1; return ZD_FLUSH; }
      s->strstart++;
    } else {
      s->matchAvailable = 1;
      s->strstart++;
    }
  }
  if (!fast && s->matchAvailable) {
    zd_lit(s, s->plain[s->strstart - 1]);
    s->matchAvailable = 0;
    s->endLit = 1;
  }
  return ZD_DONE;
}

/* the loop with its constants: deflate_fast or deflate_slow, the key of
   d4, t16 kept or not */
intptr_t ppaz_deflate(zdeflate_t *s) {
  const int six = s->key1 == 6, h16 = s->t16 != 0;
  if (s->fast) return six ? zd_run(s, 1, 6, h16) : h16 ? zd_run(s, 1, 4, 1) : zd_run(s, 1, 4, 0);
  if (six) return h16 ? zd_run(s, 0, 6, 1) : zd_run(s, 0, 6, 0);
  return h16 ? zd_run(s, 0, 4, 1) : zd_run(s, 0, 4, 0);
}

/* A segment's start: every position from `from` to `to` - 1 inserted as
   deflate_slow inserts them (all of them, up to n - MIN_MATCH), the hash
   started as fill_window starts it: the chains and the skip links at `to`
   are then the ones the whole run has there, within the window */
void ppaz_preinsert(zdeflate_t *s, intptr_t from, intptr_t to) {
  const uint8_t *p = s->plain;
  if (from + 1 < s->n) s->insH = (((intptr_t)p[from] << s->hashShift) ^ p[from + 1]) & s->hashMask;
  const int k1 = s->key1 == 6 ? 6 : 4, h16 = s->t16 != 0;
  for (intptr_t str = from; str < to; str++)
    if (str + MIN_MATCH <= s->n) zd_insert(s, str, k1, h16);
}
