/* The relay as a process, for the sweep; see docs/zone-net.md. */
#define _POSIX_C_SOURCE 200809L
#include "zone_net.h"
#include <stdio.h>
#include <stdlib.h>
int main(int argc, char **argv) {
  if (argc != 4) { fprintf(stderr, "usage: zone_serve PORT TICKS SLOW_NS\n"); return 2; }
  zn_report_t r;
  int rc = zn_run("127.0.0.1", (uint16_t)atoi(argv[1]), (uint32_t)atol(argv[2]), (uint32_t)atol(argv[3]), &r);
  printf("zone rc=%d ticks=%u people=%u frames_in=%u datagrams_out=%u refused=%u unread=%llu strangers=%u send_failed=%u overruns=%u p50=%lldns p95=%lldns p99=%lldns max=%lldns ns_per_datagram_out=%lld\n",
         rc, r.ticks, r.people, r.frames_in, r.datagrams_out, r.refused, (unsigned long long)r.unread, r.strangers, r.send_failed, r.overruns,
         (long long)r.p50_ns, (long long)r.p95_ns, (long long)r.p99_ns, (long long)r.max_ns,
         r.datagrams_out ? (long long)(r.work_ns / r.datagrams_out) : -1LL);
  if (rc != 0 || r.frames_in == 0) { puts("FAIL: no traffic"); return 1; }
  if (r.p99_ns > 4000000LL) { puts("FAIL: p99 over the 4 ms budget"); return 1; }
  puts("PASS");
  return 0;
}
