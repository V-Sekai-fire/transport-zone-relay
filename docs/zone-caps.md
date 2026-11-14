# Caps on what a zone saves

Status: set on 2026-10-09 by review and not built. Nothing in this repository enforces them. They apply to the code that saves a zone's journal, which is the store in `thirdparty/fdb-sqlite`, and the relay does not call it yet.

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

## Controls that must fail

Each gate must be shown to fail on a planted defect before it counts as green.

1. Write 257 pages. It must fail with `SQLITE_FULL`.
2. Write a player's 200,000 bytes and one record more. It must be refused, and the refusal names the owner.
3. Spend 33,554,432 bytes in one day, then write once more. It must be refused, and the refusal names the daily budget.
4. Journal a pose on every tick. The cap must refuse it before the cluster sees it.
5. Refuse a write, then restart. The world must come back at the last good state.

## What the review also changed

- An earlier plan capped writes at one in 10 s with a database of 16 MiB. That limited the wrong quantity and is replaced by the table above.
- The cluster's client certificate is a write credential and does not ship in a client build. A build that reaches the cluster needs a server in between.
- Database and key names in the backup are neutral. They do not carry a product name, because the bucket is shared with public projects.
- A journal record of 100 bytes (4 of header and 96 of entity) must be confirmed to hold the 32-byte hash of a garment. If it does not, the wardrobe is not kept whatever the cap allows.

## Not decided here

- Whether the relay persists anything. Today it holds the latest frame of each half in memory and saves nothing.
- Who owns the binding that counts bytes. It is not in this repository.
