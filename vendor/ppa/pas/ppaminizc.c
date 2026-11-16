/* miniz's parse (tdefl_compress_normal, tdefl_compress_fast,
   tdefl_find_match) in C: bit for bit what ppaminiz's Pascal ParsePas does
   (the suite runs both and demands the same tokens and blocks; PPA_NOC=1
   picks the Pascal one). A port of miniz's (MIT / public domain, Rich
   Geldreich and contributors; NOTICE has its license). The caller gives the ring, the
   hash heads and links (zeroed) and room for the tokens and blocks. Takes
   no memory and calls no library. */
#include <stdint.h>

#define DICT_SIZE 32768
#define DICT_MASK (DICT_SIZE - 1)
#define MIN_MATCH 3
#define MAX_MATCH 258
#define HASH_SIZE (1 << 15)
#define HASH_SHIFT 5
#define LEVEL1_HASH_MASK 4095
#define CODE_BUF_SIZE (64 * 1024)
#define FAST_LOOKAHEAD 4096

#define MZ_RLE 0x10000
#define MZ_FILTER 0x20000
#define MZ_RAW 0x80000
#define MZ_GREEDY 0x4000

typedef struct {
  intptr_t firstTok, nTok, dictPos, total;
  intptr_t rawOk, final;
} mz_block_t;

/* ppaminiz.pas's TMzParse, field for field */
typedef struct {
  const uint8_t *plain; intptr_t n;
  intptr_t flags, fast;
  uint8_t *dict; uint16_t *hash, *next;
  uint16_t *tokLen, *tokVal; intptr_t nTok;
  mz_block_t *blocks; intptr_t nBlocks, maxBlocks;
  const intptr_t *refFirst, *refCount, *refPos, *refLen; intptr_t refBlocks;
  const uint16_t *refTokLen, *refTokVal;
  intptr_t useRef;
} mz_parse_t;

typedef struct {
  mz_parse_t *s;
  intptr_t lookPos, lookSize, dictSize, total, dictPos, codeOfs, flagsLeft;
  intptr_t savedLen, savedDist, savedLit;
  intptr_t src, srcLeft;
  intptr_t maxProbes[2];
  intptr_t blockTok;
  int ok;
} st_t;

static void token(st_t *t, intptr_t len, intptr_t val) {
  mz_parse_t *s = t->s;
  if (s->useRef) {
    intptr_t bi = s->nBlocks;
    if (bi >= s->refBlocks) t->ok = 0;
    else if (s->refFirst[bi] >= 0) {
      if (t->blockTok >= s->refCount[bi]) t->ok = 0;
      else {
        intptr_t k = s->refFirst[bi] + t->blockTok;
        if (s->refTokLen[k] != len || s->refTokVal[k] != val) t->ok = 0;
      }
    }
  }
  s->tokLen[s->nTok] = (uint16_t)len; s->tokVal[s->nTok] = (uint16_t)val;
  s->nTok++; t->blockTok++;
}

static inline void literal(st_t *t, intptr_t c) {
  token(t, 0, c);
  t->total++; t->codeOfs++;
  if (--t->flagsLeft == 0) { t->flagsLeft = 8; t->codeOfs++; }
}

static inline void match(st_t *t, intptr_t len, intptr_t dist) {
  token(t, len, dist);
  t->total += len; t->codeOfs += 3;
  if (--t->flagsLeft == 0) { t->flagsLeft = 8; t->codeOfs++; }
}

/* 0: too many blocks (the caller's room) */
static int flush(st_t *t, int final) {
  mz_parse_t *s = t->s;
  intptr_t bi = s->nBlocks;
  if (s->useRef) {
    if (bi >= s->refBlocks) t->ok = 0;
    else if (s->refFirst[bi] < 0) {
      if (s->refPos[bi] != t->dictPos || s->refLen[bi] != t->total) t->ok = 0;
    } else if (t->blockTok != s->refCount[bi]) t->ok = 0;
    if (final && bi + 1 != s->refBlocks) t->ok = 0;
  }
  if (bi >= s->maxBlocks) return 0;
  s->blocks[bi].firstTok = s->nTok - t->blockTok;
  s->blocks[bi].nTok = t->blockTok;
  s->blocks[bi].dictPos = t->dictPos;
  s->blocks[bi].total = t->total;
  s->blocks[bi].rawOk = t->lookPos - t->dictPos <= t->dictSize;
  s->blocks[bi].final = final;
  s->nBlocks++;
  t->dictPos += t->total;
  t->total = 0; t->codeOfs = 1; t->flagsLeft = 8; t->blockTok = 0;
  return 1;
}

static inline void put_dict(uint8_t *dict, intptr_t dst, uint8_t c) {
  dict[dst] = c;
  if (dst < MAX_MATCH - 1) dict[DICT_SIZE + dst] = c;
}

static void find_match(st_t *t, intptr_t maxDist, intptr_t maxLen, intptr_t *mDist, intptr_t *mLen) {
  const uint8_t *dict = t->s->dict;
  const uint16_t *next = t->s->next;
  intptr_t pos = t->lookPos & DICT_MASK, ml = *mLen, probe = pos, nextP, dist = 0, plen, k;
  intptr_t left = t->maxProbes[ml >= 32];
  uint8_t c0 = dict[pos + ml], c1 = dict[pos + ml - 1];
  if (maxLen <= ml) return;
  for (;;) {
    for (;;) {
      int hit = 0;
      if (--left == 0) return;
      for (k = 0; k < 3; k++) {
        nextP = next[probe];
        if (!nextP) return;
        dist = (t->lookPos - nextP) & 0xFFFF;
        if (dist > maxDist) return;
        probe = nextP & DICT_MASK;
        if (dict[probe + ml] == c0 && dict[probe + ml - 1] == c1) { hit = 1; break; }
      }
      if (hit) break;
    }
    if (!dist) return;
    plen = 0;
    while (plen < maxLen && dict[pos + plen] == dict[probe + plen]) plen++;
    if (plen > ml) {
      *mDist = dist; ml = plen; *mLen = ml;
      if (ml == maxLen) return;
      c0 = dict[pos + ml]; c1 = dict[pos + ml - 1];
    }
  }
}

static int normal(st_t *t) {
  mz_parse_t *s = t->s;
  uint8_t *dict = s->dict;
  uint16_t *hash = s->hash, *next = s->next;
  while (t->ok && (t->srcLeft > 0 || t->lookSize > 0)) {
    intptr_t dst, ins, h, num, i, curLen, curDist, curPos, move;
    uint8_t c;
    if (t->lookSize + t->dictSize >= MIN_MATCH - 1) {
      dst = (t->lookPos + t->lookSize) & DICT_MASK;
      ins = t->lookPos + t->lookSize - 2;
      h = ((intptr_t)dict[ins & DICT_MASK] << HASH_SHIFT) ^ dict[(ins + 1) & DICT_MASK];
      num = t->srcLeft; if (num > MAX_MATCH - t->lookSize) num = MAX_MATCH - t->lookSize;
      t->srcLeft -= num; t->lookSize += num;
      for (i = 0; i < num; i++) {
        c = s->plain[t->src++];
        put_dict(dict, dst, c);
        h = ((h << HASH_SHIFT) ^ c) & (HASH_SIZE - 1);
        next[ins & DICT_MASK] = hash[h];
        hash[h] = (uint16_t)ins;
        dst = (dst + 1) & DICT_MASK;
        ins++;
      }
    } else {
      while (t->srcLeft > 0 && t->lookSize < MAX_MATCH) {
        c = s->plain[t->src++];
        dst = (t->lookPos + t->lookSize) & DICT_MASK;
        t->srcLeft--;
        put_dict(dict, dst, c);
        t->lookSize++;
        if (t->lookSize + t->dictSize >= MIN_MATCH) {
          ins = t->lookPos + (t->lookSize - 1) - 2;
          h = (((intptr_t)dict[ins & DICT_MASK] << (HASH_SHIFT * 2)) ^
               ((intptr_t)dict[(ins + 1) & DICT_MASK] << HASH_SHIFT) ^ c) & (HASH_SIZE - 1);
          next[ins & DICT_MASK] = hash[h];
          hash[h] = (uint16_t)ins;
        }
      }
    }
    if (t->dictSize > DICT_SIZE - t->lookSize) t->dictSize = DICT_SIZE - t->lookSize;

    move = 1;
    curDist = 0;
    curLen = t->savedLen ? t->savedLen : MIN_MATCH - 1;
    curPos = t->lookPos & DICT_MASK;
    if (s->flags & (MZ_RLE | MZ_RAW)) {
      if (t->dictSize && !(s->flags & MZ_RAW)) {
        c = dict[(curPos - 1) & DICT_MASK];
        curLen = 0;
        while (curLen < t->lookSize && dict[curPos + curLen] == c) curLen++;
        if (curLen < MIN_MATCH) curLen = 0; else curDist = 1;
      }
    } else
      find_match(t, t->dictSize, t->lookSize, &curDist, &curLen);
    if ((curLen == MIN_MATCH && curDist >= 8 * 1024) || curPos == curDist ||
        ((s->flags & MZ_FILTER) && curLen <= 5)) {
      curDist = 0; curLen = 0;
    }
    if (t->savedLen) {
      if (curLen > t->savedLen) {
        literal(t, t->savedLit);
        if (curLen >= 128) {
          match(t, curLen, curDist);
          t->savedLen = 0; move = curLen;
        } else {
          t->savedLit = dict[curPos]; t->savedDist = curDist; t->savedLen = curLen;
        }
      } else {
        match(t, t->savedLen, t->savedDist);
        move = t->savedLen - 1; t->savedLen = 0;
      }
    } else if (!curDist)
      literal(t, dict[curPos]);
    else if ((s->flags & MZ_GREEDY) || (s->flags & MZ_RLE) || curLen >= 128) {
      match(t, curLen, curDist);
      move = curLen;
    } else {
      t->savedLit = dict[curPos]; t->savedDist = curDist; t->savedLen = curLen;
    }
    t->lookPos += move;
    t->lookSize -= move;
    t->dictSize += move; if (t->dictSize > DICT_SIZE) t->dictSize = DICT_SIZE;
    if (t->codeOfs > CODE_BUF_SIZE - 8 ||
        (t->total > 31 * 1024 && (((t->codeOfs * 115) >> 7) >= t->total || (s->flags & MZ_RAW))))
      if (!flush(t, 0)) return 0;
  }
  return 1;
}

static int fast(st_t *t) {
  mz_parse_t *s = t->s;
  uint8_t *dict = s->dict;
  uint16_t *hash = s->hash;
  intptr_t curPos = t->lookPos & DICT_MASK;
  while (t->ok && (t->srcLeft > 0 || t->lookSize > 0)) {
    intptr_t dst = (t->lookPos + t->lookSize) & DICT_MASK, num, n, i, k;
    num = t->srcLeft; if (num > FAST_LOOKAHEAD - t->lookSize) num = FAST_LOOKAHEAD - t->lookSize;
    t->srcLeft -= num; t->lookSize += num;
    while (num > 0) {
      n = DICT_SIZE - dst; if (n > num) n = num;
      for (i = 0; i < n; i++) dict[dst + i] = s->plain[t->src + i];
      if (dst < MAX_MATCH - 1) {
        k = MAX_MATCH - 1 - dst; if (k > n) k = n;
        for (i = 0; i < k; i++) dict[DICT_SIZE + dst + i] = s->plain[t->src + i];
      }
      t->src += n;
      dst = (dst + n) & DICT_MASK;
      num -= n;
    }
    if (t->dictSize > DICT_SIZE - t->lookSize) t->dictSize = DICT_SIZE - t->lookSize;
    while (t->ok && t->lookSize >= 4) {
      intptr_t len = 1, dist, probe, h;
      uint32_t tri = (uint32_t)dict[curPos] | ((uint32_t)dict[curPos + 1] << 8) | ((uint32_t)dict[curPos + 2] << 16);
      h = (tri ^ (tri >> 17)) & LEVEL1_HASH_MASK;
      probe = hash[h];
      hash[h] = (uint16_t)t->lookPos;
      dist = (t->lookPos - probe) & 0xFFFF;
      probe &= DICT_MASK;
      if (dist <= t->dictSize && dict[probe] == (uint8_t)tri && dict[probe + 1] == (uint8_t)(tri >> 8) &&
          dict[probe + 2] == (uint8_t)(tri >> 16)) {
        int stop = 0;
        i = 2;
        for (k = 1; k <= 128; k++) {
          if (dict[curPos + i] != dict[probe + i] || dict[curPos + i + 1] != dict[probe + i + 1]) { stop = 1; break; }
          if (k < 128) i += 2;
        }
        if (stop) len = i + (dict[curPos + i] == dict[probe + i]);
        else len = dist ? MAX_MATCH : 0;
        if (len < MIN_MATCH || (len == MIN_MATCH && dist >= 8 * 1024)) {
          len = 1;
          literal(t, (uint8_t)tri);
        } else {
          if (len > t->lookSize) len = t->lookSize;
          match(t, len, dist);
        }
      } else
        literal(t, (uint8_t)tri);
      t->lookPos += len;
      t->dictSize += len; if (t->dictSize > DICT_SIZE) t->dictSize = DICT_SIZE;
      curPos = (curPos + len) & DICT_MASK;
      t->lookSize -= len;
      if (t->codeOfs > CODE_BUF_SIZE - 8) if (!flush(t, 0)) return 0;
    }
    while (t->ok && t->lookSize > 0) {
      literal(t, dict[curPos]);
      t->lookPos++;
      t->dictSize++; if (t->dictSize > DICT_SIZE) t->dictSize = DICT_SIZE;
      curPos = (curPos + 1) & DICT_MASK;
      t->lookSize--;
      if (t->codeOfs > CODE_BUF_SIZE - 8) if (!flush(t, 0)) return 0;
    }
  }
  return 1;
}

/* 1: the parse made, the ref followed (if any); 0: it parted from the ref
   (or the blocks did not fit) */
intptr_t ppamz_parse(mz_parse_t *s) {
  st_t t;
  t.s = s;
  t.maxProbes[0] = 1 + ((s->flags & 0xFFF) + 2) / 3;
  t.maxProbes[1] = 1 + (((s->flags & 0xFFF) >> 2) + 2) / 3;
  t.lookPos = t.lookSize = t.dictSize = t.total = t.dictPos = 0;
  t.codeOfs = 1; t.flagsLeft = 8;
  t.savedLen = t.savedDist = t.savedLit = 0;
  t.src = 0; t.srcLeft = s->n;
  t.blockTok = 0;
  t.ok = 1;
  s->nTok = 0; s->nBlocks = 0;
  if (!(s->fast ? fast(&t) : normal(&t))) return 0;
  if (t.ok && !flush(&t, 1)) return 0;
  return t.ok;
}
