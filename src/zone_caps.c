#include <string.h>
#include "zone_caps.h"

void zc_init(zc_t *c) {
  memset(c, 0, sizeof *c);
  c->last_save_s = -(int64_t)ZC_MERGE_S;
}

uint32_t zc_pages(uint64_t bytes) { return (uint32_t)((bytes + ZC_PAGE_BYTES - 1u) / ZC_PAGE_BYTES); }

int zc_due(const zc_t *c, int64_t now_s) { return now_s - c->last_save_s >= (int64_t)ZC_MERGE_S; }

zc_verdict_t zc_admit(zc_t *c, int owner, zc_kind_t kind, uint32_t bytes, int64_t now_s) {
  uint64_t day_used = c->day_bytes;
  int64_t day_start = c->day_start_s;
  uint64_t db_after;
  if (kind == ZC_POSE) { return ZC_REFUSED_POSE; }
  if (kind != ZC_DATA && kind != ZC_OBJECT && kind != ZC_WORLD) { return ZC_REFUSED_KIND; }
  if (kind != ZC_WORLD && (owner < 0 || owner >= ZR_SLOTS)) { return ZC_REFUSED_OWNER; }
  if (kind == ZC_DATA && bytes > ZC_PLAYER_DATA_BYTES - c->data[owner]) { return ZC_FULL_PLAYER; }
  if (kind == ZC_OBJECT && bytes > ZC_PLAYER_OBJECT_BYTES - c->object[owner]) { return ZC_FULL_PLAYER; }
  db_after = (uint64_t)c->db_bytes + bytes;
  if (zc_pages(db_after) > ZC_MAX_PAGES) { return ZC_FULL_DB; }
  if (now_s - day_start >= (int64_t)ZC_DAY_S) { day_used = 0u; day_start = now_s; }
  if (db_after > ZC_DAY_BYTES - day_used) { return ZC_FULL_DAY; }
  if (kind == ZC_DATA) { c->data[owner] += bytes; }
  if (kind == ZC_OBJECT) { c->object[owner] += bytes; }
  c->db_bytes = (uint32_t)db_after;
  c->day_bytes = day_used + db_after;
  c->day_start_s = day_start;
  c->last_save_s = now_s;
  return ZC_OK;
}
