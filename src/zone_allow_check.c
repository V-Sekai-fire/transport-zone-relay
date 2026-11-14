/* The allowlist of the relay on sockets (Linux: sources 127.0.0.2-4); see docs/zone-net.md. Exit 1 on failure.
 * A and B are listed, X is not. X must get nothing and be seated nowhere; A and B must hear each other.
 * Half way through, B is taken off the list by a rename; within the poll interval B must be unseated and silent. */
#define _POSIX_C_SOURCE 200809L
#include "zone_net.h"
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>
#define PORT 47341
#define FRAME 1200
#define SENDS 36
#define REMOVE_AT_NS 1500000000LL
static const char *const ADDR[3] = { "127.0.0.2", "127.0.0.3", "127.0.0.4" };
static int heard_from[3][3];
static int64_t last_from[3][3];
static int64_t t_start;
static char listpath[64], listtmp[80];
static int64_t now_ns(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return (int64_t)t.tv_sec * 1000000000LL + t.tv_nsec; }
static void drain(int fd, int me) {
  uint8_t f[1600];
  for (;;) {
    ssize_t n = recvfrom(fd, f, sizeof f, 0, 0, 0);
    if (n < 0) return;
    if (n == FRAME && f[0] < 3) { heard_from[me][f[0]]++; last_from[me][f[0]] = now_ns() - t_start; }
  }
}
static void *client(void *arg) {
  int id = (int)(intptr_t)arg, fd = socket(AF_INET, SOCK_DGRAM, 0);
  struct sockaddr_in me, s; uint8_t f[FRAME];
  memset(&me, 0, sizeof me); me.sin_family = AF_INET; inet_pton(AF_INET, ADDR[id], &me.sin_addr);
  if (fd < 0 || bind(fd, (struct sockaddr *)&me, sizeof me) < 0) { fprintf(stderr, "bind %s: %s\n", ADDR[id], strerror(errno)); exit(2); }
  fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);
  memset(&s, 0, sizeof s); s.sin_family = AF_INET; inet_pton(AF_INET, "127.0.0.1", &s.sin_addr);
  { struct timespec z = {0, 50000000L + id * 15625000L}; nanosleep(&z, 0); }
  for (int i = 0; i < SENDS; i++) {
    for (int half = 0; half < 2; half++) {
      memset(f, id * 31 + half, sizeof f); f[0] = (uint8_t)id; f[1] = (uint8_t)i; f[2] = (uint8_t)half;
      s.sin_port = htons((uint16_t)(PORT + half));
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
static void write_list(const char *body) {
  FILE *f = fopen(listtmp, "w");
  if (!f) { perror("list"); exit(2); }
  fputs(body, f); fclose(f);
  if (rename(listtmp, listpath) < 0) { perror("rename"); exit(2); }
}
static void *editor(void *arg) {
  (void)arg;
  for (;;) { if (now_ns() - t_start >= REMOVE_AT_NS) break; { struct timespec z = {0, 10000000L}; nanosleep(&z, 0); } }
  write_list("127.0.0.2\n");
  return 0;
}
int main(void) {
  zn_report_t r; pthread_t th[3], ed; int rc;
  snprintf(listpath, sizeof listpath, "/tmp/zone_allow_%d.list", (int)getpid()); snprintf(listtmp, sizeof listtmp, "%s.tmp", listpath);
  /* closed by default: a non-loopback bind with no list must refuse to start */
  unsetenv("ZONE_ALLOW_FILE");
  rc = zn_run("0.0.0.0", PORT + 10, 8, 0, &r);
  if (rc != -EPERM) { printf("RESULT: FAIL a relay bound off loopback started without an allowlist (rc=%d)\n", rc); return 1; }
  puts("closed by default: a non-loopback bind without ZONE_ALLOW_FILE refused (EPERM)");
  write_list("127.0.0.2\n127.0.0.3\n");
  setenv("ZONE_ALLOW_FILE", listpath, 1);
  t_start = now_ns();
  for (int i = 0; i < 3; i++) pthread_create(&th[i], 0, client, (void *)(intptr_t)i);
  pthread_create(&ed, 0, editor, 0);
  rc = zn_run("127.0.0.1", PORT, 320, 0, &r);
  for (int i = 0; i < 3; i++) pthread_join(th[i], 0);
  pthread_join(ed, 0);
  unlink(listpath);
  printf("ALLOW rc=%d people=%u frames_in=%u datagrams_out=%u unlisted=%u evicted=%u refused=%u\n", rc, r.people, r.frames_in, r.datagrams_out, r.unlisted, r.evicted, r.refused);
  printf("ALLOW A heard B=%d (last %lld ms), B heard A=%d (last %lld ms), X heard A=%d B=%d, A heard X=%d, B heard X=%d\n",
         heard_from[0][1], (long long)(last_from[0][1] / 1000000), heard_from[1][0], (long long)(last_from[1][0] / 1000000),
         heard_from[2][0], heard_from[2][1], heard_from[0][2], heard_from[1][2]);
  if (rc != 0) { puts("RESULT: FAIL the relay did not run"); return 1; }
  if (heard_from[2][0] || heard_from[2][1] || heard_from[0][2] || heard_from[1][2]) { puts("RESULT: FAIL an address that is not listed was given a frame or its frame was relayed"); return 1; }
  if (r.unlisted == 0) { puts("RESULT: FAIL nothing was counted as unlisted"); return 1; }
  if (heard_from[0][1] < 5 || heard_from[1][0] < 5) { puts("RESULT: FAIL listed addresses did not hear each other"); return 1; }
  if (r.evicted != 1) { puts("RESULT: FAIL taking B off the list did not unseat exactly one person"); return 1; }
  /* B left the list at 1.5 s; the relay polls every 64 ticks (1.0 s) and a client drains once a round (about 0.1 s). B sends until
     about 3.4 s, so a relay that keeps B seated is heard from past 3.0 s. */
  if (last_from[0][1] > REMOVE_AT_NS + 1550000000LL || last_from[1][0] > REMOVE_AT_NS + 1550000000LL) { puts("RESULT: FAIL a removed member was still relayed after the poll interval"); return 1; }
  printf("LEDGER unlisted=%u evicted=%u a_hears_b=%d b_hears_a=%d\n", r.unlisted, r.evicted, heard_from[0][1], heard_from[1][0]);
  puts("RESULT: PASS");
  return 0;
}
