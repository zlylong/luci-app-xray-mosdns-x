#!/usr/bin/ucode
// luci-app-xray-mosdns-x - keep the plugin's own logs from growing
//
//   logs.uc prune     drop what is older than global.log_days (30), and
//                     keep each log under its size limit
//
// The logs are in /tmp (RAM): mosdns-x's (with the query log on, a line per
// query), the scheduled geo updates' and the blocklist updates'. A line's
// time is its leading ISO 8601 time (mosdns-x's console lines, ours) or the
// "time" / "ts" of a JSON line (mosdns-x's production lines); a line without
// one (a message going on over several lines) goes with the line before it.
// Each log is rewritten in place: mosdns-x keeps appending to the file it
// opened. The DNS watchdog runs this when it starts and every 6 hours.
'use strict';

import * as fs from 'fs';

const RUNTIME = '/var/etc/xray-mosdns/runtime.env';
const DAY = 86400;
// path, size limit in bytes (the watchdog trims mosdns-x's log by size too)
const LOGS = [
	[ '/tmp/mosdns-x.log', 4194304 ],
	[ '/tmp/xray-mosdns-geo-update.log', 262144 ],
	[ '/tmp/xray-mosdns-adlist.log', 262144 ],
];

// the size mosdns-x's log may have (the query log option)
function mosdns_max() {
	for (let l in split(fs.readfile(RUNTIME) ?? '', '\n')) {
		const m = match(l, /^QUERY_LOG_MAX=([0-9]+)$/);
		if (m && +m[1] >= 1048576)
			return +m[1];
	}
	return 4194304;
}

function days() {
	let d = getenv('LOGS_DAYS');
	if (!d)
		for (let l in split(fs.readfile(RUNTIME) ?? '', '\n')) {
			const m = match(l, /^LOG_DAYS=([0-9]+)$/);
			if (m)
				d = m[1];
		}
	d = +(d ?? 30);
	return (d >= 1 && d <= 365) ? d : 30;
}

// an ISO 8601 time ("2026-11-22T14:03:03.745Z", or with an offset) in seconds
function iso(s) {
	const m = match(s, /^([0-9]{4})-([0-9]{2})-([0-9]{2})[T ]([0-9]{2}):([0-9]{2}):([0-9]{2})(\.[0-9]+)?(Z|([+-])([0-9]{2}):?([0-9]{2}))?/);
	if (!m)
		return null;
	let t = timegm({ year: +m[1], mon: +m[2], mday: +m[3], hour: +m[4], min: +m[5], sec: +m[6] });
	if (m[9])
		t -= ((m[9] == '-') ? -1 : 1) * (+m[10] * 3600 + +m[11] * 60);
	return t;
}

function time_of(line) {
	if (substr(line, 0, 1) == '{') {
		let m = match(line, /"time":"([^"]+)"/);
		if (m)
			return iso(m[1]);
		m = match(line, /"ts":([0-9.]+)/);
		return m ? int(+m[1]) : null;
	}
	return iso(line);
}

// The lines to keep: from the first one not older than `cutoff`, then the
// newest that fit in `max` bytes; null when nothing changes. A line without
// a time goes by the one before it; lines before the first with a time go
// by that one; a log with no times at all is not cut by age.
function keep(text, cutoff, max) {
	let lines = split(text, '\n');
	if (length(lines) && lines[length(lines) - 1] == '')
		pop(lines);
	let times = map(lines, time_of), first = null, cur = null;
	for (let i = 0; i < length(times); i++) {
		if (times[i] != null) {
			cur = times[i];
			if (first == null)
				first = cur;
		}
		else
			times[i] = cur;
	}
	let from = 0;
	if (first != null) {
		from = length(lines);
		for (let i = 0; i < length(times); i++)
			if ((times[i] ?? first) >= cutoff) {
				from = i;
				break;
			}
	}
	let kept = slice(lines, from);
	let size = 0, start = length(kept);
	for (let i = length(kept) - 1; i >= 0; i--) {
		size += length(kept[i]) + 1;
		if (size > max)
			break;
		start = i;
	}
	kept = slice(kept, start);
	if (length(kept) == length(lines))
		return null;
	return length(kept) ? join('\n', kept) + '\n' : '';
}

function cmd_prune() {
	const now = getenv('LOGS_NOW') ? +getenv('LOGS_NOW') : time();
	const cutoff = now - days() * DAY;
	const files = getenv('LOGS_FILES') ? map(split(getenv('LOGS_FILES'), ' '), p => [ p, +(getenv('LOGS_MAX') ?? 262144) ])
		: map(LOGS, f => (f[0] == '/tmp/mosdns-x.log') ? [ f[0], mosdns_max() ] : f);
	let out = {};
	for (let f in files) {
		if (fs.lstat(f[0])?.type != 'file')
			continue;
		const text = fs.readfile(f[0]);
		if (text == null)
			continue;
		const k = keep(text, cutoff, f[1]);
		if (k == null) {
			out[f[0]] = 'kept';
			continue;
		}
		// in place: whoever appends to it keeps writing to the same file
		const h = fs.open(f[0], 'w');
		if (!h) {
			out[f[0]] = `cannot rewrite: ${fs.error()}`;
			continue;
		}
		h.write(k);
		h.close();
		out[f[0]] = `${length(split(text, '\n')) - length(split(k, '\n'))} lines dropped`;
	}
	print({ ok: true, days: days(), files: out }, '\n');
	return 0;
}

switch (ARGV[0]) {
case 'prune': exit(cmd_prune());
default:
	warn('usage: logs.uc prune\n');
	exit(2);
}
