#define _POSIX_C_SOURCE 200809L
#ifdef __linux__
#define _GNU_SOURCE 1
#endif
#include "zone_net.h"
#include "zone_relay.h"
#include "otel_span.h"
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/uio.h>
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
#ifdef __linux__
#define ZN_BATCH 32
static uint8_t dgram[ZN_BATCH][ZR_FRAME_MAX + 1];
static struct sockaddr_in froms[ZN_BATCH];
static struct iovec rv[ZN_BATCH];
static struct mmsghdr rm[ZN_BATCH];
#else
static uint8_t dgram[ZR_FRAME_MAX + 1];
#endif
static otel_t ot_store;
static int64_t now_ns(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return (int64_t)t.tv_sec * 1000000000LL + t.tv_nsec; }
static int cmp(const void *x, const void *y) { int64_t a = *(const int64_t *)x, b = *(const int64_t *)y; return (a > b) - (a < b); }
static int same(const struct sockaddr_in *x, const struct sockaddr_in *y) { return x->sin_addr.s_addr == y->sin_addr.s_addr && x->sin_port == y->sin_port; }
static int person_of(const struct sockaddr_in *a) {
  uint32_t h = (a->sin_addr.s_addr * 2654435761u) ^ ((uint32_t)a->sin_port * 40503u);
  for (uint32_t i = 0; i < TABLE; i++) {
    uint32_t at = (h + i) & (TABLE - 1);
    if (table[at] == 0) {
      if (people == ZN_MAX_PEOPLE) { return -1; }
      who[people].a = *a; who[people].slot = -1; table[at] = people + 1;
      return people++;
    }
    if (same(&who[table[at] - 1].a, a)) { return table[at] - 1; }
  }
  return -1;
}
static int bind_udp(const char *host, uint16_t port) {
  int fd = socket(AF_INET, SOCK_DGRAM, 0);
  struct sockaddr_in a; int big = 1 << 22;
  if (fd < 0) { return -1; }
  memset(&a, 0, sizeof a); a.sin_family = AF_INET; a.sin_port = htons(port);
  if (inet_pton(AF_INET, host, &a.sin_addr) != 1 || bind(fd, (struct sockaddr *)&a, sizeof a) < 0) { close(fd); return -1; }
  setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &big, sizeof big);
  setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &big, sizeof big);
  fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);
  return fd;
}
/* One datagram taken: find the person, offer the frame to the state machine, and if it is taken send it on to the other
 * seated members of the zone from the socket of the same half. The parameter keeps the name the source rule
 * (scripts/zone-net-check.sh) looks for, so every use of a frame is seen. On Linux the sends of one frame go in one sendmmsg. */
static void take(zn_report_t *out, const int *fd, int half, const uint8_t *dgram, ssize_t n, const struct sockaddr_in *from) {
  if (n > ZR_FRAME_MAX) { out->refused++; return; }
  int p = person_of(from);
  if (p < 0) { out->strangers++; return; }
  int zi = p / ZR_SLOTS;
  zr_zone_t *z = &zones[zi];
  if (who[p].slot < 0 || zr_person_at(z, who[p].slot) != p) {
    who[p].slot = zr_join(z, p);
    if (who[p].slot < 0) { out->refused++; return; }
    seated[zi][who[p].slot] = p;
  }
  int slot = who[p].slot;
  if (!zr_put(z, slot, half, dgram, (size_t)n)) { out->refused++; return; }
  out->frames_in++;
#ifdef ZN_PLANT_HALF
  const int out_fd = fd[1 - half];
#else
  const int out_fd = fd[half];
#endif
#ifdef __linux__
  struct iovec sv[ZR_SLOTS]; struct mmsghdr sm[ZR_SLOTS]; int ns = 0;
  for (int v = 0; v < ZR_SLOTS; v++) {
    size_t len;
    if (v == slot || zr_person_at(z, v) < 0) { continue; }
    const uint8_t *held = zr_frame(z, v, (slot > v ? slot - 1 : slot) * 2 + half, &len);
    sv[ns].iov_base = (void *)held; sv[ns].iov_len = len;
    memset(&sm[ns], 0, sizeof sm[ns]);
    sm[ns].msg_hdr.msg_name = &who[seated[zi][v]].a; sm[ns].msg_hdr.msg_namelen = sizeof who[0].a;
    sm[ns].msg_hdr.msg_iov = &sv[ns]; sm[ns].msg_hdr.msg_iovlen = 1;
    ns++;
  }
  for (int off = 0; off < ns;) {
    int r = sendmmsg(out_fd, sm + off, (unsigned)(ns - off), 0);
    if (r > 0) { out->datagrams_out += (uint32_t)r; off += r; } else { out->send_failed++; off++; }
  }
#else
  for (int v = 0; v < ZR_SLOTS; v++) {
    size_t len;
    if (v == slot || zr_person_at(z, v) < 0) { continue; }
    const uint8_t *held = zr_frame(z, v, (slot > v ? slot - 1 : slot) * 2 + half, &len);
    if (sendto(out_fd, held, len, 0, (const struct sockaddr *)&who[seated[zi][v]].a, sizeof who[0].a) >= 0) { out->datagrams_out++; }
    else { out->send_failed++; }
  }
#endif
}
int zn_run(const char *host, uint16_t port, uint32_t ticks, uint32_t slow_ns, zn_report_t *out) {
  int fd[2];
  if (ticks == 0 || ticks > (1u << 16) || port == 0 || port == 65535) { return -EINVAL; }
  memset(out, 0, sizeof *out); memset(table, 0, sizeof table); people = 0;
#ifdef __linux__
  for (int i = 0; i < ZN_BATCH; i++) {
    rv[i].iov_base = dgram[i]; rv[i].iov_len = sizeof dgram[i];
    memset(&rm[i], 0, sizeof rm[i]);
    rm[i].msg_hdr.msg_name = &froms[i]; rm[i].msg_hdr.msg_iov = &rv[i]; rm[i].msg_hdr.msg_iovlen = 1;
  }
#endif
  for (int z = 0; z < ZN_MAX_ZONES; z++) { zr_reset(&zones[z]); for (int s = 0; s < ZR_SLOTS; s++) { seated[z][s] = -1; } }
  fd[0] = bind_udp(host, port);
  fd[1] = bind_udp(host, (uint16_t)(port + 1));
  if (fd[0] < 0 || fd[1] < 0) { if (fd[0] >= 0) { close(fd[0]); } if (fd[1] >= 0) { close(fd[1]); } return -EADDRINUSE; }
  int64_t start = now_ns(), next = start + ZN_TICK_NS;
  /* Spans are recorded and flushed every run; the environment only says where they go, and /dev/null is a place. */
  otel_t *ot = &ot_store;
  { const char *op = getenv("ZONE_OTEL"); if (otel_open(ot, op && *op ? op : "/dev/null", 0) < 0) { int e = errno; close(fd[0]); close(fd[1]); return -e; } }
  uint64_t run_sid = otel_id(ot);
  uint32_t counted = 0, rounds = 0;
  for (uint32_t t = 0; counted < ticks; t++, rounds++) {
    int64_t d = next - now_ns();
    if (d > 0) { struct timespec r; r.tv_sec = (time_t)(d / 1000000000LL); r.tv_nsec = (long)(d % 1000000000LL); nanosleep(&r, 0); }
    int64_t t0 = now_ns(), first = -1;
    uint32_t fi0 = out->frames_in, do0 = out->datagrams_out, re0 = out->refused;
    uint64_t tick_sid = otel_id(ot);
    otel_trace(ot);
    for (int half = 0; half < 2; half++) {
#ifdef __linux__
      for (;;) {
        for (int i = 0; i < ZN_BATCH; i++) { rm[i].msg_hdr.msg_namelen = sizeof froms[0]; }
        int got = recvmmsg(fd[half], rm, ZN_BATCH, MSG_DONTWAIT, 0);
        if (got <= 0) { break; }
        if (first < 0) { first = now_ns(); }
        for (int i = 0; i < got; i++) { take(out, fd, half, dgram[i], (ssize_t)rm[i].msg_len, &froms[i]); }
      }
#else
      for (;;) {
        struct sockaddr_in from; socklen_t fl = sizeof from;
        ssize_t n = recvfrom(fd[half], dgram, sizeof dgram, 0, (struct sockaddr *)&from, &fl);
        if (n < 0) { break; }
        if (first < 0) { first = now_ns(); }
        take(out, fd, half, dgram, n, &from);
      }
#endif
    }
    if (slow_ns) { int64_t end = now_ns() + slow_ns; while (now_ns() < end) { } }
    int64_t t1 = now_ns();
    {
      otel_rec_t *r = otel_begin(ot, tick_sid, "relay.tick", 0, t0, t1); otel_kind(r, 2);
      otel_num(r, "people", people); otel_num(r, "frames_in", (double)(out->frames_in - fi0));
      otel_num(r, "datagrams_out", (double)(out->datagrams_out - do0)); otel_num(r, "refused", (double)(out->refused - re0));
      otel_num(r, "round_us", (double)(t1 - t0) / 1000.0); otel_num(r, "late_us", (double)(t0 - next) / 1000.0);
      if ((uint32_t)((t1 - start) / ZN_TICK_NS) > counted + 1) { otel_error(r, "RoundOverrun", "the round ran past its slot"); }
      if (ot->n >= OTEL_FLUSH_AT && next - t1 > 3000000) { otel_flush(ot); }
    }
    uint32_t wall = (uint32_t)((t1 - start) / ZN_TICK_NS);
    if (wall <= counted) { wall = counted + 1; }
    if (wall > counted + 1) { out->overruns++; }
#ifdef ZN_PLANT_NO_CATCH_UP
    wall = counted + 1;
#endif
    for (; counted < wall; counted++) {
      for (int z = 0; z < (people + ZR_SLOTS - 1) / ZR_SLOTS; z++) { zr_tick(&zones[z]); }
    }
    lat[t] = t1 - (first >= 0 ? first : t0);
    if (first >= 0) { out->work_ns += t1 - first; }
    next = start + (int64_t)(counted + 1) * ZN_TICK_NS;
#ifdef ZN_PLANT_NO_CATCH_UP
    next = t1 + ZN_TICK_NS;
#endif
  }
  out->ticks = counted; out->people = (uint32_t)people;
  for (int z = 0; z < (people + ZR_SLOTS - 1) / ZR_SLOTS; z++) { out->unread += zr_unread(&zones[z]); }
  qsort(lat, rounds, sizeof(int64_t), cmp);
  out->p50_ns = lat[rounds / 2]; out->p95_ns = lat[(rounds * 95u) / 100]; out->p99_ns = lat[(rounds * 99u) / 100]; out->max_ns = lat[rounds - 1];
  {
    otel_rec_t *r; otel_trace(ot);
    r = otel_begin(ot, run_sid, "relay.run", 0, start, now_ns()); otel_kind(r, 2);
    otel_num(r, "ticks", counted); otel_num(r, "people", people); otel_num(r, "frames_in", out->frames_in); otel_num(r, "datagrams_out", out->datagrams_out);
    otel_num(r, "refused", out->refused); otel_num(r, "overruns", out->overruns); otel_num(r, "p50_us", (double)out->p50_ns / 1000.0);
    otel_num(r, "p95_us", (double)out->p95_ns / 1000.0); otel_num(r, "p99_us", (double)out->p99_ns / 1000.0); otel_num(r, "max_us", (double)out->max_ns / 1000.0);
    if (out->overruns) { otel_error(r, "RoundOverrun", "rounds ran past their slot during the run"); }
    otel_close(ot);
  }
  close(fd[0]); close(fd[1]);
  return 0;
}
