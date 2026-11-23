'use strict';
'require baseclass';
'require uci';
'require ui';
'require poll';
'require xray-mosdns.common as xm';

/* The "query log" tab of the DNS page: recent DNS queries and their results.
 * How each one was handled (direct, proxy, blocked) is not known: mosdns-x
 * crashes on the query_summary plugins that could record it. */

/* answers that mean the lookup itself went wrong (NXDOMAIN is an answer:
 * the name does not exist, or it was blocked) */
var FAILED = { 'SERVFAIL': true, 'REFUSED': true, 'NO RESPONSE': true };

function fmtTime(ts) {
	if (!ts) return '-';
	var d = new Date(ts * 1000);
	return '%02d:%02d:%02d'.format(d.getHours(), d.getMinutes(), d.getSeconds());
}

return baseclass.extend({
	load: function() {
		return xm.exec('querylog.uc', [ '200' ]);
	},

	/* the tab's content; needs the config loaded */
	render: function(data) {
		var enabled = (uci.get(xm.CONF, 'dns', 'query_log') === '1');
		var body = E('tbody');
		var summary = E('div', { 'class': 'cbi-section-descr' });
		var filter = E('input', {
			'type': 'text', 'class': 'cbi-input-text', 'style': 'max-width:20em',
			'placeholder': _('域名或客户端地址')
		});
		var follow = E('input', { 'type': 'checkbox', 'id': 'xm-ql-follow', 'checked': '' });

		function show(d) {
			var entries = (d && d.entries) || [];
			summary.textContent = (d && d.total)
				? _('最近的记录里匹配到 %d 条。').format(d.total)
				: (enabled ? _('还没有记录。') : '');

			body.replaceChildren.apply(body, entries.length ? entries.map(function(e) {
				var failed = (FAILED[e.rcode] || /^RCODE/.test(e.rcode));
				return E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td' }, fmtTime(e.ts)),
					E('td', { 'class': 'td' }, e.client || '-'),
					E('td', { 'class': 'td', 'style': 'word-break:break-all' }, e.name),
					E('td', { 'class': 'td' }, e.type),
					E('td', { 'class': 'td', 'title': e.error || '' }, failed ? xm.badge(e.rcode, 'warn') : e.rcode),
					E('td', { 'class': 'td' }, e.ms != null ? '%.1f ms'.format(e.ms) : '-')
				]);
			}) : [ E('tr', { 'class': 'tr placeholder' }, [
				E('td', { 'class': 'td', 'colspan': 6 }, E('em', {}, _('没有匹配的记录')))
			]) ]);
		}

		var last = data || {};
		function refresh() {
			return xm.exec('querylog.uc', [ '200', filter.value.trim() ]).then(function(d) {
				if (d && d.ok !== false) {
					last = d;
					show(d);
				}
			});
		}

		/* who asked most and for what, in what the log holds: on demand,
		 * it reads the whole log */
		var topBox = E('div', {});
		function pct(a, b) { return b ? '%d%%'.format(Math.round(a * 100 / b)) : '-'; }
		function topTable(title, rows, key) {
			return E('table', { 'class': 'table', 'style': 'margin-bottom:1em' }, [
				E('tr', { 'class': 'tr table-titles' }, [
					E('th', { 'class': 'th' }, title),
					E('th', { 'class': 'th' }, _('查询')),
					E('th', { 'class': 'th' }, _('其中“不存在”'))
				])
			].concat(rows.map(function(r) {
				var label = (key === 'client' && r.host) ? '%s（%s）'.format(r.host, r.client) : r[key];
				return E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td', 'style': 'word-break:break-all' }, E('a', {
						'href': '#', 'title': _('在下面的记录里筛选'),
						'click': function(ev) { ev.preventDefault(); filter.value = r[key]; refresh(); }
					}, label)),
					E('td', { 'class': 'td' }, String(r.queries)),
					E('td', { 'class': 'td' }, '%d（%s）'.format(r.nxdomain, pct(r.nxdomain, r.queries)))
				]);
			})));
		}
		function showTop() {
			return xm.exec('querylog.uc', [ 'top' ]).then(function(t) {
				if (!t || t.ok === false || !t.queries) {
					topBox.replaceChildren(E('em', {}, _('日志里还没有查询。')));
					return;
				}
				topBox.replaceChildren(
					E('div', { 'class': 'cbi-section-descr' },
						_('日志里现有的 %d 条查询（%s 到 %s）。“不存在”多的域名通常是被拦截的，或者设备在反复查一个查不到的名字。点一项可以在下面筛选。')
							.format(t.queries, fmtTime(t.from), fmtTime(t.to))),
					topTable(_('客户端'), t.clients || [], 'client'),
					topTable(_('域名'), t.names || [], 'name'));
			});
		}

		filter.addEventListener('keydown', function(ev) {
			if (ev.key === 'Enter') {
				ev.preventDefault();
				refresh();
			}
		});
		show(last);

		var node = E('div', { 'class': 'cbi-section' }, [
			E('div', { 'class': 'cbi-section-descr' },
				_('mosdns-x 最近处理的 DNS 查询：谁查了什么、结果如何、用了多久。每条查询是直连、代理还是被拦截，这里看不到：mosdns-x 能记录这一点的插件有缺陷，一配置 mosdns-x 就无法启动。被拦截的域名显示为 NXDOMAIN（拦截方式为 0.0.0.0 时是 NOERROR）。')),
			enabled ? '' : E('p', { 'class': 'alert-message warning' },
				_('查询日志没有开启。在“拦截与日志”标签里打开“记录查询”，保存并应用后这里才会有内容。')),
			E('div', {}, [
				filter,
				E('button', {
					'class': 'cbi-button cbi-button-action', 'style': 'margin-left:.5em',
					'click': ui.createHandlerFn(this, refresh)
				}, _('查询')),
				E('span', { 'style': 'margin-left:1em' }, [
					follow, E('label', { 'for': 'xm-ql-follow' }, ' ' + _('每 5 秒刷新'))
				])
			]),
			enabled ? E('div', { 'style': 'margin:.8em 0' }, [
				E('button', { 'class': 'cbi-button', 'click': ui.createHandlerFn(this, showTop) }, _('查询排行')),
				topBox
			]) : '',
			summary,
			E('table', { 'class': 'table' }, [
				E('thead', {}, E('tr', { 'class': 'tr table-titles' }, [
					E('th', { 'class': 'th' }, _('时间')),
					E('th', { 'class': 'th' }, _('客户端')),
					E('th', { 'class': 'th' }, _('域名')),
					E('th', { 'class': 'th' }, _('类型')),
					E('th', { 'class': 'th' }, _('结果')),
					E('th', { 'class': 'th' }, _('耗时'))
				])),
				body
			])
		]);

		/* only while the tab is the one on screen */
		function onScreen() {
			var pane = node.closest('[data-tab]');
			return !!pane && pane.getAttribute('data-tab-active') === 'true';
		}

		poll.add(function() {
			return (enabled && follow.checked && onScreen()) ? refresh() : Promise.resolve();
		}, 5);

		return node;
	}
});
