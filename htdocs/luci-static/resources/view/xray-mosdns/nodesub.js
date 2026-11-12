'use strict';
'require view';
'require fs';
'require uci';
'require ui';

var CONF = 'xray-mosdns';

return view.extend({
	load: function() {
		return uci.load(CONF);
	},

	render: function() {
		var area = E('textarea', {
			'id': 'nm-import',
			'style': 'width:100%;height:320px;font-family:monospace;font-size:12px;',
			'placeholder': 'vless://...\nvmess://...\ntrojan://...\nss://...\nhysteria2://...'
		});
		var output = E('pre', { 'style': 'white-space:pre-wrap;max-height:160px;overflow:auto;background:#f5f5f5;padding:8px;border-radius:4px;' }, []);

		var btn = E('button', { 'class': 'cbi-button cbi-button-apply' }, '导入节点');
		btn.addEventListener('click', function() {
			var text = area.value || '';
			if (!text.trim()) {
				ui.addNotification(null, E('p', {}, '没有可导入的内容'), 'warning');
				return;
			}
			fs.write('/tmp/xray-mosdns-import.txt', text).then(function() {
				return fs.exec('/usr/libexec/xray-mosdns/import-links.sh', [ '/tmp/xray-mosdns-import.txt' ]);
			}).then(function(res) {
				var out = {};
				try { out = JSON.parse((res && res.stdout) || '{}'); } catch (e) { out = {}; }
				output.textContent = JSON.stringify(out, null, 2);
				if (!out.ok) {
					ui.addNotification(null, E('p', {}, out.error || '导入失败'), 'error');
					return;
				}
				ui.addNotification(null, E('p', {},
					'已导入 %d 个节点，跳过 %d 行；导入的节点默认禁用，请到“节点列表”启用并选择。'
						.format(out.imported || 0, out.skipped || 0)), 'info');
				return uci.load(CONF);
			}).catch(function(err) {
				ui.addNotification(null, E('p', {}, String(err.message || err)), 'error');
			});
		});

		return E('div', {}, [
			E('h2', {}, '节点订阅 / 导入'),
			E('p', {}, '粘贴分享链接（每行一个），支持 vless / vmess / trojan / shadowsocks（SIP002）/ hysteria2（hysteria2:// 或 hy2://）。'
				+ '导入的节点默认禁用，请到“节点列表”中启用并选择。'),
			area,
			E('p', {}, btn),
			E('p', { 'class': 'cbi-value-description' }, '注意：Hysteria2 / TUIC / SSR 之外的协议暂不支持。'),
			E('h2', {}, '执行结果'),
			output
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
