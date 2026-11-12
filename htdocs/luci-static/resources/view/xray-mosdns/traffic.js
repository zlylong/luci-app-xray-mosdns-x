'use strict';
'require view';
'require fs';
'require poll';
'require ui';

function fmtBytes(n) {
	n = Number(n) || 0;
	if (n < 1024) return n + ' B';
	if (n < 1048576) return (n / 1024).toFixed(1) + ' KiB';
	if (n < 1073741824) return (n / 1048576).toFixed(1) + ' MiB';
	return (n / 1073741824).toFixed(2) + ' GiB';
}

function fmtNum(n) {
	return String(Number(n) || 0).replace(/\B(?=(\d{3})+(?!\d))/g, ',');
}

return view.extend({
	load: function() {
		return fs.exec('/usr/libexec/xray-mosdns/traffic.sh', []);
	},

	render: function(res) {
		var self = this;
		var tbody = E('tbody');

		function render(res) {
			var data = {};
			try { data = JSON.parse((res && res.stdout) || '{}'); } catch (e) { data = {}; }
			var rows = data.data || [];
			var max = 1;
			rows.forEach(function(r) { max = Math.max(max, Number(r[2] || 0) + Number(r[4] || 0)); });

			while (tbody.firstChild)
				tbody.removeChild(tbody.firstChild);

			if (!rows.length) {
				tbody.appendChild(E('tr', {}, [E('td', { 'colspan': 5, 'class': 'td' }, _('No traffic data (is nlbwmon installed and running?)'))]));
				return;
			}
			rows.forEach(function(r) {
				var total = Number(r[2] || 0) + Number(r[4] || 0);
				var pct = Math.max(1, Math.round(total / max * 100));
				tbody.appendChild(E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td' }, r[0] || ''),
					E('td', { 'class': 'td' }, fmtNum(r[1])),
					E('td', { 'class': 'td' }, fmtBytes(r[2])),
					E('td', { 'class': 'td' }, fmtBytes(r[4])),
					E('td', { 'class': 'td' }, E('div', { 'style': 'background:#e8f5e9;border-radius:3px;height:14px;width:%s%%;min-width:2px'.format(pct) }))
				]));
			});
		}

		render(res);
		poll.add(function() {
			return fs.exec('/usr/libexec/xray-mosdns/traffic.sh', []).then(render);
		}, 15);

		return E('div', {}, [
			E('h2', {}, _('Traffic')),
			E('p', {}, _('Per-host traffic counters from nlbwmon (updated every 15 seconds).')), 
			E('table', { 'class': 'table' }, [
				E('tr', { 'class': 'tr table-titles' }, [
					E('th', { 'class': 'th' }, _('Host (MAC)')),
					E('th', { 'class': 'th' }, _('Connections')),
					E('th', { 'class': 'th' }, _('Download')),
					E('th', { 'class': 'th' }, _('Upload')),
					E('th', { 'class': 'th' }, _('Total'))
				]),
				tbody
			]),
			E('p', {}, E('button', {
				'class': 'cbi-button',
				'click': ui.createHandlerFn(self, function() {
					return fs.exec('/usr/libexec/xray-mosdns/traffic.sh', []).then(render);
				})
			}, _('Refresh')))
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
