# The zone relay

`src/zone_relay.c` is the relay of one zone, a "router-only zone". A zone has four
slots. Each member sends two frames in every send interval, and the relay hands each member the
latest two frames of each of the three other slots. A frame is an opaque datagram of 1,200 bytes,
which is 12 packets of 100 bytes. The relay never reads a byte of a frame.

The behaviour was first written and checked as a reference model, `router.sgd` in
`V-Sekai-fire/interactor-zone-router-guest`, which runs inside a game engine. The product relay must not
need an engine, so it is plain C here, and a recorded trace of the model shows that the two give
the same answers.

This step adds the relay as a state machine and its check. It does not attach the relay to
`entity_serve.c`, to a socket, to the 64 Hz timer or to sessions. No existing file changes its
behaviour.

## The state machine

The relay has no heap, no I/O and no clock. All of a zone is one `zr_zone_t`, which the caller
owns and passes to every call, so one process can hold many zones. A `zr_zone_t` is about 12 KB:
eight stored frames of `ZR_FRAME_MAX` bytes and a few counters. The caller must call `zr_reset`
before any other call.

| Constant | Value | Meaning |
| --- | --- | --- |
| `ZR_SLOTS` | 4 | members of a zone |
| `ZR_FRAME_BYTES` | 1,200 | the length of a frame, and of the blank frame of an empty slot |
| `ZR_FRAME_MAX` | 1,472 | the longest datagram the relay stores |
| `ZR_SEND_TICKS` | 6 | ticks in a send interval |
| `ZR_SILENT_TICKS` | 192 | a slot that is silent for more ticks than this is emptied (3 s at 64 Hz) |

| Function | What it does |
| --- | --- |
| `zr_reset(z)` | Empties the four slots, blanks the eight frames, opens every half, and sets `now` and the unread count to 0. |
| `zr_join(z, person) -> slot or -1` | The slot the person holds. A person who is already seated gets the same slot, and the silence of that slot is not reset. A new person gets the lowest empty slot and is heard as of `now`. -1 when all four are taken. |
| `zr_leave(z, person) -> 0 or 1` | Frees the person's slot and blanks its two frames. 0 when the person holds no slot. |
| `zr_person_at(z, slot) -> person or -1` | The person in a slot, -1 for an empty slot. |
| `zr_put(z, slot, half, bytes, len) -> 0 or 1` | Stores one frame for a half (0 or 1) of a slot. A half takes one frame in 5 ticks (`OPEN_TICKS`) with a burst of two, on the relay's own clock. Each half has a due time. A frame is refused while now is more than 5 ticks short of the due time; a frame that is taken moves the due time 5 ticks on from now, or from the due time if that is later. A frame that comes sooner is refused and counted in `zr_unread`, and its bytes are not copied, so a flood makes the relay do less. A put to a slot above 3, a half above 1 or an empty slot is refused and not counted. A taken frame marks the slot as heard at `now`. |
| `zr_frame(z, viewer, k, &len) -> pointer` | Frame `k` of 6 for a viewer: the two halves of each other slot, in slot order. `k / 2` picks the other slot and `k % 2` the half. The pointer is into the zone and holds `len` bytes; it is valid until the next call that changes the zone. An empty slot gives 1,200 zero bytes. |
| `zr_tick(z) -> now` | One tick. It adds 1 to `now` and empties a slot when `now` minus the tick it was last heard is above 192. It visits all four slots whoever is present. It opens nothing: a half opens by the age of its last frame. |
| `zr_unread(z)` | The count of frames refused because their half had taken a frame under 5 ticks before. |

`now` and the unread count are 64-bit. At 64 Hz, 32 bits of ticks last about two years.

The rule before this one opened slot `s` on the tick where the relay's `now % 6` was a fixed phase. A client keeps its own clock, so its sends drift across that tick, and then one interval got two pairs and the next none. Run on real sockets for the first time, the relay refused 7 honest frames of 320. Five ticks and not six, so that a frame one tick early is still taken; a flood gets at most six frames through in five intervals.

### Details that come from the model

The relay copies the model line for line, and these follow. Each one is in the committed trace unless it says otherwise.

- A person is a 32-bit signed number and -1 is the mark of an empty slot. `zr_join(z, -1)`
  answers the lowest empty slot and seats nobody. `zr_leave(z, -1)` answers 1 when a slot is
  empty. A caller must not use -1 as a person.
- A leave, or an emptying by silence, does not open the halves of the slot. A person who takes
  the slot meets the due time the person before left there.
- `zr_frame` does not check the viewer. A viewer above 3 gets what viewer 3 gets, and a negative
  viewer gets what viewer 0 gets. The slot is in range for every viewer, so no call reads outside
  the zone. The trace holds viewers 4 and 255. It cannot hold a negative viewer; the model was
  asked once by hand and answered so.
- The silence of a slot is counted from the last frame that was taken, or from the join. A
  refused frame does not count as heard. The trace has no case where only this decides an answer.

### A frame that is not 1,200 bytes

The model has no check of the length. It was read and then tested: frames of 0, 1, 1,199, 1,201,
1,220 and 1,472 bytes are taken and handed out at the length they came, and the trace holds all
six. The relay does the same. It stores the frame as it came and hands out the same length. To
refuse a frame of a wrong length is the work of the member that receives it (the observer of the
reference model does it), because a relay that judged frames would have to be trusted.

The relay has a fixed store, so it has a longest frame, `ZR_FRAME_MAX`. It is 1,472 bytes, the
largest UDP payload of a 1,500-byte Ethernet frame over IPv4. A put longer than this is refused
and not counted, unless the half is already taken, in which case it is counted like any flood.

### Where the relay is not the model

There are four places. None of them is in the trace, and the check says nothing about them.

| Case | The model | The relay |
| --- | --- | --- |
| a first put of a half that is longer than 1,472 bytes | takes it (65,535 bytes were tested) | refuses it and does not count it |
| the caller changes its buffer after the put | keeps the caller's array, so the stored frame changes too | copied the bytes at the put, so the stored frame does not change |
| `frame` with `k` above 5, `person_at` with a slot above 3 | an error in the guest and no answer | `zr_frame` gives a null pointer and length 0, `zr_person_at` gives -1 |
| negative `k`, negative slot in `person_at` | the index wraps around the array | the same answers as the row above |

## The relay does not read frames

Three rules hold this, and `scripts/zone-relay-check.sh` runs them in CI.

1. `nm` on `zone_relay.o` shows no `malloc`, `free` or `lean_` symbol. This is the rule the tick
   object already has.
2. Every undefined symbol of `zone_relay.o` is `memcpy` or `memset`, or a form a compiler makes of
   them (`bzero`, `__memcpy_chk`, `__memset_chk`), or the stack guard, or the offset table of position-independent code. So the object cannot call
   `memcmp`, a string function, a hash or any I/O.
3. A source rule: every line of `zone_relay.c` that names the store (`store`) or the incoming
   buffer (`bytes`) must be one of four exact lines: the `memset` that blanks a frame, the one
   `memcpy` of a put, the `return` that hands a stored frame out, and the first line of `zr_put`.
   So no line indexes a byte of a frame or gives a frame to another name.

The script then plants a read (a copy of the source that looks at byte 0 of a stored frame) and
requires rule 3 to fail on it.

These are rules on the text and the symbols, not a proof. Someone who wants to defeat them can.
They are there to stop a change that reads a frame from getting in without being seen.

## The trace

`src/testdata/zone_relay.trace` is a recording of the reference model: every call of
a scripted scenario and every answer. `tests/router_trace.gd` in `interactor-zone-router-guest` writes it,
and `docs/router-trace.md` there describes it in full. The format is repeated here.

All numbers are little-endian. The file starts with the 8 bytes `RTRACE1\n` and then holds
records until its end. A record is one byte of kind, the arguments, then the answer.

| Kind | Call | Arguments | Answer |
| --- | --- | --- | --- |
| `0x01` | `join` | person: u32 | slot: i32, -1 when refused |
| `0x02` | `leave` | person: u32 | u8 |
| `0x03` | `put` | slot: u8, half: u8, len: u16, then `len` bytes | u8 |
| `0x04` | `frame` | viewer: u8, k: u8 | len: u16, then `len` bytes |
| `0x05` | `tick` | none | u32, `now` after the tick |
| `0x06` | `unread` | none | u32 |
| `0x07` | `person_at` | slot: u8 | person: i32 |

A person is written as the two's complement of a 32-bit signed number. There is no record for
`reset`; a replay starts from `zr_reset`. Records are counted from 0. The trace is a test file.
It is not a wire format, and it adds nothing to a frame or a packet.

### What the committed trace covers

The file is the 210-tick run: 1,471 records, 1,445,239 bytes. Its sha256 is in
`zone_relay.trace.sha256` beside it, and the script checks it. The frame bytes are from a seeded
generator and differ for every slot, half and tick. They are not valid packets.

The default run of the script is 1,200 ticks and 8 MB, which is too large to commit. The scenario
is written so that everything it must show happens in the first 205 ticks: the member that goes
silent stops after tick 6, so its 192 silent ticks run under the rest of the scenario and it is
emptied at tick 199. The script refuses to pass a run that does not reach all of its 17 items.
In the 210 ticks:

- four joins, a fifth join that is refused, a repeat join of a seated person;
- 35 sends, each followed by the six frames of every viewer; nine reads by one viewer between sends;
- a flood: a second and third put for both halves of a slot in one interval, and one more put
  two ticks later, all refused and counted, with the first frames still handed out;
- a put for slot 1 at tick 20, refused because the burst at tick 6 is not yet paid back, and one
  at tick 21, taken; the put of the send at tick 24 is then refused;
- puts to slots 4 and 255 and with halves 2 and 255, refused and not counted;
- frames of 0, 1, 1,199, 1,201, 1,220 and 1,472 bytes;
- a leave, a second leave of the same person, a leave of a stranger, a put to the empty slot;
- joins and leaves of person -1;
- the slot taken by a new person in the same interval, whose first put is refused and counted;
- viewers 4 and 255;
- a repeat join of the silent member, which does not reset its silence;
- the silent member still seated at tick 198 and gone at tick 199, a put to its slot refused,
  its frames blank, and the slot taken again by a new person who then sends.

What the longer run adds, and the committed file does not hold: a second member that goes
silent at tick 600 and is emptied at tick 787, a join at tick 900, and more of the same sends.
The 1,200-tick trace was replayed once by hand and passed (7,900 records); CI does not run it.

### How to make the trace again

It needs the double-precision editor with the sandbox built in, the same one the gates of
`interactor-zone-router-guest` use.

```sh
<editor> --headless --path <interactor-zone-router-guest> -s tests/router_trace.gd -- \
  src/testdata/zone_relay.trace --ticks=210
(cd src/testdata && sha256sum zone_relay.trace > zone_relay.trace.sha256)
```

Give the trace file as an absolute path. The same arguments give the same bytes. A change of `router.sgd` or of the scenario changes the
file and its sha256, and then the relay must be changed to agree with it.

## The check

```sh
bash scripts/zone-relay-check.sh
```

The script builds `zone_relay.c` and `zone_relay_check.c` with
`-std=c99 -Wall -Wextra -Werror -pedantic -O2`, runs the three rules above, checks the sha256 of
the trace, runs the planted replays and then the real one. `CC` picks the compiler (`gcc` when
not set), `BIN` the directory for the outputs, `TRACE` another trace file.

`zone_relay_check <trace>` resets a zone, makes every call of the trace against it and compares
every answer, and every byte and the length of every frame handed out. It prints

```
RELAY records=<n> RESULT: PASS
```

or the first record that differs, with its index, its kind and its offset in the file, and
exits 1:

```
RELAY record=1345 kind=person_at offset=1328174 want=-1 got=30 RESULT: FAIL
```

`want` is what the trace holds and `got` is what the relay answered. A file that is cut short or
has an unknown kind fails at that record with `kind=none`.

`--flip[=<what>]` changes one bit of the trace in memory before the replay, which must then fail
at a record that is known beforehand. `<what>` is a kind (`join`, `leave`, `put`, `frame`, `tick`,
`unread`, `person_at`) or `payload`; `--flip` alone means `frame`. For a kind, the bit is in the
last byte of the answer of the first record of that kind (for `frame`, the first that holds
bytes), and the replay must fail at that record. For `payload`, the bit is in the first byte a
member sent in the first put that was taken, and the replay must fail at a later `frame` record,
where the relay hands that byte out. The check prints a `FLIP` line with the record and offset,
then the `RELAY` line, and exits 1. If the replay passes, or fails at another record, it prints
`RESULT: ERROR` and exits 2. The script runs all eight and requires exit 1 and `RESULT: FAIL`
from each, before the real replay, so a pass counts only after the check has shown that it can
find a planted difference.

### Planted models

`router_trace.gd` can also write the trace of a planted model, with one line of the router
changed. Those traces describe a different relay, so the replay must fail on them. They are
1.4 MB each and are not committed; they were made and replayed by hand on macOS arm64, and the
replay failed on each at the record where the trace script says the planted model first differs
from the true one.

| Control | What is planted | The replay's first mismatch |
| --- | --- | --- |
| `flip` | the model flips one bit of byte 777 of a frame it hands out | record 5, `frame`, byte 777 |
| `flood` | the model takes every put, so the third of a burst is taken | record 92, `put`, want 1 got 0 |
| `silent` | the model empties a slot one tick early | record 1354, `person_at`, want -1 got 30 |
| `order` | the model hands a viewer the other slots in the wrong order | record 47, `frame`, byte 0 |
| `window` | the model takes one frame in 6 ticks, not 5 | record 209, `put`, want 0 got 1 |

To repeat it: write a trace with `--ticks=210 --control=<name>` and give it to
`zone_relay_check`.

## What the check shows and what it does not

It shows that the C state machine gives the same answers as the reference model for every call
of this one trace, with every frame equal byte for byte, and that the relay object allocates
nothing and calls nothing but `memcpy` and `memset`.

It does not show:

- that the two agree on calls the trace does not hold. The trace is one scenario, not a proof
  over all inputs. The four cases in "Where the relay is not the model" are known differences;
- anything about sockets, the 64 Hz timer, sessions, or how a datagram is matched to a person
  and a slot. The relay is not attached to `entity_serve.c` in this step;
- anything about timing or the tick budget. The check has no clock;
- that a zone tells the truth. The relay can still drop or delay frames; the members' own check
  of what they are handed is in the reference repository.
