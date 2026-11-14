FROM debian:bookworm-slim AS build
RUN apt-get update -q && apt-get install -y -q --no-install-recommends gcc libc6-dev && rm -rf /var/lib/apt/lists/*
COPY src /src
RUN gcc -std=c99 -O2 -o /zone_serve /src/zone_serve.c /src/zone_net.c /src/zone_relay.c \
 && gcc -std=c99 -O2 -o /zone_load /src/zone_load.c

FROM debian:bookworm-slim
RUN apt-get update -q && apt-get install -y -q --no-install-recommends procps libc-bin && rm -rf /var/lib/apt/lists/*
COPY --from=build /zone_serve /zone_load /usr/local/bin/
COPY scripts/fly-sweep.sh scripts/fly-public.sh /usr/local/bin/
CMD ["sh", "-c", "fly-sweep.sh; echo SWEEP_DONE; sleep 3600"]
