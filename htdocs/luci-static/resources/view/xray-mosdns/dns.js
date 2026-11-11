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

		m = new form.Map('xray-mosdns', _('DNS'),
			_('mosdns-x handles client DNS: mainland domains are resolved through the domestic upstreams, everything else is sent through the proxy via the internal SOCKS inbound.'));

		s = m.section(form.NamedSection, 'dns', 'dns', _('DNS'));
		s.addremove = false;

		o = s.option(form.Flag, 'enabled', _('Enable mosdns-x'),
			_('When enabled, dnsmasq is pointed at the local mosdns listener and restored on stop.'));
		o.default = '1';

		o = s.option(form.Value, 'mosdns_bin', _('mosdns binary'));
		o.default = '/usr/bin/mosdns';

		o = s.option(form.Value, 'listen_port', _('mosdns listen port'),
			_('dnsmasq will forward to 127.0.0.1:<port>.'));
		o.datatype = 'port';
		o.default = '5353';

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

		return m.render();
	}
});
