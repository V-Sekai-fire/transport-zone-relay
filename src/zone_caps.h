#ifndef ZONE_CAPS_H
#define ZONE_CAPS_H
#include <stdint.h>
#include "zone_relay.h"
/* The caps on what a zone saves, set by the review of 2026-10-09 (docs/zone-caps.md). Every number is here and
 * nowhere else: zone_caps.c holds no number but 0 and 1, and scripts/zone-caps-check.sh fails if it does. The
 * unit is the byte and the second. */
#define ZC_PAGE_BYTES 4096u
#define ZC_MAX_PAGES 256u
#define ZC_DB_BYTES (ZC_PAGE_BYTES * ZC_MAX_PAGES)
#define ZC_PLAYER_DATA_BYTES 100000u
#define ZC_PLAYER_OBJECT_BYTES 100000u
#define ZC_MERGE_S 1
#define ZC_DAY_S 86400
#define ZC_DAY_FILLS 32u
#define ZC_DAY_BYTES (ZC_DAY_FILLS * ZC_DB_BYTES)
#define ZC_HOLD_DAYS 30u
#define ZC_COLD_BYTES ((uint64_t)ZC_DAY_BYTES * ZC_HOLD_DAYS)
typedef enum { ZC_DATA = 0, ZC_OBJECT = 1, ZC_WORLD = 2, ZC_POSE = 3 } zc_kind_t;
typedef enum {
  ZC_OK = 0,
  ZC_REFUSED_POSE = 1,
  ZC_REFUSED_KIND = 2,
  ZC_REFUSED_OWNER = 3,
  ZC_FULL_PLAYER = 4,
  ZC_FULL_DB = 5,
  ZC_FULL_DAY = 6
} zc_verdict_t;
typedef struct {
  uint32_t data[ZR_SLOTS];
  uint32_t object[ZR_SLOTS];
  uint32_t db_bytes;
  uint64_t day_bytes;
  int64_t day_start_s;
  int64_t last_save_s;
} zc_t;
void zc_init(zc_t *c);
uint32_t zc_pages(uint64_t bytes);
int zc_due(const zc_t *c, int64_t now_s);
/* Admit a save of `bytes` more bytes of `kind` for `owner` at `now_s`. A refusal leaves c as it was, so the world
 * comes back at the last good state. A save rewrites the whole image, so the daily count adds the image after it. */
zc_verdict_t zc_admit(zc_t *c, int owner, zc_kind_t kind, uint32_t bytes, int64_t now_s);
#endif
