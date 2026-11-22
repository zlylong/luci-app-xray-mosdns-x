#!/usr/bin/ucode
// luci-app-xray-mosdns-x - DNS query and block counts, by day, 30 days
//
//   stats.uc sample   add what mosdns-x counted since the last sample to today
//   stats.uc flush    sample, then keep the counts on flash
//   stats.uc show     sample, then the last 30 days as JSON (the DNS page)
//
// mosdns-x counts every query (metrics_all, first in its main sequence) and
// every blocked one (metrics_block, first in each block branch), from its
// own start; it serves the counters on 127.0.0.1 (api.http, /metrics). Its
// counters start again from 0 when it restarts: a new process start time
// says so, and what it counted since then is all new. The DNS watchdog
// samples every 10 minutes and flushes every hour; the start script samples
// before a new configuration replaces mosdns, and flushes at stop. The
// counts live in RAM; on flash they are at most an hour old.
'use strict';

import * as fs from 'fs';
import * as socket from 'socket';

const RUNTIME = '/var/etc/xray-mosdns/runtime.env';
// the environment: only for the tests
const RAM = getenv('STATS_RAM') || '/var/run/xray-mosdns-stats.json';
const DISK = getenv('STATS_DISK') || '/etc/xray-mosdns/stats.json';
const LOCK = getenv('STATS_LOCK') || '/var/run/xray-mosdns-stats.lock';
const DAYS = 30;

function now() {
	const t = getenv('STATS_NOW');
	return (t && match(t, /^[0-9]+$/)) ? +t : time();
}

function day_of(t) {
	const l = localtime(t);
	return sprintf('%04d-%02d-%02d', l.year, l.mon, l.mday);
}

function load(path) {
	try {
		const d = json(fs.readfile(path) ?? 'null');
		return (type(d?.days) == 'object') ? d : null;
	}
	catch (e) {
		return null;
	}
}

function save(path, d) {
	const tmp = `${path}.tmp`;
	fs.mkdir(fs.dirname(path));
	if (fs.writefile(tmp, sprintf('%J', d)) == null)
		return false;
	return fs.rename(tmp, path);
}

function port() {
	for (let l in split(fs.readfile(RUNTIME) ?? '', '\n')) {
		const m = match(l, /^STATS_PORT=([0-9]+)$/);
		if (m)
			return m[1];
	}
	return null;
}

// the body of a GET from 127.0.0.1:<port>, or null; 3 seconds at most
function http_get(p, path) {
	const s = socket.connect('127.0.0.1', p, { socktype: socket.SOCK_STREAM }, 3000);
	if (!s)
		return null;
	let buf = '';
	if (s.send(`GET ${path} HTTP/1.0\r\nHost: 127.0.0.1\r\n\r\n`) != null) {
		const end = time() + 3;
		while (time() <= end) {
			const r = socket.poll(1000, [ s, socket.POLLIN ]);
			if (!length(r) || !(r[0][1] & socket.POLLIN))
				continue;
			const chunk = s.recv(65536);
			if (chunk == null || !length(chunk))
				break;		// the server closes after the answer (HTTP/1.0)
			buf += chunk;
		}
	}
	s.close();
	const i = index(buf, '\r\n\r\n');
	return (i > 0 && match(buf, /^HTTP\/1\.[01] 200 /)) ? substr(buf, i + 4) : null;
}

// { all, block, start } from mosdns-x's /metrics, or null (not running, an
// older configuration without the counters)
function counters() {
	let text = null;
	const f = getenv('STATS_METRICS');
	if (f)
		text = fs.readfile(f);
	else {
		const p = port();
		if (!p)
			return null;
		text = http_get(+p, '/metrics');
	}
	let c = {};
	for (let l in split(text ?? '', '\n')) {
		let m = match(l, /^mosdns_plugin_metrics_(all|block)_query_total ([0-9.e+]+)$/);
		if (m)
			c[m[1]] = int(+m[2]);
		else if ((m = match(l, /^process_start_time_seconds ([0-9.e+]+)$/)))
			c.start = int(+m[1]);
	}
	return (c.all != null && c.block != null) ? c : null;
}

// the counts as they are: RAM, else flash (after a reboot), else new
function current() {
	return load(RAM) ?? load(DISK) ?? { days: {}, last: null, since: null };
}

// 30 days kept; "since" is the first of them that has counts
function prune(d, t) {
	const oldest = day_of(t - (DAYS - 1) * 86400);
	for (let k in keys(d.days))
		if (k < oldest)
			delete d.days[k];
	const ks = sort(keys(d.days));
	if (length(ks) && (!d.since || d.since < ks[0]))
		d.since = ks[0];
}

function sample(d) {
	const c = counters();
	if (!c)
		return false;
	const t = now(), day = day_of(t);
	const last = d.last;
	// the same process as at the last sample: what is new is the difference;
	// a new one (or none known): everything it counted is new
	const same = last && last.start == c.start && c.all >= last.all && c.block >= last.block;
	const add_all = same ? c.all - last.all : c.all;
	const add_block = same ? c.block - last.block : c.block;
	const td = d.days[day] ?? [ 0, 0 ];
	d.days[day] = [ td[0] + add_all, td[1] + add_block ];
	d.last = c;
	if (!d.since)
		d.since = day;
	d.sampled = t;
	prune(d, t);
	return true;
}

function locked(fn) {
	const l = fs.open(LOCK, 'w');
	l?.lock('x');
	const r = fn();
	l?.lock('u');
	l?.close();
	return r;
}

function cmd_sample() {
	return locked(() => {
		let d = current();
		const ok = sample(d);
		save(RAM, d);
		return ok ? 0 : 1;
	});
}

function cmd_flush() {
	return locked(() => {
		let d = current();
		sample(d);
		save(RAM, d);
		d.saved = now();
		return save(DISK, d) ? 0 : 1;
	});
}

function cmd_show() {
	let running = false;
	const d = locked(() => {
		let d = current();
		running = sample(d);
		save(RAM, d);
		return d;
	});
	const t = now();
	let days = [], total = [ 0, 0 ];
	for (let i = 0; i < DAYS; i++) {
		const day = day_of(t - i * 86400);
		const v = d.days[day];
		if (v) {
			push(days, { day, queries: v[0], blocked: v[1] });
			total[0] += v[0];
			total[1] += v[1];
		}
	}
	const today = d.days[day_of(t)] ?? [ 0, 0 ];
	print({ ok: true, running, since: d.since, sampled: d.sampled ?? null,
		total: { queries: total[0], blocked: total[1] },
		today: { queries: today[0], blocked: today[1] }, days }, '\n');
	return 0;
}

switch (ARGV[0]) {
case 'sample': exit(cmd_sample());
case 'flush':  exit(cmd_flush());
case 'show':   exit(cmd_show());
default:
	warn('usage: stats.uc sample | flush | show\n');
	exit(2);
}
