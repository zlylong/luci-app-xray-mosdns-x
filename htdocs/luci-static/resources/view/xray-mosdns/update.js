'use strict';
'require view';
'require fs';
'require uci';
'require ui';

var SCRIPT = '/usr/libexec/xray-mosdns/update.sh';

function fmtBytes(n) {
	n = Number(n) || 0;
	if (n < 1024) return n + ' B';
	if (n < 1048576) return (n / 1024).toFixed(1) + ' KiB';
	if (n < 1073741824) return (n / 1048576).toFixed(1) + ' MiB';
	return (n / 1073741824).toFixed(2) + ' GiB';
}

function run(action, args) {
	return fs.exec(SCRIPT, [ action ].concat(args || [])).then(function(res) {
		var out = {};
		try { out = JSON.parse((res && res.stdout) || '{}'); } catch (e) { out = { ok: false, error: 'bad output' }; }
		return out;
	});
}

function statusLabel(update) {
	return update
		? E('span', { 'class': 'label label-warning' }, _('可更新'))
		: E('span', { 'class': 'label label-success' }, _('已是最新'));
}

return view.extend({
	load: function() {
		return Promise.all([
			uci.load('xray-mosdns'),
			run('check'),
			run('cron-status')
		]);
	},

	render: function(res) {
		var data = (res && res[1]) || {};
		var cron = (res && res[2]) || {};
		var local = data.local || {};
		var remote = data.remote || {};

		var info = E('table', { 'class': 'table' }, []);
		var output = E('pre', { 'style': 'white-space:pre-wrap;max-height:180px;overflow:auto;background:#f5f5f5;padding:8px;border-radius:4px;' }, []);

		function row(name, cur, rem, update) {
			info.appendChild(E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td', 'style': 'width:120px' }, name),
				E('td', { 'class': 'td' }, cur || '-'),
				E('td', { 'class': 'td' }, rem || '-'),
				E('td', { 'class': 'td' }, statusLabel(update))
			]));
		}

		function xrayUpdate() {
			return !!remote.xray && String(local.xray || '').indexOf(remote.xray) < 0;
		}
		function mosdnsUpdate() {
			return !!remote.mosdns && String(local.mosdns || '').indexOf(remote.mosdns) < 0;
		}
		function geoUpdate() {
			return !!remote.geo && local.geo_version !== remote.geo;
		}

		function fill(d, c) {
			d = d || {}; c = c || {};
			var L = d.local || {}, R = d.remote || {};
			info.replaceChildren();
			info.appendChild(E('tr', { 'class': 'tr table-titles' }, [
				E('th', { 'class': 'th' }, _('组件')),
				E('th', { 'class': 'th' }, _('当前版本')),
				E('th', { 'class': 'th' }, _('远端版本')),
				E('th', { 'class': 'th' }, _('状态'))
			]));
			row('Xray', L.xray, R.xray, !!R.xray && String(L.xray || '').indexOf(R.xray) < 0);
			row('mosdns', L.mosdns, R.mosdns, !!R.mosdns && String(L.mosdns || '').indexOf(R.mosdns) < 0);
			row(_('geo 数据'), (L.geo_version || _('未记录')) + ' (' + fmtBytes(L.geosite) + ' / ' + fmtBytes(L.geoip) + ')',
				R.geo, !!R.geo && L.geo_version !== R.geo);
			cronRow.textContent = c.enabled ? _('已启用（每天 %s:00）').format(c.hour || '?') : _('未启用');
		}

		var cronRow = E('span', { 'class': 'label' }, cron.enabled ? _('已启用（每天 %s:00）').format(cron.hour) : _('未启用'));

		function refresh() {
			return Promise.all([ run('check'), run('cron-status') ]).then(function(r) {
				fill(r[0], r[1]);
			});
		}

		fill(data, cron);

		var checkBtn = E('button', { 'class': 'cbi-button cbi-button-neutral' }, _('刷新版本'));
		checkBtn.addEventListener('click', function() {
			output.textContent = _('正在查询远端版本…');
			refresh().then(function() { output.textContent = _('远端版本已刷新'); });
		});

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

		// ---- scheduled geo update
		var autoChk = E('input', { 'type': 'checkbox', 'class': 'cbi-input-checkbox' });
		if (uci.get('xray-mosdns', 'global', 'geo_auto_update') === '1') autoChk.checked = true;

		var hourSel = E('select', { 'class': 'cbi-input-select' });
		for (var h = 0; h < 24; h++) {
			var o = E('option', { 'value': String(h) }, String(h) + ':00');
			if (String(h) === String(uci.get('xray-mosdns', 'global', 'geo_update_hour') || '4')) o.selected = true;
			hourSel.appendChild(o);
		}

		var savePlan = E('button', { 'class': 'cbi-button cbi-button-apply' }, _('保存计划'));
		savePlan.addEventListener('click', function() {
			uci.set('xray-mosdns', 'global', 'geo_auto_update', autoChk.checked ? '1' : '0');
			uci.set('xray-mosdns', 'global', 'geo_update_hour', hourSel.value);
			uci.save().then(function() { return uci.apply(); }).then(function() {
				return run(autoChk.checked ? 'cron-install' : 'cron-remove');
			}).then(function(out) {
				output.textContent = JSON.stringify(out, null, 2);
				ui.addNotification(null, E('p', {}, out.ok ? out.message : (out.error || _('保存失败'))), out.ok ? 'info' : 'error');
				return run('cron-status').then(function(c) { fill(data, c); });
			});
		});

		return E('div', {}, [
			E('h2', {}, _('更新')),
			E('p', {}, _('在线更新 Xray、mosdns-x 与 geo 规则数据（来源：GitHub 最新 release）。'
				+ '更新 Xray 会影响 PassWall（共用 /usr/bin/xray），更新后请重启相关服务。')),
			info,
			E('p', {}, [ checkBtn, ' ', btn(_('更新 geo 数据'), 'geo'), ' ', btn(_('更新 Xray'), 'xray'), ' ', btn(_('更新 mosdns-x'), 'mosdns') ]),
			E('h2', {}, _('geo 定时更新')),
			E('p', { 'class': 'cbi-value-description' },
				_('每天定时检查并更新 geo 数据（对比远端 release 版本，相同则跳过）。当前：') , cronRow),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, _('启用定时更新')),
				E('div', { 'class': 'cbi-value-field' }, [ autoChk, ' ', _('每天'), ' ', hourSel, ' ', savePlan ])
			]),
			E('h2', {}, _('执行结果')),
			output
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
