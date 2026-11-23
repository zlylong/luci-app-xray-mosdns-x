#!/usr/bin/ucode
// luci-app-xray-mosdns-x - recent DNS queries, as JSON
//
//   querylog.uc [limit] [filter]
//   querylog.uc top           who asked most, and for what, in what the
//                             log holds (its newest TOP_SCAN lines)
//
// With dns.query_log on, mosdns writes one JSON line per query (the preset
// _query_summary node, message "query summary"). It does not say how the
// query was handled: the configurable query_summary plugins that could crash
// mosdns-x. This reads the newest lines of that file. `filter` is matched
// against the name and the client address.
'use strict';

import * as fs from 'fs';
import { cursor } from 'uci';

const LOG = getenv('MOSDNS_LOG') || '/tmp/mosdns-x.log';	// the environment only for the tests
const SCAN = 6000;	// newest log lines looked at
const TOP_SCAN = 60000;	// ... for the ranking
const TOP = 10;
const LEASES = getenv('DHCP_LEASES') || '/tmp/dhcp.leases';	// the environment only for the tests
const SUMMARY = 'query summary';	// the message of the preset _query_summary
const QTYPES = { '1': 'A', '2': 'NS', '5': 'CNAME', '6': 'SOA', '12': 'PTR', '15': 'MX', '16': 'TXT',
                 '28': 'AAAA', '33': 'SRV', '64': 'SVCB', '65': 'HTTPS', '255': 'ANY' };
const RCODES = { '0': 'NOERROR', '2': 'SERVFAIL', '3': 'NXDOMAIN', '5': 'REFUSED', '-1': 'NO RESPONSE' };

let limit = +(ARGV[0] ?? 200);
if (!(limit > 0 && limit <= 2000))
	limit = 200;
const needle = lc(ARGV[1] ?? '');

function out(obj) {
	print(obj, '\n');
}

// mosdns-x writes the time of a JSON line as "time", ISO 8601
// ("2026-11-22T12:31:46.982Z", or with an offset); plain zap writes "ts",
// seconds. Returns seconds, or null.
function log_time(e) {
	if (type(e.ts) in [ 'int', 'double' ])
		return e.ts;
	const m = match(`${e.time ?? ''}`,
		/^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(\.[0-9]+)?(Z|([+-])([0-9]{2}):?([0-9]{2}))?$/);
	if (!m)
		return null;
	let t = timegm({ year: +m[1], mon: +m[2], mday: +m[3], hour: +m[4], min: +m[5], sec: +m[6] });
	if (m[9])
		t -= ((m[9] == '-') ? -1 : 1) * (+m[10] * 3600 + +m[11] * 60);
	return m[7] ? t + +`0${m[7]}` : t;
}

// mosdns-x writes durations the way Go prints them ("140.5µs", "4.18ms",
// "1m2.5s"); plain zap writes seconds. Returns milliseconds, or null.
const UNIT_MS = { h: 3600000, m: 60000, s: 1000, ms: 1, 'µs': 0.001, us: 0.001, ns: 0.000001 };
function elapsed_ms(v) {
	if (type(v) in [ 'int', 'double' ])
		return v * 1000;
	const parts = match(`${v ?? ''}`, /([0-9.]+)(h|ms|m|s|µs|us|ns)/g);
	if (!length(parts))
		return null;
	let ms = 0;
	for (let p in parts)
		ms += +p[1] * UNIT_MS[p[2]];
	return ms;
}

// with the query log off there is nothing of interest in the file: do not
// read thousands of lines to find that out (the DNS page asks on every load)
if (cursor().get('xray-mosdns', 'dns', 'query_log') != '1') {
	out({ ok: true, entries: [], total: 0, note: 'query log off' });
	exit(0);
}

if (!fs.access(LOG)) {
	out({ ok: true, entries: [], total: 0, note: 'no log file' });
	exit(0);
}

// The ranking: clients and names by number of queries, with how many of
// them got "no such name" (a blocked name, or a client that keeps asking
// for one that does not exist). The lines are not parsed as JSON: there
// may be tens of thousands.
if (ARGV[0] == 'top') {
	let hosts = {};
	for (let l in split(fs.readfile(LEASES) ?? '', '\n')) {
		const f = split(l, ' ');
		if (length(f) >= 4 && f[3] != '*')
			hosts[f[2]] = f[3];
	}
	const tp = fs.popen(`tail -n ${TOP_SCAN} ${LOG}`, 'r');
	let clients = {}, names = {}, n = 0, first = null, last = null;
	if (tp) {
		for (let line = tp.read('line'); length(line); line = tp.read('line')) {
			if (index(line, `"msg":"${SUMMARY}"`) < 0)
				continue;
			const c = match(line, /"client":"([^"]*)"/), q = match(line, /"qname":"([^"]*)"/);
			if (!c || !q)
				continue;
			const nx = index(line, '"resp_rcode":3,') >= 0 || index(line, '"resp_rcode":3}') >= 0;
			const name = rtrim(q[1], '.');
			clients[c[1]] ??= [ 0, 0 ];
			clients[c[1]][0]++;
			names[name] ??= [ 0, 0 ];
			names[name][0]++;
			if (nx) {
				clients[c[1]][1]++;
				names[name][1]++;
			}
			const t = match(line, /"time":"([^"]*)"/);
			if (t) {
				first ??= t[1];
				last = t[1];
			}
			n++;
		}
		tp.close();
	}
	const rank = (m, key) => map(slice(sort(keys(m), (a, b) => m[b][0] - m[a][0]), 0, TOP),
		k => ({ [key]: k, queries: m[k][0], nxdomain: m[k][1] }));
	let cl = rank(clients, 'client');
	for (let e in cl)
		e.host = hosts[e.client] ?? null;
	out({ ok: true, queries: n, from: first ? log_time({ time: first }) : null, to: last ? log_time({ time: last }) : null,
		clients: cl, names: rank(names, 'name') });
	exit(0);
}

const p = fs.popen(`tail -n ${SCAN} ${LOG}`, 'r');
const text = p ? p.read('all') : '';
if (p)
	p.close();

let entries = [], total = 0;
const lines = split(text ?? '', '\n');
// newest first
for (let i = length(lines) - 1; i >= 0; i--) {
	const line = lines[i];
	if (index(line, '"qname"') < 0)
		continue;
	let e;
	try {
		e = json(line);
	}
	catch (err) {
		continue;
	}
	if (e?.msg != SUMMARY || e.qname == null)
		continue;
	const name = rtrim(e.qname, '.');
	const client = `${e.client ?? ''}`;
	if (length(needle) && index(lc(name), needle) < 0 && index(client, needle) < 0)
		continue;
	total++;
	if (length(entries) < limit)
		push(entries, {
			ts: log_time(e),
			client,
			name,
			type: QTYPES[`${e.qtype}`] ?? `TYPE${e.qtype}`,
			rcode: RCODES[`${e.resp_rcode}`] ?? `RCODE${e.resp_rcode}`,
			ms: elapsed_ms(e.elapsed),
			error: e.error ?? null,
		});
}

out({ ok: true, entries, total, scanned: length(lines) });
