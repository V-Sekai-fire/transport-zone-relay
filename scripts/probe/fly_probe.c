/* What this Linux host lets the relay use: sendmmsg, UDP GSO, io_uring, AF_XDP, XDP. Prints one line per try. */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <linux/bpf.h>
#include <linux/if_xdp.h>
#include <net/if.h>
#include <netinet/in.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <sys/utsname.h>
#include <unistd.h>

#ifndef AF_XDP
#define AF_XDP 44
#endif
#ifndef SOL_XDP
#define SOL_XDP 283
#endif
#ifndef SOL_UDP
#define SOL_UDP 17
#endif
#ifndef UDP_SEGMENT
#define UDP_SEGMENT 103
#endif

static int bad_controls;

static void say(const char *name, int e) {
  if (e == 0) printf("probe   %-34s PASS\n", name);
  else printf("probe   %-34s FAIL errno=%d (%s)\n", name, e, strerror(e));
}
/* A control is a call that must fail with one named errno. A different errno means the call was refused
   earlier (seccomp, capability), so the control says nothing and the probe is untrusted for that section. */
static void control(const char *name, int e, int want) {
  if (e == want) printf("control %-34s FIRED errno=%d (%s)\n", name, e, strerror(e));
  else {
    printf("control %-34s WRONG-REASON got=%d (%s) wanted=%d (%s)\n", name, e, strerror(e), want, strerror(want));
    bad_controls++;
  }
}
static void grep_status(const char *key) {
  char line[256]; FILE *f = fopen("/proc/self/status", "r");
  if (!f) return;
  while (fgets(line, sizeof line, f)) if (!strncmp(line, key, strlen(key))) { printf("info    %s", line); break; }
  fclose(f);
}
static void file_line(const char *label, const char *path) {
  char line[256]; FILE *f = fopen(path, "r");
  if (!f) { printf("info    %s: unreadable (%s)\n", label, strerror(errno)); return; }
  if (fgets(line, sizeof line, f)) { line[strcspn(line, "\n")] = 0; printf("info    %s: %s\n", label, line); }
  fclose(f);
}

static int t_sendmmsg(void) {
  int a = socket(AF_INET, SOCK_DGRAM, 0), b = socket(AF_INET, SOCK_DGRAM, 0), e = 0;
  struct sockaddr_in ad; socklen_t l = sizeof ad;
  char out[4][100], in[4][100]; struct iovec io[4], ii[4]; struct mmsghdr m[4], r[4];
  if (a < 0 || b < 0) return errno;
  memset(&ad, 0, sizeof ad); ad.sin_family = AF_INET; ad.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  if (bind(b, (struct sockaddr *)&ad, sizeof ad) < 0 || getsockname(b, (struct sockaddr *)&ad, &l) < 0) e = errno;
  memset(m, 0, sizeof m); memset(r, 0, sizeof r);
  for (int i = 0; !e && i < 4; i++) {
    memset(out[i], i, sizeof out[i]);
    io[i].iov_base = out[i]; io[i].iov_len = sizeof out[i];
    m[i].msg_hdr.msg_name = &ad; m[i].msg_hdr.msg_namelen = sizeof ad; m[i].msg_hdr.msg_iov = &io[i]; m[i].msg_hdr.msg_iovlen = 1;
    ii[i].iov_base = in[i]; ii[i].iov_len = sizeof in[i]; r[i].msg_hdr.msg_iov = &ii[i]; r[i].msg_hdr.msg_iovlen = 1;
  }
  if (!e) { int n = sendmmsg(a, m, 4, 0); if (n != 4) e = n < 0 ? errno : EIO; }
  if (!e) { int n = recvmmsg(b, r, 4, MSG_DONTWAIT, 0); if (n != 4) e = n < 0 ? errno : EIO; }
  close(a); close(b);
  return e;
}

static int t_gso(void) {
  int a = socket(AF_INET, SOCK_DGRAM, 0), b = socket(AF_INET, SOCK_DGRAM, 0), e = 0, seg = 1200;
  struct sockaddr_in ad; socklen_t l = sizeof ad; static char big[2400], in[2][1200]; struct iovec ii[2]; struct mmsghdr r[2];
  if (a < 0 || b < 0) return errno;
  memset(&ad, 0, sizeof ad); ad.sin_family = AF_INET; ad.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  if (bind(b, (struct sockaddr *)&ad, sizeof ad) < 0 || getsockname(b, (struct sockaddr *)&ad, &l) < 0) e = errno;
  if (!e && setsockopt(a, SOL_UDP, UDP_SEGMENT, &seg, sizeof seg) < 0) e = errno;
  if (!e && sendto(a, big, sizeof big, 0, (struct sockaddr *)&ad, sizeof ad) != (ssize_t)sizeof big) e = errno ? errno : EIO;
  memset(r, 0, sizeof r);
  for (int i = 0; i < 2; i++) { ii[i].iov_base = in[i]; ii[i].iov_len = sizeof in[i]; r[i].msg_hdr.msg_iov = &ii[i]; r[i].msg_hdr.msg_iovlen = 1; }
  if (!e) { int n = recvmmsg(b, r, 2, MSG_DONTWAIT, 0); if (n != 2) e = n < 0 ? errno : EIO; }
  close(a); close(b);
  return e;
}

/* Local copies, so an old libc-dev header does not decide what the probe can ask. */
struct my_uring_params { uint32_t sq_entries, cq_entries, flags, sq_thread_cpu, sq_thread_idle, features, wq_fd, resv[3]; uint64_t sq_off[5], cq_off[5]; };
struct my_buf_reg { uint64_t ring_addr; uint32_t ring_entries; uint16_t bgid, flags; uint64_t resv[3]; };
#define MY_SINGLE_ISSUER (1U << 12)
#define MY_DEFER_TASKRUN (1U << 13)
#define MY_REGISTER_PBUF_RING 22

static int uring_setup(uint32_t flags, int *fd) {
  struct my_uring_params p; memset(&p, 0, sizeof p); p.flags = flags;
  *fd = (int)syscall(__NR_io_uring_setup, 8, &p);
  return *fd < 0 ? errno : 0;
}
static int t_uring_plain(void) { int fd, e = uring_setup(0, &fd); if (!e) close(fd); return e; }
static int t_uring_defer(void) { int fd, e = uring_setup(MY_SINGLE_ISSUER | MY_DEFER_TASKRUN, &fd); if (!e) close(fd); return e; }
static int t_uring_pbuf(void) {
  int fd, e = uring_setup(MY_SINGLE_ISSUER | MY_DEFER_TASKRUN, &fd);
  if (e) return e;
  void *ring = mmap(0, 4096, PROT_READ | PROT_WRITE, MAP_ANONYMOUS | MAP_PRIVATE, -1, 0);
  struct my_buf_reg reg; memset(&reg, 0, sizeof reg);
  reg.ring_addr = (uint64_t)(uintptr_t)ring; reg.ring_entries = 64; reg.bgid = 1;
  if (ring == MAP_FAILED) e = errno;
  else if (syscall(__NR_io_uring_register, fd, MY_REGISTER_PBUF_RING, &reg, 1) < 0) e = errno;
  close(fd);
  return e;
}
static int c_uring_flags(void) { int fd, e = uring_setup(0xFFFFFFFFu, &fd); if (!e) close(fd); return e; }

static int bpf_call(int cmd, union bpf_attr *a) { return (int)syscall(__NR_bpf, cmd, a, sizeof *a); }
static int load_xdp(const struct bpf_insn *ins, int n, int *fd) {
  union bpf_attr a; memset(&a, 0, sizeof a);
  a.prog_type = BPF_PROG_TYPE_XDP; a.insn_cnt = (uint32_t)n; a.insns = (uint64_t)(uintptr_t)ins; a.license = (uint64_t)(uintptr_t)"GPL";
  *fd = bpf_call(BPF_PROG_LOAD, &a);
  return *fd < 0 ? errno : 0;
}
static const struct bpf_insn pass_prog[2] = { { .code = 0xb7, .dst_reg = 0, .src_reg = 0, .off = 0, .imm = 2 }, { .code = 0x95 } };
static int t_bpf_load(void) { int fd, e = load_xdp(pass_prog, 2, &fd); if (!e) close(fd); return e; }
static int c_bpf_load(void) { int fd, e = load_xdp(pass_prog, 0, &fd); if (!e) close(fd); return e; }
static int t_xdp_attach(unsigned ifindex, uint32_t flags) {
  int pfd, lfd, e = load_xdp(pass_prog, 2, &pfd);
  if (e) return e;
  union bpf_attr a; memset(&a, 0, sizeof a);
  a.link_create.prog_fd = (uint32_t)pfd; a.link_create.target_ifindex = ifindex; a.link_create.attach_type = 37 /* BPF_XDP */; a.link_create.flags = flags;
  lfd = bpf_call(BPF_LINK_CREATE, &a);
  e = lfd < 0 ? errno : 0;
  if (lfd >= 0) close(lfd);
  close(pfd);
  return e;
}

static int xsk_try(unsigned ifindex, int step, const char *name) {
  int s = socket(AF_XDP, SOCK_RAW, 0), e = 0, n = 64;
  if (s < 0) return errno;
  if (step == 0) { close(s); return 0; }
  void *um = 0;
  if (posix_memalign(&um, 4096, 4096 * 64)) { close(s); return ENOMEM; }
  struct xdp_umem_reg r; memset(&r, 0, sizeof r); r.addr = (uint64_t)(uintptr_t)um; r.len = 4096 * 64; r.chunk_size = 4096;
  if (setsockopt(s, SOL_XDP, XDP_UMEM_REG, &r, sizeof r) < 0) e = errno;
  if (!e && step >= 2) {
    if (setsockopt(s, SOL_XDP, XDP_UMEM_FILL_RING, &n, sizeof n) < 0 || setsockopt(s, SOL_XDP, XDP_UMEM_COMPLETION_RING, &n, sizeof n) < 0 ||
        setsockopt(s, SOL_XDP, XDP_RX_RING, &n, sizeof n) < 0 || setsockopt(s, SOL_XDP, XDP_TX_RING, &n, sizeof n) < 0) e = errno;
  }
  if (!e && step >= 3) {
    struct sockaddr_xdp sx; memset(&sx, 0, sizeof sx); sx.sxdp_family = AF_XDP; sx.sxdp_ifindex = ifindex; sx.sxdp_queue_id = 0; sx.sxdp_flags = XDP_COPY;
    if (bind(s, (struct sockaddr *)&sx, sizeof sx) < 0) e = errno;
  }
  (void)name; close(s); free(um);
  return e;
}

static void driver_of(const char *ifn, char *out, size_t cap) {
  char p[256], t[256]; snprintf(p, sizeof p, "/sys/class/net/%s/device/driver", ifn);
  ssize_t n = readlink(p, t, sizeof t - 1);
  if (n < 0) { snprintf(out, cap, "none"); return; }
  t[n] = 0; const char *b = strrchr(t, '/'); snprintf(out, cap, "%.60s", b ? b + 1 : t);
}
static int queues_of(const char *ifn) {
  char p[256]; int n = 0;
  for (int i = 0; i < 64; i++) { snprintf(p, sizeof p, "/sys/class/net/%s/queues/rx-%d", ifn, i); if (access(p, F_OK) == 0) n++; else break; }
  return n;
}

int main(void) {
  struct utsname u; struct rlimit rl; char drv[64];
  uname(&u); printf("info    kernel %s %s %s\n", u.sysname, u.release, u.machine);
  grep_status("Seccomp:"); grep_status("CapEff:"); grep_status("CapBnd:");
  if (getrlimit(RLIMIT_MEMLOCK, &rl) == 0) printf("info    RLIMIT_MEMLOCK cur=%llu max=%llu\n", (unsigned long long)rl.rlim_cur, (unsigned long long)rl.rlim_max);
  file_line("io_uring_disabled", "/proc/sys/kernel/io_uring_disabled");
  file_line("unprivileged_bpf_disabled", "/proc/sys/kernel/unprivileged_bpf_disabled");
  printf("info    uid=%d\n", (int)getuid());

  say("sendmmsg_recvmmsg", t_sendmmsg());
  say("udp_gso_segment", t_gso());
  say("io_uring_setup_plain", t_uring_plain());
  say("io_uring_single_issuer_defer", t_uring_defer());
  say("io_uring_pbuf_ring", t_uring_pbuf());
  control("io_uring_setup_bad_flags", c_uring_flags(), EINVAL);
  say("bpf_prog_load_xdp", t_bpf_load());
  control("bpf_prog_load_zero_insns", c_bpf_load(), EINVAL);

  struct if_nameindex *ni = if_nameindex();
  for (struct if_nameindex *i = ni; i && i->if_index; i++) {
    char nm[96];
    driver_of(i->if_name, drv, sizeof drv);
    printf("info    iface %s index=%u driver=%s rx_queues=%d\n", i->if_name, i->if_index, drv, queues_of(i->if_name));
    snprintf(nm, sizeof nm, "xdp_attach_skb_%s", i->if_name); say(nm, t_xdp_attach(i->if_index, 1u << 1));
    snprintf(nm, sizeof nm, "xdp_attach_drv_%s", i->if_name); say(nm, t_xdp_attach(i->if_index, 1u << 2));
    snprintf(nm, sizeof nm, "afxdp_socket_%s", i->if_name); say(nm, xsk_try(i->if_index, 0, nm));
    snprintf(nm, sizeof nm, "afxdp_umem_reg_%s", i->if_name); say(nm, xsk_try(i->if_index, 1, nm));
    snprintf(nm, sizeof nm, "afxdp_rings_%s", i->if_name); say(nm, xsk_try(i->if_index, 2, nm));
    snprintf(nm, sizeof nm, "afxdp_bind_copy_q0_%s", i->if_name); say(nm, xsk_try(i->if_index, 3, nm));
  }
  if (ni) if_freenameindex(ni);
  control("afxdp_bind_bad_ifindex", xsk_try(999999u, 3, "bad"), ENODEV);

  printf("%s controls_not_fired=%d\n", bad_controls ? "PROBE-UNTRUSTED" : "PROBE-DONE", bad_controls);
  return bad_controls ? 1 : 0;
}
