# Caps on what a zone saves

Status: set on 2026-10-09 by review. `src/zone_caps.h` holds every number as a constant and `src/zone_caps.c` enforces them, but nothing calls it yet: the relay saves nothing, and the store in `thirdparty/fdb-sqlite` does not call it either. `bash scripts/zone-caps-check.sh` checks it.

## Why caps

A zone's saved data ends up in cold storage that keeps every write for at least 2,592,000 s (30 days). A save is therefore a cost that stays, and the cap has to bound bytes, not the number of writes: the journal is stored as one row, so every write rewrites the whole image.

## Where the numbers come from

Two outside norms set them.

- Social VR worlds. A leading platform allows each world 100,000 bytes of key-value data and 100,000 bytes of object data for each player, compressed. A save that would go over is refused and logged, and never cut short. The last good save stays.
- Competitive shooters. The network ticks at 64 Hz to 128 Hz and none of that is saved. Position is never saved. Only the profile, the loadout and the progress are saved, on events such as the end of a match.

## The caps

| What | Cap | Where it is enforced |
| --- | --- | --- |
| Per player, per world | 200,000 bytes (100,000 of data and 100,000 of objects) | The binding counts bytes per owner before it writes |
| Per zone database | 1,048,576 bytes (`PRAGMA max_page_count = 256` at 4,096 bytes a page) | SQLite refuses the write with `SQLITE_FULL` |
| What is saved | Spawn, despawn and payload changes. Never position or pose. | The zone journal |
| When it is saved | After an event, with saves inside 1 s merged into one, and once at quit | The binding |
| Bytes in 86,400 s | 33,554,432 per zone database | The binding keeps a daily byte count |
| Over any cap | The write is refused and the refusal names the owner or the budget. Nothing is cut short. The last good state stays. | The binding |

In cold storage the worst case is 33,554,432 bytes a day for 30 days, about 1,006,632,960 bytes for one zone database. The journal image today is far below 1,048,576 bytes, so the daily budget allows hundreds of saves.

## The constants

Every number is a `#define` in `src/zone_caps.h`, and `src/zone_caps.c` holds no number but 0 and 1. The gate fails if it does, and a planted literal shows that the rule can fail. `ZC_DB_BYTES`, `ZC_DAY_BYTES` and `ZC_COLD_BYTES` are products of the others, and the check compares them with the numbers written in the table above.

`zc_admit` takes an owner, a kind (data, object, world or pose), a byte count and the time in seconds. It returns `ZC_OK` or the reason it refused, and a refusal leaves the state as it was. A save rewrites the whole image, so the daily count adds the size of the image after the save, not the bytes of the change.

World data (a prop spawned by the zone) is charged to no player, only to the database and the day. That matters: four players can save at most 4 times 200,000 bytes, which is 800,000 bytes and less than the 1,048,576 bytes of the database, so the database cap binds only on world data.

## Controls that must fail

`scripts/zone-caps-check.sh` runs the check and then seven planted defects, and each must fail it.

1. A 257th page admitted (`extra_page`). The check writes 257 pages and expects a refusal.
2. A player's 200,000 bytes and one byte more (`extra_byte`), for data and for objects.
3. No cap on the day (`no_day_cap`) and a day that never ends (`day_never_ends`). The check spends 33,554,432 bytes, expects the next write refused, and expects it admitted when 86,400 s have passed.
4. A pose saved (`pose_saved`).
5. A refusal that charges the day (`refusal_charges`). The check compares the state byte for byte before and after each refusal, so the world comes back at the last good state.
6. A seat that does not exist admitted (`any_seat`).

## What the review also changed

- An earlier plan capped writes at one in 10 s with a database of 16 MiB. That limited the wrong quantity and is replaced by the table above.
- The cluster's client certificate is a write credential and does not ship in a client build. A build that reaches the cluster needs a server in between.
- Database and key names in the backup are neutral. They do not carry a product name, because the bucket is shared with public projects.
- A journal record of 100 bytes (4 of header and 96 of entity) must be confirmed to hold the 32-byte hash of a garment. If it does not, the wardrobe is not kept whatever the cap allows.

## Not decided here

- Whether the relay persists anything. Today it holds the latest frame of each half in memory and saves nothing.
- Who calls `zc_admit`. The binding between the zone and the store is not in this repository, and `PRAGMA max_page_count` is set there to `ZC_MAX_PAGES`.
