// luci-app-xray-mosdns-x - nftables ruleset
//
// The ruleset is written so that `nft -f` can be re-applied at any time:
// chains and static sets are flushed and refilled inside one transaction,
// while the *_dns sets (filled by mosdns from DNS answers) are only declared,
// never flushed here. That keeps them in step with the mosdns cache across
// reloads; they are flushed separately when the DNS rules change.
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

export function build(cfg, plan, env) {
	const g = cfg.global, d = cfg.dns;
	const T = `inet ${TABLE}`;
	const mark = g.fwmark;
	const lan = quoted(env.lan_devices);
	let out = [];

	// ------------------------------------------------------------ set contents
	let bypass = split_family([ ...g.bypass_ips, ...env.node_ips.v4, ...env.node_ips.v6 ]);
	let direct = { v4: [], v6: [] };
	let proxy = { v4: [], v6: [] };	// "must reach Xray": proxied and blocked destinations
	for (let r in plan.rules) {
		if (r.type != 'ip')
			continue;
		const lit = split_family(r.values);	// geoip:* tags stay Xray-only
		const dst = (r.class == 'direct') ? direct : proxy;
		push(dst.v4, ...lit.v4);
		push(dst.v6, ...lit.v6);
	}

	const chn = env.chnroute ?? { v4: [], v6: [] };
	// without a mainland list the carve-out cannot be done in the kernel;
	// everything is handed to Xray, whose geoip:cn rule still applies
	const cn_kernel = (plan.cn_direct && length(chn.v4) > 0);

	const static_sets = {
		bypass4: [ 'ipv4_addr', [ ...RESERVED4, ...bypass.v4 ] ],
		bypass6: [ 'ipv6_addr', [ ...RESERVED6, ...bypass.v6 ] ],
		direct4: [ 'ipv4_addr', direct.v4 ],
		direct6: [ 'ipv6_addr', direct.v6 ],
		proxy4: [ 'ipv4_addr', proxy.v4 ],
		proxy6: [ 'ipv6_addr', proxy.v6 ],
		chnroute4: [ 'ipv4_addr', cn_kernel ? chn.v4 : [] ],
		chnroute6: [ 'ipv6_addr', cn_kernel ? chn.v6 : [] ],
	};

	// ------------------------------------------------------------ objects
	push(out, `add table ${T}`);
	push(out, `add chain ${T} prerouting { type filter hook prerouting priority mangle; policy accept; }`);
	push(out, `add chain ${T} do_tproxy`);
	push(out, `add chain ${T} dns_redirect { type nat hook prerouting priority dstnat - 5; policy accept; }`);
	push(out, `add chain ${T} input_guard { type filter hook input priority filter - 5; policy accept; }`);
	for (let c in [ 'prerouting', 'do_tproxy', 'dns_redirect', 'input_guard' ])
		push(out, `flush chain ${T} ${c}`);

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
	let pre = [];
	push(pre, `iifname != { ${lan} } return`);
	push(pre, 'meta l4proto != { tcp, udp } return');
	if (d.enabled && d.redirect)
		push(pre, 'meta l4proto { tcp, udp } th dport 53 return comment "handled by dns_redirect"');
	push(pre, `ct mark & ${mark} == ${mark} goto do_tproxy`);
	push(pre, 'ct state != new return');
	push(pre, 'fib daddr type != unicast return');
	push(pre, 'ip daddr @bypass4 return');
	push(pre, 'ip6 daddr @bypass6 return');
	if (!g.ipv6)
		push(pre, 'meta nfproto ipv6 return');

	if (g.kernel_split) {
		push(pre, 'ip daddr @direct4 return');
		push(pre, 'ip daddr @direct4_dns return');
		push(pre, 'ip daddr @proxy4 goto do_tproxy');
		push(pre, 'ip daddr @proxy4_dns goto do_tproxy');
		if (g.ipv6) {
			push(pre, 'ip6 daddr @direct6 return');
			push(pre, 'ip6 daddr @direct6_dns return');
			push(pre, 'ip6 daddr @proxy6 goto do_tproxy');
			push(pre, 'ip6 daddr @proxy6_dns goto do_tproxy');
		}
		if (plan.default_class == 'direct') {
			push(pre, 'return');
		}
		else {
			if (cn_kernel) {
				push(pre, 'ip daddr @chnroute4 return');
				if (g.ipv6 && length(chn.v6))
					push(pre, 'ip6 daddr @chnroute6 return');
			}
			push(pre, 'goto do_tproxy');
		}
	}
	else {
		push(pre, 'goto do_tproxy');
	}

	let tp = [
		`ct mark set ct mark | ${mark}`,
		`meta nfproto ipv4 meta l4proto { tcp, udp } meta mark set ${mark} tproxy ip to :${g.tproxy_port} counter accept comment "xray-mosdns"`,
	];
	if (g.ipv6)
		push(tp, `meta nfproto ipv6 meta l4proto { tcp, udp } meta mark set ${mark} tproxy ip6 to :${g.tproxy_port} counter accept comment "xray-mosdns-v6"`);

	let redir = [];
	let guard = [
		// the tproxy listener is only ever reached through the tproxy rule
		`iifname != "lo" fib daddr type local meta l4proto { tcp, udp } th dport ${g.tproxy_port} drop`,
	];
	if (d.enabled && d.redirect) {
		push(redir, `iifname { ${lan} } meta l4proto { tcp, udp } th dport 53 counter redirect to :${d.listen_port}`);
		push(guard, `iifname != { "lo", ${lan} } meta l4proto { tcp, udp } th dport ${d.listen_port} drop`);
	}

	push(out, `table ${T} {`);
	for (let c in [ [ 'prerouting', pre ], [ 'do_tproxy', tp ], [ 'dns_redirect', redir ], [ 'input_guard', guard ] ]) {
		push(out, `\tchain ${c[0]} {`);
		for (let r in c[1])
			push(out, `\t\t${r}`);
		push(out, '\t}');
	}
	push(out, '}');

	return join('\n', out) + '\n';
};

// applied after nft.rules whenever the DNS rules (mosdns.yaml) changed
export function flush_dns() {
	return join('\n', map(DNS_SETS, s => `flush set inet ${TABLE} ${s}`)) + '\n';
};
