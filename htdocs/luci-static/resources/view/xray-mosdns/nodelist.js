'use strict';
'require view';
'require form';
'require uci';
'require fs';
'require ui';
'require xray-mosdns.common as xm';

var IMPORT_FILE = '/tmp/xray-mosdns-import.txt';

function latencyBadge(res) {
	if (!res || !res.ok)
		return xm.badge(_('超时'), 'bad');
	return xm.badge('%d ms'.format(res.ms), res.ms < 150 ? 'ok' : (res.ms < 400 ? 'warn' : 'bad'));
}

function testNode(sid, cell) {
	cell.replaceChildren(E('em', { 'class': 'spinning' }, _('测速中')));
	return xm.exec('latency.sh', [ sid ]).then(function(res) {
		cell.replaceChildren(latencyBadge(res));
	});
}

function importDialog() {
	var area = E('textarea', {
		'class': 'cbi-input-textarea', 'rows': 10, 'style': 'width:100%',
		'placeholder': 'vless://...\nvmess://...\ntrojan://...\nss://...\nhysteria2://...'
	});

	function doImport() {
		var text = area.value || '';
		if (!text.trim()) {
			ui.addNotification(null, E('p', {}, _('没有可导入的内容')), 'warning');
			return;
		}
		/* 0600: the links carry credentials; the import deletes the file */
		return fs.write(IMPORT_FILE, text, 384).then(function() {
			return xm.exec('import-links.sh', [ IMPORT_FILE ]);
		}).then(function(out) {
			ui.hideModal();
			if (!out.ok) {
				ui.addNotification(null, E('p', {}, out.error || _('导入失败')), 'error');
				return;
			}
			ui.addNotification(null, E('p', {},
				_('已导入 %d 个节点，跳过 %d 行。导入的节点默认未启用。').format(out.imported || 0, out.skipped || 0)), 'info');
			window.setTimeout(function() { window.location.reload(); }, 1200);
		}).catch(function(err) {
			ui.hideModal();
			ui.addNotification(null, E('p', {}, String(err.message || err)), 'error');
		});
	}

	ui.showModal(_('导入节点'), [
		E('p', {}, _('粘贴分享链接，每行一个。支持 vless、vmess、trojan、shadowsocks（SIP002）、hysteria2。')),
		area,
		E('div', { 'class': 'right' }, [
			E('button', { 'class': 'btn', 'click': ui.hideModal }, _('取消')),
			' ',
			E('button', { 'class': 'btn cbi-button-positive', 'click': doImport }, _('导入'))
		])
	]);
}

return view.extend({
	load: function() {
		return uci.load(xm.CONF);
	},

	render: function() {
		var m, s, o;
		var latencyCells = {};

		m = new form.Map(xm.CONF, _('节点'),
			_('代理出口。未启用的节点不会被使用；流量具体走哪个节点或节点组在“分流”页决定。'));

		/* ------------------------------------------------------------ node list */
		s = m.section(form.GridSection, 'node', _('节点列表'));
		s.addremove = true;
		s.anonymous = true;
		s.sortable = true;
		s.nodescriptions = true;
		s.addbtntitle = _('添加节点');
		s.modaltitle = function(sid) {
			var n = uci.get(xm.CONF, sid) || {};
			return _('节点') + ' » ' + (n.remarks || n.address || _('新节点'));
		};

		o = s.option(form.Flag, 'enabled', _('启用'));
		o.editable = true;
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.Value, 'remarks', _('备注'));
		o.placeholder = 'my-vps';

		o = s.option(form.ListValue, 'type', _('类型'));
		Object.keys(xm.TYPES).forEach(function(k) { o.value(k, xm.TYPES[k]); });
		o.default = 'vless';
		o.textvalue = function(sid) {
			var t = uci.get(xm.CONF, sid, 'type') || 'vless';
			return xm.TYPES[t] || t;
		};

		o = s.option(form.Value, 'address', _('地址'));
		o.datatype = 'host';
		o.rmempty = false;
		o.placeholder = 'example.com';
		o.textvalue = function(sid) {
			var n = uci.get(xm.CONF, sid) || {};
			return n.address ? '%s:%s'.format(n.address, n.port || '443') : null;
		};

		o = s.option(form.Value, 'port', _('端口'));
		o.datatype = 'port';
		o.default = '443';
		o.rmempty = false;
		o.modalonly = true;

		o = s.option(form.DummyValue, '_latency', _('延迟'));
		o.modalonly = false;
		o.textvalue = function(sid) {
			var cell = E('span', {}, [
				E('button', {
					'class': 'cbi-button cbi-button-action',
					'click': ui.createHandlerFn(this, function() { return testNode(sid, cell); })
				}, _('测速'))
			]);
			latencyCells[sid] = cell;
			return cell;
		};

		/* credentials */
		o = s.option(form.Value, 'uuid', 'UUID');
		o.modalonly = true;
		o.depends('type', 'vless');
		o.depends('type', 'vmess');

		o = s.option(form.Value, 'alter_id', 'Alter ID');
		o.modalonly = true;
		o.datatype = 'uinteger';
		o.default = '0';
		o.depends('type', 'vmess');

		o = s.option(form.Value, 'flow', _('流控（flow）'));
		o.modalonly = true;
		o.value('', _('无'));
		o.value('xtls-rprx-vision');
		o.depends('type', 'vless');

		o = s.option(form.Value, 'password', _('密码'));
		o.modalonly = true;
		o.password = true;
		o.depends('type', 'trojan');
		o.depends('type', 'shadowsocks');
		o.depends('type', 'hysteria2');

		o = s.option(form.ListValue, 'method', _('加密方式'));
		o.modalonly = true;
		[ 'aes-128-gcm', 'aes-256-gcm', 'chacha20-poly1305', 'xchacha20-poly1305' ].forEach(function(v) { o.value(v); });
		o.depends('type', 'shadowsocks');

		/* tls */
		o = s.option(form.Flag, 'tls', 'TLS');
		o.modalonly = true;
		o.depends('type', 'vless');
		o.depends('type', 'vmess');
		o.depends('type', 'trojan');

		o = s.option(form.Value, 'tls_server_name', _('TLS 服务器名（SNI）'), _('留空则使用节点地址。'));
		o.modalonly = true;
		o.datatype = 'hostname';
		o.depends('tls', '1');
		o.depends('type', 'hysteria2');

		o = s.option(form.ListValue, 'fingerprint', _('uTLS 指纹'));
		o.modalonly = true;
		[ 'chrome', 'firefox', 'safari', 'edge', 'random' ].forEach(function(v) { o.value(v); });
		o.depends('tls', '1');

		/* transport */
		o = s.option(form.ListValue, 'transport', _('传输方式'));
		o.modalonly = true;
		[ 'tcp', 'ws', 'grpc', 'http', 'xhttp' ].forEach(function(v) { o.value(v); });
		o.default = 'tcp';
		o.depends('type', 'vless');
		o.depends('type', 'vmess');
		o.depends('type', 'trojan');

		o = s.option(form.Value, 'path', _('路径'));
		o.modalonly = true;
		o.default = '/';
		o.depends('transport', 'ws');
		o.depends('transport', 'http');
		o.depends('transport', 'xhttp');

		o = s.option(form.Value, 'host', _('Host 头'), _('留空则使用 SNI 或节点地址。'));
		o.modalonly = true;
		o.depends('transport', 'ws');
		o.depends('transport', 'http');
		o.depends('transport', 'xhttp');

		o = s.option(form.Value, 'service_name', _('gRPC 服务名'));
		o.modalonly = true;
		o.depends('transport', 'grpc');

		/* ------------------------------------------------------------ groups */
		s = m.section(form.GridSection, 'group', _('节点组'),
			_('把几个节点组合成一个出口。组和节点一样，可以在“分流”页选作总节点或规则出口；当前用的是哪个成员在“概览”页看。'));
		s.addremove = true;
		s.anonymous = true;
		s.sortable = true;
		s.nodescriptions = true;
		s.addbtntitle = _('添加节点组');
		s.modaltitle = function(sid) {
			return _('节点组') + ' » ' + (uci.get(xm.CONF, sid, 'remarks') || _('新节点组'));
		};

		o = s.option(form.Value, 'remarks', _('名称'));
		o.rmempty = false;
		o.placeholder = _('香港');

		o = s.option(form.ListValue, 'strategy', _('策略'),
			_('最快：定期探测，用延迟最低的可用成员。按顺序：用排在最前面的可用成员，切换之后只有当前成员不可用才再次切换。轮询、随机：每个连接换一个成员，同一网站会看到多个出口 IP，可能触发登录验证。'));
		Object.keys(xm.STRATEGIES).forEach(function(k) { o.value(k, xm.STRATEGIES[k]); });
		o.default = 'fastest';
		o.textvalue = function(sid) {
			var v = uci.get(xm.CONF, sid, 'strategy') || 'fastest';
			return xm.STRATEGIES[v] || v;
		};

		o = s.option(form.Flag, 'failback', _('恢复后切回'),
			_('默认不切回：切到后面的成员之后，只要它还可用就一直用它，避免前面的成员时好时坏导致来回切换。开启后，排在前面的成员一恢复就切回去。'));
		o.modalonly = true;
		o.default = '0';
		o.depends('strategy', 'ordered');

		o = s.option(form.DynamicList, 'member', _('成员'),
			_('“按顺序”策略下，列表顺序就是切换时的挑选顺序。未启用的节点会被跳过。'));
		xm.addNodeChoices(o);
		o.rmempty = false;
		o.textvalue = function(sid) {
			var names = L.toArray(uci.get(xm.CONF, sid, 'member')).map(function(n) { return xm.targetLabel(n); });
			return names.length ? names.join(uci.get(xm.CONF, sid, 'strategy') === 'ordered' ? ' → ' : '、') : null;
		};

		o = s.option(form.ListValue, 'fallback', _('全部不可用时'));
		o.value('direct', _('直连'));
		o.value('block', _('阻断'));
		xm.addNodeChoices(o);
		o.default = 'direct';
		o.textvalue = function(sid) {
			return xm.targetLabel(uci.get(xm.CONF, sid, 'fallback') || 'direct');
		};

		return m.render().then(function(node) {
			var tools = E('div', { 'class': 'cbi-section' }, [
				E('button', { 'class': 'cbi-button cbi-button-action', 'click': importDialog }, _('导入节点…')),
				' ',
				E('button', {
					'class': 'cbi-button cbi-button-action',
					/* a few at a time: each test opens connections from the router */
					'click': ui.createHandlerFn(this, function() {
						var queue = Object.keys(latencyCells);
						function worker() {
							var sid = queue.shift();
							return sid ? testNode(sid, latencyCells[sid]).then(worker) : Promise.resolve();
						}
						return Promise.all([ worker(), worker(), worker(), worker() ]);
					})
				}, _('全部测速'))
			]);
			var first = node.querySelector('.cbi-section');
			if (first)
				first.parentNode.insertBefore(tools, first);
			return node;
		});
	}
});
