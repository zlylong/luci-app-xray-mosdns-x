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

		m = new form.Map('xray-mosdns', _('Nodes'),
			_('Proxy nodes. The node selected on the Settings page is used as the default outbound.'));

		s = m.section(form.GridSection, 'node', _('Node'));
		s.addremove = true;
		s.anonymous = false;

		o = s.option(form.Flag, 'enabled', _('Enabled'));
		o.default = '0';

		o = s.option(form.Value, 'remarks', _('Remarks'));
		o.placeholder = 'my-vps';
		o.rmempty = false;

		o = s.option(form.ListValue, 'type', _('Type'));
		o.value('vless', 'VLESS');
		o.value('vmess', 'VMess');
		o.value('trojan', 'Trojan');
		o.value('shadowsocks', 'Shadowsocks');
		o.default = 'vless';

		o = s.option(form.Value, 'address', _('Address'));
		o.rmempty = false;

		o = s.option(form.Value, 'port', _('Port'));
		o.datatype = 'port';
		o.default = '443';

		o = s.option(form.Value, 'uuid', _('UUID'), _('VLESS/VMess UUID'));
		o.depends('type', 'vless');
		o.depends('type', 'vmess');

		o = s.option(form.Value, 'alter_id', _('Alter ID'));
		o.datatype = 'uinteger';
		o.default = '0';
		o.depends('type', 'vmess');

		o = s.option(form.Value, 'password', _('Password'), _('Trojan/Shadowsocks password'));
		o.password = true;
		o.depends('type', 'trojan');
		o.depends('type', 'shadowsocks');

		o = s.option(form.ListValue, 'method', _('Shadowsocks method'));
		o.value('aes-128-gcm');
		o.value('aes-256-gcm');
		o.value('chacha20-poly1305');
		o.value('xchacha20-poly1305');
		o.depends('type', 'shadowsocks');

		o = s.option(form.Flag, 'tls', _('TLS'));
		o.default = '1';

		o = s.option(form.Value, 'tls_server_name', _('TLS SNI'),
			_('Defaults to the node address.'));

		o = s.option(form.Value, 'fingerprint', _('uTLS fingerprint'));
		['chrome', 'firefox', 'safari', 'edge', 'random'].forEach(function(v) { o.value(v); });
		o.default = 'chrome';

		o = s.option(form.Flag, 'allow_insecure', _('Allow insecure TLS'));
		o.default = '0';

		o = s.option(form.ListValue, 'transport', _('Transport'));
		o.value('tcp', 'TCP');
		o.value('ws', 'WebSocket');
		o.value('grpc', 'gRPC');
		o.value('http', 'HTTP/2');
		o.value('xhttp', 'XHTTP');
		o.default = 'tcp';

		o = s.option(form.Value, 'path', _('Path'), _('For ws/http/xhttp transports'));
		o.default = '/';
		o.depends('transport', 'ws');
		o.depends('transport', 'http');
		o.depends('transport', 'xhttp');

		o = s.option(form.Value, 'host', _('Host header'), _('For ws/http/xhttp transports'));

		o = s.option(form.Value, 'service_name', _('gRPC service name'));
		o.depends('transport', 'grpc');

		o = s.option(form.Value, 'flow', _('VLESS flow'), _('e.g. xtls-rprx-vision'));
		o.depends('type', 'vless');

		return m.render();
	}
});
