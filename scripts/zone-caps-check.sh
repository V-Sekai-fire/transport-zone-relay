#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
BIN="${BIN:-$(mktemp -d)}"
CC="${CC:-gcc}"
SRC=src
STRICT="-std=c99 -Wall -Wextra -Werror -pedantic -O2"

# The caps' properties and their planted builds are witness-cpp's, in test/zone_caps_witness.cpp (run by ctest in test/).
# This script holds the two source rules that a property cannot state: no allocator, and no number but 0 and 1 in zone_caps.c,
# since every cap is a constant in zone_caps.h.
numbers() {
  ! grep -n -E '(^|[^A-Za-z_0-9.])([2-9]|[0-9]{2,})[uUlL]*([^A-Za-z_0-9.]|$)' "$1"
}

$CC $STRICT -I "$SRC" -c "$SRC/zone_caps.c" -o "$BIN/caps.o"
if nm "$BIN/caps.o" | grep -E ' U _?(malloc|free|lean_)'; then echo "the caps object has an allocator or Lean symbol"; exit 1; fi
numbers "$SRC/zone_caps.c" || { echo "zone_caps.c holds a number that is not 0 or 1"; exit 1; }
sed 's|zc_pages(db_after) > ZC_MAX_PAGES|zc_pages(db_after) > 256u|' "$SRC/zone_caps.c" > "$BIN/caps_literal.c"
if cmp -s "$SRC/zone_caps.c" "$BIN/caps_literal.c"; then echo "the planted literal was not planted"; exit 1; fi
if numbers "$BIN/caps_literal.c" > /dev/null; then echo "the number rule did not catch a planted literal"; exit 1; fi
echo "RULES no heap, no Lean, no number but 0 and 1 in the source, planted literal caught"
