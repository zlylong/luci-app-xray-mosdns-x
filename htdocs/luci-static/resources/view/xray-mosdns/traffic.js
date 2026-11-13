'use strict';
'require view';
'require uci';
'require fs';
'require poll';
'require xray-mosdns.ui as xm';

var CONF = 'xray-mosdns';

function fmtBytes(n) {
	n = Number(n) || 0;
	if (n < 1024) return n + ' B';
	if (n < 1048576) return (n / 1024).toFixed(1) + ' KiB';
	if (n < 1073741824) return (n / 1048576).toFixed(1) + ' MiB';
	return (n / 1073741824).toFixed(2) + ' GiB';
}

function nodeLabel(tag) {
	var name = tag.replace(/^(proxy-|out-)/, '');
	var found = null;
	(uci.sections(CONF, 'node') || []).forEach(function(n) { if (n['.name'] === name) found = n; });
	if (!found) return name;
	return (found.remarks || found.address || name) + (found.address ? ' (' + found.address + ':' + (found.port || 443) + ')' : '');
}

function errorText(err) {
	if (err === 'xray_not_running') return _('Xray 未运行（启用插件后才有节点流量）');
	if (err === 'api_unavailable') return _('统计接口不可用（检查“设置 → 本地统计 API 端口”）');
	return err || _('未知错误');
}

return view.extend({
	load: function() {
		return Promise.all([
			uci.load(CONF),
			fs.exec('/usr/libexec/xray-mosdns/traffic.sh', []).then(function(res) {
				try { return JSON.parse((res && res.stdout) || '{}'); } catch (e) { return {}; }
			}).catch(function() { return {}; })
		]);
	},

	render: function(res) {
		var tbody = E('tbody');
		var errEl = E('p', { 'class': 'cbi-value-description' });
		var totalEl = E('span', {}, '-');

		function renderData(data) {
			while (tbody.firstChild) tbody.removeChild(tbody.firstChild);
			if (data.error) {
				errEl.textContent = errorText(data.error);
				totalEl.textContent = '-';
			}
			else {
				errEl.textContent = '';
			}
			var nodes = data.nodes || [];
			var up = 0, down = 0;
			nodes.forEach(function(n) {
				up += Number(n.uplink) || 0;
				down += Number(n.downlink) || 0;
				tbody.appendChild(E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td' }, nodeLabel(n.tag)),
					E('td', { 'class': 'td' }, fmtBytes(n.uplink)),
					E('td', { 'class': 'td' }, fmtBytes(n.downlink)),
					E('td', { 'class': 'td' }, fmtBytes(n.total))
				]));
			});
			if (!nodes.length) {
				tbody.appendChild(E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td', 'colspan': 4 }, _('暂无节点流量数据'))
				]));
			}
			totalEl.textContent = fmtBytes(up) + ' / ' + fmtBytes(down);
		}

		renderData(res && res[1] ? res[1] : {});

		poll.add(function() {
			return fs.exec('/usr/libexec/xray-mosdns/traffic.sh', []).then(function(r) {
				try { renderData(JSON.parse((r && r.stdout) || '{}')); } catch (e) { /* ignore */ }
			});
		}, 10);

		return xm.page({
			title: '流量统计',
			lede: '只统计代理节点的流量，数据来自 Xray StatsService；直连与 DNS 流量不计入。每 10 秒刷新。'
		}, [
			xm.section('节点流量', [
			errEl,
			E('table', { 'class': 'table' }, [
				E('thead', {}, [ E('tr', { 'class': 'tr table-titles' }, [
					E('th', { 'class': 'th' }, _('节点')),
					E('th', { 'class': 'th' }, _('上传')),
					E('th', { 'class': 'th' }, _('下载')),
					E('th', { 'class': 'th' }, _('合计'))
				]) ]),
				tbody
			]),
			E('p', { 'class': 'xmx-num xmx-muted' }, [ _('合计（上传 / 下载）：'), totalEl ])
			])
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
