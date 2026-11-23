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

	// proxy the router's own connections too: off | tcp | tcp,udp
	let proxy_router = str(g.proxy_router, '0');
	if (proxy_router == '1')
		proxy_router = 'tcp';
	if (!(proxy_router in [ 'tcp', 'tcp,udp' ]))
		proxy_router = null;
	// socket mark carried by everything Xray and mosdns send themselves, so
	// the router-traffic rules can tell their packets from everyone else's
	let self_mark = str(g.self_mark, '0xff');
	if (!match(self_mark, /^(0x[0-9a-fA-F]{1,8}|[0-9]{1,10})$/) || +self_mark == 0)
		fail(`invalid self_mark '${self_mark}'`);
	if (+self_mark == +fwmark)
		fail('self_mark must differ from fwmark');

	let cfg = {
		global: {
			enabled: bool(g.enabled),
			tproxy_port: port(g.tproxy_port, 12345, 'tproxy_port'),
			fwmark,
			proxy_router,
			self_mark,
			route_table,
			log_level: str(g.log_level, 'warning'),
			// days the plugin's own logs keep (logs.uc)
			log_days: +str(g.log_days, '30'),
			sniffing: bool(g.sniffing, true),
			socks_port: port(g.socks_port, 1070, 'socks_port'),
			api_port: port(g.api_port, 10085, 'api_port'),
			main_target: str(g.main_target, null),
			// health probe used by node groups
			probe_url: str(g.probe_url, 'https://www.gstatic.com/generate_204'),
			probe_interval: str(g.probe_interval, '1m'),
			// used instead when the group watcher finds every member "dead" at once,
			// which usually means the probe target is the thing that is unreachable
			probe_url_backup: str(g.probe_url_backup, null),
			ipv6: bool(g.ipv6_enabled),
			// what happens to traffic no rule claims: proxy | direct
			default_action: str(g.default_action, null),
			// decide proxy-vs-direct in the kernel so direct traffic never enters Xray
			kernel_split: bool(g.kernel_split, true),
			// a uci list, or one space separated string (both are written by LuCI widgets)
			lan_ifaces: words(g.lan_ifaces),
			lan_devices: list(g.lan_devices),
			bypass_ips: ip_list(g.bypass_ips, 'bypass_ips'),
			// geosite.dat / geoip.dat, for mosdns, the kernel sets and Xray alike
			geo_dir: rtrim(str(g.geo_dir, '/usr/share/v2ray'), '/') || '/',
			xray_bin: str(g.xray_bin, '/usr/bin/xray'),
		},
		dns: {
			mosdns_bin: str(d.mosdns_bin, '/usr/bin/mosdns'),
			listen_port: port(d.listen_port, 5335, 'dns.listen_port'),
			// mosdns-x's HTTP API on 127.0.0.1: its query counters, for stats.uc
			stats_port: port(d.stats_port, 5336, 'dns.stats_port'),
			// hijack every LAN port-53 query to mosdns (dnsmasq config is left alone)
			redirect: bool(d.redirect, true),
			// hand LAN DNS back to dnsmasq while mosdns is not answering
			fallback: bool(d.fallback, true),
			cache_size: +str(d.cache_size, '8192'),
			cache_everything: bool(d.cache_everything, true),
			// answer AAAA queries with an empty response, per kind of domain
			filter_proxy_ipv6: bool(d.filter_proxy_ipv6, true),
			filter_direct_ipv6: bool(d.filter_direct_ipv6, false),
			// plain DNS for the upstreams' own names (a list; one value before 1.0.4)
			bootstrap: list(d.bootstrap),
			remote: [],
			// answer for blocked names: nxdomain | zero (0.0.0.0 / ::)
			block_mode: (str(d.block_mode, 'nxdomain') == 'zero') ? 'zero' : 'nxdomain',
			// lower bound for answer TTLs, 0 = leave them alone
			min_ttl: +str(d.min_ttl, '0'),
			query_log: bool(d.query_log),
			// MB the mosdns-x log (the query log) may take in RAM
			query_log_size: +str(d.query_log_size, '4'),
			// EDNS client subnet on domestic queries; addresses given by hand,
			// else the generator finds the router's public ones
			ecs: bool(d.ecs),
			ecs_ip: list(d.ecs_ip),
			domestic: list(d.domestic_dns),
			hosts: list(d.hosts),
			// names answered over IPv4 only (AAAA and HTTPS empty), whatever their rule
			ipv4_only: list(d.ipv4_only),
			local_domains: [],
			dnsmasq_port: 53,
		},
		nodes: [],
		groups: [],
		rules: [],
		devices: [],
		// configs older than 0.9.2: a node's "enabled" flag meant "balancer
		// member", and disabled nodes could still be used as a target
		legacy_nodes: (+str(g.schema, '1') < 2),
	};

	if (!match(cfg.global.probe_interval, /^[0-9]+[smh]$/))
		fail(`invalid probe_interval '${cfg.global.probe_interval}' (use e.g. 30s, 1m)`);
	// go into the Xray environment, the start script and the generated files
	if (!match(cfg.global.geo_dir, /^\/[A-Za-z0-9_.\/-]*$/))
		fail(`invalid geo_dir '${cfg.global.geo_dir}' (an absolute directory path)`);
	for (let p in [ [ 'xray_bin', cfg.global.xray_bin ], [ 'dns.mosdns_bin', cfg.dns.mosdns_bin ] ])
		if (!match(p[1], /^\/[A-Za-z0-9_.\/-]+$/))
			fail(`invalid ${p[0]} '${p[1]}' (an absolute file path)`);
	// values passed on to Xray and mosdns as they are: caught here, with the
	// option's name, rather than by a daemon that then will not start
	if (!(type(cfg.dns.query_log_size) == 'int' && cfg.dns.query_log_size >= 1 && cfg.dns.query_log_size <= 64)) {
		note(`dns.query_log_size: ignoring '${d.query_log_size}' (1 to 64 MB), 4 then`);
		cfg.dns.query_log_size = 4;
	}
	if (!(type(cfg.global.log_days) == 'int' && cfg.global.log_days >= 1 && cfg.global.log_days <= 365)) {
		note(`global.log_days: ignoring '${g.log_days}' (1 to 365 days), 30 then`);
		cfg.global.log_days = 30;
	}
	if (!(cfg.global.log_level in [ 'debug', 'info', 'warning', 'error', 'none' ]))
		fail(`invalid log_level '${cfg.global.log_level}' (debug, info, warning, error or none)`);
	for (let k in [ 'probe_url', 'probe_url_backup' ])
		if (cfg.global[k] != null && !match(cfg.global[k], /^https?:\/\/[^[:space:]'"\\]+$/))
			fail(`invalid ${k} '${cfg.global[k]}' (an http:// or https:// address)`);
	if (type(cfg.dns.cache_size) != 'int' || cfg.dns.cache_size < 0)
		fail(`invalid dns.cache_size '${d.cache_size}' (a whole number)`);
	// domestic upstreams: an address (optionally with a port) or a URL mosdns knows
	cfg.dns.domestic = filter(cfg.dns.domestic, u => {
		const hp = match(u, /^\[?([0-9A-Fa-f:.]+)\]?(:[0-9]{1,5})?$/);
		if ((hp && ipver(hp[1])) ||
		    (match(u, /^(udp|tcp|tls|https|h3|quic):\/\/[^[:space:]'"]+$/) && index(u, '\\') < 0))
			return true;
		note(`dns.domestic_dns: ignoring '${u}' (use an IP address or a udp/tcp/tls/https/h3/quic URL)`);
		return false;
	});
	// static entries: "name address..."
	cfg.dns.hosts = filter(cfg.dns.hosts, h => {
		const f = split(trim(h), /[[:space:]]+/);
		if (length(f) >= 2 && match(f[0], /^[A-Za-z0-9*_.:-]+$/) && length(filter(slice(f, 1), a => !ipver(a))) == 0)
			return true;
		note(`dns.hosts: ignoring '${h}' (use "name address ...")`);
		return false;
	});

	// "example.com" (it and its subdomains), or with a domain: full: keyword: prefix
	cfg.dns.ipv4_only = map(filter(cfg.dns.ipv4_only, v => {
		if (match(v, /^((domain|full|keyword):)?[A-Za-z0-9_.-]+$/))
			return true;
		note(`dns.ipv4_only: ignoring '${v}' (use example.com, full:example.com or keyword:example)`);
		return false;
	}), v => match(v, /^(domain|full|keyword):/) ? v : `domain:${v}`);

	cfg.dns.bootstrap = uniq_list(filter(cfg.dns.bootstrap, b => {
		if (ipver(b))
			return true;
		note(`dns.bootstrap: ignoring '${b}' (use an IP address)`);
		return false;
	}));
	if (!length(cfg.dns.bootstrap))
		cfg.dns.bootstrap = [ '223.5.5.5' ];
	// one IPv4 and one IPv6 address at most
	let ecs4 = null, ecs6 = null;
	for (let a in cfg.dns.ecs_ip) {
		const v = ipver(a);
		if (v == 4 && !ecs4)
			ecs4 = a;
		else if (v == 6 && !ecs6)
			ecs6 = a;
		else
			note(`dns.ecs_ip: ignoring '${a}' (one IPv4 and one IPv6 address)`);
	}
	cfg.dns.ecs_ip = (ecs4 || ecs6) ? { v4: ecs4, v6: ecs6 } : null;
	if (!(cfg.dns.min_ttl >= 0 && cfg.dns.min_ttl <= 86400))
		cfg.dns.min_ttl = 0;

	// Foreign upstreams, all reached through the proxy. A bare address means
	// plain DNS over TCP; a URL is passed on (tcp, tls, https, h3, quic).
	for (let u in words(d.remote_dns ?? '1.1.1.1')) {
		const v = ipver(u);
		if (v == 4 && index(u, '/') < 0)
			push(cfg.dns.remote, `tcp://${u}:53`);
		else if (v == 6 && index(u, '/') < 0)
			push(cfg.dns.remote, `tcp://[${u}]:53`);
		else if (match(u, /^(tcp|tls|https|h3|quic):\/\/[^[:space:]'"]+$/) && index(u, '\\') < 0)
			push(cfg.dns.remote, u);
		else
			note(`dns.remote_dns: ignoring '${u}' (use an IP address or a tcp/tls/https/h3/quic URL)`);
	}
	if (!length(cfg.dns.remote))
		fail('dns.remote_dns has no usable upstream');
	if (!length(cfg.dns.domestic))
		cfg.dns.domestic = [ 'https://dns.alidns.com/dns-query', 'https://doh.pub/dns-query' ];
	if (!length(cfg.global.lan_ifaces))
		cfg.global.lan_ifaces = [ 'lan' ];

	if (cfg.global.main_target == null)
		cfg.global.main_target = 'direct';

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
		const type = str(s.rule_type, 'domain');
		// ports go to Xray as written: 80, 443, 1000-2000
		if (type == 'port')
			for (let v in values) {
				const m = match(v, /^([0-9]{1,5})(-([0-9]{1,5}))?$/);
				if (!m || +m[1] < 1 || +m[1] > 65535 || (m[3] && (+m[3] < +m[1] || +m[3] > 65535)))
					fail(`rule ${s['.name']}: '${v}' is not a port or port range`);
			}
		push(cfg.rules, {
			name: s['.name'],
			type,
			raw: join(',', values),
			values,
			outbound: str(s.outbound, 'main'),
		});
	}

	// blocklist subscriptions: the lists themselves are downloaded and
	// converted by adlist.uc; the generator only needs to know where they are
	// and whether any is enabled
	const ab = sections(all, 'adblock')[0] ?? {};
	let ad_dir = rtrim(str(ab.dir, '/etc/xray-mosdns/adlists'), '/');
	if (!match(ad_dir, /^\/[A-Za-z0-9_.\/-]+$/) || index(ad_dir, '..') >= 0)
		ad_dir = '/etc/xray-mosdns/adlists';
	// a directory of its own under /etc/xray-mosdns; one set elsewhere may be
	// shared, and the lists are in their own subdirectory there (adlist.uc)
	if (ad_dir != '/etc/xray-mosdns' && index(ad_dir, '/etc/xray-mosdns/') != 0)
		ad_dir += '/xray-mosdns';
	cfg.adblock = {
		dir: ad_dir,
		lists: length(filter(sections(all, 'adlist'), s => bool(s.enabled, true) && str(s.url, null) != null)),
	};

	// per-device routing, keyed by MAC address
	for (let s in sections(all, 'device')) {
		if (!bool(s.enabled, true))
			continue;
		let macs = [];
		for (let m in words(s.mac)) {
			if (match(m, /^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$/))
				push(macs, lc(m));
			else
				note(`device ${s['.name']}: ignoring invalid MAC address '${m}'`);
		}
		if (!length(macs))
			continue;
		let network = str(s.network, 'tcp,udp');
		if (!(network in [ 'tcp,udp', 'tcp', 'udp' ]))
			network = 'tcp,udp';
		push(cfg.devices, {
			name: s['.name'], macs, network,
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
			// a second balancer over the same members, used by no rule: it
			// tells the group watcher which members Xray still has as alive
			alive_tag: (grp.strategy == 'ordered') ? `${name}.alive` : null,
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

	// Devices are decided before any rule: everything a device sends (or only
	// its TCP / UDP) goes to one target. Each distinct proxy target gets its
	// own tproxy inbound, which is how Xray can tell these packets apart: it
	// can match on the inbound a packet arrived on, not on a MAC address.
	p.devices = [];
	p.device_inbounds = [];		// { tag, port, target }
	let reserved = [ g.tproxy_port, g.socks_port, g.api_port, cfg.dns.listen_port, cfg.dns.stats_port ];
	let next_port = g.tproxy_port;
	for (let dev in cfg.devices) {
		const target = (dev.outbound in [ 'main', 'proxy' ]) ? p.main : dev.outbound;
		if (target == 'block')
			fail(`device ${dev.name}: "block" is not a device target`);
		const cls = claim(target, `device ${dev.name}`);
		let inbound = null;
		if (cls == 'proxy') {
			inbound = filter(p.device_inbounds, i => i.target == target)[0];
			if (!inbound) {
				next_port++;
				while (next_port in reserved)
					next_port++;
				if (next_port > 65535)
					fail('no free port left for device inbounds');
				inbound = { tag: `dev-${length(p.device_inbounds)}`, port: next_port, target };
				push(p.device_inbounds, inbound);
			}
		}
		push(p.devices, { ...dev, class: cls, inbound });
	}

	// What happens to traffic no rule claims. With a direct main target
	// there is nothing to proxy to, whatever the default says.
	p.default_class = (p.main_class == 'direct') ? 'direct' : g.default_action;

	// A connection to an address that was only ever resolved for a proxied
	// name reaches Xray with the kernel's decision lost: Xray goes by the
	// name it sniffs, and when there is none to sniff (SSH, mail, most games:
	// anything but HTTP, TLS and QUIC) no domain rule matches and the
	// connection leaves by the default. With a direct default that is the
	// opposite of what the rule says. So those connections get an inbound of
	// their own, and what cannot be sniffed there goes to the proxy: the
	// target of the proxied domain rules when they all have the same one,
	// else the main target.
	p.dns_inbound = null;
	if (g.kernel_split && p.main_class == 'proxy' && p.default_class == 'direct') {
		let targets = [];
		for (let r in p.rules) {
			if (r.type != 'domain' || r.class != 'proxy')
				continue;
			const t = (r.outbound in [ 'main', 'proxy' ]) ? p.main : r.outbound;
			if (!(t in targets))
				push(targets, t);
		}
		if (length(targets)) {
			next_port++;
			while (next_port in reserved)
				next_port++;
			if (next_port > 65535)
				fail('no free port left for the inbound of proxied names');
			p.dns_inbound = { tag: 'tproxy-dns', port: next_port, target: (length(targets) == 1) ? targets[0] : p.main };
		}
	}

	// When mainland addresses are sent direct, an unclassified name can be
	// resolved the ChinaDNS way: a domestic answer is trusted only if it is
	// a mainland address (which then goes direct anyway).
	p.cn_ip_direct = false;
	for (let r in p.rules)
		if (r.type == 'ip' && r.class == 'direct' && ('geoip:cn' in map(r.values, lc)))
			p.cn_ip_direct = true;

	return p;
};
