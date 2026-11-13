/* Clients whose clocks are not the relay's: offset, skewed and jittered. See docs/zone-net.md. */
#include "zone_relay.h"
#include <stdio.h>
#include <string.h>
#define TICKS 19200
#define MILLI 1000
int main(void) {
  static zr_zone_t z;
  static const long skew_ppm[ZR_SLOTS] = {-1000, -100, 100, 1000};
  static const long offset_milli[ZR_SLOTS] = {130, 1480, 2990, 4610};
  static uint8_t frame[ZR_FRAME_BYTES];
  unsigned long lcg = 20261113UL;
  long next[ZR_SLOTS], sent = 0, refused = 0, floods = 0, floods_refused = 0;
  zr_reset(&z);
  memset(frame, 0x5a, sizeof frame);
  for (int s = 0; s < ZR_SLOTS; s++) { zr_join(&z, 100 + s); next[s] = offset_milli[s]; }
  for (long t = 0; t < TICKS; t++) {
    for (int s = 0; s < ZR_SLOTS; s++) {
      lcg = (lcg * 1103515245UL + 12345UL) & 0x7fffffffUL;
      long jitter = (long)(lcg >> 8) % 801 - 400;
      if ((next[s] + jitter) / MILLI > t) continue;
      for (int half = 0; half < 2; half++) { sent++; if (!zr_put(&z, s, half, frame, sizeof frame)) refused++; }
      if (sent % 200 == 0) { floods++; if (!zr_put(&z, s, 0, frame, sizeof frame)) floods_refused++; }
      next[s] += ZR_SEND_TICKS * MILLI + ZR_SEND_TICKS * skew_ppm[s] / 1000;
    }
    zr_tick(&z);
  }
  printf("LEDGER honest_sent=%ld honest_refused=%ld floods=%ld floods_refused=%ld unread=%llu\n", sent, refused, floods, floods_refused,
         (unsigned long long)zr_unread(&z));
  if (floods_refused != floods) { puts("RESULT: FAIL a flood was taken"); return 1; }
  if (refused != 0) { puts("RESULT: FAIL an honest frame was refused"); return 1; }
  puts("RESULT: PASS");
  return 0;
}
