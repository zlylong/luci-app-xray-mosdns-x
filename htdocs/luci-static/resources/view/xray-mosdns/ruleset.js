'use strict';
'require view';
'require uci';
'require ui';

var CONF = 'xray-mosdns';

function nodes() {
	return uci.sections(CONF, 'node') || [];
}

function fieldRow(title, node, hint) {
	return E('div', { 'class': 'cbi-value' }, [
		E('label', { 'class': 'cbi-value-title' }, title),
		E('div', { 'class': 'cbi-value-field' }, [ node, hint ? E('div', { 'class': 'cbi-value-description' }, hint) : '' ])
	]);
}

return view.extend({
	load: function() {
		return uci.load(CONF);
	},

	render: function() {
		var global = uci.get(CONF, 'global') || {};
		var balanceOn = global.balance_enabled === '1';
		var failoverOn = global.failover_enabled === '1';
		var main = global.main_target || 'direct';

		var mainSel = E('select', { 'class': 'cbi-input-select' });
		mainSel.appendChild(E('option', { 'value': 'direct' }, '直连'));
		mainSel.appendChild(E('option', { 'value': 'balance' }, '负载均衡' + (balanceOn ? '' : '（未启用）')));
		mainSel.appendChild(E('option', { 'value': 'failover' }, '主备' + (failoverOn ? '' : '（未启用）')));
		nodes().forEach(function(n) {
			mainSel.appendChild(E('option', { 'value': n['.name'] },
				'节点：' + (n.remarks || n.address || n['.name'])));
		});
		mainSel.value = main;

		var modeSel = E('select', { 'class': 'cbi-input-select' }, [
			E('option', { 'value': 'chnroute' }, '大陆白名单（国内直连）'),
			E('option', { 'value': 'gfw' }, 'GFW 列表（仅 GFW 走代理）'),
			E('option', { 'value': 'global' }, '全局代理'),
			E('option', { 'value': 'custom' }, '自定义（仅用规则）')
		]);
		modeSel.value = global.rule_mode || 'chnroute';

		var save = E('button', { 'class': 'cbi-button cbi-button-apply' }, '保存');
		save.addEventListener('click', function() {
			uci.set(CONF, 'global', 'main_target', mainSel.value);
			uci.set(CONF, 'global', 'rule_mode', modeSel.value);
			uci.save().then(function() { return uci.apply(); }).then(function() {
				ui.addNotification(null, E('p', {}, '分流设置已保存'), 'info');
			});
		});

		return E('div', {}, [
			E('h2', {}, '规则管理'),
			E('fieldset', { 'class': 'cbi-section' }, [
				E('legend', {}, '分流设置'),
				E('p', { 'class': 'cbi-value-description' },
					'匹配顺序：先按“规则列表”中的规则匹配（按序号从上到下），其次是下面的“分流模式”内置规则，最后走“分流总节点”。'),
				fieldRow('分流总节点', mainSel, '未命中任何规则时的默认出口，可选直连 / 某个节点 / 负载均衡 / 主备。'),
				fieldRow('分流模式', modeSel, '内置规则集，优先级低于“规则列表”中的规则。'),
				E('p', {}, save)
			]),
			E('p', { 'class': 'cbi-value-description' },
				'提示：具体的域名/IP 分流规则在“规则列表”页面维护，可拖拽排序（↑/↓）、支持 geo 标签搜索多选。')
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
