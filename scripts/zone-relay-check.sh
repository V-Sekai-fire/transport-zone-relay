#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
BIN="${BIN:-$(mktemp -d)}"
CC="${CC:-gcc}"
SRC=src
TRACE="${TRACE:-$SRC/testdata/zone_relay.trace}"
STRICT="-std=c99 -Wall -Wextra -Werror -pedantic -O2"

opaque() {
  ! grep -n -E 'store|bytes' "$1" | grep -v -E \
    -e '^[0-9]+: +memset\(z->store\[s \* 2( \+ 1)?\], 0, sizeof z->store\[s \* 2( \+ 1)?\]\);$' \
    -e '^[0-9]+: +if \(len > 0\) memcpy\(z->store\[at\], bytes, len\);$' \
    -e '^[0-9]+: +return z->store\[at\];$' \
    -e '^[0-9]+:int zr_put\(zr_zone_t \*z, int slot, int half, const void \*bytes, size_t len\) \{$'
}

$CC $STRICT -c "$SRC/zone_relay.c" -o "$BIN/zone_relay.o"
$CC $STRICT "$SRC/zone_relay_check.c" "$BIN/zone_relay.o" -o "$BIN/zone_relay_check"

if nm "$BIN/zone_relay.o" | grep -E ' U _?(malloc|free|lean_)'; then echo "the relay object has an allocator or Lean symbol"; exit 1; fi
if nm -u "$BIN/zone_relay.o" | awk '{print $NF}' | grep -v -E '^_*(memcpy|memset|bzero|memcpy_chk|memset_chk|stack_chk_fail|stack_chk_guard|GLOBAL_OFFSET_TABLE_)$'; then
  echo "the relay object calls something other than memcpy and memset"; exit 1
fi
opaque "$SRC/zone_relay.c" || { echo "the relay source touches frame bytes outside memcpy and memset"; exit 1; }
sed 's|^  return z->store\[at\];$|  return z->store[at] + (z->store[at][0] \& 1);|' "$SRC/zone_relay.c" > "$BIN/zone_relay_reads.c"
if cmp -s "$SRC/zone_relay.c" "$BIN/zone_relay_reads.c"; then echo "the planted read was not planted"; exit 1; fi
if opaque "$BIN/zone_relay_reads.c" > /dev/null; then echo "the source rule did not catch a planted read"; exit 1; fi
echo "RULES no heap, no Lean, only memcpy and memset, planted read caught"

if command -v sha256sum > /dev/null; then SUM="sha256sum"; else SUM="shasum -a 256"; fi
if [ "$TRACE" = "$SRC/testdata/zone_relay.trace" ]; then (cd "$SRC/testdata" && $SUM -c zone_relay.trace.sha256); fi

for what in frame payload join leave put tick unread person_at; do
  rc=0
  "$BIN/zone_relay_check" "$TRACE" "--flip=$what" > "$BIN/flip.out" || rc=$?
  cat "$BIN/flip.out"
  if [ "$rc" != 1 ] || ! grep -q 'RESULT: FAIL$' "$BIN/flip.out"; then echo "the flipped $what was not caught at its record"; exit 1; fi
done
"$BIN/zone_relay_check" "$TRACE" | tee "$BIN/replay.out"
grep -q '^RELAY records=[0-9]* RESULT: PASS$' "$BIN/replay.out"
