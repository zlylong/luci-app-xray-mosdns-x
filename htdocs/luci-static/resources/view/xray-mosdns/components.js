'use strict';
'require view';
'require uci';
'require ui';
'require xray-mosdns.common as xm';

/* cron day of the week (0 = Sunday), '*' = every day */
var DAYS = [ [ '*', _('每天') ], [ '1', _('每周一') ], [ '2', _('每周二') ], [ '3', _('每周三') ],
	[ '4', _('每周四') ], [ '5', _('每周五') ], [ '6', _('每周六') ], [ '0', _('每周日') ] ];

function dayName(d) {
	for (var i = 0; i < DAYS.length; i++)
		if (DAYS[i][0] === String(d))
			return DAYS[i][1];
	return _('每天');
}

var RELEASES = 'https://github.com/zlylong/luci-app-xray-mosdns-x/releases';

function releaseLink(tag, text) {
	return E('a', { 'href': RELEASES + '/tag/' + encodeURIComponent(tag), 'target': '_blank', 'rel': 'noreferrer noopener' }, text || tag);
}

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
		var appNote = E('div', { 'class': 'cbi-map-descr', 'style': 'display:none' });
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
			/* this package: a check only says whether a newer release is out
			 * (the last answer is kept, so it shows without a check too); it
			 * is installed by hand */
			var appLatest = hasRemote ? r.app : l.app_latest;
			var appNewer = hasRemote ? r.app_newer : l.app_newer;
			appNote.style.display = (appLatest && appNewer) ? '' : 'none';
			if (appLatest && appNewer)
				appNote.replaceChildren(
					_('本插件有新版本 %s：').format(appLatest),
					releaseLink(appLatest, _('发布说明和安装包')),
					_('。下载其中的 .apk 文件，在路由器上执行 apk add --allow-untrusted <文件名> 即可升级，配置保留。'));
			var rows = [
				[ _('本插件（luci-app-xray-mosdns-x）'), l.app || _('未知'),
					appLatest ? releaseLink(appLatest) : '-',
					appLatest ? (appNewer ? xm.badge(_('有新版本'), 'warn') : xm.badge(_('已是最新'), 'ok')) : '-' ],
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
				? xm.badge(_('已启用，%s %s:00').format(dayName(c.day), c.hour || '?'), 'ok')
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
		var daySel = E('select', { 'class': 'cbi-input-select', 'style': 'width:auto' },
			DAYS.map(function(d) { return E('option', { 'value': d[0] }, d[1]); }));
		var day = uci.get(xm.CONF, 'global', 'geo_update_day');
		daySel.value = /^[0-6]$/.test(day || '') ? day : '*';

		function saveSchedule() {
			uci.set(xm.CONF, 'global', 'geo_auto_update', autoChk.checked ? '1' : '0');
			uci.set(xm.CONF, 'global', 'geo_update_hour', hourSel.value);
			uci.set(xm.CONF, 'global', 'geo_update_day', daySel.value);
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
				_('在线更新 Xray、mosdns-x 和 geo 规则数据，来源是各自在 GitHub 上的最新 release。本插件自身只检查有没有新版本（点“检查更新”时，以及每次 geo 数据定时更新时），新版本需要下载安装包手动安装。')),
			xm.section(_('版本'), [
				verBox,
				appNote,
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
						autoChk, ' ', daySel, ' ', hourSel, ' ',
						btn(_('保存计划'), saveSchedule), cronState
					])
				])
			], _('按设定的时间检查，与最新 release 版本相同时跳过下载。geo 数据通常每天发布一次，每周更新一次一般就够用。'))
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
