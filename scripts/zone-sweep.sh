#!/usr/bin/env bash
# Sweeps the number of people one relay process carries and prints one line a size. It measures; it does
# not gate. BIN must hold zone_serve and zone_load (zone-net-check.sh builds them). See docs/zone-net.md.
set -euo pipefail
BIN="${BIN:?set BIN to the directory zone-net-check.sh built into}"
TICKS="${TICKS:-640}"
SIZES="${SIZES:-4 16 64 256 512 1024 2048 4096}"
port=47400
first=""
for n in $SIZES; do
  port=$((port + 2))
  "$BIN/zone_serve" "$port" $((TICKS + 90)) 0 > "$BIN/serve.$n.out" 2>&1 &
  pid=$!
  sleep 0.3
  "$BIN/zone_load" "$port" "$n" "$TICKS" > "$BIN/load.$n.out" 2>&1 || true
  wait "$pid" || true
  echo "SWEEP people=$n frames_a_viewer=6 $(head -1 "$BIN/serve.$n.out" | sed 's/^zone //')"
  echo "SWEEP people=$n $(cat "$BIN/load.$n.out")"
  if [ -z "$first" ] && grep -q '^FAIL: p99' "$BIN/serve.$n.out"; then first=$n; fi
done
if [ -n "$first" ]; then echo "SWEEP the tail first passes 4 ms at people=$first, people times frames=$((first * 6))"
else echo "SWEEP the tail stays under 4 ms at every size tried"; fi
