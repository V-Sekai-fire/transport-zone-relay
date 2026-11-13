/* Loopback check of the relay on sockets; see docs/zone-net.md. Exit 1 on failure. */
#define _POSIX_C_SOURCE 200809L
#include "zone_net.h"
#include <arpa/inet.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>
#define N 4
#define SENDS 40
#define FRAME 1200
#define PORT 47331
static int got[N], corrupt[N], wrong_half[N], own[N];
static void fill(uint8_t *f, int id, int send, int half) {
  f[0] = (uint8_t)id; f[1] = (uint8_t)send; f[2] = (uint8_t)half;
  for (int j = 3; j < FRAME; j++) f[j] = (uint8_t)(id * 31 + send * 7 + half * 3 + j);
}
static void drain(int fd, int id) {
  uint8_t f[1600], want[FRAME]; struct sockaddr_in from; socklen_t fl;
  for (;;) {
    fl = sizeof from;
    ssize_t n = recvfrom(fd, f, sizeof f, 0, (struct sockaddr *)&from, &fl);
    if (n < 0) return;
    got[id]++;
    if (n != FRAME || f[0] >= N || f[1] >= SENDS || f[2] > 1) { corrupt[id]++; continue; }
    fill(want, f[0], f[1], f[2]);
    if (memcmp(f, want, FRAME) != 0) corrupt[id]++;
    if (f[0] == id) own[id]++;
    if (ntohs(from.sin_port) != PORT + f[2]) wrong_half[id]++;
  }
}
static void *client(void *arg) {
  int id = (int)(intptr_t)arg, fd = socket(AF_INET, SOCK_DGRAM, 0);
  struct sockaddr_in s; uint8_t f[FRAME];
  fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);
  memset(&s, 0, sizeof s); s.sin_family = AF_INET; inet_pton(AF_INET, "127.0.0.1", &s.sin_addr);
  { struct timespec z = {0, 50000000L + id * 15625000L}; nanosleep(&z, 0); }
  for (int i = 0; i < SENDS; i++) {
    for (int half = 0; half < 2; half++) {
      fill(f, id, i, half); s.sin_port = htons((uint16_t)(PORT + half));
      sendto(fd, f, sizeof f, 0, (struct sockaddr *)&s, sizeof s);
    }
    { struct timespec z = {0, 6 * 15625000L + (id * 2 - 3) * 187500L}; nanosleep(&z, 0); }
    drain(fd, id);
  }
  { struct timespec z = {0, 100000000L}; nanosleep(&z, 0); }
  drain(fd, id);
  close(fd);
  return 0;
}
int main(void) {
  const char *sl = getenv("ZONE_SLOW_NS"); uint32_t slow = sl ? (uint32_t)atol(sl) : 0;
  zn_report_t r; pthread_t th[N]; int bad = 0, least = 1 << 30;
  for (int i = 0; i < N; i++) pthread_create(&th[i], 0, client, (void *)(intptr_t)i);
  int rc = zn_run("127.0.0.1", PORT, 320, slow, &r);
  for (int i = 0; i < N; i++) pthread_join(th[i], 0);
  printf("ZONE rc=%d ticks=%u people=%u frames_in=%u datagrams_out=%u refused=%u unread=%llu send_failed=%u overruns=%u p50=%lldns p99=%lldns max=%lldns\n",
         rc, r.ticks, r.people, r.frames_in, r.datagrams_out, r.refused, (unsigned long long)r.unread, r.send_failed, r.overruns,
         (long long)r.p50_ns, (long long)r.p99_ns, (long long)r.max_ns);
  for (int i = 0; i < N; i++) {
    printf("ZONE viewer=%d got=%d corrupt=%d wrong_half=%d own=%d\n", i, got[i], corrupt[i], wrong_half[i], own[i]);
    if (corrupt[i] || own[i]) bad |= 1;
    if (wrong_half[i]) bad |= 2;
    if (got[i] < least) least = got[i];
  }
  if (rc != 0 || r.people != N) { puts("RESULT: FAIL no zone of four"); return 1; }
  if (bad & 1) { puts("RESULT: FAIL a viewer was handed a frame that was not sent to it as it was sent"); return 1; }
  if (bad & 2) { puts("RESULT: FAIL a frame came from the socket of the other half"); return 1; }
  if (least < (N - 1) * SENDS * 2 * 8 / 10) { puts("RESULT: FAIL a viewer got under 80% of the frames"); return 1; }
  printf("LEDGER honest_refused=%u frames_in=%u least_got=%d p50_ns=%lld p99_ns=%lld\n", r.refused, r.frames_in, least, (long long)r.p50_ns, (long long)r.p99_ns);
  puts("RESULT: PASS");
  return 0;
}
