#!/bin/sh
# Per-host traffic counters from nlbwmon (optional dependency).
# Output: {"columns":[...],"data":[...]} (nlbwmon-action download -f json -g mac)
if [ ! -x /usr/libexec/nlbwmon-action ]; then
	printf '{"columns":[],"data":[],"error":"nlbwmon not installed"}\n'
	exit 0
fi
exec /usr/libexec/nlbwmon-action download -f json -g mac 2>/dev/null || \
	printf '{"columns":[],"data":[],"error":"nlbwmon unavailable"}\n'
