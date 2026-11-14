#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
BIN="${BIN:-$(mktemp -d)}"
CC="${CC:-gcc}"
SRC=src
STRICT="-std=c99 -Wall -Wextra -Werror -pedantic -O2"

# zone_caps.c holds no number but 0 and 1. Every cap is a constant in zone_caps.h.
numbers() {
  ! grep -n -E '(^|[^A-Za-z_0-9.])([2-9]|[0-9]{2,})[uUlL]*([^A-Za-z_0-9.]|$)' "$1"
}

build() { # source -> check binary
  $CC $STRICT -I "$SRC" -c "$1" -o "$BIN/caps.o" && $CC $STRICT -I "$SRC" "$SRC/zone_caps_check.c" "$BIN/caps.o" -o "$BIN/caps_check"
}

build "$SRC/zone_caps.c"
if nm "$BIN/caps.o" | grep -E ' U _?(malloc|free|lean_)'; then echo "the caps object has an allocator or Lean symbol"; exit 1; fi
numbers "$SRC/zone_caps.c" || { echo "zone_caps.c holds a number that is not 0 or 1"; exit 1; }
sed 's|zc_pages(db_after) > ZC_MAX_PAGES|zc_pages(db_after) > 256u|' "$SRC/zone_caps.c" > "$BIN/caps_literal.c"
if cmp -s "$SRC/zone_caps.c" "$BIN/caps_literal.c"; then echo "the planted literal was not planted"; exit 1; fi
if numbers "$BIN/caps_literal.c" > /dev/null; then echo "the number rule did not catch a planted literal"; exit 1; fi
echo "RULES no heap, no Lean, no number but 0 and 1 in the source, planted literal caught"

"$BIN/caps_check" | tee "$BIN/caps.out"
grep -q '^CAPS checks=[0-9]* RESULT: PASS$' "$BIN/caps.out"

# Each planted defect must fail the check.
mutant() { # name, sed expression
  sed "$2" "$SRC/zone_caps.c" > "$BIN/caps_$1.c"
  if cmp -s "$SRC/zone_caps.c" "$BIN/caps_$1.c"; then echo "the planted $1 was not planted"; exit 1; fi
  build "$BIN/caps_$1.c"
  rc=0; "$BIN/caps_check" > "$BIN/caps_$1.out" || rc=$?
  if [ "$rc" != 1 ] || ! grep -q 'RESULT: FAIL$' "$BIN/caps_$1.out"; then echo "the planted $1 was not caught"; exit 1; fi
  echo "planted $1: caught by $(grep -c '^FAIL' "$BIN/caps_$1.out") checks"
}
mutant extra_page 's|zc_pages(db_after) > ZC_MAX_PAGES|zc_pages(db_after) > ZC_MAX_PAGES + 1u|'
mutant extra_byte 's|bytes > ZC_PLAYER_DATA_BYTES - c->data\[owner\]|bytes > ZC_PLAYER_DATA_BYTES + 1u - c->data[owner]|'
mutant no_day_cap '/return ZC_FULL_DAY;/d'
mutant pose_saved '/if (kind == ZC_POSE) return ZC_REFUSED_POSE;/d'
mutant refusal_charges 's|if (kind == ZC_POSE) return ZC_REFUSED_POSE;|if (kind == ZC_POSE) { c->day_bytes += bytes; return ZC_REFUSED_POSE; }|'
mutant day_never_ends 's|now_s - day_start >= (int64_t)ZC_DAY_S|now_s - day_start > (int64_t)ZC_DAY_S|'
mutant any_seat 's|owner < 0 \|\| owner >= ZR_SLOTS|owner < 0|'
echo "CAPS gate: the check passes and every planted defect fails it"
