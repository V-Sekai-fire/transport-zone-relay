#!/usr/bin/env bash
# Property tests of the Mojo relay with the witness ladder, then the same tests
# against five broken copies of the relay. Each copy must fail them, or the
# properties could not have told a broken relay from a good one.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
mojo="${MOJO:-mojo}"
# A fixed seed keeps the gate repeatable; PROPERTY_SEED=<n> tries another.
export PROPERTY_SEED="${PROPERTY_SEED:-0x5EED}"
work="${TMPDIR:-/tmp}/zone-props.$$"
mkdir -p "$work"
trap 'rm -rf "$work"' EXIT

build() { # build <native dir> <out>
  "$mojo" build -I "$1" -I "$root/thirdparty/witness-mojo/src" "$1/zone_relay_props.mojo" -o "$2"
}

echo "== the relay"
build "$root/native" "$work/props"
"$work/props"

mutate() { # mutate <name> <old> <new>
  local dir="$work/$1"
  mkdir -p "$dir"
  cp "$root/native/zone_relay_props.mojo" "$dir/"
  python3 - "$root/native/zone_relay.mojo" "$dir/zone_relay.mojo" "$2" "$3" <<'PY'
import sys
src, dst, old, new = sys.argv[1:5]
s = open(src).read()
if s.count(old) != 1:
    sys.exit("mutant not planted: %r occurs %d times" % (old, s.count(old)))
open(dst, "w").write(s.replace(old, new))
PY
  build "$dir" "$dir/props" 2>/dev/null
  # the props main raises when a property is falsified, so a broken relay exits non-zero
  if "$dir/props" >"$dir/out" 2>&1; then
    echo "MUTANT SURVIVED: $1"; cat "$dir/out"; exit 1
  fi
  echo "killed: $1 -> $(grep -m1 'falsified' "$dir/out" | sed 's/; re-run.*//' | cut -c1-150)"
}

echo "== broken relays"
mutate no-unread-count $'            self.unread_count += 1\n' $'            pass\n'
mutate leave-keeps-frames $'                self.people[unsafe_offset=s] = -1\n                self._blank(s)\n                return 1' $'                self.people[unsafe_offset=s] = -1\n                return 1'
mutate copy-one-byte-short $'        for i in range(n):\n' $'        for i in range(n - 1 if n > 0 else 0):\n'
mutate empties-a-tick-early '> UInt64(ZR_SILENT_TICKS)' '>= UInt64(ZR_SILENT_TICKS)'
mutate takes-one-extra-tick-of-burst 'self.now + UInt64(ZR_OPEN_TICKS) < self.due[unsafe_offset=at]' 'self.now + UInt64(ZR_OPEN_TICKS) + 1 < self.due[unsafe_offset=at]'
echo "WITNESS PROPS PASS"
