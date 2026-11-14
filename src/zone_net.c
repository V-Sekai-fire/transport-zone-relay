#ifdef ZN_SENDMMSG
#define _GNU_SOURCE
#else
#define _POSIX_C_SOURCE 200809L
#endif
#include "zone_net.h"
#include "zone_relay.h"
#include "otel_span.h"
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <sys/stat.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>
#define TABLE (ZN_MAX_PEOPLE * 2)
typedef struct { struct sockaddr_in a; int slot; } who_t;
static zr_zone_t zones[ZN_MAX_ZONES];
static who_t who[ZN_MAX_PEOPLE];
static int32_t table[TABLE];
static int32_t seated[ZN_MAX_ZONES][ZR_SLOTS];
static int64_t lat[1 << 16];
static int people;
static otel_t ot_store;
static int64_t now_ns(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return (int64_t)t.tv_sec * 1000000000LL + t.tv_nsec; }
static int cmp(const void *x, const void *y) { int64_t a = *(const int64_t *)x, b = *(const int64_t *)y; return (a > b) - (a < b); }
static int same(const struct sockaddr_in *x, const struct sockaddr_in *y) { return x->sin_addr.s_addr == y->sin_addr.s_addr && x->sin_port == y->sin_port; }
static int person_of(const struct sockaddr_in *a) {
  uint32_t h = (a->sin_addr.s_addr * 2654435761u) ^ ((uint32_t)a->sin_port * 40503u);
  for (uint32_t i = 0; i < TABLE; i++) {
    uint32_t at = (h + i) & (TABLE - 1);
    if (table[at] == 0) {
      if (people == ZN_MAX_PEOPLE) return -1;
      who[people].a = *a; who[people].slot = -1; table[at] = people + 1;
      return people++;
    }
    if (same(&who[table[at] - 1].a, a)) return table[at] - 1;
  }
  return -1;
}
static uint32_t allow[ZN_MAX_ALLOW];
static int allow_n, allow_on;
static struct stat allow_seen;
int zn_allow_has(uint32_t a) {
  int lo = 0, hi = allow_n - 1;
  while (lo <= hi) { int m = (lo + hi) / 2; if (allow[m] == a) return 1; if (allow[m] < a) lo = m + 1; else hi = m - 1; }
  return 0;
}
static int cmp_u32(const void *x, const void *y) { uint32_t a = *(const uint32_t *)x, b = *(const uint32_t *)y; return (a > b) - (a < b); }
int zn_allow_load(const char *path) {
  static char buf[ZN_MAX_ALLOW * 16 + 16];
  int fd = open(path, O_RDONLY), n = 0;
  struct stat st;
  if (fd < 0) return -errno;
  if (fstat(fd, &st) < 0) { int e = errno; close(fd); return -e; }
  for (;;) { ssize_t r = read(fd, buf + n, sizeof buf - 1 - (size_t)n); if (r < 0) { int e = errno; close(fd); return -e; } if (r == 0) break; n += (int)r; if (n >= (int)sizeof buf - 1) { close(fd); return -EFBIG; } }
  close(fd);
  buf[n] = 0;
  int cnt = 0; char *p = buf;
  while (*p) {
    char *e = strchr(p, '\n'); struct in_addr ia;
    if (e) *e = 0;
    if (*p && *p != '#') { if (inet_pton(AF_INET, p, &ia) != 1) return -EINVAL; if (cnt == ZN_MAX_ALLOW) return -EFBIG; allow[cnt++] = ia.s_addr; }
    if (!e) break;
    p = e + 1;
  }
  qsort(allow, (size_t)cnt, sizeof allow[0], cmp_u32);
  allow_n = cnt; allow_on = 1; allow_seen = st;
  return cnt;
}
static int allow_changed(const char *path) {
  struct stat st;
  if (stat(path, &st) < 0) return 0;
  return st.st_ino != allow_seen.st_ino || st.st_mtime != allow_seen.st_mtime || st.st_size != allow_seen.st_size;
}
static int bind_udp(const char *host, uint16_t port) {
  int fd = socket(AF_INET, SOCK_DGRAM, 0);
  struct sockaddr_in a; int big = 1 << 22;
  if (fd < 0) return -1;
  memset(&a, 0, sizeof a); a.sin_family = AF_INET; a.sin_port = htons(port);
  if (inet_pton(AF_INET, host, &a.sin_addr) != 1 || bind(fd, (struct sockaddr *)&a, sizeof a) < 0) { close(fd); return -1; }
  setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &big, sizeof big);
  setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &big, sizeof big);
  fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);
  return fd;
}
int zn_run(const char *host, uint16_t port, uint32_t ticks, uint32_t slow_ns, zn_report_t *out) {
  static uint8_t dgram[ZR_FRAME_MAX + 1];
  int fd[2];
  if (ticks == 0 || ticks > (1u << 16) || port == 0 || port == 65535) return -EINVAL;
  const char *allow_path = getenv("ZONE_ALLOW_FILE");
  allow_on = 0; allow_n = 0;
  if (allow_path && *allow_path) { int lr = zn_allow_load(allow_path); if (lr < 0) return lr; }
  else if (strncmp(host, "127.", 4) != 0) return -EPERM;
  memset(out, 0, sizeof *out); memset(table, 0, sizeof table); people = 0;
  for (int z = 0; z < ZN_MAX_ZONES; z++) { zr_reset(&zones[z]); for (int s = 0; s < ZR_SLOTS; s++) seated[z][s] = -1; }
  fd[0] = bind_udp(host, port);
  fd[1] = bind_udp(host, (uint16_t)(port + 1));
  if (fd[0] < 0 || fd[1] < 0) { if (fd[0] >= 0) close(fd[0]); if (fd[1] >= 0) close(fd[1]); return -EADDRINUSE; }
  int64_t start = now_ns(), next = start + ZN_TICK_NS;
  otel_t *ot = 0; uint64_t run_sid = 0;
  { const char *op = getenv("ZONE_OTEL");
    if (op && *op && otel_open(&ot_store, "zone-relay", getenv("OTEL_RESOURCE_ATTRIBUTES"), op, 0) == 0) {
      const char *of = getenv("ZONE_OTEL_FORMAT"); ot = &ot_store; ot->pb = of && strcmp(of, "pb") == 0; run_sid = otel_id(ot); } }
  uint32_t counted = 0, rounds = 0;
  for (uint32_t t = 0; counted < ticks; t++, rounds++) {
    int64_t d = next - now_ns();
    if (d > 0) { struct timespec r; r.tv_sec = (time_t)(d / 1000000000LL); r.tv_nsec = (long)(d % 1000000000LL); nanosleep(&r, 0); }
    if (allow_on && rounds % ZN_ALLOW_POLL_TICKS == 0 && allow_changed(allow_path) && zn_allow_load(allow_path) >= 0) {
#ifndef ZN_PLANT_NO_EVICT
      for (int p = 0; p < people; p++)
        if (who[p].slot >= 0 && !zn_allow_has(who[p].a.sin_addr.s_addr)) {
          zr_leave(&zones[p / ZR_SLOTS], p); seated[p / ZR_SLOTS][who[p].slot] = -1; who[p].slot = -1; out->evicted++;
        }
#endif
    }
    int64_t t0 = now_ns(), first = -1;
    uint32_t fi0 = out->frames_in, do0 = out->datagrams_out, re0 = out->refused;
    for (int half = 0; half < 2; half++) {
      for (;;) {
        struct sockaddr_in from; socklen_t fl = sizeof from;
        ssize_t n = recvfrom(fd[half], dgram, sizeof dgram, 0, (struct sockaddr *)&from, &fl);
        if (n < 0) break;
        if (first < 0) first = now_ns();
        if (n > ZR_FRAME_MAX) { out->refused++; continue; }
#ifdef ZN_PLANT_ALLOW_OFF
        if (0) {
#else
        if (allow_on && !zn_allow_has(from.sin_addr.s_addr)) {
#endif
          out->unlisted++; continue; }
        int p = person_of(&from);
        if (p < 0) { out->strangers++; continue; }
        int zi = p / ZR_SLOTS;
        zr_zone_t *z = &zones[zi];
        if (who[p].slot < 0 || zr_person_at(z, who[p].slot) != p) {
          who[p].slot = zr_join(z, p);
          if (who[p].slot < 0) { out->refused++; continue; }
          seated[zi][who[p].slot] = p;
        }
        int slot = who[p].slot;
        if (!zr_put(z, slot, half, dgram, (size_t)n)) { out->refused++; continue; }
        out->frames_in++;
#ifdef ZN_SENDMMSG
        {
          struct mmsghdr mm[ZR_SLOTS]; struct iovec iv[ZR_SLOTS]; int nm = 0, sent;
          memset(mm, 0, sizeof mm);
          for (int v = 0; v < ZR_SLOTS; v++) {
            size_t len;
            if (v == slot || zr_person_at(z, v) < 0) continue;
            const uint8_t *held = zr_frame(z, v, (slot > v ? slot - 1 : slot) * 2 + half, &len);
            iv[nm].iov_base = (void *)held; iv[nm].iov_len = len;
            mm[nm].msg_hdr.msg_name = &who[seated[zi][v]].a; mm[nm].msg_hdr.msg_namelen = sizeof who[0].a;
            mm[nm].msg_hdr.msg_iov = &iv[nm]; mm[nm].msg_hdr.msg_iovlen = 1; nm++;
          }
#ifdef ZN_PLANT_BATCH_SHORT
          if (nm > 1) nm--;
#endif
#ifdef ZN_PLANT_HALF
          sent = nm ? sendmmsg(fd[1 - half], mm, (unsigned)nm, 0) : 0;
#else
          sent = nm ? sendmmsg(fd[half], mm, (unsigned)nm, 0) : 0;
#endif
          if (sent < 0) sent = 0;
          out->datagrams_out += (uint32_t)sent; out->send_failed += (uint32_t)(nm - sent);
        }
#else
        for (int v = 0; v < ZR_SLOTS; v++) {
          size_t len;
          if (v == slot || zr_person_at(z, v) < 0) continue;
          const uint8_t *held = zr_frame(z, v, (slot > v ? slot - 1 : slot) * 2 + half, &len);
#ifdef ZN_PLANT_HALF
          if (sendto(fd[1 - half], held, len, 0, (const struct sockaddr *)&who[seated[zi][v]].a, sizeof who[0].a) >= 0) out->datagrams_out++;
#else
          if (sendto(fd[half], held, len, 0, (const struct sockaddr *)&who[seated[zi][v]].a, sizeof who[0].a) >= 0) out->datagrams_out++;
#endif
          else out->send_failed++;
        }
#endif
      }
    }
    if (slow_ns) { int64_t end = now_ns() + slow_ns; while (now_ns() < end) { } }
    int64_t t1 = now_ns();
    if (ot) {
      static const char *const k[5] = { "people", "frames_in", "datagrams_out", "refused", "tick" };
      int64_t v[5]; v[0] = people; v[1] = (int64_t)out->frames_in - fi0; v[2] = (int64_t)out->datagrams_out - do0;
      v[3] = (int64_t)out->refused - re0; v[4] = counted;
      otel_span(ot, "relay.tick", run_sid, t0, t1, 5, k, v);
      if (ot->n >= OTEL_CAP / 2 && next - t1 > 3000000) otel_flush(ot);
    }
    uint32_t wall = (uint32_t)((t1 - start) / ZN_TICK_NS);
    if (wall <= counted) wall = counted + 1;
    if (wall > counted + 1) out->overruns++;
#ifdef ZN_PLANT_NO_CATCH_UP
    wall = counted + 1;
#endif
    for (; counted < wall; counted++)
      for (int z = 0; z < (people + ZR_SLOTS - 1) / ZR_SLOTS; z++) zr_tick(&zones[z]);
    lat[t] = t1 - (first >= 0 ? first : t0);
    if (first >= 0) out->work_ns += t1 - first;
    next = start + (int64_t)(counted + 1) * ZN_TICK_NS;
#ifdef ZN_PLANT_NO_CATCH_UP
    next = t1 + ZN_TICK_NS;
#endif
  }
  out->ticks = counted; out->people = (uint32_t)people;
  if (ot) {
    static const char *const k[4] = { "ticks", "people", "frames_in", "datagrams_out" };
    int64_t v[4]; v[0] = counted; v[1] = people; v[2] = (int64_t)out->frames_in; v[3] = (int64_t)out->datagrams_out;
    otel_span_as(ot, run_sid, "relay.run", 0, start, now_ns(), 4, k, v);
    otel_close(ot);
  }
  for (int z = 0; z < (people + ZR_SLOTS - 1) / ZR_SLOTS; z++) out->unread += zr_unread(&zones[z]);
  qsort(lat, rounds, sizeof(int64_t), cmp);
  out->p50_ns = lat[rounds / 2]; out->p95_ns = lat[(rounds * 95u) / 100]; out->p99_ns = lat[(rounds * 99u) / 100]; out->max_ns = lat[rounds - 1];
  close(fd[0]); close(fd[1]);
  return 0;
}
