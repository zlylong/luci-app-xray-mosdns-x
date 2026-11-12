'use strict';
'require view';
'require fs';
'require ui';

var SCRIPT = '/usr/libexec/xray-mosdns/update.sh';

function fmtBytes(n) {
	n = Number(n) || 0;
	if (n < 1024) return n + ' B';
	if (n < 1048576) return (n / 1024).toFixed(1) + ' KiB';
	if (n < 1073741824) return (n / 1048576).toFixed(1) + ' MiB';
	return (n / 1073741824).toFixed(2) + ' GiB';
}

function run(action) {
	return fs.exec(SCRIPT, [ action ]).then(function(res) {
		var out = {};
		try { out = JSON.parse((res && res.stdout) || '{}'); } catch (e) { out = { ok: false, error: 'bad output' }; }
		return out;
	});
}

return view.extend({
	load: function() {
		return run('versions');
	},

	render: function(res) {
		var st = res || {};
		var info = E('table', { 'class': 'table' }, []);
		var output = E('pre', { 'style': 'white-space:pre-wrap;max-height:200px;overflow:auto;background:#f5f5f5;padding:8px;border-radius:4px;' }, []);

		function row(label, value) {
			info.appendChild(E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td', 'style': 'width:160px' }, label),
				E('td', { 'class': 'td' }, value || '-')
			]));
		}

		function fillVersions(v) {
			info.replaceChildren();
			row(_('Xray'), v.xray);
			row(_('mosdns'), v.mosdns);
			row(_('geosite.dat'), fmtBytes(v.geosite));
			row(_('geoip.dat'), fmtBytes(v.geoip));
		}

		fillVersions(st);

		function refresh() {
			return run('versions').then(fillVersions);
		}

		function doUpdate(action) {
			ui.showModal(_('确认更新'), [
				E('p', {}, _('将联网下载最新版本并替换现有文件，旧文件会备份到 /root/pw-backup/xray-mosdns-update/。确定继续？')),
				E('div', { 'class': 'right' }, [
					E('button', { 'class': 'btn', 'click': function() { ui.hideModal(); } }, _('取消')),
					' ',
					E('button', {
						'class': 'cbi-button cbi-button-apply',
						'click': function() {
							ui.hideModal();
							output.textContent = _('正在更新…');
							run(action).then(function(out) {
								output.textContent = JSON.stringify(out, null, 2);
								ui.addNotification(null, E('p', {}, out.ok ? (out.message || _('更新完成')) : (out.error || _('更新失败'))),
									out.ok ? 'info' : 'error');
								refresh();
							});
						}
					}, _('继续'))
				])
			]);
		}

		function btn(label, action, cls) {
			var b = E('button', { 'class': 'cbi-button ' + (cls || 'cbi-button-action') }, label);
			b.addEventListener('click', function() { doUpdate(action); });
			return b;
		}

		var check = E('button', { 'class': 'cbi-button cbi-button-neutral' }, _('刷新版本'));
		check.addEventListener('click', refresh);

		return E('div', {}, [
			E('h2', {}, _('更新')),
			E('p', {}, _('在线更新 Xray、mosdns-x 与 geo 规则数据（来源：GitHub 最新 release）。'
				+ '更新 Xray 会影响 PassWall（共用 /usr/bin/xray），更新后请重启相关服务。')),
			info,
			E('p', {}, [ check, ' ', btn(_('更新 geo 数据'), 'geo'), ' ', btn(_('更新 Xray'), 'xray'), ' ', btn(_('更新 mosdns-x'), 'mosdns') ]),
			E('h2', {}, _('执行结果')),
			output
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
