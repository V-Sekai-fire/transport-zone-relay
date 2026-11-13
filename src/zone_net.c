#define _POSIX_C_SOURCE 200809L
#include "zone_net.h"
#include "zone_relay.h"
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
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
  memset(out, 0, sizeof *out); memset(table, 0, sizeof table); people = 0;
  for (int z = 0; z < ZN_MAX_ZONES; z++) { zr_reset(&zones[z]); for (int s = 0; s < ZR_SLOTS; s++) seated[z][s] = -1; }
  fd[0] = bind_udp(host, port);
  fd[1] = bind_udp(host, (uint16_t)(port + 1));
  if (fd[0] < 0 || fd[1] < 0) { if (fd[0] >= 0) close(fd[0]); if (fd[1] >= 0) close(fd[1]); return -EADDRINUSE; }
  int64_t next = now_ns() + ZN_TICK_NS;
  for (uint32_t t = 0; t < ticks; t++) {
    int64_t d = next - now_ns();
    if (d > 0) { struct timespec r; r.tv_sec = (time_t)(d / 1000000000LL); r.tv_nsec = (long)(d % 1000000000LL); nanosleep(&r, 0); }
    int64_t t0 = now_ns(), first = -1;
    for (int half = 0; half < 2; half++) {
      for (;;) {
        struct sockaddr_in from; socklen_t fl = sizeof from;
        ssize_t n = recvfrom(fd[half], dgram, sizeof dgram, 0, (struct sockaddr *)&from, &fl);
        if (n < 0) break;
        if (first < 0) first = now_ns();
        if (n > ZR_FRAME_MAX) { out->refused++; continue; }
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
      }
    }
    if (slow_ns) { int64_t end = now_ns() + slow_ns; while (now_ns() < end) { } }
    for (int z = 0; z < (people + ZR_SLOTS - 1) / ZR_SLOTS; z++) zr_tick(&zones[z]);
    int64_t t1 = now_ns();
    lat[t] = t1 - (first >= 0 ? first : t0);
    if (first >= 0) out->work_ns += t1 - first;
    if (t1 > next + ZN_TICK_NS) { out->overruns++; next = t1 + ZN_TICK_NS; } else next += ZN_TICK_NS;
  }
  out->ticks = ticks; out->people = (uint32_t)people;
  for (int z = 0; z < (people + ZR_SLOTS - 1) / ZR_SLOTS; z++) out->unread += zr_unread(&zones[z]);
  qsort(lat, ticks, sizeof(int64_t), cmp);
  out->p50_ns = lat[ticks / 2]; out->p95_ns = lat[(ticks * 95u) / 100]; out->p99_ns = lat[(ticks * 99u) / 100]; out->max_ns = lat[ticks - 1];
  close(fd[0]); close(fd[1]);
  return 0;
}
