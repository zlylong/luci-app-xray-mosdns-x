'use strict';
'require view';
'require uci';
'require ui';
'require poll';
'require xray-mosdns.common as xm';

var KINDS = {
	proxy: [ _('代理'), 'warn' ],
	direct: [ _('直连'), 'ok' ],
	block: [ _('拦截'), 'bad' ],
	fallback: [ _('自动判断'), null ],
	lan: [ _('本地'), null ]
};

function fmtTime(ts) {
	if (!ts) return '-';
	var d = new Date(ts * 1000);
	return '%02d:%02d:%02d'.format(d.getHours(), d.getMinutes(), d.getSeconds());
}

return view.extend({
	load: function() {
		return Promise.all([
			uci.load(xm.CONF),
			xm.exec('querylog.uc', [ '200' ])
		]);
	},

	render: function(res) {
		var enabled = (uci.get(xm.CONF, 'dns', 'query_log') === '1');
		var body = E('tbody');
		var summary = E('div', { 'class': 'cbi-section-descr' });
		var filter = E('input', {
			'type': 'text', 'class': 'cbi-input-text', 'style': 'max-width:20em',
			'placeholder': _('域名或客户端地址')
		});
		var kindSel = E('select', { 'class': 'cbi-input-select', 'style': 'width:auto;margin-left:.5em' },
			[ E('option', { 'value': '' }, _('全部')) ].concat(Object.keys(KINDS).map(function(k) {
				return E('option', { 'value': k }, KINDS[k][0]);
			})));
		var follow = E('input', { 'type': 'checkbox', 'id': 'xm-ql-follow', 'checked': '' });

		function show(data) {
			var entries = (data && data.entries) || [];
			var kind = kindSel.value;
			if (kind)
				entries = entries.filter(function(e) { return e.kind === kind; });

			var c = (data && data.counts) || {};
			summary.textContent = (data && data.total)
				? _('最近的记录里匹配到 %d 条：代理 %d，直连 %d，拦截 %d，自动判断 %d，本地 %d。')
					.format(data.total, c.proxy || 0, c.direct || 0, c.block || 0, c.fallback || 0, c.lan || 0)
				: (enabled ? _('还没有记录。') : '');

			body.replaceChildren.apply(body, entries.length ? entries.map(function(e) {
				var k = KINDS[e.kind] || [ e.kind, null ];
				var failed = (e.rcode !== 'NOERROR' && e.kind !== 'block');
				return E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td' }, fmtTime(e.ts)),
					E('td', { 'class': 'td' }, e.client || '-'),
					E('td', { 'class': 'td', 'style': 'word-break:break-all' }, e.name),
					E('td', { 'class': 'td' }, e.type),
					E('td', { 'class': 'td' }, xm.badge(k[0], k[1])),
					E('td', { 'class': 'td', 'title': e.error || '' }, failed ? xm.badge(e.rcode, 'warn') : e.rcode),
					E('td', { 'class': 'td' }, e.ms != null ? '%.1f ms'.format(e.ms) : '-')
				]);
			}) : [ E('tr', { 'class': 'tr placeholder' }, [
				E('td', { 'class': 'td', 'colspan': 7 }, E('em', {}, _('没有匹配的记录')))
			]) ]);
		}

		var last = res[1] || {};
		function refresh() {
			return xm.exec('querylog.uc', [ '200', filter.value.trim() ]).then(function(d) {
				if (d && d.ok !== false) {
					last = d;
					show(d);
				}
			});
		}

		filter.addEventListener('keydown', function(ev) {
			if (ev.key === 'Enter') {
				ev.preventDefault();
				refresh();
			}
		});
		kindSel.addEventListener('change', function() { show(last); });
		show(last);

		poll.add(function() {
			return (enabled && follow.checked) ? refresh() : Promise.resolve();
		}, 5);

		var page = [
			E('h2', {}, _('查询日志')),
			E('div', { 'class': 'cbi-map-descr' },
				_('mosdns-x 最近处理的 DNS 查询：谁查了什么、按哪条路处理、结果如何。“自动判断”是没有命中任何规则的域名，先问国内上游，返回国内地址就直连，否则改用代理一侧的结果。'))
		];

		if (!enabled)
			page.push(E('p', { 'class': 'alert-message warning' },
				_('查询日志没有开启。到“DNS”页的“日志”标签里打开“记录查询”，保存并应用后这里才会有内容。')));

		page.push(E('div', { 'class': 'cbi-section' }, [
			E('div', {}, [
				filter, kindSel,
				E('button', {
					'class': 'cbi-button cbi-button-action', 'style': 'margin-left:.5em',
					'click': ui.createHandlerFn(this, refresh)
				}, _('查询')),
				E('span', { 'style': 'margin-left:1em' }, [
					follow, E('label', { 'for': 'xm-ql-follow' }, ' ' + _('每 5 秒刷新'))
				])
			]),
			summary,
			E('table', { 'class': 'table' }, [
				E('thead', {}, E('tr', { 'class': 'tr table-titles' }, [
					E('th', { 'class': 'th' }, _('时间')),
					E('th', { 'class': 'th' }, _('客户端')),
					E('th', { 'class': 'th' }, _('域名')),
					E('th', { 'class': 'th' }, _('类型')),
					E('th', { 'class': 'th' }, _('处理')),
					E('th', { 'class': 'th' }, _('结果')),
					E('th', { 'class': 'th' }, _('耗时'))
				])),
				body
			])
		]));

		return E('div', {}, page);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
