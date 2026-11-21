#!/usr/bin/ucode
// luci-app-xray-mosdns-x - look inside geosite.dat / geoip.dat
//
//   geoview.uc tags [text]              list names, optionally filtered
//   geoview.uc lookup <domain|ip>       which lists contain it
//   geoview.uc list <geosite|geoip> <tag> [limit]   first entries + total
//   geoview.uc dump <geosite|geoip> <tag>           every entry, plain text
//
// Everything except `dump` prints JSON.
//
// lookup does not decode the files. A list entry is stored as a tagged,
// length-prefixed string, so "is example.com in this list" is a search for
// the bytes <0x12><len>example.com; the bytes just before a hit give the
// entry type. That keeps a lookup over the whole of geosite.dat fast enough
// for a router.
'use strict';

import { scan, fields, fmt_cidr } from 'xray_mosdns.geoip';
import { cursor } from 'uci';

const GEO_DIR = rtrim(cursor().get_first('xray-mosdns', 'global', 'geo_dir') || '/usr/share/v2ray', '/');
const FILES = {
	geosite: `${GEO_DIR}/geosite.dat`,
	geoip: `${GEO_DIR}/geoip.dat`,
};
// v2ray Domain.Type
const TYPES = [ 'keyword', 'regexp', 'domain', 'full' ];

function out(obj) {
	print(obj, '\n');
}

function die(msg) {
	out({ ok: false, error: msg });
	exit(1);
}

// ---------------------------------------------------------------- tags
function cmd_tags(text) {
	text = lc(text ?? '');
	let res = { ok: true, geosite: [], geoip: [] };
	for (let kind in [ 'geosite', 'geoip' ]) {
		scan(FILES[kind], (code) => {
			const name = lc(code);
			if (!length(text) || index(name, text) >= 0)
				push(res[kind], name);
			return false;
		});
		sort(res[kind]);
	}
	out(res);
}

// ---------------------------------------------------------------- list / dump
// Both walkers call cb(line) for the first `max` entries only and return the
// total, so a preview of a huge list does not pay for decoding all of it.
function domain_lines(buf, cb, max) {
	let total = 0;
	fields(buf, (f, w, v) => {
		if (f != 2 || w != 2)
			return;
		if (total++ >= max)
			return;
		let type = 0, value = null, attrs = '';
		fields(v, (f2, w2, v2) => {
			if (f2 == 1 && w2 == 0)
				type = v2;
			else if (f2 == 2 && w2 == 2)
				value = v2;
			else if (f2 == 3 && w2 == 2)
				fields(v2, (f3, w3, v3) => {
					if (f3 == 1 && w3 == 2)
						attrs += ` @${v3}`;
				});
		});
		if (value != null)
			cb(`${TYPES[type] ?? type}:${value}${attrs}`);
	});
	return total;
}

function cidr_lines(buf, cb, max) {
	let total = 0;
	fields(buf, (f, w, v) => {
		if (f != 2 || w != 2)
			return;
		if (total++ >= max)
			return;
		let ip = null, prefix = 0;
		fields(v, (f2, w2, v2) => {
			if (f2 == 1 && w2 == 2)
				ip = v2;
			else if (f2 == 2 && w2 == 0)
				prefix = v2;
		});
		const s = (ip != null) ? fmt_cidr(ip, prefix) : null;
		if (s)
			cb(s);
	});
	return total;
}

// returns the number of entries in the list, or null when it does not exist
function each_line(kind, tag, cb, max) {
	if (!FILES[kind])
		die('kind must be geosite or geoip');
	tag = uc(tag ?? '');
	let total = null;
	if (!scan(FILES[kind], (code, load) => {
		if (uc(code) != tag)
			return false;
		total = (kind == 'geosite' ? domain_lines : cidr_lines)(load(), cb, max ?? 1e12);
		return true;
	}))
		die(`cannot open ${FILES[kind]}`);
	return total;
}

function cmd_list(kind, tag, limit) {
	limit = +(limit ?? 100);
	if (!(limit > 0))
		limit = 100;
	let lines = [];
	const total = each_line(kind, tag, (line) => push(lines, line), limit);
	if (total == null)
		die(`${kind}:${lc(tag)} not found`);
	out({ ok: true, kind, tag: lc(tag), total, lines });
}

function cmd_dump(kind, tag) {
	const total = each_line(kind, tag, (line) => print(line, '\n'));
	if (total == null) {
		warn(`${kind}:${tag} not found\n`);
		exit(1);
	}
}

// ---------------------------------------------------------------- lookup
// every occurrence of needle in buf, in one pass (split is binary safe)
function hits(buf, needle, cb) {
	if (index(buf, needle) < 0)
		return;
	const parts = split(buf, needle);
	let pos = 0;
	for (let i = 0; i < length(parts) - 1; i++) {
		pos += length(parts[i]);
		cb(pos);
		pos += length(needle);
	}
}

function attrs_at(buf, pos) {
	let res = [];
	// repeated Attribute { string key = 1; ... } directly after the value
	while (ord(buf, pos) == 0x1a) {
		const alen = ord(buf, pos + 1);
		if (alen == null || alen > 127)
			break;
		if (ord(buf, pos + 2) == 0x0a) {
			const klen = ord(buf, pos + 3);
			if (klen != null && klen < alen)
				push(res, substr(buf, pos + 4, klen));
		}
		pos += 2 + alen;
	}
	return res;
}

// Go regexp -> POSIX ERE, close enough for the patterns found in geosite
function to_ere(re) {
	re = replace(re, /\(\?:/g, '(');
	re = replace(re, /\\d/g, '[0-9]');
	re = replace(re, /\\w/g, '[A-Za-z0-9_]');
	return re;
}

function lookup_domain(q) {
	q = lc(trim(q));
	q = replace(q, /^[a-z]+:\/\//, '');
	q = replace(q, /[\/:].*$/, '');
	q = trim(q, '.');
	if (!match(q, /^[a-z0-9_.-]+$/) || length(q) > 120)
		die('not a domain name');

	const labels = split(q, '.');
	// candidate -> what an entry holding exactly this string would mean
	//   suffix: whole labels from some point to the end (matches "domain:")
	//   any run of whole labels is also a substring (matches "keyword:")
	let cands = {};
	for (let i = 0; i < length(labels); i++)
		for (let j = i + 1; j <= length(labels); j++)
			cands[join('.', slice(labels, i, j))] = (j == length(labels));

	const regex_mark = chr(0x08, 0x01, 0x12);
	let matches = [];

	if (!scan(FILES.geosite, (code, load) => {
		const buf = load();
		const tag = lc(code);
		let seen = {};
		const add = function(rule, attrs) {
			if (seen[rule])
				return;
			seen[rule] = true;
			push(matches, { tag, rule, attrs });
		};

		for (let cand in keys(cands)) {
			const is_suffix = cands[cand];
			hits(buf, chr(0x12, length(cand)) + cand, (p) => {
				// the type field (0x08 <type>) precedes the value; it is absent for type 0
				const type = (p >= 2 && ord(buf, p - 2) == 0x08) ? ord(buf, p - 1) : 0;
				if ((type == 2 && is_suffix) || (type == 3 && cand == q) || type == 0)
					add(`${TYPES[type]}:${cand}`, attrs_at(buf, p + 2 + length(cand)));
			});
		}

		hits(buf, regex_mark, (p) => {
			const len = ord(buf, p + 3);
			if (len == null || len > 127)
				return;
			const src = substr(buf, p + 4, len);
			try {
				if (match(q, regexp(to_ere(src))))
					add(`regexp:${src}`, attrs_at(buf, p + 4 + len));
			}
			catch (e) {
				// a pattern POSIX cannot express: not evaluated
			}
		});
		return false;
	}))
		die(`cannot open ${FILES.geosite}`);

	out({ ok: true, type: 'domain', query: q, matches });
}

function v4_bytes(s) {
	const m = match(s, /^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$/);
	if (!m)
		return null;
	let b = [];
	for (let i = 1; i <= 4; i++) {
		if (+m[i] > 255)
			return null;
		push(b, +m[i]);
	}
	return b;
}

function v6_bytes(s) {
	if (index(s, ':') < 0 || !match(s, /^[0-9a-fA-F:]+$/))
		return null;
	const halves = split(s, '::');
	if (length(halves) > 2)
		return null;
	const head = length(halves[0]) ? split(halves[0], ':') : [];
	const tail = (length(halves) == 2 && length(halves[1])) ? split(halves[1], ':') : [];
	if (length(halves) == 1 ? length(head) != 8 : length(head) + length(tail) > 7)
		return null;
	let groups = [ ...head ];
	for (let i = length(head) + length(tail); i < 8; i++)
		push(groups, '0');
	push(groups, ...tail);
	let b = [];
	for (let grp in groups) {
		if (!length(grp) || length(grp) > 4)
			return null;
		const v = hex(grp);
		push(b, (v >> 8) & 0xff, v & 0xff);
	}
	return b;
}

// does the CIDR stored at buf[pos..] (len bytes, then 0x10 <prefix>) contain addr?
function cidr_contains(buf, pos, addr) {
	const n = length(addr);
	if (ord(buf, pos + n) != 0x10)
		return null;
	const prefix = ord(buf, pos + n + 1);
	if (prefix == null || prefix > n * 8)
		return null;
	for (let i = 0; i < n; i++) {
		const bits = prefix - i * 8;
		if (bits <= 0)
			break;
		const mask = (bits >= 8) ? 0xff : (0xff << (8 - bits)) & 0xff;
		if ((ord(buf, pos + i) & mask) != (addr[i] & mask))
			return null;
	}
	return prefix;
}

function lookup_ip(q) {
	const addr = v4_bytes(q) ?? v6_bytes(q);
	if (!addr)
		die('not an IP address');
	if (addr[0] == 0)
		die('addresses starting with 0 are not looked up');
	const n = length(addr);
	// a containing network of /8 or longer starts with the same first byte
	const needle = chr(0x0a, n, addr[0]);
	let matches = [];

	if (!scan(FILES.geoip, (code, load) => {
		const buf = load();
		let best = null, best_pos = 0;
		hits(buf, needle, (p) => {
			const prefix = cidr_contains(buf, p + 2, addr);
			if (prefix != null && (best == null || prefix > best)) {
				best = prefix;
				best_pos = p + 2;
			}
		});
		if (best != null)
			push(matches, { tag: lc(code), rule: fmt_cidr(substr(buf, best_pos, n), best), attrs: [] });
		return false;
	}))
		die(`cannot open ${FILES.geoip}`);

	out({ ok: true, type: 'ip', query: q, matches });
}

function cmd_lookup(q) {
	q = trim(q ?? '');
	if (!length(q))
		die('nothing to look up');
	if (v4_bytes(q) || index(q, ':') >= 0 && v6_bytes(q))
		lookup_ip(q);
	else
		lookup_domain(q);
}

switch (ARGV[0]) {
case 'tags':   cmd_tags(ARGV[1]); break;
case 'lookup': cmd_lookup(ARGV[1]); break;
case 'list':   cmd_list(ARGV[1], ARGV[2], ARGV[3]); break;
case 'dump':   cmd_dump(ARGV[1], ARGV[2]); break;
default:
	warn('usage: geoview.uc tags [text] | lookup <domain|ip> | list <geosite|geoip> <tag> [limit] | dump <geosite|geoip> <tag>\n');
	exit(1);
}
