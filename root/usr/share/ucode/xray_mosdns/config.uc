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
			// health probe used by node groups
			probe_url: str(g.probe_url, 'https://www.gstatic.com/generate_204'),
			probe_interval: str(g.probe_interval, '1m'),
			ipv6: bool(g.ipv6_enabled),
			// what happens to traffic no rule claims: proxy | direct
			default_action: str(g.default_action, null),
			// decide proxy-vs-direct in the kernel so direct traffic never enters Xray
			kernel_split: bool(g.kernel_split, true),
			// a uci list, or one space separated string (both are written by LuCI widgets)
			lan_ifaces: words(g.lan_ifaces),
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
			// answer AAAA queries with an empty response, per kind of domain
			filter_proxy_ipv6: bool(d.filter_proxy_ipv6, true),
			filter_direct_ipv6: bool(d.filter_direct_ipv6, false),
			bootstrap: str(d.bootstrap, '223.5.5.5'),
			remote_dns: str(d.remote_dns, '1.1.1.1'),
			domestic: list(d.domestic_dns),
			hosts: list(d.hosts),
			local_domains: [],
			dnsmasq_port: 53,
		},
		nodes: [],
		groups: [],
		rules: [],
		// configs older than 0.9.2: a node's "enabled" flag meant "balancer
		// member", and disabled nodes could still be used as a target
		legacy_nodes: (+str(g.schema, '1') < 2),
	};

	if (!match(cfg.global.probe_interval, /^[0-9]+[smh]$/))
		fail(`invalid probe_interval '${cfg.global.probe_interval}' (use e.g. 30s, 1m)`);

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
		if (str(g.node_mode, '') == 'balance' || bool(g.balance_enabled))
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

	for (let s in sections(all, 'group')) {
		let strategy = str(s.strategy, 'fastest');
		if (!(strategy in [ 'fastest', 'ordered', 'roundrobin', 'random' ]))
			strategy = 'fastest';
		push(cfg.groups, {
			name: s['.name'],
			remarks: str(s.remarks, s['.name']),
			strategy,
			members: list(s.member),
			fallback: str(s.fallback, 'direct'),
			// ordered only: return to an earlier member as soon as it recovers
			failback: bool(s.failback),
		});
	}

	// Pre-0.9.2 configs have one global balancer ("balance": every enabled
	// node) and one primary/standby pair ("failover"). uci-defaults turns
	// them into group sections; this gives an unconverted file the same meaning.
	if (cfg.legacy_nodes) {
		const have = {};
		for (let grp in cfg.groups)
			have[grp.name] = true;
		const outs = map(sections(all, 'rule'), r => str(r.outbound, 'main'));
		if (!have.balance && (bool(g.balance_enabled) || cfg.global.main_target == 'balance' || ('balance' in outs))) {
			const strat = { leastLoad: 'fastest', roundRobin: 'roundrobin', random: 'random' };
			push(cfg.groups, {
				name: 'balance', remarks: 'balance',
				strategy: strat[str(g.balancer_strategy, 'leastLoad')] ?? 'fastest',
				members: map(filter(cfg.nodes, n => n.enabled), n => n.name),
				fallback: str(g.fallback_node, 'direct'),
			});
		}
		if (!have.failover && (bool(g.failover_enabled) || cfg.global.main_target == 'failover' || ('failover' in outs))) {
			push(cfg.groups, {
				name: 'failover', remarks: 'failover', strategy: 'ordered',
				members: filter([ str(g.failover_primary, null), str(g.failover_standby, null) ], v => v != null),
				fallback: 'direct',
			});
		}
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
			raw: join(',', values),
			values,
			outbound: str(s.outbound, 'main'),
		});
	}

	// Configs older than 0.9.2 have a split "mode" with hidden built-in rules
	// and a separate ad-block switch. uci-defaults converts those on upgrade;
	// this keeps an unconverted file working with the same meaning.
	if (!(cfg.global.default_action in [ 'proxy', 'direct' ])) {
		const mode = str(g.rule_mode, 'chnroute');
		cfg.global.default_action = (mode == 'gfw') ? 'direct' : 'proxy';
		const have = {};
		for (let r in sections(all, 'rule'))
			have[r['.name']] = true;
		const legacy = function(name, type, value, outbound) {
			if (!have[name])
				push(cfg.rules, { name, type, values: [ value ], raw: value, outbound });
		};
		if (bool(d.adblock, true))
			legacy('builtin_ads', 'domain', 'geosite:category-ads-all', 'block');
		if (mode == 'chnroute') {
			legacy('builtin_cn_domain', 'domain', 'geosite:cn', 'direct');
			legacy('builtin_cn_ip', 'ip', 'geoip:cn', 'direct');
			legacy('builtin_noncn', 'domain', 'geosite:geolocation-!cn', 'main');
		}
		else if (mode == 'gfw') {
			legacy('builtin_gfw', 'domain', 'geosite:gfw', 'main');
		}
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
	let by_name = {}, group_by_name = {};
	for (let n in cfg.nodes)
		by_name[n.name] = n;
	for (let grp in cfg.groups)
		group_by_name[grp.name] = grp;

	let p = {
		main: g.main_target,
		needed: [],		// node names that get an outbound
		groups: [],		// groups that are actually used
		by_name,
		rules: [],
	};
	let used = {};		// group name -> resolved group

	// outbound tags never change with the configuration around them, so
	// traffic counters keep their identity
	p.tag = name => `${name}.node`;
	p.group_tag = name => `${name}.group`;

	function usable(name) {
		return by_name[name] && (by_name[name].enabled || cfg.legacy_nodes);
	}

	function need(name) {
		if (!(name in p.needed))
			push(p.needed, name);
	}

	// direct / block / node tag for a group's "nothing is healthy" case
	function fallback_tag(grp) {
		if (grp.fallback in [ 'direct', 'block' ])
			return grp.fallback;
		if (!usable(grp.fallback)) {
			note(`group ${grp.name}: fallback '${grp.fallback}' is not an enabled node, using direct`);
			return 'direct';
		}
		need(grp.fallback);
		return p.tag(grp.fallback);
	}

	function use_group(name) {
		if (used[name])
			return used[name];
		const grp = group_by_name[name];
		let members = [];
		for (let m in grp.members) {
			if (!usable(m)) {
				note(`group ${name}: member '${m}' is missing or disabled, skipped`);
				continue;
			}
			if (!(m in members)) {
				push(members, m);
				need(m);
			}
		}
		used[name] = {
			name, remarks: grp.remarks, strategy: grp.strategy, members,
			failback: !!grp.failback,
			tag: p.group_tag(name), fallback_tag: fallback_tag(grp),
		};
		push(p.groups, used[name]);
		return used[name];
	}

	// validates a target and registers what it needs; returns its class
	function claim(target, what) {
		if (target == 'direct')
			return 'direct';
		if (target == 'block')
			return 'block';
		if (group_by_name[target]) {
			use_group(target);
			return 'proxy';
		}
		if (!by_name[target])
			fail(`${what}: unknown target '${target}'`);
		if (!usable(target))
			fail(`${what}: node '${target}' is disabled`);
		need(target);
		return 'proxy';
	}

	// the Xray routing target for anything claim() accepted
	p.target = function(target) {
		if (target == 'main' || target == 'proxy')
			target = p.main;
		if (target in [ 'direct', 'block' ])
			return { outboundTag: target };
		const grp = used[target];
		if (grp)
			return length(grp.members) ? { balancerTag: grp.tag } : { outboundTag: grp.fallback_tag };
		return { outboundTag: p.tag(target) };
	};

	if (p.main == 'block')
		fail('the main target cannot be "block"');
	p.main_class = claim(p.main, 'main target');

	for (let r in cfg.rules) {
		if (!(r.type in [ 'domain', 'ip', 'port', 'network' ])) {
			note(`rule ${r.name}: unknown type '${r.type}', skipped`);
			continue;
		}
		const cls = (r.outbound in [ 'main', 'proxy' ])
			? p.main_class
			: claim(r.outbound, `rule ${r.name}`);
		push(p.rules, { ...r, class: cls });
	}

	// What happens to traffic no rule claims. With a direct main target
	// there is nothing to proxy to, whatever the default says.
	p.default_class = (p.main_class == 'direct') ? 'direct' : g.default_action;

	// When mainland addresses are sent direct, an unclassified name can be
	// resolved the ChinaDNS way: a domestic answer is trusted only if it is
	// a mainland address (which then goes direct anyway).
	p.cn_ip_direct = false;
	for (let r in p.rules)
		if (r.type == 'ip' && r.class == 'direct' && ('geoip:cn' in map(r.values, lc)))
			p.cn_ip_direct = true;

	return p;
};
