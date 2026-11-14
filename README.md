# transport-zone-relay

The zone relay in C: a state machine equal to the router model on a recorded trace, attached to two UDP sockets and a 64 Hz tick, with a load generator.

## What is here

- `src/zone_relay.c`: the state machine. Strict C99, no heap, and it reads no byte of a frame. `src/testdata/zone_relay.trace` is the router model's recorded run, and `src/zone_relay_check.c` replays it.
- `src/zone_net.c`: the relay on sockets. First frames come to one port and second frames to the next, so the half of a datagram is the socket it came on.
- `src/zone_clock_check.c`: clients whose clocks are not the relay's.
- `src/zone_serve.c` and `src/zone_load.c`: the relay as a process and the load generator that sends as clients would.
- `docs/zone-relay.md` and `docs/zone-net.md`.

    bash scripts/zone-relay-check.sh
    bash scripts/zone-net-check.sh
    BIN=<the directory zone-net-check.sh built into> bash scripts/zone-sweep.sh

The first two are gates with planted controls. The sweep measures and does not gate.

This code came out of `transport-feed-entity-servers`, which keeps the entity server.

## The relay in Mojo and Elixir

The same relay, with Mojo running the compute and Elixir running the server. It sits beside the C and does not replace it.

- `native/zone_relay.mojo`: the state machine, ported line for line from `src/zone_relay.c`.
- `native/zone_nif.mojo`: one zone as a BEAM resource, through [mojoler](https://github.com/thanos/mojoler).
- `lib/zone_relay/server.ex`: two UDP sockets (first frames on `port`, second on `port + 1`) and a 64 Hz tick.
- `native/zone_relay_check.mojo`: replays `src/testdata/zone_relay.trace` in Mojo alone.

It needs Mojo 1.1.0, OTP 28.3.1 and Elixir 1.20.2, the versions mojoler pins.

 mix test
 mojo build -I native native/zone_relay_check.mojo -o zrc && ./zrc src/testdata/zone_relay.trace

`scripts/witness-props.sh` property-tests the relay with `thirdparty/witness-mojo`, a Mojo port of [contract-witness-cpp](https://github.com/V-Sekai-fire/contract-witness-cpp). It replays random join, leave, put and tick sequences and checks the relay's invariants, then builds five broken copies of the relay and requires each to fail.

`mix test` replays the same trace through the NIF, with one flipped bit that must fail, then runs loopback UDP tests. Not ported: the load generator, the spans and the sweep.

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

## Licence

MIT; see `LICENSE`.
