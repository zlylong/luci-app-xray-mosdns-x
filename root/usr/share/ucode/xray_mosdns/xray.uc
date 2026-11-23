// luci-app-xray-mosdns-x - Xray configuration (returned as a plain object)
'use strict';

import { fail, hash } from 'xray_mosdns.util';

function stream_settings(n) {
	let st = { network: n.transport, security: 'none' };
	const sni = n.sni ?? n.address;
	const host = n.host ?? n.sni ?? n.address;

	if (n.tls) {
		st.security = 'tls';
		// allowInsecure was removed from Xray 26.x; do not emit it
		st.tlsSettings = { serverName: sni, fingerprint: n.fingerprint };
	}

	switch (n.transport) {
	case 'tcp':
		break;
	case 'ws':
		st.wsSettings = { path: n.path, headers: { Host: host } };
		break;
	case 'grpc':
		st.grpcSettings = { serviceName: n.service_name };
		break;
	case 'http':
		st.httpSettings = { path: n.path, host: [ host ] };
		break;
	case 'xhttp':
		st.xhttpSettings = { path: n.path, host };
		break;
	default:
		fail(`node ${n.name}: unsupported transport '${n.transport}'`);
	}
	return st;
}

// The node address is passed through as configured. Xray resolves a
// hostname itself on every dial (router resolver -> domestic upstream),
// so start-up no longer depends on DNS being reachable and a changed
// node IP is picked up without regenerating the configuration.
function outbound(n, tag) {
	if (!n.address)
		fail(`node ${n.name}: empty address`);

	switch (n.type) {
	case 'hysteria2':
		// Xray >= 26: protocol "hysteria" + hysteria transport (Hysteria2 compatible)
		if (!n.password)
			fail(`hysteria2 node ${n.name} needs password`);
		return {
			tag,
			protocol: 'hysteria',
			settings: { version: 2, address: n.address, port: n.port },
			streamSettings: {
				network: 'hysteria',
				security: 'tls',
				tlsSettings: { serverName: n.sni ?? n.address, alpn: [ 'h3' ] },
				hysteriaSettings: { version: 2, auth: n.password },
			},
		};
	case 'vless':
		if (!n.uuid)
			fail(`vless node ${n.name} needs uuid`);
		return {
			tag,
			protocol: 'vless',
			settings: { vnext: [ {
				address: n.address, port: n.port,
				users: [ { id: n.uuid, encryption: 'none', flow: n.flow } ],
			} ] },
			streamSettings: stream_settings(n),
		};
	case 'vmess':
		if (!n.uuid)
			fail(`vmess node ${n.name} needs uuid`);
		return {
			tag,
			protocol: 'vmess',
			settings: { vnext: [ {
				address: n.address, port: n.port,
				users: [ { id: n.uuid, alterId: n.alter_id, security: 'auto' } ],
			} ] },
			streamSettings: stream_settings(n),
		};
	case 'trojan':
		if (!n.password)
			fail(`trojan node ${n.name} needs password`);
		return {
			tag,
			protocol: 'trojan',
			settings: { servers: [ { address: n.address, port: n.port, password: n.password } ] },
			streamSettings: stream_settings(n),
		};
	case 'shadowsocks':
		if (!n.password)
			fail(`shadowsocks node ${n.name} needs password`);
		return {
			tag,
			protocol: 'shadowsocks',
			settings: { servers: [ { address: n.address, port: n.port, method: n.method, password: n.password } ] },
			streamSettings: stream_settings(n),
		};
	}
	fail(`node ${n.name}: unsupported node type '${n.type}'`);
}

// How a group strategy maps onto an Xray balancer.
//  fastest: leastLoad picks the member with the best probe results
//  ordered: leastLoad only does the health checking here (expected = all
//           members keeps every healthy one selectable); the group watcher
//           pins the first healthy member in list order. Xray's own
//           "costs" weight probe jitter, not latency, so they cannot
//           express a strict priority. Healthy means no failed probe among
//           the last ones (tolerance): Xray itself calls a member alive
//           until every probe it keeps (sampling: 3) has failed, and a
//           member whose probes fail every other time, with its traffic,
//           would never be given up. The watcher falls back to the alive
//           ones (the group's ".alive" balancer) when none is healthy.
const ORDERED_TOLERANCE = 0.3;	// one failed probe of three is too many
function strategy(grp) {
	switch (grp.strategy) {
	case 'ordered':    return { type: 'leastLoad', settings: { expected: length(grp.members), tolerance: ORDERED_TOLERANCE } };
	case 'roundrobin': return { type: 'roundRobin' };
	case 'random':     return { type: 'random' };
	}
	return { type: 'leastLoad' };
}

export function build(cfg, plan, env) {
	const g = cfg.global;

	// ------------------------------------------------------------ outbounds
	let outbounds = [];
	for (let name in plan.needed)
		push(outbounds, outbound(plan.by_name[name], plan.tag(name)));
	push(outbounds, { tag: 'direct', protocol: 'freedom' });

	// With router traffic proxied, whatever Xray itself sends has to be
	// recognisable or it would be fed straight back into Xray.
	if (g.proxy_router) {
		for (let o in outbounds) {
			o.streamSettings ??= {};
			o.streamSettings.sockopt = { ...(o.streamSettings.sockopt ?? {}), mark: +g.self_mark };
		}
	}
	push(outbounds, { tag: 'block', protocol: 'blackhole' });

	// ------------------------------------------------------------ rules
	let rules = [
		{ type: 'field', inboundTag: [ 'api' ], outboundTag: 'api' },
		{ type: 'field', ip: [ 'geoip:private' ], outboundTag: 'direct' },
	];
	const node_ips = [ ...env.node_ips.v4, ...env.node_ips.v6 ];
	if (length(node_ips))
		push(rules, { type: 'field', ip: node_ips, outboundTag: 'direct' });

	// The internal SOCKS inbound exists so that mosdns (and the connectivity
	// check) can reach things through the proxy. Without this rule its
	// traffic would fall through the rule table like any other, and with a
	// direct default the "foreign" DNS upstream would be queried directly.
	if (plan.main_class == 'proxy')
		push(rules, { type: 'field', inboundTag: [ 'socks-in' ], ...plan.target('main') });

	// per-device targets come before every rule
	for (let inb in plan.device_inbounds)
		push(rules, { type: 'field', inboundTag: [ inb.tag ], ...plan.target(inb.target) });

	// rules in list order; presets such as "mainland direct" are ordinary rules
	for (let r in plan.rules) {
		let rule = { type: 'field' };
		switch (r.type) {
		case 'domain':
			// subscribed blocklists are answered by mosdns; Xray has no such list
			rule.domain = filter(r.values, v => index(v, 'adlist:') != 0);
			if (!length(rule.domain))
				continue;
			break;
		case 'ip':      rule.ip = r.values; break;
		case 'port':    rule.port = r.raw; break;
		case 'network': rule.network = r.raw; break;
		}
		push(rules, { ...rule, ...plan.target(r.outbound) });
	}

	// Connections to addresses resolved for a proxied name only (see
	// config.uc, dns_inbound), which no rule above claimed: one with a name
	// sniffed is another site on the same address and goes by the default,
	// as before; one without is taken as the proxied name's. The "protocol"
	// of a rule is what was sniffed, so the first rule is how to say "a name
	// was seen". Without sniffing nothing ever is.
	if (plan.dns_inbound) {
		const from = { type: 'field', inboundTag: [ plan.dns_inbound.tag ] };
		if (g.sniffing)
			push(rules, { ...from, protocol: [ 'http', 'tls', 'quic' ], outboundTag: 'direct' });
		push(rules, { ...from, ...plan.target(plan.dns_inbound.target) });
	}

	// default: whatever no rule claimed
	push(rules, {
		type: 'field', network: 'tcp,udp',
		...(plan.default_class == 'proxy' ? plan.target('main') : { outboundTag: 'direct' }),
	});

	// ------------------------------------------------------------ inbounds
	const sniffing = g.sniffing
		? { enabled: true, destOverride: [ 'http', 'tls', 'quic' ], routeOnly: true }
		: null;

	let tproxy_in = {
		tag: 'tproxy-in',
		port: g.tproxy_port,
		protocol: 'tunnel',
		listen: g.ipv6 ? '::' : '0.0.0.0',
		// followRedirect: use the packet's original destination. Without it the
		// inbound forwards everything to its own (empty) target address.
		// "network" is the key Xray reads; an unknown key is ignored silently and
		// leaves the inbound TCP only
		settings: { network: 'tcp,udp', followRedirect: true },
		streamSettings: { sockopt: { tproxy: 'tproxy' } },
	};
	let socks_in = {
		tag: 'socks-in',
		port: g.socks_port,
		protocol: 'socks',
		listen: '127.0.0.1',
		settings: { udp: true, auth: 'noauth' },
	};
	if (sniffing) {
		tproxy_in.sniffing = sniffing;
		socks_in.sniffing = sniffing;
	}

	// one extra tproxy inbound per device target; nftables steers the devices' packets to it
	let device_in = map(plan.device_inbounds, function(inb) {
		let o = { ...tproxy_in, tag: inb.tag, port: inb.port };
		return o;
	});

	// The access log (a line per connection, into the system log) only at
	// debug and info: otherwise it pushes everything else out of logd's
	// small buffer within the hour.
	let log = { loglevel: g.log_level };
	if (!(g.log_level in [ 'debug', 'info' ]))
		log.access = 'none';

	if (plan.dns_inbound)
		push(device_in, { ...tproxy_in, tag: plan.dns_inbound.tag, port: plan.dns_inbound.port });

	let conf = {
		log: log,
		inbounds: [
			tproxy_in,
			...device_in,
			socks_in,
			{
				tag: 'api', listen: '127.0.0.1', port: g.api_port,
				protocol: 'dokodemo-door', settings: { address: '127.0.0.1' },
			},
		],
		outbounds,
		stats: {},
		// RoutingService: lets the group watcher and the UI read and pin balancer choices
		api: { tag: 'api', services: [ 'StatsService', 'RoutingService' ] },
		policy: { system: {
			statsInboundUplink: true, statsInboundDownlink: true,
			statsOutboundUplink: true, statsOutboundDownlink: true,
		} },
	};

	// ------------------------------------------------------------ groups
	// AsIs: Xray never resolves a name to make a routing decision. A
	// transparently proxied connection already carries its real destination
	// address (which mosdns handed to the client) next to the sniffed name, so
	// IP rules match that address. IPOnDemand would re-resolve the name with
	// Xray's own DNS and route by an address the client never connected to.
	let routing = { domainStrategy: 'AsIs' };
	let balancers = [], probed = [];
	for (let grp in plan.groups) {
		if (!length(grp.members))
			continue;	// nothing to choose from: targets point at the fallback directly
		const tags = map(grp.members, plan.tag);
		for (let t in tags)
			if (!(t in probed))
				push(probed, t);
		// selectors are prefix matches; every node tag ends in ".node", so a
		// full tag can only match itself
		push(balancers, { tag: grp.tag, selector: tags, strategy: strategy(grp), fallbackTag: grp.fallback_tag });
		if (grp.alive_tag)
			push(balancers, { tag: grp.alive_tag, selector: tags, strategy: { type: 'leastLoad', settings: { expected: length(tags) } } });
	}
	if (length(balancers)) {
		conf.burstObservatory = {
			subjectSelector: probed,
			pingConfig: {
				destination: g.probe_url,
				interval: g.probe_interval, timeout: '5s', sampling: 3,
			},
		};
		routing.balancers = balancers;
	}
	// Every rule tagged, the tag starting with the hash of the whole set:
	// another set of rules has no tag of this one, so it can be added to a
	// running Xray before this one is removed (xray-rules.sh).
	const set = hash(sprintf('%J', rules));
	for (let i = 0; i < length(rules); i++)
		rules[i].ruleTag = `r${set}_${i}`;
	routing.rules = rules;
	conf.routing = routing;

	return conf;
};
