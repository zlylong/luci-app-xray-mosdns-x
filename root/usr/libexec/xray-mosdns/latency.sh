#!/usr/bin/ucode
// luci-app-xray-mosdns-x - node latency test
//
//   latency.sh <uci-section>       test a configured node
//   latency.sh --target host:port  test any address
//
// Prints {"ok":true,"section":...,"type":...,"target":"ip:port","via":"tcp|icmp","ms":N}
// or {"ok":false,...,"error":"..."}. The time is that of a TCP handshake with
// the node, the best of two per address; a node that does not answer on TCP,
// such as hysteria over UDP, is pinged instead.
//
// The name ends in .sh because the LuCI views and the rpcd ACL call it so.
'use strict';

import * as fs from 'fs';
import * as socket from 'socket';
import { cursor } from 'uci';

const TIMEOUT = 2000;	// ms, per connection attempt

function done(res) {
	print(sprintf('%J\n', res));
	exit(0);
}

function now_ms() {
	const t = clock(true);
	return t[0] * 1000.0 + t[1] / 1000000.0;
}

function is_v6(ip) {
	return index(ip, ':') >= 0;
}

// IPv4 addresses first, each group in resolver order
function resolve(host) {
	if (iptoarr(host))
		return [ host ];
	let v4 = [], v6 = [];
	for (let ai in (socket.addrinfo(host, null, { socktype: socket.SOCK_STREAM }) ?? [])) {
		const ip = ai.addr?.address;
		if (!ip || (ip in v4) || (ip in v6))
			continue;
		push(is_v6(ip) ? v6 : v4, ip);
	}
	return [ ...v4, ...v6 ];
}

function tcp_ms(ip, port) {
	const addr = { family: is_v6(ip) ? socket.AF_INET6 : socket.AF_INET, address: ip, port };
	const t0 = now_ms();
	const conn = socket.connect(addr, null, null, TIMEOUT);
	if (!conn)
		return null;
	const ms = now_ms() - t0;
	conn.close();
	return ms;
}

function ping_ms(ip) {
	// only a literal address ever reaches the shell
	if (!iptoarr(ip))
		return null;
	const p = fs.popen(`ping -c 1 -W 2 ${ip} 2>/dev/null`, 'r');
	if (!p)
		return null;
	const text = p.read('all') ?? '';
	p.close();
	const m = match(text, /time=([0-9.]+)/);
	return m ? +m[1] : null;
}

let section = '', ntype = '', host, port;

if (ARGV[0] == '--target') {
	const m = match(ARGV[1] ?? '', /^(.*):([^:]*)$/);
	if (!m || m[1] == '')
		done({ ok: false, error: 'bad target' });
	host = m[1];
	port = m[2];
}
else {
	section = ARGV[0] ?? '';
	const uci = cursor();
	host = (section != '') ? uci.get('xray-mosdns', section, 'address') : null;
	if (!host)
		done({ ok: false, section, error: 'node not found' });
	port = uci.get('xray-mosdns', section, 'port') ?? '443';
	ntype = uci.get('xray-mosdns', section, 'type') ?? '';
}

const bracketed = match(host, /^\[(.*)\]$/);
if (bracketed)
	host = bracketed[1];
port = +port;
if (type(port) != 'int' || port < 1 || port > 65535)
	port = 443;

const ips = resolve(host);
if (!length(ips))
	done({ ok: false, section, error: 'no address' });

// the IPv6 addresses of a node given by name are tried for hysteria nodes only
const v6_ok = is_v6(host) || index(ntype, 'hysteria') == 0;

let best = null, used = '', via = 'tcp';
for (let ip in slice(ips, 0, 3)) {
	if (is_v6(ip) && !v6_ok)
		continue;
	for (let i = 0; i < 2; i++) {
		const ms = tcp_ms(ip, port);
		if (ms == null)
			break;
		if (best == null || ms < best) {
			best = ms;
			used = ip;
		}
	}
}

if (best == null) {
	via = 'icmp';
	for (let ip in slice(ips, 0, 2)) {
		const ms = ping_ms(ip);
		if (ms != null && (best == null || ms < best)) {
			best = ms;
			used = ip;
		}
	}
	if (best == null)
		done({ ok: false, section, target: `${host}:${port}`, type: ntype, error: 'unreachable (tcp/icmp)' });
}

done({ ok: true, section, type: ntype, target: `${used}:${port}`, via, ms: +sprintf('%.1f', best) });
