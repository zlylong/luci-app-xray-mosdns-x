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

		m = new form.Map('xray-mosdns', _('分流规则'),
			_('规则按顺序匹配，命中后使用对应策略；未命中时按“设置 → 分流模式”处理。' +
			  '如需按端口/协议分流，可直接在 UCI 中添加 rule_type=\'port\' 或 \'network\' 的规则段。' +
			  '域名使用 Xray 语法：geosite:google、domain:openai.com、full:example.org、regexp:^ad\\.；' +
			  'IP 使用 CIDR：10.0.0.0/8。'));

		s = m.section(form.GridSection, 'rule', _('规则列表'));
		s.addremove = true;
		s.anonymous = false;
		s.sortable = true;

		o = s.option(form.Flag, 'enabled', _('启用'));
		o.default = '0';

		o = s.option(form.Value, 'remarks', _('备注'));
		o.placeholder = 'block-ads';

		o = s.option(form.ListValue, 'rule_type', _('分流方式'));
		o.value('domain', _('域名'));
		o.value('ip', _('IP / CIDR'));
		o.default = 'domain';

		o = s.option(form.Value, 'value', _('匹配值'),
			_('多个值用逗号分隔。'));
		o.placeholder = 'geosite:google,domain:openai.com';
		o.rmempty = false;

		o = s.option(form.ListValue, 'outbound', _('策略'));
		o.value('proxy', _('代理'));
		o.value('direct', _('直连'));
		o.value('block', _('阻断'));
		o.default = 'proxy';

		return m.render();
	}
});
