# Four bodies, four parties

This page covers `tests/world_lib.gd` and `tests/world_gate.gd`: four people in one process, each
with a real body, each seeing the other three, and each sender judged by four parties. It is rung
2 of the ladder in `ledger.tsv`.

## The run

One physics guest holds four people on one model. Each plays a clip of its own, walk, idle,
walk back and run, forward and then backward so that it never jumps, standing 1.6 m apart. A
person sends on its own tick of the six, 0, 1, 3 or 4. A send is 21 Packets from the codec,
sealed by that person's observer with its hashes and its tags, and put into the router. Each of
the other three takes the two frames out and checks their size, ids and tag.

A frame that passes is held, not drawn. At the end of each interval of 6 ticks every observer
closes: it gives a verdict on each other sender from four reports, the sender's own hash, its
own, and the two other viewers'. A verdict of valid is about the send before, and only then do
that send's points go into the viewer's curves, so nothing is drawn that four parties did not agree
on and nothing is shown and then taken back. A viewer draws 18 ticks behind, three sends; see
below for why it is not two.

The run is 960 ticks, 15 seconds.

## What was measured

| Number | Value |
| --- | --- |
| Pairs of people who see each other | 12 of 12 |
| Verdicts that were valid | 1,896 of 1,896 |
| Party named | nobody |
| Mean distance of a drawn part from the sender's 18 ticks before | 0.48 mm |
| Largest distance | 34 mm |
| Largest distance between points of a rotation star | 35 mm |
| Share of a tick for one world's codec, router, observers and curves | 0.030 |
| Share of a tick for one world's physics | 0.66 |

A pair sees each other when all 21 parts were drawn and their mean distance is under 5 mm.

## Three sends behind, not two

The plan held that a viewer could draw two sends behind and still draw only judged points,
because the verdict on a send arrives with the next send. That is one send short. A verdict
needs the other viewers' hashes of that send, and those travel in their own next frames. So the
points of send `n - 1` are known to be valid at the end of interval `n`, and a segment needs
its far end before the view time passes its near end. With a delay of 12 ticks the far end came
up to five ticks late, every part coasted and rejoined at every send, and the mean distance was
1.60 mm with a largest of 160 mm. With 18 ticks the far end is always there: 0.48 mm and 34 mm.

So judged drawing costs 281 ms of delay, not 188. The two rules of the plan, 12 ticks behind and
from valid points only, cannot both hold, and the gate keeps the second.

The mean is still more than rung 1's 0.21 mm and the largest more than its 9 mm. One clip is a
run, which is faster than a walk. And each clip turns round at its end, where every velocity
changes sign within one tick; a curve through points 6 ticks apart cannot follow that, and no
real body does it.

The physics of one body takes two thirds of a tick on the interpreted tier, so four bodies do
not fit one process at 64 ticks a second. They are not meant to: each client has its own.

## The controls

Each control is planted from tick 300 and must be named.

| Control | What is planted | Named | Pairs seeing |
| --- | --- | --- | --- |
| `alter` | the zone flips one bit of slot 1's first frame for every viewer | `forged:1` | 9 |
| `halves` | the sender in slot 3 sends the second frame of the send before | `sender:3` | 9 |
| `stale` | viewer 2 keeps an old first frame of slot 0 | `viewer:2` | 11 |
| `silent` | the client in slot 2 stops sending | `silent:2` | 9 |

Under `alter`, `halves` and `silent` the three pairs that lose sight are the three views of the
planted sender, and the other nine go on. Under `stale` only the stale viewer's own view of slot 0
is lost. Before a verdict could be made from three reports, `stale` cost three pairs and a silent
client left only three of twelve.

    godot --headless --path . -s tests/world_gate.gd -- <mujoco.double.elf> <clips dir> [--control=alter|halves|stale|silent]

## Not here

The four as separate programs through the relay, which is the next rung. Avatars: this gate
measures the 21 parts and poses no skeleton, and the movie that does is still to be made. Any
placement of a send's work across ticks.
