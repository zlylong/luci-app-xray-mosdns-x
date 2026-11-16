'use strict';
'require view';
'require fs';
'require ui';
'require xray-mosdns.common as xm';

var SCRIPT = '/usr/libexec/xray-mosdns/geoview.uc';
var PREVIEW = 100;	/* lines shown in the page; the rest is offered as a download */
var MAX_TAGS = 300;	/* dataset names shown at once */

function kindLabel(kind) {
	return kind === 'geoip' ? 'geoip' : 'geosite';
}

return view.extend({
	load: function() {
		return xm.exec('geoview.uc', [ 'tags' ]);
	},

	render: function(tags) {
		var all = [];
		(tags.geosite || []).forEach(function(t) { all.push({ kind: 'geosite', tag: t }); });
		(tags.geoip || []).forEach(function(t) { all.push({ kind: 'geoip', tag: t }); });

		var lookupOut = E('div');
		var tagList = E('div');
		var tagCount = E('div', { 'class': 'cbi-section-descr' });
		var content = E('div');

		/* ------------------------------------------------------------ dataset content */
		function download(kind, tag) {
			return fs.exec_direct(SCRIPT, [ 'dump', kind, tag ], 'blob').then(function(blob) {
				var url = URL.createObjectURL(blob);
				var a = E('a', { 'href': url, 'download': '%s-%s.txt'.format(kind, tag), 'style': 'display:none' });
				document.body.appendChild(a);
				a.click();
				document.body.removeChild(a);
				window.setTimeout(function() { URL.revokeObjectURL(url); }, 1000);
			}).catch(function(err) {
				ui.addNotification(null, E('p', {}, _('下载失败：%s').format(err.message || err)), 'error');
			});
		}

		function showDataset(kind, tag) {
			content.replaceChildren(E('p', { 'class': 'spinning' }, _('正在读取 %s:%s…').format(kindLabel(kind), tag)));
			content.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
			return xm.exec('geoview.uc', [ 'list', kind, tag, String(PREVIEW) ]).then(function(r) {
				if (r.ok === false) {
					content.replaceChildren(E('p', { 'class': 'alert-message warning' }, r.error || _('读取失败')));
					return;
				}
				var more = r.total > r.lines.length;
				content.replaceChildren(
					E('h3', {}, '%s:%s'.format(kindLabel(kind), r.tag)),
					E('div', { 'class': 'cbi-section-descr' }, more
						? _('共 %d 条，下面显示前 %d 条。').format(r.total, r.lines.length)
						: _('共 %d 条。').format(r.total)),
					E('textarea', {
						'class': 'cbi-input-textarea', 'readonly': '', 'wrap': 'off',
						'rows': Math.min(Math.max(r.lines.length, 3), 20),
						'style': 'width:100%;font-family:monospace;font-size:12px'
					}, r.lines.join('\n')),
					E('div', { 'class': 'cbi-page-actions', 'style': 'text-align:left' }, [
						E('button', {
							'class': 'cbi-button cbi-button-action',
							'click': ui.createHandlerFn(this, function() { return download(kind, r.tag); })
						}, more ? _('下载全部 %d 条（txt）').format(r.total) : _('下载为 txt'))
					])
				);
			});
		}

		function tagLink(kind, tag) {
			return E('a', {
				'href': '#',
				'click': function(ev) {
					ev.preventDefault();
					showDataset(kind, tag);
				}
			}, '%s:%s'.format(kindLabel(kind), tag));
		}

		/* ------------------------------------------------------------ dataset names */
		function renderTags(text) {
			text = (text || '').trim().toLowerCase().replace(/^geo(site|ip):/, '');
			var found = all.filter(function(e) { return !text || e.tag.indexOf(text) >= 0; });
			tagCount.textContent = text
				? _('名称包含“%s”的数据集有 %d 个%s').format(text, found.length,
					found.length > MAX_TAGS ? _('，显示前 %d 个，继续输入可以缩小范围。').format(MAX_TAGS) : '。')
				: _('共 %d 个数据集（geosite %d 个，geoip %d 个）%s').format(all.length,
					(tags.geosite || []).length, (tags.geoip || []).length,
					all.length > MAX_TAGS ? _('，显示前 %d 个，输入名称来查找。').format(MAX_TAGS) : '。');
			tagList.replaceChildren.apply(tagList, found.slice(0, MAX_TAGS).map(function(e) {
				return E('span', { 'style': 'display:inline-block;margin:0 1em .4em 0;white-space:nowrap' },
					tagLink(e.kind, e.tag));
			}));
		}

		var tagInput = E('input', {
			'type': 'text', 'class': 'cbi-input-text', 'placeholder': 'google',
			'style': 'max-width:24em'
		});
		tagInput.addEventListener('input', function() { renderTags(tagInput.value); });
		renderTags('');

		/* ------------------------------------------------------------ reverse lookup */
		var queryInput = E('input', {
			'type': 'text', 'class': 'cbi-input-text', 'placeholder': 'www.google.com / 8.8.8.8',
			'style': 'max-width:24em'
		});

		function lookup() {
			var q = queryInput.value.trim();
			if (!q)
				return Promise.resolve();
			lookupOut.replaceChildren(E('p', { 'class': 'spinning' }, _('正在查询…')));
			return xm.exec('geoview.uc', [ 'lookup', q ]).then(function(r) {
				if (r.ok === false) {
					lookupOut.replaceChildren(E('p', { 'class': 'alert-message warning' },
						r.error === 'not a domain name' ? _('请输入域名或 IP 地址。') : (r.error || _('查询失败'))));
					return;
				}
				var kind = (r.type === 'ip') ? 'geoip' : 'geosite';
				if (!r.matches.length) {
					lookupOut.replaceChildren(E('p', {}, _('%s 不在任何 %s 数据集里。').format(r.query, kind)));
					return;
				}
				lookupOut.replaceChildren(
					E('div', { 'class': 'cbi-section-descr' },
						_('%s 出现在 %d 条记录里。点数据集名称可以查看它的全部内容。').format(r.query, r.matches.length)),
					E('table', { 'class': 'table' }, [
						E('tr', { 'class': 'tr table-titles' }, [
							E('th', { 'class': 'th' }, _('数据集')),
							E('th', { 'class': 'th' }, _('命中的条目')),
							E('th', { 'class': 'th' }, _('属性'))
						])
					].concat(r.matches.map(function(m) {
						return E('tr', { 'class': 'tr' }, [
							E('td', { 'class': 'td' }, tagLink(kind, m.tag)),
							E('td', { 'class': 'td' }, E('code', {}, m.rule)),
							E('td', { 'class': 'td' }, (m.attrs || []).map(function(a) { return '@' + a; }).join(' ') || '-')
						]);
					})))
				);
			});
		}

		var lookupBtn = E('button', {
			'class': 'cbi-button cbi-button-action', 'style': 'margin-left:.5em',
			'click': ui.createHandlerFn(this, lookup)
		}, _('查询'));
		queryInput.addEventListener('keydown', function(ev) {
			if (ev.key === 'Enter') {
				ev.preventDefault();
				lookupBtn.click();
			}
		});

		if (!all.length)
			return E('div', {}, [
				E('h2', {}, _('Geo 数据查询')),
				E('p', { 'class': 'alert-message warning' },
					_('没有找到 geo 数据（/usr/share/v2ray/geosite.dat、geoip.dat）。可以到“更新”页下载。'))
			]);

		return E('div', {}, [
			E('h2', {}, _('Geo 数据查询')),
			E('div', { 'class': 'cbi-map-descr' },
				_('查看 geosite.dat 和 geoip.dat 里有什么：某个域名或 IP 属于哪些数据集，某个数据集里有哪些条目。写分流规则时用得上。')),
			xm.section(_('域名或 IP 属于哪些数据集'), [
				E('div', {}, [ queryInput, lookupBtn ]),
				lookupOut
			], _('域名按完整域名、上级域名和关键字匹配；正则条目按 POSIX 语法近似判断，个别写法可能判断不了。IP 只看 /8 及更长的网段。')),
			xm.section(_('数据集'), [
				E('div', {}, [ tagInput ]),
				tagCount,
				tagList,
				content
			], _('输入名称的一部分来查找，点名称查看内容。'))
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
