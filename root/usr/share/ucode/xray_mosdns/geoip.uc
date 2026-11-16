// luci-app-xray-mosdns-x - extract one country's CIDRs from a v2ray geoip.dat
//
// geoip.dat is a protobuf GeoIPList:
//   repeated GeoIP entry = 1 { string country_code = 1;
//                              repeated CIDR cidr = 2 { bytes ip = 1; uint32 prefix = 2; } }
// Entries are skipped with seek() unless their country code matches, so only
// the wanted entry is ever held in memory.
'use strict';

import * as fs from 'fs';

function varint(buf, pos) {
	let val = 0, shift = 0;
	while (true) {
		const b = ord(buf, pos++);
		if (b == null)
			return null;
		val |= (b & 0x7f) << shift;
		if (!(b & 0x80))
			return [ val, pos ];
		shift += 7;
		if (shift > 56)
			return null;
	}
}

// iterate length-delimited / varint fields of a message held in `buf`
export function fields(buf, cb) {
	let pos = 0;
	const n = length(buf);
	while (pos < n) {
		let r = varint(buf, pos);
		if (!r)
			return false;
		const field = r[0] >> 3, wt = r[0] & 7;
		pos = r[1];
		switch (wt) {
		case 0:
			r = varint(buf, pos);
			if (!r)
				return false;
			cb(field, wt, r[0]);
			pos = r[1];
			break;
		case 2:
			r = varint(buf, pos);
			if (!r || r[1] + r[0] > n)
				return false;
			cb(field, wt, substr(buf, r[1], r[0]));
			pos = r[1] + r[0];
			break;
		case 1: pos += 8; break;
		case 5: pos += 4; break;
		default: return false;
		}
	}
	return true;
};

export function fmt_cidr(ip, prefix) {
	if (length(ip) == 4)
		return sprintf('%d.%d.%d.%d/%d', ord(ip, 0), ord(ip, 1), ord(ip, 2), ord(ip, 3), prefix);
	if (length(ip) == 16) {
		let g = [];
		for (let i = 0; i < 16; i += 2)
			push(g, sprintf('%x', (ord(ip, i) << 8) | ord(ip, i + 1)));
		return join(':', g) + '/' + prefix;
	}
	return null;
};

function parse_entry(buf) {
	let res = { v4: [], v6: [] };
	fields(buf, (field, wt, val) => {
		if (field != 2 || wt != 2)
			return;
		let ip = null, prefix = 0;
		fields(val, (f, w, v) => {
			if (f == 1 && w == 2)
				ip = v;
			else if (f == 2 && w == 0)
				prefix = v;
		});
		if (ip == null)
			return;
		const s = fmt_cidr(ip, prefix);
		if (s)
			push(length(ip) == 4 ? res.v4 : res.v6, s);
	});
	return res;
}

// Walk the top-level entries of a geoip.dat / geosite.dat file.
// cb(code, load) is called per entry; load() returns the entry body and is
// the only thing that reads it, so entries the caller skips cost one seek.
// Return true from cb to stop. Returns false when the file cannot be opened.
export function scan(path, cb) {
	const fh = fs.open(path, 'r');
	if (!fh)
		return false;

	while (true) {
		// entry header: tag (1 byte) + length varint (<= 10 bytes)
		const start = fh.tell();
		const head = fh.read(12);
		if (!head || !length(head))
			break;
		let r = varint(head, 0);
		if (!r || (r[0] & 7) != 2)
			break;
		const field = r[0] >> 3;
		r = varint(head, r[1]);
		if (!r)
			break;
		const body = start + r[1], len = r[0];

		if (field == 1) {
			const load = function() {
				fh.seek(body, 0);
				return fh.read(len);
			};
			// peek at the first field, which is the country code / list name
			fh.seek(body, 0);
			const peek = fh.read(len < 80 ? len : 80);
			let cc = null;
			if (peek && ord(peek, 0) == 0x0a) {
				const l = ord(peek, 1);
				if (l != null && l < 78)
					cc = substr(peek, 2, l);
			}
			// a code that does not sit first means an unusual encoder: parse fully
			if (cc == null) {
				fields(load(), (f, w, v) => {
					if (f == 1 && w == 2)
						cc = v;
				});
			}
			if (cc != null && cb(cc, load) === true)
				break;
		}
		fh.seek(body + len, 0);
	}
	fh.close();
	return true;
};

// returns { v4: [...], v6: [...] } or null when the file / country is missing
export function country(path, code) {
	code = uc(code);
	let res = null;
	scan(path, (cc, load) => {
		if (uc(cc) != code)
			return false;
		res = parse_entry(load());
		return true;
	});
	return res;
};

// cached wrapper: the parse only reruns when geoip.dat changes
export function country_cached(path, code, cache_file) {
	const st = fs.stat(path);
	if (!st)
		return null;
	const stamp = `${st.size}:${st.mtime}:${code}`;

	let cached = null;
	try {
		cached = json(fs.readfile(cache_file));
	}
	catch (e) {
		cached = null;
	}
	if (cached?.stamp == stamp && type(cached.v4) == 'array')
		return cached;

	const res = country(path, code);
	if (!res)
		return null;
	res.stamp = stamp;
	fs.writefile(cache_file, sprintf('%J', res));
	return res;
};
