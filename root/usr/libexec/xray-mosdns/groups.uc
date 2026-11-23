#!/usr/bin/ucode
// luci-app-xray-mosdns-x - node group helper
//
//   groups.uc list                 state of every group, as JSON
//   groups.uc pin <group> <node>   keep a group on one member ("-" releases it)
//   groups.uc watch                daemon: enforce "ordered" groups and pins
//
// An "ordered" group is kept on its first usable member by overriding the
// balancer; when no member is usable the override is removed so the
// balancer's fallback applies.
//
// Which members are usable the watcher finds out itself: it sends a request
// through each one (Xray's "probe-in" SOCKS inbound hands an account to the
// node of its name). Xray's own checking (burstObservatory) asks at random
// moments, a few times per several intervals, gives a member up for one
// lost answer and takes three good ones to have it back, and its first
// request after every start fails. Here a member is asked at once at the
// start and then every interval; a request that fails is repeated on the
// next rounds, and only FAIL_LIMIT in a row make the member down (so one
// lost answer moves nothing, and a dead member is known within the
// interval plus half a minute); a down one is asked more often and is up
// again after RISE good answers. The backup address is tried when the
// first gives nothing, without restarting anything. When every member
// fails at once and the router cannot reach a domestic site either, it is
// the uplink: nothing is counted.
//
// Groups of the other kinds are still Xray's (leastLoad, random, round
// robin need its results), and so is an ordered group when the files in
// effect are from before the probe inbound (no PROBE_PORT in runtime.env):
// then the balancer's own selection is what "usable" means, as it was.
//
// By default an ordered group is sticky: once it has moved to a later member
// it stays there for as long as that member is usable, so a primary that
// keeps going up and down cannot drag live connections back and forth. With
// the group's "failback" option it returns to the earliest usable member.
//
// A group with no member held (Xray just started, so its overrides are
// gone, or the group had fallen to its fallback) settles first: for a few
// probe rounds it follows list order whatever "failback" says. Xray's first
// probe at start fails for every member, so the member that answers a probe
// first is not necessarily the first one; held at once by a sticky group,
// a backup would be kept until it failed.
'use strict';

import * as fs from 'fs';
import { cursor } from 'uci';

const GROUPS = '/var/etc/xray-mosdns/groups.json';
const PINS = '/var/run/xray-mosdns-pins.json';
const PROBE_STATE = '/var/run/xray-mosdns-probe';
// what the watcher knows of the nodes it probes, for `list`
const NODES = '/var/run/xray-mosdns-nodes.json';
const INTERVAL = 10;		// seconds between rounds when Xray does the checking
const TICK = 5;			// ... when the watcher does
const PROBE_TIMEOUT = 5;	// seconds a probe may take
const FAIL_LIMIT = 3;		// failed probes in a row before a node is down
const RISE = 2;			// good ones in a row before a down node is up again
const DOWN_INTERVAL = 30;	// a down node is asked at least this often
// reachable without the proxy when the uplink works
const UPLINK = [ 'https://www.aliyun.com', 'https://www.baidu.com' ];
const SETTLE_ROUNDS = 4;	// probe rounds a group without a held member follows list order
const SWITCH_COOLDOWN = 600;	// seconds between probe target switches
const URL = /^https?:\/\/[^[:space:]'"\\]+$/;

function load(path, dflt) {
	try {
		return json(fs.readfile(path)) ?? dflt;
	}
	catch (e) {
		return dflt;
	}
}

const RUNTIME = '/var/etc/xray-mosdns/runtime.env';

// The binary, API port and probe settings in effect: from the runtime.env
// next to the running config, else from UCI. The watcher reads them again
// every round, so a reload that changes them reaches it without a restart.
function settings() {
	let rt = {};
	for (let l in split(fs.readfile(RUNTIME) ?? '', '\n')) {
		const m = match(l, /^([A-Z_]+)='?([^']*)'?$/);
		if (m)
			rt[m[1]] = m[2];
	}
	const uci = cursor();
	const opt = (k) => uci.get_first('xray-mosdns', 'global', k);
	let xray = rt.XRAY_BIN || opt('xray_bin') || '/usr/bin/xray';
	let port = rt.API_PORT || opt('api_port') || '10085';
	// both go into a shell command
	if (!match(xray, /^[A-Za-z0-9_.\/-]+$/))
		xray = '/usr/bin/xray';
	if (!match(port, /^[0-9]+$/))
		port = '10085';
	const m = match(rt.PROBE_INTERVAL || opt('probe_interval') || '1m', /^([0-9]+)([smh])$/);
	// the addresses go into a shell command, in single quotes
	const url = (v) => (v && match(v, URL)) ? v : null;
	return {
		xray, port,
		// the probe inbound of the files in effect: without one Xray does the checking
		probe_port: match(rt.PROBE_PORT ?? '', /^[0-9]+$/) ? rt.PROBE_PORT : null,
		probe_url: url(rt.PROBE_URL),
		probe_url_backup: url(rt.PROBE_URL_BACKUP),
		probe_backup: ('PROBE_BACKUP' in rt) ? rt.PROBE_BACKUP == '1' : !!opt('probe_url_backup'),
		probe_interval: m ? +m[1] * { s: 1, m: 60, h: 3600 }[m[2]] : 60,
	};
}

let S = settings();

function probe_target() {
	return (S.probe_backup && trim(fs.readfile(PROBE_STATE) ?? '') == 'backup') ? 'backup' : 'primary';
}

const TAG = /^[A-Za-z0-9_]+\.(node|group)$/;
const ALIVE_TAG = /^[A-Za-z0-9_]+\.alive$/;

// every argument is checked against TAG (or ALIVE_TAG) before it gets here
function api(args) {
	const p = fs.popen(`${S.xray} api ${args[0]} --server=127.0.0.1:${S.port} ${join(' ', slice(args, 1))} 2>/dev/null`, 'r');
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
	return filter(load(GROUPS, []), grp => {
		if (grp.alive != null && !match(grp.alive, ALIVE_TAG))
			grp.alive = null;
		return match(grp.tag, TAG) && length(filter(grp.members, m => !match(m.tag, TAG))) == 0;
	});
}

function member_tags(grp) {
	return map(grp.members, m => m.tag);
}

// The members of an ordered group Xray still has as alive (not every probe
// it keeps failed), from the group's ".alive" balancer: read once per round.
function alive_members(grp, state) {
	if (state.alive == null)
		state.alive = (grp.alive ? balancer(grp.alive)?.selects : null) ?? [];
	return state.alive;
}

// the member a group should be held on, or null to let the balancer decide;
// `settling`: list order, as with failback (see the top)
function desired(grp, state, pins, settling) {
	const pin = pins[grp.name];
	if (pin && (pin in member_tags(grp)))
		return pin;
	if (grp.strategy == 'ordered') {
		const sticky = !grp.failback && !settling;
		// usable: no failed probe lately (the balancer's tolerance)
		// sticky: the member in use is only given up when it stops being usable
		if (sticky && state.override
		    && (state.override in member_tags(grp)) && (state.override in state.selects))
			return state.override;
		for (let m in grp.members)
			if (m.tag in state.selects)
				return m.tag;
		// Every member failed a probe lately: the probe target or the uplink
		// may be what failed. A member Xray still has as alive (not every
		// probe it keeps failed) beats the group's fallback: the one in use
		// first, then the first in order.
		const alive = alive_members(grp, state);
		if (sticky && state.override && (state.override in member_tags(grp)) && (state.override in alive))
			return state.override;
		for (let m in grp.members)
			if (m.tag in alive)
				return m.tag;
	}
	return null;
}

function name_of(grp, tag) {
	for (let m in grp.members)
		if (m.tag == tag)
			return m.name;
	return null;
}

function say(msg) {
	system([ 'logger', '-t', 'xray-mosdns', msg ]);
}

// ---------------------------------------------------------------- own probes
// does the watcher check the ordered groups' members itself?
function own() {
	return S.probe_port != null && S.probe_url != null;
}

// tag -> { up: true | false | null (not known yet), fails, oks (in a row),
//          at (last probe), next (when the next is due), ms, via }
let nodes = {};
let uplink_down = false;

// One request through each of the nodes, all at once: tag -> { ok, ms, via }.
// Any HTTP answer counts, whatever its status: the node carried it.
function probe(tags) {
	const one = (t, u) => `curl -s -o /dev/null -m ${PROBE_TIMEOUT} -w '%{http_code} %{time_total}' ` +
		`-x 'socks5h://${t}:probe@127.0.0.1:${S.probe_port}' '${u}' 2>/dev/null`;
	let cmd = '';
	for (let t in tags) {
		cmd += `( v=p; r=$(${one(t, S.probe_url)}); `;
		if (S.probe_url_backup)
			cmd += `case "$r" in 000*|"") v=b; r=$(${one(t, S.probe_url_backup)}) ;; esac; `;
		cmd += `echo "${t} $v $r" ) & `;
	}
	const p = fs.popen(cmd + 'wait', 'r');
	if (!p)
		return null;
	const out = p.read('all');
	p.close();
	let res = {};
	for (let line in split(out ?? '', '\n')) {
		const m = match(line, /^(\S+) ([pb]) ([0-9]{3}) ([0-9.]+)$/);
		if (m && m[3] != '000')
			res[m[1]] = { ok: true, ms: int(+m[4] * 1000), via: (m[2] == 'b') ? 'backup' : 'primary' };
	}
	for (let t in tags)
		res[t] ??= { ok: false };
	return res;
}

function uplink_ok() {
	for (let u in UPLINK)
		if (system(`curl -s -o /dev/null -m 4 '${u}' 2>/dev/null`) == 0)
			return true;
	return false;
}

// Probes the nodes that are due and keeps their state (see the top).
// `names`: tag -> node name, for the log.
function probe_due(tags, names) {
	for (let t in keys(nodes))
		if (!(t in tags))
			delete nodes[t];
	const now = time();
	const due = filter(tags, t => !(nodes[t]?.next > now));
	if (!length(due))
		return;
	const res = probe(due);
	if (!res)
		return;
	// Nothing answered, and no node that was not asked is up: the nodes,
	// or the way out? Not counted when the router reaches nothing at all.
	if (!length(filter(due, t => res[t].ok)) && !length(filter(tags, t => !(t in due) && nodes[t]?.up === true))) {
		const down = !uplink_ok();
		if (down != uplink_down)
			say(down ? 'node probes: the router reaches no domestic site either: the uplink, not the nodes; nothing is counted until it is back'
			         : 'node probes: the uplink is back');
		uplink_down = down;
		if (down)
			return;
	}
	else
		uplink_down = false;
	for (let t in due) {
		nodes[t] ??= { up: null, fails: 0, oks: 0 };
		const n = nodes[t], r = res[t];
		n.at = time();
		if (r.ok) {
			n.fails = 0;
			n.oks++;
			n.ms = r.ms;
			n.via = r.via;
			if (n.up !== true && (n.up == null || n.oks >= RISE)) {
				if (n.up === false)
					say(`node ${names[t] ?? t}: answers again (${r.ms} ms)`);
				n.up = true;
			}
			n.next = n.at + (n.up ? S.probe_interval : TICK);
		}
		else {
			n.oks = 0;
			n.fails++;
			n.ms = null;
			if (n.fails >= FAIL_LIMIT) {
				if (n.up !== false)
					say(`node ${names[t] ?? t}: no answer to ${n.fails} probes in a row, taken as down`);
				n.up = false;
				n.next = n.at + ((S.probe_interval < DOWN_INTERVAL) ? S.probe_interval : DOWN_INTERVAL);
			}
			else
				n.next = n.at + TICK;
		}
	}
	fs.writefile(NODES, sprintf('%J', { at: time(), nodes }));
}

// The member an ordered group should be held on by the watcher's own
// probes, or null for the balancer's fallback. Up: answered lately. A
// member that has failed fewer than FAIL_LIMIT probes in a row is still up;
// one not known yet is neither up nor down.
function desired_probed(grp, state, pins) {
	const tags = member_tags(grp);
	const pin = pins[grp.name];
	if (pin && (pin in tags))
		return pin;
	const up = t => nodes[t]?.up === true;
	const held = (state.override in tags) ? state.override : null;
	if (held && !grp.failback) {
		// sticky: given up only when it is down; while it is not known yet
		// (the watcher just started) it stays
		if (up(held) || nodes[held]?.up == null)
			return held;
	}
	// Nothing held and not every member known yet (the first probes of one
	// failed): no member is taken before the ones ahead of it in the list
	// are known, or a sticky group would keep whichever answered first.
	for (let t in tags) {
		if (up(t))
			return t;
		if (!held && nodes[t]?.up == null)
			return null;
	}
	// none is up; the one in use while it is not down yet
	return (held && nodes[held]?.up !== false) ? held : null;
}

// group name -> until when it settles (see the top); the watcher's memory
let settle_until = {};

function enforce(grp, pins) {
	const state = balancer(grp.tag);
	if (!state)
		return null;
	let want;
	if (grp.strategy == 'ordered' && own())
		want = desired_probed(grp, state, pins);
	else {
		const now = time();
		if (grp.strategy == 'ordered' && state.override == null && !(settle_until[grp.name] > now))
			// long enough for the first member's probes to come back after a start
			settle_until[grp.name] = now + SETTLE_ROUNDS * S.probe_interval;
		want = desired(grp, state, pins, settle_until[grp.name] > now);
	}
	if (want != state.override) {
		override(grp.tag, want);
		if (grp.strategy == 'ordered' && own())
			say(`group ${grp.name}: on ${want ? name_of(grp, want) : `its fallback (${grp.fallback})`} now` +
			    (state.override ? `, was on ${name_of(grp, state.override) ?? state.override}` : ''));
		state.override = want;
	}
	return state;
}

function cmd_list() {
	const pins = load(PINS, {});
	// what the watcher knows, while it is fresh (it writes after every probe)
	const known = load(NODES, {});
	if (own() && time() - (known.at ?? 0) < 2 * S.probe_interval + 60 && type(known.nodes) == 'object')
		nodes = known.nodes;
	let out = [];
	for (let grp in valid_groups()) {
		const state = balancer(grp.tag);
		const probed = (grp.strategy == 'ordered' && own());
		let current = null;
		if (state) {
			// the member held, else the one it would be (the watcher holds it
			// within a round); round robin / random have no single current member
			current = state.override ?? (probed ? desired_probed(grp, state, pins) : desired(grp, state, pins))
				?? ((grp.strategy == 'fastest') ? state.selects[0] : null);
		}
		let latency = {};
		if (probed)
			for (let m in grp.members)
				if (nodes[m.tag]?.up === true && nodes[m.tag].ms != null)
					latency[m.name] = nodes[m.tag].ms;
		push(out, {
			name: grp.name,
			remarks: grp.remarks,
			strategy: grp.strategy,
			members: map(grp.members, m => m.name),
			running: state != null,
			healthy: probed ? map(filter(grp.members, m => nodes[m.tag]?.up === true), m => m.name)
				: (state ? filter(map(state.selects, t => name_of(grp, t)), v => v != null) : []),
			// milliseconds of the last probe through each usable member (ordered groups)
			latency,
			current: current ? name_of(grp, current) : null,
			pinned: (pins[grp.name] && (pins[grp.name] in member_tags(grp))) ? name_of(grp, pins[grp.name]) : null,
			fallback: grp.fallback,
		});
	}
	print({ ok: true, groups: out, probe: probe_target(), probe_backup: S.probe_backup }, '\n');
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
	let dead_since = null;
	let last_switch = fs.stat(PROBE_STATE)?.mtime ?? 0;

	while (true) {
		S = settings();
		// long enough for a freshly started Xray to have finished its first probes
		const dead_limit = 3 * S.probe_interval + 60;
		const pins = load(PINS, {});
		const groups = valid_groups();
		if (own()) {
			let tags = [], names = {};
			for (let grp in groups)
				if (grp.strategy == 'ordered')
					for (let m in grp.members)
						if (!(m.tag in tags)) {
							push(tags, m.tag);
							names[m.tag] = m.name;
						}
			probe_due(tags, names);
		}
		let seen = 0, alive = 0;
		for (let grp in groups) {
			let state = null;
			if (grp.strategy == 'ordered' || pins[grp.name])
				state = enforce(grp, pins);
			else if (S.probe_backup)
				state = balancer(grp.tag);
			// the groups Xray checks: is its probe address the thing that fails?
			if (state && !(grp.strategy == 'ordered' && own())) {
				seen++;
				// a member with a failed probe lately is not usable but still
				// answers: the probe target is not the one at fault
				if (length(state.selects) || (grp.strategy == 'ordered' && length(alive_members(grp, state))))
					alive++;
			}
		}

		if (S.probe_backup) {
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
		system([ 'sleep', `${own() ? TICK : INTERVAL}` ]);
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
