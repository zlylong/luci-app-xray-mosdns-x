'use strict';
'require view';
'require form';
'require uci';
'require tools.widgets as widgets';
'require xray-mosdns.common as xm';

return view.extend({
	load: function() {
		return uci.load(xm.CONF);
	},

	render: function() {
		var m, s, o;

		m = new form.Map(xm.CONF, _('系统'),
			_('运行参数。这里的选项通常不需要改。'));

		s = m.section(form.NamedSection, 'global', 'global', _('运行参数'));
		s.tab('proxy', _('透明代理'));
		s.tab('ports', _('端口与路径'));

		o = s.taboption('proxy', widgets.NetworkSelect, 'lan_ifaces', _('接口'),
			_('代理从这些接口进入的流量，DNS 重定向也只对它们生效。除了 LAN，也可以选 VPN 之类的接口，让拨入的设备同样走分流；没选中的接口（包括 WAN）不会被处理。'));
		o.multiple = true;
		o.nocreate = true;
		o.filter = function(sid, name) { return name !== 'loopback'; };
		o.default = 'lan';
		o.rmempty = false;

		o = s.taboption('proxy', form.ListValue, 'proxy_router', _('代理路由器自身的流量'),
			_('路由器自己发起的连接（下载 geo 数据和组件更新、软件包安装、DDNS 等）也按分流规则走代理，路由器自己的域名解析同时改由 mosdns-x 负责。注意：默认出口是代理时，路由器上的 VPN 客户端、内网穿透等连接也会被送进代理，需要把它们的服务器地址加到“不代理的目标”；UDP 一般不需要开。'));
		o.value('0', _('关闭'));
		o.value('tcp', _('仅 TCP'));
		o.value('tcp,udp', _('TCP + UDP'));
		o.default = '0';

		o = s.taboption('proxy', form.Flag, 'kernel_split', _('内核分流'),
			_('由 nftables 按目的地址决定是否进入 Xray：直连流量留在内核转发，只有需要代理的流量才交给 Xray。关闭后所有流量都进入 Xray 再分流。'));
		o.default = '1';
		o.rmempty = false;

		o = s.taboption('proxy', form.DynamicList, 'bypass_ips', _('不代理的目标'),
			_('这些 IP 或网段始终直连。'));
		o.datatype = 'or(ipaddr, cidr)';
		o.placeholder = '203.0.113.0/24';

		o = s.taboption('proxy', form.Flag, 'ipv6_enabled', _('IPv6 透明代理'),
			_('实验性功能，需要节点支持 IPv6。'));
		o.default = '0';

		o = s.taboption('proxy', form.Flag, 'sniffing', _('嗅探域名'),
			_('从 TLS/HTTP/QUIC 握手中读出域名，供 Xray 的域名规则使用。'));
		o.default = '1';

		o = s.taboption('proxy', form.Value, 'probe_url', _('节点组探测地址'),
			_('节点组用它判断成员是否可用，需要是经代理可达、返回很小的地址。'));
		o.placeholder = 'https://www.gstatic.com/generate_204';

		o = s.taboption('proxy', form.Value, 'probe_url_backup', _('备用探测地址'),
			_('可留空。所有节点组的全部成员同时探测失败并持续一段时间（约 3 个探测间隔加 1 分钟）时，多半是探测地址本身不可达，这时自动换用备用地址；切换需要重启 Xray，两次切换至少间隔 10 分钟。重启路由器后回到主地址。'));
		o.placeholder = 'https://cp.cloudflare.com/generate_204';

		o = s.taboption('proxy', form.Value, 'probe_interval', _('节点组探测间隔'),
			_('例如 30s、1m、5m。间隔越短切换越快，探测流量也越多。'));
		o.placeholder = '1m';
		o.validate = function(sid, v) {
			return (!v || /^[0-9]+[smh]$/.test(v)) ? true : _('格式应为数字加 s、m 或 h');
		};

		o = s.taboption('proxy', form.ListValue, 'log_level', _('Xray 日志级别'));
		[ 'debug', 'info', 'warning', 'error', 'none' ].forEach(function(v) { o.value(v); });
		o.default = 'warning';

		o = s.taboption('ports', form.Value, 'xray_bin', _('Xray 程序路径'));
		o.default = '/usr/bin/xray';

		o = s.taboption('ports', form.Value, 'geo_dir', _('Geo 数据目录'),
			_('geosite.dat 和 geoip.dat 所在的目录。mosdns-x、内核集合和 Xray 都从这里读取，“更新”页也下载到这里。'));
		o.placeholder = '/usr/share/v2ray';
		o.validate = function(sid, v) {
			return (!v || /^\/[A-Za-z0-9_.\/-]*$/.test(v)) ? true : _('需要是以 / 开头的目录路径');
		};

		o = s.taboption('ports', form.Value, 'tproxy_port', _('TProxy 端口'));
		o.datatype = 'port';
		o.default = '12345';

		o = s.taboption('ports', form.Value, 'socks_port', _('内部 SOCKS 端口'),
			_('mosdns-x 通过它把需要代理的 DNS 查询交给 Xray。'));
		o.datatype = 'port';
		o.default = '1070';

		o = s.taboption('ports', form.Value, 'api_port', _('本地统计 API 端口'),
			_('概览页的节点流量和节点组状态从这里读取。'));
		o.datatype = 'port';
		o.default = '10085';

		o = s.taboption('ports', form.Value, 'fwmark', _('防火墙标记'));
		o.default = '0x1';

		o = s.taboption('ports', form.Value, 'self_mark', _('自身流量标记'),
			_('Xray 和 mosdns-x 自己发出的包带这个标记，代理路由器自身流量时靠它避免回环。不能和防火墙标记相同。'));
		o.default = '0xff';

		o = s.taboption('ports', form.Value, 'route_table', _('策略路由表'));
		o.datatype = 'range(1,252)';
		o.default = '100';

		return m.render();
	}
});
