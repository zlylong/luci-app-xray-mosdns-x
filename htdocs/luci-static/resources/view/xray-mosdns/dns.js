'use strict';
'require view';
'require form';
'require uci';
'require xray-mosdns.ui as xm';

return view.extend({
	load: function() {
		return uci.load('xray-mosdns');
	},

	render: function() {
		var m, s, o;

		m = new form.Map('xray-mosdns', '', '');

		s = m.section(form.NamedSection, 'dns', 'dns', _('上游与缓存'));
		s.addremove = false;

		o = s.option(form.Flag, 'enabled', _('Enable mosdns-x'),
			_('mosdns-x answers LAN clients directly. dnsmasq keeps DHCP and local host names and is not reconfigured.'));
		o.default = '1';

		o = s.option(form.Flag, 'redirect', _('Redirect LAN DNS to mosdns-x'),
			_('Every port 53 query entering from the LAN (including clients with a hard-coded DNS server) is redirected to mosdns-x by nftables. Disable only if you point clients at mosdns-x yourself.'));
		o.default = '1';

		o = s.option(form.Value, 'mosdns_bin', _('mosdns binary'));
		o.default = '/usr/bin/mosdns';

		o = s.option(form.Value, 'listen_port', _('mosdns listen port'),
			_('Port 53 on the LAN is redirected here. Avoid 5353 (mDNS).'));
		o.datatype = 'port';
		o.default = '5335';

		o = s.option(form.Value, 'cache_size', _('Cache entries'));
		o.datatype = 'uinteger';
		o.default = '8192';

		o = s.option(form.Flag, 'cache_everything', _('Cache EDNS queries'),
			_('Required by most modern clients, whose queries carry an EDNS0 OPT record.'));
		o.default = '1';

		o = s.option(form.Flag, 'adblock', _('Block ad domains'),
			_('Uses geosite:category-ads-all from /usr/share/v2ray/geosite.dat.'));
		o.default = '1';

		o = s.option(form.Flag, 'filter_proxy_ipv6', _('Drop AAAA for proxied domains'),
			_('Prevents IPv6 answers from bypassing the proxy.'));
		o.default = '1';

		o = s.option(form.Value, 'bootstrap', _('Bootstrap resolver'),
			_('Plain resolver used to resolve DoH/DoT hostnames and the node address.'));
		o.datatype = 'ipaddr';
		o.default = '223.5.5.5';

		o = s.option(form.Value, 'remote_dns', _('Foreign DNS server'),
			_('Queried through the proxy for non-mainland domains.'));
		o.datatype = 'ipaddr';
		o.default = '1.1.1.1';

		o = s.option(form.DynamicList, 'domestic_dns', _('Domestic upstreams'),
			_('DoH/DoT/plain, one per line, e.g. https://dns.alidns.com/dns-query'));

		o = s.option(form.DynamicList, 'hosts', _('Static hosts'),
			_('"domain ip" pairs, e.g. v1.example.com 203.0.113.10'));

		return xm.page({
			title: 'DNS',
			lede: 'LAN 的 53 端口查询由 nftables 重定向到 mosdns-x：分流规则与转发共用同一套规则，国内域名走国内上游，代理域名经内部 SOCKS 交给 Xray 解析并写入内核集合；本地主机名和反向解析仍交给 dnsmasq。'
		}, [ m.render() ]);
	}
});
