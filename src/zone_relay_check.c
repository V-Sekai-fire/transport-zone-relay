#include "zone_relay.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define MAGIC "RTRACE1\n"
enum { JOIN = 1, LEAVE, PUT, FRAME, TICK, UNREAD, PERSON_AT, KINDS };
static const char *const NAME[KINDS] = {"none", "join", "leave", "put", "frame", "tick", "unread", "person_at"};
typedef struct { int kind; size_t at, body, len, end; } rec_t;
typedef struct { long records, bad; int kind; size_t at; char why[96]; } run_t;
static zr_zone_t zone;
static uint32_t u16(const uint8_t *p) { return (uint32_t)p[0] | (uint32_t)p[1] << 8; }
static uint32_t u32(const uint8_t *p) { return u16(p) | u16(p + 2) << 16; }
static int32_t i32(const uint8_t *p) {
  uint32_t v = u32(p);
  return v < 0x80000000u ? (int32_t)v : (int32_t)(v - 0x80000000u) - 2147483647 - 1;
}
static int next(const uint8_t *d, size_t n, size_t at, rec_t *r) {
  static const size_t head[KINDS] = {0, 5, 5, 5, 5, 1, 1, 2}, tail[KINDS] = {0, 4, 1, 1, 0, 4, 4, 4};
  r->kind = d[at]; r->at = at; r->len = 0;
  if (r->kind < JOIN || r->kind >= KINDS) return -1;
  if (n - at < head[r->kind]) return -1;
  if (r->kind == PUT || r->kind == FRAME) r->len = u16(d + at + 3);
  r->body = at + head[r->kind];
  if (n - r->body < r->len + tail[r->kind]) return -1;
  r->end = r->body + r->len + tail[r->kind];
  return 0;
}
static int differs(run_t *o, long want, long got) {
  if (want == got) return 0;
  snprintf(o->why, sizeof o->why, "want=%ld got=%ld", want, got);
  return 1;
}
static int frame_differs(run_t *o, const uint8_t *want, size_t wn, const uint8_t *got, size_t gn) {
  if (!got || wn != gn) { snprintf(o->why, sizeof o->why, "length want=%lu got=%lu", (unsigned long)wn, (unsigned long)gn); return 1; }
  for (size_t i = 0; i < wn; i++)
    if (want[i] != got[i]) { snprintf(o->why, sizeof o->why, "byte %lu of %lu want=%u got=%u", (unsigned long)i, (unsigned long)wn, want[i], got[i]); return 1; }
  return 0;
}
static void replay(const uint8_t *d, size_t n, run_t *o) {
  rec_t r;
  size_t at = sizeof MAGIC - 1, gn;
  o->records = 0; o->bad = -1; o->kind = 0; o->why[0] = 0;
  zr_reset(&zone);
  while (at < n) {
    int bad;
    o->at = at;
    if (next(d, n, at, &r) < 0) { o->bad = o->records; snprintf(o->why, sizeof o->why, "the record is cut short or has no known kind"); return; }
    const uint8_t *a = d + r.at + 1, *ans = d + r.body + r.len, *got;
    switch (r.kind) {
    case JOIN: bad = differs(o, i32(ans), zr_join(&zone, i32(a))); break;
    case LEAVE: bad = differs(o, ans[0], zr_leave(&zone, i32(a))); break;
    case PUT: bad = differs(o, ans[0], zr_put(&zone, a[0], a[1], d + r.body, r.len)); break;
    case FRAME: got = zr_frame(&zone, a[0], a[1], &gn); bad = frame_differs(o, d + r.body, r.len, got, gn); break;
    case TICK: bad = differs(o, (long)u32(ans), (long)(uint32_t)zr_tick(&zone)); break;
    case UNREAD: bad = differs(o, (long)u32(ans), (long)(uint32_t)zr_unread(&zone)); break;
    default: bad = differs(o, i32(ans), zr_person_at(&zone, a[0])); break;
    }
    if (bad) { o->bad = o->records; o->kind = r.kind; return; }
    o->records++;
    at = r.end;
  }
}
static long plant(uint8_t *d, size_t n, const char *what) {
  rec_t r;
  int payload = strcmp(what, "payload") == 0, kind = payload ? PUT : 0;
  for (int k = JOIN; k < KINDS && !kind; k++)
    if (strcmp(what, NAME[k]) == 0) kind = k;
  if (!kind) return -1;
  long i = 0;
  for (size_t at = sizeof MAGIC - 1; at < n && next(d, n, at, &r) == 0; at = r.end, i++) {
    if (r.kind != kind || (kind == FRAME && r.len == 0)) continue;
    if (payload && (r.len == 0 || d[r.end - 1] != 1)) continue;
    size_t where = payload ? r.body : r.end - 1;
    d[where] ^= 1;
    printf("FLIP %s record=%ld offset=%lu\n", what, i, (unsigned long)where);
    return i;
  }
  return -1;
}
int main(int argc, char **argv) {
  const char *path = 0, *flip = 0;
  for (int i = 1; i < argc; i++) {
    if (strcmp(argv[i], "--flip") == 0) flip = "frame";
    else if (strncmp(argv[i], "--flip=", 7) == 0) flip = argv[i] + 7;
    else path = argv[i];
  }
  FILE *f = path ? fopen(path, "rb") : 0;
  if (!f) { puts("RELAY RESULT: ERROR give a trace file that can be read, then --flip[=<kind>|payload]"); return 2; }
  fseek(f, 0, SEEK_END);
  long size = ftell(f);
  rewind(f);
  uint8_t *d = size > 0 ? malloc((size_t)size) : 0;
  if (!d || fread(d, 1, (size_t)size, f) != (size_t)size) { puts("RELAY RESULT: ERROR the trace file cannot be read"); return 2; }
  fclose(f);
  size_t n = (size_t)size;
  if (n < sizeof MAGIC - 1 || memcmp(d, MAGIC, sizeof MAGIC - 1) != 0) { puts("RELAY record=0 kind=magic the file does not start with RTRACE1 RESULT: FAIL"); return 1; }
  long target = flip ? plant(d, n, flip) : -1;
  if (flip && target < 0) { printf("RELAY RESULT: ERROR the trace has no record to flip for %s\n", flip); return 2; }
  run_t o;
  replay(d, n, &o);
  free(d);
  if (o.bad < 0 && !flip) { printf("RELAY records=%ld RESULT: PASS\n", o.records); return 0; }
  if (o.bad < 0) { printf("RELAY records=%ld RESULT: ERROR the flip at record %ld was not caught\n", o.records, target); return 2; }
  int late = flip && strcmp(flip, "payload") == 0;
  int caught = !flip || (late ? o.bad > target && o.kind == FRAME : o.bad == target);
  printf("RELAY record=%ld kind=%s offset=%lu %s RESULT: %s\n", o.bad, NAME[o.kind], (unsigned long)o.at, o.why,
         caught ? "FAIL" : "ERROR the flip was caught at another record");
  return caught ? 1 : 2;
}
