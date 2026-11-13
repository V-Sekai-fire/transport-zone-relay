#include "zone_relay.h"
#include <string.h>
static void blank(zr_zone_t *z, int s) {
  memset(z->store[s * 2], 0, sizeof z->store[s * 2]);
  memset(z->store[s * 2 + 1], 0, sizeof z->store[s * 2 + 1]);
  z->len[s * 2] = ZR_FRAME_BYTES;
  z->len[s * 2 + 1] = ZR_FRAME_BYTES;
}
void zr_reset(zr_zone_t *z) {
  for (int s = 0; s < ZR_SLOTS; s++) {
    z->people[s] = -1;
    z->heard[s] = 0;
    z->open[s * 2] = 0;
    z->open[s * 2 + 1] = 0;
    blank(z, s);
  }
  z->now = 0;
  z->unread = 0;
}
int zr_join(zr_zone_t *z, int32_t person) {
  for (int s = 0; s < ZR_SLOTS; s++)
    if (z->people[s] == person) return s;
  for (int s = 0; s < ZR_SLOTS; s++)
    if (z->people[s] == -1) {
      z->people[s] = person;
      z->heard[s] = z->now;
      return s;
    }
  return -1;
}
int zr_leave(zr_zone_t *z, int32_t person) {
  for (int s = 0; s < ZR_SLOTS; s++)
    if (z->people[s] == person) {
      z->people[s] = -1;
      blank(z, s);
      return 1;
    }
  return 0;
}
int32_t zr_person_at(const zr_zone_t *z, int slot) {
  if (slot < 0 || slot >= ZR_SLOTS) return -1;
  return z->people[slot];
}
int zr_put(zr_zone_t *z, int slot, int half, const void *bytes, size_t len) {
  if (slot < 0 || slot >= ZR_SLOTS || half < 0 || half > 1) return 0;
  if (z->people[slot] == -1) return 0;
  int at = slot * 2 + half;
  if (z->now < z->open[at]) {
    z->unread++;
    return 0;
  }
  if (len > ZR_FRAME_MAX) return 0;
#ifdef ZR_PLANT_PHASE
  static const uint8_t phase[ZR_SLOTS] = {0, 1, 3, 4};
  z->open[at] = z->now + (phase[slot] + 2 * ZR_SEND_TICKS - 1 - z->now % ZR_SEND_TICKS) % ZR_SEND_TICKS + 1;
#else
  z->open[at] = z->now + ZR_OPEN_TICKS;
#endif
  if (len > 0) memcpy(z->store[at], bytes, len);
  z->len[at] = (uint16_t)len;
  z->heard[slot] = z->now;
  return 1;
}
const uint8_t *zr_frame(const zr_zone_t *z, int viewer, int k, size_t *len) {
  *len = 0;
  if (k < 0 || k >= (ZR_SLOTS - 1) * 2) return 0;
  int other = k / 2, half = k % 2;
  int at = (other >= viewer ? other + 1 : other) * 2 + half;
  *len = z->len[at];
  return z->store[at];
}
uint64_t zr_tick(zr_zone_t *z) {
  z->now++;
  for (int s = 0; s < ZR_SLOTS; s++) {
    if (z->people[s] != -1 && z->now - z->heard[s] > ZR_SILENT_TICKS) {
      z->people[s] = -1;
      blank(z, s);
    }
  }
  return z->now;
}
uint64_t zr_unread(const zr_zone_t *z) { return z->unread; }
