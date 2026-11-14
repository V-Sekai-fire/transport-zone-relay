# Spans from the relay

`src/otel_span.h` is a copy of the span emitter in `transport-feed-entity-servers`
(`transports/csrc/otel_span.h`); its own description and the reasons for it are in that repository's
`docs/otel.md`. A copy, not a link, so this repository builds alone; change the original first and copy it.

The relay records a `relay.run` span with a `relay.tick` child for every round of its loop, in every run, and appends
them to a file as protobuf records. The attributes of a tick are `people`, `frames_in`, `datagrams_out`, `refused`
and `tick`. There is no switch: `ZONE_OTEL=<file>` names the file and defaults to `/dev/null`, which is a place, so
the work is the same whether anyone reads it. A file that cannot be opened stops the run with an error. Spans are
flushed in the idle part of a round, when the ring is half full and more than 3 ms remain. The relay reads no frame to
do this: it counts, as it did.

The protobuf records go to a collector with `tools/otlp_post_pb.exs` of `interactor-otel-guest`, which adds the
resource, and so the key, at post time.

## Check

`test/otel_span_witness.cpp` and `test/CMakeLists.txt` are the witness-cpp properties and the two planted builds
of the emitter, run here as the `otel-span` job:

    cmake -S test -B build && cmake --build build && ctest --test-dir build
