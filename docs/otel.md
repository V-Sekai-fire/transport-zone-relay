# Spans from the relay

`src/otel_span.h` is a copy of the span emitter in `transport-feed-entity-servers`
(`transports/csrc/otel_span.h`); its own description and the reasons for it are in that repository's
`docs/otel.md`. A copy, not a link, so this repository builds alone; change the original first and copy it.

Every round of the loop is its own trace: a `relay.tick` root span of kind server, with the numbers `people`,
`frames_in`, `datagrams_out`, `refused`, `round_us` and `late_us` (how late the round began against its slot).
A round that ran past its slot has status error and an exception event `RoundOverrun`, which a collector lists as
an error. Each run also records a `relay.run` span with the totals and the `p50_us`, `p95_us`, `p99_us` and
`max_us` of the rounds. The numbers are doubles, because a collector averages and graphs a double and groups by an
integer or a string. The optional parts of the protocol are written every time. There is no switch:
`ZONE_OTEL=<file>` names the file and defaults to `/dev/null`, which is a place, so the work is the same whether
anyone reads it. A file that cannot be opened stops the run with an error. Spans are flushed in the idle part of
a round, 256 records at a time and only when more than 3 ms remain. The relay reads no frame to do this: it counts,
as it did.

The protobuf records go to a collector with `tools/otlp_post_pb.exs` of `interactor-otel-guest`, which adds the
resource, and so the key, at post time.

## Check

`test/otel_span_witness.cpp` and `test/CMakeLists.txt` are the witness-cpp properties and the two planted builds
of the emitter, run here as the `otel-span` job:

    cmake -S test -B build && cmake --build build && ctest --test-dir build
