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
 * 后端: 专用 rpcd 脚本 /usr/libexec/rpcd/hc5962-upgrade（check/log/start）
 *       不用 file.exec —— 它有命令白名单，非预登记命令会被权限拒绝
 * 安全: 升级必须输入确认词；升级中按钮置灰并轮询日志。
 * 进度: v4（2026-09-21）升级中显示三步进度面板（下载/校验/刷入），
 *       按日志 [1/6]~[6/6] 标记点亮；下载与刷入阶段按耗时估算进度，
 *       校验阶段（MIPS 上慢、无输出）用滑动动画 + "页面不动是正常的"提示。
 *       9/18 实测教训：sha256 几十秒无输出被误判为卡死。
 */

const checkRpc = rpc.declare({ object: 'hc5962-upgrade', method: 'check' });
const logRpc   = rpc.declare({ object: 'hc5962-upgrade', method: 'log' });
const startRpc = rpc.declare({ object: 'hc5962-upgrade', method: 'start' });

const CSS =
	'.hc5u-banner{background:#eaf3fd;border:1px solid #bcd8f5;color:#1c5a9e;border-radius:6px;padding:10px 14px;font-size:14px;font-weight:bold;margin:8px 0 14px}' +
	'.hc5u-banner.ok{background:#e8f7ef;border-color:#b5e2cb;color:#1c6e44}' +
	'.hc5u-banner.err{background:#fdecec;border-color:#f0b9b7;color:#a13030}' +
	'.hc5u-pct{font-size:26px;font-weight:bold;color:#2f7cd3}' +
	'.hc5u-stage{font-size:14px;margin-left:8px}' +
	'.hc5u-track{height:14px;background:#e6e9ed;border-radius:7px;overflow:hidden;margin:8px 0 14px}' +
	'.hc5u-fill{height:100%;width:0%;background:linear-gradient(90deg,#2f7cd3,#55a1e8);border-radius:7px;transition:width .5s ease}' +
	'.hc5u-fill.indet{width:30%;animation:hc5u-slide 1.1s ease-in-out infinite alternate}' +
	'.hc5u-fill.full{background:#2ea36b}' +
	'@keyframes hc5u-slide{from{margin-left:0}to{margin-left:70%}}' +
	'.hc5u-steps{list-style:none;margin:0;padding:0;font-size:14px}' +
	'.hc5u-steps li{display:flex;align-items:center;gap:9px;padding:6px 2px;color:#7a8794}' +
	'.hc5u-ic{width:20px;height:20px;border-radius:50%;flex:none;display:flex;align-items:center;justify-content:center;font-size:12px;background:#e6e9ed;color:#98a2ad}' +
	'.hc5u-steps li.active{color:#2c3e50;font-weight:bold}' +
	'.hc5u-steps li.active .hc5u-ic{background:#2f7cd3;color:#fff;animation:hc5u-pulse 1.2s ease-in-out infinite}' +
	'.hc5u-steps li.done{color:#2ea36b}' +
	'.hc5u-steps li.done .hc5u-ic{background:#2ea36b;color:#fff}' +
	'.hc5u-dt{margin-left:auto;font-size:12px;color:#7a8794;font-weight:normal}' +
	'@keyframes hc5u-pulse{50%{opacity:.55}}' +
	'.hc5u-spin{display:inline-block;width:12px;height:12px;border:2px solid #cfe0f2;border-top-color:#2f7cd3;border-radius:50%;animation:hc5u-rot .8s linear infinite;vertical-align:-1px;margin-right:6px}' +
	'@keyframes hc5u-rot{to{transform:rotate(360deg)}}' +
	'.hc5u-slow{font-size:12.5px;color:#e8a33d;margin-top:4px}';

/* 日志标记 → 三步映射: ①[1/6]+[2/6] ②[3/6]+[4/6]+[5/6] ③[6/6] */
const MARK = { step3: '[6/6]', step2: '[3/6]', step1: '[1/6]' };

return view.extend({
	upgrading: false,
	pollFn: null,
	curStep: 0,
	stepStartedAt: 0,

	badge: function(text, cls) {
		return E('span', { class: 'cbi-button ' + (cls || '') }, text);
	},

	buildStatusCard: function(info) {
		var badge;

		if (!info || Object.keys(info).length === 0) {
			badge = this.badge('后端调用失败（检查浏览器控制台或 SSH 跑 fw-check-update）', 'cbi-button-negative');
		}
		else if (info.error) {
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
						E('div', { class: 'td left' }, (info && info.current) || '未知')
					]),
					E('div', { class: 'tr' }, [
						E('div', { class: 'td left', width: '30%' }, '最新版本'),
						E('div', { class: 'td left' }, (info && info.latest) || '—')
					]),
					E('div', { class: 'tr' }, [
						E('div', { class: 'td left', width: '30%' }, '发布日期'),
						E('div', { class: 'td left' }, (info && info.published) || '—')
					]),
					E('div', { class: 'tr' }, [
						E('div', { class: 'td left', width: '30%' }, '状态'),
						E('div', { class: 'td left' }, badge)
					])
				])
			])
		]);
	},

	/* ===== v4 三步进度面板 ===== */

	buildProgressSection: function() {
		var self = this;

		self.bannerEl = E('div', { class: 'hc5u-banner' },
			'升级进行中，请勿断电、请勿关闭此页面…');
		self.pctEl = E('span', { class: 'hc5u-pct' }, '0%');
		self.stageLabelEl = E('span', { class: 'hc5u-stage' }, '准备中…');
		self.fillEl = E('div', { class: 'hc5u-fill' });
		self.slowNoteEl = E('p', { class: 'hc5u-slow', style: 'display:none' }, [
			E('span', { class: 'hc5u-spin' }),
			' 校验在 MIPS CPU 上较慢，页面不动是正常的，通常需要 1-2 分钟，请耐心等待。'
		]);

		self.stepEls = {};
		var names = { 1: '下载固件', 2: '校验完整性并验证镜像', 3: '写入 Flash 并重启' };
		var list = E('ul', { class: 'hc5u-steps' });

		for (var i = 1; i <= 3; i++) {
			var ic = E('span', { class: 'hc5u-ic' }, String(i));
			var dt = E('span', { class: 'hc5u-dt' });
			self.stepEls[i] = { li: E('li', {}, [ic, names[i], dt]), ic: ic, dt: dt };
			list.appendChild(self.stepEls[i].li);
		}

		self.curStep = 0;
		self.stepStartedAt = Date.now();

		return E('div', {}, [
			E('h3', '升级进度'),
			self.bannerEl,
			E('div', {}, [ self.pctEl, self.stageLabelEl ]),
			E('div', { class: 'hc5u-track' }, self.fillEl),
			list,
			self.slowNoteEl
		]);
	},

	setStepState: function(i, state) {
		var s = this.stepEls[i];
		if (!s) return;
		s.li.className = state;
		if (state === 'done') s.ic.textContent = '✓';
	},

	go: function(pct, label, indet) {
		this.stageLabelEl.textContent = label;
		if (indet) {
			this.fillEl.className = 'hc5u-fill indet';
			this.pctEl.textContent = '…';
		} else {
			this.fillEl.className = 'hc5u-fill';
			this.fillEl.style.width = pct + '%';
			this.pctEl.textContent = Math.round(pct) + '%';
		}
	},

	/* 依据后端日志更新三步面板；log 为 rpcd log 返回的全文 */
	renderProgress: function(log) {
		var self = this;
		log = log || '';

		var step = log.indexOf(MARK.step3) >= 0 ? 3 :
		           log.indexOf(MARK.step2) >= 0 ? 2 :
		           log.indexOf(MARK.step1) >= 0 ? 1 : 0;

		if (step !== self.curStep) {
			/* 上一步收尾：打勾 + 记录耗时 */
			if (self.curStep > 0) {
				self.setStepState(self.curStep, 'done');
				var took = (Date.now() - self.stepStartedAt) / 1000;
				self.stepEls[self.curStep].dt.textContent =
					took >= 60 ? Math.floor(took/60) + 'm' + Math.round(took%60) + 's'
					   : Math.round(took) + 's';
			}
			if (step > 0)
				self.setStepState(step, 'active');
			self.curStep = step;
			self.stepStartedAt = Date.now();
		}

		var el = (Date.now() - self.stepStartedAt) / 1000;

		if (step === 0) {
			self.go(2, '等待升级脚本启动…');
		}
		else if (step === 1) {
			/* 下载：按耗时估算（33MB，按约 150s 估算），标记出现时由下一步校正 */
			var p = 4 + Math.min(30, el / 150 * 30);
			self.go(p, '下载固件（约 33 MB）…');
		}
		else if (step === 2) {
			/* 校验 + 试刷：MIPS 上慢且无输出 → 不确定进度动画 */
			self.go(38, '校验完整性并验证镜像…', true);
			self.slowNoteEl.style.display = el > 5 ? '' : 'none';
		}
		else {
			/* 写入：缓慢爬到 97%，等待进程结束 */
			var p3 = 72 + Math.min(25, el / 240 * 25);
			self.go(p3, '写入 Flash，请勿断电…');
			self.slowNoteEl.style.display = 'none';
		}
	},

	finishProgress: function(log) {
		var self = this;
		var flashing = (log.indexOf(MARK.step3) >= 0);

		poll.remove(self.pollFn);
		self.upgrading = false;
		self.slowNoteEl.style.display = 'none';

		if (flashing) {
			self.setStepState(3, 'done');
			self.fillEl.className = 'hc5u-fill full';
			self.fillEl.style.width = '100%';
			self.pctEl.textContent = '100%';
			self.stageLabelEl.textContent = '完成，等待路由器重启';
			self.bannerEl.className = 'hc5u-banner ok';
			self.bannerEl.textContent = '✅ 刷机已启动，路由器正在重启。2-3 分钟后请重新打开本页面，应显示新版本。';
		} else {
			self.bannerEl.className = 'hc5u-banner err';
			self.bannerEl.textContent = '❌ 升级流程已结束，但未走到刷入步骤（可能是失败）。错误详情：';
			/* 失败时才展示日志，便于排障 */
			self.progressHost.appendChild(
				E('pre', { style: 'max-height:320px;overflow:auto;white-space:pre-wrap;word-break:break-all;background:#14181d;color:#4ade80;padding:10px;border-radius:6px;font-size:12px;' },
					log || '(无日志)'));
		}
	},

	buildUpgradeSection: function(info) {
		var self = this;

		if (self.upgrading)
			return self.progressHost;

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
		return L.resolveDefault(checkRpc(), {}).then(function(info) {
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
		self.progressHost = E('div', {});
		dom.content(self.progressHost, self.buildProgressSection());
		dom.content(self.upgradeSectionHost, self.progressHost);

		return L.resolveDefault(startRpc(), {}).then(function() {
			self.pollFn = L.bind(self.pollLog, self);
			poll.add(self.pollFn, 2);
			poll.start();
		});
	},

	pollLog: function() {
		var self = this;

		return L.resolveDefault(logRpc(), {}).then(function(res) {
			var log = (res && res.log) || '';

			if (res && res.running) {
				self.renderProgress(log);
				return;
			}

			self.finishProgress(log);
		});
	},

	load: function() {
		return Promise.all([
			L.resolveDefault(checkRpc(), {}),
			L.resolveDefault(logRpc(), { running: false, log: '' })
		]);
	},

	render: function(data) {
		var self = this;
		var info = data[0] || {};
		var running = !!(data[1] && data[1].running);

		self.kwInput = E('input', { type: 'text', id: 'hc5962-kw', placeholder: 'upgrade', style: 'width:8em' });
		self.statusCardHost = E('div', {});
		self.upgradeSectionHost = E('div', {});

		/* 进度面板样式只注入一次 */
		if (!document.getElementById('hc5u-css')) {
			document.head.appendChild(E('style', { id: 'hc5u-css' }, CSS));
		}

		dom.content(self.statusCardHost, self.buildStatusCard(info));
		dom.content(self.upgradeSectionHost, self.buildUpgradeSection(info));

		if (running) {
			self.upgrading = true;
			self.progressHost = E('div', {});
			dom.content(self.progressHost, self.buildProgressSection());
			dom.content(self.upgradeSectionHost, self.progressHost);
			self.pollFn = L.bind(self.pollLog, self);
			poll.add(self.pollFn, 2);
			poll.start();
		}

		return E('div', { class: 'cbi-map' }, [
			E('h2', '固件升级'),
			E('p', { class: 'cbi-map-descr' },
				'检查 GitHub 仓库是否有新版本固件，并在线刷入。升级前请确认路由器供电稳定；整个过程约 3-5 分钟。（升级工具 v4 · 2026-09-21）'),
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
