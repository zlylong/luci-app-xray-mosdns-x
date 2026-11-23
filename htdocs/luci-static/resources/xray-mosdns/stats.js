'use strict';
'require baseclass';
'require xray-mosdns.common as xm';

/* The DNS counts on the "blocking and log" tab: queries and blocked ones,
 * summed over the last 30 days, and today's (stats.uc keeps them by day;
 * mosdns-x counts, the DNS watchdog adds them up every 10 minutes). A row
 * per day made the page long without telling more. */

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
		var row = function(label, x) {
			return E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td' }, label),
				E('td', { 'class': 'td' }, num(x.queries)),
				E('td', { 'class': 'td' }, num(x.blocked)),
				E('td', { 'class': 'td' }, pct(x.blocked, x.queries))
			]);
		};

		return E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('解析与拦截统计')),
			(d.ok && days.length) ? '' : E('div', { 'class': 'cbi-section-descr' },
				_('还没有统计数据：服务运行后每 10 分钟累计一次。')),
			(d.ok && d.running === false) ? E('p', { 'class': 'alert-message warning' },
				_('现在读不到 mosdns-x 的计数（服务没有运行，或还在用旧配置），数字停在上一次统计的时候。')) : '',
			(d.ok && days.length) ? E('table', { 'class': 'table' }, [
				E('tr', { 'class': 'tr table-titles' }, [
					E('th', { 'class': 'th' }, _('时间')),
					E('th', { 'class': 'th' }, _('解析')),
					E('th', { 'class': 'th' }, _('拦截')),
					E('th', { 'class': 'th' }, _('拦截比例'))
				]),
				row(_('最近 30 天'), t),
				row(_('今天'), today)
			]) : '',
			E('div', { 'class': 'cbi-section-descr' },
				_('解析是 mosdns-x 收到的全部查询（局域网和路由器自己的），拦截是订阅列表和“阻断”规则拦下的查询；查询日志关着也照样统计。每 10 分钟累计一次，每小时存到闪存（突然断电最多丢最近一小时的数），保留 30 天。') +
				(d.since ? ' ' + _('从 %s 开始统计。').format(d.since) : ''))
		]);
	}
});
