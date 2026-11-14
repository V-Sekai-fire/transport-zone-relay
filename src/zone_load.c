/* Sends frames as PEOPLE clients would and reads every reply; see docs/fly.md.
 * Each frame carries its send time, so a client that receives another's frame measures the round
 * trip through the relay on one clock. Delivery is counted at the receivers, not at sendto. */
#define _POSIX_C_SOURCE 200809L
#include "zone_net.h"
#include <arpa/inet.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>
#define FRAME 1200
#define MAX_SAMPLES (1 << 22)
static int fd[ZN_MAX_PEOPLE];
static uint32_t rtt[MAX_SAMPLES];
static int64_t now_ns(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return (int64_t)t.tv_sec * 1000000000LL + t.tv_nsec; }
static int cmp(const void *x, const void *y) { uint32_t a = *(const uint32_t *)x, b = *(const uint32_t *)y; return (a > b) - (a < b); }
static long received, samples;
static void drain(int people) {
  static uint8_t buf[FRAME + 64];
  for (int k = 0; k < people; k++)
    for (;;) {
      ssize_t n = recvfrom(fd[k], buf, sizeof buf, 0, 0, 0);
      if (n < 0) break;
      received++;
      if (n == FRAME && samples < MAX_SAMPLES) {
        int64_t sent; memcpy(&sent, buf, sizeof sent);
        int64_t d = (now_ns() - sent) / 1000;
        rtt[samples++] = d < 0 ? 0 : (uint32_t)d;
      }
    }
}
int main(int argc, char **argv) {
  static const int phase[4] = {0, 1, 3, 4};
  if (argc != 4 && argc != 5) { fprintf(stderr, "usage: zone_load PORT PEOPLE TICKS [HOST]\n"); return 2; }
  int port = atoi(argv[1]), people = atoi(argv[2]), ticks = atoi(argv[3]), slow = 0, failed = 0;
  const char *host = argc == 5 ? argv[4] : "127.0.0.1";
  if (people <= 0 || people > ZN_MAX_PEOPLE || ticks <= 0) return 2;
  struct rlimit rl;
  if (getrlimit(RLIMIT_NOFILE, &rl) == 0 && rl.rlim_cur < (rlim_t)people + 32) {
    rl.rlim_cur = rl.rlim_max < (rlim_t)people + 32 ? rl.rlim_max : (rlim_t)people + 32;
    setrlimit(RLIMIT_NOFILE, &rl);
  }
  struct sockaddr_in to[2];
  for (int h = 0; h < 2; h++) {
    memset(&to[h], 0, sizeof to[h]); to[h].sin_family = AF_INET; to[h].sin_port = htons((uint16_t)(port + h));
    if (inet_pton(AF_INET, host, &to[h].sin_addr) != 1) { fprintf(stderr, "bad host %s\n", host); return 2; }
  }
  int big = 1 << 18;
  for (int k = 0; k < people; k++) {
    fd[k] = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd[k] < 0) { fprintf(stderr, "socket %d of %d failed\n", k, people); return 2; }
    setsockopt(fd[k], SOL_SOCKET, SO_RCVBUF, &big, sizeof big);
    fcntl(fd[k], F_SETFL, fcntl(fd[k], F_GETFL, 0) | O_NONBLOCK);
  }
  uint8_t f[FRAME];
  memset(f, 0x5a, sizeof f);
  long sent = 0;
  for (int k = 0; k < people; k++) {
    int64_t t = now_ns(); memcpy(f, &t, sizeof t);
    if (sendto(fd[k], f, sizeof f, 0, (struct sockaddr *)&to[0], sizeof to[0]) >= 0) sent++; else failed++;
    if (k % 64 == 63) { struct timespec z = {0, 5000000L}; nanosleep(&z, 0); }
  }
  { struct timespec z = {1, 0}; nanosleep(&z, 0); }
  drain(people);
  received = 0; samples = 0; sent = 0;
  int64_t next = now_ns() + 20 * ZN_TICK_NS, max_pass = 0;
  for (int t = 0; t < ticks; t++) {
    int64_t d = next - now_ns();
    if (d > 0) { struct timespec r = {(time_t)(d / 1000000000LL), (long)(d % 1000000000LL)}; nanosleep(&r, 0); }
    int64_t t0 = now_ns();
    for (int k = 0; k < people; k++) {
      if (phase[k % 4] != t % 6) continue;
      for (int h = 0; h < 2; h++) {
        int64_t s = now_ns(); memcpy(f, &s, sizeof s);
        if (sendto(fd[k], f, sizeof f, 0, (struct sockaddr *)&to[h], sizeof to[h]) >= 0) sent++; else failed++;
      }
    }
    drain(people);
    int64_t t1 = now_ns();
    if (t1 - t0 > max_pass) max_pass = t1 - t0;
    if (t1 - t0 > ZN_TICK_NS || t0 - next > ZN_TICK_NS) slow++;
    next += ZN_TICK_NS;
  }
  for (int i = 0; i < 40; i++) { struct timespec z = {0, 25000000L}; nanosleep(&z, 0); drain(people); }
  long expected = 3 * sent;
  qsort(rtt, (size_t)samples, sizeof rtt[0], cmp);
  printf("load people=%d ticks=%d sent=%ld expected=%ld received=%ld delivered_pct=%.2f rtt_p50_us=%u rtt_p99_us=%u rtt_max_us=%u max_pass_ns=%lld slow_passes=%d sends_failed=%d\n",
         people, ticks, sent, expected, received, expected ? 100.0 * (double)received / (double)expected : 0.0,
         samples ? rtt[samples / 2] : 0, samples ? rtt[(samples * 99) / 100] : 0, samples ? rtt[samples - 1] : 0,
         (long long)max_pass, slow, failed);
  return 0;
}
