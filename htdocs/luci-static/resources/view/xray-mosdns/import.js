'use strict';
'require view';
'require fs';
'require uci';
'require ui';

return view.extend({
	load: function() {
		return uci.load('xray-mosdns');
	},

	handleImport: function(ev) {
		var area = document.getElementById('xray-mosdns-links');
		var text = area ? area.value : '';
		if (!text.trim( )) {
			ui.addNotification(null, E('p', {}, _('Nothing to import')), 'warning');
			return;
		}
		var self = this;
		return fs.write('/tmp/xray-mosdns-import.txt', text).then(function() {
			return fs.exec('/usr/libexec/xray-mosdns/import-links.sh', [ '/tmp/xray-mosdns-import.txt' ]);
		}).then(function(res) {
			var out = {};
			try { out = JSON.parse((res && res.stdout) || '{}'); } catch (e) { out = {}; }
			if (!out.ok) {
				ui.addNotification(null, E('p', {}, _('Import failed: %s').format((out.error || 'unknown error'))), 'error');
				return;
			}
			ui.addNotification(null, E('p', {},
				_('Imported %d node(s), skipped %d line(s). Enable and select a node on the Nodes page.').format(out.imported || 0, out.skipped || 0)),
				'info');
			return uci.load('xray-mosdns');
		}).catch(function(err) {
			ui.addNotification(null, E('p', {}, _('Import failed: %s').format(err.message || err)), 'error');
		});
	},

	render: function() {
		var area = E('textarea', {
			'id': 'xray-mosdns-links',
			'style': 'width:100%;height:320px;font-family:monospace;font-size:12px;',
			'spellcheck': 'false',
			'placeholder': 'vless://...\nvmess://...\ntrojan://...\nss://...'
		}, []);

		return E('div', {}, [
			E('h2', {}, _('Import share links')),
			E('p', {}, _('Paste proxy share links, one per line. Supported: vless, vmess, trojan, shadowsocks (SIP002). ' +
				'Imported nodes are created disabled; review them on the Nodes page.')),
			area,
			E('p', {}, E('button', {
				'class': 'cbi-button cbi-button-apply',
				'click': ui.createHandlerFn(this, 'handleImport')
			}, _('Import'))),
			E('p', { 'class': 'cbi-section-descr' },
				_('Note: Hysteria2 / TUIC / SSR links are not supported by Xray and will be skipped.'))
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
