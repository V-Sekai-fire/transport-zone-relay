# How large a compressed frame is

The plain bytes of a person do not fit the budget: two frames of 1,200 bytes at 10.67 sends a
second are 25,600 bytes a second, against a budget of 8,192, bursts to 12,288 and a hard cap of
18,432. Each frame is therefore coded alone against one fixed dictionary file, and whether that
is enough is a thing to measure on real motion, not to estimate.

## The tool

```sh
elixir tools/frame_sizes.exs <dir of .frames> <work dir> [--every=N]
elixir tools/frame_sizes.exs --self-test <work dir>
```

A `.frames` file is the frames one person sent, one after another: 1,200 bytes each, the first
and the second frame of each send in turn. One file is one stream, for example one clip or one
play session.

The tool sorts the streams by name and uses every second one to build the dictionaries: frames
taken at even steps through those streams until the file is 16, 64 or 256 KiB. It measures the
other streams, which the dictionary never saw. `--every=N` measures one send in N. It codes each
frame with the Zstandard command-line tool's `--patch-from`, which gives the old data as the
prefix dictionary of one frame, as the engine's delta encoder does, and adds 5 bytes for the
engine's own header. It also measures no dictionary, and the send before as the dictionary, for
comparison.

The self-test is the tool's control: a frame of random bytes must not shrink, and a frame of
zeros must shrink to under 64 bytes.

## Measurements, 2026-11-13

62 animation clips of the muscle skeleton, 29 minutes of motion, played at the 64 Hz tick and
written as the 21 Packets of one person, with observer hashes in the dummy Packets. Half the
clips built the dictionaries and sends of the other half were measured.

Every native field is filled: position, velocity as the move since the tick before, acceleration
as the second difference rounded up in size as the contract's `accelCodeUp` does, the tick, the
owner, the part and the rotation. Face parameters are zero.

### Every 6 ticks, 10.67 sends a second

| Dictionary | Level | Bytes a send | Bytes a Packet | Up, bytes a second | Down from three others | Against 8,192 |
| --- | --- | --- | --- | --- | --- | --- |
| none | 3 | 982 | 46.8 | 10,476 | 31,428 | over |
| fixed, 64 KiB | 3 | 947 | 45.1 | 10,100 | 30,300 | over |
| fixed, 64 KiB | 19 | 815 | 38.8 | 8,693 | 26,079 | over by 6% |
| the send before | 3 | 843 | 40.1 | 8,989 | 26,967 | over |
| the send before | 19 | 791 | 37.7 | 8,436 | 25,308 | over by 3% |

### Every 8 ticks, 8 sends a second

| Dictionary | Level | Bytes a send | Bytes a Packet | Up, bytes a second | Down from three others | Against 8,192 |
| --- | --- | --- | --- | --- | --- | --- |
| none | 3 | 982 | 46.8 | 7,856 | 23,568 | under by 4% |
| fixed, 64 KiB | 3 | 948 | 45.1 | 7,581 | 22,743 | under by 7% |
| fixed, 64 KiB | 19 | 814 | 38.8 | 6,510 | 19,530 | under by 21% |
| the send before | 3 | 847 | 40.3 | 6,776 | 20,328 | under by 17% |
| the send before | 19 | 795 | 37.8 | 6,358 | 19,074 | under by 22% |

What they show:

- At 6 ticks the budget is missed at every setting, by 6% at best with a fixed dictionary. Every
  figure is under the burst of 12,288 and the cap of 18,432.
- At 8 ticks the budget is met at every setting, even with no dictionary.
- The bytes of a send do not grow when sends are further apart: 815 at 6 ticks and 814 at 8. So
  the bytes a second follow the send rate directly, and 7 ticks would give about 7,450 at
  level 19 and about 8,660 at level 3.
- The size of the dictionary does not matter between 16 KiB and 256 KiB.
- A fixed dictionary costs about 3% against using the send before, at level 19. So frames that
  each stand alone, with no state shared between sends, are nearly free.
- The level matters more than the dictionary: level 19 saves about 14% over level 3.

An earlier run on the same clips left the acceleration field at zero, as an older copy of the
contract had it. It gave 692 bytes a send at level 19 and 6 ticks, 7,384 bytes a second, under
the budget. The acceleration costs about 120 bytes a send, and with it that result does not
hold. In that run a standing body cost as much as a running one, and rounding positions to 1 mm
and rotations and velocities to coarser steps saved under 2%.

What they do not show:

- The engine function's own bytes. The command-line tool stands in for it here.
- The time to code a frame at level 19, in a guest or natively.
- Face parameters. They add at most 32 bytes a send: 341 bytes a second at 6 ticks, 256 at 8.
- Play in a headset, where hands and head move less smoothly than a clip. A session's frames,
  written as a `.frames` file, go through the same tool.

The tool's send rate is a constant in its source, 64 / 6. The 8-tick table was made with that
constant changed.

The clips are not in this repository, and neither are frames made from them.
