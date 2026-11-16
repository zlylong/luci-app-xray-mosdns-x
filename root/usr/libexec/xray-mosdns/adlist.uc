#!/usr/bin/ucode
// luci-app-xray-mosdns-x - blocklist subscriptions
//
//   adlist.uc update            download and convert every enabled list
//   adlist.uc start             the same, detached (the web UI cannot wait)
//   adlist.uc ensure            start an update if an enabled list has no data yet
//   adlist.uc status            what is installed, as JSON
//   adlist.uc catalog           the AdGuard blocklist catalogue, as JSON
//   adlist.uc catalog-update    refresh the catalogue from AdGuard's registry
//   adlist.uc cron-sync         make the daily update job match the settings
//
// Lists are in the syntax AdGuard Home reads. Only what a DNS server that
// matches names can honour is kept; every list becomes a mosdns domain file:
//   ||example.org^      -> domain:example.org   (the name and its subdomains)
//   0.0.0.0 example.org -> full:example.org     (hosts line: that name only)
//   example.org         -> full:example.org     (plain name: that name only)
//   @@||example.org^    -> an exception, kept in the allow file
// Rules with wildcards, regular expressions or modifiers other than
// $important are counted as skipped.
'use strict';

import * as fs from 'fs';
import { cursor } from 'uci';

const CONF = 'xray-mosdns';
const SHIPPED = '/usr/share/xray-mosdns/adlist-catalog.json';
const CATALOG = '/etc/xray-mosdns/adlist-catalog.json';
const REGISTRY = 'https://adguardteam.github.io/HostlistsRegistry/assets/filters.json';
const LOCK = '/var/run/xray-mosdns-adlist.pid';
const LOG = '/tmp/xray-mosdns-adlist.log';
const SELF = '/usr/libexec/xray-mosdns/adlist.uc';
const CRON = '/etc/crontabs/root';
const CRON_TAG = '# xray-mosdns-adlist';

const uci = cursor();

function out(obj) {
	print(obj, '\n');
}

function load(path, dflt) {
	try {
		return json(fs.readfile(path)) ?? dflt;
	}
	catch (e) {
		return dflt;
	}
}

function settings() {
	let dir = uci.get_first(CONF, 'adblock', 'dir') ?? '/etc/xray-mosdns/adlists';
	if (!match(dir, /^\/[A-Za-z0-9_.\/-]+$/) || index(dir, '..') >= 0)
		dir = '/etc/xray-mosdns/adlists';
	let hour = uci.get_first(CONF, 'adblock', 'update_hour') ?? '5';
	if (!match(hour, /^[0-9]{1,2}$/) || +hour > 23)
		hour = '5';
	return {
		dir: rtrim(dir, '/'),
		auto: (uci.get_first(CONF, 'adblock', 'auto_update') ?? '1') == '1',
		hour,
	};
}

function lists() {
	let res = [];
	uci.foreach(CONF, 'adlist', (s) => {
		if (s.enabled == '0' || !s.url)
			return;
		// no class escapes inside brackets: POSIX reads [^\s] as "not a backslash, not an s"
		if (!match(s['.name'], /^[A-Za-z0-9_]+$/) || !match(s.url, /^https?:\/\/[^[:space:]'"]+$/) || index(s.url, '\\') >= 0)
			return;
		push(res, { id: s['.name'], name: s.name ?? s['.name'], url: s.url });
	});
	return res;
}

function running() {
	const pid = trim(fs.readfile(LOCK) ?? '');
	return match(pid, /^[0-9]+$/) && fs.access(`/proc/${pid}`);
}

// ---------------------------------------------------------------- download
function xray_socks() {
	const port = uci.get_first(CONF, 'global', 'socks_port') ?? '1070';
	if (!match(port, /^[0-9]+$/))
		return null;
	// only when something is listening there
	return (system(`netstat -ltn 2>/dev/null | grep -q '127.0.0.1:${port} '`) == 0) ? port : null;
}

// through the proxy first when it is up (the registry is on GitHub Pages), then direct.
// curl is preferred because it can use the SOCKS inbound; without it the
// download falls back to uclient-fetch / wget, which every OpenWrt has, direct only.
function download(url, dest) {
	if (system('command -v curl >/dev/null 2>&1') == 0) {
		const base = `curl -fsSL --connect-timeout 15 --max-time 300 --max-filesize 67108864 -o '${dest}' '${url}'`;
		const port = xray_socks();
		if (port && system(`${base} -x socks5h://127.0.0.1:${port} 2>/dev/null`) == 0)
			return true;
		return system(`${base} 2>/dev/null`) == 0;
	}
	for (let tool in [ 'uclient-fetch', 'wget' ]) {
		if (system(`command -v ${tool} >/dev/null 2>&1`) != 0)
			continue;
		fs.unlink(dest);
		return system(`${tool} -q -T 300 -O '${dest}' '${url}' 2>/dev/null`) == 0;
	}
	return false;
}

// ---------------------------------------------------------------- convert
const RE_NAME = /^[a-z0-9_]([a-z0-9_-]*[a-z0-9_])?(\.[a-z0-9_]([a-z0-9_-]*[a-z0-9_])?)+$/;
const RE_HOSTS = /^(0\.0\.0\.0|127\.0\.0\.1|::1?|::ffff:0\.0\.0\.0)[ \t]+(.+)$/;
const LOCAL_NAMES = [ 'localhost', 'localhost.localdomain', 'local', 'broadcasthost', 'ip6-localhost', 'ip6-loopback' ];

// returns [ kind, rule ] with kind "block" | "allow", or null when the line is not usable
function convert(line) {
	line = trim(line);
	if (!length(line))
		return false;
	const c = substr(line, 0, 1);
	if (c == '!' || c == '#' || c == '[')
		return false;

	let kind = 'block';
	if (substr(line, 0, 2) == '@@') {
		kind = 'allow';
		line = substr(line, 2);
	}

	let m = match(line, RE_HOSTS);
	if (m) {
		// a hosts line may carry several names and a trailing comment
		let res = [];
		for (let name in split(replace(m[2], /#.*$/, ''), /[ \t]+/)) {
			name = lc(name);
			if (match(name, RE_NAME) && !(name in LOCAL_NAMES))
				push(res, [ kind, `full:${name}` ]);
		}
		return length(res) ? res : null;
	}

	// modifiers: $important changes nothing for us, anything else changes the meaning
	const d = index(line, '$');
	if (d >= 0) {
		if (substr(line, d + 1) != 'important')
			return null;
		line = substr(line, 0, d);
	}

	if (substr(line, 0, 2) == '||') {
		let name = lc(substr(line, 2));
		name = replace(name, /\^$/, '');
		return match(name, RE_NAME) ? [ [ kind, `domain:${name}` ] ] : null;
	}
	if (substr(line, 0, 1) == '|') {
		let name = lc(replace(substr(line, 1), /\^?\|?$/, ''));
		return match(name, RE_NAME) ? [ [ kind, `full:${name}` ] ] : null;
	}

	// a plain name, possibly followed by a comment
	const name = lc(trim(replace(line, /[ \t]#.*$/, '')));
	return match(name, RE_NAME) ? [ [ kind, `full:${name}` ] ] : null;
}

function convert_file(src, block_path, allow_path) {
	const fin = fs.open(src, 'r');
	const fb = fs.open(block_path, 'w');
	const fa = fs.open(allow_path, 'w');
	if (!fin || !fb || !fa)
		return null;
	let st = { rules: 0, allow: 0, skipped: 0 };
	let line;
	while ((line = fin.read('line')) != null && length(line)) {
		const res = convert(line);
		if (res === false)
			continue;
		if (res == null) {
			st.skipped++;
			continue;
		}
		for (let r in res) {
			if (r[0] == 'block') {
				fb.write(r[1] + '\n');
				st.rules++;
			}
			else {
				fa.write(r[1] + '\n');
				st.allow++;
			}
		}
	}
	fin.close();
	fb.close();
	fa.close();
	return st;
}

// ---------------------------------------------------------------- update
function state_path(cfg) {
	return `${cfg.dir}/state.json`;
}

// block.txt / allow.txt are what mosdns loads; they are replaced in one
// rename so a reload never sees half a file
function merge(cfg, all) {
	for (let kind in [ 'block', 'allow' ]) {
		const parts = join(' ', map(filter(all, l => fs.access(`${cfg.dir}/${l.id}.${kind}`)), l => `'${cfg.dir}/${l.id}.${kind}'`));
		const tmp = `${cfg.dir}/.${kind}.tmp`;
		system(length(parts) ? `cat ${parts} > '${tmp}'` : `: > '${tmp}'`);
		fs.rename(tmp, `${cfg.dir}/${kind}.txt`);
	}
}

function cmd_update() {
	if (running()) {
		out({ ok: false, error: 'an update is already running' });
		return 1;
	}
	fs.writefile(LOCK, fs.readlink('/proc/self') ?? '0');
	const cfg = settings();
	system([ 'mkdir', '-p', cfg.dir ]);

	const all = lists();
	let state = load(state_path(cfg), {});
	let lists_state = {};
	let failed = 0;

	for (let l in all) {
		const raw = `${cfg.dir}/.${l.id}.raw`;
		let entry = state.lists?.[l.id] ?? {};
		entry.name = l.name;
		if (download(l.url, raw)) {
			const st = convert_file(raw, `${cfg.dir}/.${l.id}.block.tmp`, `${cfg.dir}/.${l.id}.allow.tmp`);
			if (st && (st.rules + st.allow) > 0) {
				fs.rename(`${cfg.dir}/.${l.id}.block.tmp`, `${cfg.dir}/${l.id}.block`);
				fs.rename(`${cfg.dir}/.${l.id}.allow.tmp`, `${cfg.dir}/${l.id}.allow`);
				entry = { name: l.name, rules: st.rules, allow: st.allow, skipped: st.skipped, updated: time(), error: null };
			}
			else {
				// an empty result is almost certainly an error page, keep the old data
				entry.error = 'no usable rules in the downloaded file';
				failed++;
			}
		}
		else {
			entry.error = 'download failed';
			failed++;
		}
		fs.unlink(raw);
		fs.unlink(`${cfg.dir}/.${l.id}.block.tmp`);
		fs.unlink(`${cfg.dir}/.${l.id}.allow.tmp`);
		lists_state[l.id] = entry;
	}

	// data of lists that are no longer subscribed
	const keep = map(all, l => l.id);
	for (let f in (fs.lsdir(cfg.dir) ?? [])) {
		const m = match(f, /^([A-Za-z0-9_]+)\.(block|allow)$/);
		if (m && !(m[1] in keep))
			fs.unlink(`${cfg.dir}/${f}`);
	}

	merge(cfg, all);
	let total = 0;
	for (let id in keys(lists_state))
		total += lists_state[id].rules ?? 0;
	fs.writefile(state_path(cfg), sprintf('%J', { lists: lists_state, total, finished: time() }));
	fs.unlink(LOCK);
	system([ 'logger', '-t', 'xray-mosdns', `blocklists updated: ${length(all)} lists, ${total} rules, ${failed} failed` ]);
	out({ ok: failed == 0, lists: length(all), total, failed });
	return failed ? 1 : 0;
}

function cmd_start() {
	if (running()) {
		out({ ok: true, running: true });
		return 0;
	}
	system(`( ucode ${SELF} update > ${LOG} 2>&1 & )`);
	out({ ok: true, running: true });
	return 0;
}

function cmd_ensure() {
	const cfg = settings();
	for (let l in lists())
		if (!fs.access(`${cfg.dir}/${l.id}.block`))
			return cmd_start();
	return 0;
}

function cmd_status() {
	const cfg = settings();
	const state = load(state_path(cfg), {});
	out({ ok: true, running: !!running(), dir: cfg.dir, lists: state.lists ?? {}, total: state.total ?? 0, finished: state.finished ?? null });
}

// ---------------------------------------------------------------- catalogue
function cmd_catalog() {
	const cat = load(CATALOG, null) ?? load(SHIPPED, null);
	if (!cat)
		return out({ ok: false, error: 'catalogue not found' });
	cat.ok = true;
	out(cat);
}

function cmd_catalog_update() {
	const tmp = '/tmp/xray-mosdns-adlist-catalog.json';
	if (!download(REGISTRY, tmp)) {
		out({ ok: false, error: 'download failed' });
		return 1;
	}
	const d = load(tmp, null);
	fs.unlink(tmp);
	if (!d?.filters || !d?.groups) {
		out({ ok: false, error: 'unexpected catalogue format' });
		return 1;
	}
	let cat = { source: REGISTRY, groups: [], filters: [] };
	for (let grp in sort(d.groups, (a, b) => a.displayNumber - b.displayNumber))
		push(cat.groups, { id: grp.groupId, name: grp.groupName });
	for (let f in d.filters)
		if (!f.deprecated && match(f.downloadUrl ?? '', /^https:\/\//))
			push(cat.filters, {
				id: f.filterId, group: f.groupId, name: f.name,
				description: f.description, homepage: f.homepage, url: f.downloadUrl,
			});
	system([ 'mkdir', '-p', '/etc/xray-mosdns' ]);
	fs.writefile(CATALOG, sprintf('%J', cat));
	out({ ok: true, filters: length(cat.filters) });
	return 0;
}

// ---------------------------------------------------------------- cron
function cmd_cron_sync() {
	const cfg = settings();
	const want = (cfg.auto && length(lists()))
		? `17 ${cfg.hour} * * * ucode ${SELF} update >${LOG} 2>&1 ${CRON_TAG}`
		: null;
	const cur = split(fs.readfile(CRON) ?? '', '\n');
	const have = filter(cur, l => index(l, CRON_TAG) >= 0)[0] ?? null;
	if (have == want)
		return 0;
	let lines = filter(cur, l => index(l, CRON_TAG) < 0 && length(l));
	if (want)
		push(lines, want);
	system([ 'mkdir', '-p', '/etc/crontabs' ]);
	fs.writefile(CRON, join('\n', lines) + '\n');
	system('/etc/init.d/cron restart >/dev/null 2>&1');
	return 0;
}

switch (ARGV[0]) {
case 'update':         exit(cmd_update()); break;
case 'start':          exit(cmd_start()); break;
case 'ensure':         exit(cmd_ensure()); break;
case 'status':         cmd_status(); break;
case 'catalog':        cmd_catalog(); break;
case 'catalog-update': exit(cmd_catalog_update()); break;
case 'cron-sync':      exit(cmd_cron_sync()); break;
case 'convert':
	// adlist.uc convert <in> <block-out> <allow-out>: used by the tests
	out(convert_file(ARGV[1], ARGV[2], ARGV[3]));
	break;
default:
	warn('usage: adlist.uc update | start | ensure | status | catalog | catalog-update | cron-sync\n');
	exit(1);
}
