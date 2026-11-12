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

		m = new form.Map('xray-mosdns', _('Routing rules'),
			_('Custom routing rules, evaluated before the legacy domain lists and the default outbound. ' +
			  'Domain values use Xray syntax: geosite:google, domain:openai.com, full:example.org, regexp:^ad\\. ' +
			  'IP values are CIDRs. Port values may be lists or ranges: 80,443,8000-9000.'));

		s = m.section(form.GridSection, 'rule', _('Rules'));
		s.addremove = true;
		s.anonymous = false;
		s.sortable = true;

		o = s.option(form.Flag, 'enabled', _('Enabled'));
		o.default = '0';

		o = s.option(form.Value, 'remarks', _('Remarks'));
		o.placeholder = 'block-ads';

		o = s.option(form.ListValue, 'rule_type', _('Type'));
		o.value('domain', _('Domain'));
		o.value('ip', _('IP / CIDR'));
		o.value('port', _('Port'));
		o.value('network', _('Network (tcp/udp)'));
		o.default = 'domain';

		o = s.option(form.Value, 'value', _('Value'));
		o.placeholder = 'geosite:google,domain:openai.com';
		o.rmempty = false;

		o = s.option(form.ListValue, 'outbound', _('Outbound'));
		o.value('proxy', _('Proxy'));
		o.value('direct', _('Direct'));
		o.value('block', _('Block'));
		o.default = 'proxy';

		return m.render();
	}
});
