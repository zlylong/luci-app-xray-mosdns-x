'use strict';
'require view';
'require fs';
'require ui';
'require poll';
'require xray-mosdns.common as xm';

var LINES = '300';
var LOG = '/usr/libexec/xray-mosdns/log.sh';
var STORE = 'xm-log-source';

var SOURCES = [
	{ id: 'xray', title: 'Xray',
	  descr: _('Xray 进程的输出（系统日志）最近 %s 行。详细程度在“系统 → Xray 日志级别”里调。') },
	{ id: 'mosdns', title: 'mosdns-x',
	  descr: _('mosdns-x 的日志文件 /tmp/mosdns-x.log 最近 %s 行，不含逐条查询记录（见“DNS → 查询日志”）；启动失败这类写进系统日志的输出列在前面。') },
	{ id: 'app', title: _('插件服务'),
	  descr: _('本插件服务自身的日志最近 %s 行：启动与重载、配置生成、防火墙规则、DNS 看门狗、节点组看护、拦截列表更新。') }
];

function stored() {
	var id = null;
	try { id = window.sessionStorage.getItem(STORE); } catch (e) {}
	return SOURCES.some(function(s) { return s.id == id; }) ? id : SOURCES[0].id;
}

function fetchLog(id) {
	return L.resolveDefault(fs.exec(LOG, [ id, LINES ]), {});
}

return view.extend({
	load: function() {
		this.source = stored();
		return fetchLog(this.source);
	},

	render: function(res) {
		var source = this.source;
		var seq = 0;
		var box = E('textarea', {
			'class': 'cbi-input-textarea', 'readonly': '', 'wrap': 'off', 'rows': 30,
			'style': 'width:100%;font-family:monospace;font-size:12px'
		});
		var descr = E('div', { 'class': 'cbi-map-descr' });
		var follow = E('input', { 'type': 'checkbox', 'id': 'xm-log-follow', 'checked': '' });
		var tabs = E('ul', { 'class': 'cbi-tabmenu' }, SOURCES.map(function(s) {
			return E('li', { 'data-source': s.id }, E('a', {
				'href': '#',
				'click': function(ev) { ev.preventDefault(); select(s.id); }
			}, s.title));
		}));

		function mark() {
			tabs.querySelectorAll('li').forEach(function(li) {
				li.className = (li.getAttribute('data-source') == source) ? 'cbi-tab' : 'cbi-tab-disabled';
			});
			descr.textContent = SOURCES.filter(function(s) { return s.id == source; })[0].descr.format(LINES);
		}

		function show(r, toEnd) {
			var atBottom = (box.scrollTop + box.clientHeight >= box.scrollHeight - 4);
			box.value = ((r && r.stdout) || '').trim() || _('暂无日志');
			// keep the reader's place unless they were already at the end
			if (toEnd || atBottom)
				box.scrollTop = box.scrollHeight;
		}

		// only the newest request is shown: a reply for a tab that was left
		// in the meantime is dropped
		function refresh(toEnd) {
			var n = ++seq;
			return fetchLog(source).then(function(r) {
				if (n == seq)
					show(r, toEnd);
			});
		}

		function select(id) {
			if (id == source)
				return;
			source = id;
			try { window.sessionStorage.setItem(STORE, id); } catch (e) {}
			mark();
			box.value = '';
			return refresh(true);
		}

		mark();
		show(res);
		window.setTimeout(function() { box.scrollTop = box.scrollHeight; }, 0);

		poll.add(function() {
			return follow.checked ? refresh(false) : Promise.resolve();
		}, 5);

		return E('div', {}, [
			E('h2', {}, _('运行日志')),
			tabs,
			descr,
			E('div', { 'class': 'cbi-section' }, [
				box,
				E('div', { 'class': 'cbi-page-actions', 'style': 'text-align:left' }, [
					E('button', { 'class': 'cbi-button cbi-button-action', 'click': ui.createHandlerFn(this, function() { return refresh(false); }) }, _('刷新')),
					' ',
					follow,
					E('label', { 'for': 'xm-log-follow' }, ' ' + _('每 5 秒自动刷新'))
				])
			])
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
