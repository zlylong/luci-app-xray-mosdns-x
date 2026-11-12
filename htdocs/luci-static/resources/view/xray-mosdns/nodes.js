'use strict';
'require view';
'require uci';
'require fs';
'require ui';

var CONF = 'xray-mosdns';

var TYPES = {
	vless: 'VLESS',
	vmess: 'VMess',
	trojan: 'Trojan',
	shadowsocks: 'Shadowsocks',
	hysteria2: 'Hysteria2'
};

var TRANSPORTS = [ 'tcp', 'ws', 'grpc', 'http', 'xhttp' ];
var METHODS = [ 'aes-128-gcm', 'aes-256-gcm', 'chacha20-poly1305', 'xchacha20-poly1305' ];
var FINGERPRINTS = [ 'chrome', 'firefox', 'safari', 'edge', 'random' ];

function nodes() {
	return uci.sections(CONF, 'node') || [];
}

function nodeById(sid) {
	var found = null;
	nodes().forEach(function(n) { if (n['.name'] === sid) found = n; });
	return found;
}

function opt(id, title, input, hint) {
	return E('div', { 'class': 'cbi-value', 'data-opt': id }, [
		E('label', { 'class': 'cbi-value-title' }, title),
		E('div', { 'class': 'cbi-value-field' }, [
			input,
			hint ? E('div', { 'class': 'cbi-value-description' }, hint) : ''
		])
	]);
}

function input(id, value, placeholder) {
	return E('input', {
		'id': id, 'type': 'text', 'class': 'cbi-input-text',
		'value': value || '', 'placeholder': placeholder || ''
	});
}

function check(id, value) {
	var el = E('input', { 'id': id, 'type': 'checkbox', 'class': 'cbi-input-checkbox' });
	if (value === '1') el.checked = true;
	return el;
}

function select(id, values, value) {
	var el = E('select', { 'id': id, 'class': 'cbi-input-select' });
	values.forEach(function(v) {
		var o = E('option', { 'value': v }, TYPES[v] || v);
		if (v === value) o.selected = true;
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

function rowData(sid) {
	var el = document.querySelector('tr[data-node="' + sid + '"]');
	return el;
}

function fmtMs(res) {
	if (!res || !res.ok) return null;
	return res.ms;
}

function msClass(ms) {
	if (ms == null) return 'label';
	if (ms < 150) return 'label label-success';
	if (ms < 400) return 'label label-warning';
	return 'label label-danger';
}

function typeBadge(type) {
	return E('span', { 'class': 'label label-default' }, TYPES[type] || type || '?');
}

function showError(msg) {
	ui.addNotification(null, E('p', {}, msg), 'error');
}

function saveNode(sid, values) {
	var created = (sid === null);
	if (created) {
		sid = uci.add(CONF, 'node');
	}
	Object.keys(values).forEach(function(k) {
		if (values[k] === null || values[k] === undefined)
			uci.unset(CONF, sid, k);
		else
			uci.set(CONF, sid, k, values[k]);
	});
	return uci.save().then(function() { return uci.apply(); });
}

function deleteNode(sid) {
	uci.remove(CONF, sid);
	return uci.save().then(function() { return uci.apply(); });
}

function editModal(sid) {
	var n = sid ? (nodeById(sid) || {}) : { '.name': null };
	var isNew = !sid;
	var type = n.type || 'vless';

	var container = E('div', {}, []);

	function collectCurrent() {
		return {
			remarks: val('nm-remarks'), enabled: val('nm-enabled'), type: val('nm-type') || type,
			address: val('nm-address'), port: val('nm-port'), uuid: val('nm-uuid'),
			alter_id: val('nm-alter_id'), password: val('nm-password'), method: val('nm-method'),
			flow: val('nm-flow'), tls: val('nm-tls'), tls_server_name: val('nm-sni'),
			fingerprint: val('nm-fingerprint'), transport: val('nm-transport'),
			path: val('nm-path'), host: val('nm-host'), service_name: val('nm-service_name')
		};
	}

	function refreshFields(preferred) {
		var t = (preferred && preferred.type) || type;
		var fields = [];
		var sel = select('nm-type', Object.keys(TYPES), t);
		sel.addEventListener('change', function() {
			var cur = collectCurrent();
			cur.type = sel.value;
			refreshFields(cur);
		});

		fields.push(opt('nm-remarks', _('Remarks'), input('nm-remarks', preferred && preferred.remarks, 'my-vps')));
		fields.push(opt('nm-enabled', _('Enabled'), check('nm-enabled', (preferred && preferred.enabled) || '0'),
			_('Only enabled nodes are used in balance mode.')));
		fields.push(opt('nm-type', _('Type'), sel));
		fields.push(opt('nm-address', _('Address'), input('nm-address', preferred && preferred.address, 'example.com or IP')));
		fields.push(opt('nm-port', _('Port'), input('nm-port', (preferred && preferred.port) || '443')));

		if (t === 'vless' || t === 'vmess')
			fields.push(opt('nm-uuid', _('UUID'), input('nm-uuid', preferred && preferred.uuid)));
		if (t === 'vmess')
			fields.push(opt('nm-alter_id', _('Alter ID'), input('nm-alter_id', (preferred && preferred.alter_id) || '0')));
		if (t === 'trojan' || t === 'shadowsocks' || t === 'hysteria2')
			fields.push(opt('nm-password', _('Password'), input('nm-password', preferred && preferred.password)));
		if (t === 'shadowsocks')
			fields.push(opt('nm-method', _('Method'), select('nm-method', METHODS, (preferred && preferred.method) || 'aes-128-gcm')));
		if (t === 'vless')
			fields.push(opt('nm-flow', _('Flow'), input('nm-flow', preferred && preferred.flow, 'xtls-rprx-vision')));

		if (t !== 'hysteria2') {
			fields.push(opt('nm-tls', _('TLS'), check('nm-tls', (preferred && preferred.tls) || (t === 'trojan' ? '1' : '0'))));
			fields.push(opt('nm-sni', _('TLS SNI'), input('nm-sni', preferred && preferred.tls_server_name),
				_('Defaults to the address. Xray 26.x has removed allowInsecure.')));
			fields.push(opt('nm-fingerprint', _('uTLS fingerprint'), select('nm-fingerprint', FINGERPRINTS, (preferred && preferred.fingerprint) || 'chrome')));
			fields.push(opt('nm-transport', _('Transport'), select('nm-transport', TRANSPORTS, (preferred && preferred.transport) || 'tcp')));
			fields.push(opt('nm-path', _('Path'), input('nm-path', (preferred && preferred.path) || '/')));
			fields.push(opt('nm-host', _('Host header'), input('nm-host', preferred && preferred.host)));
			fields.push(opt('nm-service_name', _('gRPC service name'), input('nm-service_name', preferred && preferred.service_name)));
		}
		else {
			fields.push(opt('nm-sni', _('TLS SNI / server name'), input('nm-sni', preferred && preferred.tls_server_name),
				_('Hysteria2 always uses TLS with ALPN h3.')));
		}

		container.replaceChildren(E('div', {}, fields));
	}

	function collect() {
		var v = collectCurrent();
		if (v.type === 'hysteria2') {
			return {
				enabled: v.enabled, remarks: v.remarks, type: 'hysteria2',
				address: v.address, port: v.port || '443', password: v.password,
				tls: '1', tls_server_name: v.tls_server_name || '',
				fingerprint: '', transport: '', path: '', host: '', service_name: '',
				allow_insecure: '0'
			};
		}
		if (v.type === 'shadowsocks') {
			return {
				enabled: v.enabled, remarks: v.remarks, type: 'shadowsocks',
				address: v.address, port: v.port || '443', password: v.password, method: v.method,
				tls: '0', tls_server_name: '', fingerprint: '', transport: '', path: '',
				host: '', service_name: '', uuid: '', alter_id: '', flow: ''
			};
		}
		return {
			enabled: v.enabled, remarks: v.remarks, type: v.type,
			address: v.address, port: v.port || '443', uuid: v.uuid,
			alter_id: v.alter_id || '0', flow: v.flow || '', password: '',
			method: '', tls: v.tls, tls_server_name: v.tls_server_name,
			fingerprint: v.fingerprint, transport: v.transport, path: v.path,
			host: v.host, service_name: v.service_name, allow_insecure: '0'
		};
	}

	var saveBtn = E('button', { 'class': 'cbi-button cbi-button-apply' }, _('Save'));
	saveBtn.addEventListener('click', function() {
		var v = collect();
		if (!v.address) { showError(_('Address is required.')); return; }
		saveNode(isNew ? null : sid, v).then(function() {
			ui.hideModal();
			refreshTable();
			ui.addNotification(null, E('p', {}, _('Node saved.')), 'info');
		}).catch(function(err) { showError(err.message || String(err)); });
	});

	refreshFields(n);

	ui.showModal(isNew ? _('Add node') : _('Node detail'), [
		container,
		E('div', { 'class': 'right' }, [
			E('button', { 'class': 'btn', 'click': function() { ui.hideModal(); } }, _('Cancel')),
			' ',
			saveBtn
		])
	]);
}

function importModal() {
	var area = E('textarea', {
		'id': 'nm-import', 'style': 'width:100%;height:260px;font-family:monospace;font-size:12px;',
		'placeholder': 'vless://...\nvmess://...\ntrojan://...\nss://...\nhysteria2://...'
	});
	var status = E('p', { 'class': 'cbi-value-description' }, _('Supported: vless / vmess / trojan / shadowsocks / hysteria2. Imported nodes are disabled.'));

	var btn = E('button', { 'class': 'cbi-button cbi-button-apply' }, _('Import'));
	btn.addEventListener('click', function() {
		var text = area.value || '';
		if (!text.trim()) { showError(_('Nothing to import')); return; }
		fs.write('/tmp/xray-mosdns-import.txt', text).then(function() {
			return fs.exec('/usr/libexec/xray-mosdns/import-links.sh', [ '/tmp/xray-mosdns-import.txt' ]);
		}).then(function(res) {
			var out = {};
			try { out = JSON.parse((res && res.stdout) || '{}'); } catch (e) { out = {}; }
			if (!out.ok) { showError((out.error || 'import failed')); return; }
			ui.hideModal();
			return uci.load(CONF).then(function() {
				refreshTable();
				ui.addNotification(null, E('p', {}, _('Imported %d node(s), skipped %d line(s).').format(out.imported || 0, out.skipped || 0)), 'info');
			});
		}).catch(function(err) { showError(err.message || String(err)); });
	});

	ui.showModal(_('Import share links'), [
		E('p', {}, _('Paste proxy share links, one per line.')),
		area,
		status,
		E('div', { 'class': 'right' }, [
			E('button', { 'class': 'btn', 'click': function() { ui.hideModal(); } }, _('Cancel')),
			' ',
			btn
		])
	]);
}

var tbody, tableWrap;

function renderLatency(sid, cell) {
	cell.replaceChildren(E('span', { 'class': 'label' }, '…'));
	fs.exec('/usr/libexec/xray-mosdns/latency.sh', [ sid ]).then(function(res) {
		var out = {};
		try { out = JSON.parse((res && res.stdout) || '{}'); } catch (e) { out = {}; }
		if (!out.ok) {
			cell.replaceChildren(E('span', { 'class': 'label label-danger', 'title': out.error || '' }, _('失败')));
			return;
		}
		cell.replaceChildren(E('span', { 'class': msClass(out.ms) }, out.ms + ' ms'));
	}).catch(function() {
		cell.replaceChildren(E('span', { 'class': 'label label-danger' }, _('失败')));
	});
}

function addActions(row, n) {
	var sid = n['.name'];
	var actions = E('td', { 'class': 'td cbi-section-actions' }, []);
	var testBtn = E('button', { 'class': 'cbi-button cbi-button-neutral' }, _('测速'));
	var editBtn = E('button', { 'class': 'cbi-button cbi-button-action' }, _('详情'));
	var delBtn = E('button', { 'class': 'cbi-button cbi-button-remove' }, _('删除'));
	var latCell = E('td', { 'class': 'td' }, [ E('span', { 'class': 'label' }, '—') ]);
	testBtn.addEventListener('click', function() { renderLatency(sid, latCell); });
	actions.appendChild(testBtn);
	actions.appendChild(document.createTextNode(' '));
	actions.appendChild(editBtn);
	actions.appendChild(document.createTextNode(' '));
	actions.appendChild(delBtn);
	editBtn.addEventListener('click', function() { editModal(sid); });
	delBtn.addEventListener('click', function() {
		ui.showModal(_('Delete node'), [
			E('p', {}, _('Delete node "%s"?').format(n.remarks || n.address || sid)),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': function() { ui.hideModal(); } }, _('Cancel')),
				' ',
				E('button', {
					'class': 'cbi-button cbi-button-remove',
					'click': function() {
						deleteNode(sid).then(function() {
							ui.hideModal();
							refreshTable();
						});
					}
				}, _('Delete'))
			])
		]);
	});
	row.appendChild(latCell);
	row.appendChild(actions);
	return latCell;
}

function refreshTable() {
	if (!tbody) return;
	tbody.replaceChildren();
	var list = nodes();
	if (!list.length) {
		tbody.appendChild(E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td', 'colspan': 6 }, _('No nodes yet. Click "Add node" or "Import".'))
		]));
		return;
	}
	list.forEach(function(n) {
		var row = E('tr', { 'class': 'tr', 'data-node': n['.name'] }, []);
		var enabled = E('input', { 'type': 'checkbox', 'class': 'cbi-input-checkbox' });
		if (n.enabled === '1') enabled.checked = true;
		enabled.addEventListener('change', function() {
			uci.set(CONF, n['.name'], 'enabled', enabled.checked ? '1' : '0');
			uci.save().then(function() { return uci.apply(); });
		});
		row.appendChild(E('td', { 'class': 'td' }, [ enabled ]));
		row.appendChild(E('td', { 'class': 'td' }, [ E('strong', {}, n.remarks || '-') ]));
		row.appendChild(E('td', { 'class': 'td' }, [
			E('span', {}, (n.address || '?') + (n.port ? ':' + n.port : '')),
			' ', typeBadge(n.type)
		]));
		addActions(row, n);
		tbody.appendChild(row);
	});
}

return view.extend({
	load: function() {
		return uci.load(CONF);
	},

	render: function() {
		tableWrap = E('div', { 'class': 'cbi-section' }, []);
		tbody = E('tbody');

		var addBtn = E('button', { 'class': 'cbi-button cbi-button-add' }, _('添加节点'));
		var impBtn = E('button', { 'class': 'cbi-button cbi-button-action' }, _('导入节点'));
		var testAllBtn = E('button', { 'class': 'cbi-button cbi-button-neutral' }, _('全部测速'));

		addBtn.addEventListener('click', function() { editModal(null); });
		impBtn.addEventListener('click', importModal);
		testAllBtn.addEventListener('click', function() {
			nodes().forEach(function(n) {
				var cell = document.querySelector('tr[data-node="' + n['.name'] + '"] td:nth-last-child(2)');
				if (cell) renderLatency(n['.name'], cell);
			});
		});

		var toolbar = E('div', { 'class': 'cbi-section-node' }, [ addBtn, ' ', impBtn, ' ', testAllBtn ]);
		tableWrap.appendChild(toolbar);
		tableWrap.appendChild(E('table', { 'class': 'table cbi-section-table' }, [
			E('thead', {}, [ E('tr', { 'class': 'tr table-titles' }, [
				E('th', { 'class': 'th' }, _('启用')),
				E('th', { 'class': 'th' }, _('备注')),
				E('th', { 'class': 'th' }, _('地址')),
				E('th', { 'class': 'th' }, _('延迟')),
				E('th', { 'class': 'th' }, _('操作'))
			]) ]),
			tbody
		]));

		refreshTable();
		return tableWrap;
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
