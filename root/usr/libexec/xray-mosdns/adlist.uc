#!/usr/bin/ucode
// luci-app-xray-mosdns-x - blocklist subscriptions
//
//   adlist.uc update            download and convert every enabled list
//   adlist.uc start             the same, detached (the web UI cannot wait)
//   adlist.uc ensure            start an update if an enabled list has no data yet
//   adlist.uc migrate           move what 0.9.7 kept at the top of a shared directory (start script)
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
// held (flock) by whoever writes the list directory: an update, a move, the
// merge at start. Never removed: a new file would be a second lock.
const LOCK = '/var/run/xray-mosdns-adlist.lock';
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

// The directory set in the options may be shared with other programs (a
// USB stick, say): there everything this file writes goes into its own
// subdirectory, xray-mosdns/. Under /etc/xray-mosdns the directory is ours
// as it is. config.uc points mosdns at the same place.
function settings() {
	let base = rtrim(uci.get_first(CONF, 'adblock', 'dir') ?? '', '/');
	if (!match(base, /^\/[A-Za-z0-9_.\/-]+$/) || index(base, '..') >= 0)
		base = '/etc/xray-mosdns/adlists';
	const own = (base == '/etc/xray-mosdns' || index(base, '/etc/xray-mosdns/') == 0);
	let hour = uci.get_first(CONF, 'adblock', 'update_hour') ?? '5';
	if (!match(hour, /^[0-9]{1,2}$/) || +hour > 23)
		hour = '5';
	return {
		dir: own ? base : `${base}/xray-mosdns`,
		base, own,
		auto: (uci.get_first(CONF, 'adblock', 'auto_update') ?? '1') == '1',
		hour,
	};
}

// Up to 0.9.7 the lists of a directory set in the options were kept at its
// top. The start script has them moved into the subdirectory (adlist.uc
// migrate) once a configuration that reads them there is in place, and
// never before: a start that falls back to the previous configuration
// leaves that one reading the top. By name: what the state file there
// (ours if it has the lists we wrote) and UCI name, nothing else. A file
// the subdirectory already has (an update ran since) is newer, and the one
// at the top just goes. The state file goes last, and only once every
// other file has: a migration that did not finish is done again at the
// next start. Returns the names that could not be moved.
function migrate(cfg) {
	if (cfg.own)
		return [];
	const st = load(`${cfg.base}/state.json`, null);
	if (type(st?.lists) != 'object')
		return [];
	let ids = keys(st.lists);
	uci.foreach(CONF, 'adlist', (s) => push(ids, s['.name']));
	let names = [ 'block.txt', 'allow.txt', '.block.tmp', '.allow.tmp' ];
	for (let id in uniq(ids))
		if (match(id, /^[A-Za-z0-9_]+$/))
			push(names, `${id}.block`, `${id}.allow`, `.${id}.raw`, `.${id}.block.tmp`, `.${id}.allow.tmp`);
	push(names, 'state.json');
	if (system([ 'mkdir', '-p', cfg.dir ]) != 0 || fs.lstat(cfg.dir)?.type != 'directory') {
		system([ 'logger', '-p', 'daemon.err', '-t', 'xray-mosdns', `blocklists: cannot create ${cfg.dir}; the lists stay in ${cfg.base}` ]);
		return [ cfg.dir ];
	}
	let moved = 0, failed = [];
	for (let n in names) {
		const from = `${cfg.base}/${n}`, to = `${cfg.dir}/${n}`;
		if (fs.lstat(from)?.type != 'file')
			continue;
		if (n == 'state.json' && length(failed))
			break;
		if ((fs.lstat(to)?.type == 'file') ? fs.unlink(from) : fs.rename(from, to))
			moved++;
		else
			push(failed, n);
	}
	if (length(failed))
		system([ 'logger', '-p', 'daemon.err', '-t', 'xray-mosdns',
			`blocklists: cannot move ${join(' ', failed)} from ${cfg.base} into ${cfg.dir}; tried again at the next start` ]);
	else if (moved)
		system([ 'logger', '-t', 'xray-mosdns', `blocklists: moved from ${cfg.base} into ${cfg.dir}` ]);
	return failed;
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

// One writer of the list directory at a time: an exclusive flock on LOCK,
// taken without waiting, so that taking it and finding it free are one
// step. It goes with the process, one that crashed included.
// lock_busy: another process has it (an update running); else lock_error
// says why it could not be taken
let held = null, lock_error = null, lock_busy = false;
function lock() {
	if (held)
		return true;
	// /var/run is there once the system has booted; not necessarily before
	const dir = match(LOCK, /^(.*)\//)[1];
	if (!fs.access(dir))
		system([ 'mkdir', '-p', dir ]);
	const f = fs.open(LOCK, 'a');
	if (!f) {
		lock_error = `cannot open ${LOCK}: ${fs.error() ?? ('there is a ' + (fs.lstat(LOCK)?.type ?? 'nothing') + ' in its place')}`;
		lock_busy = false;
		return false;
	}
	if (!f.lock('xn')) {
		f.close();
		lock_error = 'an update is already running';
		lock_busy = true;
		return false;
	}
	held = f;
	return true;
}

// The lock, waiting up to secs seconds for another holder to let go: a
// catalogue sync or a move holds it for a moment, an update for its whole
// download (minutes), so still busy after a few seconds means an update.
function lock_wait(secs) {
	for (let i = 0; ; i++) {
		if (lock())
			return true;
		if (!lock_busy || i >= secs)
			return false;
		system([ 'sleep', '1' ]);
	}
}

function unlock() {
	if (held) {
		held.close();
		held = null;
	}
}

// whether another process holds it (an update running)
function running() {
	if (held)
		return false;
	const f = fs.open(LOCK, 'a');
	if (!f)
		return false;
	const free = f.lock('sn');
	f.close();
	return !free;
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
// The catalogue as the registry has it now, or null. Nothing is written
// here: an update and a catalogue sync may both download at once (each has
// a download file of its own), and the cache is only written with the list
// lock held (save_catalog). It is dated when the download started: of two
// downloads the one that started later has the newer content, whichever
// finished first.
function refresh_catalog() {
	const me = fs.readlink('/proc/self') ?? `${time()}`;
	const tmp = `/tmp/xray-mosdns-adlist-catalog.${me}.json`;
	const started = time();
	if (!download(REGISTRY, tmp)) {
		// curl may have written part of it
		fs.unlink(tmp);
		return null;
	}
	const d = load(tmp, null);
	fs.unlink(tmp);
	if (type(d?.filters) != 'array' || type(d?.groups) != 'array' || !length(d.filters))
		return null;
	let cat = { source: REGISTRY, updated: started, groups: [], filters: [] };
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
	return cat;
}

// With the list lock held: the newer of a downloaded catalogue and the
// cached one, which is what to use; the cache becomes the downloaded one
// only if that is newer (the same second keeps what is there), in one rename.
function save_catalog(cat) {
	const cached = load(CATALOG, null);
	if (type(cached?.filters) == 'array' && (cached.updated ?? 0) >= (cat.updated ?? 0))
		return cached;
	const tmp = `${CATALOG}.${fs.readlink('/proc/self') ?? time()}.tmp`;
	system([ 'mkdir', '-p', '/etc/xray-mosdns' ]);
	if (fs.writefile(tmp, sprintf('%J', cat)) == null || !fs.rename(tmp, CATALOG))
		fs.unlink(tmp);
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
// It rewrites subscriptions and the state an update writes too: not while
// one runs (the page says so and leaves it for later). The download comes
// first, without the lock, so that what waits for it (the start) waits
// for a moment at most.
function cmd_catalog_sync() {
	let cat = refresh_catalog();
	if (!cat) {
		out({ ok: false, error: 'could not download the catalogue' });
		return 1;
	}
	if (!lock_wait(5)) {
		out({ ok: false, busy: lock_busy, error: lock_busy ? 'a blocklist update is running' : lock_error });
		return 1;
	}
	// While this one downloaded, an update may have fetched the catalogue
	// too, started later, and brought the subscriptions in line with it:
	// then that one is used, and the subscriptions are read again as they
	// are now.
	cat = save_catalog(cat);
	uci.unload(CONF);
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

// A file's content written to another file (made, or rewritten in place:
// the same file afterwards), checked by its size. Paths are checked ones.
function copy_file(from, to) {
	return system(`cat '${from}' > '${to}' 2>/dev/null`) == 0 && fs.lstat(to)?.type == 'file'
		&& fs.lstat(to).size == fs.lstat(from)?.size;
}

// block.txt / allow.txt are what mosdns loads. Both are written in full
// first, beside them: when either cannot be (a full flash cuts it short),
// both stay as they were and the reason is returned. Then each is
// rewritten in place, never replaced by another file: mosdns-x watches the
// file it opened, and one renamed over it is reloaded once, after which no
// later update is noticed until mosdns restarts. Its reload waits for a
// second without writes, so it reads a list whole. Copies of the lists in
// use are kept until both are rewritten, and one that cannot be rewritten
// puts them back: mosdns does not get a new block list with an old
// exception list, or the reverse. Where there is no room for the copies the
// lists are rewritten without them: an update that cannot finish then
// leaves them mixed until the next one, which beats never updating.
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
	const live = (kind) => `${cfg.dir}/${kind}.txt`;
	const prev = (kind) => `${cfg.dir}/.${kind}.prev`;
	// something other than a file where a list or its copy goes: not ours
	// to remove, nothing is rewritten
	for (let kind in kinds) {
		if (err)
			break;
		const t = fs.lstat(live(kind))?.type, p = fs.lstat(prev(kind))?.type;
		if (t != null && t != 'file')
			err = `cannot replace ${live(kind)}: not a file`;
		else if (p != null && p != 'file')
			err = `cannot keep ${live(kind)} while replacing it: ${prev(kind)} is in the way`;
		else if (p != null && !fs.unlink(prev(kind)))
			err = `cannot keep ${live(kind)} while replacing it: ${fs.error()}`;
	}
	let copies = !err;
	for (let kind in kinds)
		if (copies && fs.access(live(kind)) && !copy_file(live(kind), prev(kind)))
			copies = false;
	let written = [], keep = {};
	for (let kind in kinds) {
		if (err)
			break;
		if (copy_file(tmp(kind), live(kind))) {
			push(written, kind);
			continue;
		}
		err = `cannot rewrite ${live(kind)} (is the disk full?)`;
		// this one may be cut short, the ones before it are new: back as they were
		for (let k in [ ...written, kind ]) {
			if (copies && fs.access(prev(k)) ? copy_file(prev(k), live(k)) : (k == kind && fs.writefile(live(k), '') != null))
				continue;
			keep[k] = true;
			err += `; ${live(k)} could not be put back as it was`;
		}
	}
	for (let kind in kinds) {
		// a directory in the way is not ours to remove
		if (fs.lstat(tmp(kind))?.type == 'file')
			fs.unlink(tmp(kind));
		if (!keep[kind] && fs.lstat(prev(kind))?.type == 'file')
			fs.unlink(prev(kind));
	}
	return err;
}

function cmd_update() {
	if (!lock()) {
		out({ ok: false, error: lock_error });
		return 1;
	}
	const cfg = settings();
	system([ 'mkdir', '-p', cfg.dir ]);

	// follow the catalogue first, so a moved list is fetched from its new address;
	// when the registry cannot be reached the last known catalogue is used
	let cat = refresh_catalog();
	cat = cat ? save_catalog(cat) : current_catalog();
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

	// data of lists that are no longer subscribed: the directory is ours
	// alone (a shared one has its own subdirectory for us)
	const keep = map(all, l => l.id);
	for (let f in (fs.lsdir(cfg.dir) ?? [])) {
		const m = match(f, /^([A-Za-z0-9_]+)\.(block|allow)$/);
		if (m && !(m[1] in keep))
			fs.unlink(`${cfg.dir}/${f}`);
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
	unlock();
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

// Exit status: 0 nothing (left) to move, 1 some files could not be moved
// (their names on stderr), 2 not now: an update writes the same directory.
// Either way the state stays at the top and the next start tries again.
function cmd_migrate() {
	const cfg = settings();
	if (cfg.own || type(load(`${cfg.base}/state.json`, null)?.lists) != 'object') {
		out({ ok: true, failed: [] });
		return 0;
	}
	// and no update starts while the files move; a short holder (a
	// catalogue sync) is waited for
	if (!lock_wait(5)) {
		system([ 'logger', '-t', 'xray-mosdns',
			`blocklists: ${lock_error}; moving the lists from ${cfg.base} into ${cfg.dir} is left to the next start` ]);
		out({ ok: false, postponed: true });
		return 2;
	}
	const failed = migrate(cfg);
	unlock();
	if (length(failed))
		warn(join(' ', failed), '\n');
	out({ ok: !length(failed), failed });
	return length(failed) ? 1 : 0;
}

// At every start, before mosdns: it does not start at all when a list it
// reads is missing (the config has them as soon as a subscription is
// enabled, as config.uc counts them), and nothing would start it again
// once the list is there. Merged lists that are not what the lists there
// make (missing, empty or cut short, or from before a list was turned off:
// their size is the sum of the lists' sizes) are made again, which needs
// no download; a short holder of the lock is waited for. While an update
// runs, which writes them itself, empty ones stand in for missing ones
// (never over a file that is there) for it to rewrite. A subscribed list with no data yet is fetched in the
// background. Whatever goes wrong is printed on stderr (the start script
// puts it on the overview).
function cmd_ensure() {
	const cfg = settings();
	let wanted = 0;
	uci.foreach(CONF, 'adlist', (s) => { if (s.enabled != '0' && s.url) wanted++; });
	if (!wanted)
		return 0;
	const all = lists();
	const live = (kind) => `${cfg.dir}/${kind}.txt`;
	const size = (kind) => {
		let n = 0;
		for (let l in all)
			n += fs.stat(`${cfg.dir}/${l.id}.${kind}`)?.size ?? 0;
		return n;
	};
	// With a list's data missing (being fetched, a move that did not
	// finish) the lists there make less than the list in use has: that one
	// stays until the update below has the data. Missing, it is made from
	// what there is.
	// a list's data is both its files (an update always writes the two)
	const has_data = (l) => fs.access(`${cfg.dir}/${l.id}.block`) && fs.access(`${cfg.dir}/${l.id}.allow`);
	const complete = !length(filter(all, l => !has_data(l)));
	const stale = filter([ 'block', 'allow' ], k => fs.lstat(live(k))?.type != 'file'
		|| (complete && fs.lstat(live(k)).size != size(k)));
	if (length(stale)) {
		system([ 'mkdir', '-p', cfg.dir ]);
		let err = null;
		if (lock_wait(5)) {
			err = merge(cfg, all);
			unlock();
		}
		else {
			// an update running makes them itself; a lock that cannot be
			// taken at all is a fault, said as such
			if (!lock_busy)
				err = lock_error;
			for (let k in stale)
				if (fs.lstat(live(k)) == null)
					fs.open(live(k), 'wx')?.close();
		}
		if (err)
			warn(`cannot make the merged lists in ${cfg.dir}: ${err}\n`);
		else
			for (let k in stale)
				if (fs.lstat(live(k))?.type != 'file') {
					warn(`${live(k)} is missing and cannot be made\n`);
					break;
				}
	}
	for (let l in all)
		if (!has_data(l))
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
case 'migrate':        exit(cmd_migrate()); break;
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
