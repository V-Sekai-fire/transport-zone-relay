/* Sends frames as PEOPLE clients would, each on its slot's tick of the six; see docs/zone-net.md. */
#define _POSIX_C_SOURCE 200809L
#include "zone_net.h"
#include <arpa/inet.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>
#define FRAME 1200
static int fd[ZN_MAX_PEOPLE];
static int64_t now_ns(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return (int64_t)t.tv_sec * 1000000000LL + t.tv_nsec; }
int main(int argc, char **argv) {
  static const int phase[4] = {0, 1, 3, 4};
  if (argc != 4) { fprintf(stderr, "usage: zone_load PORT PEOPLE TICKS\n"); return 2; }
  int port = atoi(argv[1]), people = atoi(argv[2]), ticks = atoi(argv[3]), slow = 0, failed = 0;
  if (people <= 0 || people > ZN_MAX_PEOPLE || ticks <= 0) return 2;
  struct rlimit rl;
  if (getrlimit(RLIMIT_NOFILE, &rl) == 0 && rl.rlim_cur < (rlim_t)people + 32) {
    rl.rlim_cur = rl.rlim_max < (rlim_t)people + 32 ? rl.rlim_max : (rlim_t)people + 32;
    setrlimit(RLIMIT_NOFILE, &rl);
  }
  struct sockaddr_in to[2];
  for (int h = 0; h < 2; h++) {
    memset(&to[h], 0, sizeof to[h]); to[h].sin_family = AF_INET; to[h].sin_port = htons((uint16_t)(port + h));
    inet_pton(AF_INET, "127.0.0.1", &to[h].sin_addr);
  }
  for (int k = 0; k < people; k++) {
    int small = 2048;
    fd[k] = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd[k] < 0) { fprintf(stderr, "socket %d of %d failed\n", k, people); return 2; }
    setsockopt(fd[k], SOL_SOCKET, SO_RCVBUF, &small, sizeof small);
  }
  uint8_t f[FRAME];
  memset(f, 0x5a, sizeof f);
  /* One datagram from each client first, in order, so that client k is person k and sits in slot k % 4. */
  for (int k = 0; k < people; k++) { sendto(fd[k], f, sizeof f, 0, (struct sockaddr *)&to[0], sizeof to[0]); if (k % 64 == 63) { struct timespec z = {0, 2000000L}; nanosleep(&z, 0); } }
  int64_t next = now_ns() + 20 * ZN_TICK_NS, max_pass = 0;
  for (int t = 0; t < ticks; t++) {
    int64_t d = next - now_ns();
    if (d > 0) { struct timespec r = {(time_t)(d / 1000000000LL), (long)(d % 1000000000LL)}; nanosleep(&r, 0); }
    int64_t t0 = now_ns();
    for (int k = 0; k < people; k++) {
      if (phase[k % 4] != t % 6) continue;
      for (int h = 0; h < 2; h++)
        if (sendto(fd[k], f, sizeof f, 0, (struct sockaddr *)&to[h], sizeof to[h]) < 0) failed++;
    }
    int64_t t1 = now_ns();
    if (t1 - t0 > max_pass) max_pass = t1 - t0;
    if (t1 - t0 > ZN_TICK_NS || t0 - next > ZN_TICK_NS) slow++;
    next += ZN_TICK_NS;
  }
  printf("load people=%d ticks=%d max_pass_ns=%lld slow_passes=%d sends_failed=%d\n", people, ticks, (long long)max_pass, slow, failed);
  return 0;
}
