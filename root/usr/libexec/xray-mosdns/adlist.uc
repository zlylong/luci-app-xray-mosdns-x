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
//   ||example.org^|     -> as without the "|" (it says "the address ends
//                       here", which a name does anyway)
//   ||example.org^$badfilter -> takes the rule ||example.org^ out of this
//                       list again (lists compiled from several sources
//                       withdraw a source's rule that way)
//   ||example.org^$dnsrewrite=NXDOMAIN (or REFUSED, 0.0.0.0, ::, AdGuard's
//                       blocking host) -> blocked like the first form
//   ||ad*.example.org^, ||example.*^, .example.org^, ||example.
//                       -> a pattern ("*" anything; the name may go on where
//                       no "^" or "|" ends it): a regular expression, kept
//                       apart (see below)
// Regular expressions (/.../), patterns with anything but names in them
// and rules with other modifiers (a $dnsrewrite that answers with a record
// is a rewrite, not a block) are counted as skipped.
//
// A list's patterns go into two more files, <id>.wild (regexp: lines) and
// <id>.keys (keyword: lines, for each pattern a piece of text every name it
// matches contains), merged into wild.txt and keys.txt. mosdns tries a
// regular expression at a time, about 2 µs each for every query; the
// keywords cost a hundredth of that, and only a name that contains one is
// held against the expressions. Exceptions that are patterns sit in the
// allow file as they are: those are only looked at for a blocked name.
//
// A list's data files and state go by its UCI section's name. For an
// anonymous section ("cfg140306") that name is only its place in the file:
// a section added or removed before it gives every list the name of its
// neighbour. So the state records the address each list's data came from,
// and data from another address is not used: not merged, not counted as
// there. When a list's data is there under another name it is moved to the
// list's name (rekey(): at start and before an update), nothing is fetched;
// otherwise the list is fetched again. State written before addresses were
// recorded counts as another address (fetched again once).
//
// An update that fails for a list throws nothing away: what was there stays
// and stays merged as it was, whatever address it came from, until a
// download of the list's own address has been converted and put in place.
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
// which list a running update is at, for the page
const PROGRESS = '/var/run/xray-mosdns-adlist.progress';
const SELF = '/usr/libexec/xray-mosdns/adlist.uc';
// ADLIST_CRON: another crontab, for the tests (cron is left alone then)
const CRON = getenv('ADLIST_CRON') || '/etc/crontabs/root';
const CRON_TAG = '# xray-mosdns-adlist';

// a list's data files, and the two it cannot do without (lists converted
// before patterns were kept have no others)
const KINDS = [ 'block', 'allow', 'wild', 'keys' ];
const MAIN = [ 'block', 'allow' ];

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
		// --speed-*: a transfer that stalls (under 1 KB/s for 30 s) is given
		// up at once, not after the 5 minutes a whole list may take
		const base = `curl -fsSL --connect-timeout 15 --max-time 300 --speed-limit 1024 --speed-time 30 --max-filesize 67108864 -o '${dest}' '${url}'`;
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
// how a rule's name may end: never empty (replace() with a pattern that can
// match nothing gives the string twice)
const RE_END = /(\^\||\^|\|)$/;
const RE_HOSTS = /^(0\.0\.0\.0|127\.0\.0\.1|::1?|::ffff:0\.0\.0\.0)[ \t]+(.+)$/;
const LOCAL_NAMES = [ 'localhost', 'localhost.localdomain', 'local', 'broadcasthost', 'ip6-localhost', 'ip6-loopback' ];
// $dnsrewrite values that mean "blocked" (lower case): an error answer or an
// empty one (RCODE;; is the long form), a null address, or a name of
// AdGuard's that answers with its block page
const BLOCKING_REWRITES = [ 'nxdomain', 'nxdomain;;', 'refused', 'refused;;', 'noerror;;',
	'0.0.0.0', '::', '127.0.0.1', '::1',
	'ad-block.dns.adguard.com', 'family-block.dns.adguard.com', 'standard-block.dns.adguard.com' ];

// A rule that is a pattern and not a name, as [ [ kind, "regexp:...",
// "keyword:..." ] ], or null. "||" stands for the start of the name or of a
// label, "|" for the very start, "^" and "|" at the end for the end; "*" is
// anything. Without a start (or an end) the name may begin (or go on)
// anywhere. Only names' characters besides: the expression is made of
// those, "\.", ".*" and the anchors, so mosdns can always compile it (one
// it cannot stops it from starting). The keyword is a piece between the
// "*" (which one: below); an ending like ".com" only when it is all there
// is to the pattern. A pattern that names less than two letters or digits
// is not used.
const RE_BODY = /^[a-z0-9_.*-]+$/;
function pattern(kind, line) {
	let s = lc(line), start = '', end = '';
	if (substr(s, 0, 2) == '||') {
		start = '(^|\\.)';
		s = substr(s, 2);
	}
	else if (substr(s, 0, 1) == '|') {
		start = '^';
		s = substr(s, 1);
	}
	const e = match(s, RE_END);
	if (e) {
		end = '$';
		s = substr(s, 0, length(s) - length(e[1]));
	}
	// a bare word is not written as a pattern
	if (!start && !end && index(s, '*') < 0)
		return null;
	if (!match(s, RE_BODY))
		return null;
	s = replace(s, /\*+/g, '*');
	// where the name may go on anyway, "anything" says nothing
	if (!end && substr(s, -1) == '*')
		s = substr(s, 0, length(s) - 1);
	if (!start && substr(s, 0, 1) == '*')
		s = substr(s, 1);
	const chunks = split(s, '*');
	// The keyword: a piece before the last one when it names five letters
	// or digits (the last piece of a pattern with an end is the zone, and
	// "amazonaws.com" is in a great many names, while "reachableads-av."
	// is in next to none); else the longest piece.
	const alnum = c => length(replace(c, /[^a-z0-9]/g, ''));
	let key = '', lead = '';
	for (let i = 0; i < length(chunks); i++) {
		const c = chunks[i], last = (end && length(chunks) > 1 && i == length(chunks) - 1);
		if (last && match(c, /^\.[a-z0-9-]+$/))
			continue;
		if (length(c) > length(key))
			key = c;
		if (!last && alnum(c) >= 5 && length(c) > length(lead))
			lead = c;
	}
	if (length(lead))
		key = lead;
	if (alnum(key) < 2)
		return null;
	const re = start + join('.*', map(chunks, c => replace(c, /\./g, '\\.'))) + end;
	return [ [ kind, `regexp:${re}`, `keyword:${key}` ] ];
}

// returns [ [ kind, rule ], ... ] with kind "block" | "allow", or "-block" |
// "-allow" for a $badfilter line (that rule is taken out of the list);
// false for a line that is no rule, null when the line is not usable
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

	// modifiers: $important changes nothing for us; a $dnsrewrite that
	// answers "no such name", refuses, points at a null address or at
	// AdGuard's blocking host is a block (AdGuard's DNS lists write their
	// blocks that way); $badfilter withdraws the rule it is written on;
	// anything else changes the meaning
	let bad = false;
	const d = index(line, '$');
	if (d >= 0) {
		for (let mod in split(substr(line, d + 1), ',')) {
			if (mod == 'important')
				continue;
			if (mod == 'badfilter') {
				bad = true;
				continue;
			}
			const rw = match(mod, /^dnsrewrite=(.*)$/);
			if (!rw || kind != 'block' || !(lc(rw[1]) in BLOCKING_REWRITES))
				return null;
		}
		line = substr(line, 0, d);
	}
	if (bad)
		kind = '-' + kind;

	if (substr(line, 0, 2) == '||') {
		let name = lc(substr(line, 2));
		name = replace(name, RE_END, '');
		return match(name, RE_NAME) ? [ [ kind, `domain:${name}` ] ] : pattern(kind, line);
	}
	if (substr(line, 0, 1) == '|') {
		let name = lc(replace(substr(line, 1), RE_END, ''));
		return match(name, RE_NAME) ? [ [ kind, `full:${name}` ] ] : pattern(kind, line);
	}

	// a plain name, possibly followed by a comment
	const name = lc(trim(replace(line, /[ \t]#.*$/, '')));
	return match(name, RE_NAME) ? [ [ kind, `full:${name}` ] ] : pattern(kind, line);
}

// wild_path, keys_path: where the block rules that are patterns go (see the top)
function convert_file(src, block_path, allow_path, wild_path, keys_path) {
	// The rules this list withdraws ($badfilter), looked for first: such a
	// line may stand before its rule or after it. By what the rule converts
	// to, so the same rule written with $important goes as well.
	let gone = {}, line;
	let fin = fs.open(src, 'r');
	if (!fin)
		return null;
	while ((line = fin.read('line')) != null && length(line)) {
		if (index(line, 'badfilter') < 0)
			continue;
		for (let r in (convert(line) || []))
			if (substr(r[0], 0, 1) == '-')
				gone[`${substr(r[0], 1)} ${r[1]}`] = true;
	}
	fin.close();

	fin = fs.open(src, 'r');
	const fb = fs.open(block_path, 'w');
	const fa = fs.open(allow_path, 'w');
	const fw = fs.open(wild_path, 'w');
	const fk = fs.open(keys_path, 'w');
	if (!fin || !fb || !fa || !fw || !fk)
		return null;
	let st = { rules: 0, allow: 0, skipped: 0 };
	while ((line = fin.read('line')) != null && length(line)) {
		const res = convert(line);
		if (res === false)
			continue;
		if (res == null) {
			st.skipped++;
			continue;
		}
		for (let r in res) {
			if (substr(r[0], 0, 1) == '-' || gone[`${r[0]} ${r[1]}`])
				continue;
			if (r[0] == 'block' && r[2]) {
				fw.write(r[1] + '\n');
				fk.write(r[2] + '\n');
				st.rules++;
			}
			else if (r[0] == 'block') {
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
	fw.close();
	fk.close();
	return st;
}

function state_path(cfg) {
	return `${cfg.dir}/state.json`;
}

// a list's two files are there (as files: something else in the way is
// not data that can be merged)
function has_files(cfg, l) {
	return fs.lstat(`${cfg.dir}/${l.id}.block`)?.type == 'file' && fs.lstat(`${cfg.dir}/${l.id}.allow`)?.type == 'file';
}

// a list's data is there, and is from its address (see the top)
function has_data(cfg, state, l) {
	return state?.lists?.[l.id]?.url == l.url && has_files(cfg, l);
}

// Lists whose data is there under another name (see the top: a section
// added or removed before the lists renames them all): each list's two
// files and its state go to its name, by the address they came from.
// Nothing is fetched and the merged lists stay what they are (the same
// data). All of them are taken out first and put in place after, so lists
// that changed places do not overwrite each other. Only with the lock held.
// Returns the state to go on with (written when something moved).
function rekey(cfg, all, state) {
	const sl = state?.lists;
	if (type(sl) != 'object')
		return state;
	const kinds = KINDS;
	const cur = (id, k) => `${cfg.dir}/${id}.${k}`;
	const tmp = (id, k) => `${cfg.dir}/.${id}.${k}.rekey`;
	// left by a run that was cut short: no telling whose it is any more
	for (let f in (fs.lsdir(cfg.dir) ?? []))
		if (match(f, /^\.[A-Za-z0-9_]+\.(block|allow|wild|keys)\.rekey$/))
			fs.unlink(`${cfg.dir}/${f}`);

	let url_of = {};
	for (let l in all)
		url_of[l.id] = l.url;
	let moves = [], taken = {};
	for (let l in all) {
		if (sl[l.id]?.url == l.url && has_files(cfg, l))
			continue;	// its own data is there
		// where it goes must be free, or files
		if (length(filter(kinds, k => (fs.lstat(cur(l.id, k))?.type ?? 'file') != 'file')))
			continue;
		for (let id, e in sl) {
			if (id == l.id || taken[id] || e?.url != l.url || !match(id, /^[A-Za-z0-9_]+$/))
				continue;
			// the section of that name has this address too (twice the same list): its own
			if (url_of[id] == e.url || !has_files(cfg, { id }))
				continue;
			taken[id] = true;
			push(moves, { from: id, to: l.id, entry: e, name: l.name });
			break;
		}
	}
	if (!length(moves))
		return state;

	// out, all of them; any that cannot be goes back, nothing changes
	let out_ok = true;
	for (let m in moves)
		for (let k in kinds) {
			// a list converted before patterns were kept has only the two
			if (!(k in MAIN) && fs.lstat(cur(m.from, k)) == null)
				continue;
			if (out_ok && fs.rename(cur(m.from, k), tmp(m.to, k)))
				m[k] = true;
			else
				out_ok = false;
		}
	if (!out_ok) {
		for (let m in moves)
			for (let k in kinds)
				if (m[k])
					fs.rename(tmp(m.to, k), cur(m.from, k));
		return state;
	}
	// in place; what was under that name was another list's
	let lists_state = {}, moved = 0;
	for (let id, e in sl)
		if (!taken[id])
			lists_state[id] = e;
	for (let m in moves) {
		let ok = true;
		for (let k in kinds) {
			if (!m[k]) {
				// nothing of this kind came along: not the other list's either
				fs.unlink(cur(m.to, k));
				continue;
			}
			if (!fs.rename(tmp(m.to, k), cur(m.to, k))) {
				ok = false;
				fs.unlink(tmp(m.to, k));
			}
		}
		if (ok) {
			m.entry.name = m.name;
			lists_state[m.to] = m.entry;
			moved++;
		}
		else
			delete lists_state[m.to];	// half there: fetched again
	}
	state.lists = lists_state;
	fs.writefile(state_path(cfg), sprintf('%J', state));
	system([ 'logger', '-t', 'xray-mosdns', `blocklists: the data of ${moved} list(s) moved to their sections' new names (nothing fetched)` ]);
	return state;
}

// A list's data that replace_data() put aside and did not put back (the
// process was killed, the power went in between): back where it belongs.
// Only with the lock held, or an update in the middle of replacing would
// have its files moved under it.
function recover_aside(cfg, l) {
	for (let k in KINDS) {
		const cur = `${cfg.dir}/${l.id}.${k}`, old = `${cfg.dir}/.${l.id}.${k}.old`;
		if (fs.lstat(old)?.type == 'file' && fs.lstat(cur) == null && fs.rename(old, cur))
			system([ 'logger', '-t', 'xray-mosdns', `blocklists: ${cur} put back from ${old} (an update was cut short)` ]);
	}
}

// A list's new files (written beside them) in place of its old ones:
// all or none. The old ones go aside first and come back when a new one
// cannot be put in place. Returns null, or why not.
function replace_data(cfg, l) {
	const kinds = KINDS;
	const cur = (k) => `${cfg.dir}/${l.id}.${k}`;
	const tmp = (k) => `${cfg.dir}/.${l.id}.${k}.tmp`;
	const old = (k) => `${cfg.dir}/.${l.id}.${k}.old`;
	// what an earlier one cut short left aside is the data: back first
	recover_aside(cfg, l);
	for (let k in kinds) {
		const t = fs.lstat(cur(k))?.type;
		if (t != null && t != 'file')
			return `cannot replace ${cur(k)}: not a file`;
		// a copy left next to a file that is there is out of date
		if (fs.lstat(old(k)) != null && !fs.unlink(old(k)))
			return `cannot replace ${cur(k)}: ${old(k)} is in the way`;
	}
	let aside = [], placed = [], err = null;
	for (let k in kinds) {
		if (fs.lstat(cur(k)) == null)
			continue;
		if (!fs.rename(cur(k), old(k))) {
			err = `cannot replace ${cur(k)}: ${fs.error()}`;
			break;
		}
		push(aside, k);
	}
	for (let k in kinds) {
		if (err)
			break;
		if (!fs.rename(tmp(k), cur(k)))
			err = `cannot replace ${cur(k)}: ${fs.error()}`;
		else
			push(placed, k);
	}
	if (err) {
		// back as it was
		for (let k in placed)
			if (!(k in aside))
				fs.unlink(cur(k));
		for (let k in aside)
			if (!fs.rename(old(k), cur(k)))
				err += `; ${cur(k)} could not be put back (it is in ${old(k)})`;
		return err;
	}
	for (let k in aside)
		fs.unlink(old(k));
	return null;
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

// block.txt / allow.txt / wild.txt / keys.txt are what mosdns loads. All
// are written in full first, beside them: when one cannot be (a full flash
// cuts it short), all stay as they were and the reason is returned. Then each is
// rewritten in place, never replaced by another file: mosdns-x watches the
// file it opened, and one renamed over it is reloaded once, after which no
// later update is noticed until mosdns restarts. Its reload waits for a
// second without writes, so it reads a list whole. Copies of the lists in
// use are kept until both are rewritten, and one that cannot be rewritten
// puts them back: mosdns does not get a new block list with an old
// exception list, or the reverse. Where there is no room for the copies the
// lists are rewritten without them: an update that cannot finish then
// leaves them mixed until the next one, which beats never updating.
// `all` is the lists whose data may be used (has_data).
function merge(cfg, all) {
	const kinds = KINDS;
	const tmp = (kind) => `${cfg.dir}/.${kind}.tmp`;
	let err = null;
	for (let kind in kinds) {
		const files = map(filter(all, l => fs.lstat(`${cfg.dir}/${l.id}.${kind}`)?.type == 'file'), l => `${cfg.dir}/${l.id}.${kind}`);
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
	// data under another name (sections renamed) first to its list
	for (let l in all)
		recover_aside(cfg, l);
	state = rekey(cfg, all, state);
	let lists_state = {};
	let failed = 0;
	let at = 0;

	// lists whose update failed: their data (from another address) stays
	// merged as it was; `lost`: ones that had something there (merged into
	// the lists in use) and have nothing that can be merged now
	let kept = {}, lost = [];
	for (let l in all) {
		const raw = `${cfg.dir}/.${l.id}.raw`;
		const prev = state.lists?.[l.id] ?? {};
		fs.writefile(PROGRESS, sprintf('%J', { index: ++at, of: length(all), name: l.name }));
		recover_aside(cfg, l);
		const had = fs.lstat(`${cfg.dir}/${l.id}.block`) != null || fs.lstat(`${cfg.dir}/${l.id}.allow`) != null;
		// what is there under this name is this list's (see the top)
		const own = (prev.url == l.url);
		let entry = own ? prev : { name: l.name };
		entry.name = l.name;
		let err = null;
		if (!download(l.url, raw))
			err = 'download failed';
		else {
			const st = convert_file(raw, ...map(KINDS, k => `${cfg.dir}/.${l.id}.${k}.tmp`));
			if (!st || (st.rules + st.allow) == 0) {
				// an empty result is almost certainly an error page
				err = 'no usable rules in the downloaded file';
				entry.skipped = st?.skipped ?? null;
			}
			else if (!(err = replace_data(cfg, l)))
				entry = { name: l.name, url: l.url, rules: st.rules, allow: st.allow, skipped: st.skipped, updated: time(), error: null };
		}
		if (err) {
			// nothing thrown away; what went wrong, for this address
			entry.error = err;
			entry.tried = l.url;
			failed++;
			if (!has_files(cfg, l)) {
				if (had)
					push(lost, `${l.name}: ${err}`);
			}
			else if (!own)
				kept[l.id] = prev.rules ?? 0;
		}
		fs.unlink(raw);
		for (let k in KINDS)
			fs.unlink(`${cfg.dir}/.${l.id}.${k}.tmp`);
		entry.catalog = synced.flags[l.id] ?? null;
		lists_state[l.id] = entry;
	}

	// data of lists that are no longer subscribed: the directory is ours
	// alone (a shared one has its own subdirectory for us)
	const keep = map(all, l => l.id);
	for (let f in (fs.lsdir(cfg.dir) ?? [])) {
		const m = match(f, /^([A-Za-z0-9_]+)\.(block|allow|wild|keys)$/);
		if (m && !(m[1] in keep))
			fs.unlink(`${cfg.dir}/${f}`);
	}

	const usable = (l) => has_data(cfg, { lists: lists_state }, l) || (l.id in kept);
	// A list that failed with nothing to merge would be dropped from the
	// lists in use, its rules with it: those stay as they are then (the next
	// update that gets it merges everything). A new list that failed has no
	// rules in them to lose.
	let merr = null;
	if (length(lost) && length(filter([ 'block', 'allow' ], k => fs.lstat(`${cfg.dir}/${k}.txt`)?.type == 'file')) == 2)
		merr = `nothing to merge for ${join('; ', lost)}: the lists in use stay as they are`;
	else
		merr = merge(cfg, filter(all, usable));
	let total = 0;
	for (let l in all)
		if (has_data(cfg, { lists: lists_state }, l))
			total += lists_state[l.id].rules ?? 0;
		else if (l.id in kept)
			total += kept[l.id];
	// when the merged lists could not be written mosdns keeps the previous
	// ones: so does the total
	if (merr)
		total = state.total ?? 0;
	fs.writefile(state_path(cfg), sprintf('%J', { lists: lists_state, total, finished: time(), error: merr }));
	fs.unlink(PROGRESS);
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
	// data an update that was cut short left aside, back first (not while
	// one runs: it may be in the middle of replacing)
	// ... and data under another name (sections renamed) to its list:
	// nothing to fetch for those
	if (lock_wait(5)) {
		for (let l in all)
			recover_aside(cfg, l);
		rekey(cfg, all, load(state_path(cfg), {}));
		unlock();
	}
	const state = load(state_path(cfg), {});
	const usable = filter(all, l => has_data(cfg, state, l));
	const live = (kind) => `${cfg.dir}/${kind}.txt`;
	const size = (kind) => {
		let n = 0;
		for (let l in usable)
			n += fs.stat(`${cfg.dir}/${l.id}.${kind}`)?.size ?? 0;
		return n;
	};
	// With a list's data missing (being fetched, a move that did not
	// finish) the lists there make less than the list in use has: that one
	// stays until the update below has the data. Missing, it is made from
	// what there is.
	// a list's data is both its files (an update always writes the two), from its address
	const complete = (length(usable) == length(all));
	const stale = filter(KINDS, k => fs.lstat(live(k))?.type != 'file'
		|| (complete && fs.lstat(live(k)).size != size(k)));
	if (length(stale)) {
		system([ 'mkdir', '-p', cfg.dir ]);
		let err = null;
		if (lock_wait(5)) {
			err = merge(cfg, usable);
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
	if (!complete)
		return cmd_start();
	return 0;
}

function cmd_status() {
	const cfg = settings();
	const state = load(state_path(cfg), {});
	// what the state says of a section that now has another address is not about it
	let shown = {};
	uci.foreach(CONF, 'adlist', (s) => {
		const e = state.lists?.[s['.name']];
		if (e && (e.url == s.url || e.tried == s.url))
			shown[s['.name']] = e;
	});
	const busy = !!running();
	out({ ok: true, running: busy, progress: busy ? load(PROGRESS, null) : null, dir: cfg.dir, lists: shown,
		total: state.total ?? 0, finished: state.finished ?? null, error: state.error ?? null });
}

// ---------------------------------------------------------------- cron
function cmd_cron_sync() {
	const cfg = settings();
	const want = (cfg.auto && length(lists()))
		? `0 ${cfg.hour} * * * ucode ${SELF} update >${LOG} 2>&1 ${CRON_TAG}`
		: null;
	const cur = split(fs.readfile(CRON) ?? '', '\n');
	const have = filter(cur, l => index(l, CRON_TAG) >= 0)[0] ?? null;
	if (have == want)
		return 0;
	let lines = filter(cur, l => index(l, CRON_TAG) < 0 && length(l));
	if (want)
		push(lines, want);
	const test = !!getenv('ADLIST_CRON');
	if (!test)
		system([ 'mkdir', '-p', '/etc/crontabs' ]);
	fs.writefile(CRON, join('\n', lines) + '\n');
	if (!test)
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
	// adlist.uc convert <in> <block-out> <allow-out> <wild-out> <keys-out>: used by the tests
	out(convert_file(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5]));
	break;
default:
	warn('usage: adlist.uc update | start | ensure | status | catalog | catalog-sync | cron-sync\n');
	exit(1);
}
