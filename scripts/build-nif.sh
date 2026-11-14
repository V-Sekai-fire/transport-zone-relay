#!/usr/bin/env bash
# Build priv/native/libzone_nif.so from native/*.mojo. Mojo runs the relay.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
mojoler="${MOJOLER:-$root/deps/mojoler}"
# shellcheck source=/dev/null
source "$mojoler/scripts/env.sh"
[[ -n "${MOJO:-}" && -x "$MOJO" ]] || { echo "mojo not found" >&2; exit 1; }
out="$root/priv/native"; mkdir -p "$out"
tmp="$out/.build.$$"; mkdir -p "$tmp"
"$MOJO" build "$root/native/zone_nif.mojo" --emit shared-lib \
  -I "$root/native" -I "$mojoler/native" -o "$tmp/libzone_nif.so" "${MOJO_LINK_FLAGS[@]}"
mv "$tmp/libzone_nif.so" "$out/libzone_nif.so"; rmdir "$tmp"
