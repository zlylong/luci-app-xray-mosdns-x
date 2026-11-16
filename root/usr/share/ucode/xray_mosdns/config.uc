// luci-app-xray-mosdns-x - UCI -> normalized configuration + routing plan
//
// The "plan" is the single rule model every backend is generated from:
// each user rule gets a class (proxy / direct / block) and the split mode
// gets a default class. mosdns, nftables and Xray all read the same plan,
// so the DNS decision and the forwarding decision cannot drift apart.
'use strict';

import { cursor } from 'uci';
import { fail, note, bool, str, port, list, words, ipver, uniq_list } from 'xray_mosdns.util';

const CFG = 'xray-mosdns';

function sections(all, stype) {
	let out = [];
	for (let name in keys(all))
		if (all[name]['.type'] == stype)
			push(out, all[name]);
	return sort(out, (a, b) => a['.index'] - b['.index']);
}

function ip_list(v, what) {
	let out = [];
	for (let item in words(v)) {
		if (ipver(item))
			push(out, item);
		else
			note(`${what}: ignoring invalid address '${item}'`);
	}
	return out;
}

export function load(confdir) {
	const c = confdir ? cursor(confdir) : cursor();
	const all = c.get_all(CFG);
	if (!all)
		fail(`cannot load uci config '${CFG}'`);

	const g = sections(all, 'global')[0] ?? {};
	const d = sections(all, 'dns')[0] ?? {};

	let fwmark = str(g.fwmark, '0x1');
	if (!match(fwmark, /^(0x[0-9a-fA-F]{1,8}|[0-9]{1,10})$/))
		fail(`invalid fwmark '${fwmark}'`);
	let route_table = str(g.route_table, '100');
	if (!match(route_table, /^[0-9]{1,10}$/))
		fail(`invalid route_table '${route_table}'`);

	let mode = str(g.rule_mode, 'chnroute');
	if (!(mode in [ 'chnroute', 'gfw', 'global', 'custom' ]))
		mode = 'chnroute';

	let cfg = {
		global: {
			enabled: bool(g.enabled),
			tproxy_port: port(g.tproxy_port, 12345, 'tproxy_port'),
			fwmark,
			route_table,
			log_level: str(g.log_level, 'warning'),
			sniffing: bool(g.sniffing, true),
			socks_port: port(g.socks_port, 1070, 'socks_port'),
			api_port: port(g.api_port, 10085, 'api_port'),
			main_target: str(g.main_target, null),
			balance_enabled: bool(g.balance_enabled),
			balancer_strategy: str(g.balancer_strategy, 'leastLoad'),
			fallback_node: str(g.fallback_node, null),
			failover_enabled: bool(g.failover_enabled),
			failover_primary: str(g.failover_primary, null),
			failover_standby: str(g.failover_standby, null),
			ipv6: bool(g.ipv6_enabled),
			rule_mode: mode,
			// decide proxy-vs-direct in the kernel so direct traffic never enters Xray
			kernel_split: bool(g.kernel_split, true),
			lan_ifaces: list(g.lan_ifaces),
			lan_devices: list(g.lan_devices),
			bypass_ips: ip_list(g.bypass_ips, 'bypass_ips'),
		},
		dns: {
			enabled: bool(d.enabled, true),
			listen_port: port(d.listen_port, 5335, 'dns.listen_port'),
			// hijack every LAN port-53 query to mosdns (dnsmasq config is left alone)
			redirect: bool(d.redirect, true),
			cache_size: +str(d.cache_size, '8192'),
			cache_everything: bool(d.cache_everything, true),
			adblock: bool(d.adblock, true),
			filter_proxy_ipv6: bool(d.filter_proxy_ipv6, true),
			bootstrap: str(d.bootstrap, '223.5.5.5'),
			remote_dns: str(d.remote_dns, '1.1.1.1'),
			domestic: list(d.domestic_dns),
			hosts: list(d.hosts),
			local_domains: [],
			dnsmasq_port: 53,
		},
		nodes: [],
		rules: [],
	};

	// the kernel sets are filled from DNS answers; without mosdns only Xray can classify
	if (!cfg.dns.enabled && cfg.global.kernel_split) {
		note('dns is disabled: kernel split turned off, Xray classifies all traffic');
		cfg.global.kernel_split = false;
	}

	if (!ipver(cfg.dns.bootstrap))
		fail(`dns.bootstrap must be an IP address, got '${cfg.dns.bootstrap}'`);
	if (!ipver(cfg.dns.remote_dns))
		fail(`dns.remote_dns must be an IP address, got '${cfg.dns.remote_dns}'`);
	if (!length(cfg.dns.domestic))
		cfg.dns.domestic = [ 'https://dns.alidns.com/dns-query', 'https://doh.pub/dns-query' ];
	if (!length(cfg.global.lan_ifaces))
		cfg.global.lan_ifaces = [ 'lan' ];

	// legacy selection (pre-0.5 configs)
	if (cfg.global.main_target == null) {
		if (str(g.node_mode, '') == 'balance' || cfg.global.balance_enabled)
			cfg.global.main_target = 'balance';
		else
			cfg.global.main_target = str(g.node, 'direct');
	}

	for (let s in sections(all, 'node')) {
		push(cfg.nodes, {
			name: s['.name'],
			enabled: bool(s.enabled),
			remarks: str(s.remarks, ''),
			type: str(s.type, 'vless'),
			address: str(s.address, null),
			port: port(s.port, 443, `node ${s['.name']}`),
			uuid: str(s.uuid, null),
			alter_id: +str(s.alter_id, '0'),
			flow: str(s.flow, ''),
			password: str(s.password, null),
			method: str(s.method, 'aes-128-gcm'),
			tls: bool(s.tls),
			sni: str(s.tls_server_name, null),
			fingerprint: str(s.fingerprint, 'chrome'),
			transport: str(s.transport, 'tcp'),
			path: str(s.path, '/'),
			host: str(s.host, null),
			service_name: str(s.service_name, ''),
		});
	}

	for (let s in sections(all, 'rule')) {
		if (!bool(s.enabled))
			continue;
		const values = words(s.value);
		if (!length(values))
			continue;
		push(cfg.rules, {
			name: s['.name'],
			type: str(s.rule_type, 'domain'),
			raw: str(s.value, ''),
			values,
			outbound: str(s.outbound, 'main'),
		});
	}

	// dnsmasq keeps serving local names; mosdns forwards those zones to it
	const dhcp = c.get_all('dhcp');
	if (dhcp) {
		const dm = sections(dhcp, 'dnsmasq')[0];
		if (dm) {
			cfg.dns.dnsmasq_port = port(dm.port, 53, 'dhcp.dnsmasq.port');
			for (let dom in [ str(dm.domain, null), ...map(list(dm.local), v => trim(v, '/')) ])
				if (dom && match(dom, /^[A-Za-z0-9._-]+$/))
					push(cfg.dns.local_domains, dom);
		}
	}
	if (!length(cfg.dns.local_domains))
		cfg.dns.local_domains = [ 'lan' ];
	cfg.dns.local_domains = uniq_list(cfg.dns.local_domains);

	return cfg;
};

// ---------------------------------------------------------------- plan
export function plan(cfg) {
	const g = cfg.global;
	let by_name = {};
	for (let n in cfg.nodes)
		by_name[n.name] = n;

	let p = {
		mode: g.rule_mode,
		main: g.main_target,
		bal_needed: (g.main_target == 'balance' || g.balance_enabled),
		fo_needed: (g.main_target == 'failover' || g.failover_enabled),
		needed: [],
		by_name,
		rules: [],
	};

	function need(name) {
		if (!(name in p.needed))
			push(p.needed, name);
	}

	if (!(p.main in [ 'direct', 'balance', 'failover' ])) {
		if (!by_name[p.main])
			fail(`main node '${p.main}' not found`);
		need(p.main);
	}
	p.main_class = (p.main == 'direct') ? 'direct' : 'proxy';

	for (let r in cfg.rules) {
		let cls;
		switch (r.outbound) {
		case 'main':
		case 'proxy':    cls = p.main_class; break;
		case 'direct':   cls = 'direct'; break;
		case 'block':    cls = 'block'; break;
		case 'balance':  cls = 'proxy'; p.bal_needed = true; break;
		case 'failover': cls = 'proxy'; p.fo_needed = true; break;
		default:
			if (!by_name[r.outbound])
				fail(`rule ${r.name}: unknown outbound '${r.outbound}'`);
			need(r.outbound);
			cls = 'proxy';
		}
		if (!(r.type in [ 'domain', 'ip', 'port', 'network' ])) {
			note(`rule ${r.name}: unknown type '${r.type}', skipped`);
			continue;
		}
		push(p.rules, { ...r, class: cls });
	}

	if (p.bal_needed) {
		if (g.fallback_node && by_name[g.fallback_node])
			need(g.fallback_node);
		for (let n in cfg.nodes)
			if (n.enabled)
				need(n.name);
		if (!length(p.needed))
			fail('load balancing enabled but no enabled node');
	}

	if (p.fo_needed) {
		if (!g.failover_primary || !by_name[g.failover_primary])
			fail('failover: primary node not set');
		need(g.failover_primary);
		if (g.failover_standby && by_name[g.failover_standby])
			need(g.failover_standby);
	}

	// What happens to traffic no rule and no built-in list claims.
	//   chnroute: proxy, with mainland destinations carved out
	//   gfw:      direct, only listed domains are proxied
	//   global / custom: proxy
	if (p.main_class == 'direct')
		p.default_class = 'direct';
	else
		p.default_class = (p.mode == 'gfw') ? 'direct' : 'proxy';
	p.cn_direct = (p.mode == 'chnroute' && p.main_class == 'proxy');

	p.tag = function(name) {
		return (p.bal_needed && by_name[name]?.enabled) ? `proxy-${name}` : `out-${name}`;
	};

	return p;
};
