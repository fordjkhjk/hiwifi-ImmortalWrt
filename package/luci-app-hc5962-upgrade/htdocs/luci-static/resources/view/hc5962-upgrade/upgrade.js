'use strict';
'require view';
'require rpc';
'require ui';
'require poll';
'require dom';

/*
 * luci-app-hc5962-upgrade — HC5962 网页固件升级
 *
 * 页面: 系统 → 固件升级
 * 流程: 显示当前/最新版本 → 检查更新 → 输入确认词 upgrade → 一键刷入
 * 后端: 复用固件内置脚本 fw-check-update --json / fw-upgrade -y
 * 安全: 升级必须输入确认词；升级中按钮置灰并轮询日志。
 */

const exec = rpc.declare({
	object: 'file',
	method: 'exec',
	params: ['command', 'params'],
	expect: { code: 0, stdout: '', stderr: '' }
});

return view.extend({
	upgrading: false,
	pollFn: null,

	/* rpcd 的 file.exec 不走 shell、不搜 PATH，统一用 /bin/sh -c 包一层 */
	runCmd: function(cmd) {
		return L.resolveDefault(exec('/bin/sh', ['-c', cmd]),
			{ code: -1, stdout: '', stderr: '命令执行失败' });
	},

	parseInfo: function(res) {
		try {
			var o = JSON.parse(res.stdout || '{}');
			return (o && typeof o === 'object') ? o : {};
		}
		catch (e) {
			return {};
		}
	},

	badge: function(text, cls) {
		return E('span', { class: 'cbi-button ' + (cls || '') }, text);
	},

	buildStatusCard: function(info) {
		var badge;

		if (info.error) {
			badge = this.badge(info.error, 'cbi-button-negative');
		}
		else if (info.current && info.latest) {
			badge = info.updatable ?
				this.badge('有新版本可升级', 'cbi-button-positive important') :
				this.badge('已是最新版本', 'cbi-button-action');
		}
		else {
			badge = this.badge('未知（旧版固件，建议升级一次）');
		}

		return E('div', { class: 'cbi-section' }, [
			E('div', { class: 'cbi-section-node' }, [
				E('div', { class: 'table' }, [
					E('div', { class: 'tr' }, [
						E('div', { class: 'td left', width: '30%' }, '当前版本'),
						E('div', { class: 'td left' }, info.current || '未知')
					]),
					E('div', { class: 'tr' }, [
						E('div', { class: 'td left', width: '30%' }, '最新版本'),
						E('div', { class: 'td left' }, info.latest || '—')
					]),
					E('div', { class: 'tr' }, [
						E('div', { class: 'td left', width: '30%' }, '发布日期'),
						E('div', { class: 'td left' }, info.published || '—')
					]),
					E('div', { class: 'tr' }, [
						E('div', { class: 'td left', width: '30%' }, '状态'),
						E('div', { class: 'td left' }, badge)
					])
				])
			])
		]);
	},

	buildUpgradeSection: function(info) {
		var self = this;

		if (self.upgrading) {
			return E('div', {}, [
				E('p', { class: 'cbi-button cbi-button-positive important' }, '升级进行中，请勿断电、请勿关闭此页面…'),
				self.logArea
			]);
		}

		if (info && info.updatable) {
			return E('div', {}, [
				E('p', '新固件约 ' + (info.size_mb || '?') + ' MB。下载到内存后自动校验 sha256 并试刷，全部通过才写入。'),
				E('p', '升级会清除 iStore / opkg 后装的软件（内置插件不受影响），路由器会自动重启，全程约 3-5 分钟。'),
				E('div', { class: 'cbi-section-node' }, [
					E('label', { for: 'hc5962-kw' }, '输入 upgrade 确认升级：'),
					self.kwInput,
					' ',
					E('button', {
						class: 'cbi-button cbi-button-negative important',
						click: ui.createHandlerFn(self, self.startUpgrade)
					}, '开始升级')
				])
			]);
		}

		return E('div', {});
	},

	checkUpdate: function() {
		var self = this;
		return self.runCmd('fw-check-update --json').then(function(res) {
			var info = self.parseInfo(res);
			dom.content(self.statusCardHost, self.buildStatusCard(info));
			dom.content(self.upgradeSectionHost, self.buildUpgradeSection(info));
		});
	},

	startUpgrade: function() {
		var self = this;

		if ((self.kwInput.value || '').trim() !== 'upgrade') {
			ui.addNotification(null, E('p', '确认词不正确。请在输入框中输入 upgrade 后再点「开始升级」。'));
			return;
		}

		self.upgrading = true;
		dom.content(self.upgradeSectionHost, self.buildUpgradeSection(null));

		return self.runCmd('nohup fw-upgrade -y >/tmp/fw-upgrade.log 2>&1 &').then(function() {
			self.pollFn = L.bind(self.pollLog, self);
			poll.add(self.pollFn, 2);
			poll.start();
		});
	},

	pollLog: function() {
		var self = this;

		self.runCmd('cat /tmp/fw-upgrade.log 2>/dev/null').then(function(res) {
			if (self.logArea) {
				self.logArea.textContent = res.stdout || '(暂无日志)';
				self.logArea.scrollTop = self.logArea.scrollHeight;
			}
		});

		return self.runCmd('pgrep -f "^fw-upgrade -y" >/dev/null 2>&1 && echo RUNNING || echo DONE').then(function(res) {
			if (res.stdout.indexOf('RUNNING') >= 0)
				return;

			poll.remove(self.pollFn);
			self.upgrading = false;

			return self.runCmd('tail -n 4 /tmp/fw-upgrade.log 2>/dev/null').then(function(r) {
				var flashing = (r.stdout.indexOf('[6/6]') >= 0);
				dom.content(self.upgradeSectionHost, E('div', {}, [
					E('p', { class: flashing ? 'cbi-button cbi-button-positive important' : 'cbi-button cbi-button-negative' },
						flashing ? '刷机已启动，路由器正在重启。2-3 分钟后请重新打开本页面，应显示新版本。' :
						'升级流程已结束，请查看上方日志确认结果（若有错误即为失败）。')
				]));
			});
		});
	},

	load: function() {
		var self = this;
		return Promise.all([
			self.runCmd('fw-check-update --json'),
			self.runCmd('pgrep -f "^fw-upgrade -y" >/dev/null 2>&1 && echo RUNNING || echo DONE')
		]);
	},

	render: function(data) {
		var self = this;
		var info = self.parseInfo(data[0]);
		var running = (data[1].stdout || '').indexOf('RUNNING') >= 0;

		self.kwInput = E('input', { type: 'text', id: 'hc5962-kw', placeholder: 'upgrade', style: 'width:8em' });
		self.logArea = E('pre', { style: 'max-height:320px;overflow:auto;white-space:pre-wrap;word-break:break-all;background:#111;color:#4ade80;padding:8px;border-radius:4px;font-size:12px;' });
		self.statusCardHost = E('div', {});
		self.upgradeSectionHost = E('div', {});

		dom.content(self.statusCardHost, self.buildStatusCard(info));
		dom.content(self.upgradeSectionHost, self.buildUpgradeSection(info));

		if (running) {
			self.upgrading = true;
			dom.content(self.upgradeSectionHost, self.buildUpgradeSection(null));
			self.pollFn = L.bind(self.pollLog, self);
			poll.add(self.pollFn, 2);
			poll.start();
			self.pollLog();
		}

		return E('div', { class: 'cbi-map' }, [
			E('h2', '固件升级'),
			E('p', { class: 'cbi-map-descr' },
				'检查 GitHub 仓库是否有新版本固件，并在线刷入。升级前请确认路由器供电稳定；整个过程约 3-5 分钟。'),
			self.statusCardHost,
			E('div', { class: 'right', style: 'margin:8px 0' }, [
				E('button', {
					class: 'cbi-button cbi-button-action',
					click: ui.createHandlerFn(self, self.checkUpdate)
				}, '检查更新')
			]),
			self.upgradeSectionHost
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
