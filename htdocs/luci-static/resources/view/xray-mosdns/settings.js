'use strict';
'require view';
'require form';
'require uci';

function nodeOptions(o, onlyEnabled) {
	var nodes = uci.sections('xray-mosdns', 'node') || [];
	nodes.forEach(function(sec) {
		if (onlyEnabled && sec.enabled !== '1')
			return;
		var addr = sec.address ? sec.address + (sec.port ? ':' + sec.port : '') : '';
		var label = sec.remarks ? sec.remarks + (addr ? ' (' + addr + ')' : '') : (addr || sec['.name']);
		o.value(sec['.name'], label);
	});
}

return view.extend({
	load: function() {
		return uci.load('xray-mosdns');
	},

	render: function() {
		var m, s, o;

		m = new form.Map('xray-mosdns', _('Xray + mosdns-x'),
			_('Transparent proxy (TProxy) powered by Xray, with mosdns-x based DNS split, cache and ad blocking.'));

		// ---------------------------------------------------------- basic
		s = m.section(form.NamedSection, 'global', 'global', _('基本设置'));
		s.addremove = false;

		o = s.option(form.Flag, 'enabled', _('启用'));
		o.rmempty = false;

		// ---------------------------------------------------------- nodes
		s = m.section(form.NamedSection, 'global', 'global', _('节点与负载均衡'));
		s.addremove = false;

		o = s.option(form.ListValue, 'node_mode', _('节点模式'),
			_('负载均衡会在所有“启用”的节点之间选择：leastLoad 通过健康检查（每分钟探测一次延迟）选用当前最快的可用节点，属于自动选路/故障切换，不会按连接数分摊。'));
		o.value('single', _('单节点'));
		o.value('balance', _('负载均衡 / 故障切换'));
		o.default = 'single';

		o = s.option(form.ListValue, 'node', _('节点'), _('单节点模式下使用的节点（所有节点都会出现在列表里）。'));
		nodeOptions(o, false);
		o.depends('node_mode', 'single');
		o.rmempty = false;

		o = s.option(form.ListValue, 'balancer_strategy', _('均衡策略'));
		o.value('leastLoad', _('leastLoad：自动选择延迟最低的可用节点（推荐）'));
		o.value('roundRobin', _('roundRobin：轮询'));
		o.value('random', _('random：随机'));
		o.default = 'leastLoad';
		o.depends('node_mode', 'balance');

		o = s.option(form.ListValue, 'fallback_node', _('备用节点'),
			_('均衡器探测不到任何可用节点时使用（会从全部节点中选择，不要求该节点处于“启用”状态）。'));
		nodeOptions(o, false);
		o.value('', _('直连'));
		o.default = '';
		o.depends('node_mode', 'balance');

		// ---------------------------------------------------------- split mode
		s = m.section(form.NamedSection, 'global', 'global', _('分流模式'));
		s.addremove = false;

		o = s.option(form.ListValue, 'rule_mode', _('分流模式'),
			_('chnroute：国内流量直连，其余走代理；gfw：只有 GFW 列表走代理；global：全部走代理；custom：自定义。'));
		o.value('chnroute', _('大陆白名单（国内直连）'));
		o.value('gfw', _('GFW 列表（只有 GFW 域名走代理）'));
		o.value('global', _('全局代理'));
		o.value('custom', _('自定义'));
		o.default = 'chnroute';

		o = s.option(form.Flag, 'bypass_chn', _('国内直连（自定义模式）'),
			_('把 geosite:cn / geoip:cn 的流量直连。'));
		o.depends('rule_mode', 'custom');

		o = s.option(form.ListValue, 'default_outbound', _('默认出口（自定义模式）'),
			_('未命中任何规则时的出口。'));
		o.value('proxy', _('代理'));
		o.value('direct', _('直连'));
		o.depends('rule_mode', 'custom');

		// ---------------------------------------------------------- tproxy
		s = m.section(form.NamedSection, 'global', 'global', _('TProxy 与高级选项'));
		s.addremove = false;

		o = s.option(form.Value, 'tproxy_port', _('TProxy 端口'));
		o.datatype = 'port';
		o.default = '12345';

		o = s.option(form.Value, 'fwmark', _('fwmark'));
		o.default = '0x1';

		o = s.option(form.Value, 'route_table', _('策略路由表'));
		o.datatype = 'range(1,252)';
		o.default = '100';

		o = s.option(form.Flag, 'ipv6_enabled', _('启用 IPv6 TProxy'),
			_('实验性：需要节点支持 IPv6。'));
		o.default = '0';

		o = s.option(form.Flag, 'sniffing', _('嗅探域名（sniffing）'));
		o.default = '1';

		o = s.option(form.ListValue, 'log_level', _('日志级别'));
		['debug', 'info', 'warning', 'error', 'none'].forEach(function(v) { o.value(v); });
		o.default = 'warning';

		o = s.option(form.Value, 'xray_bin', _('Xray 程序路径'));
		o.default = '/usr/bin/xray';

		o = s.option(form.Value, 'socks_port', _('内部 SOCKS 端口'),
			_('mosdns 通过它把国外 DNS 交给 Xray 代理解析。'));
		o.datatype = 'port';
		o.default = '1070';

		o = s.option(form.Flag, 'allow_coexist', _('允许与 PassWall 同时运行'),
			_('不推荐：两套 TProxy/DNS 规则会冲突。'));
		o.default = '0';

		o = s.option(form.DynamicList, 'proxy_domains', _('旧版：强制代理域名'),
			_('兼容选项，推荐使用“规则”页面。'));
		o.placeholder = 'geosite:geolocation-!cn';

		o = s.option(form.DynamicList, 'direct_domains', _('旧版：强制直连域名'));
		o.placeholder = 'geosite:cn';

		o = s.option(form.DynamicList, 'block_domains', _('旧版：阻断域名'));

		o = s.option(form.DynamicList, 'bypass_ips', _('直连目标 IP/CIDR'),
			_('这些目标不会被 TProxy 劫持。'));
		o.placeholder = '203.0.113.0/24';

		return m.render();
	}
});
