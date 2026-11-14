#!/bin/sh
# People against relay processes on one Linux machine; prints one line a cell and the machine's own
# numbers. The loader and the relays share the machine over loopback. See docs/fly.md.
#   PEOPLE="64 128 256 512 1024" RELAYS="1 2 4 8" TICKS=640 fly-sweep.sh
PEOPLE="${PEOPLE:-64 128 256 512 1024 2048 4096}"
RELAYS="${RELAYS:-1 2 4 8}"
TICKS="${TICKS:-640}"
echo "MACHINE cpus=$(nproc) kernel=$(uname -r) $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | tr -s ' ')"
port=47000
for r in $RELAYS; do
  for p in $PEOPLE; do
    share=$(( (p + r - 1) / r ))
    [ "$share" -gt 4096 ] && continue
    i=0; pids=""
    while [ "$i" -lt "$r" ]; do
      ${ZONE_SERVE:-zone_serve} $((port + 2 * i)) $((TICKS + 160)) 0 > /tmp/serve.$i.out 2>&1 &
      pids="$pids $!"; i=$((i + 1))
    done
    sleep 0.5
    i=0
    while [ "$i" -lt "$r" ]; do
      zone_load $((port + 2 * i)) "$share" "$TICKS" > /tmp/load.$i.out 2>&1 &
      i=$((i + 1))
    done
    wait $pids
    worst=0; refused=0; over=0; slow=0; out=0; p99=0; dmin=100.00; rttmax=0
    i=0
    while [ "$i" -lt "$r" ]; do
      l=$(head -1 /tmp/serve.$i.out)
      v=$(echo "$l" | sed -n 's/.* p99=\([0-9]*\)ns.*/\1/p'); [ "${v:-0}" -gt "$p99" ] && p99=$v
      o=$(echo "$l" | sed -n 's/.* overruns=\([0-9]*\).*/\1/p'); [ "${o:-0}" -gt "$over" ] && over=$o
      f=$(echo "$l" | sed -n 's/.* refused=\([0-9]*\).*/\1/p'); refused=$((refused + ${f:-0}))
      d=$(echo "$l" | sed -n 's/.* datagrams_out=\([0-9]*\).*/\1/p'); out=$((out + ${d:-0}))
      dp=$(sed -n 's/.*delivered_pct=\([0-9.]*\).*/\1/p' /tmp/load.$i.out); [ -n "$dp" ] && dmin=$(echo "$dp $dmin" | awk '{print ($1<$2)?$1:$2}')
      rr=$(sed -n 's/.*rtt_p99_us=\([0-9]*\).*/\1/p' /tmp/load.$i.out); [ "${rr:-0}" -gt "$rttmax" ] && rttmax=$rr
      s=$(sed -n 's/.*slow_passes=\([0-9]*\).*/\1/p' /tmp/load.$i.out); slow=$((slow + ${s:-0}))
      i=$((i + 1))
    done
    echo "CELL people=$p relays=$r per_relay=$share worst_p99_ns=$p99 worst_overruns_of_$((TICKS + 160))=$over refused=$refused datagrams_out=$out loader_slow_passes=$slow min_delivered_pct=$dmin worst_rtt_p99_us=$rttmax"
    port=$((port + 2 * r + 2))
  done
done
echo ALL_CELLS_DONE
