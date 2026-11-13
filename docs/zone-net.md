# The zone relay on sockets

`src/zone_net.c` attaches the relay's state machine (`zone_relay.c`, see
`docs/zone-relay.md`) to two UDP sockets and the 64 Hz tick. It is the first form of the relay
that a client can send to. This page says what it does, what it leaves out, how it is checked and
what was measured.

## What it does

A person sends two frames at a send: parts 0 to 11, and parts 12 to 20 with three dummy Packets.
The relay must know which of the two a datagram is, and it may not read the datagram to find out.
So it listens on two ports: the first frame goes to `PORT` and the second to `PORT + 1`. Which
socket a datagram arrived on is its half. Nothing is added to a frame and nothing travels beside
it.

A person is known by the address the datagram came from. A client sends both halves from one
socket, so both have one address. The first datagram from a new address makes a person: people
are numbered in the order they appear, person `p` belongs to zone `p / 4`, and the state machine
seats it in the lowest empty slot of that zone. This is a stand-in. In the product the home
server names the members and their addresses, and a datagram from an address it did not name is
dropped; that arrives with the transport step.

At each tick the relay empties both sockets. For each datagram it finds the person, calls
`zr_put`, and if the frame was taken it sends that frame at once to the other seated members of
the zone, from the socket of the same half. Then it calls `zr_tick` for every zone that has ever
had a person. A viewer therefore gets six frames a send interval, two from each of the three
others, and tells the halves apart by the port they came from.

The relay sends a frame when it arrives and not at a fixed moment of the interval, so no frame
waits in it longer than one tick. It keeps the latest frame of each half only for the state
machine's own rules; it never sends a frame twice.

| Counter | Meaning |
| --- | --- |
| `frames_in` | frames taken |
| `datagrams_out` | frames sent on; three for each frame taken in a full zone |
| `refused` | datagrams over 1,472 bytes, a fifth person for a zone, and frames the state machine refused |
| `unread` | the state machine's own count of frames refused because the half was already taken in the interval |
| `strangers` | datagrams from a new address when 4,096 people are known |
| `send_failed` | sends the kernel refused |
| `p50`, `p95`, `p99`, `max` | for each tick, the time from the first datagram received to the end of the tick's work; a tick with no datagram counts its own short length |
| `ns_per_datagram_out` | the work time of all ticks with traffic, over `datagrams_out` |

## The rules of the source

`scripts/zone-net-check.sh` holds the socket layer to the rules the state machine has.
It compiles under `-std=c99 -Wall -Wextra -Werror -pedantic`. Its object has no allocator and no
Lean symbol. And a frame is touched in five lines only: the buffer's declaration, `recvfrom`,
`zr_put`, `zr_frame` and `sendto`. A copy of the source with one read of a frame byte planted
must fail that rule before the real source is accepted.

## The check

`zone_net_check.c` runs the relay for 320 ticks in one thread and four clients in four more. Each
client sends 40 sends of two frames, 6 ticks apart, and reads what comes back. A frame's first
three bytes name its sender, send and half, and the rest follow from them, so a viewer can tell
whether a frame is whole, whose it is and which half it is. The clients read frames; the relay
does not.

The clients' clocks are not the relay's: each sleeps a little under or over 6 ticks between sends,
up to 0.6% either way, so they drift against it. It passes when no viewer got a frame that differs
from what was sent or a frame of its own, every frame came from the socket of its half, and every
viewer got at least 80% of the 240 frames the others sent. It prints a `LEDGER` line with the
honest frames refused and the median and the 99th percentile of the tick. It does not fail on a
time: during development a run is held to the run before it, not to the 4 ms budget of
RFD66606-2442, which is where the work is going and not a gate on the way.

The script runs the check three times and adds the lines up. Two controls must show first:

| Control | What is planted | What it must do |
| --- | --- | --- |
| `-DZN_PLANT_HALF` | the relay sends each frame from the socket of the other half | `a frame came from the socket of the other half` |
| `ZONE_SLOW_NS=6000000` | 6 ms of busy work in every tick, the entity server's own planted handler | make the median tick worse by at least 5 ms |

## Clocks that are not the relay's

Threads and sockets on a desktop are too uneven to compare two rules, so the rule for taking
frames is checked without them. `zone_clock_check.c` drives the state machine for 19,200 ticks
with four clients whose clocks start at different moments, run 1,000 and 100 parts in a million
fast and slow, and arrive up to 0.4 of a tick early or late by a fixed pseudo-random sequence.
Every 200th frame is followed by a flood frame on the same tick. It passes when no honest frame
is refused and every flood frame is.

A half is open again 5 ticks after the frame it last took (`OPEN_TICKS`), counted on the relay's own clock from that frame and from nothing else.

The rule before this one opened slot `s` on the tick where the relay's `now % 6` was a fixed phase. A client keeps its own clock, so its sends drift across that tick, and then one interval got two pairs and the next none. Run on real sockets for the first time, the relay refused 7 honest frames of 320. Five ticks and not six, so that a frame one tick early is still taken; a flood gets at most six frames through in five intervals.

The old rule is kept as a planted build, `-DZR_PLANT_PHASE`, and the script requires it to fail.
Measured, on the same sequence:

| Rule | Honest frames sent | Honest frames refused | Flood frames refused |
| --- | --- | --- | --- |
| open 5 ticks after the last frame | 25,602 | 0 | 128 of 128 |
| open on a fixed tick of the relay's clock | 25,602 | 1,894 | 128 of 128 |

## The sweep

`scripts/zone-sweep.sh` starts `zone_serve` and drives it with `zone_load` at 4 to 4,096
people. The loader sends as clients would: client `k` sits in slot `k % 4` and sends its two frames
on the tick where `t % 6` is 0, 1, 3 or 4 for slots 0 to 3. Its frames are filler and its sockets
are never read, so the kernel drops what the relay sends them; the relay's cost of sending is
still paid. The sweep prints one line a size and the first size at which the tail passes 4 ms. It
measures and does not gate, and nothing waits on it.

Each viewer is handed six frames an interval at every size, because a zone is four people. The
product the plan asks for is people times six.

## What was measured

On the development Mac, three runs of the socket check together: 0 honest frames refused of 960,
a median tick of about 10 microseconds, and 6 ms a tick with the planted handler. The first run
of this layer, under the old rule, refused 7 of 320. The sweep has not been run on a machine
whose times mean anything, and no number of people is claimed.

## What the check does not show

- Anything about the home server's member table, keys or `sees`; a person here is an address.
- A real network. Everything is loopback on one machine, with the loader beside the relay.
- A send backend other than one `sendto` a datagram. The entity server measured batched sends
  separately, and the same choice is open here.
- Absolute time. On the development Mac one loopback datagram costs about 0.4 ms in either
  program, so times here are good for comparing one run with the next and for nothing else.
