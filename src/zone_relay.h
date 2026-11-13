#ifndef ZONE_RELAY_H
#define ZONE_RELAY_H
#include <stddef.h>
#include <stdint.h>
#define ZR_SLOTS 4
#define ZR_FRAME_BYTES 1200
#define ZR_FRAME_MAX 1472
#define ZR_SILENT_TICKS 192
#define ZR_SEND_TICKS 6
#define ZR_OPEN_TICKS 5
typedef struct {
  int32_t people[ZR_SLOTS];
  uint64_t heard[ZR_SLOTS];
  uint64_t now;
  uint64_t unread;
  uint64_t open[ZR_SLOTS * 2];
  uint16_t len[ZR_SLOTS * 2];
  uint8_t store[ZR_SLOTS * 2][ZR_FRAME_MAX];
} zr_zone_t;
void zr_reset(zr_zone_t *z);
int zr_join(zr_zone_t *z, int32_t person);
int zr_leave(zr_zone_t *z, int32_t person);
int32_t zr_person_at(const zr_zone_t *z, int slot);
int zr_put(zr_zone_t *z, int slot, int half, const void *bytes, size_t len);
const uint8_t *zr_frame(const zr_zone_t *z, int viewer, int k, size_t *len);
uint64_t zr_tick(zr_zone_t *z);
uint64_t zr_unread(const zr_zone_t *z);
#endif
