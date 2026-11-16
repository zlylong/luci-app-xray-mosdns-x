'use strict';
'require view';
'require fs';
'require ui';
'require poll';
'require xray-mosdns.common as xm';

var LINES = '300';

return view.extend({
	load: function() {
		return L.resolveDefault(fs.exec('/usr/libexec/xray-mosdns/log.sh', [ LINES ]), {});
	},

	render: function(res) {
		var box = E('textarea', {
			'class': 'cbi-input-textarea', 'readonly': '', 'wrap': 'off', 'rows': 30,
			'style': 'width:100%;font-family:monospace;font-size:12px'
		});
		var follow = E('input', { 'type': 'checkbox', 'id': 'xm-log-follow', 'checked': '' });

		function show(r) {
			var atBottom = (box.scrollTop + box.clientHeight >= box.scrollHeight - 4);
			box.value = ((r && r.stdout) || '').trim() || _('暂无日志');
			// keep the reader's place unless they were already at the end
			if (atBottom)
				box.scrollTop = box.scrollHeight;
		}

		function refresh() {
			return L.resolveDefault(fs.exec('/usr/libexec/xray-mosdns/log.sh', [ LINES ]), {}).then(show);
		}

		show(res);
		window.setTimeout(function() { box.scrollTop = box.scrollHeight; }, 0);

		poll.add(function() {
			return follow.checked ? refresh() : Promise.resolve();
		}, 5);

		return E('div', {}, [
			E('h2', {}, _('运行日志')),
			E('div', { 'class': 'cbi-map-descr' },
				_('系统日志中与 Xray、mosdns-x 和本插件有关的最近 %s 行。Xray 的详细程度在“系统 → Xray 日志级别”里调。').format(LINES)),
			E('div', { 'class': 'cbi-section' }, [
				box,
				E('div', { 'class': 'cbi-page-actions', 'style': 'text-align:left' }, [
					E('button', { 'class': 'cbi-button cbi-button-action', 'click': ui.createHandlerFn(this, refresh) }, _('刷新')),
					' ',
					follow,
					E('label', { 'for': 'xm-log-follow' }, ' ' + _('每 5 秒自动刷新'))
				])
			])
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
