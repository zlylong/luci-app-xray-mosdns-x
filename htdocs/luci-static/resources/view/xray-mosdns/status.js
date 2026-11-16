'use strict';
'require view';
'require uci';
'require fs';
'require ui';
'require poll';
'require xray-mosdns.common as xm';

var INIT = '/etc/init.d/xray-mosdns';

var CHECKS = [
	{ id: 'aliyun',  label: _('阿里云') },
	{ id: 'google',  label: 'Google' },
	{ id: 'github',  label: 'GitHub' },
	{ id: 'youtube', label: 'YouTube' }
];

function running(on, enabled) {
	if (on) return xm.badge(_('运行中'), 'ok');
	return enabled ? xm.badge(_('未运行'), 'bad') : xm.badge(_('已停止'));
}

return view.extend({
	load: function() {
		return Promise.all([
			uci.load(xm.CONF),
			xm.exec('status.sh'),
			xm.exec('traffic.sh'),
			xm.exec('groups.uc', [ 'list' ])
		]);
	},

	render: function(res) {
		var global = uci.get(xm.CONF, 'global') || {};
		var dns = uci.get(xm.CONF, 'dns') || {};
		var statusBox = E('div');
		var trafficBody = E('tbody');
		var trafficNote = E('div', { 'class': 'cbi-section-descr' });

		/* ------------------------------------------------------------ status */
		function renderStatus(st) {
			var enabled = st.enabled == 1;
			var fwOk = st.fw && st.fw.nft && st.fw.rule;
			var rows = [
				[ _('服务'), enabled ? xm.badge(_('已启用'), 'ok') : xm.badge(_('未启用')) ],
				[ 'Xray', running(st.xray_running == 1, enabled) ],
				[ 'mosdns-x', dns.enabled === '0'
					? xm.badge(_('已关闭'))
					: running(st.mosdns_running == 1, enabled) ],
				[ _('防火墙规则'), fwOk
					? xm.badge(_('已加载'), 'ok')
					: (enabled ? xm.badge(_('未加载'), 'bad') : xm.badge(_('未加载'))) ],
				[ _('未命中规则时'), xm.DEFAULTS[global.default_action || 'proxy'] ],
				[ _('总节点'), xm.targetLabel(st.main_target || global.main_target || 'direct') ],
				[ _('分流位置'), global.kernel_split === '0'
					? _('全部进入 Xray 后分流')
					: _('内核分流（直连流量不进 Xray）') ],
				[ _('LAN DNS'), dns.enabled === '0'
					? _('未接管')
					: (dns.redirect === '0'
						? _('mosdns-x 监听 :%s，未重定向').format(dns.listen_port || '5335')
						: (!enabled || st.dns_redirect
							? _('53 端口重定向到 mosdns-x :%s').format(dns.listen_port || '5335')
							: E('span', {}, [ xm.badge(_('已回退'), 'warn'), ' ',
								_('mosdns-x 没有应答，当前由 dnsmasq 解析') ]))) ]
			];
			statusBox.replaceChildren(xm.infoTable(rows));
		}
		renderStatus(res[1] || {});

		/* ------------------------------------------------------------ control */
		function act(enable, restartOnly) {
			var p = Promise.resolve();
			if (!restartOnly) {
				uci.set(xm.CONF, 'global', 'enabled', enable ? '1' : '0');
				p = uci.save().then(function() { return uci.apply(); });
			}
			ui.showModal(_('正在应用…'), [ E('p', { 'class': 'spinning' }, _('请稍候')) ]);
			return p.then(function() {
				if (!enable)
					return fs.exec(INIT, [ 'stop' ]);
				return fs.exec(INIT, [ 'enable' ]).then(function() {
					return fs.exec(INIT, [ 'restart' ]);
				});
			}).then(function(r) {
				if (r && r.code)
					ui.addNotification(null, E('p', {}, (r.stderr || r.stdout || _('操作失败')).trim()), 'error');
			}).catch(function(err) {
				ui.addNotification(null, E('p', {}, String(err.message || err)), 'error');
			}).then(function() {
				ui.hideModal();
				window.location.reload();
			});
		}

		var isOn = global.enabled === '1';
		var controls = E('div', { 'class': 'cbi-page-actions', 'style': 'text-align:left' }, [
			isOn
				? E('button', { 'class': 'cbi-button cbi-button-negative', 'click': function() { return act(false); } }, _('停用'))
				: E('button', { 'class': 'cbi-button cbi-button-positive', 'click': function() { return act(true); } }, _('启用并启动')),
			' ',
			E('button', {
				'class': 'cbi-button cbi-button-action',
				'disabled': isOn ? null : '',
				'click': function() { return act(true, true); }
			}, _('重启服务'))
		]);

		/* ------------------------------------------------------------ connectivity */
		var checkCells = {};
		var checkTable = E('table', { 'class': 'table' }, [
			E('tr', { 'class': 'tr table-titles' }, [
				E('th', { 'class': 'th' }, _('目标')),
				E('th', { 'class': 'th' }, _('结果')),
				E('th', { 'class': 'th' }, _('耗时')),
				E('th', { 'class': 'th' }, _('路径'))
			])
		].concat(CHECKS.map(function(c) {
			checkCells[c.id] = [ E('td', { 'class': 'td' }, '-'), E('td', { 'class': 'td' }, '-'), E('td', { 'class': 'td' }, '-') ];
			return E('tr', { 'class': 'tr' }, [ E('td', { 'class': 'td' }, c.label) ].concat(checkCells[c.id]));
		})));

		function runChecks(ev) {
			var btn = ev.currentTarget;
			btn.disabled = true;
			return Promise.all(CHECKS.map(function(c) {
				var cells = checkCells[c.id];
				cells[0].replaceChildren(E('em', { 'class': 'spinning' }, _('检测中')));
				return xm.exec('check-connect.sh', [ c.id ]).then(function(r) {
					cells[0].replaceChildren(r.ok ? xm.badge(_('可达'), 'ok') : xm.badge(_('不可达'), 'bad'));
					cells[1].textContent = r.ok ? '%d ms'.format(r.ms) : '-';
					cells[2].textContent = r.via === 'proxy' ? _('经代理') : _('直连');
				});
			})).then(function() { btn.disabled = false; });
		}

		/* ------------------------------------------------------------ groups */
		var groupBody = E('tbody');
		var groupSection = E('div');

		function pin(group, node) {
			return xm.exec('groups.uc', [ 'pin', group, node || '-' ]).then(function(r) {
				if (r.ok === false)
					ui.addNotification(null, E('p', {}, r.error || _('操作失败')), 'error');
				return xm.exec('groups.uc', [ 'list' ]).then(renderGroups);
			});
		}

		var probeNote = E('div', { 'class': 'cbi-section-descr' });

		function renderGroups(data) {
			var groups = (data && data.groups) || [];
			probeNote.replaceChildren.apply(probeNote, (data && data.probe === 'backup')
				? [ xm.badge(_('备用探测地址'), 'warn'), ' ', _('主探测地址上所有成员都没有应答，当前改用备用地址探测。') ]
				: []);
			groupSection.style.display = groups.length ? '' : 'none';
			groupBody.replaceChildren.apply(groupBody, groups.map(function(grp) {
				var current;
				if (!grp.running)
					current = xm.badge(_('Xray 未运行'));
				else if (grp.current)
					current = E('span', {}, [ xm.targetLabel(grp.current), ' ',
						grp.pinned ? xm.badge(_('已锁定'), 'warn') : '' ]);
				else if (grp.healthy.length)
					current = _('在 %d 个可用成员间轮换').format(grp.healthy.length);
				else
					current = E('span', {}, [ xm.badge(_('无可用成员'), 'bad'), ' ',
						_('走兜底：%s').format(xm.targetLabel(grp.fallback.replace(/\.node$/, ''))) ]);

				var sel = E('select', { 'class': 'cbi-input-select', 'style': 'width:auto' },
					[ E('option', { 'value': '' }, _('自动')) ].concat(grp.members.map(function(n) {
						return E('option', { 'value': n }, xm.targetLabel(n));
					})));
				sel.value = grp.pinned || '';
				sel.disabled = !grp.running;
				sel.addEventListener('change', function() { pin(grp.name, sel.value); });

				return E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td' }, grp.remarks || grp.name),
					E('td', { 'class': 'td' }, xm.STRATEGIES[grp.strategy] || grp.strategy),
					E('td', { 'class': 'td' }, current),
					E('td', { 'class': 'td' }, '%d / %d'.format(grp.healthy.length, grp.members.length)),
					E('td', { 'class': 'td' }, sel)
				]);
			}));
		}
		renderGroups(res[3] || {});

		/* ------------------------------------------------------------ traffic */
		function renderTraffic(data) {
			var nodes = (data && data.nodes) || [];
			var err = data && data.error;
			trafficNote.textContent =
				err === 'xray_not_running' ? _('Xray 未运行，暂无数据。') :
				err === 'api_unavailable' ? _('统计接口不可用，请检查“系统 → 本地统计 API 端口”。') :
				err ? _('读取失败：%s').format(err) : '';
			trafficBody.replaceChildren.apply(trafficBody, nodes.length ? nodes.map(function(n) {
				return E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td' }, xm.targetLabel(n.tag.replace(/\.node$/, ''))),
					E('td', { 'class': 'td' }, xm.fmtBytes(n.uplink)),
					E('td', { 'class': 'td' }, xm.fmtBytes(n.downlink)),
					E('td', { 'class': 'td' }, xm.fmtBytes(n.total))
				]);
			}) : [ E('tr', { 'class': 'tr placeholder' }, [
				E('td', { 'class': 'td', 'colspan': 4 }, E('em', {}, _('暂无节点流量')))
			]) ]);
		}
		renderTraffic(res[2] || {});

		poll.add(function() {
			return Promise.all([
				xm.exec('status.sh'), xm.exec('traffic.sh'), xm.exec('groups.uc', [ 'list' ])
			]).then(function(r) {
				renderStatus(r[0] || {});
				renderTraffic(r[1] || {});
				// do not rebuild the table under an open drop-down
				if (!groupBody.contains(document.activeElement))
					renderGroups(r[2] || {});
			});
		}, 10);

		return E('div', {}, [
			E('h2', {}, 'Xray + mosdns-x'),
			E('div', { 'class': 'cbi-map-descr' },
				_('透明代理与 DNS 分流。节点、分流规则和 DNS 上游各有一页；这里只看运行状态。')),
			xm.section(_('运行状态'), [ statusBox, controls ]),
			(groupSection.appendChild(xm.section(_('节点组'), [
				probeNote,
				E('table', { 'class': 'table' }, [
					E('thead', {}, E('tr', { 'class': 'tr table-titles' }, [
						E('th', { 'class': 'th' }, _('组')),
						E('th', { 'class': 'th' }, _('策略')),
						E('th', { 'class': 'th' }, _('当前出口')),
						E('th', { 'class': 'th' }, _('可用成员')),
						E('th', { 'class': 'th' }, _('锁定'))
					])),
					groupBody
				])
			], _('只显示正在被总节点或规则使用的组。锁定是临时的，重启路由器后恢复自动。'))), groupSection),
			xm.section(_('连通性'), [
				checkTable,
				E('div', { 'class': 'cbi-page-actions', 'style': 'text-align:left' }, [
					E('button', { 'class': 'cbi-button cbi-button-action', 'click': runChecks }, _('检测'))
				])
			], _('服务运行时经代理访问，否则直连。')),
			xm.section(_('节点流量'), [
				trafficNote,
				E('table', { 'class': 'table' }, [
					E('thead', {}, E('tr', { 'class': 'tr table-titles' }, [
						E('th', { 'class': 'th' }, _('节点')),
						E('th', { 'class': 'th' }, _('上行')),
						E('th', { 'class': 'th' }, _('下行')),
						E('th', { 'class': 'th' }, _('合计'))
					])),
					trafficBody
				])
			], _('自 Xray 启动以来经各节点的流量，直连流量不计入。'))
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
