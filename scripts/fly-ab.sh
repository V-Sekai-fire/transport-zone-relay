#!/bin/sh
# Interleaved A/B of the two send paths on one machine: portable (sendto) and sendmmsg. Each arm's binary hash is
# printed first, so an arm that silently ran the other binary shows. See docs/fly.md.
#   ROUNDS=3 PEOPLE="512 1024 2048" RELAYS="1" TICKS=640 fly-ab.sh
ROUNDS="${ROUNDS:-3}"
export PEOPLE="${PEOPLE:-512 1024 2048}" RELAYS="${RELAYS:-1}" TICKS="${TICKS:-640}"
for b in zone_serve zone_serve_mmsg; do echo "ARM_BINARY $b $(sha256sum "$(command -v $b)" | cut -c1-16)"; done
[ "$(sha256sum "$(command -v zone_serve)" | cut -c1-16)" = "$(sha256sum "$(command -v zone_serve_mmsg)" | cut -c1-16)" ] && { echo "the two arms are the same binary"; exit 1; }
r=1
while [ "$r" -le "$ROUNDS" ]; do
  for arm in zone_serve zone_serve_mmsg; do
    echo "ROUND $r ARM $arm"
    ZONE_SERVE=$arm /usr/local/bin/fly-sweep.sh | sed "s/^CELL /CELL round=$r arm=$arm /" | grep -E '^(MACHINE|CELL)'
  done
  r=$((r + 1))
done
echo AB_DONE
