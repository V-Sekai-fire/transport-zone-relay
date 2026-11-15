# The wire, the router and the observer

This page holds what the source files do not say in comments. The code keeps its comments under
3% of its lines, and the explanation lives here.

## Frames and Packets

A Packet is the 100-byte entity packet of `contract-entity-packet`, unchanged. The offsets the
guests use are `gid` at 0, `hlc` at 40 (a 24-bit tick above an 8-bit counter) and the 40-byte
`payload` at 58. Bytes 34 to 39 are the acceleration and bytes 98 and 99 are reserved and zero.
The tables below use payload bytes 0 to 35, so they fit.

A frame is 12 Packets, 1,200 bytes. A person is 21 Packets, one for each body part, with
`gid = 2,000,000 + person * 21 + part`. They travel as two frames:

| Frame | Packets |
| --- | --- |
| first | parts 0 to 11 |
| second | parts 12 to 20, then three dummy Packets |

A dummy Packet has every native field at zero. Its payload is written by the observer:

| Payload bytes | Content |
| --- | --- |
| 0 to 15 | the hash this client took of one other sender's two frames. Dummy `d` holds the hash for the `d`-th other slot, in slot order with the client's own slot left out |
| 16 to 31 | in dummy 0 only: the hash of this client's own two frames |
| 32 to 35 | the tick of the frame that carries the hashes. The hashes are of the send before |

A hash is the first 16 bytes of SHA-256 over the hex text of the two frames joined. The hex text
is used because it is the hash a SafeGDScript guest can reach; `proof/hash.sgd` shows it equals
the host's and takes about 17 microseconds for a frame.

A person sends once every 6 ticks of a 64 Hz clock. Both frames of a send carry the same tick.

## `router.sgd`

The zone. It reads no byte of a frame.

| Call | What it does |
| --- | --- |
| `reset()` | empties the four slots |
| `join(person) -> int` | the slot the person holds, or -1 when all four are taken. A person who is already seated gets the same slot |
| `leave(person) -> bool` | frees the slot and blanks its frames |
| `person_at(slot) -> int` | the person in a slot, or -1 |
| `put(slot, half, frame) -> bool` | stores one frame. A half takes one frame in 5 ticks (`OPEN_TICKS`) with a burst of two, on the relay's own clock. Each half has a due time. A frame is refused while now is more than 5 ticks short of the due time; a frame that is taken moves the due time 5 ticks on from now, or from the due time if that is later. A frame that comes sooner is counted in `unread_count` and not stored, so a flood makes the router do less |
| `frame(viewer, k) -> PackedByteArray` | frame `k` of 6 for a viewer: the two halves of each other slot, in slot order. An empty slot gives a blank frame of 1,200 zero bytes |
| `tick() -> int` | the pass that runs at every tick. It visits all four slots whoever is present and empties a slot that has been silent for more than 192 ticks |

## `observer.sgd`

One client's check of what the router hands it.

| Call | What it does |
| --- | --- |
| `setup(slot, a, b, c, d)` | this client's slot and the people in slots 0 to 3 |
| `seal(first, second, tick) -> PackedByteArray` | the second frame with its three dummy Packets written, by the payload table above. It then takes the hash of this client's own two frames, to state in the next send |
| `take(k, frame) -> bool` | one frame from the router. A frame that is not 1,200 bytes, or that holds a Packet whose `gid` is not the part its sender's slot must send in that place, is refused and counted in `refused_count()` |
| `close(tick) -> PackedInt32Array` | after the six frames of a send. Three verdicts, one for each other slot in slot order, on that sender's send before this one. It then takes this client's hashes of the frames just received |

The verdict codes:

| Code | Meaning |
| --- | --- |
| 0 | valid: the sender's own hash, this client's, and the two other viewers' all agree |
| 1 | incomplete: a frame or a hash was missing |
| 2 | the sender: its two halves do not carry this send's tick |
| 3 | the sender, or the zone on that sender's frames: the three viewers agree and differ from the sender |
| 4 | the zone: viewers differ, each in its own way |
| 5 | this client: the sender and both other viewers agree and this client differs. It was told something else, or it is faulty |
| 10 + slot | that viewer: it differs alone |

A verdict arrives one send after the frames it judges, because the hashes of a send travel in
the next one.

## Tags under the pairwise keys

Each pair of members holds a 32-byte key that the home server gives to those two and to nobody
else. The relay holds none. Every frame carries one 8-byte tag for each of its three viewers, in
the payload of one named Packet of that frame, and never the head's:

| Frame | The Packet that carries the tags | Payload bytes |
| --- | --- | --- |
| first | Packet 3, the pelvis | 0 to 23 |
| second | Packet 0, part 12 | 0 to 23 |

The tag for the `d`-th other slot is at payload bytes `8 * d` to `8 * d + 7`. A tag is the first
8 bytes of `H(key, H(key, frame))`, where `H(key, x)` is SHA-256 over the hex text of the key
followed by the hex text of `x`, and the frame is taken with its 24 tag bytes at zero. It is a
keyed hash in two passes built from the one hash a SafeGDScript guest can reach. It is not HMAC.

`keys(a, b, c)` gives an observer its three keys, in the order of the other slots. `seal` now
answers both frames joined, the first with its tags and then the second with its hashes and its
tags, 2,400 bytes for a whole send. `take` checks the tag for this viewer after the size and the
`gid`, and a frame whose tag is wrong is dropped and counted in `forged_counts()`, one count for
each other slot. The hashes that observers echo are taken over the frames with their tags.

A relay that alters a frame cannot make its tag, so the viewer drops the frame as forged. Two
limits remain. A sender can write a wrong tag for one viewer only, and that viewer then sees a
forged frame where the others see a valid one; from the viewer's side that cannot be told from a
relay that altered the frame. And a relay that is handed one pair key can alter a frame for that
one viewer under a valid tag. The hashes then differ at that viewer alone, so the honest majority
names the viewer and not the relay. A leaked key lets the relay frame a member.

## When one party is silent

A verdict of four reports waits for the sender's hash, this client's own, and the hashes of the
two other viewers. If one of those two gives none for a send, because it has left, lost a frame
or counts its sends wrongly, the verdict is made from three: when the sender's hash, this
client's and the one other viewer's all agree, the verdict is `SILENT` plus the slot that was
missing, 20 to 23. Three reports that do not all agree leave the verdict incomplete, since
three parties cannot say who is wrong.

A viewer draws a send when at least three parties agree on it: a verdict of 0, of `VIEWER` plus
a slot, which names the one viewer that differed, or of `SILENT` plus a slot. Without this rule
one client with a wrong clock blinded everyone: no verdict was ever whole, and nothing was
drawn. With it the three that agree carry on and the fourth is named.

## What the checks do not show

They show that every viewer was told the same thing, and that each Packet is the part its slot
must send. They do not show that a body follows from its controls, and they hold against one
faulty party among four, not two. The router can still drop or delay frames.
