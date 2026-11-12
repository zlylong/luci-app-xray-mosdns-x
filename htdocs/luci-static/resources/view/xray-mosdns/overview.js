'use strict';
'require view';
'require fs';
'require uci';
'require ui';
'require poll';

var CONF = 'xray-mosdns';

var CHECKS = [
	{ id: 'aliyun', label: '阿里连接' },
	{ id: 'google', label: '谷歌连接' },
	{ id: 'github', label: 'GitHub 连接' },
	{ id: 'youtube', label: 'YouTube 连接' }
];

function statusDot(ok) {
	return E('span', {
		'style': 'display:inline-block;width:10px;height:10px;border-radius:50%;margin-right:6px;' +
			'background:' + (ok ? '#2e7d32' : '#c62828')
	});
}

function tile(title, valueNode) {
	return E('div', {
		'class': 'cbi-section',
		'style': 'flex:1 1 180px;min-width:180px;padding:12px;'
	}, [
		E('strong', { 'style': 'display:block;margin-bottom:8px;' }, title),
		valueNode
	]);
}

function fieldRow(title, node, hint) {
	return E('div', { 'class': 'cbi-value' }, [
		E('label', { 'class': 'cbi-value-title' }, title),
		E('div', { 'class': 'cbi-value-field' }, [ node, hint ? E('div', { 'class': 'cbi-value-description' }, hint) : '' ])
	]);
}

return view.extend({
	load: function() {
		return Promise.all([
			uci.load(CONF),
			fs.exec('/usr/libexec/xray-mosdns/status.sh', [])
		]);
	},

	render: function(res) {
		var st = {};
		try { st = JSON.parse(((res && res[1]) && res[1].stdout) || '{}'); } catch (e) { st = {}; }

		var global = uci.get(CONF, 'global') || {};
		var nodes = uci.sections(CONF, 'node') || [];

		// ---------------------------------------------------------------- state tiles
		var tiles = E('div', { 'style': 'display:flex;flex-wrap:wrap;gap:12px;margin-bottom:16px;' });

		function setRunning(ok) {
			return E('span', { 'style': ok ? 'color:#2e7d32;font-weight:bold' : 'color:#c62828;font-weight:bold' },
				[ statusDot(ok), ok ? '运行中' : '未运行' ]);
		}

		tiles.appendChild(tile('主开关', E('span', { 'style': st.enabled == 1 ? 'color:#2e7d32;font-weight:bold' : 'color:#c62828;font-weight:bold' },
			[ statusDot(st.enabled == 1), st.enabled == 1 ? '已启用' : '未启用' ])));
		tiles.appendChild(tile('Xray', setRunning(st.xray_running == 1)));
		tiles.appendChild(tile('mosdns（DNS）', setRunning(st.mosdns_running == 1)));
		tiles.appendChild(tile('TProxy', E('span', {}, st.tproxy_port ? ('端口 ' + st.tproxy_port) : '-')));
		tiles.appendChild(tile('分流总节点', E('span', {}, st.node_remarks || st.main_target || '-')));

		// ---------------------------------------------------------------- connectivity checks
		var checkTiles = E('div', { 'style': 'display:flex;flex-wrap:wrap;gap:12px;margin-bottom:16px;' });
		var checkEls = {};

		CHECKS.forEach(function(c) {
			var valueEl = E('span', { 'style': 'color:#c62828;font-weight:bold' }, [ statusDot(false), '点我检测' ]);
			checkEls[c.id] = valueEl;
			var b = E('button', { 'class': 'cbi-button cbi-button-neutral', 'style': 'margin-top:8px;' }, '检测');
			b.addEventListener('click', function() {
				valueEl.replaceChildren(E('span', { 'style': 'color:#666' }, '检测中…'));
				fs.exec('/usr/libexec/xray-mosdns/check-connect.sh', [ c.id ]).then(function(r) {
					var out = {};
					try { out = JSON.parse((r && r.stdout) || '{}'); } catch (e) { out = {}; }
					var ok = out.ok === true;
					valueEl.replaceChildren(E('span', { 'style': ok ? 'color:#2e7d32;font-weight:bold' : 'color:#c62828;font-weight:bold' },
						[ statusDot(ok), (ok ? 'HTTP ' + out.http : '失败') + (out.ms ? ' · ' + out.ms + 'ms' : '') + '（' + (out.via === 'proxy' ? '经代理' : '直连') + '）' ]));
				}).catch(function() {
					valueEl.replaceChildren(E('span', { 'style': 'color:#c62828' }, [ statusDot(false), '失败' ]));
				});
			});
			checkTiles.appendChild(tile(c.label, E('div', {}, [ valueEl, b ])));
		});

		// ---------------------------------------------------------------- main switch
		var switchEl = E('input', { 'type': 'checkbox', 'class': 'cbi-input-checkbox' });
		if (global.enabled === '1') switchEl.checked = true;

		var switchSave = E('button', { 'class': 'cbi-button cbi-button-apply' }, '保存');
		switchSave.addEventListener('click', function() {
			var on = switchEl.checked;
			uci.set(CONF, 'global', 'enabled', on ? '1' : '0');
			uci.save().then(function() { return uci.apply(); }).then(function() {
				var init = '/etc/init.d/xray-mosdns';
				if (on) {
					return fs.exec(init, [ 'enable' ]).then(function() {
						return fs.exec(init, [ 'restart' ]).then(function(r) {
							var msg = ((r && r.stderr) || '').trim();
							ui.addNotification(null, E('p', {}, msg || '已保存并尝试启动（如 PassWall 正在运行会被拒绝）'), 'info');
						});
					});
				}
				return fs.exec(init, [ 'stop' ]).then(function() {
					return fs.exec(init, [ 'disable' ]);
				}).then(function() {
					ui.addNotification(null, E('p', {}, '已保存并停止服务'), 'info');
				});
			}).catch(function(err) {
				ui.addNotification(null, E('p', {}, String(err.message || err)), 'error');
			});
		});

		// ---------------------------------------------------------------- main target
		var targetSel = E('select', { 'class': 'cbi-input-select' });
		targetSel.appendChild(E('option', { 'value': 'direct' }, '直连'));
		targetSel.appendChild(E('option', { 'value': 'balance' },
			'负载均衡' + (global.balance_enabled === '1' ? '' : '（未启用）')));
		targetSel.appendChild(E('option', { 'value': 'failover' },
			'主备' + (global.failover_enabled === '1' ? '' : '（未启用）')));
		nodes.forEach(function(n) {
			var o = E('option', { 'value': n['.name'] },
				'节点：' + (n.remarks || n.address || n['.name']));
			if ((global.main_target || 'direct') === n['.name']) o.selected = true;
			targetSel.appendChild(o);
		});
		if (['direct', 'balance', 'failover'].indexOf(global.main_target || 'direct') >= 0)
			targetSel.value = global.main_target || 'direct';

		var targetSave = E('button', { 'class': 'cbi-button cbi-button-apply' }, '保存');
		targetSave.addEventListener('click', function() {
			uci.set(CONF, 'global', 'main_target', targetSel.value);
			uci.save().then(function() { return uci.apply(); }).then(function() {
				ui.addNotification(null, E('p', {}, '分流总节点已保存'), 'info');
			});
		});

		// ---------------------------------------------------------------- ports info
		var socksPort = global.socks_port || '1070';
		var apiPort = global.api_port || '10085';
		var info = E('table', { 'class': 'table' }, [
			E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td', 'style': 'width:200px' }, '内部 Socks 端口'),
				E('td', { 'class': 'td' }, '127.0.0.1:' + socksPort + '（供 mosdns 代理解析国外 DNS）')
			]),
			E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td' }, '统计 API 端口'),
				E('td', { 'class': 'td' }, '127.0.0.1:' + apiPort)
			]),
			E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td' }, 'TProxy 端口'),
				E('td', { 'class': 'td' }, String(st.tproxy_port || global.tproxy_port || '12345'))
			])
		]);

		poll.add(function() {
			return fs.exec('/usr/libexec/xray-mosdns/status.sh', []).then(function(r) {
				var s = {};
				try { s = JSON.parse((r && r.stdout) || '{}'); } catch (e) { return; }
				tiles.replaceChildren();
				tiles.appendChild(tile('主开关', E('span', { 'style': s.enabled == 1 ? 'color:#2e7d32;font-weight:bold' : 'color:#c62828;font-weight:bold' },
					[ statusDot(s.enabled == 1), s.enabled == 1 ? '已启用' : '未启用' ])));
				tiles.appendChild(tile('Xray', setRunning(s.xray_running == 1)));
				tiles.appendChild(tile('mosdns（DNS）', setRunning(s.mosdns_running == 1)));
				tiles.appendChild(tile('TProxy', E('span', {}, s.tproxy_port ? ('端口 ' + s.tproxy_port) : '-')));
				tiles.appendChild(tile('分流总节点', E('span', {}, s.node_remarks || s.main_target || '-')));
			});
		}, 15);

		return E('div', {}, [
			E('h2', {}, '运行状态'),
			tiles,
			checkTiles,
			E('fieldset', { 'class': 'cbi-section' }, [
				E('legend', {}, '基本设置'),
				fieldRow('主开关', switchEl, '启用后由插件接管 TProxy 与 DNS；与 PassWall 冲突时会被拒绝启动。'),
				E('p', {}, switchSave)
			]),
			E('fieldset', { 'class': 'cbi-section' }, [
				E('legend', {}, '代理节点（分流总节点）'),
				fieldRow('分流总节点', targetSel, '未命中规则时的默认出口，可选直连 / 节点 / 负载均衡 / 主备。'),
				E('p', {}, targetSave)
			]),
			E('fieldset', { 'class': 'cbi-section' }, [
				E('legend', {}, '端口信息'),
				info
			])
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
