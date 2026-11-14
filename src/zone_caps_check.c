/* Checks the caps of zone_caps.h against the numbers written in docs/zone-caps.md, and each control of that doc. */
#include <stdio.h>
#include <string.h>
#include "zone_caps.h"
static int checks, bad;
#define EXPECT(what, cond) do { checks++; if (!(cond)) { bad++; printf("FAIL %s\n", what); } } while (0)
static int same(const zc_t *a, const zc_t *b) { return memcmp(a, b, sizeof *a) == 0; }
int main(void) {
  zc_t c, before;
  int i;
  EXPECT("the database is 1,048,576 bytes", ZC_DB_BYTES == 1048576u);
  EXPECT("a day is 33,554,432 bytes", ZC_DAY_BYTES == 33554432u);
  EXPECT("cold storage holds at most 1,006,632,960 bytes", ZC_COLD_BYTES == 1006632960u);
  EXPECT("a player may save 200,000 bytes", ZC_PLAYER_DATA_BYTES + ZC_PLAYER_OBJECT_BYTES == 200000u);

  /* control 1: 257 pages fail, 256 do not */
  zc_init(&c);
  EXPECT("256 pages are admitted", zc_admit(&c, 0, ZC_WORLD, ZC_MAX_PAGES * ZC_PAGE_BYTES, 0) == ZC_OK);
  EXPECT("one byte more is the 257th page and is refused", zc_admit(&c, 0, ZC_WORLD, 1u, 0) == ZC_FULL_DB);
  zc_init(&c);
  EXPECT("257 pages in one write are refused", zc_admit(&c, 0, ZC_WORLD, (ZC_MAX_PAGES + 1u) * ZC_PAGE_BYTES, 0) == ZC_FULL_DB);

  /* control 2: a player's 200,000 bytes and one record more */
  zc_init(&c);
  EXPECT("100,000 bytes of data are admitted", zc_admit(&c, 0, ZC_DATA, ZC_PLAYER_DATA_BYTES, 0) == ZC_OK);
  EXPECT("100,000 bytes of objects are admitted", zc_admit(&c, 0, ZC_OBJECT, ZC_PLAYER_OBJECT_BYTES, 0) == ZC_OK);
  EXPECT("one byte more of data is refused", zc_admit(&c, 0, ZC_DATA, 1u, 0) == ZC_FULL_PLAYER);
  EXPECT("one byte more of objects is refused", zc_admit(&c, 0, ZC_OBJECT, 1u, 0) == ZC_FULL_PLAYER);
  EXPECT("another player is not charged", zc_admit(&c, 1, ZC_DATA, ZC_PLAYER_DATA_BYTES, 0) == ZC_OK);
  EXPECT("a seat that does not exist is refused", zc_admit(&c, ZR_SLOTS, ZC_DATA, 1u, 0) == ZC_REFUSED_OWNER);
  EXPECT("a negative seat is refused", zc_admit(&c, -1, ZC_OBJECT, 1u, 0) == ZC_REFUSED_OWNER);
  EXPECT("a kind that does not exist is refused", zc_admit(&c, 0, (zc_kind_t)ZC_POSE + 1, 1u, 0) == ZC_REFUSED_KIND);

  /* control 3: the day's bytes, and the window that opens again */
  zc_init(&c);
  EXPECT("the first fill is admitted", zc_admit(&c, 0, ZC_WORLD, ZC_DB_BYTES, 0) == ZC_OK);
  for (i = 1; i < (int)ZC_DAY_FILLS; i++) EXPECT("a fill of the day is admitted", zc_admit(&c, 0, ZC_WORLD, 0u, 0) == ZC_OK);
  EXPECT("the write past 33,554,432 bytes is refused", zc_admit(&c, 0, ZC_WORLD, 0u, 0) == ZC_FULL_DAY);
  EXPECT("it is still refused one second before the day ends", zc_admit(&c, 0, ZC_WORLD, 0u, (int64_t)ZC_DAY_S - 1) == ZC_FULL_DAY);
  EXPECT("it is admitted when the day has passed", zc_admit(&c, 0, ZC_WORLD, 0u, (int64_t)ZC_DAY_S) == ZC_OK);

  /* control 4: a pose on every tick never reaches the store */
  zc_init(&c);
  memcpy(&before, &c, sizeof c);
  EXPECT("a pose is refused", zc_admit(&c, 0, ZC_POSE, 96u, 0) == ZC_REFUSED_POSE);
  EXPECT("a refused pose leaves the state as it was", same(&c, &before));

  /* control 5: every refusal leaves the last good state */
  zc_init(&c);
  zc_admit(&c, 0, ZC_DATA, ZC_PLAYER_DATA_BYTES, 5);
  zc_admit(&c, 0, ZC_WORLD, ZC_DB_BYTES - ZC_PLAYER_DATA_BYTES, 5);
  memcpy(&before, &c, sizeof c);
  EXPECT("a full player is refused", zc_admit(&c, 0, ZC_DATA, 7u, 6) == ZC_FULL_PLAYER);
  EXPECT("a full database is refused", zc_admit(&c, 1, ZC_WORLD, 7u, 6) == ZC_FULL_DB);
  EXPECT("a bad seat is refused", zc_admit(&c, ZR_SLOTS, ZC_OBJECT, 7u, 6) == ZC_REFUSED_OWNER);
  EXPECT("refusals leave the state byte for byte", same(&c, &before));

  /* saves inside one second are merged */
  zc_init(&c);
  EXPECT("the first save is due", zc_due(&c, 0));
  zc_admit(&c, 0, ZC_WORLD, 1u, 5);
  EXPECT("a save in the same second is not due", !zc_due(&c, 5));
  EXPECT("a save one second later is due", zc_due(&c, 5 + (int64_t)ZC_MERGE_S));

  printf("CAPS checks=%d RESULT: %s\n", checks, bad ? "FAIL" : "PASS");
  return bad ? 1 : 0;
}
