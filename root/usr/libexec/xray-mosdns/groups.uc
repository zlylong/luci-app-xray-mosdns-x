#!/usr/bin/ucode
// luci-app-xray-mosdns-x - node group helper
//
//   groups.uc list                 state of every group, as JSON
//   groups.uc pin <group> <node>   keep a group on one member ("-" releases it)
//   groups.uc watch                daemon: enforce "ordered" groups and pins
//
// Xray does the health checking (burstObservatory) and reports which members
// of a balancer are currently usable. An "ordered" group is kept on its first
// usable member by overriding the balancer; when no member is usable the
// override is removed so the balancer's fallback applies.
//
// By default an ordered group is sticky: once it has moved to a later member
// it stays there for as long as that member is usable, so a primary that
// keeps going up and down cannot drag live connections back and forth. With
// the group's "failback" option it returns to the earliest usable member.
'use strict';

import * as fs from 'fs';
import { cursor } from 'uci';

const GROUPS = '/var/etc/xray-mosdns/groups.json';
const PINS = '/var/run/xray-mosdns-pins.json';
const PROBE_STATE = '/var/run/xray-mosdns-probe';
const INTERVAL = 10;
const SWITCH_COOLDOWN = 600;	// seconds between probe target switches

function load(path, dflt) {
	try {
		return json(fs.readfile(path)) ?? dflt;
	}
	catch (e) {
		return dflt;
	}
}

const uci = cursor();
let xray = uci.get_first('xray-mosdns', 'global', 'xray_bin') ?? '/usr/bin/xray';
let port = uci.get_first('xray-mosdns', 'global', 'api_port') ?? '10085';
if (!match(xray, /^[A-Za-z0-9_.\/-]+$/))
	xray = '/usr/bin/xray';
if (!match(port, /^[0-9]+$/))
	port = '10085';

const probe_backup = uci.get_first('xray-mosdns', 'global', 'probe_url_backup');

function probe_interval() {
	const m = match(uci.get_first('xray-mosdns', 'global', 'probe_interval') ?? '1m', /^([0-9]+)([smh])$/);
	return m ? +m[1] * { s: 1, m: 60, h: 3600 }[m[2]] : 60;
}

function probe_target() {
	return (probe_backup && trim(fs.readfile(PROBE_STATE) ?? '') == 'backup') ? 'backup' : 'primary';
}

const TAG = /^[A-Za-z0-9_]+\.(node|group)$/;

// every argument is checked against TAG before it gets here
function api(args) {
	const p = fs.popen(`${xray} api ${args[0]} --server=127.0.0.1:${port} ${join(' ', slice(args, 1))} 2>/dev/null`, 'r');
	if (!p)
		return null;
	const out = p.read('all');
	return (p.close() == 0) ? out : null;
}

// { override: tag|null, selects: [tag, ...] } or null when Xray is not reachable
function balancer(tag) {
	const out = api([ 'bi', tag ]);
	if (out == null)
		return null;
	let res = { override: null, selects: [] }, sec = null;
	for (let line in split(out, '\n')) {
		if (index(line, 'Selecting Override') >= 0)
			sec = 'override';
		else if (index(line, 'Selects') >= 0)
			sec = 'selects';
		else {
			const m = match(line, /^\s*[0-9]+\s+(\S+)/);
			if (!m)
				continue;
			if (sec == 'override')
				res.override = m[1];
			else if (sec == 'selects')
				push(res.selects, m[1]);
		}
	}
	return res;
}

function override(group_tag, node_tag) {
	return api(node_tag ? [ 'bo', '-b', group_tag, node_tag ] : [ 'bo', '-b', group_tag, '-r' ]) != null;
}

function valid_groups() {
	return filter(load(GROUPS, []), grp =>
		match(grp.tag, TAG) && length(filter(grp.members, m => !match(m.tag, TAG))) == 0);
}

function member_tags(grp) {
	return map(grp.members, m => m.tag);
}

// the member a group should be held on, or null to let the balancer decide
function desired(grp, state, pins) {
	const pin = pins[grp.name];
	if (pin && (pin in member_tags(grp)))
		return pin;
	if (grp.strategy == 'ordered') {
		// sticky: the member in use is only given up when it stops being usable
		if (!grp.failback && state.override
		    && (state.override in member_tags(grp)) && (state.override in state.selects))
			return state.override;
		for (let m in grp.members)
			if (m.tag in state.selects)
				return m.tag;
	}
	return null;
}

function enforce(grp, pins) {
	const state = balancer(grp.tag);
	if (!state)
		return null;
	const want = desired(grp, state, pins);
	if (want != state.override) {
		override(grp.tag, want);
		state.override = want;
	}
	return state;
}

function name_of(grp, tag) {
	for (let m in grp.members)
		if (m.tag == tag)
			return m.name;
	return null;
}

function cmd_list() {
	const pins = load(PINS, {});
	let out = [];
	for (let grp in valid_groups()) {
		const state = balancer(grp.tag);
		let current = null;
		if (state) {
			const want = desired(grp, state, pins);
			// round robin / random have no single current member
			current = want ?? state.override
				?? ((grp.strategy == 'fastest') ? state.selects[0] : null);
		}
		push(out, {
			name: grp.name,
			remarks: grp.remarks,
			strategy: grp.strategy,
			members: map(grp.members, m => m.name),
			running: state != null,
			healthy: state ? filter(map(state.selects, t => name_of(grp, t)), v => v != null) : [],
			current: current ? name_of(grp, current) : null,
			pinned: (pins[grp.name] && (pins[grp.name] in member_tags(grp))) ? name_of(grp, pins[grp.name]) : null,
			fallback: grp.fallback,
		});
	}
	print({ ok: true, groups: out, probe: probe_target(), probe_backup: !!probe_backup }, '\n');
}

function cmd_pin(group, node) {
	let pins = load(PINS, {});
	for (let grp in valid_groups()) {
		if (grp.name != group)
			continue;
		if (node == '-' || node == null) {
			delete pins[group];
		}
		else {
			const m = filter(grp.members, m => m.name == node)[0];
			if (!m) {
				print({ ok: false, error: 'not a member of this group' }, '\n');
				return 1;
			}
			pins[group] = m.tag;
		}
		if (fs.writefile(PINS, sprintf('%J', pins)) == null) {
			print({ ok: false, error: `cannot write ${PINS}` }, '\n');
			return 1;
		}
		enforce(grp, pins);
		print({ ok: true }, '\n');
		return 0;
	}
	print({ ok: false, error: 'unknown group' }, '\n');
	return 1;
}

// When every member of every group looks dead at the same moment, the nodes
// are rarely all down: far more often the probe target itself cannot be
// reached. With a backup target configured the watcher then switches to the
// other one. That needs an Xray restart, which costs little here because all
// group traffic is already on the fallback outbounds.
function switch_probe() {
	const to = (probe_target() == 'backup') ? 'primary' : 'backup';
	if (to == 'backup')
		fs.writefile(PROBE_STATE, 'backup\n');
	else
		fs.unlink(PROBE_STATE);
	system([ 'logger', '-p', 'daemon.warn', '-t', 'xray-mosdns',
		`no group member answers the probe: switching to the ${to} probe address` ]);
	system([ '/etc/init.d/xray-mosdns', 'reload' ]);
}

function cmd_watch() {
	// long enough for a freshly started Xray to have finished its first probes
	const dead_limit = 3 * probe_interval() + 60;
	let dead_since = null;
	let last_switch = fs.stat(PROBE_STATE)?.mtime ?? 0;

	while (true) {
		const pins = load(PINS, {});
		let seen = 0, alive = 0;
		for (let grp in valid_groups()) {
			let state = null;
			if (grp.strategy == 'ordered' || pins[grp.name])
				state = enforce(grp, pins);
			else if (probe_backup)
				state = balancer(grp.tag);
			if (state) {
				seen++;
				if (length(state.selects))
					alive++;
			}
		}

		if (probe_backup) {
			const now = time();
			if (seen == 0 || alive > 0)
				dead_since = null;
			else if (dead_since == null)
				dead_since = now;
			else if (now - dead_since >= dead_limit && now - last_switch >= SWITCH_COOLDOWN) {
				switch_probe();
				last_switch = now;
				dead_since = null;
			}
		}
		system([ 'sleep', `${INTERVAL}` ]);
	}
}

switch (ARGV[0]) {
case 'list':  cmd_list(); break;
case 'pin':   exit(cmd_pin(ARGV[1], ARGV[2])); break;
case 'watch': cmd_watch(); break;
default:
	warn('usage: groups.uc list | pin <group> <node|-> | watch\n');
	exit(1);
}
