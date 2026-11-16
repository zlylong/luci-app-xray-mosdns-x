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
const INTERVAL = 10;

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
	print({ ok: true, groups: out }, '\n');
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

function cmd_watch() {
	while (true) {
		const pins = load(PINS, {});
		for (let grp in valid_groups())
			if (grp.strategy == 'ordered' || pins[grp.name])
				enforce(grp, pins);
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
