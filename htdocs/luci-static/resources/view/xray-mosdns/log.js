'use strict';
'require view';
'require fs';
'require uci';
'require ui';
'require poll';

var CONF = 'xray-mosdns';
var LEVELS = [ 'debug', 'info', 'warning', 'error', 'none' ];

return view.extend({
	load: function() {
		return Promise.all([
			uci.load(CONF),
			fs.exec('/usr/libexec/xray-mosdns/log.sh', [ '300' ])
		]);
	},

	render: function(res) {
		var level = uci.get(CONF, 'global', 'log_level') || 'warning';

		var sel = E('select', { 'class': 'cbi-input-select' });
		LEVELS.forEach(function(l) {
			var o = E('option', { 'value': l }, l);
			if (l === level) o.selected = true;
			sel.appendChild(o);
		});

		var area = E('textarea', {
			'style': 'width:100%;height:420px;font-family:monospace;font-size:12px;white-space:pre;',
			'readonly': 'readonly',
			'spellcheck': 'false'
		}, [ (res && res[1] && res[1].stdout) || '' ]);

		function refresh() {
			return fs.exec('/usr/libexec/xray-mosdns/log.sh', [ '300' ]).then(function(r) {
				area.value = (r && r.stdout) || '';
			});
		}

		var save = E('button', { 'class': 'cbi-button cbi-button-apply' }, _('保存日志等级'));
		save.addEventListener('click', function() {
			uci.set(CONF, 'global', 'log_level', sel.value);
			uci.save().then(function() { return uci.apply(); }).then(function() {
				ui.addNotification(null, E('p', {}, _('日志等级已保存，重启服务后生效')), 'info');
			});
		});

		var reload = E('button', { 'class': 'cbi-button cbi-button-neutral' }, _('刷新'));
		reload.addEventListener('click', refresh);

		poll.add(refresh, 15);

		return E('div', {}, [
			E('h2', {}, _('日志')),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, _('日志等级')),
				E('div', { 'class': 'cbi-value-field' }, [
					sel, ' ', save,
					E('div', { 'class': 'cbi-value-description' },
						_('Xray 日志等级（debug/info/warning/error/none），保存后需重启插件服务生效。'))
				])
			]),
			E('p', {}, [ reload, ' ', _('最近 300 行 Xray / mosdns 日志（自动刷新）') ]),
			area
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
