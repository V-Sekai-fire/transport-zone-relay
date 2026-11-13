#!/usr/bin/env bash
# The relay on sockets: rules of the source, three planted defects, and a ledger line. See docs/zone-net.md.
set -euo pipefail
cd "$(dirname "$0")/.."
BIN="${BIN:-$(mktemp -d)}"
CC="${CC:-gcc}"
SRC=src
STRICT="-std=c99 -Wall -Wextra -Werror -pedantic -O2"
RUNS="${RUNS:-3}"

opaque() {
  ! grep -n -E 'dgram|held' "$1" | grep -v -E \
    -e '^[0-9]+: +static uint8_t dgram\[ZR_FRAME_MAX \+ 1\];$' \
    -e '^[0-9]+: +ssize_t n = recvfrom\(fd\[half\], dgram, sizeof dgram, 0, \(struct sockaddr \*\)&from, &fl\);$' \
    -e '^[0-9]+: +if \(!zr_put\(z, slot, half, dgram, \(size_t\)n\)\) \{ out->refused\+\+; continue; \}$' \
    -e '^[0-9]+: +const uint8_t \*held = zr_frame\(z, v, \(slot > v \? slot - 1 : slot\) \* 2 \+ half, &len\);$' \
    -e '^[0-9]+: +if \(sendto\(fd\[(half|1 - half)\], held, len, 0, \(const struct sockaddr \*\)&who\[seated\[zi\]\[v\]\]\.a, sizeof who\[0\]\.a\) >= 0\) out->datagrams_out\+\+;$'
}

$CC $STRICT -c "$SRC/zone_relay.c" -o "$BIN/zone_relay.o"
$CC $STRICT -c "$SRC/zone_net.c" -o "$BIN/zone_net.o"
$CC $STRICT -DZN_PLANT_HALF -c "$SRC/zone_net.c" -o "$BIN/zone_net_half.o"
$CC -std=gnu99 -O2 -Wall -Wextra -Werror -pthread "$SRC/zone_net_check.c" "$BIN/zone_net.o" "$BIN/zone_relay.o" -o "$BIN/zone_net_check"
$CC -std=gnu99 -O2 -Wall -Wextra -Werror -pthread "$SRC/zone_net_check.c" "$BIN/zone_net_half.o" "$BIN/zone_relay.o" -o "$BIN/zone_net_check_half"
$CC $STRICT "$SRC/zone_clock_check.c" "$SRC/zone_relay.c" -o "$BIN/zone_clock_check"
$CC $STRICT -DZR_PLANT_PHASE "$SRC/zone_clock_check.c" "$SRC/zone_relay.c" -o "$BIN/zone_clock_check_phase"
$CC $STRICT "$SRC/zone_serve.c" "$BIN/zone_net.o" "$BIN/zone_relay.o" -o "$BIN/zone_serve"
$CC $STRICT "$SRC/zone_load.c" -o "$BIN/zone_load"

if nm "$BIN/zone_net.o" | grep -E ' U _?(malloc|calloc|realloc|free|lean_)'; then echo "the socket layer has an allocator or Lean symbol"; exit 1; fi
opaque "$SRC/zone_net.c" || { echo "the socket layer touches a frame outside recvfrom, zr_put, zr_frame and sendto"; exit 1; }
sed 's|^        out->frames_in++;$|        out->frames_in += 1 + (dgram[0] \& 0);|' "$SRC/zone_net.c" > "$BIN/zone_net_reads.c"
if cmp -s "$SRC/zone_net.c" "$BIN/zone_net_reads.c"; then echo "the planted read was not planted"; exit 1; fi
if opaque "$BIN/zone_net_reads.c" > /dev/null; then echo "the source rule did not catch a planted read"; exit 1; fi
echo "RULES no heap, no Lean, a frame goes only to recvfrom, zr_put, zr_frame and sendto, planted read caught"

rc=0; "$BIN/zone_net_check_half" > "$BIN/half.out" || rc=$?
tail -1 "$BIN/half.out"
if [ "$rc" != 1 ] || ! grep -q '^RESULT: FAIL a frame came from the socket of the other half$' "$BIN/half.out"; then echo "the frame from the wrong socket was not caught"; exit 1; fi

# sum <field> <program> [env]: runs the check RUNS times, prints each LEDGER line, leaves the sum of one field in $total.
sum() {
  local field="$1" tag="$2"; shift 2
  total=0
  for i in $(seq 1 "$RUNS"); do
    "$@" > "$BIN/run.out" || { cat "$BIN/run.out"; echo "run $i of $tag failed"; exit 1; }
    line=$(grep '^LEDGER' "$BIN/run.out")
    echo "$tag $line"
    total=$((total + $(echo "$line" | sed "s/.* $field=\([0-9]*\).*/\1/")))
  done
}
sum honest_refused clean "$BIN/zone_net_check"; clean_refused=$total
sum p50_ns clean "$BIN/zone_net_check"; clean_p50=$total
sum p50_ns slow env ZONE_SLOW_NS=6000000 "$BIN/zone_net_check"; slow_p50=$total
echo "sockets LEDGER runs=$RUNS honest_refused=$clean_refused p50_ns_sum=$clean_p50 slow_p50_ns_sum=$slow_p50"

rc=0; "$BIN/zone_clock_check_phase" > "$BIN/phase.out" || rc=$?
echo "fixed-phase $(head -1 "$BIN/phase.out")"
if [ "$rc" != 1 ] || ! grep -q '^RESULT: FAIL an honest frame was refused$' "$BIN/phase.out"; then echo "the fixed-phase rule refused no honest frame of a drifting client"; exit 1; fi
"$BIN/zone_clock_check" > "$BIN/clock.out" || { cat "$BIN/clock.out"; exit 1; }
echo "clocks $(head -1 "$BIN/clock.out")"
if [ "$slow_p50" -lt $((clean_p50 + RUNS * 5000000)) ]; then echo "RESULT: FAIL the planted 6 ms handler did not make the median tick worse by 5 ms"; exit 1; fi
echo "RESULT: PASS"
