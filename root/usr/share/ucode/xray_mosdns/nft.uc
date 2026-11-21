// luci-app-xray-mosdns-x - nftables ruleset
//
// The ruleset is written so that `nft -f` can be re-applied at any time:
// chains and static sets are flushed and refilled inside one transaction,
// while the *_dns sets (filled by mosdns from DNS answers) are only declared,
// never flushed here. That keeps them in step with the mosdns cache across
// reloads; they are flushed separately when the DNS rules change.
//
// Sets: bypass4/6 (never proxied), ipg4_N/ipg6_N (IP rules, in rule order),
// direct4_dns/proxy4_dns and their v6 twins (filled by mosdns).
//
// Packet path (prerouting, mangle priority):
//   1. only traffic entering from the LAN devices is considered
//   2. flows already handed to Xray keep going there (conntrack mark)
//   3. flows already decided as direct are left alone (not "new")
//   4. a new flow is classified once, by destination address
'use strict';

import { ipver } from 'xray_mosdns.util';

export const TABLE = 'xray-mosdns';

const RESERVED4 = [
	'0.0.0.0/8', '10.0.0.0/8', '100.64.0.0/10', '127.0.0.0/8', '169.254.0.0/16',
	'172.16.0.0/12', '192.168.0.0/16', '224.0.0.0/4', '240.0.0.0/4',
];
const RESERVED6 = [ '::/127', 'fc00::/7', 'fe80::/10', 'ff00::/8' ];

const DNS_SETS = [ 'direct4_dns', 'direct6_dns', 'proxy4_dns', 'proxy6_dns' ];
const DNS_TIMEOUT = '3d';
// fixed number of ordered IP-rule groups, so the ruleset can always be re-applied in place
const IP_GROUPS = 8;

function split_family(list) {
	let r = { v4: [], v6: [] };
	for (let a in list) {
		const v = ipver(a);
		if (v == 4)
			push(r.v4, a);
		else if (v == 6)
			push(r.v6, a);
	}
	return r;
}

function quoted(devs) {
	return join(', ', map(devs, d => `"${d}"`));
}

// The router resolves through mosdns too when its traffic is proxied:
// otherwise names it looks up would never reach the kernel sets, and blocked
// names would come back poisoned. Queries mosdns itself sends to dnsmasq
// carry the self mark and are left alone.
function router_dns(cfg) {
	return !!cfg.global.proxy_router && cfg.dns.redirect;
}

function router_redirect_rule(cfg) {
	return `meta mark != ${cfg.global.self_mark} fib daddr type local meta l4proto { tcp, udp } th dport 53 counter redirect to :${cfg.dns.listen_port}`;
}

function redirect_rule(d, lan) {
	return `iifname { ${lan} } meta l4proto { tcp, udp } th dport 53 counter redirect to :${d.listen_port}`;
}

export function build(cfg, plan, env) {
	const g = cfg.global, d = cfg.dns;
	const T = `inet ${TABLE}`;
	const mark = g.fwmark;
	const lan = quoted(env.lan_devices);
	let out = [];

	// one chain per device inbound: same exemptions as everyone else, then its own port
	let dev_chains = [];
	for (let inb in plan.device_inbounds) {
		let c = [
			'fib daddr type != unicast return',
			'ip daddr @bypass4 return',
			'ip6 daddr @bypass6 return',
			`meta nfproto ipv4 meta l4proto { tcp, udp } meta mark set ${mark} tproxy ip to :${inb.port} counter accept`,
		];
		if (g.ipv6)
			push(c, `meta nfproto ipv6 meta l4proto { tcp, udp } meta mark set ${mark} tproxy ip6 to :${inb.port} counter accept`);
		else
			push(c, 'return');
		push(dev_chains, [ `dev_${inb.port}`, c ]);
	}

	// ------------------------------------------------------------ set contents
	let bypass = split_family([ ...g.bypass_ips, ...env.node_ips.v4, ...env.node_ips.v6 ]);

	// IP rules keep their order: consecutive rules of one kind share a group,
	// and the groups are tested in sequence. "proxy" here means "must reach
	// Xray", which also covers blocked destinations.
	let groups = [];
	for (let r in plan.rules) {
		if (r.type != 'ip')
			continue;
		const kind = (r.class == 'direct') ? 'direct' : 'proxy';
		let grp = groups[length(groups) - 1];
		if (!grp || grp.kind != kind) {
			grp = { kind, v4: [], v6: [] };
			push(groups, grp);
		}
		const lit = split_family(r.values);
		push(grp.v4, ...lit.v4);
		push(grp.v6, ...lit.v6);
		for (let v in r.values) {
			const m = match(v, /^geoip:([A-Za-z0-9_-]+)$/);
			if (!m || lc(m[1]) == 'private')
				continue;	// negated / private tags stay Xray-only
			const set = g.kernel_split ? env.geoip(m[1]) : null;
			if (set) {
				push(grp.v4, ...set.v4);
				push(grp.v6, ...set.v6);
			}
		}
	}
	// a trailing group that only repeats the default decides nothing
	while (length(groups) && groups[length(groups) - 1].kind == plan.default_class)
		pop(groups);
	// more groups than slots: fold the tail into the last slot of the same kind
	while (length(groups) > IP_GROUPS) {
		const extra = pop(groups);
		for (let i = IP_GROUPS - 1; i >= 0; i--) {
			if (groups[i].kind == extra.kind) {
				push(groups[i].v4, ...extra.v4);
				push(groups[i].v6, ...extra.v6);
				break;
			}
		}
	}

	let static_sets = {
		bypass4: [ 'ipv4_addr', [ ...RESERVED4, ...bypass.v4 ] ],
		bypass6: [ 'ipv6_addr', [ ...RESERVED6, ...bypass.v6 ] ],
	};
	for (let i = 0; i < IP_GROUPS; i++) {
		static_sets[`ipg4_${i}`] = [ 'ipv4_addr', groups[i]?.v4 ?? [] ];
		static_sets[`ipg6_${i}`] = [ 'ipv6_addr', groups[i]?.v6 ?? [] ];
	}

	// ------------------------------------------------------------ objects
	push(out, `add table ${T}`);
	push(out, `add chain ${T} prerouting { type filter hook prerouting priority mangle; policy accept; }`);
	push(out, `add chain ${T} do_tproxy`);
	push(out, `add chain ${T} dns_redirect { type nat hook prerouting priority dstnat - 5; policy accept; }`);
	push(out, `add chain ${T} input_guard { type filter hook input priority filter - 5; policy accept; }`);
	// the router's own connections: marked here, re-routed to lo by the policy
	// rule, and picked up by prerouting like everything else
	push(out, `add chain ${T} output { type route hook output priority mangle; policy accept; }`);
	push(out, `add chain ${T} out_mark`);
	push(out, `add chain ${T} dns_redirect_out { type nat hook output priority dstnat - 5; policy accept; }`);
	// With the DNS watchdog the redirect chain belongs to it: it is declared
	// here but neither flushed nor filled, so re-applying this file can never
	// point LAN DNS at a mosdns that is not answering.
	const watched = (d.redirect && d.fallback);
	for (let c in [ 'prerouting', 'do_tproxy', 'dns_redirect', 'input_guard', 'output', 'out_mark', 'dns_redirect_out' ])
		if (!(watched && (c == 'dns_redirect' || c == 'dns_redirect_out')))
			push(out, `flush chain ${T} ${c}`);

	// Device chains come and go with the configuration. A chain cannot be
	// deleted while prerouting still jumps to it, so prerouting is flushed
	// first (above) and stale dev_* chains are removed by fw.sh after loading.
	for (let dc in dev_chains) {
		push(out, `add chain ${T} ${dc[0]}`);
		push(out, `flush chain ${T} ${dc[0]}`);
	}

	for (let name in keys(static_sets)) {
		const s = static_sets[name];
		push(out, `add set ${T} ${name} { type ${s[0]}; flags interval; auto-merge; }`);
		push(out, `flush set ${T} ${name}`);
		if (length(s[1]))
			push(out, `add element ${T} ${name} { ${join(', ', s[1])} }`);
	}
	for (let name in DNS_SETS) {
		const t = (index(name, '6') >= 0) ? 'ipv6_addr' : 'ipv4_addr';
		push(out, `add set ${T} ${name} { type ${t}; flags timeout; timeout ${DNS_TIMEOUT}; }`);
	}

	// ------------------------------------------------------------ rules
	// The decision for a new flow, by destination address. Used for traffic
	// entering from the LAN and, with a different "proxy" verdict, for the
	// router's own connections.
	function classify(proxy) {
		let r = [
			'fib daddr type != unicast return',
			'ip daddr @bypass4 return',
			'ip6 daddr @bypass6 return',
		];
		if (!g.ipv6)
			push(r, 'meta nfproto ipv6 return');
		if (!g.kernel_split) {
			push(r, proxy);
			return r;
		}
		// addresses mosdns resolved for a domain rule are the most specific
		// information available, so they are tested before the IP rules.
		// An address learned for both a direct and a proxied name, typically
		// one CDN address serving many sites, cannot be decided by address:
		// such flows go to Xray, which matches the sniffed name against the
		// same rules. Without sniffing Xray could not tell them apart either,
		// and the direct set keeps precedence.
		const shared = 'comment "learned for a direct and a proxied name"';
		if (g.sniffing)
			push(r, `ip daddr @direct4_dns ip daddr @proxy4_dns ${proxy} ${shared}`);
		push(r, 'ip daddr @direct4_dns return');
		push(r, `ip daddr @proxy4_dns ${proxy}`);
		if (g.ipv6) {
			if (g.sniffing)
				push(r, `ip6 daddr @direct6_dns ip6 daddr @proxy6_dns ${proxy} ${shared}`);
			push(r, 'ip6 daddr @direct6_dns return');
			push(r, `ip6 daddr @proxy6_dns ${proxy}`);
		}
		for (let i = 0; i < length(groups); i++) {
			const verdict = (groups[i].kind == 'direct') ? 'return' : proxy;
			if (length(groups[i].v4))
				push(r, `ip daddr @ipg4_${i} ${verdict}`);
			if (g.ipv6 && length(groups[i].v6))
				push(r, `ip6 daddr @ipg6_${i} ${verdict}`);
		}
		push(r, (plan.default_class == 'direct') ? 'return' : proxy);
		return r;
	}

	let pre = [];
	if (g.proxy_router)
		push(pre, `iifname "lo" meta mark ${mark} goto do_tproxy comment "router traffic, marked in output"`);
	push(pre, `iifname != { ${lan} } return`);
	push(pre, 'meta l4proto != { tcp, udp } return');
	if (d.redirect)
		push(pre, 'meta l4proto { tcp, udp } th dport 53 return comment "handled by dns_redirect"');
	// Per-device targets. Matched on every packet, ahead of the per-flow logic
	// below: a device's UDP has to reach the same Xray inbound for the whole
	// exchange, and a MAC match is stateless, so no flow memory is needed.
	const l4 = { 'tcp,udp': '', tcp: 'meta l4proto tcp ', udp: 'meta l4proto udp ' };
	for (let dev in plan.devices) {
		const src = `ether saddr { ${join(', ', dev.macs)} } ${l4[dev.network]}`;
		push(pre, (dev.class == 'direct')
			? `${src}return comment "device ${dev.name}: direct"`
			: `${src}goto dev_${dev.inbound.port} comment "device ${dev.name}"`);
	}

	push(pre, `ct mark & ${mark} == ${mark} goto do_tproxy`);
	push(pre, 'ct state != new return');
	push(pre, ...classify('goto do_tproxy'));

	let tp = [
		`ct mark set ct mark | ${mark}`,
		`meta nfproto ipv4 meta l4proto { tcp, udp } meta mark set ${mark} tproxy ip to :${g.tproxy_port} counter accept comment "xray-mosdns"`,
	];
	if (g.ipv6)
		push(tp, `meta nfproto ipv6 meta l4proto { tcp, udp } meta mark set ${mark} tproxy ip6 to :${g.tproxy_port} counter accept comment "xray-mosdns-v6"`);

	// ------------------------------------------------------------ router traffic
	let outc = [], outm = [], redir_out = [];
	if (g.proxy_router) {
		const protos = (g.proxy_router == 'tcp') ? 'tcp' : '{ tcp, udp }';
		outc = [
			`meta mark ${g.self_mark} return comment "sent by Xray or mosdns"`,
			`meta l4proto != ${protos} return`,
			// the router's lookups go to mosdns through dns_redirect_out, or stay with dnsmasq
			'meta l4proto { tcp, udp } th dport 53 return',
			`ct mark & ${mark} == ${mark} goto out_mark`,
			'ct state != new return',
			...classify('goto out_mark'),
		];
		outm = [
			`ct mark set ct mark | ${mark}`,
			`meta mark set ${mark}`,
		];
		if (router_dns(cfg) && !watched)
			push(redir_out, router_redirect_rule(cfg));
	}

	let redir = [];
	let guard = [
		// the tproxy listener is only ever reached through the tproxy rule
		`iifname != "lo" fib daddr type local meta l4proto { tcp, udp } th dport { ${join(', ', [ g.tproxy_port, ...map(plan.device_inbounds, i => i.port) ])} } drop`,
	];
	if (d.redirect) {
		if (!watched)
			push(redir, redirect_rule(d, lan));
		push(guard, `iifname != { "lo", ${lan} } meta l4proto { tcp, udp } th dport ${d.listen_port} drop`);
	}

	push(out, `table ${T} {`);
	for (let c in [ [ 'prerouting', pre ], [ 'do_tproxy', tp ], ...dev_chains, [ 'dns_redirect', redir ], [ 'input_guard', guard ],
	                [ 'output', outc ], [ 'out_mark', outm ], [ 'dns_redirect_out', redir_out ] ]) {
		push(out, `\tchain ${c[0]} {`);
		for (let r in c[1])
			push(out, `\t\t${r}`);
		push(out, '\t}');
	}
	push(out, '}');

	return join('\n', out) + '\n';
};

// the two states of the redirect chain, for the DNS watchdog
export function dns_redirect(cfg, env) {
	const T = `inet ${TABLE}`;
	const flush = `flush chain ${T} dns_redirect\nflush chain ${T} dns_redirect_out\n`;
	let on = flush + `add rule ${T} dns_redirect ${redirect_rule(cfg.dns, quoted(env.lan_devices))}\n`;
	if (router_dns(cfg))
		on += `add rule ${T} dns_redirect_out ${router_redirect_rule(cfg)}\n`;
	return { on, off: flush };
};

// applied after nft.rules whenever the DNS rules (mosdns.yaml) changed
export function flush_dns() {
	return join('\n', map(DNS_SETS, s => `flush set inet ${TABLE} ${s}`)) + '\n';
};
