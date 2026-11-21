#!/usr/bin/ucode
// luci-app-xray-mosdns-x - traffic of the proxy nodes, from Xray's StatsService
//
// Prints {"nodes":[{"tag":"x.node","uplink":N,"downlink":N,"total":N}],"error":null},
// busiest node first; error is xray_not_running, api_unavailable or
// bad_api_output. XRAY and API_PORT in the environment override the
// configured values.
//
// The name ends in .sh because the LuCI views and the rpcd ACL call it so.
'use strict';

import * as fs from 'fs';
import { cursor } from 'uci';

function done(nodes, error) {
	print(sprintf('%J\n', { nodes, error }));
	exit(0);
}

// the binary and API port in effect (runtime.env next to the running
// config), else the configured ones
let rt = {};
for (let l in split(fs.readfile('/var/etc/xray-mosdns/runtime.env') ?? '', '\n')) {
	const m = match(l, /^([A-Z_]+)='?([^']*)'?$/);
	if (m)
		rt[m[1]] = m[2];
}
const uci = cursor();
let xray = getenv('XRAY') || rt.XRAY_BIN || uci.get_first('xray-mosdns', 'global', 'xray_bin') || '/usr/bin/xray';
let port = getenv('API_PORT') || rt.API_PORT || uci.get_first('xray-mosdns', 'global', 'api_port') || '10085';
// both go into a shell command
if (!match(xray, /^[A-Za-z0-9_.\/-]+$/))
	xray = '/usr/bin/xray';
if (!match(port, /^[0-9]+$/))
	port = '10085';

const p = fs.popen(`${xray} api statsquery --server=127.0.0.1:${port} 2>/dev/null`, 'r');
const raw = p?.read('all');
if (!p || p.close() != 0) {
	// is it running at all? by the name of the binary in use (xray-core, ...)
	const name = match(xray, /([^\/]+)$/)[1];
	done([], (system(`pidof '${name}' >/dev/null 2>&1`) == 0) ? 'api_unavailable' : 'xray_not_running');
}

let data;
try {
	data = json(trim(raw ?? '') || '{}');
}
catch (e) {
	done([], 'bad_api_output');
}

// stat names look like outbound>>>TAG>>>traffic>>>uplink|downlink
let nodes = {};
for (let item in ((type(data?.stat) == 'array') ? data.stat : [])) {
	const f = split(item?.name ?? '', '>>>');
	if (length(f) != 4 || f[0] != 'outbound' || f[2] != 'traffic' || !match(f[1], /\.node$/))
		continue;
	if (!(f[3] in [ 'uplink', 'downlink' ]))
		continue;
	if (!nodes[f[1]])
		nodes[f[1]] = { tag: f[1], uplink: 0, downlink: 0 };
	// int64 counters arrive as strings
	const v = +(item.value ?? 0);
	if (type(v) == 'int')
		nodes[f[1]][f[3]] += v;
}

let list = values(nodes);
for (let n in list)
	n.total = n.uplink + n.downlink;
done(sort(list, (a, b) => b.total - a.total), null);
