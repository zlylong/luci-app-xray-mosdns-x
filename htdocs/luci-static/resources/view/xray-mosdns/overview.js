'use strict';
'require view';
'require fs';
'require poll';
'require ui';

function yesno(v) {
	return v ? E('span', { 'style': 'color:#2e7d32;font-weight:bold' }, '● running')
		: E('span', { 'style': 'color:#c62828;font-weight:bold' }, '○ stopped');
}

return view.extend({
	handleSave: null,
	handleSaveApply: null,
	handleReset: null,

	load: function() {
		return fs.exec('/usr/libexec/xray-mosdns/status.sh');
	},

	render: function(res) {
		var st = {};
		try { st = JSON.parse((res && res.stdout) || '{}'); } catch (e) { st = {}; }

		var table = E('table', { 'class': 'table' }, [
			E('tr', { 'class': 'tr table-titles' }, [
				E('th', { 'class': 'th' }, _('Item')),
				E('th', { 'class': 'th' }, _('Value'))
			])
		]);

		function row(title, value) {
			table.appendChild(E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td' }, title),
				E('td', { 'class': 'td' }, value)
			]));
		}

		row(_('Plugin'), st.enabled == 1 ? E('span', { 'style': 'color:#2e7d32;font-weight:bold' }, '● enabled') : E('span', { 'style': 'color:#c62828;font-weight:bold' }, '○ disabled'));
		row(_('Xray process'), yesno(st.xray_running));
		row(_('mosdns process'), yesno(st.mosdns_running));
		row(_('Node'), (st.node_remarks || st.node_address) ? (st.node_remarks || '') + ' (' + (st.node_type || '') + ' ' + (st.node_address || '') + ')' : E('em', {}, _('not configured')));
		row(_('TProxy port'), String(st.tproxy_port || ''));
		row(_('nftables rules'), yesno(st.fw && st.fw.nft));
		row(_('Policy routing'), yesno(st.fw && st.fw.rule));

		var node = E('div', {}, [
			E('h2', {}, _('Xray + mosdns-x')),
			E('div', { 'class': 'cbi-section' }, [table]),
			E('div', { 'class': 'cbi-section' }, [
				E('p', {}, _('This plugin is not enabled until "Enable" is set on the Settings page and the service is started.')),
				E('p', {}, [
					E('a', { 'href': L.url('admin/services/xray-mosdns/settings') }, _('Settings')), ' | ',
					E('a', { 'href': L.url('admin/services/xray-mosdns/nodes') }, _('Nodes')), ' | ',
					E('a', { 'href': L.url('admin/services/xray-mosdns/dns') }, _('DNS')), ' | ',
					E('a', { 'href': L.url('admin/services/xray-mosdns/log') }, _('Log'))
				])
			])
		]);

		return node;
	}
});
