#!/usr/bin/ucode
// luci-app-xray-mosdns-x - recent log lines, by source
//
//   log.sh xray   [lines]   Xray's output, from the system log
//   log.sh mosdns [lines]   mosdns-x: its log file without the per-query
//                           lines, after its output in the system log if any
//   log.sh app    [lines]   the service itself: start and reload, config
//                           generation, firewall, DNS watchdog, group
//                           watcher, blocklist updates
//   log.sh [lines]          every system log line of the three
//
// In the system log, procd names a daemon's output after its binary
// ("xray[1234]: ...") and mentions an instance as "xray-mosdns::<instance>"
// in its own lines; the service's scripts log as xray-mosdns, the
// generator as xray-mosdns-gen. LOGREAD and MOSDNS_LOG in the environment
// replace the logread command and the mosdns log file.
//
// The name ends in .sh because the LuCI view and the rpcd ACL call it so.
'use strict';

import * as fs from 'fs';
import { cursor } from 'uci';

const SCAN = 5000;	// newest lines of the mosdns log looked at
const QUERY_KINDS = [ 'lan', 'block', 'direct', 'proxy', 'fallback' ];
const SAFE_PATH = /^[A-Za-z0-9_.\/-]+$/;

let logread = getenv('LOGREAD') || 'logread';
let mosdns_log = getenv('MOSDNS_LOG') || '/tmp/mosdns-x.log';
// both go into a shell command
if (!match(logread, SAFE_PATH))
	logread = 'logread';
if (!match(mosdns_log, SAFE_PATH))
	mosdns_log = '/tmp/mosdns-x.log';

let source = ARGV[0] ?? 'all', count = ARGV[1];
// older pages call `log.sh <lines>`
if (match(source, /^[0-9]+$/)) {
	count = source;
	source = 'all';
}
if (!(source in [ 'xray', 'mosdns', 'app', 'all' ])) {
	warn('usage: log.sh xray|mosdns|app [lines] | log.sh [lines]\n');
	exit(1);
}
count = +(count ?? 200);
if (type(count) != 'int' || count < 1 || count > 2000)
	count = 200;

function basename(path) {
	return match(path, /([^\/]*)$/)[1];
}

const uci = cursor();
let by_ident = {};
// procd names a daemon's lines after its binary: the ones in effect
// (runtime.env next to the running config) and the configured ones, which
// differ after a change that was not applied or did not take
let rt = {};
for (let l in split(fs.readfile('/var/etc/xray-mosdns/runtime.env') ?? '', '\n')) {
	const m = match(l, /^([A-Z_]+)='?([^']*)'?$/);
	if (m)
		rt[m[1]] = m[2];
}
// (another binary of the same kind, not the one in use, stays out)
function idents(kind, bins) {
	bins = filter(bins, b => b);
	for (let bin in (length(bins) ? bins : [ `/usr/bin/${kind}` ]))
		by_ident[basename(bin)] ??= kind;
}
idents('xray', [ rt.XRAY_BIN, uci.get_first('xray-mosdns', 'global', 'xray_bin') ]);
idents('mosdns', [ rt.MOSDNS_BIN, uci.get_first('xray-mosdns', 'dns', 'mosdns_bin') ]);
for (let id in [ 'xray-mosdns', 'xray-mosdns-gen', 'groups.uc', 'dns-watchdog.sh' ])
	by_ident[id] = 'app';
const by_instance = { xray: 'xray', mosdns: 'mosdns', dnswatch: 'app', groups: 'app' };

function lines_of(cmd) {
	const p = fs.popen(`${cmd} 2>/dev/null`, 'r');
	if (!p)
		return [];
	const text = p.read('all') ?? '';
	p.close();
	return filter(split(text, '\n'), l => length(l));
}

function last(list, n) {
	return slice(list, (length(list) > n) ? length(list) - n : 0);
}

// "Sat Nov 21 13:00:00 2026 daemon.err xray[1234]: message" -> source
function source_of(line) {
	const m = match(line, /^[^ ]+ +[^ ]+ +[^ ]+ +[^ ]+ +[^ ]+ +[^ ]+ +([^ :[]+)(\[[0-9]+\])?: (.*)$/);
	if (!m)
		return null;
	if (m[1] == 'procd') {
		const i = match(m[3], /xray-mosdns::([A-Za-z0-9_]+)/);
		return i ? by_instance[i[1]] : null;
	}
	return by_ident[m[1]];
}

function syslog(want) {
	return last(filter(lines_of(logread), l => {
		const s = source_of(l);
		return s && (want == 'all' || s == want);
	}), count);
}

function fmt_time(ts) {
	const t = localtime(int(ts));
	return sprintf('%04d-%02d-%02d %02d:%02d:%02d', t.year, t.mon, t.mday, t.hour, t.min, t.sec);
}

// With the query log on, mosdns writes JSON lines; they are made readable
// here, and the per-query ones left to the query log page.
function mosdns_line(line) {
	if (substr(line, 0, 1) != '{')
		return line;
	let e;
	try {
		e = json(line);
	}
	catch (err) {
		return line;
	}
	if (type(e) != 'object')
		return line;
	if ((e.msg in QUERY_KINDS) && e.qname != null)
		return null;
	let s = (type(e.ts) in [ 'int', 'double' ]) ? fmt_time(e.ts) : `${e.ts ?? '-'}`;
	s += ` ${uc(e.level ?? '')}`;
	if (e.logger)
		s += ` ${e.logger}`;
	s += `: ${e.msg ?? ''}`;
	for (let k in keys(e))
		if (!(k in [ 'ts', 'level', 'logger', 'msg', 'caller' ]))
			s += ` ${k}=${(type(e[k]) in [ 'object', 'array' ]) ? sprintf('%J', e[k]) : e[k]}`;
	return s;
}

function show(list) {
	if (length(list))
		print(join('\n', list), '\n');
}

if (source != 'mosdns') {
	show(syslog(source));
	exit(0);
}

const own = syslog('mosdns');
const file = fs.access(mosdns_log)
	? last(filter(map(lines_of(`tail -n ${SCAN} ${mosdns_log}`), mosdns_line), l => l != null), count)
	: [];
if (length(own)) {
	print('== 系统日志 ==\n');
	show(own);
	if (length(file))
		print(`== ${mosdns_log} ==\n`);
}
show(file);
