'use strict';
'require view';
'require fs';
'require uci';
'require ui';
'require poll';
'require xray-mosdns.ui as xm';

var CONF = 'xray-mosdns';

var CHECKS = [
	{ id: 'aliyun',  label: '阿里' },
	{ id: 'google',  label: '谷歌' },
	{ id: 'github',  label: 'GitHub' },
	{ id: 'youtube', label: 'YouTube' }
];

var TARGET_LABEL = {
	direct: '直连',
	balance: '负载均衡',
	failover: '主备'
};

var MODE_LABEL = {
	chnroute: '大陆白名单',
	gfw: 'GFW 列表',
	global: '全局代理',
	custom: '自定义规则'
};

function parseJson(res) {
	try { return JSON.parse((res && res.stdout) || '{}'); } catch (e) { return {}; }
}

function fmtBytes(n) {
	n = Number(n) || 0;
	if (n < 1024) return n + ' B';
	if (n < 1048576) return (n / 1024).toFixed(1) + ' KiB';
	if (n < 1073741824) return (n / 1048576).toFixed(1) + ' MiB';
	return (n / 1073741824).toFixed(2) + ' GiB';
}

function vLabel(st) {
	if (st.enabled != 1) return '未启用';
	if (st.xray_running == 1) return '运行中';
	return '已启用，未运行';
}

function xrayVersion(ver) {
	var m = /Xray\s+([0-9][0-9.]*)/.exec(ver.xray || '');
	return m ? 'Xray ' + m[1] : (ver.xray || '未安装');
}

function mosdnsVersion(ver) {
	var raw = ver.mosdns || '';
	var d = /build time:\s*([0-9.]+)/.exec(raw);
	if (d) return 'mosdns-x ' + d[1];
	return raw || '未安装';
}

return view.extend({
	load: function() {
		return Promise.all([
			uci.load(CONF),
			fs.exec('/usr/libexec/xray-mosdns/status.sh', []),
			fs.exec('/usr/libexec/xray-mosdns/update.sh', [ 'versions' ])
		]);
	},

	render: function(res) {
		var st = parseJson(res && res[1]);
		var ver = parseJson(res && res[2]);
		var global = uci.get(CONF, 'global') || {};
		var dns = uci.get(CONF, 'dns') || {};
		var nodes = uci.sections(CONF, 'node') || [];

		var tproxy = st.tproxy_port || global.tproxy_port || '12345';
		var socks = global.socks_port || '1070';
		var mosdnsPort = dns.listen_port || '5353';
		var api = global.api_port || '10085';
		var mode = global.rule_mode || 'chnroute';
		var main = st.main_target || global.main_target || 'direct';
		var targetText = st.node_remarks || TARGET_LABEL[main] || '直连';


		function headLamps(s) {
			var running = s.enabled == 1;
			return [
				xm.lamp(running ? 'on' : 'warn', '服务', running ? '已启用' : '未启用'),
				xm.lamp(s.xray_running == 1 ? 'on' : (running ? 'warn' : 'off'), 'Xray',
					s.xray_running == 1 ? '运行中' : (running ? '未运行' : '停止')),
				xm.lamp(s.mosdns_running == 1 ? 'on' : (running ? 'warn' : 'off'), 'mosdns',
					s.mosdns_running == 1 ? '运行中' : (running ? '未运行' : '停止'))
			];
		}

		var lampsWrap = E('div', { 'class': 'xmx-lamps' }, headLamps(st));
		/* ---------------------------------------------------------- route diagram */
		function buildRoute(s) {
			var run = s.enabled == 1;
			var xrayOn = s.xray_running == 1;
			var dnsOn = s.mosdns_running == 1;
			var dnsEnabled = s.dns_enabled == 1;
			var live = run && xrayOn;
			var stamp = run ? (xrayOn ? '运行中' : '已启用 · 未运行') : '未启用';

			function stn(name, value, on, extra) {
				var state = on === true ? '' : (on === 'standby' ? 'standby' : 'off');
				return xm.station(name, value, state || undefined);
			}

			var traffic = xm.lane('流量', [
				stn('客户端', 'LAN', true),
				xm.link(live ? 'on' : 'off'),
				stn('TProxy', ':' + (s.tproxy_port || tproxy), xrayOn),
				xm.link(live ? 'on' : 'off'),
				stn('Xray 分流', MODE_LABEL[mode] || mode, xrayOn),
				xm.link(live ? 'on' : 'off'),
				stn('出口', targetText, xrayOn)
			], live);

			var dns = xm.lane('DNS', [
				stn('dnsmasq', ':53 → 上游链', true),
				xm.link(dnsOn && dnsEnabled ? 'on' : 'off'),
				stn('mosdns-x', ':' + mosdnsPort, dnsEnabled && dnsOn),
				xm.link(dnsOn && dnsEnabled ? 'on' : 'off'),
				stn('上游', '国内直连 · 国外经代理', dnsEnabled && dnsOn)
			], dnsOn && dnsEnabled);

			return E('div', { 'class': 'xmx-route' + (live ? ' is-live' : '') }, [
				E('div', { 'class': 'xmx-route-top' }, [
					E('span', { 'class': 'xmx-stamp ' + (run ? (xrayOn ? 'is-live' : 'is-idle') : 'is-off') }, stamp)
				]),
				traffic,
				dns
			]);
		}

		var routeBox = E('div', {}, [ buildRoute(st) ]);

		/* ---------------------------------------------------------- main switch */
		var switchEl = E('input', { 'type': 'checkbox' });
		if (global.enabled === '1') switchEl.checked = true;

		var switchSave = xm.btn(global.enabled === '1' ? '保存并重启' : '启用并启动', 'xmx-btn-primary');
		switchSave.addEventListener('click', function() {
			var on = switchEl.checked;
			switchSave.disabled = true;
			uci.set(CONF, 'global', 'enabled', on ? '1' : '0');
			uci.save().then(function() { return uci.apply(); }).then(function() {
				var init = '/etc/init.d/xray-mosdns';
				if (!on)
					return fs.exec(init, [ 'stop' ]).then(function() {
						return fs.exec(init, [ 'disable' ]);
					}).then(function() {
						ui.addNotification(null, E('p', {}, '已停用，服务不再随开机启动。'), 'info');
					});
				return fs.exec(init, [ 'enable' ]).then(function() {
					return fs.exec(init, [ 'restart' ]);
				}).then(function(r) {
					var msg = ((r && r.stderr) || '').trim();
					ui.addNotification(null, E('p', {},
						msg || '已启用并启动服务。'), msg ? 'warning' : 'info');
				});
			}).catch(function(err) {
				ui.addNotification(null, E('p', {}, String(err.message || err)), 'error');
			}).then(function() {
				switchSave.disabled = false;
			});
		});

		var switchPlate = E('div', { 'class': 'xmx-plate' }, [
			E('h3', {}, '主开关'),
			E('p', { 'class': 'xmx-plate-sub' }, global.enabled === '1'
				? '服务已启用。与 PassWall 同时运行会被拒绝。'
				: '未启用：所有线路保持断开。启用后会接管 TProxy、DNS 与 nft 规则。'),
			E('div', { 'class': 'xmx-row' }, [ switchEl, E('span', {}, '启用 xray-mosdns-x') ]),
			E('div', { 'class': 'xmx-row' }, [ switchSave ])
		]);

		/* ---------------------------------------------------------- main target */
		var targetSel = E('select', {});
		targetSel.appendChild(E('option', { 'value': 'direct' }, '直连'));
		targetSel.appendChild(E('option', { 'value': 'balance' },
			'负载均衡' + (global.balance_enabled === '1' ? '' : '（未启用）')));
		targetSel.appendChild(E('option', { 'value': 'failover' },
			'主备' + (global.failover_enabled === '1' ? '' : '（未启用）')));
		nodes.forEach(function(n) {
			var addr = n.address ? ' · ' + n.address : '';
			targetSel.appendChild(E('option', { 'value': n['.name'] },
				(n.remarks || n.address || n['.name']) + addr));
		});
		targetSel.value = main;

		var targetSave = xm.btn('保存出口');
		targetSave.addEventListener('click', function() {
			uci.set(CONF, 'global', 'main_target', targetSel.value);
			uci.save().then(function() { return uci.apply(); }).then(function() {
				ui.addNotification(null, E('p', {}, '分流总节点已保存，重启服务后生效。'), 'info');
			});
		});

		var targetPlate = E('div', { 'class': 'xmx-plate' }, [
			E('h3', {}, '分流总节点'),
			E('p', { 'class': 'xmx-plate-sub' }, '未命中规则时的默认出口。可选直连、单个节点、负载均衡或主备。'),
			E('div', { 'class': 'xmx-row' }, [ targetSel ]),
			E('div', { 'class': 'xmx-row' }, [
				targetSave,
				E('span', { 'class': 'xmx-muted xmx-small' }, '当前：' + targetText)
			])
		]);

		/* ---------------------------------------------------------- connectivity */
		var checkEls = {};
		var checkGrid = E('div', { 'class': 'xmx-checks' });

		function runCheck(c, box, resultEl, btnEl) {
			resultEl.textContent = '检测中…';
			box.className = 'xmx-check';
			if (btnEl) btnEl.disabled = true;
			return fs.exec('/usr/libexec/xray-mosdns/check-connect.sh', [ c.id ]).then(function(r) {
				var out = parseJson(r);
				var ok = out.ok === true;
				box.className = 'xmx-check ' + (ok ? 'is-ok' : 'is-fail');
				var bits = [];
				if (out.http) bits.push('HTTP ' + out.http);
				if (out.ms) bits.push(out.ms + ' ms');
				bits.push(out.via === 'proxy' ? '经代理' : '直连');
				resultEl.textContent = ok ? bits.join(' · ') : '失败 · 检查网络';
			}).catch(function() {
				box.className = 'xmx-check is-fail';
				resultEl.textContent = '检测失败';
			}).then(function() {
				if (btnEl) btnEl.disabled = false;
			});
		}

		CHECKS.forEach(function(c) {
			var resultEl = E('span', { 'class': 'xmx-check-result' }, '未检测');
			var btnEl = xm.btn('检测');
			var box = E('div', { 'class': 'xmx-check' }, [
				E('div', { 'class': 'xmx-check-name' }, [ E('i'), c.label ]),
				resultEl,
				E('div', { 'class': 'xmx-check-actions' }, [ btnEl ])
			]);
			btnEl.addEventListener('click', function() { runCheck(c, box, resultEl, btnEl); });
			checkEls[c.id] = { c: c, box: box, resultEl: resultEl, btnEl: btnEl };
			checkGrid.appendChild(box);
		});

		var checkAll = xm.btn('全部检测');
		checkAll.addEventListener('click', function() {
			checkAll.disabled = true;
			Promise.all(CHECKS.map(function(c) {
				var e = checkEls[c.id];
				return runCheck(e.c, e.box, e.resultEl, e.btnEl);
			})).then(function() { checkAll.disabled = false; });
		});

		/* ---------------------------------------------------------- ports */
		function bool(v) { return v === true ? '已加载' : '未加载'; }

		var portTable = E('table', {}, [
			E('thead', {}, E('tr', {}, [
				E('th', {}, '用途'), E('th', {}, '监听'), E('th', {}, '状态')
			])),
			E('tbody', {}, [
				E('tr', {}, [
					E('td', {}, 'TProxy 入站'),
					E('td', { 'class': 'xmx-num' }, ':' + tproxy),
					E('td', { 'class': 'xmx-num' }, bool(st.fw && st.fw.nft))
				]),
				E('tr', {}, [
					E('td', {}, '内部 SOCKS（mosdns 国外解析）'),
					E('td', { 'class': 'xmx-num' }, '127.0.0.1:' + socks),
					E('td', { 'class': 'xmx-num' }, st.xray_running == 1 ? '运行中' : '停止')
				]),
				E('tr', {}, [
					E('td', {}, 'mosdns-x DNS'),
					E('td', { 'class': 'xmx-num' }, '127.0.0.1:' + mosdnsPort),
					E('td', { 'class': 'xmx-num' }, st.mosdns_running == 1 ? '运行中' : '停止')
				]),
				E('tr', {}, [
					E('td', {}, '统计 API'),
					E('td', { 'class': 'xmx-num' }, '127.0.0.1:' + api),
					E('td', { 'class': 'xmx-num' }, st.xray_running == 1 ? '运行中' : '停止')
				])
			])
		]);

		/* ---------------------------------------------------------- versions */
		var versionLine = E('p', { 'class': 'xmx-num xmx-muted', 'style': 'margin:0' }, [
			xrayVersion(ver) + ' · ' + mosdnsVersion(ver) + ' · geo ' + (ver.geo_version || '未记录'),
			' · ',
			E('a', { 'href': '#' }, '组件更新')
		]);
		versionLine.querySelector('a').addEventListener('click', function(ev) {
			ev.preventDefault();
			ui.showModal('组件版本', [
				E('table', { 'class': 'table' }, [
					E('tr', { 'class': 'tr' }, [ E('td', { 'class': 'td' }, 'Xray'), E('td', { 'class': 'td xmx-num' }, ver.xray || '-') ]),
					E('tr', { 'class': 'tr' }, [ E('td', { 'class': 'td' }, 'mosdns'), E('td', { 'class': 'td xmx-num' }, ver.mosdns || '-') ]),
					E('tr', { 'class': 'tr' }, [ E('td', { 'class': 'td' }, 'geo 数据'), E('td', { 'class': 'td xmx-num' }, (ver.geo_version || '-') + ' (' + fmtBytes(ver.geosite) + ' / ' + fmtBytes(ver.geoip) + ')') ])
				]),
				E('div', { 'class': 'right' }, E('button', { 'class': 'cbi-button', 'click': ui.hideModal }, '关闭'))
			]);
		});

		/* ---------------------------------------------------------- poll */
		poll.add(function() {
			return fs.exec('/usr/libexec/xray-mosdns/status.sh', []).then(function(r) {
				var s = parseJson(r);
				lampsWrap.replaceChildren.apply(lampsWrap, headLamps(s));
				routeBox.replaceChildren(buildRoute(s));
			});
		}, 15);

		return xm.page({
			title: '基本设置',
			lede: '透明代理与 DNS 分流的总览。下面是当前生效的线路、出口和连通性；改动会写入 UCI 并重启服务后生效。',
			lamps: lampsWrap
		}, [
			xm.section('线路图', [ routeBox ], '每 15 秒刷新'),
			xm.section('控制', [
				E('div', { 'class': 'xmx-grid' }, [ switchPlate, targetPlate ])
			]),
			xm.section('连通性', [ checkGrid ], checkAll),
			xm.section('端口', [ portTable ]),
			xm.section('组件', [ versionLine ])
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
