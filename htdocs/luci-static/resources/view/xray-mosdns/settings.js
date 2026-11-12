'use strict';
'require view';
'require form';
'require uci';

function nodeOptions(o) {
	var nodes = uci.sections('xray-mosdns', 'node') || [];
	nodes.forEach(function(sec) {
		if (sec.enabled !== '1')
			return;
		o.value(sec['.name'], sec.remarks || sec.address || sec['.name']);
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

		s = m.section(form.NamedSection, 'global', 'global', _('General'));
		s.addremove = false;

		o = s.option(form.Flag, 'enabled', _('Enable'),
			_('When disabled the service will not start and the firewall is left untouched.'));
		o.rmempty = false;

		o = s.option(form.Flag, 'allow_coexist', _('Allow running next to PassWall'),
			_('Not recommended: both stacks install tproxy/DNS rules. Stop PassWall instead.'));
		o.default = '0';

		o = s.option(form.Value, 'tproxy_port', _('TProxy port'));
		o.datatype = 'port';
		o.default = '12345';

		o = s.option(form.Value, 'fwmark', _('fwmark'),
			_('Mark used to deliver the redirected packets locally, keep it unique.'));
		o.default = '0x1';

		o = s.option(form.Value, 'route_table', _('Policy routing table'));
		o.datatype = 'range(1,252)';
		o.default = '100';

		o = s.option(form.Flag, 'ipv6_enabled', _('Enable IPv6 (TProxy + policy routing)'),
			_('Experimental: requires the node to be reachable over IPv6 or to have AAAA records.'));
		o.default = '0';

		o = s.option(form.ListValue, 'node_mode', _('Node mode'));
		o.value('single', _('Single node'));
		o.value('balance', _('Load balance / failover'));
		o.default = 'single';

		o = s.option(form.ListValue, 'node', _('Node'));
		nodeOptions(o);
		o.depends('node_mode', 'single');
		o.rmempty = false;

		o = s.option(form.ListValue, 'balancer_strategy', _('Balancer strategy'));
		o.value('leastLoad', _('leastLoad (lowest latency, needs health checks)'));
		o.value('roundRobin', _('roundRobin'));
		o.value('random', _('random'));
		o.default = 'leastLoad';
		o.depends('node_mode', 'balance');

		o = s.option(form.ListValue, 'fallback_node', _('Fallback node'),
			_('Used when the balancer has no healthy member.'));
		nodeOptions(o);
		o.value('', _('Direct'));
		o.default = '';
		o.depends('node_mode', 'balance');

		o = s.option(form.ListValue, 'default_outbound', _('Default outbound'));
		o.value('proxy', _('Proxy (node/balancer)'));
		o.value('direct', _('Direct'));

		o = s.option(form.Flag, 'bypass_chn', _('Route mainland China destinations directly'),
			_('Uses geosite:cn / geoip:cn rules inside Xray.'));
		o.default = '1';

		o = s.option(form.Flag, 'sniffing', _('Sniffing (http/tls/quic)'));
		o.default = '1';

		o = s.option(form.ListValue, 'log_level', _('Xray log level'));
		['debug', 'info', 'warning', 'error', 'none'].forEach(function(v) { o.value(v); });
		o.default = 'warning';

		o = s.option(form.Value, 'xray_bin', _('Xray binary'));
		o.default = '/usr/bin/xray';

		o = s.option(form.Value, 'socks_port', _('Internal SOCKS port'),
			_('Local SOCKS inbound used by mosdns to send foreign DNS through the proxy.'));
		o.datatype = 'port';
		o.default = '1070';

		o = s.option(form.DynamicList, 'proxy_domains', _('Always proxied domains'),
			_('Xray domain syntax, e.g. geosite:google or domain:openai.com'));
		o.placeholder = 'geosite:geolocation-!cn';

		o = s.option(form.DynamicList, 'direct_domains', _('Always direct domains'));
		o.placeholder = 'geosite:cn';

		o = s.option(form.DynamicList, 'block_domains', _('Blocked domains'));

		o = s.option(form.DynamicList, 'bypass_ips', _('Destination IPs/CIDRs to bypass'),
			_('Subnets that should never be redirected.'));

		return m.render();
	}
});
