'use strict';
'require baseclass';
'require xray-mosdns.common as xm';

/* The DNS counts on the "blocking and log" tab: queries and blocked ones by
 * day, the last 30 days (stats.uc; mosdns-x counts, the DNS watchdog adds
 * them up every 10 minutes). */

function num(n) {
	return String(n || 0).replace(/\B(?=(\d{3})+(?!\d))/g, ',');
}

function pct(blocked, queries) {
	return queries ? '%.1f%%'.format(blocked * 100 / queries) : '-';
}

return baseclass.extend({
	load: function() {
		return xm.exec('info.sh', [ 'stats' ]);
	},

	render: function(d) {
		d = d || {};
		var t = d.total || {}, today = d.today || {}, days = d.days || [];
		var rows = days.map(function(x) {
			return E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td' }, x.day),
				E('td', { 'class': 'td' }, num(x.queries)),
				E('td', { 'class': 'td' }, num(x.blocked)),
				E('td', { 'class': 'td' }, pct(x.blocked, x.queries))
			]);
		});

		return E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('解析与拦截统计')),
			E('div', { 'class': 'cbi-section-descr' }, (d.ok && days.length)
				? _('最近 30 天：解析 %s 次，拦截 %s 次（%s）。今天：解析 %s 次，拦截 %s 次（%s）。').format(
					num(t.queries), num(t.blocked), pct(t.blocked, t.queries),
					num(today.queries), num(today.blocked), pct(today.blocked, today.queries))
				: _('还没有统计数据：服务运行后每 10 分钟累计一次。')),
			(d.ok && d.running === false) ? E('p', { 'class': 'alert-message warning' },
				_('现在读不到 mosdns-x 的计数（服务没有运行，或还在用旧配置），数字停在上一次统计的时候。')) : '',
			days.length ? E('table', { 'class': 'table' }, [
				E('tr', { 'class': 'tr table-titles' }, [
					E('th', { 'class': 'th' }, _('日期')),
					E('th', { 'class': 'th' }, _('解析')),
					E('th', { 'class': 'th' }, _('拦截')),
					E('th', { 'class': 'th' }, _('拦截比例'))
				])
			].concat(rows)) : '',
			E('div', { 'class': 'cbi-section-descr' },
				_('解析是 mosdns-x 收到的全部查询（局域网和路由器自己的），拦截是订阅列表和“阻断”规则拦下的查询；查询日志关着也照样统计。每 10 分钟累计一次，每小时存到闪存（突然断电最多丢最近一小时的数），保留 30 天。') +
				(d.since ? ' ' + _('从 %s 开始统计。').format(d.since) : ''))
		]);
	}
});
