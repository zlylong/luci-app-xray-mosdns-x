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
import { TABLE } from 'xray_mosdns.nft';

// Xray domain syntax -> mosdns domain syntax
function domain_entries(rule, cfg) {
	let out = [];
	for (let v in rule.values) {
		if (index(v, 'adlist:') == 0) {
			// every enabled subscription, merged into one file by adlist.uc
			if (cfg.adblock.lists > 0)
				push(out, 'provider:adblock');
		}
		else if (index(v, 'geosite:') == 0)
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

	// "no IPv6" means AAAA and also HTTPS/SVCB (type 65): browsers ask for
	// that record too and it can carry IPv6 address hints
	const no_aaaa = { if: 'query_is_ipv6', exec: [ '_new_empty_response', '_return' ] };

	// metrics_block counts what is blocked (stats.uc)
	const block = (d.block_mode == 'zero') ? [ 'metrics_block', 'block_zero', '_return' ] : [ 'metrics_block', '_new_nxdomain_response', '_return' ];

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
	// every query and every blocked one, counted from mosdns' start; read on
	// 127.0.0.1 (api.http, /metrics) by stats.uc
	plugin('metrics_all', 'metrics_collector');
	plugin('metrics_block', 'metrics_collector');

	let cache = { size: d.cache_size, lazy_cache_ttl: 86400 };
	if (d.cache_everything)
		cache.cache_everything = true;
	plugin('cache', 'cache', cache);

	if (length(d.hosts))
		plugin('hosts', 'hosts', { hosts: d.hosts });

	// Router traffic proxied: mosdns' own direct queries carry the self mark,
	// so they are neither proxied nor (for 127.0.0.1:53) redirected back here.
	const self = g.proxy_router ? { so_mark: +g.self_mark } : {};

	// A URL with a host name: its address is looked up once, domestically, by
	// a bootstrap resolver. mosdns-x takes one per upstream, so with several
	// they go round the host-name upstreams in turn: one that does not answer
	// leaves the others reachable.
	let nboot = 0;
	function boot(u) {
		const host = match(u.addr, /^[a-z0-9]+:\/\/([^\/]*)/)?.[1] ?? '';
		if (index(host, '[') != 0 && match(host, /[A-Za-z]/))
			u.bootstrap = d.bootstrap[nboot++ % length(d.bootstrap)];
		return u;
	}

	plugin('forward_local', 'fast_forward', {
		upstream: map(d.domestic, addr => boot({ addr, idle_timeout: 10, ...self })),
	});
	// ECS: domestic queries carry the router's network (/24, /48), so that a
	// resolver picks CDN addresses near it. Proxied ones do not: their
	// resolver sees the proxy's address, near which they want to be answered.
	// It sits behind the cache, which keys on the query as the client sent it,
	// and takes the option off the answer again before the cache stores it.
	const ecs = d.ecs ? d.ecs_addr : null;
	if (ecs) {
		let a = { mask4: 24, mask6: 48 };
		if (ecs.v4)
			a.ipv4 = ecs.v4;
		if (ecs.v6)
			a.ipv6 = ecs.v6;
		plugin('ecs_local', 'ecs', a);
	}
	const local_fwd = ecs ? [ 'ecs_local', 'forward_local' ] : [ 'forward_local' ];

	plugin('forward_remote', 'fast_forward', {
		upstream: map(d.remote, function(addr) {
			let u = { addr, socks5: `127.0.0.1:${g.socks_port}`, idle_timeout: 10 };
			if (index(addr, 'tcp://') == 0)
				u.enable_pipeline = true;
			return boot(u);
		}),
	});

	if (d.block_mode == 'zero')
		plugin('block_zero', 'blackhole', { ipv4: [ '0.0.0.0' ], ipv6: [ '::' ] });
	if (d.min_ttl > 0)
		plugin('min_ttl', 'ttl', { minimal_ttl: d.min_ttl });

	// local names / reverse lookups stay with dnsmasq (DHCP leases, /etc/hosts)
	const lan_forward = (d.redirect && d.dnsmasq_port != d.listen_port);
	if (lan_forward)
		plugin('forward_lan', 'fast_forward', {
			upstream: [ { addr: `udp://127.0.0.1:${d.dnsmasq_port}`, ...self } ],
		});

	if (split) {
		nftset('add_proxy', 'proxy');
		nftset('add_direct', 'direct');
	}

	// ------------------------------------------------------------ matchers
	function qmatch(tag, args) {
		plugin(tag, 'query_matcher', args);
	}

	qmatch('query_is_ipv6', { qtype: [ 28, 65 ] });
	// the DNS watchdog's health check (every few seconds; a reserved name)
	qmatch('query_is_probe', { domain: [ 'full:xray-mosdns-probe.invalid' ] });
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
	// the TTL floor sits behind the forwarder so the cache stores the raised value
	const ttl = (d.min_ttl > 0) ? [ 'min_ttl' ] : [];
	plugin('local_seq', 'sequence', { exec: [ 'cache', ...local_fwd, ...ttl ] });
	plugin('remote_seq', 'sequence', { exec: [ 'cache', 'forward_remote', ...ttl ] });
	// ChinaDNS behaviour for unclassified names: trust the domestic answer
	// only when it is a mainland address, otherwise use the proxied answer.
	plugin('fallback_seq', 'sequence', { exec: [
		'cache',
		{
			primary: [
				...local_fwd,
				{
					if: '(! response_has_local_ip) && [_response_valid_answer]',
					exec: [ '_drop_response' ],
				},
			],
			secondary: [ '_prefer_ipv4', 'forward_remote' ],
			fast_fallback: 200,
		},
		...ttl,
	] });

	// ------------------------------------------------------------ main
	// The query log: the preset summary node, first after the health check,
	// so it wraps everything behind it and writes one line per query once it
	// is answered. Plugins
	// of type query_summary (which could name the outcome in their message)
	// cannot be used: mosdns-x v26.05.25 panics while loading any of them
	// (its args constructor returns new(*Args), Init asserts *Args).
	// The watchdog's health check first: answered at once, neither logged nor
	// counted (it would be a third of the queries of a quiet LAN).
	push(main, { if: 'query_is_probe', exec: [ '_new_nxdomain_response', '_return' ] });
	if (d.query_log)
		push(main, '_query_summary');
	push(main, 'metrics_all');
	push(main, 'edns_cookie_filter');
	if (length(d.hosts))
		push(main, 'hosts');
	// names to be reached over IPv4 only, whatever rule they fall under
	// (say a home server's DDNS name whose IPv6 is not usable from the LAN)
	if (length(d.ipv4_only)) {
		qmatch('query_is_ipv4_only', { domain: d.ipv4_only });
		push(main, { if: 'query_is_ipv4_only && query_is_ipv6', exec: [ '_new_empty_response', '_return' ] });
	}
	if (lan_forward)
		push(main, { if: 'query_is_lan_name || query_is_ptr', exec: [ 'forward_lan', '_return' ] });
	if (length(node_domains))
		push(main, { if: 'query_is_node', exec: [ 'local_seq', '_return' ] });

	// rules, in the same order Xray evaluates them
	let i = 0;
	let ad_exception = false;
	for (let r in plan.rules) {
		if (r.type != 'domain')
			continue;
		const entries = domain_entries(r, cfg);
		if (!length(entries))
			continue;
		const tag = `rule_${i++}`;
		qmatch(tag, { domain: entries });
		// exceptions (@@ rules) shipped inside the subscribed lists
		const cond = ('provider:adblock' in entries) ? `${tag} && (! query_is_ad_exception)` : tag;
		if (cond != tag && !ad_exception) {
			ad_exception = true;
			qmatch('query_is_ad_exception', { domain: [ 'provider:adallow' ] });
		}
		switch (r.class) {
		case 'block':
			push(main, { if: cond, exec: block });
			break;
		case 'direct':
			push(main, { if: cond, exec: via_local(true) });
			break;
		default:
			push(main, { if: cond, exec: via_proxy(true) });
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
			push(main, d.filter_proxy_ipv6 ? no_aaaa : { if: 'query_is_ipv6', exec: [ 'remote_seq', '_return' ] });
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
		// production = one JSON object per line, which is what the query log reader parses
		log: { level: 'info', file: '/tmp/mosdns-x.log', production: d.query_log },
		api: { http: `127.0.0.1:${d.stats_port}` },
		data_providers: [
			{ tag: 'geosite', file: `${g.geo_dir}/geosite.dat`, auto_reload: true },
			{ tag: 'geoip', file: `${g.geo_dir}/geoip.dat`, auto_reload: true },
			// auto_reload: a blocklist update takes effect without restarting mosdns
			...(ad_exception ? [
				{ tag: 'adblock', file: `${cfg.adblock.dir}/block.txt`, auto_reload: true },
				{ tag: 'adallow', file: `${cfg.adblock.dir}/allow.txt`, auto_reload: true },
			] : []),
		],
		plugins,
		servers: [ { exec: 'main_sequence', listeners } ],
	};
};
