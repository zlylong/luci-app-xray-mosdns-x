'use strict';
'require view';
'require form';
'require uci';
'require xray-mosdns.common as xm';

return view.extend({
	load: function() {
		return uci.load(xm.CONF);
	},

	render: function() {
		var m, s, o;

		m = new form.Map(xm.CONF, 'DNS',
			_('LAN 的 DNS 查询由 mosdns-x 应答。哪些域名走国内上游、哪些经代理解析、哪些被拦截（包括广告），都由“分流”页的规则决定；本地主机名和反向解析仍交给 dnsmasq。'));

		s = m.section(form.NamedSection, 'dns', 'dns');
		s.tab('general', _('接管'));
		s.tab('upstream', _('上游'));
		s.tab('ipv6tab', _('IPv6'));
		s.tab('cachetab', _('缓存'));

		/* ------------------------------------------------------------ takeover */
		o = s.taboption('general', form.Flag, 'enabled', _('启用 mosdns-x'),
			_('关闭后不启动 mosdns-x，内核分流也随之关闭（集合靠 DNS 应答填充）。'));
		o.default = '1';
		o.rmempty = false;

		o = s.taboption('general', form.Flag, 'redirect', _('重定向 LAN 的 53 端口'),
			_('从 LAN 进入的所有 DNS 查询（包括写死 DNS 服务器的客户端）都交给 mosdns-x。dnsmasq 的配置不会被改动；仅当你自行把客户端指向 mosdns-x 时才关闭。'));
		o.default = '1';
		o.rmempty = false;
		o.depends('enabled', '1');

		o = s.taboption('general', form.Value, 'listen_port', _('监听端口'),
			_('不要用 5353，那是 mDNS 的端口。'));
		o.datatype = 'port';
		o.default = '5335';
		o.depends('enabled', '1');

		o = s.taboption('general', form.Value, 'mosdns_bin', _('mosdns-x 程序路径'));
		o.default = '/usr/bin/mosdns';

		/* ------------------------------------------------------------ upstream */
		o = s.taboption('upstream', form.DynamicList, 'domestic_dns', _('国内上游'),
			_('直连访问，支持 DoH、DoT 和明文，例如 https://dns.alidns.com/dns-query。'));

		o = s.taboption('upstream', form.Value, 'remote_dns', _('国外上游'),
			_('经代理访问，用于需要走代理的域名。'));
		o.datatype = 'ipaddr';
		o.default = '1.1.1.1';

		o = s.taboption('upstream', form.Value, 'bootstrap', _('引导解析器'),
			_('用来解析 DoH/DoT 上游自身域名的明文 DNS，需为国内可直连的 IP。'));
		o.datatype = 'ipaddr';
		o.default = '223.5.5.5';

		o = s.taboption('upstream', form.DynamicList, 'hosts', _('静态解析'),
			_('格式为“域名 IP”，例如 v1.example.com 203.0.113.10。'));

		/* ------------------------------------------------------------ cache / filter */
		o = s.taboption('ipv6tab', form.Flag, 'filter_proxy_ipv6', _('代理域名不返回 AAAA'),
			_('走代理解析的域名只返回 IPv4 地址。未启用 IPv6 透明代理时保持开启，否则这些域名会通过 IPv6 绕过代理直接出去。'));
		o.default = '1';

		o = s.taboption('ipv6tab', form.Flag, 'filter_direct_ipv6', _('直连域名不返回 AAAA'),
			_('走国内上游解析的域名只返回 IPv4 地址。宽带没有 IPv6，或 IPv6 线路质量差、想让直连流量都走 IPv4 时开启。'));
		o.default = '0';

		o = s.taboption('cachetab', form.Value, 'cache_size', _('缓存条数'));
		o.datatype = 'uinteger';
		o.default = '8192';

		o = s.taboption('cachetab', form.Flag, 'cache_everything', _('缓存带 EDNS 的查询'),
			_('多数现代客户端的查询都带 EDNS0，关闭后这些查询不会被缓存。'));
		o.default = '1';

		return m.render();
	}
});
