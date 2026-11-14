/* The zone relay on two UDP sockets and the 64 Hz tick; see docs/zone-net.md. Plain C99, no heap. */
#ifndef ZONE_NET_H
#define ZONE_NET_H
#include <stdint.h>
#define ZN_TICK_NS 15625000LL
#define ZN_MAX_ZONES 1024
#define ZN_MAX_PEOPLE (ZN_MAX_ZONES * 4)
#define ZN_MAX_ALLOW 8192
#define ZN_ALLOW_POLL_TICKS 64
typedef struct {
  uint32_t ticks, overruns, people, frames_in, datagrams_out, refused, strangers, send_failed, unlisted, evicted;
  uint64_t unread;
  int64_t p50_ns, p95_ns, p99_ns, max_ns, work_ns;
} zn_report_t;
/* The allowlist: IPv4 addresses, one a line, in a file that is replaced by rename. A relay bound to a non-loopback
   address refuses to start without ZONE_ALLOW_FILE; an address that is not listed is never seated and gets nothing. */
int zn_allow_load(const char *path);
int zn_allow_has(uint32_t addr_be);
int zn_run(const char *host, uint16_t port, uint32_t ticks, uint32_t slow_ns, zn_report_t *out);
#endif
