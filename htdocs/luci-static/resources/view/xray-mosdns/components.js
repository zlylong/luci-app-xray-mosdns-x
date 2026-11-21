'use strict';
'require view';
'require uci';
'require ui';
'require xray-mosdns.common as xm';

function mosdnsText(l) {
	var text = l.mosdns || '-';
	if (l.mosdns_kind && l.mosdns_kind !== 'mosdns-x')
		text += ' ' + _('（官方 mosdns，不是 mosdns-x）');
	else if (l.mosdns_kind === 'mosdns-x' && l.mosdns_date)
		text += ' ' + _('（build %s）').format(l.mosdns_date);
	return text;
}

return view.extend({
	load: function() {
		return Promise.all([
			uci.load(xm.CONF),
			xm.exec('info.sh', [ 'versions' ]),
			xm.exec('info.sh', [ 'cron-status' ])
		]);
	},

	render: function(res) {
		var verBox = E('div');
		var output = E('pre', { 'style': 'white-space:pre-wrap;max-height:12em;overflow:auto;display:none' });
		var cronState = E('span');

		function say(text) {
			output.style.display = '';
			output.textContent = text;
		}

		/* `versions` returns the local values flat, `check` returns { local, remote } */
		function renderVersions(d) {
			var l = (d && d.local) || d || {}, r = (d && d.remote) || {};
			var hasRemote = !!(d && d.remote);
			function st(diff) {
				if (!hasRemote) return '-';
				return diff ? xm.badge(_('可更新'), 'warn') : xm.badge(_('已是最新'), 'ok');
			}
			var mosDiff = (l.mosdns_kind !== 'mosdns-x') ? !!r.mosdns : (!!r.mosdns_date && l.mosdns_date !== r.mosdns_date);
			var rows = [
				[ 'Xray', l.xray, r.xray, st(!!r.xray_num && l.xray_num !== r.xray_num) ],
				[ 'mosdns-x', mosdnsText(l), r.mosdns, st(mosDiff) ],
				[ _('geo 数据'), '%s（%s / %s）'.format(l.geo_version || _('未记录'), xm.fmtBytes(l.geosite), xm.fmtBytes(l.geoip)),
					r.geo, st(!!r.geo && l.geo_version !== r.geo) ]
			];
			verBox.replaceChildren(E('table', { 'class': 'table' }, [
				E('tr', { 'class': 'tr table-titles' }, [
					E('th', { 'class': 'th' }, _('组件')),
					E('th', { 'class': 'th' }, _('当前版本')),
					E('th', { 'class': 'th' }, _('最新版本')),
					E('th', { 'class': 'th' }, _('状态'))
				])
			].concat(rows.map(function(row) {
				return E('tr', { 'class': 'tr' }, row.map(function(c) {
					return E('td', { 'class': 'td' }, c || '-');
				}));
			}))));
		}

		function renderCron(c) {
			cronState.replaceChildren(c && c.enabled
				? xm.badge(_('已启用，每天 %s:00').format(c.hour || '?'), 'ok')
				: xm.badge(_('未启用')));
		}

		renderVersions(res[1]);
		renderCron(res[2]);

		function check() {
			say(_('正在查询最新版本…'));
			return xm.exec('info.sh', [ 'check' ]).then(function(d) {
				renderVersions(d);
				say(d.ok === false ? (d.error || _('查询失败')) : _('已刷新'));
			});
		}

		function update(action, name) {
			ui.showModal(_('更新 %s').format(name), [
				E('p', {}, _('将从 GitHub 下载最新版本并替换现有文件，旧文件备份到 /root/pw-backup/xray-mosdns-update/。更新 Xray 会影响共用 /usr/bin/xray 的其他插件。')),
				E('div', { 'class': 'right' }, [
					E('button', { 'class': 'btn', 'click': ui.hideModal }, _('取消')),
					' ',
					E('button', {
						'class': 'btn cbi-button-positive',
						'click': function() {
							ui.hideModal();
							say(_('正在更新 %s…').format(name));
							return xm.exec('update.sh', [ action ]).then(function(out) {
								say(out.ok ? (out.message || _('更新完成')) : (out.error || _('更新失败')));
								return xm.exec('info.sh', [ 'versions' ]).then(renderVersions);
							});
						}
					}, _('更新'))
				])
			]);
		}

		var autoChk = E('input', { 'type': 'checkbox', 'id': 'xm-geo-auto' });
		autoChk.checked = (uci.get(xm.CONF, 'global', 'geo_auto_update') === '1');
		var hourSel = E('select', { 'class': 'cbi-input-select', 'style': 'width:auto' });
		for (var h = 0; h < 24; h++)
			hourSel.appendChild(E('option', { 'value': String(h) }, '%d:00'.format(h)));
		hourSel.value = String(uci.get(xm.CONF, 'global', 'geo_update_hour') || '4');

		function saveSchedule() {
			uci.set(xm.CONF, 'global', 'geo_auto_update', autoChk.checked ? '1' : '0');
			uci.set(xm.CONF, 'global', 'geo_update_hour', hourSel.value);
			return uci.save().then(function() { return uci.apply(); }).then(function() {
				return xm.exec('update.sh', [ autoChk.checked ? 'cron-install' : 'cron-remove' ]);
			}).then(function(out) {
				say(out.ok ? out.message : (out.error || _('保存失败')));
				return xm.exec('info.sh', [ 'cron-status' ]).then(renderCron);
			});
		}

		function btn(label, fn) {
			return E('button', {
				'class': 'cbi-button cbi-button-action',
				'style': 'margin-right:.5em',
				'click': ui.createHandlerFn(this, fn)
			}, label);
		}

		return E('div', {}, [
			E('h2', {}, _('组件更新')),
			E('div', { 'class': 'cbi-map-descr' },
				_('在线更新 Xray、mosdns-x 和 geo 规则数据，来源是各自在 GitHub 上的最新 release。')),
			xm.section(_('版本'), [
				verBox,
				E('div', { 'class': 'cbi-page-actions', 'style': 'text-align:left' }, [
					btn(_('检查更新'), check),
					btn(_('更新 geo 数据'), function() { update('geo', _('geo 数据')); }),
					btn(_('更新 Xray'), function() { update('xray', 'Xray'); }),
					btn(_('更新 mosdns-x'), function() { update('mosdns', 'mosdns-x'); })
				]),
				output
			]),
			xm.section(_('geo 数据定时更新'), [
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title', 'for': 'xm-geo-auto' }, _('自动更新')),
					E('div', { 'class': 'cbi-value-field' }, [
						autoChk, ' ', _('每天'), ' ', hourSel, ' ',
						btn(_('保存计划'), saveSchedule), cronState
					])
				])
			], _('与最新 release 版本相同时跳过下载。'))
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
