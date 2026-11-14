#!/bin/sh
# One relay on the machine's public UDP address, for clients that are not on the machine.
# Fly's UDP proxy delivers to fly-global-services, and a reply must leave from the same address.
HOST=$(getent hosts fly-global-services | awk '{print $1}')
echo "PUBLIC relay host=$HOST ports=47600,47601"
exec zone_serve 47600 "${TICKS:-9600}" 0 "$HOST"
