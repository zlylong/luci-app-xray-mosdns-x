'use strict';
'require view';
'require uci';
'require ui';
'require xray-mosdns.ui as xm';

var CONF = 'xray-mosdns';

function nodes() {
	return uci.sections(CONF, 'node') || [];
}

function nodeSelect(current, allowEmpty) {
	var sel = E('select', { 'class': 'cbi-input-select' });
	if (allowEmpty)
		sel.appendChild(E('option', { 'value': '' }, '直连'));
	nodes().forEach(function(n) {
		var addr = n.address ? n.address + ':' + (n.port || 443) : '';
		var label = n.remarks ? n.remarks + (addr ? ' (' + addr + ')' : '') : (addr || n['.name']);
		var o = E('option', { 'value': n['.name'] }, label);
		if (n['.name'] === current) o.selected = true;
		sel.appendChild(o);
	});
	return sel;
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

		// ---------------------------------------------------------------- load balancing
		var lbEnabled = E('input', { 'type': 'checkbox', 'class': 'cbi-input-checkbox' });
		if (global.balance_enabled === '1') lbEnabled.checked = true;

		var lbStrategy = E('select', { 'class': 'cbi-input-select' }, [
			E('option', { 'value': 'leastLoad' }, 'leastLoad（自动选最快节点）'),
			E('option', { 'value': 'roundRobin' }, 'roundRobin（轮询）'),
			E('option', { 'value': 'random' }, 'random（随机）')
		]);
		lbStrategy.value = global.balancer_strategy || 'leastLoad';

		var lbFallback = nodeSelect(global.fallback_node || '', true);

		var lbSave = E('button', { 'class': 'cbi-button cbi-button-apply' }, '保存');
		lbSave.addEventListener('click', function() {
			uci.set(CONF, 'global', 'balance_enabled', lbEnabled.checked ? '1' : '0');
			uci.set(CONF, 'global', 'balancer_strategy', lbStrategy.value);
			uci.set(CONF, 'global', 'fallback_node', lbFallback.value);
			if (!lbEnabled.checked && uci.get(CONF, 'global', 'main_target') === 'balance')
				uci.set(CONF, 'global', 'main_target', 'direct');
			uci.save().then(function() { return uci.apply(); }).then(function() {
				ui.addNotification(null, E('p', {}, '负载均衡设置已保存'), 'info');
			});
		});

		// ---------------------------------------------------------------- active / standby
		var foEnabled = E('input', { 'type': 'checkbox', 'class': 'cbi-input-checkbox' });
		if (global.failover_enabled === '1') foEnabled.checked = true;

		var foPrimary = nodeSelect(global.failover_primary || '', false);
		var foStandby = nodeSelect(global.failover_standby || '', true);

		var foSave = E('button', { 'class': 'cbi-button cbi-button-apply' }, '保存');
		foSave.addEventListener('click', function() {
			uci.set(CONF, 'global', 'failover_enabled', foEnabled.checked ? '1' : '0');
			uci.set(CONF, 'global', 'failover_primary', foPrimary.value);
			uci.set(CONF, 'global', 'failover_standby', foStandby.value);
			if (!foEnabled.checked && uci.get(CONF, 'global', 'main_target') === 'failover')
				uci.set(CONF, 'global', 'main_target', 'direct');
			uci.save().then(function() { return uci.apply(); }).then(function() {
				ui.addNotification(null, E('p', {}, '主备设置已保存'), 'info');
			});
		});

		return xm.page({
			title: '负载均衡',
			lede: '两种选路模型，可分别启用，也可以同时存在。切换“分流总节点”后，规则里的“跟随总节点”会跟着变。',
			lamps: [
				xm.lamp(global.balance_enabled === '1' ? 'on' : 'off', '负载均衡',
					global.balance_enabled === '1' ? '已启用' : '未启用'),
				xm.lamp(global.failover_enabled === '1' ? 'on' : 'off', '主备',
					global.failover_enabled === '1' ? '已启用' : '未启用')
			]
		}, [
			xm.section('负载均衡', [ E('div', { 'class': 'cbi-section' }, [
				E('p', { 'class': 'cbi-value-description' },
					'启用后“分流总节点”和规则策略都可以选择“负载均衡”。成员是所有已启用的节点；'
					+ 'leastLoad 每分钟探活并选择延迟最低的可用节点（自动选路/故障切换，不是按连接数分摊）。'),
				fieldRow('启用负载均衡', lbEnabled),
				fieldRow('均衡策略', lbStrategy),
				fieldRow('备用节点', lbFallback, '均衡器探测不到任何可用节点时使用。'),
				E('p', {}, lbSave)
			]) ]),
			xm.section('主备', [ E('div', { 'class': 'cbi-section' }, [
				E('p', { 'class': 'cbi-value-description' },
					'主节点健康检查（每分钟）正常时使用主节点；探测失败时自动切换到备节点（未设备节点则回落到直连）。'),
				fieldRow('启用主备', foEnabled),
				fieldRow('主节点', foPrimary),
				fieldRow('备节点', foStandby),
				E('p', {}, foSave)
			]) ])
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
