# Testing with witness-cpp

The properties of this repository are witness-cpp's, in `test/`. A property is checked on generated cases, and each is set beside a build that plants one defect and must fail it. The trace replay and the source rules in `scripts/` stay as they are.

    cmake -S test -B build -G Ninja && cmake --build build && ctest --test-dir build --output-on-failure

| File | What it checks | Planted builds that must fail |
| --- | --- | --- |
| `test/otel_span_witness.cpp` | the span emitter, read back with a reader that shares no code with it | 3 |
| `test/zone_caps_witness.cpp` | the caps of `src/zone_caps.c` against a model from `docs/zone-caps.md` | 8 |
| `test/zone_relay_witness.cpp` | the state machine against a model from `docs/zone-relay.md`: joins, leaves, frames, ticks, silence, the burst of two, a viewer never given its own slot, a leave that blanks | 9 (8 written in at configure time and `ZR_PLANT_PHASE`) |
| `test/zone_net_witness.cpp` | the relay on loopback: between 2 and 8 clients, and every client gets exactly the frames of the others in its zone, on the half they were sent on | 4 (`ZN_PLANT_HALF` and 3 written in at configure time) |

A planted build is a copy of the source with one defect written in by `test/CMakeLists.txt`, so the shipped source holds no planted code, and configuring fails if a defect did not change the source. Its test is marked `WILL_FAIL`, which also passes if the program crashes, so the failure message of each is worth reading once.

The socket test runs a real relay for about a second a case, so it uses a short ladder of 5 cases. It is built so that a slow machine cannot change the answer: who joined first is decided by the first half's socket, which keeps its order, because a tick takes the first half before the second.

CI runs the socket test by itself after the others, so that the other tests do not take its CPU.

## Not covered

- Timing. None of the properties has a clock budget; `scripts/zone-sweep.sh` measures and does not gate.
- More than 8 clients, and more than 2 zones, on sockets.
