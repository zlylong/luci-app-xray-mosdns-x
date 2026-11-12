'use strict';
'require view';
'require form';
'require uci';

return view.extend({
	load: function() {
		return uci.load('xray-mosdns');
	},

	render: function() {
		var m, s, o;

		m = new form.Map('xray-mosdns', _('高级设置'),
			_('Transparent proxy (TProxy) powered by Xray, with mosdns-x based DNS split, cache and ad blocking. ' +
			  'Node/load-balancing options are on the Nodes page, split rules and the main target on the Rules page.'));

		s = m.section(form.NamedSection, 'global', 'global', _('基本设置'));
		s.addremove = false;

		o = s.option(form.Flag, 'enabled', _('启用'));
		o.rmempty = false;

		o = s.option(form.Flag, 'allow_coexist', _('允许与 PassWall 同时运行'),
			_('不推荐：两套 TProxy/DNS 规则会冲突。'));
		o.default = '0';

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

		o = s.option(form.Value, 'api_port', _('本地统计 API 端口'),
			_('Xray 统计接口，用于“流量统计”页面读取节点流量。'));
		o.datatype = 'port';
		o.default = '10085';

		o = s.option(form.DynamicList, 'bypass_ips', _('直连目标 IP/CIDR'),
			_('这些目标不会被 TProxy 劫持。'));
		o.placeholder = '203.0.113.0/24';

		return m.render();
	}
});
