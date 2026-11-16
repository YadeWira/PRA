/* Layer 2a's hot spot in C: a block's tokens written as deflate bits, bit
   for bit what ppadeflate's Pascal Encode loop does (PPA_NOC=1 picks the
   Pascal one; the suite writes every stream both ways). The bit writer is
   ppadeflate's TBitWriter: 64 bits kept, 32 written at a time; the caller
   has made room for the worst (48 bits a token). Takes no memory and calls
   no library. */
#include <stdint.h>

#define LEN_258_AS_284 259

typedef struct {
  uint8_t *out; intptr_t *n; uint64_t *buf; int32_t *cnt;
  const uint16_t *tokLen, *tokVal; intptr_t first, count;
  const uint16_t *lcode; const uint8_t *llen;          /* the literal/length code */
  const uint16_t *dcode; const uint8_t *dlen;          /* the distance code */
  const uint16_t *lenSym;                              /* LenSym[3..258], from 3 */
  const uint8_t *distSym;                              /* DistSym[1..32768], from 1 */
  const uint16_t *lenBase; const uint8_t *lenExtra;    /* [257..285], from 257 */
  const uint16_t *distBase; const uint8_t *distExtra;  /* [0..29] */
} ppad_tokens_t;

void ppad_tokens(const ppad_tokens_t *a) {
  uint8_t *out = a->out;
  intptr_t n = *a->n;
  uint64_t buf = *a->buf;
  int cnt = *a->cnt;
#define PUT(v, k) do { buf |= (uint64_t)(v) << cnt; cnt += (k); \
    if (cnt >= 32) { out[n] = (uint8_t)buf; out[n + 1] = (uint8_t)(buf >> 8); out[n + 2] = (uint8_t)(buf >> 16); \
      out[n + 3] = (uint8_t)(buf >> 24); n += 4; buf >>= 32; cnt -= 32; } } while (0)
  for (intptr_t i = a->first; i < a->first + a->count; i++) {
    const int l = a->tokLen[i];
    if (l == 0) {
      const int sym = a->tokVal[i];
      PUT(a->lcode[sym], a->llen[sym]);
    } else {
      if (l == LEN_258_AS_284) {
        PUT(a->lcode[284], a->llen[284]);
        PUT(31, 5);
      } else {
        const int sym = a->lenSym[l - 3];
        PUT(a->lcode[sym], a->llen[sym]);
        PUT(l - a->lenBase[sym - 257], a->lenExtra[sym - 257]);
      }
      const int d = a->tokVal[i];
      const int sym = a->distSym[d - 1];
      PUT(a->dcode[sym], a->dlen[sym]);
      PUT(d - a->distBase[sym], a->distExtra[sym]);
    }
  }
#undef PUT
  *a->n = n; *a->buf = buf; *a->cnt = cnt;
}
