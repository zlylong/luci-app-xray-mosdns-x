'use strict';
'require view';
'require form';
'require uci';
'require ui';
'require network';
'require xray-mosdns.common as xm';

var RULE_TYPES = {
	domain: _('域名'),
	ip: _('IP / CIDR'),
	port: _('端口'),
	network: _('协议')
};

/* rule values are a uci list; configs written before 0.9 hold one comma separated string */
function ruleValues(sid) {
	return L.toArray(uci.get(xm.CONF, sid, 'value')).join(',').split(/[,\s]+/).filter(function(v) {
		return v.length > 0;
	});
}

/* Rows every install starts with. They are ordinary rules: the presets
   below only switch them on or off and set the default. */
var BUILTIN = {
	builtin_adlist:    { remarks: _('广告（订阅列表）'), rule_type: 'domain', value: 'adlist:all',          outbound: 'block' },
	builtin_cn_domain: { remarks: _('国内域名'),   rule_type: 'domain', value: 'geosite:cn',               outbound: 'direct' },
	builtin_cn_ip:     { remarks: _('国内 IP'),    rule_type: 'ip',     value: 'geoip:cn',                 outbound: 'direct' },
	builtin_noncn:     { remarks: _('非国内域名'), rule_type: 'domain', value: 'geosite:geolocation-!cn',  outbound: 'main' },
	builtin_gfw:       { remarks: _('GFW 列表'),   rule_type: 'domain', value: 'geosite:gfw',              outbound: 'main' }
};

var PRESETS = {
	whitelist: {
		title: _('大陆白名单'),
		descr: _('国内直连，其余走代理。'),
		default_action: 'proxy',
		on: [ 'builtin_cn_domain', 'builtin_cn_ip', 'builtin_noncn' ], off: [ 'builtin_gfw' ]
	},
	gfw: {
		title: _('GFW 列表'),
		descr: _('只有 GFW 列表里的域名走代理，其余直连。'),
		default_action: 'direct',
		on: [ 'builtin_gfw' ], off: [ 'builtin_cn_domain', 'builtin_cn_ip', 'builtin_noncn' ]
	},
	global: {
		title: _('全局'),
		descr: _('除了你自己的规则，全部走代理。'),
		default_action: 'proxy',
		on: [], off: [ 'builtin_cn_domain', 'builtin_cn_ip', 'builtin_noncn', 'builtin_gfw' ]
	}
};

/* a preset is staged like any other edit: nothing changes until Save & Apply */
function applyPreset(id) {
	var p = PRESETS[id];

	function toggle(name, enabled) {
		if (!uci.get(xm.CONF, name)) {
			if (!enabled)
				return;
			uci.add(xm.CONF, 'rule', name);
			Object.keys(BUILTIN[name]).forEach(function(k) {
				uci.set(xm.CONF, name, k, BUILTIN[name][k]);
			});
		}
		uci.set(xm.CONF, name, 'enabled', enabled ? '1' : '0');
	}

	uci.set(xm.CONF, 'global', 'default_action', p.default_action);
	p.on.forEach(function(n) { toggle(n, true); });
	p.off.forEach(function(n) { toggle(n, false); });

	return uci.save().then(function() {
		window.location.reload();
	});
}

return view.extend({
	load: function() {
		return Promise.all([
			uci.load(xm.CONF),
			xm.exec('geoview.uc', [ 'tags' ]),
			L.resolveDefault(network.getHostHints(), null)
		]);
	},

	render: function(res) {
		var m, s, o;
		var tags = res[1] || {};

		/* browser-native autocomplete for geosite:/geoip: tags in the rule editor */
		var datalist = E('datalist', { 'id': 'xm-geo-tags' },
			(tags.geosite || []).map(function(t) { return E('option', { 'value': 'geosite:' + t }); })
				.concat((tags.geoip || []).map(function(t) { return E('option', { 'value': 'geoip:' + t }); })));

		m = new form.Map(xm.CONF, _('分流'),
			_('决定哪些流量走代理。规则从上到下匹配，第一条命中的生效，都没命中的按“未命中规则时”处理。域名规则同时决定该域名用哪一路 DNS 解析。'));

		/* ------------------------------------------------------------ policy */
		s = m.section(form.NamedSection, 'global', 'global', _('默认策略'));

		o = s.option(form.ListValue, 'main_target', _('总节点'),
			_('代理流量的默认出口，可以是节点或节点组。规则里的“跟随总节点”也指它。'));
		xm.addNodeChoices(o, { direct: 'direct', groups: true });
		o.default = 'direct';

		o = s.option(form.ListValue, 'default_action', _('未命中规则时'),
			_('总节点为“直连”时，这里无论选什么都是直连。'));
		Object.keys(xm.DEFAULTS).forEach(function(k) { o.value(k, xm.DEFAULTS[k]); });
		o.default = 'proxy';

		/* ------------------------------------------------------------ rules */
		s = m.section(form.GridSection, 'rule', _('规则'),
			_('拖动手柄调整顺序。“国内域名”“广告”这类预置行也是普通规则，可以关掉、改动或挪到任意位置。端口和协议规则只对进入 Xray 的流量生效。'));
		s.addremove = true;
		s.anonymous = true;
		s.sortable = true;
		s.nodescriptions = true;
		s.addbtntitle = _('添加规则');
		s.modaltitle = function(sid) {
			return _('规则') + ' » ' + (uci.get(xm.CONF, sid, 'remarks') || _('新规则'));
		};

		o = s.option(form.Flag, 'enabled', _('启用'));
		o.editable = true;
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.Value, 'remarks', _('备注'));

		o = s.option(form.ListValue, 'rule_type', _('匹配类型'));
		Object.keys(RULE_TYPES).forEach(function(k) { o.value(k, RULE_TYPES[k]); });
		o.default = 'domain';
		o.textvalue = function(sid) {
			var t = uci.get(xm.CONF, sid, 'rule_type') || 'domain';
			return RULE_TYPES[t] || t;
		};

		o = s.option(form.DummyValue, '_value', _('匹配值'));
		o.modalonly = false;
		o.textvalue = function(sid) {
			var all = ruleValues(sid).join(', ');
			if (!all.length)
				return null;
			return E('span', { 'title': all }, all.length > 60 ? all.substring(0, 60) + '…' : all);
		};

		o = s.option(form.DynamicList, 'value', _('匹配值'),
			_('域名：geosite:google、domain:example.com、full:a.example.com、keyword:abc，adlist:all 表示“DNS → 广告过滤”里订阅的全部列表。' +
			  'IP：192.0.2.0/24、geoip:telegram。端口：443、1000-2000。协议：tcp 或 udp。'));
		o.modalonly = true;
		o.rmempty = false;
		o.cfgvalue = ruleValues;
		o.renderWidget = function() {
			var node = form.DynamicList.prototype.renderWidget.apply(this, arguments);
			var input = node.querySelector('input[type="text"]');
			if (input)
				input.setAttribute('list', 'xm-geo-tags');
			return node;
		};

		o = s.option(form.ListValue, 'outbound', _('出口'));
		xm.addNodeChoices(o, { main: true, direct: 'direct', block: true, groups: true });
		o.default = 'main';
		o.textvalue = function(sid) {
			return xm.targetLabel(uci.get(xm.CONF, sid, 'outbound') || 'main');
		};

		/* ------------------------------------------------------------ devices */
		var NETWORKS = {
			'tcp,udp': _('全部（TCP + UDP）'),
			'udp': _('仅 UDP'),
			'tcp': _('仅 TCP')
		};
		var macHints = {};
		(res[2] ? res[2].getMACHints() : []).forEach(function(h) {
			macHints[h[0].toLowerCase()] = h[1];
		});
		function macLabel(mac) {
			var hint = macHints[String(mac).toLowerCase()];
			return hint ? '%s (%s)'.format(mac, hint) : mac;
		}

		s = m.section(form.GridSection, 'device', _('按设备分流'),
			_('让某台设备的流量整体走指定出口，先于上面所有规则生效，适合给游戏机或某台电脑做 UDP/TCP 加速，或者让某台设备完全不走代理。设备按 MAC 地址识别；手机默认使用随机 MAC，需要先对这个 Wi-Fi 关闭“私有地址”。只选 UDP 或 TCP 时，其余流量仍按规则处理。'));
		s.addremove = true;
		s.anonymous = true;
		s.sortable = true;
		s.nodescriptions = true;
		s.addbtntitle = _('添加设备');
		s.modaltitle = function(sid) {
			return _('设备') + ' » ' + (uci.get(xm.CONF, sid, 'remarks') || _('新设备'));
		};

		o = s.option(form.Flag, 'enabled', _('启用'));
		o.editable = true;
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.Value, 'remarks', _('备注'));
		o.placeholder = _('客厅的游戏机');

		o = s.option(form.DynamicList, 'mac', _('MAC 地址'),
			_('可以从已知设备里选，也可以手动输入。一条里填多个地址表示这些设备用同一个出口。'));
		o.datatype = 'macaddr';
		o.rmempty = false;
		Object.keys(macHints).sort().forEach(function(mac) {
			o.value(mac.toUpperCase(), macLabel(mac.toUpperCase()));
		});
		o.textvalue = function(sid) {
			var macs = L.toArray(uci.get(xm.CONF, sid, 'mac'));
			return macs.length ? macs.map(macLabel).join('、') : null;
		};

		o = s.option(form.ListValue, 'network', _('流量'));
		Object.keys(NETWORKS).forEach(function(k) { o.value(k, NETWORKS[k]); });
		o.default = 'tcp,udp';
		o.textvalue = function(sid) {
			return NETWORKS[uci.get(xm.CONF, sid, 'network') || 'tcp,udp'];
		};

		o = s.option(form.ListValue, 'outbound', _('出口'));
		xm.addNodeChoices(o, { main: true, direct: 'direct', groups: true });
		o.default = 'main';
		o.textvalue = function(sid) {
			return xm.targetLabel(uci.get(xm.CONF, sid, 'outbound') || 'main');
		};

		return m.render().then(function(node) {
			var presets = E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('快速预设')),
				E('div', { 'class': 'cbi-section-descr' },
					_('一键设置“未命中规则时”并开关对应的预置规则，你自己的规则不受影响。点击后只是暂存，检查无误再“保存并应用”。')),
				E('div', {}, Object.keys(PRESETS).map(function(id) {
					return E('button', {
						'class': 'cbi-button cbi-button-action',
						'style': 'margin-right:.5em',
						'title': PRESETS[id].descr,
						'click': ui.createHandlerFn(this, function() { return applyPreset(id); })
					}, PRESETS[id].title);
				}))
			]);
			var first = node.querySelector('.cbi-section');
			if (first)
				first.parentNode.insertBefore(presets, first);
			node.appendChild(datalist);
			return node;
		});
	}
});
