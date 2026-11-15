#!/bin/sh
# People against relays; one LEDGER line a cell. See docs/clients.md.
#   GODOT= MUJOCO_ELF= CLIPS= [BINTR=] sh tools/relay_sweep.sh [people...]
set -u
PEOPLE="${*:-64 128 192 256}"
RELAY_COUNTS="${RELAY_COUNTS:-1 2 4 8}"
for p in $PEOPLE; do
  for r in $RELAY_COUNTS; do
    out=$(SECONDS="${SECONDS_RUN:-15}" RELAYS=$r LOAD=$((p - 4)) elixir tools/clients.exs 2>&1)
    echo "CELL people=$p relays=$r $(echo "$out" | grep '^LEDGER' | sed 's/^LEDGER //')"
    echo "$out" | grep '^RELAY' | sed 's/^/  /'
    echo "  $(echo "$out" | grep '^RESULT')"
  done
done
