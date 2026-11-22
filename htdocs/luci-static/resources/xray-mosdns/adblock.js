'use strict';
'require baseclass';
'require form';
'require uci';
'require ui';
'require poll';
'require xray-mosdns.common as xm';

/* The "ad filtering" tab of the DNS page: blocklist subscriptions, their
 * update settings, and the tools around them. */

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

/* a catalogue entry counts as subscribed by its id, or by address for older subscriptions */
function subscribed() {
	var ids = {}, urls = {};
	(uci.sections(xm.CONF, 'adlist') || []).forEach(function(s) {
		if (s.catalog_id != null) ids[String(s.catalog_id)] = true;
		urls[s.url] = true;
	});
	return function(f) { return !!(ids[String(f.id)] || urls[f.url]); };
}

/* Pick lists from AdGuard's catalogue. The picks are staged like any other
 * edit, after the form's own unsaved edits (map.save parses those first),
 * and the form is redrawn in place: nothing typed so far is lost. */
function catalogDialog(catalog, map) {
	var isSubscribed = subscribed();
	var boxes = [];
	var body = [];

	(catalog.groups || []).forEach(function(grp) {
		var filters = (catalog.filters || []).filter(function(f) { return f.group === grp.id && !f.deprecated; });
		filters.sort(function(a, b) { return a.name.toLowerCase() < b.name.toLowerCase() ? -1 : 1; });
		if (!filters.length)
			return;
		var label = GROUPS[grp.name] || [ grp.name, '' ];
		body.push(E('h5', { 'style': 'margin:1em 0 0' }, label[0]));
		if (label[1])
			body.push(E('div', { 'class': 'cbi-value-description', 'style': 'margin:0 0 .5em' }, label[1]));
		filters.forEach(function(f) {
			var cb = E('input', { 'type': 'checkbox', 'id': 'xm-adl-' + f.id });
			var has = isSubscribed(f);
			if (has) {
				cb.checked = true;
				cb.disabled = true;
			}
			else {
				boxes.push([ cb, f ]);
			}
			body.push(E('div', { 'style': 'margin:.15em 0' }, [
				cb, ' ',
				E('label', { 'for': 'xm-adl-' + f.id, 'title': f.description || '' }, f.name),
				has ? E('em', {}, ' ' + _('（已订阅）')) : '',
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
		return map.save(function() {
			picked.forEach(function(b) {
				var sid = uci.add(xm.CONF, 'adlist');
				uci.set(xm.CONF, sid, 'enabled', '1');
				uci.set(xm.CONF, sid, 'name', b[1].name);
				uci.set(xm.CONF, sid, 'url', b[1].url);
				/* the link to the catalogue: name and address follow this entry from now on */
				uci.set(xm.CONF, sid, 'catalog_id', String(b[1].id));
			});
		}).then(ui.hideModal);
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

return baseclass.extend({
	/* download status and the AdGuard catalogue, for tab() */
	load: function() {
		return Promise.all([
			xm.exec('info.sh', [ 'adlist-status' ]),
			xm.exec('info.sh', [ 'adlist-catalog' ])
		]);
	},

	/* fills tab `tab` of section `s` (same map, config xray-mosdns) */
	tab: function(s, tab, data) {
		var o, ss;
		var status = (data && data[0]) || {};
		var catalog = (data && data[1]) || {};
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
			var extra = [];
			if (st.error)
				extra.push(' ', xm.badge(_('上次更新失败'), 'warn'));
			if (st.catalog === 'deprecated')
				extra.push(' ', E('span', { 'title': _('AdGuard 已把这个列表标记为弃用，它可能不再更新。建议删除或换一个。') },
					xm.badge(_('已弃用'), 'warn')));
			else if (st.catalog === 'gone')
				extra.push(' ', E('span', { 'title': _('这个列表已经不在 AdGuard 的列表库里了，地址可能随时失效。建议删除或换一个。') },
					xm.badge(_('已从列表库移除'), 'bad')));
			return extra.length ? E('span', {}, [ node ].concat(extra)) : node;
		}

		function renderStatus() {
			summary.replaceChildren.apply(summary, status.running
				? [ E('em', { 'class': 'spinning' }, _('正在下载并转换列表…')) ]
				: [ _('已安装 %s 条拦截规则').format(fmtCount(status.total)),
					status.finished ? _('，上次更新 %s。').format(fmtTime(status.finished)) : _('。') ].concat(status.error
					? [ ' ', xm.badge(_('合并失败'), 'bad'), ' ', _('仍在使用上一份列表：%s').format(status.error) ] : []));
			Object.keys(stateCells).forEach(function(sid) {
				stateCells[sid].replaceChildren(listState(sid));
			});
		}

		function refresh() {
			return xm.exec('info.sh', [ 'adlist-status' ]).then(function(st) {
				if (st && st.ok !== false) {
					status = st;
					renderStatus();
				}
			});
		}

		function syncCatalog() {
			return xm.exec('adlist.uc', [ 'catalog-sync' ]).then(function(r) {
				if (r.ok === false) {
					/* an update running is not a failure: it is done the same way afterwards */
					ui.addNotification(null, E('p', {}, r.busy
						? _('拦截列表正在更新，更新完成后再同步列表库。')
						: _('列表库下载失败，继续使用现有的目录。')), r.busy ? 'info' : 'warning');
					return;
				}
				var flagged = Object.keys(r.flags || {}).length;
				ui.addNotification(null, E('p', {},
					_('列表库已刷新，共 %d 个列表。').format(r.filters) +
					(r.changed ? _('有订阅的名称或地址随列表库更新了。') : '') +
					(flagged ? _('有 %d 个订阅的列表已被弃用或移除，见下方标记。').format(flagged) : '')), 'info');
				window.setTimeout(function() { window.location.reload(); }, 1500);
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

		/* ------------------------------------------------------------ tools */
		o = s.taboption(tab, form.DummyValue, '_adblock_tools');
		o.render = function() {
			return E('div', { 'class': 'cbi-section' }, [
				E('div', { 'class': 'cbi-section-descr' },
					_('订阅拦截列表，被列入的域名在 DNS 上直接返回“不存在”（或按“拦截与日志”里的拦截方式应答）。列表使用 AdGuard Home 的规则格式，可以从它的列表库里选，也可以填自己的地址。')),
				E('div', {}, [
					E('button', {
						'class': 'cbi-button cbi-button-action', 'style': 'margin-right:.5em',
						'click': function(ev) { ev.preventDefault(); catalogDialog(catalog, s.map); }
					}, _('从 AdGuard 列表库添加…')),
					E('button', {
						'class': 'cbi-button cbi-button-action', 'style': 'margin-right:.5em',
						'click': ui.createHandlerFn(this, updateNow)
					}, _('立即更新')),
					E('button', {
						'class': 'cbi-button cbi-button-action',
						'title': _('重新下载 AdGuard 的列表目录，并让来自列表库的订阅跟随它'),
						'click': ui.createHandlerFn(this, syncCatalog)
					}, _('刷新列表库'))
				]),
				summary
			]);
		};

		/* ------------------------------------------------------------ subscriptions */
		o = s.taboption(tab, form.SectionValue, '_adlist', form.GridSection, 'adlist', _('订阅的列表'),
			_('列表通过“分流”页里的“广告（订阅列表）”规则行生效：排在它前面的规则优先，所以把某个域名加到它前面的直连或代理规则里，就等于放行。新添加的列表在“保存并应用”后自动下载。从列表库添加的订阅会跟随列表库：每次更新前先刷新目录，名称和地址随之同步；列表被弃用或移除时只做标记，不会自动删除。'));
		ss = o.subsection;
		ss.addremove = true;
		ss.anonymous = true;
		ss.sortable = true;
		ss.nodescriptions = true;
		ss.addbtntitle = _('添加自定义列表');
		ss.modaltitle = function(sid) {
			return _('列表') + ' » ' + (uci.get(xm.CONF, sid, 'name') || _('新列表'));
		};

		o = ss.option(form.Flag, 'enabled', _('启用'));
		o.editable = true;
		o.default = '1';
		o.rmempty = false;

		o = ss.option(form.Value, 'name', _('名称'),
			_('来自列表库的订阅，名称和地址在每次更新时会被列表库里的值覆盖。'));
		o.rmempty = false;

		o = ss.option(form.Value, 'url', _('地址'),
			_('http 或 https 地址。支持 AdGuard 规则（||example.com^）、hosts 文件和纯域名列表三种写法。'));
		o.rmempty = false;
		o.validate = function(sid, v) {
			return /^https?:\/\/[^\s'"\\]+$/.test(v || '') ? true : _('需要是 http:// 或 https:// 开头的地址');
		};
		o.textvalue = function(sid) {
			var u = uci.get(xm.CONF, sid, 'url') || '';
			return E('span', { 'title': u }, u.length > 56 ? u.substring(0, 56) + '…' : u);
		};

		o = ss.option(form.DummyValue, '_state', _('规则数'));
		o.modalonly = false;
		o.textvalue = function(sid) {
			stateCells[sid] = E('span', {}, listState(sid));
			return stateCells[sid];
		};

		/* ------------------------------------------------------------ settings */
		o = s.taboption(tab, form.SectionValue, '_adblock', form.NamedSection, 'adblock', 'adblock', _('更新'));
		ss = o.subsection;

		o = ss.option(form.Flag, 'auto_update', _('每天自动更新'));
		o.default = '1';
		o.rmempty = false;

		o = ss.option(form.ListValue, 'update_hour', _('更新时间'));
		for (var h = 0; h < 24; h++)
			o.value(String(h), '%d:17'.format(h));
		o.default = '5';
		o.depends('auto_update', '1');

		o = ss.option(form.Value, 'dir', _('存放目录'),
			_('转换后的列表保存在这里。大的列表有十几 MB，闪存空间紧张时可以改到 U 盘之类的位置；放在 /tmp 下重启后需要重新下载。/etc/xray-mosdns 以外的目录可以和别的程序共用：列表放在其中的 xray-mosdns 子目录里，卸载时只删除这个子目录。'));
		o.default = '/etc/xray-mosdns/adlists';

		renderStatus();
		poll.add(function() {
			/* cheap when idle: only keep asking while an update is running */
			return status.running ? refresh() : Promise.resolve();
		}, 3);
	}
});
