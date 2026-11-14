/* Spans as OTLP protobuf, written from C. A header-only port of the span half of the engine's
 * open_telemetry module (see docs/otel.md): spans are recorded after the fact into a fixed ring, so a
 * hot loop pays for one struct copy, and otel_flush appends the ring as one length-prefixed ScopeSpans
 * record. There is one format and one path; a caller that wants no output opens /dev/null. Nothing here
 * allocates or opens a socket, and only otel_flush writes. */
#ifndef OTEL_SPAN_H
#define OTEL_SPAN_H
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define OTEL_CAP 4096
#define OTEL_ATTRS 6

typedef struct {
  uint64_t t0, t1, sid, psid; /* wall nanoseconds; psid 0 means a root */
  const char *name;
  uint32_t nattr;
  const char *key[OTEL_ATTRS];
  int64_t val[OTEL_ATTRS];
} otel_rec_t;

typedef struct {
  uint64_t tid_hi, tid_lo, rng;
  int64_t wall_off; /* wall minus monotonic, in nanoseconds, fixed at open */
  uint32_t n, dropped;
  FILE *out;
  otel_rec_t r[OTEL_CAP];
} otel_t;

static inline uint64_t otel_next(otel_t *o) { /* xorshift64, logical shifts */
  o->rng ^= o->rng << 13; o->rng ^= o->rng >> 7; o->rng ^= o->rng << 17;
  return o->rng;
}

static inline uint64_t otel_id(otel_t *o) { uint64_t v = otel_next(o); return v ? v : 1; }

/* Opens path for appending. */
static inline int otel_open(otel_t *o, const char *path, uint64_t seed) {
  struct timespec w, m;
  memset(o, 0, offsetof(otel_t, r));
  clock_gettime(CLOCK_REALTIME, &w); clock_gettime(CLOCK_MONOTONIC, &m);
  o->wall_off = ((int64_t)w.tv_sec - (int64_t)m.tv_sec) * 1000000000LL + ((int64_t)w.tv_nsec - (int64_t)m.tv_nsec);
  o->rng = seed ? seed : (uint64_t)w.tv_nsec * 2654435761u + 88172645463325252ull;
  o->tid_hi = otel_id(o); o->tid_lo = otel_id(o);
  o->out = fopen(path, "a");
  return o->out ? 0 : -1;
}

static inline uint64_t otel_wall(const otel_t *o, int64_t mono_ns) { return (uint64_t)(mono_ns + o->wall_off); }

/* Records a finished span; returns its id so a child can name it. A full ring drops and counts. */
static inline uint64_t otel_span_as(otel_t *o, uint64_t sid, const char *name, uint64_t parent, int64_t mono0, int64_t mono1,
                                    uint32_t nattr, const char *const *keys, const int64_t *vals) {
  if (o->n >= OTEL_CAP) { o->dropped++; return sid; }
  otel_rec_t *r = &o->r[o->n++];
  r->t0 = otel_wall(o, mono0); r->t1 = otel_wall(o, mono1); r->sid = sid; r->psid = parent; r->name = name;
  r->nattr = nattr > OTEL_ATTRS ? OTEL_ATTRS : nattr;
  for (uint32_t i = 0; i < r->nattr; i++) { r->key[i] = keys[i]; r->val[i] = vals[i]; }
  return sid;
}

static inline uint64_t otel_span(otel_t *o, const char *name, uint64_t parent, int64_t mono0, int64_t mono1, uint32_t nattr,
                                 const char *const *keys, const int64_t *vals) {
  return otel_span_as(o, otel_id(o), name, parent, mono0, mono1, nattr, keys, vals);
}

/* Protobuf (OTLP/HTTP's own encoding). A record is a 4-byte little-endian length and one ScopeSpans
 * message. The resource, which may hold a key, is not written: the poster wraps each record in a
 * ResourceSpans with the resource it reads from its own environment. */
static inline uint32_t otel_pb_varint(uint8_t *b, uint64_t v) {
  uint32_t n = 0;
  while (v >= 0x80) { if (b) b[n] = (uint8_t)(v | 0x80); n++; v >>= 7; }
  if (b) b[n] = (uint8_t)v;
  return n + 1;
}
static inline uint32_t otel_pb_bytes(uint8_t *b, uint8_t tag, const void *p, uint32_t len) {
  uint32_t n = 1 + otel_pb_varint(b ? b + 1 : 0, len);
  if (b) { b[0] = tag; memcpy(b + n, p, len); }
  return n + len;
}
static inline void otel_pb_be(uint8_t *b, uint64_t v) { for (int i = 0; i < 8; i++) b[i] = (uint8_t)(v >> (56 - 8 * i)); }
static inline void otel_pb_le(uint8_t *b, uint64_t v) { for (int i = 0; i < 8; i++) b[i] = (uint8_t)(v >> (8 * i)); }

/* Encodes one Span into b (or only measures when b is null). 512 bytes always hold one. */
static inline uint32_t otel_pb_span(const otel_t *o, const otel_rec_t *r, uint8_t *b) {
  uint8_t id[16]; uint32_t n = 0;
  otel_pb_be(id, o->tid_hi); otel_pb_be(id + 8, o->tid_lo);
  n += otel_pb_bytes(b ? b + n : 0, 0x0A, id, 16);
  otel_pb_be(id, r->sid); n += otel_pb_bytes(b ? b + n : 0, 0x12, id, 8);
#ifndef OTEL_PLANT_PBPARENT
  if (r->psid) { otel_pb_be(id, r->psid); n += otel_pb_bytes(b ? b + n : 0, 0x22, id, 8); }
#endif
  n += otel_pb_bytes(b ? b + n : 0, 0x2A, r->name, (uint32_t)strlen(r->name));
  if (b) b[n] = 0x30;
  n++; n += otel_pb_varint(b ? b + n : 0, 1);
  if (b) { b[n] = 0x39; otel_pb_le(b + n + 1, r->t0); b[n + 9] = 0x41;
#ifdef OTEL_PLANT_PBTIMES
    otel_pb_le(b + n + 10, r->t0); }
#else
    otel_pb_le(b + n + 10, r->t1); }
#endif
  n += 18;
  for (uint32_t k = 0; k < r->nattr; k++) {
    uint8_t kv[96]; uint32_t m = otel_pb_bytes(kv, 0x0A, r->key[k], (uint32_t)strlen(r->key[k]));
    uint8_t any[16]; uint32_t a = 0;
    any[a++] = 0x18; a += otel_pb_varint(any + a, (uint64_t)r->val[k]);
    m += otel_pb_bytes(kv + m, 0x12, any, a);
    n += otel_pb_bytes(b ? b + n : 0, 0x4A, kv, m);
  }
  return n;
}

static inline void otel_flush(otel_t *o) {
  if (!o->out || o->n == 0) return;
  static const char scope[] = "entity-server";
  uint8_t head[32], tmp[512], sc[32];
  uint32_t sclen = otel_pb_bytes(sc, 0x0A, scope, (uint32_t)strlen(scope)); /* InstrumentationScope{name} */
  uint32_t body = 1 + otel_pb_varint(0, sclen) + sclen;
  for (uint32_t i = 0; i < o->n; i++) { uint32_t m = otel_pb_span(o, &o->r[i], 0); body += 1 + otel_pb_varint(0, m) + m; }
  head[0] = (uint8_t)body; head[1] = (uint8_t)(body >> 8); head[2] = (uint8_t)(body >> 16); head[3] = (uint8_t)(body >> 24);
  fwrite(head, 1, 4, o->out);
  { uint32_t h = 0; head[h++] = 0x0A; h += otel_pb_varint(head + h, sclen); fwrite(head, 1, h, o->out); fwrite(sc, 1, sclen, o->out); }
  for (uint32_t i = 0; i < o->n; i++) {
    uint32_t m = otel_pb_span(o, &o->r[i], tmp), h = 0;
    head[h++] = 0x12; h += otel_pb_varint(head + h, m);
    fwrite(head, 1, h, o->out); fwrite(tmp, 1, m, o->out);
  }
  fflush(o->out);
  o->n = 0;
}

static inline void otel_close(otel_t *o) { otel_flush(o); if (o->out) fclose(o->out); o->out = 0; }
#endif
