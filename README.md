# interactor-presence-gates

The gates that join the parts of the presence slice on a real body, with the videos and the ledger of what each rung moved.

## What is here

- `tests/byz_gate.gd`: four scripted clients through the router and the observers, with a planted zone, sender and viewer that must each be named.
- `tests/body_gate.gd`, `tests/body_lib.gd`, `tests/body_movie.gd`: one real body from one world to another, through the codec, router, observers and curve, and the movie of it.
- `tests/world_gate.gd` and `tests/world_lib.gd`: four bodies in one process, each sender judged by four parties, with a planted zone, sender and viewer named on real bodies.
- `tests/client.gd` and `tools/clients.exs`: the four as four programs, sending by UDP to the relay process, with the load generator beside them.
- `tests/parts.gd`: where the sibling parts are. They are looked for beside this repository, or under `PARTS`.
- `tools/gates.exs` runs every part's gates and their controls. `tools/body.exs` runs the body gate and its controls.
- `ledger.tsv` and `docs/ledger.md`: one row for each number a rung set out to move, with the value the end asks for beside it.
- `docs/wire.md`, `docs/gates.md`, `docs/body.md`, `docs/world.md`, `docs/clients.md`, `docs/frame-sizes.md`.

    GODOT=<double editor> PACKET_GOLDEN=<packet_golden.csv> MUJOCO_ELF=<mujoco.double.elf> elixir tools/gates.exs
    GODOT=<double editor> ANNY_FOLLOW=<follower repo> MUJOCO_ELF=<mujoco.double.elf> ANNY_GLB=<anny_base.glb> CLIPS=<clips dir> elixir tools/body.exs

## The other parts

Each part of the presence slice is a repository of its own in `V-Sekai-fire`, and they are checked
out side by side.

| Repository | What it holds |
| --- | --- |
| `interactor-packets-guest` | the Packet codec and the order of a body's 21 parts |
| `interactor-zone-router-guest` | the model of a zone that only routes, and the trace a relay replays |
| `interactor-observer-guest` | one client's check of what the zone relays: hashes, tags and verdicts |
| `interactor-curve-guest` | curve playback between sends |
| `interactor-replica-guest` | a shared object as four replicas |
| `interactor-anny-follow-guest` | the avatar posed from the muscle skeleton |
| `transport-zone-relay` | the relay in C, on sockets, with its load generator |
| `interactor-presence-gates` | the gates that join the parts on a real body, the videos and the ledger |

## Rules of the source

Guests are SafeGDScript and gates are GDScript run on a double-precision editor with the sandbox
built in. A gate prints a `RESULT:` line and has controls that must fail. Comments are at most 3%
of a file's lines, which `tools/comment_density.exs` of `interactor-presence-gates` checks, and
the explanation is in the documentation.

## Licence

MIT; see `LICENSE`.
