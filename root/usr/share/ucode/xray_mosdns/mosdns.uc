// luci-app-xray-mosdns-x - mosdns-x configuration (returned as a plain object)
//
// Execution notes (mosdns-x / mosdns v4 semantics):
//  - `cache` stops its own chain on a hit, so it lives inside small
//    `sequence` plugins (local_seq / remote_seq / fallback_seq). A sequence
//    plugin always continues with the caller's next node, which is what lets
//    `nftset` run for cached answers too. Without that, a cached answer
//    would be served while the kernel set no longer holds its address.
//  - `_return` ends the whole query.
'use strict';

import { note } from 'xray_mosdns.util';

const TABLE = 'xray-mosdns';

// Xray domain syntax -> mosdns domain syntax
function domain_entries(rule) {
	let out = [];
	for (let v in rule.values) {
		if (index(v, 'geosite:') == 0)
			push(out, `provider:geosite:${substr(v, 8)}`);
		else if (match(v, /^(domain|full|keyword|regexp):/))
			push(out, v);
		else if (index(v, 'ext:') == 0)
			note(`rule ${rule.name}: '${v}' is not usable for DNS split, Xray only`);
		else
			push(out, `keyword:${v}`);	// a bare value is a substring match in Xray
	}
	return out;
}

export function build(cfg, plan) {
	const d = cfg.dns, g = cfg.global;
	const split = g.kernel_split;

	let plugins = [];
	let main = [];

	function plugin(tag, type, args) {
		push(plugins, { tag, type, args });
	}

	function nftset(tag, set) {
		let args = {
			table_family4: 'inet', table_name4: TABLE, set_name4: `${set}4_dns`, mask4: 32,
		};
		if (g.ipv6) {
			args.table_family6 = 'inet';
			args.table_name6 = TABLE;
			args.set_name6 = `${set}6_dns`;
			args.mask6 = 128;
		}
		plugin(tag, 'nftset', args);
	}

	const no_aaaa = { if: 'query_is_aaaa', exec: [ '_new_empty_response', '_return' ] };

	// answer through the proxy; `mark` records the addresses for the kernel
	function via_proxy(mark) {
		let e = [];
		if (d.filter_proxy_ipv6)
			push(e, no_aaaa);
		push(e, 'remote_seq');
		if (mark && split)
			push(e, 'add_proxy');
		push(e, '_return');
		return e;
	}

	function via_local(mark) {
		let e = [];
		if (d.filter_direct_ipv6)
			push(e, no_aaaa);
		push(e, 'local_seq');
		if (mark && split)
			push(e, 'add_direct');
		push(e, '_return');
		return e;
	}

	// ------------------------------------------------------------ executables
	plugin('edns_cookie_filter', 'edns0_filter', { discard: [ 10 ] });

	let cache = { size: d.cache_size, lazy_cache_ttl: 86400 };
	if (d.cache_everything)
		cache.cache_everything = true;
	plugin('cache', 'cache', cache);

	if (length(d.hosts))
		plugin('hosts', 'hosts', { hosts: d.hosts });

	plugin('forward_local', 'fast_forward', {
		upstream: map(d.domestic, addr => ({ addr, bootstrap: d.bootstrap, idle_timeout: 10 })),
	});
	plugin('forward_remote', 'fast_forward', {
		upstream: [ {
			addr: `tcp://${d.remote_dns}:53`,
			socks5: `127.0.0.1:${g.socks_port}`,
			enable_pipeline: true,
			idle_timeout: 10,
		} ],
	});

	// local names / reverse lookups stay with dnsmasq (DHCP leases, /etc/hosts)
	const lan_forward = (d.redirect && d.dnsmasq_port != d.listen_port);
	if (lan_forward)
		plugin('forward_lan', 'fast_forward', {
			upstream: [ { addr: `udp://127.0.0.1:${d.dnsmasq_port}` } ],
		});

	if (split) {
		nftset('add_proxy', 'proxy');
		nftset('add_direct', 'direct');
	}

	// ------------------------------------------------------------ matchers
	function qmatch(tag, args) {
		plugin(tag, 'query_matcher', args);
	}

	qmatch('query_is_aaaa', { qtype: [ 28 ] });
	if (lan_forward) {
		qmatch('query_is_ptr', { qtype: [ 12 ] });
		qmatch('query_is_lan_name', {
			domain: [ ...map(d.local_domains, v => `domain:${v}`), 'regexp:^[^.]+\\.?$' ],
		});
	}

	// node hostnames must never be resolved through the proxy they describe
	let node_domains = [];
	for (let name in plan.needed) {
		const a = plan.by_name[name].address;
		if (a && match(a, /[A-Za-z]/) && index(a, ':') < 0)
			push(node_domains, `full:${a}`);
	}
	if (length(node_domains))
		qmatch('query_is_node', { domain: node_domains });

	plugin('response_has_local_ip', 'response_matcher', { ip: [ 'provider:geoip:cn' ] });

	// ------------------------------------------------------------ sequences
	plugin('local_seq', 'sequence', { exec: [ 'cache', 'forward_local' ] });
	plugin('remote_seq', 'sequence', { exec: [ 'cache', 'forward_remote' ] });
	// ChinaDNS behaviour for unclassified names: trust the domestic answer
	// only when it is a mainland address, otherwise use the proxied answer.
	plugin('fallback_seq', 'sequence', { exec: [
		'cache',
		{
			primary: [
				'forward_local',
				{
					if: '(! response_has_local_ip) && [_response_valid_answer]',
					exec: [ '_drop_response' ],
				},
			],
			secondary: [ '_prefer_ipv4', 'forward_remote' ],
			fast_fallback: 200,
		},
	] });

	// ------------------------------------------------------------ main
	push(main, 'edns_cookie_filter');
	if (length(d.hosts))
		push(main, 'hosts');
	if (lan_forward)
		push(main, { if: 'query_is_lan_name || query_is_ptr', exec: [ 'forward_lan', '_return' ] });
	if (length(node_domains))
		push(main, { if: 'query_is_node', exec: [ 'local_seq', '_return' ] });

	// rules, in the same order Xray evaluates them
	let i = 0;
	for (let r in plan.rules) {
		if (r.type != 'domain')
			continue;
		const entries = domain_entries(r);
		if (!length(entries))
			continue;
		const tag = `rule_${i++}`;
		qmatch(tag, { domain: entries });
		switch (r.class) {
		case 'block':
			push(main, { if: tag, exec: [ '_new_nxdomain_response', '_return' ] });
			break;
		case 'direct':
			push(main, { if: tag, exec: via_local(true) });
			break;
		default:
			push(main, { if: tag, exec: via_proxy(true) });
		}
	}

	// names no rule claimed follow the default
	if (plan.default_class == 'direct') {
		for (let e in via_local(false))
			push(main, e);
	}
	else if (plan.cn_ip_direct) {
		// Unclassified names may turn out direct (mainland answer) or proxied.
		// The proxied side is already kept on IPv4 by the fallback itself; when
		// direct names must not get AAAA either, the domestic answer cannot be
		// used for AAAA at all, so such queries follow the proxy setting.
		if (d.filter_direct_ipv6)
			push(main, d.filter_proxy_ipv6 ? no_aaaa : { if: 'query_is_aaaa', exec: [ 'remote_seq', '_return' ] });
		push(main, 'fallback_seq');
	}
	else {
		for (let e in via_proxy(false))
			push(main, e);
	}

	plugin('main_sequence', 'sequence', { exec: main });

	// ------------------------------------------------------------ listeners
	let listeners = [];
	// with the port-53 redirect clients reach mosdns on the LAN address;
	// ":port" is a dual-stack wildcard (WAN access is dropped in nftables)
	const addrs = d.redirect
		? [ `:${d.listen_port}` ]
		: [ `127.0.0.1:${d.listen_port}`, `[::1]:${d.listen_port}` ];
	for (let addr in addrs) {
		push(listeners, { protocol: 'udp', addr });
		push(listeners, { protocol: 'tcp', addr });
	}

	return {
		log: { level: 'info', file: '/tmp/mosdns-x.log' },
		data_providers: [
			{ tag: 'geosite', file: '/usr/share/v2ray/geosite.dat', auto_reload: true },
			{ tag: 'geoip', file: '/usr/share/v2ray/geoip.dat', auto_reload: true },
		],
		plugins,
		servers: [ { exec: 'main_sequence', listeners } ],
	};
};
