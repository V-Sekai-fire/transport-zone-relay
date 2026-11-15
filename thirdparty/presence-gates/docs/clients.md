# Four clients, a relay and a load generator

This page covers `tests/client.gd` and `tools/clients.exs`: four people as four programs, each
with its own physics and body, sending by UDP to the relay as a fifth program, with the load
generator beside them. It is rung 4 of the ladder in `ledger.tsv`.

## The run

`tools/clients.exs` builds `zone_serve` and `zone_load` from `transport-zone-relay`, starts the
relay on two ports, and starts four headless editors with `tests/client.gd`. Each client is one
person. It plays its clip on its own MuJoCo guest, writes 21 Packets every 6 ticks, seals them
with its observer and sends the first frame to the first port and the second to the next. It
reads what the relay sends it, tells the halves apart by the port they came from and the sender
by the ids in the frame, checks size, ids and tag, and closes each interval with a verdict of
four parties. It draws the other three 18 ticks behind from valid points only.

The clients share nothing but a starting moment, given to each as a time of day. Each counts its
ticks from that on its own. On one machine that is one clock; between machines it is what the
hybrid logical clock is for.

Each client writes what its body was at every tick and what it drew of each other person. When
they have all stopped, the driver sets each drawing against the sender's own record of the same
tick. A pair sees each other when the drawing has all 21 parts and its mean distance is under
5 mm.

    GODOT=<double editor> MUJOCO_ELF=<mujoco.double.elf> CLIPS=<clips dir> [SECONDS=20] [LOAD=<people>] elixir tools/clients.exs [--control=half|drift]

## What was measured

Fifteen seconds, on one macOS arm64 machine, with no load beside the four.

| Number | Value |
| --- | --- |
| Pairs of people who see each other | 12 of 12 |
| Verdicts that were valid | 1,869 of 1,896 |
| Mean distance of a drawn part from the sender's | 0.71 mm |
| Largest distance | 271 mm |
| A client's tick, mean and worst | 11.2 ms and 23 ms, of 15.6 |
| Frames the relay refused | 2 of 1,276 |

In one process the same four gave 0.48 mm and every verdict valid. Over sockets 27 verdicts
were not valid, most of them at the start before every client had sent twice, and a part coasts
and rejoins after each, which is where the largest distance comes from.

## The controls

| Control | What is planted | Pairs seeing |
| --- | --- | --- |
| `half` | the relay sends every frame from the socket of the other half | 0 of 12, with 1,884 frames refused |
| `drift` | the client in slot 3 counts its ticks 2% fast | 9 of 12: the three views that client has of the others are lost |

## What the run taught

Three things, none of which a list had asked.

One client with a wrong clock blinds everyone, not only itself. A verdict needs the hashes of
both other viewers for the same send. A client that counts its sends differently never gives
one, so every verdict that would have used it is incomplete and nothing is drawn. Four parties
find one that lies, but as built they do not go on without one that is silent or out of step.
That is a fault of liveness in the observer and it is the same fault a client that has left
would cause.

The relay falls behind its own clock and then refuses honest frames. With 16 people from the
load generator beside the four, the relay overran 144 of its 1,472 ticks and refused 1,777
frames, and no pair saw each other. The relay counts ticks, and a relay that has skipped ticks
counts fewer than the wall has had, so two frames that are six ticks apart on the wall look
closer than five to it.

And this machine cannot say what the relay's maximum is. One loopback datagram costs it about
0.39 ms, so a zone of four with 16 others already asks for a tick and a half of sending. The
maximum is a question for a Linux machine.

## After the two were mended

Both faults above were mended, one change each. The relay takes one frame in 5 ticks with a
burst of two and counts its ticks by the wall. An observer makes its verdict from three reports
when the fourth party gives none.

| Run | Pairs seeing before | Pairs seeing after |
| --- | --- | --- |
| the four alone | 12 | 12 |
| beside 16 people of the load generator | 0 | 12 |
| beside 64 people | 0 | 12 |
| one client with a clock 2% fast | 3 | 9 |

Beside 64 people 1,613 of 1,896 verdicts were whole and valid and the mean distance rose to
2.3 mm, so load still costs sight; it no longer takes it away. The relay refused no frame in any
of these runs.

## Not here

A video of the four. More than one zone that anyone watches. The relay catching its clock up.
