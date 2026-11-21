#!/usr/bin/ucode
// luci-app-xray-mosdns-x - recent DNS queries, as JSON
//
//   querylog.uc [limit] [filter]
//
// With dns.query_log on, mosdns writes one JSON line per query (the
// query_summary plugin; its message names how the query was handled:
// lan / block / direct / proxy / fallback). This reads the newest lines of
// that file. `filter` is matched against the name and the client address.
'use strict';

import * as fs from 'fs';
import { cursor } from 'uci';

const LOG = '/tmp/mosdns-x.log';
const SCAN = 6000;	// newest log lines looked at
const KINDS = [ 'lan', 'block', 'direct', 'proxy', 'fallback' ];
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

const p = fs.popen(`tail -n ${SCAN} ${LOG}`, 'r');
const text = p ? p.read('all') : '';
if (p)
	p.close();

let entries = [], total = 0, counts = {};
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
	if (!(e?.msg in KINDS) || e.qname == null)
		continue;
	const name = rtrim(e.qname, '.');
	const client = `${e.client ?? ''}`;
	if (length(needle) && index(lc(name), needle) < 0 && index(client, needle) < 0)
		continue;
	total++;
	counts[e.msg] = (counts[e.msg] ?? 0) + 1;
	if (length(entries) < limit)
		push(entries, {
			ts: e.ts,
			client,
			name,
			type: QTYPES[`${e.qtype}`] ?? `TYPE${e.qtype}`,
			kind: e.msg,
			rcode: RCODES[`${e.resp_rcode}`] ?? `RCODE${e.resp_rcode}`,
			ms: (type(e.elapsed) in [ 'int', 'double' ]) ? e.elapsed * 1000 : null,
			error: e.error ?? null,
		});
}

out({ ok: true, entries, total, counts, scanned: length(lines) });
