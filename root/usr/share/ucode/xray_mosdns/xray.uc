// luci-app-xray-mosdns-x - Xray configuration (returned as a plain object)
'use strict';

import { fail } from 'xray_mosdns.util';

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

export function build(cfg, plan, env) {
	const g = cfg.global;

	function target(out) {
		if (out == 'main' || out == 'proxy')
			out = plan.main;
		switch (out) {
		case 'direct':   return { outboundTag: 'direct' };
		case 'block':    return { outboundTag: 'block' };
		case 'balance':  return { balancerTag: 'balancer' };
		case 'failover': return { balancerTag: 'failover' };
		}
		return { outboundTag: plan.tag(out) };
	}

	// ------------------------------------------------------------ outbounds
	let outbounds = [];
	for (let name in plan.needed)
		push(outbounds, outbound(plan.by_name[name], plan.tag(name)));
	if (plan.fo_needed)
		push(outbounds, outbound(plan.by_name[g.failover_primary], `fo-${g.failover_primary}`));
	push(outbounds, { tag: 'direct', protocol: 'freedom' });
	push(outbounds, { tag: 'block', protocol: 'blackhole' });

	// ------------------------------------------------------------ rules
	let rules = [
		{ type: 'field', inboundTag: [ 'api' ], outboundTag: 'api' },
		{ type: 'field', ip: [ 'geoip:private' ], outboundTag: 'direct' },
	];
	const node_ips = [ ...env.node_ips.v4, ...env.node_ips.v6 ];
	if (length(node_ips))
		push(rules, { type: 'field', ip: node_ips, outboundTag: 'direct' });

	// user rules have priority over the built-in split mode
	for (let r in plan.rules) {
		let rule = { type: 'field' };
		switch (r.type) {
		case 'domain':  rule.domain = r.values; break;
		case 'ip':      rule.ip = r.values; break;
		case 'port':    rule.port = r.raw; break;
		case 'network': rule.network = r.raw; break;
		}
		push(rules, { ...rule, ...target(r.outbound) });
	}

	if (plan.cn_direct) {
		push(rules, { type: 'field', domain: [ 'geosite:cn' ], outboundTag: 'direct' });
		push(rules, { type: 'field', ip: [ 'geoip:cn' ], outboundTag: 'direct' });
	}
	if (plan.mode == 'gfw')
		push(rules, { type: 'field', domain: [ 'geosite:gfw' ], ...target('main') });

	// default: follows the plan (GFW mode leaves everything else direct)
	push(rules, {
		type: 'field', network: 'tcp,udp',
		...(plan.default_class == 'proxy' ? target('main') : { outboundTag: 'direct' }),
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
		settings: { allowedNetwork: 'tcp,udp' },
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

	let conf = {
		log: { loglevel: g.log_level },
		dns: { queryStrategy: 'UseIPv4', servers: [ cfg.dns.bootstrap ] },
		inbounds: [
			tproxy_in,
			socks_in,
			{
				tag: 'api', listen: '127.0.0.1', port: g.api_port,
				protocol: 'dokodemo-door', settings: { address: '127.0.0.1' },
			},
		],
		outbounds,
		stats: {},
		api: { tag: 'api', services: [ 'StatsService' ] },
		policy: { system: {
			statsInboundUplink: true, statsInboundDownlink: true,
			statsOutboundUplink: true, statsOutboundDownlink: true,
		} },
	};

	// ------------------------------------------------------------ balancers
	let routing = { domainStrategy: 'IPIfNonMatch' };
	if (plan.bal_needed || plan.fo_needed) {
		// the observatory also registers the balancer members as used outbounds,
		// otherwise fallbackTag/selector members may be pruned as unresolved deps
		let selector = [];
		let balancers = [];
		if (plan.bal_needed) {
			push(selector, 'proxy-');
			let fb = 'direct';
			if (g.fallback_node && plan.by_name[g.fallback_node])
				fb = plan.tag(g.fallback_node);
			push(balancers, {
				tag: 'balancer', selector: [ 'proxy-' ],
				strategy: { type: g.balancer_strategy }, fallbackTag: fb,
			});
		}
		if (plan.fo_needed) {
			push(selector, 'fo-', 'out-');
			let fb = 'direct';
			if (g.failover_standby && plan.by_name[g.failover_standby])
				fb = plan.tag(g.failover_standby);
			push(balancers, {
				tag: 'failover', selector: [ 'fo-' ],
				strategy: { type: 'leastLoad' }, fallbackTag: fb,
			});
		}
		conf.burstObservatory = {
			subjectSelector: selector,
			pingConfig: {
				destination: 'https://www.gstatic.com/generate_204',
				interval: '1m', timeout: '5s', sampling: 3,
			},
		};
		routing.balancers = balancers;
	}
	routing.rules = rules;
	conf.routing = routing;

	return conf;
};
