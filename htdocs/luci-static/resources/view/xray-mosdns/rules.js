'use strict';
'require view';
'require uci';
'require fs';
'require ui';

var CONF = 'xray-mosdns';

var TYPES = {
	domain: _('域名'),
	ip: _('IP / CIDR'),
	port: _('端口'),
	network: _('协议 (tcp/udp)')
};

var STATIC_POLICIES = {
	main: _('跟随总节点'),
	balance: _('负载均衡'),
	failover: _('主备'),
	direct: _('直连'),
	block: _('阻断')
};

function nodeList() {
	return uci.sections(CONF, 'node') || [];
}

function policyOptions() {
	var global = uci.get(CONF, 'global') || {};
	var opts = [ 'main', 'direct', 'block' ];
	var labels = {};
	opts.forEach(function(k) { labels[k] = STATIC_POLICIES[k]; });
	if (global.balance_enabled === '1') {
		opts.splice(1, 0, 'balance');
		labels.balance = STATIC_POLICIES.balance;
	}
	if (global.failover_enabled === '1') {
		opts.splice(opts.indexOf('balance') >= 0 ? 2 : 1, 0, 'failover');
		labels.failover = STATIC_POLICIES.failover;
	}
	nodeList().forEach(function(n) {
		var label = (n.remarks || n.address || n['.name']);
		opts.push(n['.name']);
		labels[n['.name']] = _('节点：') + label;
	});
	return { order: opts, labels: labels };
}

function policyLabel(v) {
	if (!v || v === 'main' || v === 'proxy') return STATIC_POLICIES.main;
	if (STATIC_POLICIES[v]) return STATIC_POLICIES[v];
	var found = null;
	nodeList().forEach(function(n) { if (n['.name'] === v) found = n; });
	if (found) return _('节点：') + (found.remarks || found.address || v);
	return v;
}

var geoData = { geosite: [], geoip: [] };
var ruleTbody = null;

function rules() {
	return uci.sections(CONF, 'rule') || [];
}

function ruleById(sid) {
	var found = null;
	rules().forEach(function(r) { if (r['.name'] === sid) found = r; });
	return found;
}

function opt(title, input, hint) {
	return E('div', { 'class': 'cbi-value' }, [
		E('label', { 'class': 'cbi-value-title' }, title),
		E('div', { 'class': 'cbi-value-field' }, [
			input,
			hint ? E('div', { 'class': 'cbi-value-description' }, hint) : ''
		])
	]);
}

function input(id, value, placeholder) {
	return E('input', { 'id': id, 'type': 'text', 'class': 'cbi-input-text', 'value': value || '', 'placeholder': placeholder || '' });
}

function check(id, value) {
	var el = E('input', { 'id': id, 'type': 'checkbox', 'class': 'cbi-input-checkbox' });
	if (value === '1') el.checked = true;
	return el;
}

function selectBox(id, values, value) {
	var el = E('select', { 'id': id, 'class': 'cbi-input-select' });
	Object.keys(values).forEach(function(k) {
		var o = E('option', { 'value': k }, values[k]);
		if (k === value) o.selected = true;
		el.appendChild(o);
	});
	return el;
}

function val(id) {
	var el = document.getElementById(id);
	if (!el) return '';
	if (el.type === 'checkbox') return el.checked ? '1' : '0';
	return (el.value || '').trim();
}

function splitValue(value) {
	var selected = [];
	var manual = [];
	(value || '').split(',').forEach(function(v) {
		v = v.trim();
		if (!v) return;
		if (v.indexOf('geosite:') === 0) selected.push(v.slice(8));
		else if (v.indexOf('geoip:') === 0) selected.push(v.slice(6));
		else manual.push(v);
	});
	return { selected: selected, manual: manual };
}

function joinValue(type, selected, manual) {
	var out = [];
	selected.forEach(function(t) {
		out.push((type === 'ip' ? 'geoip:' : 'geosite:') + t);
	});
	manual.forEach(function(m) { if (m.trim()) out.push(m.trim()); });
	return out.join(',');
}

function displayValue(r) {
	var v = (r.value || '').replace(/geosite:|geoip:/g, '');
	var list = v.split(',').filter(function(x) { return x.trim(); });
	if (!list.length) return '-';
	var shown = list.slice(0, 3).join(', ');
	if (list.length > 3) shown += ' … +' + (list.length - 3);
	return shown;
}

function moveRule(sid, dir) {
	var list = rules();
	var idx = -1;
	list.forEach(function(r, i) { if (r['.name'] === sid) idx = i; });
	var target = idx + dir;
	if (idx < 0 || target < 0 || target >= list.length) return;
	var other = list[target]['.name'];
	uci.move(CONF, sid, other, dir > 0);
	uci.save().then(function() { return uci.apply(); }).then(function() {
		refreshTable();
	});
}

function refreshTable() {
	var tbody = ruleTbody;
	if (!tbody) return;
	tbody.replaceChildren();
	var list = rules();
	if (!list.length) {
		tbody.appendChild(E('tr', { 'class': 'tr' }, [ E('td', { 'class': 'td', 'colspan': 7 }, _('还没有规则')) ]));
		return;
	}
	list.forEach(function(r) {
		var tr = E('tr', { 'class': 'tr', 'data-rule': r['.name'] });
		var enabled = E('input', { 'type': 'checkbox', 'class': 'cbi-input-checkbox' });
		if (r.enabled === '1') enabled.checked = true;
		enabled.addEventListener('change', function() {
			uci.set(CONF, r['.name'], 'enabled', enabled.checked ? '1' : '0');
			uci.save().then(function() { return uci.apply(); });
		});
		var order = rules().map(function(x) { return x['.name']; }).indexOf(r['.name']) + 1;
		tr.appendChild(E('td', { 'class': 'td' }, String(order)));
		tr.appendChild(E('td', { 'class': 'td' }, [ enabled ]));
		tr.appendChild(E('td', { 'class': 'td' }, [ E('strong', {}, r.remarks || '-') ]));
		tr.appendChild(E('td', { 'class': 'td' }, TYPES[r.rule_type] || r.rule_type || ''));
		tr.appendChild(E('td', { 'class': 'td' }, [ E('span', { 'title': r.value || '' }, displayValue(r)) ]));
		tr.appendChild(E('td', { 'class': 'td' }, policyLabel(r.outbound)));
		var ops = E('td', { 'class': 'td cbi-section-actions' });
		var up = E('button', { 'class': 'cbi-button cbi-button-neutral', 'title': _('上移') }, '↑');
		var down = E('button', { 'class': 'cbi-button cbi-button-neutral', 'title': _('下移') }, '↓');
		var edit = E('button', { 'class': 'cbi-button cbi-button-action' }, _('详情'));
		var del = E('button', { 'class': 'cbi-button cbi-button-remove' }, _('删除'));
		up.addEventListener('click', function() { moveRule(r['.name'], -1); });
		down.addEventListener('click', function() { moveRule(r['.name'], 1); });
		edit.addEventListener('click', function() { editModal(r['.name']); });
		del.addEventListener('click', function() {
			ui.showModal(_('删除规则'), [
				E('p', {}, _('确定删除规则 "%s"？').format(r.remarks || r['.name'])),
				E('div', { 'class': 'right' }, [
					E('button', { 'class': 'btn', 'click': function() { ui.hideModal(); } }, _('取消')),
					' ',
					E('button', {
						'class': 'cbi-button cbi-button-remove',
						'click': function() {
							uci.remove(CONF, r['.name']);
							uci.save().then(function() { return uci.apply(); }).then(function() {
								ui.hideModal();
								refreshTable();
							});
						}
					}, _('删除'))
				])
			]);
		});
		ops.appendChild(up);
		ops.appendChild(document.createTextNode(' '));
		ops.appendChild(down);
		ops.appendChild(document.createTextNode(' '));
		ops.appendChild(edit);
		ops.appendChild(document.createTextNode(' '));
		ops.appendChild(del);
		tr.appendChild(ops);
		tbody.appendChild(tr);
	});
}

function saveRule(sid, values) {
	if (sid === null) sid = uci.add(CONF, 'rule');
	Object.keys(values).forEach(function(k) {
		if (values[k] === null || values[k] === undefined) uci.unset(CONF, sid, k);
		else uci.set(CONF, sid, k, values[k]);
	});
	return uci.save().then(function() { return uci.apply(); });
}

function editModal(sid) {
	var r = sid ? (ruleById(sid) || {}) : {};
	var isNew = !sid;
	var type = r.rule_type || 'domain';

	var parsed = splitValue(r.value || '');
	var selected = parsed.selected.slice();
	var manual = parsed.manual.slice();

	var container = E('div', {}, []);

	var typeSel = selectBox('ru-type', TYPES, type);
	var polOpts = policyOptions();
	var polSel = selectBox('ru-policy', polOpts.labels, r.outbound || 'main');

	var chips = E('div', { 'style': 'margin:4px 0;min-height:24px;' });
	var search = E('input', { 'id': 'ru-search', 'type': 'text', 'class': 'cbi-input-text', 'placeholder': _('搜索 geo 标签…') });
	var listBox = E('div', { 'style': 'max-height:220px;overflow:auto;border:1px solid #ddd;padding:4px;border-radius:3px;' });
	var count = E('span', { 'class': 'cbi-value-description' });

	function tagsForType() {
		return type === 'ip' ? (geoData.geoip || []) : (geoData.geosite || []);
	}

	function renderChips() {
		chips.replaceChildren();
		if (!selected.length) {
			chips.appendChild(E('span', { 'class': 'cbi-value-description' }, _('未选择标签，可在下方列表勾选或手动输入')));
			return;
		}
		selected.forEach(function(t) {
			var chip = E('span', {
				'class': 'label label-primary',
				'style': 'display:inline-block;margin:2px 4px 2px 0;padding:2px 6px;cursor:pointer',
				'title': _('点击移除')
			}, t + ' ×');
			chip.addEventListener('click', function(ev) {
				ev.preventDefault();
				var idx = selected.indexOf(t);
				if (idx >= 0) selected.splice(idx, 1);
				renderChips();
				renderList();
			});
			chips.appendChild(chip);
		});
	}

	function renderList() {
		var q = (val('ru-search') || '').toLowerCase();
		var tags = tagsForType();
		var shown = tags.filter(function(t) { return !q || t.toLowerCase().indexOf(q) >= 0; });
		count.textContent = _('共 %d 个标签，显示 %d 个').format(tags.length, Math.min(shown.length, 300));
		listBox.replaceChildren();
		if (!tags.length) {
			listBox.appendChild(E('div', { 'class': 'cbi-value-description' }, _('未找到 geo 数据（geosite.dat/geoip.dat）')));
			return;
		}
		shown.slice(0, 300).forEach(function(t) {
			var cb = E('input', { 'type': 'checkbox', 'class': 'cbi-input-checkbox' });
			if (selected.indexOf(t) >= 0) cb.checked = true;
			cb.addEventListener('change', function() {
				if (cb.checked) {
					if (selected.indexOf(t) < 0) selected.push(t);
				}
				else {
					var i = selected.indexOf(t);
					if (i >= 0) selected.splice(i, 1);
				}
				renderChips();
			});
			listBox.appendChild(E('label', { 'style': 'display:block;padding:1px 2px;cursor:pointer' }, [ cb, ' ', t ]));
		});
	}

	search.addEventListener('input', renderList);
	typeSel.addEventListener('change', function() {
		type = typeSel.value;
		selected = [];
		renderChips();
		renderList();
	});

	renderChips();
	renderList();

	var manualArea = E('textarea', {
		'id': 'ru-manual',
		'style': 'width:100%;height:70px;font-family:monospace;font-size:12px;',
		'placeholder': type === 'ip' ? '10.0.0.0/8, 192.168.0.0/16' : 'domain:openai.com\nfull:example.org\nregexp:^ad\\.'
	}, [ manual.join('\n') ]);

	var fields = [
		opt(_('备注'), input('ru-remarks', r.remarks, 'block-ads')),
		opt(_('启用'), check('ru-enabled', r.enabled || '0')),
		opt(_('分流方式'), typeSel, _('域名用 geosite 标签，IP 用 geoip 标签。')),
		opt(_('策略'), polSel),
		opt(_('Geo 标签（可搜索多选）'), E('div', {}, [ chips, search, count, listBox ]),
			_('勾选后自动生成 geosite:/geoip: 前缀。')),
		opt(_('手动匹配值'), manualArea, _('每行一个：domain:、full:、regexp: 或 CIDR。也可直接输入 geosite:xxx。'))
	];

	container.appendChild(E('div', {}, fields));

	var save = E('button', { 'class': 'cbi-button cbi-button-apply' }, _('保存'));
	save.addEventListener('click', function() {
		var t = val('ru-type');
		var manualLines = (document.getElementById('ru-manual').value || '').split('\n').map(function(s) { return s.trim(); }).filter(Boolean);
		var value = joinValue(t, selected, manualLines);
		if (!value) {
			ui.addNotification(null, E('p', {}, _('匹配值不能为空')), 'error');
			return;
		}
		saveRule(isNew ? null : sid, {
			enabled: val('ru-enabled'),
			remarks: val('ru-remarks'),
			rule_type: t,
			outbound: val('ru-policy'),
			value: value
		}).then(function() {
			ui.hideModal();
			refreshTable();
			ui.addNotification(null, E('p', {}, _('规则已保存')), 'info');
		}).catch(function(err) {
			ui.addNotification(null, E('p', {}, String(err.message || err)), 'error');
		});
	});

	ui.showModal(isNew ? _('添加分流规则') : _('规则详情'), [
		container,
		E('div', { 'class': 'right' }, [
			E('button', { 'class': 'btn', 'click': function() { ui.hideModal(); } }, _('取消')),
			' ',
			save
		])
	]);
}

function mainPanel() {
	var global = uci.get(CONF, 'global') || {};
	var balanceOn = global.balance_enabled === '1';
	var failoverOn = global.failover_enabled === '1';
	var main = global.main_target || 'direct';

	var mainSel = E('select', { 'class': 'cbi-input-select' });
	mainSel.appendChild(E('option', { 'value': 'direct' }, _('直连')));
	mainSel.appendChild(E('option', { 'value': 'balance' }, _('负载均衡') + (balanceOn ? '' : _('（未启用）'))));
	mainSel.appendChild(E('option', { 'value': 'failover' }, _('主备') + (failoverOn ? '' : _('（未启用）'))));
	nodeList().forEach(function(n) {
		mainSel.appendChild(E('option', { 'value': n['.name'] },
			_('节点：') + (n.remarks || n.address || n['.name'])));
	});
	mainSel.value = main;

	var modeSel = E('select', { 'class': 'cbi-input-select' }, [
		E('option', { 'value': 'chnroute' }, _('大陆白名单（国内直连）')),
		E('option', { 'value': 'gfw' }, _('GFW 列表（仅 GFW 走代理）')),
		E('option', { 'value': 'global' }, _('全局代理')),
		E('option', { 'value': 'custom' }, _('自定义（仅用规则）'))
	]);
	modeSel.value = global.rule_mode || 'chnroute';

	var save = E('button', { 'class': 'cbi-button cbi-button-apply' }, _('保存'));
	save.addEventListener('click', function() {
		uci.set(CONF, 'global', 'main_target', mainSel.value);
		uci.set(CONF, 'global', 'rule_mode', modeSel.value);
		uci.save().then(function() { return uci.apply(); }).then(function() {
			ui.addNotification(null, E('p', {}, _('分流设置已保存')), 'info');
		});
	});

	function field(title, node, hint) {
		return E('div', { 'class': 'cbi-value' }, [
			E('label', { 'class': 'cbi-value-title' }, title),
			E('div', { 'class': 'cbi-value-field' }, [ node, hint ? E('div', { 'class': 'cbi-value-description' }, hint) : '' ])
		]);
	}

	return E('fieldset', { 'class': 'cbi-section' }, [
		E('legend', {}, _('分流设置')),
		E('p', { 'class': 'cbi-value-description' },
			_('匹配顺序：先按上面的规则列表匹配（按序号从上到下），其次是“分流模式”内置规则，最后走“分流总节点”。')),
		field(_('分流总节点'), mainSel, _('未命中任何规则时的默认出口，可选直连 / 某个节点 / 负载均衡 / 主备。')),
		field(_('分流模式'), modeSel, _('内置规则集，优先级低于上方规则列表。')),
		E('p', {}, save)
	]);
}

return view.extend({
	load: function() {
		return Promise.all([
			uci.load(CONF),
			fs.exec('/usr/libexec/xray-mosdns/geo-tags.sh', []).then(function(res) {
				try {
					geoData = JSON.parse((res && res.stdout) || '{}');
				} catch (e) {
					geoData = { geosite: [], geoip: [] };
				}
				return geoData;
			}).catch(function() { return null; })
		]);
	},

	render: function() {
		var addBtn = E('button', { 'class': 'cbi-button cbi-button-add' }, _('添加规则'));
		addBtn.addEventListener('click', function() { editModal(null); });

		var toolbar = E('div', { 'class': 'cbi-section-node' }, [ addBtn ]);
		var table = E('table', { 'class': 'table cbi-section-table' }, [
			E('thead', {}, [ E('tr', { 'class': 'tr table-titles' }, [
				E('th', { 'class': 'th', 'style': 'width:48px' }, _('序号')),
				E('th', { 'class': 'th' }, _('启用')),
				E('th', { 'class': 'th' }, _('备注')),
				E('th', { 'class': 'th' }, _('分流方式')),
				E('th', { 'class': 'th' }, _('匹配值')),
				E('th', { 'class': 'th' }, _('策略')),
				E('th', { 'class': 'th' }, _('操作'))
			]) ]),
			(ruleTbody = E('tbody'))
		]);

		refreshTable();

		return E('div', {}, [
			E('p', {}, _('规则按序号从上到下匹配，命中后使用对应策略；未命中时按“分流模式”内置规则，最后走“分流总节点”。可用 ↑/↓ 调整顺序。')),
			E('p', { 'class': 'cbi-value-description' },
				_('Geo 标签来源于 /usr/share/v2ray/geosite.dat 与 geoip.dat，支持搜索、多选；也可手动输入 domain:/full:/regexp:/CIDR。')),
			toolbar,
			table,
			mainPanel()
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
