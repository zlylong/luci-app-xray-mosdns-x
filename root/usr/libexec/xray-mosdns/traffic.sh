#!/bin/sh
# Node traffic counters from the Xray StatsService API (only proxy node traffic).
# Output: {"nodes":[{"tag":"proxy-x","uplink":N,"downlink":N,"total":N}],"error":null}
CFG=xray-mosdns
XRAY="${XRAY:-$(uci -q get "$CFG.@global[0].xray_bin" 2>/dev/null || true)}"
[ -n "$XRAY" ] || XRAY=/usr/bin/xray
API_PORT="${API_PORT:-$(uci -q get "$CFG.@global[0].api_port" 2>/dev/null || true)}"
[ -n "$API_PORT" ] || API_PORT=10085

if ! pidof xray >/dev/null 2>&1; then
	printf '{"nodes":[],"error":"xray_not_running"}\n'
	exit 0
fi

OUT=$("$XRAY" api statsquery --server="127.0.0.1:$API_PORT" 2>/dev/null) || {
	printf '{"nodes":[],"error":"api_unavailable"}\n'
	exit 0
}

printf '%s' "$OUT" | python3 -c '
import json, sys

raw = sys.stdin.read().strip()
try:
    data = json.loads(raw) if raw else {}
except ValueError:
    print(json.dumps({"nodes": [], "error": "bad_api_output"}))
    sys.exit(0)

nodes = {}
for item in data.get("stat", []):
    name = item.get("name", "")
    value = int(item.get("value") or 0)
    parts = name.split(">>>")
    if len(parts) != 4 or parts[0] != "outbound" or parts[2] != "traffic":
        continue
    tag, direction = parts[1], parts[3]
    if not (tag.startswith("proxy-") or tag.startswith("out-")):
        continue
    entry = nodes.setdefault(tag, {"tag": tag, "uplink": 0, "downlink": 0})
    if direction == "uplink":
        entry["uplink"] += value
    elif direction == "downlink":
        entry["downlink"] += value

out = []
for entry in nodes.values():
    entry["total"] = entry["uplink"] + entry["downlink"]
    out.append(entry)
out.sort(key=lambda x: x["total"], reverse=True)
print(json.dumps({"nodes": out, "error": None}))
'
