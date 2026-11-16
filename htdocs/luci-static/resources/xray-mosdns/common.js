'use strict';
'require baseclass';
'require fs';
'require uci';

var CONF = 'xray-mosdns';
var LIBEXEC = '/usr/libexec/xray-mosdns/';

var TYPES = {
	vless: 'VLESS',
	vmess: 'VMess',
	trojan: 'Trojan',
	shadowsocks: 'Shadowsocks',
	hysteria2: 'Hysteria2'
};

var STRATEGIES = {
	fastest: _('最快'),
	ordered: _('按顺序'),
	roundrobin: _('轮询'),
	random: _('随机')
};

var DEFAULTS = {
	proxy: _('走代理（总节点）'),
	direct: _('直连')
};

return baseclass.extend({
	CONF: CONF,
	TYPES: TYPES,
	DEFAULTS: DEFAULTS,
	STRATEGIES: STRATEGIES,

	/* run a helper script and parse its JSON output; never rejects */
	exec: function(script, args) {
		return fs.exec(LIBEXEC + script, args || []).then(function(res) {
			try { return JSON.parse((res && res.stdout) || '{}'); }
			catch (e) { return { ok: false, error: 'bad_output' }; }
		}).catch(function(err) {
			return { ok: false, error: String((err && err.message) || err) };
		});
	},

	nodes: function() {
		return uci.sections(CONF, 'node') || [];
	},

	groups: function() {
		return uci.sections(CONF, 'group') || [];
	},

	groupLabel: function(grp) {
		return _('组：%s').format(grp.remarks || grp['.name']);
	},

	nodeLabel: function(n) {
		var name = n.remarks || n.address || n['.name'];
		return n.address && n.remarks ? '%s (%s)'.format(name, n.address) : name;
	},

	/* fill a ListValue with the things traffic can be sent to */
	addNodeChoices: function(o, opts) {
		opts = opts || {};
		var self = this;
		if (opts.main) o.value('main', _('跟随总节点'));
		if (opts.direct != null) o.value(opts.direct, _('直连'));
		if (opts.block) o.value('block', _('阻断'));
		if (opts.groups) {
			this.groups().forEach(function(grp) {
				o.value(grp['.name'], self.groupLabel(grp));
			});
		}
		this.nodes().forEach(function(n) {
			o.value(n['.name'], self.nodeLabel(n) + (n.enabled === '1' ? '' : _('（未启用）')));
		});
	},

	targetLabel: function(target) {
		var self = this, label = null;
		switch (target) {
		case 'direct':   return _('直连');
		case 'block':    return _('阻断');
		case 'main':     return _('跟随总节点');
		}
		this.nodes().forEach(function(n) {
			if (n['.name'] === target) label = self.nodeLabel(n);
		});
		this.groups().forEach(function(grp) {
			if (grp['.name'] === target) label = self.groupLabel(grp);
		});
		return label || target || '-';
	},

	fmtBytes: function(n) {
		n = Number(n) || 0;
		if (n < 1024) return n + ' B';
		if (n < 1048576) return (n / 1024).toFixed(1) + ' KiB';
		if (n < 1073741824) return (n / 1048576).toFixed(1) + ' MiB';
		return (n / 1073741824).toFixed(2) + ' GiB';
	},

	/* the stock LuCI badge; state: ok | warn | bad | null */
	badge: function(text, state) {
		var cls = { ok: 'label label-success', warn: 'label label-warning', bad: 'label label-danger' };
		return E('span', { 'class': cls[state] || 'label' }, text);
	},

	/* a two-column key/value table built from [ [title, node], ... ] */
	infoTable: function(rows) {
		return E('table', { 'class': 'table' }, rows.map(function(r) {
			return E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td left', 'width': '33%' }, r[0]),
				E('td', { 'class': 'td left' }, r[1])
			]);
		}));
	},

	section: function(title, children, descr) {
		return E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, title),
			descr ? E('div', { 'class': 'cbi-section-descr' }, descr) : ''
		].concat(children));
	}
});
