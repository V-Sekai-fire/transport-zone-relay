#!/bin/sh
# The load generator machine of a two-machine run: it sends to the relay machine's public address
# and reads every reply, so delivery and round trip are measured across Fly's network.
sleep 10
echo "LOADER cpus=$(nproc) kernel=$(uname -r) target=$RELAY_IP"
for p in ${PEOPLE:-64 128 256 512}; do
  echo "CELL $(zone_load 47600 "$p" 640 "$RELAY_IP")"
done
echo "ALL_CELLS_DONE"
sleep 3600
