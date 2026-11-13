'use strict';
'require view';
'require fs';
'require uci';
'require ui';
'require xray-mosdns.ui as xm';

var CONF = 'xray-mosdns';

return view.extend({
	load: function() {
		return uci.load(CONF);
	},

	render: function() {
		var area = E('textarea', {
			'id': 'nm-import',
			'class': 'xmx-code',
			'style': 'width:100%;height:300px;',
			'placeholder': 'vless://...\nvmess://...\ntrojan://...\nss://...\nhysteria2://...'
		});
		var output = E('pre', { 'class': 'xmx-code' }, []);

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

		return xm.page({
			title: '节点订阅',
			lede: '粘贴分享链接，一次导入多个节点。导入后节点默认禁用，去“节点列表”启用并决定它们参与哪种选路。',
			lamps: [ xm.lamp('on', '支持', 'vless · vmess · trojan · ss · hysteria2') ]
		}, [
			xm.section('粘贴链接', [
				area,
				E('div', { 'class': 'xmx-row', 'style': 'margin-top:10px' }, [
					btn,
					E('span', { 'class': 'xmx-muted xmx-small' }, '每行一个；支持 vless / vmess / trojan / shadowsocks（SIP002）/ hysteria2（hy2://）。')
				])
			]),
			xm.section('执行结果', [ output ])
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
