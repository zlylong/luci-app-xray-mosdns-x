'use strict';
'require view';
'require form';
'require uci';
'require ui';
'require poll';
'require xray-mosdns.common as xm';

var GROUPS = {
	'General': [ _('常规'), _('在大多数设备上阻止跟踪和广告的列表') ],
	'Other': [ _('其它'), _('其他黑名单') ],
	'Regional': [ _('区域'), _('针对特定地区或语言的列表') ],
	'Security': [ _('安全'), _('拦截恶意软件、钓鱼和诈骗域名的列表') ]
};

function fmtTime(ts) {
	if (!ts) return '-';
	var d = new Date(ts * 1000);
	return '%04d-%02d-%02d %02d:%02d'.format(d.getFullYear(), d.getMonth() + 1, d.getDate(), d.getHours(), d.getMinutes());
}

function fmtCount(n) {
	return String(n || 0).replace(/\B(?=(\d{3})+(?!\d))/g, ',');
}

function subscribedUrls() {
	var urls = {};
	(uci.sections(xm.CONF, 'adlist') || []).forEach(function(s) { urls[s.url] = true; });
	return urls;
}

/* pick lists from AdGuard's catalogue; the picks are staged like any other edit */
function catalogDialog(catalog) {
	var have = subscribedUrls();
	var boxes = [];
	var body = [];

	(catalog.groups || []).forEach(function(grp) {
		var filters = (catalog.filters || []).filter(function(f) { return f.group === grp.id; });
		filters.sort(function(a, b) { return a.name.toLowerCase() < b.name.toLowerCase() ? -1 : 1; });
		if (!filters.length)
			return;
		var label = GROUPS[grp.name] || [ grp.name, '' ];
		body.push(E('h5', { 'style': 'margin:1em 0 0' }, label[0]));
		if (label[1])
			body.push(E('div', { 'class': 'cbi-value-description', 'style': 'margin:0 0 .5em' }, label[1]));
		filters.forEach(function(f) {
			var cb = E('input', { 'type': 'checkbox', 'id': 'xm-adl-' + f.id });
			if (have[f.url]) {
				cb.checked = true;
				cb.disabled = true;
			}
			else {
				boxes.push([ cb, f ]);
			}
			body.push(E('div', { 'style': 'margin:.15em 0' }, [
				cb, ' ',
				E('label', { 'for': 'xm-adl-' + f.id, 'title': f.description || '' }, f.name),
				have[f.url] ? E('em', {}, ' ' + _('（已订阅）')) : '',
				f.homepage ? E('a', {
					'href': f.homepage, 'target': '_blank', 'rel': 'noreferrer noopener',
					'style': 'margin-left:.5em', 'title': _('主页')
				}, '↗') : ''
			]));
		});
	});

	function add() {
		var picked = boxes.filter(function(b) { return b[0].checked; });
		if (!picked.length) {
			ui.hideModal();
			return;
		}
		picked.forEach(function(b) {
			var sid = uci.add(xm.CONF, 'adlist');
			uci.set(xm.CONF, sid, 'enabled', '1');
			uci.set(xm.CONF, sid, 'name', b[1].name);
			uci.set(xm.CONF, sid, 'url', b[1].url);
		});
		return uci.save().then(function() {
			window.location.reload();
		});
	}

	ui.showModal(_('选择黑名单'), [
		E('p', {}, _('这是 AdGuard Home 内置的列表库。鼠标停在名称上可以看到说明。列表越大占用的内存越多，一般选一两个就够了。')),
		E('div', { 'style': 'max-height:60vh;overflow:auto;padding-right:.5em' }, body),
		E('div', { 'class': 'right', 'style': 'margin-top:1em' }, [
			E('button', { 'class': 'btn', 'click': ui.hideModal }, _('取消')),
			' ',
			E('button', { 'class': 'btn cbi-button-positive', 'click': ui.createHandlerFn(this, add) }, _('添加所选'))
		])
	]);
}

return view.extend({
	load: function() {
		return Promise.all([
			uci.load(xm.CONF),
			xm.exec('adlist.uc', [ 'status' ]),
			xm.exec('adlist.uc', [ 'catalog' ])
		]);
	},

	render: function(res) {
		var m, s, o;
		var status = res[1] || {};
		var catalog = res[2] || {};
		var summary = E('div', { 'class': 'cbi-section-descr' });
		var stateCells = {};

		function listState(sid) {
			var st = (status.lists || {})[sid];
			if (!st)
				return E('em', {}, status.running ? _('下载中…') : _('尚未下载'));
			var parts = [ _('%s 条').format(fmtCount(st.rules)) ];
			if (st.allow)
				parts.push(_('例外 %s').format(fmtCount(st.allow)));
			if (st.skipped)
				parts.push(_('不支持 %s').format(fmtCount(st.skipped)));
			var node = E('span', { 'title': _('上次更新：%s').format(fmtTime(st.updated)) }, parts.join(' · '));
			return st.error
				? E('span', {}, [ node, ' ', xm.badge(_('上次更新失败'), 'warn') ])
				: node;
		}

		function renderStatus() {
			summary.replaceChildren.apply(summary, status.running
				? [ E('em', { 'class': 'spinning' }, _('正在下载并转换列表…')) ]
				: [ _('已安装 %s 条拦截规则').format(fmtCount(status.total)),
					status.finished ? _('，上次更新 %s。').format(fmtTime(status.finished)) : _('。') ]);
			Object.keys(stateCells).forEach(function(sid) {
				stateCells[sid].replaceChildren(listState(sid));
			});
		}

		function refresh() {
			return xm.exec('adlist.uc', [ 'status' ]).then(function(st) {
				if (st && st.ok !== false) {
					status = st;
					renderStatus();
				}
			});
		}

		function updateNow() {
			return xm.exec('adlist.uc', [ 'start' ]).then(function(r) {
				if (r.ok === false)
					ui.addNotification(null, E('p', {}, r.error || _('无法开始更新')), 'error');
				status.running = true;
				renderStatus();
			});
		}

		m = new form.Map(xm.CONF, _('广告过滤'),
			_('订阅拦截列表，被列入的域名在 DNS 上直接返回“不存在”。列表使用 AdGuard Home 的规则格式，可以从它的列表库里选，也可以填自己的地址。'));

		/* ------------------------------------------------------------ subscriptions */
		s = m.section(form.GridSection, 'adlist', _('订阅的列表'),
			_('列表通过“分流”页里的“广告（订阅列表）”规则行生效：排在它前面的规则优先，所以把某个域名加到它前面的直连或代理规则里，就等于放行。新添加的列表在“保存并应用”后自动下载。'));
		s.addremove = true;
		s.anonymous = true;
		s.sortable = true;
		s.nodescriptions = true;
		s.addbtntitle = _('添加自定义列表');
		s.modaltitle = function(sid) {
			return _('列表') + ' » ' + (uci.get(xm.CONF, sid, 'name') || _('新列表'));
		};

		o = s.option(form.Flag, 'enabled', _('启用'));
		o.editable = true;
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.Value, 'name', _('名称'));
		o.rmempty = false;

		o = s.option(form.Value, 'url', _('地址'),
			_('http 或 https 地址。支持 AdGuard 规则（||example.com^）、hosts 文件和纯域名列表三种写法。'));
		o.rmempty = false;
		o.validate = function(sid, v) {
			return /^https?:\/\/[^\s'"\\]+$/.test(v || '') ? true : _('需要是 http:// 或 https:// 开头的地址');
		};
		o.textvalue = function(sid) {
			var u = uci.get(xm.CONF, sid, 'url') || '';
			return E('span', { 'title': u }, u.length > 56 ? u.substring(0, 56) + '…' : u);
		};

		o = s.option(form.DummyValue, '_state', _('规则数'));
		o.modalonly = false;
		o.textvalue = function(sid) {
			stateCells[sid] = E('span', {}, listState(sid));
			return stateCells[sid];
		};

		/* ------------------------------------------------------------ settings */
		s = m.section(form.NamedSection, 'adblock', 'adblock', _('更新'));

		o = s.option(form.Flag, 'auto_update', _('每天自动更新'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.ListValue, 'update_hour', _('更新时间'));
		for (var h = 0; h < 24; h++)
			o.value(String(h), '%d:17'.format(h));
		o.default = '5';
		o.depends('auto_update', '1');

		o = s.option(form.Value, 'dir', _('存放目录'),
			_('转换后的列表保存在这里。大的列表有十几 MB，闪存空间紧张时可以改到 U 盘之类的位置；放在 /tmp 下重启后需要重新下载。'));
		o.default = '/etc/xray-mosdns/adlists';

		renderStatus();
		poll.add(function() {
			/* cheap when idle: only keep asking while an update is running */
			return status.running ? refresh() : Promise.resolve();
		}, 3);

		return m.render().then(function(node) {
			var tools = E('div', { 'class': 'cbi-section' }, [
				E('button', {
					'class': 'cbi-button cbi-button-action', 'style': 'margin-right:.5em',
					'click': function() { catalogDialog(catalog); }
				}, _('从 AdGuard 列表库添加…')),
				E('button', {
					'class': 'cbi-button cbi-button-action',
					'click': ui.createHandlerFn(this, updateNow)
				}, _('立即更新')),
				summary
			]);
			var first = node.querySelector('.cbi-section');
			if (first)
				first.parentNode.insertBefore(tools, first);
			return node;
		});
	}
});
