#!/usr/bin/ucode
// luci-app-xray-mosdns-x - configuration generator
// Generates xray.json, mosdns.yaml, nft.rules and nft-flush-dns.rules.
//
// usage: gen-config.uc [-o outdir] [-c uci-confdir] [-g geoip.dat]
//                      [-l lan-device]... [-n]
//   -g  geoip.dat to extract kernel sets from (default: global.geo_dir)
//   -n  do not resolve node hostnames (bypass set is then IP literals only)
'use strict';

import * as fs from 'fs';
import { fail, note, ipver, uniq_list, yaml } from 'xray_mosdns.util';
import { load, plan as make_plan } from 'xray_mosdns.config';
import * as xray from 'xray_mosdns.xray';
import * as mosdns from 'xray_mosdns.mosdns';
import * as nft from 'xray_mosdns.nft';
import { country_cached } from 'xray_mosdns.geoip';

let opt = {
	out: '/var/etc/xray-mosdns',
	confdir: null,
	geoip: null,	// default: <global.geo_dir>/geoip.dat
	lan: [],
	resolve: true,
};

for (let i = 0; i < length(ARGV); i++) {
	switch (ARGV[i]) {
	case '-o': opt.out = ARGV[++i]; break;
	case '-c': opt.confdir = ARGV[++i]; break;
	case '-g': opt.geoip = ARGV[++i]; break;
	case '-l': push(opt.lan, ARGV[++i]); break;
	case '-n': opt.resolve = false; break;
	default:
		fail(`unknown argument '${ARGV[i]}'`);
	}
}

// ---------------------------------------------------------------- environment
// logical interface names ("lan") -> kernel devices ("br-lan")
function lan_devices(cfg) {
	let devs = [ ...opt.lan, ...cfg.global.lan_devices ];
	if (length(devs))
		return uniq_list(devs);

	let ubus = null;
	try {
		ubus = require('ubus').connect();
	}
	catch (e) {
		ubus = null;
	}
	for (let ifname in cfg.global.lan_ifaces) {
		const st = ubus?.call(`network.interface.${ifname}`, 'status');
		const dev = st?.l3_device ?? st?.device;
		if (dev)
			push(devs, dev);
		else
			note(`interface '${ifname}' has no device yet`);
	}
	if (!length(devs)) {
		note('no LAN device found, falling back to br-lan');
		devs = [ 'br-lan' ];
	}
	return uniq_list(devs);
}

// Best effort only: these addresses keep LAN clients that talk to a node
// directly out of the proxy. Nothing breaks when a lookup fails. The names
// are looked up all at once, so a slow resolver costs one timeout, not one
// per node.
function node_ips(cfg, plan) {
	let res = { v4: [], v6: [] };
	let names = {};		// host name -> the nodes using it
	function add(ip) {
		const v = ipver(ip);
		if (v == 4)
			push(res.v4, ip);
		else if (v == 6)
			push(res.v6, ip);
	}
	for (let name in plan.needed) {
		const addr = plan.by_name[name].address;
		if (!addr)
			continue;
		if (ipver(addr))
			add(addr);
		else if (opt.resolve && match(addr, /^[A-Za-z0-9._-]+$/)) {
			if (!names[addr])
				names[addr] = [];
			push(names[addr], name);
		}
	}

	const hosts = keys(names);
	if (length(hosts)) {
		// one background lookup per name, each answer line prefixed with the name
		// (names are checked above to hold nothing the shell would interpret)
		const cmd = join(' ', map(hosts, h => `(resolveip -t 3 '${h}' 2>/dev/null | sed 's/^/${h} /') &`)) + ' wait';
		let answered = {};
		const p = fs.popen(cmd, 'r');
		if (p) {
			for (let line in split(p.read('all') ?? '', '\n')) {
				const f = split(trim(line), /\s+/);
				if (length(f) == 2 && (f[0] in hosts) && ipver(f[1])) {
					answered[f[0]] = true;
					add(f[1]);
				}
			}
			p.close();
		}
		for (let h in hosts)
			if (!answered[h])
				note(`node ${join(', ', names[h])}: could not resolve '${h}' (continuing)`);
	}
	res.v4 = uniq_list(res.v4);
	res.v6 = uniq_list(res.v6);
	return res;
}

for (let dev in opt.lan)
	if (!match(dev, /^[A-Za-z0-9._@-]+$/))
		fail(`invalid device name '${dev}'`);

// ---------------------------------------------------------------- generate
const cfg = load(opt.confdir);
if (!opt.geoip)
	opt.geoip = `${cfg.global.geo_dir}/geoip.dat`;

// the group watcher switches to the backup probe target by writing this file
const PROBE_STATE = '/var/run/xray-mosdns-probe';
if (cfg.global.probe_url_backup && trim(fs.readfile(PROBE_STATE) ?? '') == 'backup')
	cfg.global.probe_url = cfg.global.probe_url_backup;
const plan = make_plan(cfg);

fs.mkdir(opt.out);
if (!fs.stat(opt.out))
	fail(`cannot create ${opt.out}`);

let env = {
	lan_devices: lan_devices(cfg),
	node_ips: node_ips(cfg, plan),
	geoip: null,
};
for (let dev in env.lan_devices)
	if (!match(dev, /^[A-Za-z0-9._@-]+$/))
		fail(`invalid device name '${dev}'`);

// address ranges behind a geoip:<tag> rule value, parsed once per geoip.dat
let geoip_seen = {};
env.geoip = function(tag) {
	tag = lc(tag);
	if (!(tag in geoip_seen)) {
		geoip_seen[tag] = country_cached(opt.geoip, tag, `${opt.out}/geoip-${tag}.json`);
		if (!geoip_seen[tag])
			note(`geoip:${tag} not found in ${opt.geoip}: that rule is applied by Xray only`);
	}
	return geoip_seen[tag];
};

// mosdns refuses to start when a data provider's file is missing, and the
// first download may not have happened yet
if (cfg.adblock.lists > 0) {
	system([ 'mkdir', '-p', cfg.adblock.dir ]);
	for (let f in [ 'block.txt', 'allow.txt' ])
		if (!fs.access(`${cfg.adblock.dir}/${f}`))
			fs.writefile(`${cfg.adblock.dir}/${f}`, '');
}

function write(name, data) {
	const tmp = `${opt.out}/.${name}.tmp`;
	if (fs.writefile(tmp, data) == null || !fs.rename(tmp, `${opt.out}/${name}`))
		fail(`cannot write ${opt.out}/${name}: ${fs.error()}`);
}

write('xray.json', sprintf('%.J\n', xray.build(cfg, plan, env)));
write('mosdns.yaml', '# generated by luci-app-xray-mosdns-x, do not edit\n' +
	yaml(mosdns.build(cfg, plan)));
write('nft.rules', nft.build(cfg, plan, env));
write('nft-flush-dns.rules', nft.flush_dns());
// only rewritten when it changes: the watchdog re-applies the rule when this file is newer
const redir = nft.dns_redirect(cfg, env);
if (fs.readfile(`${opt.out}/nft-dns-on.rules`) != redir.on)
	write('nft-dns-on.rules', redir.on);
write('nft-dns-off.rules', redir.off);
// what the group watcher and the status page need to talk to the balancers
write('groups.json', sprintf('%.J\n', map(filter(plan.groups, grp => length(grp.members) > 0), grp => ({
	name: grp.name, remarks: grp.remarks, tag: grp.tag, strategy: grp.strategy, failback: grp.failback,
	members: map(grp.members, m => ({ name: m, tag: plan.tag(m) })),
	fallback: grp.fallback_tag,
}))));
// The values everything else has to use while these files are in effect.
// The start script, fw.sh, the watchdog and the status page read them from
// here rather than from UCI, so a reload that falls back to the previous
// files falls back to the previous ports, mark and table as well. Every
// value is validated above; section names are UCI identifiers.
const g = cfg.global;
write('runtime.env', join('\n', [
	'# generated by luci-app-xray-mosdns-x: the values the files next to this one were made with',
	`XRAY_BIN='${g.xray_bin}'`,
	`MOSDNS_BIN='${cfg.dns.mosdns_bin}'`,
	`GEO_DIR='${g.geo_dir}'`,
	`TPROXY_PORT=${g.tproxy_port}`,
	`API_PORT=${g.api_port}`,
	`SOCKS_PORT=${g.socks_port}`,
	`DNS_PORT=${cfg.dns.listen_port}`,
	`DNS_REDIRECT=${cfg.dns.redirect ? 1 : 0}`,
	`DNS_WATCH=${(cfg.dns.redirect && cfg.dns.fallback) ? 'manage' : 'log-only'}`,
	`FWMARK=${g.fwmark}`,
	`ROUTE_TABLE=${g.route_table}`,
	`IPV6=${g.ipv6 ? 1 : 0}`,
	`KERNEL_SPLIT=${g.kernel_split ? 1 : 0}`,
	`DEFAULT_ACTION=${g.default_action}`,
	// the group watcher's pace and whether it may switch to the backup probe
	`PROBE_INTERVAL=${g.probe_interval}`,
	`PROBE_BACKUP=${g.probe_url_backup ? 1 : 0}`,
	`MAIN_TARGET='${match(g.main_target ?? '', /^[A-Za-z0-9_-]+$/) ? g.main_target : ''}'`,
]) + '\n');

note(sprintf('config generated in %s (main=%s default=%s rules=%d nodes=%d lan=%s split=%s geoip=%s)',
	opt.out, plan.main, plan.default_class, length(plan.rules), length(plan.needed),
	join(',', env.lan_devices), cfg.global.kernel_split ? 'kernel' : 'xray',
	join(',', keys(geoip_seen)) || '-'));
