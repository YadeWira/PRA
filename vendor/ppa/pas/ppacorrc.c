/* Recipe kind 3's hot loops (ppacorr.pas): the predictor's search (zlib's
   longest_match on the predictor's own chains) and the rank walk. Same
   results as ppacorr's SearchPas and RankPas, which are the reference;
   test_preflate compares the two on every stream it is given.

   No library, no runtime: plain C, built by build_c.sh. */
#include <stdint.h>

typedef intptr_t sz;

/* ppacorr.pas's TPredState, field for field */
typedef struct {
  const uint8_t *plain; sz n;
  int32_t *head; int32_t *prev;
  sz ins;
  sz hmask, hshift;
  sz chain, nice, good, maxDist;
  sz hops;
  /* the C search's own links (ppacorr allocates them for it): each
     position's order in its hash chain (ord, by position and PREV_MASK; hcnt
     counts each hash's insertions) and the chains of the same 4 bytes'
     hash (head4: 2^16, link4: by position and PREV_MASK) */
  int32_t *ord; int32_t *hcnt; int32_t *head4; int32_t *link4;
  /* where each position's run of one byte starts (by position and PREV_MASK) */
  int32_t *runs;
  /* the rank walk's and the longest match's own chains of 3 bytes (hash3x) */
  int32_t *head3; int32_t *link3;
} pcstate_t;

#define MIN_MATCH 3
#define MAX_MATCH 258
#define WINDOW 32768
#define PREV_MASK 65535

static inline sz hash3(const pcstate_t *s, sz q) {
  const uint8_t *p = s->plain + q;
  return (((((sz)p[0] << s->hshift) ^ p[1]) << s->hshift) ^ p[2]) & s->hmask;
}

/* ppacorr.pas's Hash4: the 4 bytes' value, the first lowest (whatever
   the machine's order), times 2654435761, the top 16 of the low 32 bits */
static inline sz hash4(const pcstate_t *s, sz q) {
  const uint8_t *p = s->plain + q;
  uint32_t v = (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
  return (sz)((v * 2654435761u) >> 16);
}

/* ppacorr.pas's Hash3x */
static inline sz hash3x(const pcstate_t *s, sz q) {
  const uint8_t *p = s->plain + q;
  uint32_t v = (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16);
  return (sz)((v * 2654435761u) >> 16);
}

static void insert_up_to(pcstate_t *s, sz k) {
  if (k > s->n - MIN_MATCH) k = s->n - MIN_MATCH;
  while (s->ins <= k) {
    sz i = s->ins, h = hash3(s, i);
    s->prev[i & PREV_MASK] = s->head[h];
    s->head[h] = (int32_t)i;
    s->ord[i & PREV_MASK] = s->hcnt[h]++;
    h = hash3x(s, i);
    s->link3[i & PREV_MASK] = s->head3[h];
    s->head3[h] = (int32_t)i;
    s->runs[i & PREV_MASK] = (i > 0 && s->plain[i] == s->plain[i - 1]) ? s->runs[(i - 1) & PREV_MASK] : (int32_t)i;
    if (i + 3 < s->n) {
      sz h4 = hash4(s, i);
      s->link4[i & PREV_MASK] = s->head4[h4];
      s->head4[h4] = (int32_t)i;
    }
    s->ins++;
  }
}

static sz chain3_start(pcstate_t *s, sz q) {
  if (q < s->ins) return s->link3[q & PREV_MASK];
  insert_up_to(s, q - 1);
  return s->head3[hash3x(s, q)];
}

static sz chain_start(pcstate_t *s, sz q) {
  if (q < s->ins) return s->prev[q & PREV_MASK];
  insert_up_to(s, q - 1);
  return s->head[hash3(s, q)];
}

/* the trailing zero bits of a nonzero 64-bit value, through 32-bit ctz:
   __builtin_ctzll calls libgcc's __ctzdi2 on 32-bit x86, and the C objects
   call no library (.github/test.sh checks it with nm) */
static inline int ctz64(uint64_t v) {
  const uint32_t lo = (uint32_t)v;
  return lo ? __builtin_ctz(lo) : 32 + __builtin_ctz((uint32_t)(v >> 32));
}

/* the length of the common prefix of a and b, at most max (max >= start) */
static inline sz common(const uint8_t *a, const uint8_t *b, sz start, sz max) {
  sz len = start;
  while (len + 8 <= max) {
    uint64_t x, y;
    __builtin_memcpy(&x, a + len, 8); __builtin_memcpy(&y, b + len, 8);
    if (x != y) {
      /* little-endian: the first differing byte is the lowest; elsewhere
         the bytes one by one below */
#if defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
      return len + (ctz64(x ^ y) >> 3);
#else
      break;
#endif
    }
    len += 8;
  }
  while (len < max && a[len] == b[len]) len++;
  return len;
}

sz pc_search(pcstate_t *s, sz q, sz prevLen, sz *dist) {
  const uint8_t *pl = s->plain;
  sz cur, limit, chainLen, bestLen, nice, look, len, maxLen;
  *dist = 0;
  look = s->n - q;
  if (look < MIN_MATCH || prevLen >= look) return 0;
  cur = chain_start(s, q);
  if (cur <= 0 || q - cur > s->maxDist) return 0;
  limit = q > s->maxDist ? q - s->maxDist : 0;
  chainLen = s->chain;
  if (prevLen >= s->good) chainLen >>= 2;
  if (chainLen < 1) chainLen = 1;
  nice = s->nice; if (nice > look) nice = look;
  maxLen = MAX_MATCH; if (maxLen > look) maxLen = look;
  bestLen = prevLen;
  {
    sz start = cur, startOrd = s->ord[cur & PREV_MASK], budget = chainLen;
    do {
      if (pl[cur + bestLen] == pl[q + bestLen] && pl[cur + bestLen - 1] == pl[q + bestLen - 1] &&
          pl[cur] == pl[q] && pl[cur + 1] == pl[q + 1]) {
        len = common(pl + cur, pl + q, 2, maxLen);
        if (len > bestLen) {
          bestLen = len; *dist = q - cur;
          if (len >= nice) goto done;
        }
      }
      if (bestLen >= MIN_MATCH && look > MIN_MATCH) goto skip;
      cur = s->prev[cur & PREV_MASK];
      chainLen--;
    } while (cur > limit && chainLen != 0);
    goto done;
  skip:
    /* From here only a candidate with the same 4 bytes as q can be longer
       than bestLen (>= 3): the walk goes along q's 4-byte chain instead,
       visiting the same candidates zlib's would, in the same order, up to
       the same hop (counted by the positions' order in their hash chain,
       the same for all of them: their first 3 bytes are q's). */
    {
      sz c4 = q < s->ins ? s->link4[q & PREV_MASK] : s->head4[hash4(s, q)];
      uint32_t key; __builtin_memcpy(&key, pl + q, 4);
      (void)start;
      while (c4 >= cur) c4 = s->link4[c4 & PREV_MASK];
      while (c4 > limit) {
        uint32_t v; __builtin_memcpy(&v, pl + c4, 4);
        if (v == key) {
          if (startOrd - s->ord[c4 & PREV_MASK] >= budget) break;
          if (pl[c4 + bestLen] == pl[q + bestLen] && pl[c4 + bestLen - 1] == pl[q + bestLen - 1]) {
            len = common(pl + c4, pl + q, 4, maxLen);
            if (len > bestLen) {
              bestLen = len; *dist = q - c4;
              if (len >= nice) break;
            }
          }
        }
        c4 = s->link4[c4 & PREV_MASK];
      }
    }
  }
done:
  if (bestLen > prevLen) return bestLen;
  *dist = 0;
  return 0;
}

static inline sz run_from(const uint8_t *pl, sz c, sz cap) {
  sz r = 1; uint8_t b = pl[c];
#if defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
  uint64_t pat = (uint64_t)b * 0x0101010101010101ull;
  while (r + 8 <= cap) {
    uint64_t x; __builtin_memcpy(&x, pl + c + r, 8);
    if (x != pat) return r + (ctz64(x ^ pat) >> 3);
    r += 8;
  }
#endif
  while (r < cap && pl[c + r] == b) r++;
  return r;
}

/* ppacorr.pas's RankPas, with its skips over runs of one byte */
sz pc_rank(pcstate_t *s, sz q, sz len, sz target, sz wantRank) {
  const uint8_t *pl = s->plain;
  sz cur, hops = 0, rank = 0, rq, rc, rs;
  if (len < MIN_MATCH || q + len > s->n) return -1;
  cur = chain3_start(s, q);
  rq = run_from(pl, q, len);
  while (cur >= 0 && q - cur <= WINDOW && hops < s->hops) {
    if (rq >= MIN_MATCH && rq < len && pl[cur] == pl[q]) {
      rc = run_from(pl, cur, rq + 1);
      if (rc >= MIN_MATCH && rc != rq) {
        hops++;
        rs = s->runs[cur & PREV_MASK];
        if (rc < rq && cur - (rq - rc) >= rs) { cur -= rq - rc; continue; }
        if (q - rs > WINDOW) break;
        cur = s->link3[rs & PREV_MASK];
        continue;
      }
    }
    if (pl[cur + len - 1] == pl[q + len - 1] && common(pl + cur, pl + q, 0, len) == len) {
      if (wantRank) { if (rank == target) return q - cur; }
      else if (q - cur == target) return rank;
      rank++;
    }
    cur = s->link3[cur & PREV_MASK];
    hops++;
  }
  return -1;
}

/* ppacorr.pas's LongestPas: the nearest 3 bytes the same on the 3-byte
   chain, then longer matches on the 4-byte chain, with the rank walk's
   skips over runs */
#define HOPS3 256
sz pc_longest(pcstate_t *s, sz q, sz maxHops, sz *dist) {
  const uint8_t *pl = s->plain;
  sz cur, hops, best = 0, maxLen, k, rq, rc, rs, lo;
  *dist = 0;
  maxLen = s->n - q; if (maxLen > MAX_MATCH) maxLen = MAX_MATCH;
  if (maxLen < MIN_MATCH) return 0;
  cur = chain3_start(s, q);
  hops = 0;
  while (cur >= 0 && q - cur <= WINDOW && hops < HOPS3) {
    if (pl[cur] == pl[q] && pl[cur + 1] == pl[q + 1] && pl[cur + 2] == pl[q + 2]) {
      best = common(pl + cur, pl + q, MIN_MATCH, maxLen);
      *dist = q - cur;
      break;
    }
    cur = s->link3[cur & PREV_MASK];
    hops++;
  }
  if (maxLen < 4 || best >= maxLen) {
    if (best >= MIN_MATCH) return best;
    *dist = 0;
    return 0;
  }
  cur = q < s->ins ? s->link4[q & PREV_MASK] : s->head4[hash4(s, q)];
  if (best >= 4)
    while (cur >= q - *dist) cur = s->link4[cur & PREV_MASK];
  hops = 0;
  rq = run_from(pl, q, maxLen);
  while (cur >= 0 && q - cur <= WINDOW && hops < maxHops) {
    if (rq >= 4 && rq < maxLen && pl[cur] == pl[q]) {
      rc = run_from(pl, cur, rq + 1);
      if (rc >= 4 && rc != rq) {
        hops++;
        rs = s->runs[cur & PREV_MASK];
        if (rc > rq) {
          if (rq > best) { best = rq; *dist = q - cur; }
        } else if (cur - (rq - rc) >= rs) {
          cur -= rq - rc; continue;
        } else {
          lo = q - WINDOW; if (lo < rs) lo = rs;
          k = rc + cur - lo;
          if (k > best) { best = k; *dist = q - lo; }
        }
        if (q - rs > WINDOW) break;
        cur = s->link4[rs & PREV_MASK];
        continue;
      }
    }
    if (pl[cur + best] == pl[q + best]) {
      k = common(pl + cur, pl + q, 0, maxLen);
      if (k > best) {
        best = k; *dist = q - cur;
        if (best >= maxLen) break;
      }
    }
    cur = s->link4[cur & PREV_MASK];
    hops++;
  }
  if (best >= MIN_MATCH) return best;
  *dist = 0;
  return 0;
}
