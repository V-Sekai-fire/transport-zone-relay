# Levels of detail in the zone relay (parked)

Status: parked. Nothing here is built; every section below is a placeholder. The measured costs are real and the rest is to be decided.

Resume when a load generator can send to viewers at different distances, or when a zone needs more than the 256 people the relay carries now.

## The three levels

**LAYER.** Distance rings around a viewer. A near ghost is shown as a full body. A farther ghost is sent less often (TDM). A farthest ghost is collapsed to less than the full body, which can be any subset of it and is not only the root bone.

- Who assigns a ring to a viewer and a sender: to be decided. The relay reads no byte of a frame, so it cannot measure distance. The home server's member table and `sees` is the likely source.
- How many rings and where their edges lie: to be decided.
- How a reduced body is made: to be decided. The sender can make a second, smaller frame; the relay cannot cut one.

**TDM.** A ring gets a sender on one tick in N instead of every tick.

- N for each ring: to be decided.
- Where the schedule lives: to be decided. It needs the tick number and a ring, and no frame bytes, so it can stay inside the state machine.

**Motion prediction via motion matching.** The client fills the ticks that TDM skips by predicting the ghost's motion with the motion-matching picker (`interactor-motion-matching-guest`).

- Client only; the relay holds nothing for it.
- What the picker takes as input from a reduced frame: to be decided.
- How far a prediction may run before the next real frame corrects it: to be decided.

## What was measured

On a Fly performance-2x machine, sender and receiver on separate cores, three runs each, after the batching of `zone_net.c`. The cost of one datagram does not depend on its size, so a smaller body saves time only if it also means fewer datagrams.

| Frame size | Cost of a send, one datagram a frame |
| --- | --- |
| 1200 bytes | 3.456e-6 s |
| 300 bytes | 3.462e-6 s |
| 75 bytes | 3.409e-6 s |

Many frames to one viewer in one call, 75-byte frames:

| Frames per call | Packed in one datagram | One `sendmsg` with `UDP_SEGMENT` |
| --- | --- | --- |
| 4 | 0.905e-6 s a frame | 1.585e-6 s a frame |
| 8 | 0.466e-6 s a frame | 1.045e-6 s a frame |
| 16 | 0.24e-6 s a frame | 0.778e-6 s a frame |
| 32 | 0.118e-6 s a frame | 0.626e-6 s a frame |

Packing needs frame lengths in the relay and an unpacking client. `UDP_SEGMENT` leaves the client unchanged but needs equal sizes to one destination.

## Not measured

- A load generator with near, middle and far viewers. Until then the saving of any ring mix is arithmetic, not a run.
- The tick's 99.9th percentile with packing or `UDP_SEGMENT`.
- A real network.
