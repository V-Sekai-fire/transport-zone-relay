# The gates

Each gate prints a `RESULT:` line. `tools/gates.exs` runs each gate once as it is, which must
print `RESULT: PASS`, and once for each control, which must print `RESULT: FAIL` and must not
print `RESULT: ERROR`. A gate prints `RESULT: ERROR` when the party it named is not the one that
was planted. The engine's exit code is not trusted alone, because a script that fails to parse
exits 0. A run that outlives 10 minutes is killed and reads as no result.

```sh
GODOT=<double-precision editor with the sandbox built in> \
PACKET_GOLDEN=<contract-entity-packet>/packet_golden.csv \
MUJOCO_ELF=<interactor-mujoco-sandbox-demo>/project/plans/mujoco.double.elf \
elixir tools/gates.exs
```

`tools/frame_sizes.exs --self-test <work dir>` is the control of the frame size tool; see
`docs/frame-sizes.md`.

`tools/comment_density.exs <files>` fails when comments are more than 3% of a file's lines.

## `tests/proof_gate.gd -- <packet_golden.csv> [--control=flip]`

A SafeGDScript guest reads the `gid` of every golden Packet two ways, by `decode_u32` and by
indexed bytes. The control flips one bit of byte 0 before the call.

## `tests/hash_proof.gd [-- --control=flip]`

A guest takes SHA-256 of a frame's hex text and the engine's 32-bit hash, and each answer is
compared with the host's. The gate prints the cost of each call. The control flips one bit of
the frame the guest sees.

## `tests/byz_gate.gd [-- --ticks=N] [--keys=<dir>] [--control=<name>]`

Four scripted clients, in slots 0 to 3, each send 21 synthetic Packets every 6 ticks. They do not
send on the same tick: slot `s` sends on the ticks where `t % 6` is `PHASE[s]`, and `PHASE` is
0, 1, 3, 4, so no two senders share a tick and no tick has more than two frames for one viewer. The
router does not ask when a sender sends: a half takes one frame in 5 ticks with a burst of two,
on the router's own clock. The first
half of a run stands still and the second half walks. Without `--ticks` a run is 19,200 ticks,
5 minutes of the clock.

The pairwise keys are read from `testdata/zone-fixture`, or from `--keys`. That directory is
what `mix uro.zone_tables --fixture` of `contract-zone-backend` writes for its fixed zone of
four, whose members are the gate's four people; the sha256 of each file is in that repository's
`docs/zone-tables.md`.

Without a control the gate passes when every verdict from the second send on is valid, nothing
is refused or forged, the router's source has no `decode_` call, 28,800 bytes are relayed in every
interval of 6 ticks, still or walking, no viewer is handed more than two frames on one tick, and the
newest first frame a viewer holds of each sender is never more than 6 ticks old. The last two are
the queueing rules: arrivals are spread, and no stage keeps a line. The gate prints both measures
(`arrivals_per_tick`, `age_ticks`) and each stage's share of a 15.625 ms tick.

A control is planted from tick 600. The zone's controls replace one line of `router.sgd` before
it is compiled, and the viewer's control does the same to `observer.sgd` for slot 2 only.

| Control | What is planted | The party that must be named |
| --- | --- | --- |
| `alter` | the zone flips one bit of slot 1's first frame, the same for every viewer | `forged:1` |
| `split` | the zone flips different bits of that frame for viewers 0 and 2 and none for viewer 3 | `forged:1` |
| `leak` | the zone is handed the key of slots 1 and 0, flips a bit of slot 1's first frame for viewer 0 and writes a valid tag | `viewer:0` |
| `halftag` | the sender in slot 3 writes a wrong tag for viewer 0 only | `forged:3` |
| `swap` | the zone hands viewer 0 the frames of slots 1 and 2 in each other's place | `refused` |
| `decode` | the zone reads a `gid` | `router-reads` |
| `stale` | viewer 2 keeps an old first frame of slot 0 | `viewer:2` |
| `halves` | the sender in slot 3 takes its second frame from the send before | `sender:3` |
| `size` | the sender in slot 3 sends a first frame of 1,201 bytes | `refused` |
| `header` | the sender in slot 3 puts 20 bytes before its Packets | `refused` |
| `sametick` | every slot sends on tick 0 of the six | `bunched` |
| `fifo` | the zone keeps a line of two and hands on the older frame | `queued` |

The gate prints one `NAMED` line for each kind of verdict that was not valid, with the count of
sends, then the party the honest majority names. The names are tried in this order: a router
that reads, a refused frame, a forged tag, bunched arrivals, an old frame, and then the verdicts. A
refused frame is never counted as held, so its age is not measured.

The `leak` control does not name the relay. It shows what a leaked key costs: the forged frame
passes its tag, only viewer 0's hash differs, and the other three name viewer 0.

Measured on macOS arm64 with the interpreted tier: the four observers together take about 1.7 ms
a send with tags, and 0.8 ms without.

## `tests/curve_gate.gd [-- --control=<name>]`

Curve playback between sends, on synthetic control points: the error against the `T^4 / 384`
bound at 6, 8 and 16 ticks, and the largest move in a tick after one, two and three lost sends.
The controls are `snap` and `novel`. See `docs/curve.md`.

## `tests/packets_gate.gd -- <packet_golden_full.csv> [--control=<name>]` and `tools/body.exs`

The Packet codec against the contract, and one real body sent from one world to another. Both are
in `docs/body.md`. `tools/body.exs` needs the muscle course, the physics guest, the baked avatar
and the clips, which it takes from `MUSCLE_COURSE`, `MUJOCO_ELF`, `ANNY_GLB` and `CLIPS`.

## `tests/replica_gate.gd`

See `docs/replica.md`.

## `tests/router_trace.gd -- <out file> [--ticks=N] [--control=<name>]`

Writes every call to `router.sgd` and every answer of one scripted scenario to a binary file, for
a relay in another language to replay. It passes when the scenario reached all 17 of its items.
The controls `flip`, `flood`, `silent`, `order` and `window` each replace one line of the router; the script
runs the true router beside the planted one and names the first record where they differ. The
file format, the scenario and the controls are in `docs/router-trace.md`.
