#!/usr/bin/ucode
// luci-app-xray-mosdns-x - blocklist subscriptions
//
//   adlist.uc update            download and convert every enabled list
//   adlist.uc start             the same, detached (the web UI cannot wait)
//   adlist.uc ensure            start an update if an enabled list has no data yet
//   adlist.uc status            what is installed, as JSON
//   adlist.uc catalog           the AdGuard blocklist catalogue, as JSON
//   adlist.uc catalog-sync      refresh the catalogue and bring subscriptions in line with it
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

function state_path(cfg) {
	return `${cfg.dir}/state.json`;
}

// ---------------------------------------------------------------- catalogue
function current_catalog() {
	return load(CATALOG, null) ?? load(SHIPPED, null);
}

function cmd_catalog() {
	const cat = current_catalog();
	if (!cat)
		return out({ ok: false, error: 'catalogue not found' });
	cat.ok = true;
	out(cat);
}

// download AdGuard's registry and keep the fields we use; null when that fails
function refresh_catalog() {
	const tmp = '/tmp/xray-mosdns-adlist-catalog.json';
	if (!download(REGISTRY, tmp))
		return null;
	const d = load(tmp, null);
	fs.unlink(tmp);
	if (type(d?.filters) != 'array' || type(d?.groups) != 'array' || !length(d.filters))
		return null;
	let cat = { source: REGISTRY, updated: time(), groups: [], filters: [] };
	for (let grp in sort(d.groups, (a, b) => a.displayNumber - b.displayNumber))
		push(cat.groups, { id: grp.groupId, name: grp.groupName });
	for (let f in d.filters) {
		if (!match(f.downloadUrl ?? '', /^https:\/\//))
			continue;
		let e = {
			id: f.filterId, group: f.groupId, name: f.name,
			description: f.description, homepage: f.homepage, url: f.downloadUrl,
		};
		// deprecated lists stay in the catalogue so a subscription to one can be flagged
		if (f.deprecated)
			e.deprecated = true;
		push(cat.filters, e);
	}
	system([ 'mkdir', '-p', '/etc/xray-mosdns' ]);
	fs.writefile(CATALOG, sprintf('%J', cat));
	return cat;
}

// Bring subscriptions that came from the catalogue in line with it: name and
// address follow the catalogue entry with the same id. A list that is
// deprecated or gone is only flagged; removing it is the user's decision.
// Returns { changed, flags: { <section>: 'deprecated' | 'gone' } }.
function sync_catalog(cat) {
	let by_id = {}, by_url = {};
	for (let f in cat.filters) {
		by_id[`${f.id}`] = f;
		by_url[f.url] = f;
	}
	let res = { changed: 0, flags: {} };
	let edits = [];
	uci.foreach(CONF, 'adlist', (s) => {
		let id = s.catalog_id;
		// subscribed before ids were recorded: adopt the entry with the same address
		if (id == null && s.url && by_url[s.url]) {
			id = `${by_url[s.url].id}`;
			push(edits, [ s['.name'], 'catalog_id', id ]);
		}
		if (id == null)
			return;		// a custom list
		const f = by_id[`${id}`];
		if (!f) {
			res.flags[s['.name']] = 'gone';
			return;
		}
		if (f.deprecated)
			res.flags[s['.name']] = 'deprecated';
		if (s.url != f.url)
			push(edits, [ s['.name'], 'url', f.url ]);
		if (s.name != f.name)
			push(edits, [ s['.name'], 'name', f.name ]);
	});
	for (let e in edits)
		uci.set(CONF, e[0], e[1], e[2]);
	if (length(edits)) {
		uci.commit(CONF);
		res.changed = length(edits);
	}
	return res;
}

// refresh the catalogue and re-sync; used by the page's button
function cmd_catalog_sync() {
	const cat = refresh_catalog();
	if (!cat) {
		out({ ok: false, error: 'could not download the catalogue' });
		return 1;
	}
	const res = sync_catalog(cat);
	const cfg = settings();
	let state = load(state_path(cfg), null);
	if (state?.lists) {
		for (let id in keys(state.lists))
			state.lists[id].catalog = res.flags[id] ?? null;
		fs.writefile(state_path(cfg), sprintf('%J', state));
	}
	out({ ok: true, filters: length(filter(cat.filters, f => !f.deprecated)), changed: res.changed, flags: res.flags });
	return 0;
}

// ---------------------------------------------------------------- update

// block.txt / allow.txt are what mosdns loads; they are replaced in one
// rename so a reload never sees half a file. Both are written in full
// first: when either cannot be (a full flash cuts it short), both stay as
// they were and the reason is returned.
function merge(cfg, all) {
	const kinds = [ 'block', 'allow' ];
	const tmp = (kind) => `${cfg.dir}/.${kind}.tmp`;
	let err = null;
	for (let kind in kinds) {
		const files = map(filter(all, l => fs.access(`${cfg.dir}/${l.id}.${kind}`)), l => `${cfg.dir}/${l.id}.${kind}`);
		let want = 0;
		for (let f in files)
			want += fs.stat(f)?.size ?? 0;
		// the braces take the shell's own message too (a target it cannot create)
		const rc = system(`{ ${length(files) ? 'cat ' + join(' ', map(files, f => `'${f}'`)) : ':'} > '${tmp(kind)}'; } 2>/dev/null`);
		if (rc != 0 || fs.stat(tmp(kind))?.type != 'file' || fs.stat(tmp(kind)).size != want) {
			err = `cannot write ${cfg.dir}/${kind}.txt (is the disk full?)`;
			break;
		}
	}
	for (let kind in kinds) {
		if (!err && !fs.rename(tmp(kind), `${cfg.dir}/${kind}.txt`))
			err = `cannot replace ${cfg.dir}/${kind}.txt: ${fs.error()}`;
		// a directory in the way is not ours to remove
		if (fs.stat(tmp(kind))?.type == 'file')
			fs.unlink(tmp(kind));
	}
	return err;
}

function cmd_update() {
	if (running()) {
		out({ ok: false, error: 'an update is already running' });
		return 1;
	}
	fs.writefile(LOCK, fs.readlink('/proc/self') ?? '0');
	const cfg = settings();
	system([ 'mkdir', '-p', cfg.dir ]);

	// follow the catalogue first, so a moved list is fetched from its new address;
	// when the registry cannot be reached the last known catalogue is used
	const cat = refresh_catalog() ?? current_catalog();
	const synced = cat ? sync_catalog(cat) : { changed: 0, flags: {} };

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
		entry.catalog = synced.flags[l.id] ?? null;
		lists_state[l.id] = entry;
	}

	// data of lists that are no longer subscribed. A directory of our own
	// holds nothing else; one set in the options may be shared with other
	// programs, so there only the lists this file wrote go, by name.
	const keep = map(all, l => l.id);
	let gone = keys(state.lists ?? {});
	if (index(cfg.dir, '/etc/xray-mosdns/') == 0)
		for (let f in (fs.lsdir(cfg.dir) ?? [])) {
			const m = match(f, /^([A-Za-z0-9_]+)\.(block|allow)$/);
			if (m)
				push(gone, m[1]);
		}
	for (let id in uniq(gone)) {
		if (!match(id, /^[A-Za-z0-9_]+$/) || (id in keep))
			continue;
		fs.unlink(`${cfg.dir}/${id}.block`);
		fs.unlink(`${cfg.dir}/${id}.allow`);
	}

	const merr = merge(cfg, all);
	let total = 0;
	for (let id in keys(lists_state))
		total += lists_state[id].rules ?? 0;
	// when the merged lists could not be written mosdns keeps the previous
	// ones: so does the total
	if (merr)
		total = state.total ?? 0;
	fs.writefile(state_path(cfg), sprintf('%J', { lists: lists_state, total, finished: time(), error: merr }));
	fs.unlink(LOCK);
	if (merr) {
		system([ 'logger', '-p', 'daemon.err', '-t', 'xray-mosdns', `blocklists: ${merr}; the previous lists stay in use` ]);
		out({ ok: false, error: merr, lists: length(all), total, failed });
		return 1;
	}
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
	out({ ok: true, running: !!running(), dir: cfg.dir, lists: state.lists ?? {}, total: state.total ?? 0, finished: state.finished ?? null,
		error: state.error ?? null });
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
case 'catalog-sync':   exit(cmd_catalog_sync()); break;
case 'cron-sync':      exit(cmd_cron_sync()); break;
case 'convert':
	// adlist.uc convert <in> <block-out> <allow-out>: used by the tests
	out(convert_file(ARGV[1], ARGV[2], ARGV[3]));
	break;
default:
	warn('usage: adlist.uc update | start | ensure | status | catalog | catalog-sync | cron-sync\n');
	exit(1);
}
