'use strict';

var THEME_VERSION = '0.9.0';

function themeLink() {
	return E('link', {
		'rel': 'stylesheet',
		'href': '/luci-static/resources/xray-mosdns/theme.css?v=' + THEME_VERSION
	});
}

function lamp(state, label, value) {
	var cls = 'xmx-lamp';
	if (state === 'on') cls += ' is-on';
	else if (state === 'warn') cls += ' is-warn';
	else if (state === 'alert') cls += ' is-alert';
	return E('span', { 'class': cls }, [
		E('i'),
		E('strong', {}, label),
		value != null ? E('span', {}, value) : ''
	]);
}

function head(opts) {
	var lamps = opts.lamps;
	if (lamps && !lamps.nodeType)
		lamps = E('div', { 'class': 'xmx-lamps' }, Array.isArray(lamps) ? lamps : [ lamps ]);
	return E('header', { 'class': 'xmx-head' }, [
		E('div', { 'class': 'xmx-head-main' }, [
			E('h1', { 'class': 'xmx-title' }, opts.title),
			opts.lede ? E('p', { 'class': 'xmx-lede' }, opts.lede) : ''
		]),
		lamps || ''
	]);
}

function section(title, body, note) {
	var noteEl = '';
	if (note)
		noteEl = note.nodeType ? note : E('span', { 'class': 'xmx-note' }, note);
	return E('section', { 'class': 'xmx-section' }, [
		E('div', { 'class': 'xmx-section-head' }, [
			E('h2', {}, title),
			noteEl
		]),
		E('div', { 'class': 'xmx-section-body' }, body)
	]);
}

function page(opts, children) {
	return E('div', { 'class': 'xmx' }, [ themeLink(), head(opts) ]
		.concat(children || []));
}

function station(name, value, state) {
	var cls = 'xmx-station';
	if (state === 'off') cls += ' is-off';
	else if (state === 'standby') cls += ' is-standby';
	else if (state === 'alert') cls += ' is-alert';
	return E('div', { 'class': cls }, [
		E('span', { 'class': 'xmx-node' }),
		E('b', {}, name),
		value ? E('small', {}, value) : ''
	]);
}

function link(state) {
	return E('span', { 'class': 'xmx-link' + (state ? ' is-' + state : '') });
}

function lane(id, stations, live) {
	return E('div', { 'class': 'xmx-lane' + (live ? ' is-live' : '') }, [
		E('span', { 'class': 'xmx-lane-id' }, id),
		E('div', { 'class': 'xmx-stations' }, stations)
	]);
}

function btn(label, cls) {
	return E('button', { 'class': 'xmx-btn' + (cls ? ' ' + cls : ''), 'type': 'button' }, label);
}

function field(label, control, hint) {
	return E('div', { 'class': 'xmx-row' }, [
		E('span', { 'class': 'xmx-muted xmx-small', 'style': 'min-width:88px' }, label),
		control,
		hint ? E('span', { 'class': 'xmx-muted xmx-small' }, hint) : ''
	]);
}

return {
	version: THEME_VERSION,
	themeLink: themeLink,
	head: head,
	section: section,
	page: page,
	lamp: lamp,
	station: station,
	link: link,
	lane: lane,
	btn: btn,
	field: field
};
