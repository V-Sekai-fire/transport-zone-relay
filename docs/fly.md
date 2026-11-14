# The relay on Linux, on Fly

`Dockerfile`, `fly.toml`, `fly.public.toml`, `scripts/fly-sweep.sh` and `scripts/fly-public.sh`
build the relay and its load generator in a container and run them on a Fly machine. Fly builds
remotely, so Docker is not needed here. Set `app` in the toml to a new app name, and destroy the
app when the run is over; a dedicated IPv4 costs money while the app exists.

## The sweep

`fly.toml` runs `fly-sweep.sh` on one `performance-8x` machine (8 dedicated cores, Linux 6.12).
The relays and their load generators share the machine over loopback, so there is no network in
it and the loader competes with the relays for cores. For each count of people and each count of
relay processes it runs 800 ticks, 12.5 s of the clock, with the people spread over the relays
in zones of four, each sending as clients would. People are filler frames.

| People | 1 relay | 2 relays | 4 relays | 8 relays |
| --- | --- | --- | --- | --- |
| 64 | 0.44 ms | 0.24 | 0.16 | 0.09 |
| 128 | 0.85 | 0.42 | 0.23 | 0.14 |
| 256 | 1.64 | 0.89 | 0.42 | 0.22 |
| 512 | 3.29 | 2.97 | 0.84 | 0.43 |
| 1,024 | 4.65, 72% sent | 3.17 | 2.25 | 1.10 |
| 2,048 | 4.72, 36% | 6.64, 57% | 4.48, 95% | 2.01 |
| 4,096 | 5.97, 19% | 4.63, 36% | 7.49, 73% | 5.21 |

The figure is the worst relay's 99th percentile of a tick's work, in milliseconds. A percentage
is the share of the datagrams a full run would send that were sent; a cell without one sent all
of them. No relay refused a frame and none overran its clock in any cell, and no loader fell
behind its own.

So the table says three things. One relay carries 256 people with a tail of 1.6 ms and 512 with
3.3 ms, inside the 4 ms budget of RFD66606-2442, and loses frames from 1,024 on: it is one
thread. Each doubling of relays roughly doubles the people at full delivery, up to the cores the
machine has. And 8 relays on 8 cores sent every datagram of 4,096 people, with the tail over
5 ms. The loaders took cores from the relays throughout, so these are low figures.

It is zones of four and not one zone of 256 shown to everyone.

## The public relay

`fly.public.toml` runs one relay on `fly-global-services` for clients that are not on the
machine. UDP on Fly needs a dedicated IPv4 address, `fly ips allocate-v4`, and the relay must
bind to that special address so that replies leave from it. `RELAY_HOST` makes the client
programs of `interactor-presence-gates` send to it.

Four ANNY clients on a Mac in the first run reached it and received frames from it. None of their
verdicts was whole, because an observer closes each interval of 6 ticks, 94 ms, as if the network
were a local one. 2,718 frames were counted late. `CLOSE_LAG` holds an interval open for more
intervals; a rerun with a lag of three was cut off when the app reached its destroy deadline and
shows nothing.
