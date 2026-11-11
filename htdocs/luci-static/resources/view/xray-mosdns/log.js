'use strict';
'require view';
'require fs';
'require ui';

return view.extend({
	load: function() {
		return fs.exec('/usr/libexec/xray-mosdns/log.sh', [ '200' ]);
	},

	render: function(res) {
		var out = (res && res.stdout) || '';

		var area = E('textarea', {
			'style': 'width:100%;height:480px;font-family:monospace;font-size:12px;white-space:pre;',
			'readonly': 'readonly',
			'spellcheck': 'false'
		}, [ out ]);

		return E('div', {}, [
			E('h2', {}, _('Log')),
			E('p', {}, _('Recent Xray / mosdns lines from logread.')),
			area
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
