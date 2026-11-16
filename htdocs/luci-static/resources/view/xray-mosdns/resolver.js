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
			_('mosdns-x 随插件的总开关一起启停。LAN 的 DNS 查询由它应答。哪些域名走国内上游、哪些经代理解析、哪些被拦截（包括广告），都由“分流”页的规则决定；本地主机名和反向解析仍交给 dnsmasq。'));

		s = m.section(form.NamedSection, 'dns', 'dns');
		s.tab('general', _('接管'));
		s.tab('upstream', _('上游'));
		s.tab('ipv6tab', _('IPv6'));
		s.tab('cachetab', _('缓存'));
		s.tab('logtab', _('拦截与日志'));

		/* ------------------------------------------------------------ takeover */
		o = s.taboption('general', form.Flag, 'redirect', _('重定向 LAN 的 53 端口'),
			_('从 LAN 进入的所有 DNS 查询（包括写死 DNS 服务器的客户端）都交给 mosdns-x。dnsmasq 的配置不会被改动；仅当你自行把客户端指向 mosdns-x 时才关闭。'));
		o.default = '1';
		o.rmempty = false;

		o = s.taboption('general', form.Flag, 'fallback', _('故障时交给 dnsmasq'),
			_('看门狗每 5 秒探测一次 mosdns-x：连续两次没有应答就撤掉重定向，让 dnsmasq 接管 LAN 的解析，恢复应答后自动切回。回退期间域名规则不再学到新地址，分流只按 IP 规则和默认出口生效。关闭后，mosdns-x 故障时 LAN 上的解析会全部超时。'));
		o.default = '1';
		o.rmempty = false;
		o.depends('redirect', '1');

		o = s.taboption('general', form.Value, 'listen_port', _('监听端口'),
			_('不要用 5353，那是 mDNS 的端口。'));
		o.datatype = 'port';
		o.default = '5335';

		o = s.taboption('general', form.Value, 'mosdns_bin', _('mosdns-x 程序路径'));
		o.default = '/usr/bin/mosdns';

		/* ------------------------------------------------------------ upstream */
		o = s.taboption('upstream', form.DynamicList, 'domestic_dns', _('国内上游'),
			_('直连访问，支持 DoH、DoT 和明文，例如 https://dns.alidns.com/dns-query。'));

		o = s.taboption('upstream', form.DynamicList, 'remote_dns', _('国外上游'),
			_('始终经代理访问，用于需要走代理的域名。填 IP 地址表示普通 DNS（TCP），也可以填 tcp://、tls://、https:// 开头的地址，例如 https://1.1.1.1/dns-query。填多个时同时查询，用最先返回的结果。'));
		o.placeholder = '1.1.1.1';
		o.validate = function(sid, v) {
			if (!v)
				return true;
			return (/^(\d{1,3}\.){3}\d{1,3}$/.test(v) || /^[0-9a-fA-F:]*:[0-9a-fA-F:]*$/.test(v) ||
				/^(tcp|tls|https|h3|quic):\/\/[^\s'"\\]+$/.test(v)) ? true : _('需要是 IP 地址，或 tcp/tls/https/h3/quic 开头的地址');
		};

		o = s.taboption('upstream', form.Value, 'bootstrap', _('引导解析器'),
			_('用来解析 DoH/DoT 上游自身域名的明文 DNS，需为国内可直连的 IP。'));
		o.datatype = 'ipaddr';
		o.default = '223.5.5.5';

		o = s.taboption('upstream', form.DynamicList, 'hosts', _('静态解析'),
			_('格式为“域名 IP”，例如 v1.example.com 203.0.113.10。'));

		/* ------------------------------------------------------------ cache / filter */
		o = s.taboption('ipv6tab', form.Flag, 'filter_proxy_ipv6', _('代理域名不返回 AAAA'),
			_('走代理解析的域名只返回 IPv4 地址：AAAA 查询和可以携带 IPv6 地址提示的 HTTPS 记录查询都返回空。未启用 IPv6 透明代理时保持开启，否则这些域名会通过 IPv6 绕过代理直接出去。'));
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

		o = s.taboption('cachetab', form.Value, 'min_ttl', _('最小 TTL（秒）'),
			_('把有效期短于这个值的应答抬高到这个值，减少客户端反复查询。0 表示不改动；一般填 60 到 300。'));
		o.datatype = 'range(0,86400)';
		o.placeholder = '0';

		/* ------------------------------------------------------------ blocking / log */
		o = s.taboption('logtab', form.ListValue, 'block_mode', _('拦截方式'),
			_('被“阻断”规则和广告过滤拦下的域名怎么应答。返回 0.0.0.0 时应用会立刻连接失败；返回“域名不存在”时，个别应用会反复重试。'));
		o.value('nxdomain', _('返回“域名不存在”'));
		o.value('zero', _('返回 0.0.0.0'));
		o.default = 'nxdomain';

		o = s.taboption('logtab', form.Flag, 'query_log', _('记录查询'),
			_('把每一次查询写进 /tmp/mosdns-x.log，供“查询日志”页查看。日志在内存里，超过 4 MB 时只保留最新的 4000 行，重启后清空。'));
		o.default = '0';

		return m.render();
	}
});
