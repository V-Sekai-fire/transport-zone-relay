# A body on the wire

This page covers `packets.sgd`, `data/parts.tsv` and the gate that sends one real body from one
world to another. It is rung 1 of the ladder in `ledger.tsv`.

## The run

One process holds two worlds. In the first a retargeted clip moves the MS-Human-700 muscle
skeleton in the MuJoCo guest, and `follow.sgd` of the muscle course poses ANNY from it. Every 6
ticks the 21 bodies that drive ANNY are written as 21 Packets, in two frames. The frames are
sealed by the sender's `observer.sgd`, which adds its tags, put into `router.sgd`, taken out for
the viewer, and checked by the viewer's `observer.sgd`. A frame that passes gives its positions
and velocities to `curve.sgd` as control points. At every tick the second world draws each part
at the present less 12 ticks, and a second `follow.sgd` poses a second ANNY from that.

The viewer accepts a frame when its size, its ids and its tag are right. That is less than the
judgement of four parties, which needs four worlds and is the next rungs' work.

The order of the 21 parts, the codec and the rule that keeps a position right to a hair at any
distance are in `docs/packets.md` of `interactor-packets-guest`.

## What was measured

`tools/body.exs` runs the gate on `walk` and `idle`, 894 ticks, and then each control.

| Number | Value |
| --- | --- |
| Parts drawn | 21 of 21 |
| Frames taken | 296, none refused |
| Largest distance of a part from where the sender's was 12 ticks before | 9.09 mm |
| Mean distance | 0.21 mm |
| Largest difference of a part's rotation | 185 milliradians, about 10.6 degrees |
| Largest and mean distance between the points of a part's rotation star | 14.6 mm and 0.29 mm |
| Share of a tick for the codec, router, observers, curve and second follower | 0.030 |

The share of a tick leaves out the sender's own physics, which is the same with or without a
viewer. The times are of the interpreted tier on one macOS arm64 machine.

Three things are worse than the worked figures promised, and they are what this run teaches.
The largest position error is 9 mm where the curve gate's bound for a limb was 1.5 mm; the
velocity a Packet carries is the move since the tick before, which is half a tick late, and a
walk has sharper motion at a heel strike than a sine wave. The rotation is the plainest fault:
it is interpolated on the shortest arc between two sends with no rate, and a hand turns faster
than that follows. And the codec's own share is small, so the tick's budget is spent by the
physics and not by the wire.

## The controls

Each control must make the largest error at least twice the clean run's, and is named when it
does.

| Control | What is planted | Largest error |
| --- | --- | --- |
| `swap` | the viewer's table has the two hands exchanged | 658 mm |
| `axes` | the sender's codec uses another engine's axes | 5,806 mm |
| `flip` | one bit of the first frame is flipped in transit from tick 300 | 365 mm, with 57 frames refused |

The flipped frames are refused by their tags and nothing from them is drawn. The parts of the
first frame then coast and stand, which is the error the table shows.

`tests/packets_gate.gd` holds the codec alone: all 64 golden rows of the contract written and
read, the contract's four rotation examples within one code, 2,000 round trips within 93
microradians, and the hair test above. Its controls are `flip`, `axes`, `twist` and `float`.

## Not here

Four worlds and the judgement of four parties. A rate for rotation.
The stretch and the stilt that make the two skeletons coincide, so the second ANNY has the same
faults against the muscle skeleton that the first has.

## The rotation star

A part's rotation is hard to judge as an angle and easy to judge as points. The rotation star of
`contract-rotation-star` is a frame as 7 points: its origin and the ends of its six axes. The
gate takes each drawn part's star with arms of 5 cm, sets it against the sender's star of 12
ticks before, and reports the largest and the mean distance between matching points. A wrong
rotation moves six of the seven points, so the star's error holds position and rotation in one
number of millimetres.

## The video

`tests/body_movie.gd` is not a gate. It runs the same pipeline as the gate, through
`tests/body_lib.gd`, with a window and the movie writer:

    godot --path <muscle course> --write-movie <out.mkv> --fixed-fps 32 -s <here>/tests/body_movie.gd -- <here> <mujoco.elf> <anny_base.glb> <clips dir> [--control=swap|axes|flip]

It plays walk, idle, walk_back and run, 858 frames, each clip from 8 Hammersley orbit views.

- The sender is on the left and the second avatar 1.6 m to its side.
- Each of the 21 parts is drawn on its own body as a rotation star: the origin in orange on the
  sender and blue on the copy, and the ends of the axes 5 cm out, X red, Y green and Z blue.
- The floor is the plane geom of the physics model, read from `mjc_geom_table`, and the green
  shapes are the model's other colliding geoms, 19 in all. They are drawn see-through and without
  a depth test, so a view from below the floor still shows the bodies.
- Yellow dots are the contacts `mjc_contacts` reports between the body and that floor in the
  pose of the frame. The engine finds the body on its floor in 844 of the 858 frames.
- The caption is in a strip under the picture and covers nothing.

The floor is real in that it is the physics engine's own and the engine finds the body touching
it. It does not hold the body up in this run: the clip sets the pose at every tick and nothing is
stepped, so a foot can sink into it or hang above it. A foot that the floor carries is the work of
the feet rung.

Four recordings are made each time, the real run and one for each control, and their files
differ.
