# 极路由 4 增强版 (HiWiFi HC5962) · ImmortalWrt 云编译配置

**编译的源码：`https://github.com/immortalwrt/immortalwrt` 分支 `openwrt-25.12`**  
**本仓库不引用 P3TERX/Actions-OpenWrt，也不需要**

> **本仓库有两条分支**：`openwrt-25.12` = 当前主线（季度自动编译跑在这里）｜
> `main` = 对应 openwrt-23.05，**已冻结**，仅作退路保留，需要时手动触发即可编出旧版。

> **没用过 GitHub？先看这份：** [操作手册-手把手.md](操作手册-手把手.md)  
> 从注册账号到拿到固件，每一步点哪个按钮、填什么都写清楚了，不需要任何基础。  
> 下面这份 README 是技术细节说明（为什么这么配、各参数什么意思）。
>
> **出问题了先看这份：** [bug分析.md](bug分析.md)  
> 汇总了本机踩过的全部坑：DNS 自举死锁、国外 DNS 隧道不通、Xray 内存暴涨崩溃、
> ssr+ 定时任务竞态等，每条都给了现象、根因、证据和当前状态，方便按图索骥。



---

## 零、先厘清一件事：源码 vs 流水线

这两个仓库经常被混为一谈，上次固件编译失败的根源就在这里。

| 仓库                        | 角色      | 说明                                         |
| ------------------------- | ------- | ------------------------------------------ |
| `immortalwrt/immortalwrt` | **源码**  | 被编译的原材料，本次唯一指定的源码                          |
| `P3TERX/Actions-OpenWrt`  | **流水线** | 一段 GitHub Actions 脚本，负责在云端 Linux 上敲 `make` |

P3TERX 那个仓库里没有任何源码，只有一个 workflow 文件和几个空壳。它的价值仅仅是「省得自己写 workflow」。

**但不能用它**，因为它的默认值是：

```yaml
REPO_URL: https://github.com/coolsnowwolf/lede   # ← 不是 ImmortalWrt！
REPO_BRANCH: master
```

用 "Use this template" 建出来的仓库会预置这两行，编译出来的其实是 **Lean 的 LEDE**——这正是上次源码选错的原因。

本工程的 workflow 是自己写的，clone 的是官方源码：

```yaml
env:
  REPO_URL: https://github.com/immortalwrt/immortalwrt
  REPO_BRANCH: openwrt-25.12
...
run: git clone $REPO_URL -b $REPO_BRANCH openwrt
```

所以只要新建一个**空白仓库**就够了，不需要引用任何第三方模板。

---

## 一、几个必须知道的前提

### 1. 32MB 只卡 factory，不卡 sysupgrade（这点很多人搞错）

先看 ImmortalWrt 对 HC5962 的定义（`target/linux/ramips/image/mt7621.mk`）：

```makefile
define Device/hiwifi_hc5962
  $(Device/nand)
  $(Device/uimage-lzma-loader)
  IMAGE_SIZE := 32768k
  IMAGES += factory.bin
  IMAGE/factory.bin := append-kernel | pad-to $(KERNEL_SIZE) | append-ubi | check-size
  DEVICE_VENDOR := HiWiFi
  DEVICE_MODEL := HC5962
  DEVICE_PACKAGES := kmod-mt7603 kmod-mt76x2 kmod-usb3 -uboot-envtools
endef
```

`IMAGE_SIZE := 32768k` 看着像硬上限，但**它只作用于带 `check-size` 的那个 recipe**。  
HC5962 的 `IMAGE/sysupgrade.bin` 不是自己定义的，继承自同文件里的 `Device/nand`：

```makefile
define Device/nand
  BLOCKSIZE := 128k
  KERNEL_SIZE := 4096k
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata      # ← 没有 check-size
endef
```

所以真实情况是：

| 产物               | recipe 含 check-size | 编译期体积校验 | 结论               |
| ---------------- | ------------------- | ------- | ---------------- |
| `factory.bin`    | ✅ 有                 | 有       | **超 32MB 会编译失败** |
| `sysupgrade.bin` | ❌ 无                 | 无       | 不受 32MB 约束       |

那 sysupgrade 的真实上限是多少？看 DTS（`mt7621_hiwifi_hc5962.dts`）：

```
u-boot      0x0        512KB
debug       0x80000    512KB
factory     0x100000   256KB   (MAC/无线校准，只读)
kernel      0x140000   4MB
ubiconcat0  0x540000   28.5MB  ┐
bdinfo      0x21c0000  512KB   │ mtd-concat 拼成 "ubi"
ubiconcat1  0x2240000  93.25MB ┘
```

`ubiconcat0 + ubiconcat1` 经 `mtd-concat` 拼成一个约 **121.75MB** 的 `ubi` 分区。  
40MB 量级的 sysupgrade 塞进去绰绰有余。

**这正是「分两次编译」方案的立论基础：**

- `minimal` 档位 → 出 `factory.bin`（必须 ≤32MB），给 Breed 首刷
- `full` 档位 → 只出 `sysupgrade.bin`（可超 32MB），系统内升级，装全协议 ssr+

`diy-part2.sh` 会在 full 档位自动把 `IMAGES += factory.bin` 从 HC5962 段落里摘掉，  
避免它因 check-size 报错把整轮编译拖挂。

### 2. 为什么是 openwrt-25.12（23.05 已 EOL）

| 维度           | 25.12（当前主线）                                    | 23.05（`main` 分支，已冻结）                    |
| ------------ | ---------------------------------------------- | --------------------------------------- |
| 官方支持状态       | **当前唯一受支持的版本**                                 | **2025-08-16 已 EOL** —— 官方明确说连严重安全漏洞都不再修 |
| ImmortalWrt 该分支 | 活跃（master / 24.10 / 25.12 均在更新）                 | 主源码停 2026-02-27、packages 停 2026-02-06       |
| 内核           | 6.12                                           | 5.15                                    |
| 包管理          | **apk**（取代 opkg）                               | opkg                                    |
| 防火墙后端        | firewall4 + nftables                           | firewall4 + nftables（实测）                |
| HC5962 设备定义  | 与 23.05 **逐字未改**：`IMAGE_SIZE 32768k`、factory 配方、`DEVICE_PACKAGES` 全一致 | 同左                                      |

**为什么 23.05 上的「季度自动编译」没意义**：源码和 packages 双双停更，编出来的东西与上一份逐字节相同（只差版本时间戳），且拿不到任何安全补丁 —— 那是「重建」，不是「升级」。所以季度编译已迁到 `openwrt-25.12` 分支。

> 注：早期这份配置想"显式切回 firewall3"，实测被 defconfig 静默推翻
> （`CONFIG_PACKAGE_firewall=y` 被降级成 `=m`，fw4 照装），所以固件里实际
> 就是 firewall4。自定义 NAT 规则走 uci（lan zone masq），不写任何 nft 文件。
> 25.12 同样是 firewall4 + nftables，这套写法原样可用。

**迁移代价（动手前必须知道）**

- **跨版本必须全新刷机，不能保留配置**。两条分支的 `DEVICE_COMPAT_VERSION` 都是 `1.0`，
  sysupgrade **不会拒绝**跨版本，会**静默保留配置** —— 那才是真正的危险点。
- 首次刷 25.12：SSH 走 `fw-upgrade -y -n`（`-n` = 不保留配置），或在 LuCI 原生升级页
  **取消勾选**「保留配置」。
- 另需重做两件 —— **均已于 2026-09-25 完成**（详见文末变更记录）：
  - `configs/config-full.config`：库包去 ABI 数字后缀（`libstdcpp6`→`libstdcpp`、
    `libatomic1`→`libatomic`、`libnatpmp1`→`libnatpmp`）；**透明代理后端在 25.12 上
    只能选 Nftables** —— dev 版给 Iptables 选项加了 `depends on !PACKAGE_firewall4`，
    而 25.12 默认就装 firewall4，写了会被 defconfig 静默丢弃；机制由
    iptables+ipset 变为 nftables+nftset。
  - `files/etc/AdGuardHome.yaml`：升到 **schema 34 / AGH 0.107.78**。旧文件（schema 28）
    在 0.107.78 上会连做 6 次迁移并改写文件 —— 那正是 9/18 事故的触发路径。
    已用官方 0.107.78 本体验证：`--check-config` exit=0 **且校验后 md5 不变**。

### 3. 插件来源核对结果

| 插件           | 来源                                     | 说明                                                                                                   |
| ------------ | -------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| SMB          | `luci-app-ksmbd`                       | ImmortalWrt 官方 luci feed。ksmbd 是内核态 SMB3，约 300KB；samba4 约 8-10MB，为控体积选 ksmbd                         |
| U盘自动挂载       | `automount`                            | ImmortalWrt 官方 `package/emortal/automount`，热插拔自动挂载并写 fstab                                           |
| ssr+         | `luci-app-ssr-plus`                    | **ImmortalWrt 任何官方源都没有**，用上游 `fw876/helloworld`。feeds 里**刻意不写分支号**（跟随该仓库默认分支 dev）；2026-09-25 更正：此前写死 `;master`，而 master 自 2026-07-11 停更，导致 ssr+ 长期停在 190-3 从未升级                                                      |
| AdGuard Home | `adguardhome` + `luci-app-adguardhome` | 核心在官方 packages 源；**LuCI 界面在 23.05 的官方 luci feed 里没有**（本项目统一用社区版，不依赖官方 feed 是否有）。⚠ 2026-09-25 复查：**25.12 的 luci feed 已经有了官方版** `luci-app-adguardhome`（maintainer George Sapkin，`LUCI_EXTRA_DEPENDS:=adguardhome (>=0.107.73-r3)`），与社区版**同名**。按 OpenWrt 的包扫描顺序（`package/feeds/*` 在 `package/<本地目录>` 之前），**本地 clone 的社区版覆盖官方版**，行为与 23.05 一致、无需改动 —— 这里只是把事实记清楚。社区版 `rufengsuixing/luci-app-adguardhome` 仓库是 package 目录布局（Makefile 在根目录），**不能当 feed 用**（feed 扫描只认子目录，会被静默忽略），由 `diy-part1.sh` 直接 clone 进 `package/` |
| ZeroTier     | `zerotier` + `luci-app-zerotier`       | **纯官方 packages / luci 源，不需要任何第三方源**。本体约 500KB，依赖 `kmod-tun`（TUN/TAP 虚拟网卡）                            |
| vlmcsd (KMS) | `vlmcsd` + `luci-app-vlmcsd`           | **纯官方 packages / luci 源**。本体仅 23KB，用于局域网内 Windows / Office 的 KMS 激活                                  |
| Wake-on-LAN | `luci-app-wol` + `etherwake`           | **纯官方 luci / packages 源**（2026-09-15 烘焙；实机此前已 opkg 手动装过同两款，烘焙后 sysupgrade 升级不再丢失）。etherwake 发魔术包唤醒局域网内支持 WoL 的设备，本体约 10KB，无后台服务 |
| mosdns       | `mosdns`                              | **纯官方 packages 源**（`net/mosdns`，v5.3.3，Go 程序）。AGH 的下游分流器。注意 v5.3.3 不支持 geosite.dat 二进制，国内域名名单改用纯文本列表 `files/etc/mosdns/cn.txt` 走 `domain_set` 加载，见「十二·五」章 |

### 5. 插件的默认运行状态

full 档位里的功能组件分两类：**DNS 链（AGH + mosdns）默认运行**，**其余（ssr+ / ZeroTier / KMS）默认不运行**。这样 DNS 广告过滤 + 分流一刷机就生效，而代理、组网、KMS 这类需要你手动配置的服务保持关闭、不抢资源。

| 组件 | 前端入口 | 默认状态 | 说明 |
|---|---|---|---|
| AdGuard Home | 服务 → AdGuard Home | **运行** | 烘焙配置（`/etc/AdGuardHome.yaml`，大写）+ 首启置 `AdGuardHome.AdGuardHome.enabled=1`，刷机即起，监听 5335，首次进 `:3000` 界面设账号密码即可 |
| mosdns | **无 web 前端**（后台组件） | **运行** | 官方包 init 无开关，编译时统一 enable，随 `files/etc/mosdns/config.yaml` 起在 5353 |
| ssr+ | 服务 → ShadowSocksR Plus+ | 未启动 | 装好即带，但节点、模式都要你配置后才真正生效（DNS 模式默认 0 = 本机 5335） |
| ZeroTier | VPN → ZeroTier | 未启用 | uci `zerotier.global.enabled=0`，填 Network ID 并勾启用才连 |
| vlmcsd (KMS) | 服务 → vlmcsd | 未启用 | uci `vlmcsd.config.enabled=0`，勾启用才监听 1688 |
| Wake-on-LAN | 网络 → Wake-on-LAN | **无服务进程**（随用随点） | etherwake 按需发魔术包，没有常驻进程，无需开关；在界面填目标网卡 MAC 点「唤醒」即可 |

> **默认运行怎么实现的**：AGH 走 `files/etc/uci-defaults/99-dns-setup` 首启脚本
> 把 `AdGuardHome.AdGuardHome.enabled` 置 1（官方包 init 本来默认 0；注意 uci
> 段名和 init 脚本名都是**大写 AdGuardHome**，小写版它们不读）；mosdns 官方包 init
> 没有开关，固件编译时所有 `/etc/init.d/*` 会被统一 enable，所以刷机即起、读烘焙好的
> config.yaml。dnsmasq 也由同一脚本改成转发 `127.0.0.1#5335`（并 noresolv），整条
> `dnsmasq:53 → AGH:5335 → mosdns:5353` 链首启自动就位，无需手动做任何事。
>
> 其余三个「不默认运行」是**官方包自带默认值就是 `enabled='0'`**（zerotier 读
> `zerotier.global.enabled`、vlmcsd 读 `vlmcsd.config.enabled`），无需额外脚本去关。

### 4. 为什么选 ImmortalWrt 而不是 Lean 的 LEDE

结论：**推荐 ImmortalWrt**。下面是实打实的对比，你可以自己判断。

| 维度    | ImmortalWrt                         | coolsnowwolf/lede            |
| ----- | ----------------------------------- | ---------------------------- |
| 上游跟进  | 紧跟 OpenWrt，23.05 / 24.10 / 25.12 齐全 | 长期基于 18.06 深度魔改，内核与工具链偏旧     |
| 代码规范  | 团队维护，有 PR 审核流程                      | 个人项目，改动随性，部分补丁不合上游规范         |
| 插件完整度 | 官方源干净，ssr+ / ADG 需外挂源               | **ssr+、passwall 等直接内置**，开箱即用 |
| 编译容错率 | 要自己配 feeds，容易踩坑                     | 一条龙，一次成功的概率更高                |
| 长期维护  | 活跃，出新版本能跟着升                         | 迭代慢，将来想升内核会卡住                |
| 行为可预期 | 贴近上游，出问题好排查                         | 内置大量非上游补丁，行为可能偏离预期           |

**推荐 ImmortalWrt 的理由：**

1. **上次踩的坑不是 LEDE 不行，而是被模板偷偷换成了 LEDE 而你不知情**——这是知情权问题，不是 LEDE 本身有问题。现在源码显式写在 workflow 里，这个坑已经不存在了。
2. **ssr+ 用的是上游 `fw876/helloworld`，比 LEDE 内置的版本更新**。你要"协议尽量全"，走上游源反而更有优势。
3. **未来升级成本**。路由器刷好后通常长期不动，一两年后想升级时，ImmortalWrt 有活跃上游兜着；LEDE 大概率还停在那套老工具链上。
4. 25.12 的内核是 6.12（23.05 是 5.15），比 LEDE 的 5.4/5.10 新，MT7621 的无线驱动（mt76）也更完善。

**什么情况该选 LEDE：** 如果第一诉求是"少折腾、一次编译就成"，且不在意内核新旧，LEDE 的容错率确实更高。要换我就给你配，说一声就行。

---

## 二、文件清单

```
.github/workflows/openwrt-builder.yml   # 构建流程，档位可选 minimal / full / both；含季度定时
.github/workflows/keepalive.yml          # 每月自动提交一次，防止定时任务被 60 天规则禁用
feeds.conf.default                      # 4 个官方源 + helloworld（AGH 界面不走 feed，见 diy-part1.sh）
configs/config-minimal.config           # 档位 A：精简版 ~11MB，Breed 首刷（出 factory+sysupgrade）
configs/config-full.config               # 档位 B：完整版 factory 31.5MB / sysupgrade 28.5MB（首编实测）
diy-part1.sh                            # feeds 兜底校验
diy-part2.sh                            # 默认 IP 兜底 + 权限修复 + full 档位摘除 factory.bin
files/etc/uci-defaults/zz-hc5962-custom # IP/网关/DNS/关 DHCP/lan zone masq/LuCI 检查更新按钮
files/etc/uci-defaults/99-dns-setup    # 首启固化 DNS 链：dnsmasq 转发 5335 + 启用 AGH（见第五、七、十二·五章）
files/etc/AdGuardHome.yaml             # AGH 烘焙配置（端口 5335、上游 127.0.0.1:5353、1MB 缓存、schema 34 / AGH 0.107.78）
files/etc/mosdns/config.yaml           # mosdns v5.3.3 分流配置（监听 5353，国内外分流，见十二·五章）
files/etc/mosdns/cn.txt                # 国内域名名单（约 11 万条，dnsmasq-china-list 转换）
files/etc/config/ksmbd                  # ksmbd 共享配置（U 盘挂到 /mnt/sda1 即自动访客可读写共享；同时绑 LAN+ZeroTier）
files/etc/hotplug.d/net/60-ksmbd-zerotier  # ZT 网卡出现时重启 ksmbd（补绑 zt 接口，解决开机时序）
files/etc/hc5962-upgrade.conf           # 升级仓库配置（分享固件给别人时改 REPO 一行）
files/etc/health_sample.sh              # 健康采样 v1.06：每 5 分钟记负载/内存明细/CPU细分(iowait)/D状态进程数/Xray占用/DoH连接数/网桥速率，双写 /tmp（内存盘）+ /root（闪存，重启不丢）；异常时另存详细现场到 /root/health-alert.log；Xray 单进程 >50MB 且可用内存 <30MB 才自动重启（双条件，30 分钟冷却，进程名自动发现+排除名单）；可用内存连续 3 次 <25MB 时写 `!! LOWMEM` 专项取证（只取证不动作）
files/usr/bin/fw-check-update           # 路由器端：检查 GitHub 有无新固件（支持 --json，网页用）
files/usr/bin/fw-upgrade                # 路由器端：下载→校验→试刷→确认→刷入（支持 -y，网页用）
package/luci-app-hc5962-upgrade/        # 网页固件升级页（LuCI → 系统 → 固件升级，仅 full 档位）
```

**网络定制**（由 `zz-hc5962-custom` 在首次启动时写入）：

- LAN IP `192.168.112.200` / 掩码 `255.255.255.0`
- 网关 `192.168.112.1`
- DNS `127.0.0.1`（路由器本机走自己的 DNS 链。2026-09-06 曾写 114.114.114.114，会把 99-dns-setup 置的 127.0.0.1 覆盖掉、且直连 114 会被污染，已修正）
- `dhcp.lan.ignore=1` → 关闭 IPv4 DHCP
- `ra=disabled` `dhcpv6=disabled` `ndp=disabled` + 停用 odhcpd → 关闭 IPv6
- lan zone `masq='1'` → fw4 自动生成 fullcone srcnat，旁路由回程 NAT 直接生效（见第十一章）

---

## 三、部署到 GitHub

### 方式一：新建空白仓库（推荐）

1. GitHub 右上角 `+` → **New repository**
2. 仓库名 **`hiwifi-ImmortalWrt`**；可见性选 **Public**
   > 为什么必须 Public：① 路由器端的升级脚本要从 GitHub 匿名下载固件，私有仓库的 Release
   > 需要 token 才能下，而 token 有效期最长一年，到期后升级脚本会静默失效；
   > ② 定时任务的「60 天无活动自动禁用」规则只作用于公开仓库，配套 keepalive 已处理。
   > 代价是配置里 `192.168.112.200` 这个内网地址会公开可见——它是 RFC1918 私有地址，
   > 互联网上无法直接访问，实际风险只是暴露内网拓扑，可接受。
3. **什么都不要勾** —— 不要 Add README、不要 .gitignore、不要 license，保持完全空白
4. 创建后，进仓库页面，点 **uploading an existing files**
5. 把本目录**所有内容**拖进上传框（GitHub 支持直接拖文件夹，`.github` 隐藏目录也能拖进去）
6. 提交到 `main` 分支

需要传的文件一共 15 个：

```
.github/workflows/openwrt-builder.yml
.github/workflows/keepalive.yml
configs/config-minimal.config
configs/config-full.config
feeds.conf.default
diy-part1.sh
diy-part2.sh
files/etc/uci-defaults/zz-hc5962-custom
files/etc/hc5962-upgrade.conf
files/usr/bin/fw-check-update
files/usr/bin/fw-upgrade
package/luci-app-hc5962-upgrade/Makefile
package/luci-app-hc5962-upgrade/root/usr/share/luci/menu.d/luci-app-hc5962-upgrade.json
package/luci-app-hc5962-upgrade/root/usr/share/rpcd/acl.d/luci-app-hc5962-upgrade.json
package/luci-app-hc5962-upgrade/htdocs/luci-static/resources/view/hc5962-upgrade/upgrade.js
README.md
```

### 方式二：本地 git 推（更稳，Windows 下尤其推荐）

网页拖拽有时不认 `.github` 这类隐藏目录，用命令行最保险：

```bash
cd "immortalwrt-hc5962-build"

git init
git add -A
git commit -m "ImmortalWrt 25.12 HC5962 build config"
git branch -M main
git remote add origin https://github.com/<你的用户名>/<仓库名>.git
git push -u origin main
```

> 首次使用需先设置身份：`git config --global user.name "xxx"` 和 `git config --global user.email "xxx@xxx"`

### 如果用上次那个仓库 / 之前用过 P3TERX 模板

必须先清理干净，否则会按旧配置编译：

1. **删掉 `.github/workflows/` 下的所有旧 yml** —— 里面的 `REPO_URL` 写死的是 `coolsnowwolf/lede`
2. 删掉根目录的旧 `diy-part1.sh`、`diy-part2.sh`、`.config`、`feeds.conf.default`
3. 再按上面方式上传本套文件

### ⚠️ 必须做：给 Actions 开写权限

2023 年之后 GitHub 新建仓库的 `GITHUB_TOKEN` 默认是**只读**，会导致固件上传 Release 失败（但 Artifacts 不受影响，固件照样能下载）。

如果希望 Release 也能用：**Settings → Actions → General → Workflow permissions → 勾选 Read and write permissions → Save**

### ⚠️ 另一个坑：网页上传的文件没有可执行权限

GitHub 网页上传的文件一律是 `644`，不可执行。uci-defaults 脚本不可执行 = 首次启动时不会被调用 = **IP、网关、关 DHCP、防火墙规则全部失效**。

`diy-part2.sh` 里已经写了 `chmod +x files/etc/uci-defaults/*` 来兜底。用方式二（git 推）的话权限会自动带上，双保险。

---

## 四、触发编译

三种触发方式：

1. **手动**：点顶部 **Actions** → 左侧选 **ImmortalWrt HC5962 Builder** → 右侧 **Run workflow** → 档位选 **`both`**（一次跑出 minimal 和 full 两个版本）
2. **季度定时**：每年 1/4/7/10 月 1 号北京时间 03:37 自动编 full（固定只编 full，理由见下节）
3. 外部触发（repository_dispatch，预留未用）

手动触发时等待约 20-40 分钟（两个 job 并行）。

产物在各自 job 的 **Artifacts**：

```
OpenWrt_firmware_minimal_hiwifi_hc5962_<时间戳>
  ├── *factory.bin       ← 第 1 步：Breed 首刷用这个（≤32MB）
  └── *sysupgrade.bin

OpenWrt_firmware_full_hiwifi_hc5962_<时间戳>
  └── *sysupgrade.bin    ← 第 2 步：系统内升级用这个（~40MB，无 factory）
```

full 档位不产出 factory.bin，是 `diy-part2.sh` 主动摘掉的——它的 recipe 带 check-size，  
超 32MB 会让整轮编译失败，而这个档位根本用不到 factory。

编译日志末尾会打印每个 bin 的体积，并按各自限额告警（factory 32MB / sysupgrade 118MB）。

---

## 五、刷机流程（Breed）

### 第 1 步：Breed 刷入 minimal 版

1. 路由器断电 → 按住 **Reset** → 通电 → 等 5-10 秒松开
2. 电脑网口接路由器 **LAN 口**，手动设 IP `192.168.1.2/24`
3. 浏览器访问 `192.168.1.1` 进入 Breed
4. 选 **固件更新** → 勾选 **固件**（不用勾 Bootloader / 配置）→ 选 minimal 版的 **`*factory.bin`**
5. 上传 → 刷入 → 自动重启（约 2 分钟）

### 第 2 步：升级到 full 版

1. 电脑改回自动获取 IP（或设 `192.168.112.x/24`）
2. 浏览器访问 **<http://192.168.112.200>** （用户名 `root`，密码 `password`）
3. **系统 → 备份/升级 → 刷写新的固件**
4. 上传 full 版的 **`*sysupgrade.bin`**
5. **不要勾选「保留配置」**（勾了的话 uci-defaults 不会重跑，虽然网络配置会保留，但保险起见不勾）
6. 刷完自动重启，插件已就位

---

## 六、U 盘自动挂载

插入 U 盘后约 2 秒自动挂载，SSH 登录验证：

```sh
ls /mnt/          # 应看到 sda1 或类似目录
block info        # 查看分区与文件系统
df -h             # 查看挂载点
```

`automount` 已内置，无需手动配置。SMB 共享也已烘焙（`files/etc/config/ksmbd`）：
U 盘挂到 `/mnt/sda1` 后即以访客可读写方式自动共享，无需进界面配置；
换盘后设备名若不是 sda1，到 **网络共享** 菜单改一下路径即可。

samba 同时监听 LAN 和 ZeroTier 虚拟网卡（`option interface 'lan zerotier'`），
外网 ZT 设备可直接访问 `\\192.168.196.x`（路由器的 ZT IP）读写共享。
两点说明：

- ksmbd 开机启动早于 zerotier 入网，靠 `files/etc/hotplug.d/net/60-ksmbd-zerotier`
  在 ZT 网卡出现时自动重启 ksmbd 补绑，无需人工干预
- ZT 网卡名（`ztuze4o5om`）由网络 ID 派生（当前 ID `9f77fc393e3b4cf2`）。
  若换了网络 ID，需同步改 `files/etc/uci-defaults/zz-hc5962-custom` 第 8 节
  和 ksmbd 配置里的 device 名

> 若 U 盘是 NTFS 且需要写入，固件已内置 `kmod-fs-ntfs3`（内核态 NTFS 读写）。  
> 极少数老 U 盘不识别，多半是 `kmod-usb-storage-uas` 的 UASP 兼容问题，拔插重试即可。

---

## 七、AdGuard Home 与 dnsmasq 的端口冲突

固件里 dnsmasq 已占用 53 端口，AdGuard Home 默认也要 53，二者会打架。

> **full 档位全新刷机无需手动做**：`files/etc/AdGuardHome.yaml` 已把 AGH 端口烘焙为
> `5335`，`files/etc/uci-defaults/99-dns-setup` 首启自动把 dnsmasq 上游指向
> `127.0.0.1#5335` 并 noresolv。下面这套手动步骤只作「理解原理 / 在旧固件上手动搭」的参考。

**手动场景（参考）—— AdGuard Home 网页界面 → 设置 → DNS 设置**

- 端口改为 `5335`

**或 SSH 执行：**

```sh
uci set adguardhome.@AdGuardHome[0].port='5335'
uci commit adguardhome

# dnsmasq 上游指向 AdGuard Home
uci set dhcp.@dnsmasq[0].port='53'
uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#5335'
uci set dhcp.@dnsmasq[0].noresolv='1'
uci commit dhcp

/etc/init.d/adguardhome restart
/etc/init.d/dnsmasq restart
```

这样 dnsmasq 只做本地解析转发，AdGuard Home 负责真正的过滤。

> 注：full 档位里 dnsmasq 已被替换成 **dnsmasq-full（ipset 版）**，这是 ssr+ 透明代理必需的，  
> 不要改回精简版 dnsmasq，否则 ssr+ 的国内/国外分流会失效。

---

## 八、ssr+ 协议矩阵（mipsel 实测可用性）

MT7621 是 **mipsel** 架构，不少 Go/Rust 写的现代协议跑不了。逐个核对 `fw876/helloworld` 的 Makefile 后定稿。

**配置原则是稳妥优先**：默认只开主力协议（跟 LEDE 内置 ssr+ 的常规水平相当），  
冷门的一律关掉——多一个组件就多一处出错的可能，用不上就是纯粹的负担。

### 默认启用

| 选项                                  | 组件包                                         | 覆盖                                                                          |
| ----------------------------------- | ------------------------------------------- | --------------------------------------------------------------------------- |
| `INCLUDE_Xray`                      | `xray-core`                                 | VLESS / VMess / Trojan / Shadowsocks / Reality，含 XTLS、gRPC、WebSocket、HTTP/2 |
| `INCLUDE_Shadowsocks_Libev_Client`  | `shadowsocks-libev-ss-local` `-ss-redir`    | Shadowsocks                                                                 |
| `INCLUDE_ShadowsocksR_Libev_Client` | `shadowsocksr-libev-ssr-local` `-ssr-redir` | ShadowsocksR（Makefile 里默认就是 y）                                              |
| `INCLUDE_ChinaDNS_NG`               | `chinadns-ng`                               | 国内外域名分流，ssr+ 的看家功能                                                          |
| `INCLUDE_DNS2SOCKS`                 | `dns2socks`                                 | Makefile 默认 y，体积极小                                                          |
| `INCLUDE_IPT2Socks`                 | `ipt2socks`                                 | Xray 透明代理链路要用到                                                              |

透明代理后端用 `Iptables_Transparent_Proxy`（ssr+ 的 ipset 分流方案，与防火墙后端
是 firewall4 不冲突——它走 iptables 命令行 + ipset，fw4 管的是 nftables 那套规则表），  
它会自动 select `dnsmasq-full(ipset)` + `ipset` + 若干 `iptables-mod-*`。

### 按需开启（默认全关）

| 选项                                 | 组件包                  | 什么时候才需要                                              |
| ---------------------------------- | -------------------- | ---------------------------------------------------- |
| `INCLUDE_Trojan`                   | `trojan`             | Xray 已原生支持 Trojan，只有遇到「Xray 连不上但 trojan 客户端能连」的老节点才开 |
| `INCLUDE_Shadowsocks_Simple_Obfs`  | `simple-obfs-client` | 老式 obfs 混淆，现已被 WebSocket+TLS 取代，仅老 SS 节点             |
| `INCLUDE_Shadowsocks_V2ray_Plugin` | `v2ray-plugin`       | Xray 已原生支持 WebSocket，仅老版 SS 节点                       |
| `INCLUDE_Hysteria`                 | `hysteria`           | Go 写的，mipsel 上约 3MB 且兼容风险最高。除非机场明确提供 Hysteria2 节点    |
| `INCLUDE_Redsocks2`                | `redsocks2`          | 全局 TCP 转发，特殊场景才用                                     |
| `INCLUDE_DNSPROXY`                 | `dnsproxy`           | 与 ChinaDNS-NG 功能重叠，二选一                               |

要开的话，在 `config-full.config` 里把对应行取消注释，**同时把下面依赖包区的同名包也打开**（两处都在文件里，已用注释标好）。一次只开一个，出问题好定位。

### 开不了，别动

| 选项                    | 原因                                                    |
| --------------------- | ----------------------------------------------------- |
| `INCLUDE_Tuic_Client` | `depends on aarch64\|\|arm\|\|i386\|\|x86_64`         |
| `INCLUDE_Shadow_TLS`  | `depends on aarch64\|\|arm\|\|x86_64`                 |
| `INCLUDE_NaiveProxy`  | `depends on !(arc\|\|armeb\|\|mips\|\|mips64\|\|...)` |
| `INCLUDE_Kcptun`      | 依赖 `kcptun-client`，但 helloworld 源里**根本没有这个包**，开了必挂    |
| `INCLUDE_MosDNS`      | 这是 ssr+ **捆绑**的 MosDNS（会 bind 5335 与 AGH 抢端口），不开；分流用独立包 `mosdns`（见十二·五章），两者是不同东西     |

### ssr+ 运维须知（2026-09-11 故障后固化）

- **自动切换已关**（`enable_switch=0`，2026-09-15 确认）：ssr-switch 判定备用节点可用只验
  TCP 端口可达、不验真实翻墙可用性，2026-09-11 曾自动切到"端口通、实际不通"的
  SG烈焰节点致全网断 8 分钟。关掉后主节点故障需手动切。
- **前端显示 ≠ 实际节点**：ssr-switch 切节点只重启服务、**不写回 UCI**，LuCI 下拉框
  永远显示默认节点。查真实在跑的节点看 `/var/log/ssrplus.log` 里的 `Switch to` 行。
- **翻墙断的 1 分钟判据**：先看 `ssrplus.log` 有无 switch 记录（有 = 节点/切换问题），
  再对照 `health-flash.log` 的 `net=` 流量（流量高 + 失败 = 拥塞；流量低 + 失败 = 节点问题）。
- **每天 02:00 订阅更新会重启 ssr+**，隧道中断数十秒，属固有行为；翻墙瞬断先想到这个。
- 缓解项：AGH 已开**乐观缓存**（缓存中已有的域名过期也先应答），隧道被挤兑时
  已知域名照常解析；新域名仍会失败，根治需给国外 DoH 独立出口（未实施）。

---

## 九、体积控制：只有 factory 需要操心

| 档位      | 产物               | 编译期限额               | 首编实测（2026.08.31）  |
| ------- | ---------------- | ------------------- | ------------------- |
| minimal | `factory.bin`    | 32MB（check-size 会拦） | **14.88MB** ✅       |
| minimal | `sysupgrade.bin` | 无                   | 12.34MB             |
| full    | `factory.bin`    | 32MB（check-size 会拦） | **31.50MB** ✅ 临界但过 |
| full    | `sysupgrade.bin` | 无（物理上限 121MB）       | 28.54MB ✅           |

**minimal 和 full 的 factory.bin 都要盯着 32MB 限额。** full 首编 31.50MB，离上限只剩
0.5MB 余量——将来往 full 档位加插件要留意，超了编译会直接在 check-size 挂掉。

> mosdns 是 Go 程序，编译进 squashfs 约增 4-5MB，会让 full 的 factory.bin 逼近甚至
> 超过 32MB 限额。**不过 full 档位不产出 factory.bin**（`diy-part2.sh` 已主动摘掉），
> 只出 sysupgrade.bin（物理上限 121MB，很宽松），所以加 mosdns 对 full 无影响。
> 受影响的是 **minimal**——它出 factory.bin，如果将来想往 minimal 也塞 mosdns 才需警惕。

万一 factory 超了，按这个顺序砍：

1. 注释掉 `config-minimal.config` 里的 `luci-theme-argon` + `luci-app-argon-config`（省 ~1.5MB）
2. 注释掉 `htop`、`fdisk`、`badblocks`（省 ~1MB）
3. 去掉 `kmod-fs-ntfs3`（省 ~0.3MB，代价：不能读写 NTFS 格式 U 盘）

full 的 sysupgrade 对 121MB 的 ubi 分区很宽松，不用管。

> 表中数值已是首次编译（tag：`full-2026.08.31-1913` / `minimal-2026.08.31-1912`）
> 的 Release 实测值。注：该次编译缺 `luci-app-adguardhome`（feed 根目录 Makefile 不被
> 识别的坑，已修复），补上后 full 体积会再增约 1-2MB，仍在 32MB 内。

---

## 十、无线与有线驱动：开源还是闭源

**结论：本固件用的是开源 mt76 驱动。ImmortalWrt 官方源码里没有闭源驱动。**

### 无线：开源 mt76

HC5962 在 `mt7621.mk` 里的默认包：

```
DEVICE_PACKAGES := kmod-mt7603 kmod-mt76x2 kmod-usb3
```

- `kmod-mt7603` → 2.4G（MT7603EN）
- `kmod-mt76x2` → 5G（MT7612EN / MT7662EN）

两者都出自 `package/kernel/mt76`，源码地址 `https://github.com/openwrt/mt76`——  
社区维护的开源驱动，不是 MediaTek 的闭源 blob。

DTS 里也能印证，两个 PCIe 无线节点写的都是 `mt76`：

```dts
&pcie0 {
	mt76@0,0 {
		mediatek,mtd-eeprom = <&factory 0x0000>;   /* 2.4G 校准数据 */
		ieee80211-freq-limit = <2400000 2500000>;
	};
};
&pcie1 {
	mt76@0,0 {
		mediatek,mtd-eeprom = <&factory 0x8000>;   /* 5G 校准数据 */
		ieee80211-freq-limit = <5000000 6000000>;
	};
};
```

**那闭源驱动是什么？** MediaTek 官方的 `mt_wifi`（闭源内核模块 + 用户态配置工具），  
主要用在 Padavan、老毛子这类固件上。它性能更强（WED 硬件加速、256-QAM、  
完整 MU-MIMO），但它是跟内核版本强绑定的二进制 blob，ImmortalWrt / OpenWrt 官方  
既不收录也拿不到。

### 开源 vs 闭源的实际差距

|                        | 开源 mt76（本固件）                             | 闭源 mt_wifi    |
| ---------------------- | ---------------------------------------- | ------------- |
| 获取方式                   | ImmortalWrt 源码自带                         | 仅第三方固件提供      |
| 无线吞吐                   | 中等，纯软件转发                                 | 更强，有 WED 硬件加速 |
| MT7603 / MT76x2 支持 WED | **不支持**（mt76 里只有 mt7915e 有 `wed_enable`） | 支持            |
| 跟随内核升级                 | 可以                                       | 内核一换就失效       |
| 稳定性                    | 好，社区持续在修                                 | 强，但停在特定内核版本   |

### 有线 NAT 加速

顺带说明：ImmortalWrt 的 ramips target（23.05 实测，25.12 未复核）**没有内置 mtk_hnat 驱动**  
（查过 `target/linux/ramips/files/drivers/...` 该目录不存在，  
`mt7621/config-5.15` 里也只有 `CONFIG_NET_MEDIATEK_SOC=y`）。

所以**硬件 NAT 加速用不上**，但软件 Flow Offloading 是有的。  
LuCI 的「网络 → 防火墙 → 常规设置」里那两个开关：  
「Flow offloading」（软件）有效；「Hardware flow offloading」勾了也不生效。

> 旁路由场景下流量主要走 LAN↔LAN，本来就不太过 NAT，这个缺失对你影响很小。  
> 真要榨干性能，那得换 Padavan/老毛子那类带闭源驱动的固件。

内核版本：**5.15.198**

---

## 十一、防火墙规则（fw4 + uci masq 写法）

旁路由回程 NAT 的实现：`zz-hc5962-custom` 首启把 **lan zone 的 `masq` 置 1**，
fw4 自动生成 fullcone srcnat，等效于当年手写的 `oifname "br-lan" masquerade`。

**为什么不用手写 nft 文件**（2026-09-05 实机排障的教训）：曾在
`/etc/nftables.d/` 放过 `table ip nat { chain ... masquerade }`，但 fw4 是把
该目录的 `*.nft` include 进**自己的 `table inet fw4 { ... }` 内部**——table 里再
声明 table = nft 语法错，导致**整个 fw4 ruleset 渲染失败**，防火墙裸奔（无 NAT、
无转发规则，症状就是「网关指向旁路由 = 彻底上不了网」）。`/etc/nftables.d/`
只能写规则片段，NAT 这种需求走 uci 的 zone masq 才是正道。

> fw4 也**不执行 `/etc/firewall.user`**（`fw4_compatible` 默认 false），
> 旧固件里那条 iptables MASQUERADE 实际是失效的——所以本仓库两处都不用。

刷机后 SSH 到 192.168.112.200 验证：

```sh
uci get firewall.@zone[0].masq        # 应输出 1
nft list chain inet fw4 srcnat_lan    # 应看到 fullcone 规则
```

---

## 十二、ZeroTier 与 vlmcsd（full 档位）

这两个都来自 **ImmortalWrt 官方源**，不需要任何第三方 feed。  
这一点对季度自动编译很重要：第三方源随时可能失联或改名，官方源最不容易掉链子。

### ZeroTier

位置：**LuCI → VPN → ZeroTier**

1. 填入 Network ID，勾选「启用」，保存并应用
2. 到 <https://my.zerotier.com> 授权这台设备（新设备默认要手动放行）
3. 状态起来后，SSH 里 `zerotier-cli listnetworks` 能看到分配到的虚拟 IP

`zerotier` 依赖的 `kmod-tun`（TUN/TAP 虚拟网卡）已显式写进 config，不会漏。

一点预期管理：ZeroTier 的加解密在**用户态**完成，用不到内核的硬件加密引擎，  
MT7621 这类老 MIPS 平台上跑不出高吞吐。当**远程管理路由器**的通道很合适，  
拿它当主力数据通道跑大流量不现实。

### vlmcsd

位置：**LuCI → 服务 → vlmcsd**，默认监听 **1688** 端口，开机自启。

Windows 客户端上（管理员命令行）：

```
slmgr /skms 192.168.112.200
slmgr /ato
```

`192.168.112.200` 是本固件的默认 LAN IP，网段改过就换成实际地址。  
路由器是旁路由，客户端只要能 ping 通这个地址就行。

---

## 十二·五、mosdns 分流器（full 档位）

### 它解决什么问题

本固件的 DNS 链是：`dnsmasq:53 → AdGuard Home:5335 → mosdns:5353 → 国内外分流`。

- AGH 负责**广告过滤 + 缓存**（占 5335，dnsmasq 上游指它），查完转给 mosdns
- mosdns 负责**按域名名单分流**：国内域名直连国内 DNS（3 家并行取最快），
  国外域名在 socks5 隧道内用 DoH 查 8.8.8.8 / 1.1.1.1 防污染、失败才直连兜底

为什么需要 mosdns 而不是让 AGH 直接分流：**AGH 的 upstream 不支持 socks5**，
它没法把查询送进梯子；而「国外域名在隧道内解析」必须由会走 socks5 的 mosdns 补位。

### 已烘焙，刷机即用

mosdns 及其配置**已经烘焙进 full 固件**（`CONFIG_PACKAGE_mosdns=y`），全新刷机后
自动运行，**无需任何手动配置**。仓库里就位的文件：

| 文件 | 作用 |
|---|---|
| `files/etc/mosdns/config.yaml` | v5.3.3 plugins-only 原生格式，监听 5353，定义国内/国外两条分流路径（已用官方 v5.3.3 二进制实跑验证通过） |
| `files/etc/mosdns/cn.txt` | 国内域名名单（约 11 万条，源自 felixonmars/dnsmasq-china-list，每行一个域名） |
| `files/etc/AdGuardHome.yaml` | AGH 烘焙配置（schema 34 / AGH 0.107.78）：上游只有一行 `127.0.0.1:5353`（mosdns）、**1MB 缓存**（2026-09-25 由 4MB 降档，上下有 dnsmasq 8000 条 / mosdns 4096 条兜底）、**开乐观缓存**（2026-09-15 起，隧道被挤兑时用过期缓存顶上，缓解国外 DNS 全断） |
| `files/etc/uci-defaults/99-dns-setup` | 首启脚本：dnsmasq 转发 `127.0.0.1#5335` + noresolv、AGH 置 enabled、重启 dnsmasq |

> 为什么不用 geosite.dat：**mosdns v5.3.3 已经移除了 `data_providers`/`servers`
> 顶层键，也不支持 geosite.dat 二进制**（源码里没有 load_dat 插件、没有 v2ray/geosite
> 相关代码）。所以国内名单改用纯文本列表 cn.txt，由 `domain_set` 插件加载——零额外
> 数据包依赖，比 geosite.dat 更可控。

### 分流逻辑（config.yaml 干了什么）

`files/etc/mosdns/config.yaml` 的实际分流：

- **国内域名**（命中 cn.txt）→ `forward_local`：3 家上游并行取最快 ——
  `223.5.5.5`、`119.29.29.29`、`114.114.114.114`（全是 IP 形式的 UDP 直连）
  > 2026-09-06 前这里还挂着阿里 DoH 与 DNSPod DoH 两条，因域名型上游会与本机
  > DNS 链形成自举死锁而删除，详见《故障分析-DNS自举死锁-2026-09-06.md》
- **国外域名**（未命中）→ 先走 `socks5 127.0.0.1:1080` 隧道，用 DoH 查
  `https://8.8.8.8/dns-query` 与 `https://1.1.1.1/dns-query`（防污染）；
  隧道不通时 `fallback` 兜底：`114.114.114.114` 优先、`1.1.1.1` 次选
  （兜底是境外 UDP 直连，结果不可信，只当最后保险，保链路可用）
- **兜底触发阈值** `threshold: 2500`（毫秒），为什么是这个数见下一节
- **缓存**：mosdns 自带一层 cache（`size: 4096`），兜住 AGH 漏掉的查询

> socks5 端口 `1080` 是 helloworld/ssr+ 的默认本地代理口，如你在 ssr+ 里改过就以界面为准。

### 为什么国外上游必须是 DoH（2026-09-07 实测）

上游写 `addr: 8.8.8.8`（不带前缀）= **UDP 查询**，走的是 socks5 的
**UDP ASSOCIATE**：需要机场服务端把 UDP 从隧道里还原出去、再发给 8.8.8.8:53。
实测 susun 机场（trojan+ws 与 trojan+gRPC 两种传输、共 76 个节点）**一律不转发
UDP**，于是每个国外查询都卡满 5 秒超时，最后只能落到兜底、拿 114 的污染结果
（真实表现：网页版 B 站加载海外资源时转圈很久才出来）。

改成 `https://8.8.8.8/dns-query` 后走的是 443 = TCP，用 socks5 的 **CONNECT**，
和浏览器流量完全同路，机场必然转发。实测 20+ 个全新国外域名全部拿到真实 IP，
5 秒超时日志消失。

两个配套要点：

1. **上游只写 IP，不写域名。** `https://dns.google/dns-query` 这类域名型上游
   需要先解析它自己的域名 → 回到本机 DNS 链 → 又是自举死锁。写成 IP 就无需解析，
   所以**不用配 bootstrap**，`bootstrap` / `bootstrap_version` 参数在这里没有用武之地。
2. **`threshold` 必须给到 2500ms**（原来是 500）。DoH 首次查询要建 TCP + TLS，
   走隧道到境外实测约 2 秒（复用长连接后降到 0–1 秒）。500ms 时兜底（114 直连
   30ms 就回）几乎必定抢先，把污染结果当成答案返回，等于主路白干。
   代价：隧道真断了时，每个国外查询要等 2.5 秒才走兜底——仍快于 UDP 时代的 5 秒。

> 换机场后即便新机场支持 UDP 转发，也**不建议改回 UDP 上游**：明文 UDP 查询本来
> 就容易被污染，DoH 在隧道里加密出境是更彻底的做法。

### 连接复用：enable_pipeline（2026-09-08 加）

国外上游开了 `enable_pipeline: true` —— HTTP/2 多路复用，让多个查询挤在同一条
连接上走，减少 TLS 握手次数。实测 8 次串行查询，开启后新建连接数由 4 条降到 2 条。
意义在于：握手少了，撞上「3.3 秒超时」的机会就少了（约 4.3% 的国外查询会卡到
3.3 秒，网页版 B 站转圈就是这么攒出来的）。

**另外两个参数经实测与论证后决定不加，勿自作主张补上：**

| 参数 | 为什么不加 |
|---|---|
| `idle_timeout: 10` | 初衷是「连接空着也占内存」，但这已被现场数据推翻（连接数降 62% 时 Xray 内存纹丝不动，说明内存不是连接数的函数）。而且 10 秒太短：查询间隔稍长连接就被关，下次要重新 TLS 握手（约 1 秒），**反而比复用慢得多**。默认 30 秒别动 |
| `max_conns: 2` | 初衷是给连接数加硬顶防内存爆，同样基于已被推翻的假说；而 2 条在并发时会成为瓶颈。真要加也得设 4～8 |

> 另注：`insecure` 这个参数在 upstream 层**不被接受**（会报 invalid keys），别加。

### ssr+ 的 DNS 解析方式到底怎么选

这是 AGH + mosdns + ssr+ 三者配合时最容易搞错的一步，单独说清。

先记住一个原则：**ssr+ 的「DNS 解析方式」只决定「DNS 由谁解析」，跟数据面的
国内外 IP 分流（防火墙 ssr-rules）是两条独立的线。** 本固件已经把 DNS 解析整条
外包给了 AGH + mosdns，所以 ssr+ 这里**不需要再启动任何自己的 DNS 组件**。
（对应字段 `pdnsd_enable` 默认值就是 0，即「本机 5335」，无需任何脚本干预。）

在 ssr+ 界面「基本设置 → DNS 解析方式」下拉框里：

| 选项（值） | 界面文字 | 做了什么 | 本固件该不该选 |
|---|---|---|---|
| **0** | 使用本机 5335 端口 DNS 服务 | 不启动任何进程，直接用 5335 上现成的服务（就是 AGH） | ✅ **选这个（默认）** |
| 1 | 使用 DNS2TCP 查询 | 启动 dns2tcp/dns2socks 绑 5335 | ❌ 与 AGH 抢端口 |
| 4 | 使用 MosDNS 查询 | 启动 ssr+ 自带的 mosdns 绑 5335 | ❌ 与 AGH 抢端口 |
| 6 | 使用 ChinaDNS-NG 查询并缓存 | 启动 chinadns-ng 绑 5335 | ❌ 与 AGH 抢端口 |
| 7 | 使用本机内置 DNS | xray 内核接管 5335 | ❌ 与 AGH 抢端口 |

为什么 1/4/6/7 都不能选：它们都会让 ssr+ 自己去监听 5335 端口，而 5335 已经被
AdGuard Home 占着（dnsmasq 的 `server=127.0.0.1#5335` 指的就是它）。一旦选了，
端口冲突，ssr+ 大概率起不来——这正是之前排查过的「5335 被占导致 ssr+ 挂」的场景。

**选 0 的完整含义**：ssr+ 的 DNS 进程全部关掉，DNS 交给
`dnsmasq:53 → AGH:5335 → mosdns:5353` 这条外链。数据面的防火墙分流、出站代理、
sniffing 跟这个下拉框无关，照常工作，翻墙不受影响。

> 一句话：**DNS 解析方式选 0，其余全不选。** 这个下拉框的唯一作用就是"别让它
> 碰 5335"，真正干活的是外面那条 AGH + mosdns 的链。

### 关于 web 前端

mosdns **没有 LuCI 网页前端**（官方 luci 源不收录 luci-app-mosdns），
但它是「配置一次就长期不动」的后台组件——本次已把配置烘焙进固件，日常完全不需要碰。
社区第三方有 luci-app-mosdns 面板，但那是配合它自家模板方案用的，
跟自定义 YAML 不兼容，不值得为此引入第三方源。

---

## 十三、季度自动编译与在线升级（full 档位）

这一套由四个部件组成，仓库里全部就绪：

### 1. 季度定时编译（`.github/workflows/openwrt-builder.yml`）

```
cron: '37 3 1 1,4,7,10 *'   timezone: Asia/Shanghai
```

**⚠️ 定时任务只在「默认分支」上执行**（GitHub 硬规则，与 workflow 内容无关）。本仓库已把
默认分支切到 `openwrt-25.12`，所以季度自动编译跟着 25.12 走；`main` 保留但不会自动编译，
需要时到 Actions 页手动 Run workflow 即可编出 23.05 版本。

**⚠️ Release 是仓库级的**（`/releases/latest` 不分分支）：25.12 编出来后，路由器升级页会
把它当作普通更新推给你 —— 而跨版本升级**不能保留配置**（见「一、2」节）。

每年 1/4/7/10 月 1 号北京时间 03:37 自动触发，**固定只编 full**。两个原因：

- minimal 只在 Breed 首刷用一次，季度重编没意义
- 一次编译只产一个 Release，路由器端脚本查 `/releases/latest` 才有唯一答案

时区说明：`timezone` 字段是 2026 年 3 月 GitHub 新增的（changelog 有记载），  
配合 POSIX cron 直接写北京时间，不用换算 UTC。

### 2. 60 天规则的对策（`.github/workflows/keepalive.yml`）

GitHub 对公开仓库有「60 天无 repository activity 自动禁用定时任务」的规则。  
季度间隔远超 60 天，所以 keepalive 每月 1 号提交一次 `.last-keepalive` 文件，  
让活动间隔永远 ≤31 天。

「机器人提交也算 activity」是社区通行做法，GitHub 未明文背书。万一失效，  
手动到 Actions 页点一次 Enable workflow 即可恢复——有兜底，不会无解。

### 3. 版本号与校验文件（编译时自动生成）

- **`/etc/hc5962-fw-version`**：编译前由 workflow 写入固件，内容即 Release tag（如 `full-2026.09.01-0337`），路由器靠它和 GitHub 比对版本
- **`sha256sums`**：Release 附带，路由器下载固件后用它验证完整性

### 4. 路由器端两个脚本 + 网页升级页（`files/usr/bin/` + `package/luci-app-hc5962-upgrade/`）

**检查更新**（纯只读，任何入口都安全）：

- LuCI：**系统 → 固件升级** 页面自带版本对比；另有 **系统 → 自定义命令 → 检查固件更新** 按钮（luci-app-commands）
- SSH：`fw-check-update`

输出当前版本、最新版本、发布日期、固件体积，并给出结论（已是最新 / 有新版本）。

**升级固件**（两种方式，流程完全一致）：

| 方式 | 入口 | 说明 |
|---|---|---|
| 网页一键（日常推荐） | LuCI → **系统 → 固件升级** | 点「检查更新」→ 看到新版本 → 输入确认词 `upgrade` → 点「开始升级」，页面实时显示进度日志 |
| SSH 交互（保留） | 终端跑 `fw-upgrade` | 适合需要细分选项的场景（如 `-n` 不保留配置） |

六步流水（两种方式相同）：查 Release → 查 `/tmp` 空间 → 下载 → **sha256 校验** → **`sysupgrade -T` 试刷校验** → 刷入。两道安全闸门任何一道失败都会中止并保留现场，绝不带病刷机。

**网页版的安全设计**（比 SSH 只弱一点点）：

1. 点「开始升级」前必须输入确认词 `upgrade`，按钮才生效（防误点）
2. 升级进行中按钮消失、页面轮询显示日志，无法重复触发
3. SSH 的 `fw-upgrade` 原样保留——网页版出任何问题，SSH 随时是退路

**升级过程的进度显示（v4，2026-09-21 起）**

页面不只甩一坨日志，而是把 `fw-upgrade` 的六步流水**归并成三步面板**实时点亮：

| 面板步骤 | 对应日志标记 | 说明 |
|---|---|---|
| ① 下载固件 | `[1/6]` 查 Release + `[2/6]` 下载 | 按固件体积与耗时估算百分比 |
| ② 校验完整性 | `[3/6]` sha256 + `[4/6]` 试刷 + `[5/6]` 即将刷入 | sha256 在 MIPS 上要算几十秒，此阶段显示滑动动画 + 「MIPS 较慢，页面不动属正常」提示 |
| ③ 刷入并重启 | `[6/6]` 开始刷入 | 之后路由器重启，页面自然失联 |

日志全文默认收起，只有失败时才展开；前端每 2 秒轮询一次，靠 rpcd 的 `running` 标志判断升级是否仍在进行。

> ⚠️ 已知坑（2026-09-24 修复，见变更记录）：判断 `running` 曾用
> `pgrep -f '^fw-upgrade -y'`，该写法在 busybox 上**永远失配**，会让页面在 2 秒后误报「失败」。
> 现改为 `pgrep -f '^fw-upgrade'`。
> **用 1543 及更早的固件刷机时，页面仍会谎报失败——看到失败不要重复点升级。**

**分享固件给别人**（比如恩山论坛）：改 `files/etc/hc5962-upgrade.conf` 里的 `REPO` 一行即可
指向你自己的仓库（格式 `用户名/仓库名`），检查/升级脚本和网页页都会跟着走。

### 升级会清掉什么

| 内容 | 升级后 |
|---|---|
| 烘焙进固件的插件（ssr+、AdGuard Home、ZeroTier、vlmcsd 等） | ✅ 升级到新版本 |
| LuCI 里的设置、无线密码、ssr+ 节点配置 | ✅ 保留 |
| iStore / opkg 手动装的插件 | ❌ 清掉，需重装（2026-09 起固件已不带 iStore：官方源砍了 mipsel_24kc 架构 feed，iStore 在本机装不了任何插件，纯占体积） |
| 烘焙配置（mosdns、ksmbd、lan masq 等）及 uci-defaults 已生效的定制 | ✅ 保留（烘焙 + conffiles 机制） |
| **`/etc/AdGuardHome.yaml`** | ⚠️ **2026-09-18 实测不保留**（它不在 conffiles/keep.d 里）。已双保险堵住：①实机与烘焙 UCI 均设 `upprotect=/etc/AdGuardHome.yaml`（写进 keep.d，sysupgrade 保留）；②烘焙 yaml 本身重写为 AGH 能直接读取的形态。注意②经过两轮才修好：9/18 只修了 YAML 语法（`interval` 单位、补 `schema_version`），**9/24 才发现 AGH 仍读不了它**（字段类型不符 + 缺段），遂以 AGH 自己写出的配置为骨架整份重写，并经 `AdGuardHome --check-config` 验证 `exit=0`。详见变更记录 9/18 与 9/24 条目。9/18 之前刷机此文件会被清掉 |

「长期必用烘焙、偶尔尝鲜走 opkg」分层策略的落点。

---

## 十四、健康采样与崩溃取证（full 档位）

### 它解决什么问题

一句话：**它是个只会记账、不会动手的记录员，专门为了下次崩溃时能抓到凶手。**

2026-09-06 实机发生过一次全机假死：负载飙到 31、SSH / LuCI / 翻墙全断，只能强制重启。  
事后却**查不出原因**——因为 syslog、`dmesg`、AdGuard Home 查询日志全都存在内存盘里，  
**一重启就清空**，而这台设备又没有 `/sys/fs/pstore`（内核崩溃留遗言的通道）。现场被水冲干净了。

所以它每 5 分钟让路由器自己在本子上写一行，记录当时有多忙、还剩多少内存、谁最占内存。  
平时没人看它，出事了回放才知道之前发生了什么——**类似行车记录仪**。

### 三个输出文件

| 文件 | 存在哪 | 重启后 | 用途 |
|---|---|---|---|
| `/tmp/health.log` | 内存盘 | 清空 | 日常趋势，看当天详情 |
| `/root/health-flash.log` | 闪存 | **保留** | **崩溃取证**——半夜崩了，第二天开机还能读到崩溃前最后几行 |
| `/root/health-alert.log` | 闪存 | **保留** | 异常时自动抓的**详细现场**（只在触发阈值时才产生） |

### 采样行怎么读

```
2026-09-10 10:40:06 load=[0.10 0.17 0.25] avail=53588kB
                    mem=[free=28884 cached=80648 anon=72420 sunrecl=23436 shmem=13208 tmpfs=13208]
                    cpu=[u=17% s=24% io=0%]  Dproc=0
                    xray=[max=32748 tot=32748kB fd=24 dohconn=0]
                    net=[rx=22 tx=8KB/s]
                    top=[33720:AdGuardHome 32748:v2ray 17868:mosdns]
```

| 字段 | 含义 | 正常值 |
|---|---|---|
| `load=[0.22 0.36 0.30]` | 1/5/15 分钟负载 | 0～1（事故时 25～31） |
| `avail` | 可用内存 | 50～90MB；**<40MB 预警，<25MB 危险**（事故前 16MB） |
| `anon` | 用户进程占用的内存 | 它涨 = 某个进程在泄漏 |
| `sunrecl` | 内核不可回收内存 | 它涨 = 内核对象泄漏（conntrack / dentry 等） |
| `shmem` | 共享内存 / tmpfs 总量 | 见下节；**本机无 swap，这一项涨了就下不来** |
| `tmpfs` | `/tmp` 内存盘已用（kB） | 查询日志 12h 自轮转后稳态 **9～11MB**（6.9MB 基线 + ~5.2MB 日志）；持续每天 +5MB 以上说明轮转失效了 |
| `u% / s%` | 用户态 / 内核态 CPU | 真的在计算时的占比 |
| `io%` | **iowait，等 I/O 的时间占比** | 接近 0；高了说明卡在 I/O |
| `Dproc` | D 状态（不可中断，通常卡 I/O）进程数 | **0** |
| `xray.max` | Xray **单个进程**的最大 RSS（kB） | 空闲 17～20MB、看视频 40～44MB；**>50MB 且可用内存 <30MB 才触发自动重启** |
| `xray.tot` | 两个 Xray 进程的 RSS 合计（kB） | 35MB 左右 |
| `xray.fd` | 两个 Xray 进程打开的 fd 总数 | 30 上下，粗略反映连接数 |
| `dohconn` | 本机到 8.8.8.8 / 1.1.1.1 的 443 连接数 | 0～2（空闲时 0） |
| `net` | br-lan 收发速率 KB/s（与上次采样求差） | 空闲个位数，看电影时能到几千 |
| `top` | 占内存前三的进程 | AdGuardHome / mosdns / v2ray |

> v1.02 新增 `xray.*` / `dohconn` / `net` 三组字段。动机见下节。  
> v1.06 新增 `shmem` / `tmpfs` 两个字段。动机见「十四·五」。

### 崩溃后怎么判断性质（这张表最关键）

| 现场显示 | 结论 | 往哪查 |
|---|---|---|
| `io%` 高 + `Dproc` 多 | 卡在 I/O，根源是**内存回收** | 内存问题，看 `anon`/`sunrecl` 谁在涨 |
| `u%`/`s%` 高 + `Dproc` 少 | 真的在计算 | CPU 问题，看 `top` 里是哪个进程 |

**为什么非要记 `io%` 不可**：LuCI 页面在事故时显示的是「CPU 94%」，很容易误判成"某个进程算疯了"。  
但 Linux 的 load average 统计的是「**可运行 + 不可中断(D状态)**」进程数——内存耗尽引发回收 I/O，  
会把大批进程卡成 D 状态，于是负载和 CPU 使用率一起飙升，**看着像 CPU 忙，实际是在等 I/O**。  
不记 iowait 就无法分辨这两种性质完全不同的故障。（这条正是 2026-09-07 补上的，之前吃过亏。）

### 异常时自动抓现场

满足任一条件时，自动往 `/root/health-alert.log` 存一份完整现场：

- 1 分钟负载 **> 5**
- 可用内存 **< 30MB**
- D 状态进程 **> 3**
- 可用内存**连续 3 次 < 25MB**（v1.06 新增，`!! LOWMEM` 专项取证块：额外含 Xray 是否超阈值的判定、`df -k /tmp` 与 /tmp 占用 top10、`ls -l /var/adguardhome/data/`；**只取证、不动作**）

现场包含：`/proc/meminfo` 全量、进程 RSS 前 15、D 状态进程清单、`top` 快照、conntrack 数、`dmesg` 尾部。  
上限 150KB，超出保留最后 900 行。

**为什么需要它**：崩溃往往发生在半夜，人不在场。有了这个，即使机器后来又重启了，  
崩溃前最后的详细记录还在闪存里，第二天照样能读到——不用再靠"碰巧在线"抓现行。

### Xray 内存超限自动重启（v1.02 新增）

2026-09-08 01:05 又崩了一次，这次采样脚本完整记下了全程。关键数字：

| 时刻 | 可用内存 | Xray 单进程 | 负载 |
|---|---|---|---|
| 00:40 | 62.8 MB | 16.6 MB | 0.06 |
| **01:05** | **10.2 MB** | **69.8 MB** | **15.87** |
| 01:36 | 15.0 MB | 69.9 MB | 26.56 |
| 01:40 | 56.1 MB | 30.3 MB | 1.95 |

5 分钟内 Xray 从 27MB 涨到 69.8MB，可用内存被抽干，随后内核疯狂回收 → UBI 闪存
I/O 阻塞 → 全机 D 状态假死 31 分钟才自愈。

**暴涨的根因至今没有定论。** 「DoH 并发导致连接堆积」这个一度被写进结论的假说，
后来被现场数据自己推翻了：

> 01:05 时 conntrack 493 条、Xray 69.8MB；到 01:20 conntrack 降到 **186 条（少 62%）**，
> Xray 却是 **69.9MB —— 一个 KB 都没降**。  
> 如果内存真是连接对象占的，连接少六成它必须跟着降。

（顺带纠正另一个想当然：conntrack 里含 127.0.0.1 的只有 7 条，**回环基本不进 conntrack**，
所以 mosdns → 127.0.0.1:1080 的连接根本不在那个数里，别拿它当 DoH 连接数用。）

根因未定，但有一点是实测事实：**Xray 单进程一旦冲到 70MB，内存必然见底**。  
所以 v1.02 加了不依赖根因的兜底：

- 阈值：Xray **单进程** RSS > 50MB（51200 kB）
- 动作：重启 `shadowsocksr`（翻墙断约 10 秒，国内网络不受影响）
- 冷却：30 分钟内最多重启一次，防止重启风暴
- 重启前会把 meminfo、RSS top10、DoH 连接数存进 `health-alert.log`

**为什么按"单进程"而不是两个加起来**：Xray 有 TCP / UDP 两个进程，基线各 17～20MB
（合计已经 35MB）。按合计判断，离 50MB 只剩 15MB 余量，会频繁误触发。

**为什么是 50MB**：全天最高见过 39.2MB（正常），崩溃时 69.8MB，50MB 卡在中间，
既不会误伤，又明显早于崩溃水位。

**进程名是自动发现的，不要写死（v1.03 修正）**：ssr+ 把当前在用的内核软链到
`/var/etc/ssrplus/bin/<名字>`，现在是 `bin/v2ray -> /usr/bin/xray`。内核记进程名
用的是启动时传进来的路径名、不解析软链接，所以 `comm` 显示 `v2ray` ——
**实测 `comm=v2ray` 命中 2 个进程，`comm=xray` 命中 0 个**。

脚本每次从这个目录读名字再匹配，而不是硬编码：

```sh
PROXY_NAMES=$(ls /var/etc/ssrplus/bin/ 2>/dev/null | tr '\n' ' ')
PROXY_NAMES=$(echo $PROXY_NAMES)
[ -z "$PROXY_NAMES" ] && PROXY_NAMES="v2ray xray"
```

这么做的原因：ssr+ 支持多内核（v2ray / xray / trojan / naive / hysteria …），
换内核时软链名就跟着变。**写死名字的话，一换就匹配不到，而且它不报错、不告警** ——
`XRSS_MAX` 恒为 0，兜底永远不触发，日志看着一切正常（静默失效）。读目录则换什么
内核都自动认得。ssr+ 没启用时目录为空 → 匹配不到 → 不触发，行为是安全的。

各内核在这个目录里的软链名（全部出自 `/etc/init.d/shadowsocksr` 的 `ln_start_bin`
调用点）：vmess/vless/trojan（Xray 承载）恒为 `v2ray`、独立 trojan 为 `trojan`、
naive 为 `naive`、hysteria 为 `hysteria`、tuic 为 `tuic-client`、ss/ssr 为
`ss-redir`/`ssr-redir`、ss-rust 为 `sslocal`。

**排除名单（v1.04 补）**：这个目录不只有代理内核，ssr+ 自启的 DNS / 辅助进程也走
同一个 `ln_start_bin`，一样在里面留软链 —— `mosdns`(326,737)、`chinadns-ng`(416,826)、
`dnsproxy`(335,382)、`dns2tcp`(293)、`dns2socks`(298,716)、`dns2socks-rust`(303,719)、
`microsocks`、`redsocks2`、`ipt2socks`、`shadow-tls`。

启用 ssr+ 自带 DNS 分流后，这些名字会混进候选列表被一起统计；mosdns 现在就已
14.6MB，它涨到 50MB 会被误判成「Xray 爆了」而白重启一次 shadowsocksr。所以从发现
结果里剔除它们。用「排除」而非「白名单」：将来漏写某个名字，后果只是少统计一个
进程，不会退回 v1.02 那种静默失效。

### 十四·五、内存盘 tmpfs：真正的「只增不减」项（2026-09-10 新增）

这一节记录 2026-09-10 那次内存排查的结论，以及据此做的两处改动（① 和 ⑤）。

#### 结论：进程全都不漏，涨的是内存盘

用 09-09 04:02 周重启后的 29.9 小时干净基线（360 个 5 分钟采样）逐进程回归：

| 观察对象 | 稳定期斜率 | 判定 |
|---|---:|---|
| AdGuardHome | −399 kB/h | 不漏（峰值 55.7MB 后自行回落，Go GC） |
| mosdns | −205 kB/h | 不漏 |
| zerotier-one | −0.2 kB/h | 纹丝不动 |
| v2ray | +263 kB/h | 流量驱动，会自愈 |
| **全部进程合计** | **−255 kB/h** | **不漏** |
| anon（用户进程内存合计） | **−173 kB/h** | 开机 6 小时预热后即饱和，地板 66.0 / 67.4 / 66.7MB **持平** |
| **shmem / tmpfs** | **+234 kB/h** | **严格单调，从不回落 ← 元凶** |

也就是说，之前观察到的「anon 从 52MB 爬到 79MB」**不是泄漏**，而是开机预热
（mosdns 启动 +27.5MB、v2ray 缓冲区 +20.9MB、AGH 缓存 +15.1MB、dnsmasq +10.8MB），
6 小时后就饱和了。

#### 元凶：AdGuardHome 的数据目录整个在内存里

- AGH 的 workdir 是 `/var/adguardhome`，而 **OpenWrt 上 `/var` 就是 `/tmp`**，也就是 tmpfs
- `files/etc/AdGuardHome.yaml` 原配置 `querylog.interval: 90`（90 天，`file_enabled: true`）
  → 90 天内不轮转、不删除
- 实测 `querylog.json` 每天长 **5～13MB**（随 DNS 查询量浮动，09-10 白天实测到 540 kB/h）
- **本机 `SwapTotal = 0`** → tmpfs 页既不能换出也不能回收，涨一兆就少一兆可用内存

`/tmp` 的常驻构成（09-10 实测）：

| 文件 | 大小 | 性质 |
|---|---:|---|
| `/tmp/adguardhome/data/querylog.json` | 6.0→6.4 MB | **持续增长 ← 元凶** |
| `/tmp/adguardhome/data/filters/1.txt` | 4.26 MB | 每 24h 原地刷新，固定 |
| `/tmp/dnsmasq.d/.../gfw_list.conf` | 1.92 MB | ssr+ 生成，固定 |
| `/tmp/adguardhome/data/stats.db` | 0.26 MB | 固定 |

外推：距下次周重启还有 6 天时，tmpfs 会到 ~42MB，可用内存从 52MB 掉到 **~23MB**
（低于 25MB 危险线）—— 不加处理几乎必然再次触发「内存耗尽 → UBI I/O 阻塞 → 全机假死」。

#### 改动 ①：查询日志保留期 90 天 → 12 小时，交给 AGH 自己轮转

只改一个值：`files/etc/AdGuardHome.yaml` 的 `querylog.interval` 由 `90`（90 天）改为 **`12h`**。

AGH 轮转的真实行为（v0.107.46 源码 `internal/querylog/querylogfile.go`）：

- `os.Rename(querylog.json → querylog.json.1)`，**只保留一个备份**，不存在 `.2/.3`，
  下一次轮转时旧 `.1` 被直接覆盖
- 源码 `querylog.go` 注释写得很明白：旧文件是 **renamed, NOT deleted**，
  所以 **实际保留时长 = 2 × interval**，任一时刻内存里同时躺着 `querylog.json`
  和 `querylog.json.1` 两份
- 判据是「文件里**最早一条记录**的时间 + interval < 现在」，每小时检查一次
  （`rotationCheckIvl = 1h`）

所以稳态占用 ≈ 两个 interval 的量：

| interval | 内存峰值（json + .1） | 日志可回看 |
|---|---:|---|
| 24h | ~10.4 MB | 48 小时 |
| **12h（采用）** | **~5.2 MB** | **24 小时** |
| 8h | ~3.5 MB | 16 小时 |

（按本机实测 5.2 MB/天、约 634 条/小时计算。）

> **曾经加过、后来撤销的方案**：2026-09-10 上午一度在 `zz-hc5962-custom` 里加过
> 第 11 节 cron `50 3 * * *`「停 AGH → 删 `querylog.json` → 启 AGH」，当天即撤销。
> 原因：AGH 自己轮转到 12h 就能把内存压在 ~5.2MB，与每天删一次效果相当，
> 却没有每天 5～15 秒的 DNS 中断。而且两者互斥——每天删会让文件「最早记录」
> 永远不到 12 小时，轮转反而永远不会触发。
>
> **如果将来要手工清空，必须先 `stop` 再删**：AGH 持有该文件的 fd，进程还活着时
> `rm` 只解除目录项，块仍被占用，内存不会释放。

⚠️ **改 interval 后必须重启 AGH 才生效**：AGH 只在启动时读 `/etc/AdGuardHome.yaml`，
改了文件不重启等于没改。2026-09-10 就踩过一次——yaml 上午就改好了，进程却从两天前
一直没重启过，配置始终没加载，「轮转没生效」差点被误判成「AGH 不会轮转」。

#### 改动 ⑤：可用内存持续过低时的专项取证

原来的 Xray 兜底只在「Xray 超阈值 **且** 内存见底」时才动作。如果内存是被别的东西
吃掉的（tmpfs / 内核 slab / 别的进程），它全程沉默 —— 这正是这次排查中暴露的盲区。

v1.06 补上按可用内存**单独**触发的一条：

| 参数 | 值 | 理由 |
|---|---|---|
| `AVAIL_HARD` | 25600 kB（25MB） | 比 Xray 那条 30MB 更严 |
| `LOWMEM_N` | 3 次 | 连续 3 次 = 持续 15 分钟，滤掉流量突发造成的单次误报 |

触发后往 `/root/health-alert.log` 写一块 `!! LOWMEM` 现场，额外包含：

- **Xray 是否背锅**的判定（超没超 50MB 阈值，直接给结论）
- `df -k /tmp` 与 `/tmp` 各目录占用 top10
- AGH 工作目录 `ls -l /var/adguardhome/data/`
- meminfo 关键项、进程 RSS top10

**它只取证、不动作。** 低内存的成因还没穷举完（tmpfs 只是已确认的一个），贸然自动
重启别的服务既可能掩盖真凶，也会误伤正在用网的人。

顺带把 `shmem` / `tmpfs` 加进常规采样行 —— 这次排查为了拿到「/tmp 里到底谁在涨」
不得不临时部署采集脚本，补上后趋势直接可见，下次不用再装东西。

### 它是怎么挂上去的

由 `files/etc/uci-defaults/zz-hc5962-custom` **第 10 节**在首次开机时写入 cron：

```
*/5 * * * * /etc/health_sample.sh
```

**不要直接烘焙 `/etc/crontabs/root`**：ssr+ 每次启动都会重写这个文件（它会 `sed -i '/ssrplus.log/d'`），  
直接放文件会被覆盖掉。走 uci-defaults 开机追加才稳。

同理，本脚本的 **cron 行和日志名都不能包含 `ssrplus.log` 字样**，否则会被 ssr+ 误删。

### 两个环境事实（影响判读）

- **本机 `SwapTotal = 0`，完全没有 swap**。内存耗尽时没有换页缓冲，只能硬着陆——  
  所以症状是**突然假死**，而不是逐渐变慢。
- 闪存磨损：常规行 288 行/天 × 约 180B ≈ **50KB/天，一年约 18MB**（overlay 有 71MB），常规 NAND 寿命下可忽略。

---

## 十五、待确认事项

1. **无线默认是开着的**（这条要特别注意）  
   ImmortalWrt 的 `mac80211.sh` 生成的默认配置是 `disabled=0` + `country=CN`，  
   也就是说刷完机就能搜到一个名为 **ImmortalWrt 的开放网络（无密码）**。

   保持了你的要求（不动它，由你进设置关）。但要注意：刷机后到你设置密码之间的这段时间，  
   邻居是能直接连进来的。

   关闭方式 —— 网络 → 无线 → 对应 radio 点「禁用」；或 SSH：
   ```sh
   uci set wireless.radio0.disabled='1'
   uci set wireless.radio1.disabled='1'
   uci commit wireless
   wifi reload
   ```
2. **Breed 版本**：极早期 Breed 对 HC5962 的 NAND 支持有差异。如果首刷失败，先确认 Breed 版本再排查。

---

## 十六、变更记录

### 2026-09-25 · 迁移 openwrt-25.12 分支：helloworld 钉错分支的重大更正

**背景**：为「季度编译前自动检查插件上游有没有升级」这个需求做上游核对时，连带查出一条被忽略很久的问题。

**更正一：ssr+ 的 helloworld 源钉错了分支，自 2026-07-11 起从未拿到更新**

| 项 | 内容 |
|---|---|
| 位置 | `feeds.conf.default` 第 8 行 `src-git helloworld https://github.com/fw876/helloworld;master` |
| 事实 | 该仓库有三个分支：`main`（停 2024-10-09）、`master`（**停 2026-07-11**）、`dev`（**活跃，且是仓库默认分支**）。分叉点 `6b578665`（2026-04-26），此后 dev 领先 305 个提交 |
| 实证 | 实机 `opkg list-installed` 里 `luci-app-ssr-plus - 190-3`（= master@2026-07-11 的版本），而 dev 已是 `196-9`；`luci-i18n-ssr-plus-zh-cn - git-26.192.35200-2abdc9a` 里的 `26.192` = 2026 年第 192 天 = 7/11 |
| 为什么会这样 | `scripts/feeds` 第 235–240 行：**写了 `;分支` 才 clone 该分支，不写则跟随远程默认分支**。我们一直写着 `;master`，等于主动把自己钉在一个会停更的分支上 |
| 修复 | 去掉 `;master`（`feeds.conf.default` 与 `diy-part1.sh` 兜底串两处），改为跟随默认分支 |
| 教训 | 「引用没变」≠「内容是对的」—— 钉的分支死了，基线永远不变，任何靠「比对引用」的自动检查都会**安静地不报警**。上游检查必须落到「**实机产物版本 vs 该分支 HEAD 处 Makefile 的版本**」这个对照上 |

**更正二：xray 永远取 immortalwrt/packages 的版本，helloworld 那份从未生效**

`package/feeds/<feed>` 按**字母序**扫描，`helloworld`(h) 先于 `packages`(p) ⇒ 同名包由 packages 覆盖。实机 `/usr/bin/xray` = `24.12.31`（packages@23.05 的版本），helloworld 钉的 26.5.9 从未被编进固件（25.12 上对应 26.3.27）。

**本次迁移：新建 `openwrt-25.12` 分支**

23.05 上游已于 **2025-08-16 EOL**，ImmortalWrt 的 openwrt-23.05 主源码停 2026-02-27、packages 停 2026-02-06 ⇒ 在该分支上继续季度编译只是「重建」、零安全补丁。故新建 `openwrt-25.12` 分支承接季度自动编译，`main` 冻结留作退路。

改动只涉及 4 个文件：

- `feeds.conf.default`：4 个官方源分支号 → `openwrt-25.12`；helloworld 去掉 `;master`
- `diy-part1.sh`：兜底 append 串同步去掉 `;master`
- `.github/workflows/openwrt-builder.yml`：`REPO_BRANCH` → `openwrt-25.12`（含头部注释）
- `README.md`：本文件同步更新

**同日晚续做（第二笔提交）：把「编译前还需做的两件」也做完了**

① `configs/config-full.config` 按 25.12 + helloworld dev 重做（264 → 285 行）：

| 项 | 内容 |
|---|---|
| 库包改名 | 25.12 去掉了 ABI 数字后缀：`libstdcpp6`→`libstdcpp`、`libatomic1`→`libatomic`、`libnatpmp1`→`libnatpmp`（23.05 实机 opkg 仍是旧名） |
| **透明代理后端换机制** | dev 版给 `Iptables_Transparent_Proxy` 加了 `depends on !PACKAGE_firewall4`，而 25.12 的 `DEFAULT_PACKAGES.router` 默认带 firewall4 ⇒ 写 Iptables 会被 defconfig **静默丢弃**，由 choice 默认值落到 **`Nftables_Transparent_Proxy`**（其 depends 恰为 `PACKAGE_firewall4`）。master（实机的 190-3）没有这条 depends —— 它只在 choice 的 `default` 行里带条件 —— 所以 23.05 实机跑的是 iptables+ipset。**迁移后机制变为 nftables+nftset**，属上游设计变更 |
| 选项被删 | dev 删掉了 `INCLUDE_Shadowsocks_Libev_Client`（SS 客户端只剩 Rust，我们**不开**：Rust 常驻内存大，而 Xray 原生支持 SS）、`INCLUDE_DNS2SOCKS`、`INCLUDE_IPT2Socks`（改自动依赖） |
| 新增落点 | `dnsmasq_full_nftset`、`nftables`、`kmod-nft-tproxy`、`kmod-nft-nat`（显式写，确保进固件而非编成 ipk）；ipset 三项保留作安全网 |
| 核对方式 | 拉 `immortalwrt/{luci,packages,immortalwrt}@openwrt-25.12` + `fw876/helloworld@dev` 四份源码，逐个 `define Package/` 比对 94 项。另澄清：**25.12 的 rust 支持 mipsel**（`rust-values.mk` 的 `RUST_ARCH_DEPENDS` 含 mipsel），旧记「Rust 程序 mipsel 编不了」只对 mihomo/clash 成立 |

② `files/etc/AdGuardHome.yaml` 升到 **AGH 0.107.78 / `schema_version: 34`**：

| 项 | 内容 |
|---|---|
| 为什么必须升 | 实测把旧文件（`schema_version: 28`）交给 0.107.78 的 `--check-config`，它会连做 **6 次迁移（28→29→…→34）并改写文件** —— 这正是 9/18 事故的触发路径 |
| 骨架来源 | 让 0.107.78 **自己迁移写出来**的那份文件，再填回我们的取值（这是「AGH 会不会认」的唯一权威答案） |
| 新增键 | `dns.cache_enabled` / `cache_optimistic_answer_ttl` / `cache_optimistic_max_age`、`filtering.safe_fs_patterns`、`http.doh.routes`、`querylog.ignored_enabled`、`statistics.ignored_enabled` |
| 删除键 | `tls.allow_unencrypted_doh`（新版本已移除） |
| 顺手做的省内存项 | `dns.cache_size` 4MB → **1MB**；`querylog.interval` 12h → **6h** |
| 坑 | AGH 写出的 `safe_fs_patterns` 带的是**当时 workdir 的绝对路径**（PC 上的 `C:\Users\...`）—— 必须换成路由器路径 `/var/adguardhome/data/userfilters/*`，否则把 PC 路径烘焙进固件 |
| 验证 | 官方 0.107.78 本体 `--check-config` → **exit=0 且校验前后 md5 一字未变**（`d5b0ef73…`），日志无任何 `config_migrator: upgrade` 行。这就是「全新刷机 AGH 一定能起来」的判据 |

### 2026-09-24 · 编译前体检再揪三个 bug（升级状态判定恒假 + 烘焙 yaml 非法结构 + 烘焙 yaml 与 AGH schema 不同构）

再一次「准备编译新固件 → 然后走网页升级」之前做例行复查，又揪出两个必须修的问题（commit `dd70210`）。这两个都是**隐蔽型**：不报错、不影响日常使用，只在特定路径上炸。

**Bug ③：网页升级页会在 2 秒后误报「失败」（升级状态判定永远为假）**

| 项 | 内容 |
|---|---|
| 位置 | `package/luci-app-hc5962-upgrade/root/usr/libexec/rpcd/hc5962-upgrade` 的 `log` 方法 |
| 现象 | 点「开始升级」后进度面板亮一下，2 秒后跳红色「失败」并**停止轮询**；但路由器其实在正常下载 → 校验 → 刷入 → 重启 |
| 根因 | 判断「升级是否在跑」用的是 `pgrep -f '^fw-upgrade -y'`。**busybox 的 `pgrep -f` 匹配串是以「进程名(comm)」开头、后接完整 cmdline**，而不是 cmdline 的首字段。`fw-upgrade` 是 `#!/bin/sh` 脚本，跑起来后匹配串形如 `fw-upgrade /bin/sh /usr/bin/fw-upgrade -y` —— `'^fw-upgrade -y'` 中间隔着 `/bin/sh`，**永远失配** → `running` 恒为 `false` → 前端第一轮 poll（2 秒）就认为升级已结束，日志里还没有 `[6/6]` → 判定失败 |
| 实测 | 路由器上做**同名同构**验证（临时 `/tmp/fw-upgrade -y`，测完即清）：`pgrep -f '^fw-upgrade -y'` = **NOMATCH**；`pgrep -f '^fw-upgrade'` = **MATCH** |
| 修复 | 判定串去掉 ` -y`，改为 `pgrep -f '^fw-upgrade'` |
| ⚠️ 危险点 | 页面显示「失败」时**千万别重复点升级** —— 第一次刷机其实仍在进行，重复点会并发触发第二次，风险很高。判断真伪看路由器是否在 3 分钟后重启、版本号是否变新 |
| 影响面 | 升级功能**从 v3 起一直带着这个 bug**（9/18 修 nohup 时没发现它）。它不阻碍刷机，只让页面谎报失败 |

**Bug ④：烘焙 yaml 是非法 YAML（`ignored: []` 被顶到 `schema_version` 下）**

| 项 | 内容 |
|---|---|
| 位置 | `files/etc/AdGuardHome.yaml` 尾部 |
| 现象 | `schema_version: 28` 紧跟一行缩进的 `ignored: []`；pyyaml 直接报 `mapping values are not allowed here (line 110)` |
| 根因 | 9/18 修 Bug ② 时（commit `c4de2d7`）在 `statistics:` 段后插入 `schema_version` 注释块，**插入点选在了原 `ignored: []` 前面**，把这一行顶成了「标量 `28` 的缩进子键」 |
| 依据 | 路由器上 **AGH 自己写出的** yaml 里，`ignored: []` 同时存在于 `querylog:` 和 `statistics:` 两段；本文件里它属于 `statistics:` 段 |
| 修复 | 把 `ignored: []` 挪回 `statistics:` 段（`interval: 24h` 之后），`schema_version: 28` 作文件顶层收尾 |
| 影响面 | ⚠️ **走 sysupgrade 升级不受影响**（upprotect 生效，保留的是路由器上那份合法配置）；但**全新刷机 / 恢复出厂 / 把固件分享给别人**会直接读到它 → AGH 起不来 → 9/18 全屋断网事故重演。属于必须堵死的隐患 |
| 教训 | 「同一份文件在两条路径上被读，只测了一条」—— 9/18 只验证了 sysupgrade 路径，没有验证「新刷/出厂」路径。凡改烘焙配置，两条路径都要想一遍 |

**Bug ⑤：烘焙 yaml 即使 YAML 合法，AGH 也读不进去（字段类型不符 + 缺段）**

**本次体检最有价值的发现**，也说明 9/18 那次修复只修了表皮。

| 项 | 内容 |
|---|---|
| 怎么发现的 | 不再靠「我看着合法」——把烘焙 yaml 放到路由器 `/tmp`，用 **AGH 本体**校验：`/usr/bin/AdGuardHome --check-config -c /tmp/xxx.yaml` |
| 结果 | `exit=1`：`line 49: cannot unmarshal !!bool 'false' into dnsforward.EDNSClientSubnet`、`line 77: cannot unmarshal !!seq into filtering.BlockedServices` |
| 根因 | 0.107.46 里 `edns_client_subnet`、`blocked_services` 是**结构体**，烘焙文件却写成标量 `false` 和空序列 `[]`；另有一个凭空捏造的 `blocked_services_schedule` 独立键（它本该是 `blocked_services.schedule`）。此外**整整缺了 8 个段**：`tls` / `filters` / `whitelist_filters` / `user_rules` / `dhcp` / `clients` / `log` / `os`，以及一批子键 |
| 为什么一直没暴露 | 这三条路径全靠「路由器上那份 AGH 自己写的合法配置」兜着：日常运行读 `/etc` 那份、sysupgrade 有 upprotect 保留。**烘焙文件从未被 AGH 成功读取过一次**——9/18 之前读不到（配置没丢时它是被盖住的），9/18 读到了却起不来 |
| 后果 | 全新刷机 / 恢复出厂 / 把固件分享给别人 → AGH 起不来 → 本地 DNS 全灭 → 全屋断翻墙，与 9/18 完全同款 |
| 修复 | 以「路由器上 AGH 自己写出的配置」为**结构骨架**重写整份烘焙 yaml（键顺序、层级、类型全部同构），只把值改成设计要的：单上游 `127.0.0.1:5353`（mosdns）、4MB 缓存、乐观缓存开、`aaaa_disabled`、querylog 12h、statistics 24h、安全搜索关、`users` 空、订阅不烘焙。commit `42277c8` |
| 验证 | `--check-config` → **`exit=0` + `configuration file is ok`**，且**校验后文件 md5 未变**（说明不再触发 schema 迁移）—— 这是「新刷后 AGH 一定能起来」的最强证据 |
| 教训 | 凡改烘焙配置，**必须让目标程序自己校验一遍**。「YAML 能解析」≠「程序能读得进去」，中间还隔着 schema 这一层；9/18 就是只验到「YAML 语法」这一层就收工了 |

**本次升级（编译后首次刷）的注意事项**

- 本次编译出的固件**自带这三处修复**，刷完后网页升级页的进度显示会正常（不会再谎报失败），AGH 配置也经 AGH 本体验证可读。
- 但**这次升级动作本身用的是路由器上现有的旧 rpcd**（仍是恒假版本）：若不先热部署，页面依然会在 2 秒后显示失败。**已热部署到实机**（`/usr/libexec/rpcd/hc5962-upgrade`，与 9/18 那次同样的手法）——热部署是 overlay 文件，下次 sysupgrade 后由镜像内版本接管，版本一致，无冲突。
- 前端与后端日志标记契约同时复核通过：`fw-upgrade` 打印 `[1/6]`~`[6/6]` → rpcd 透传 `/tmp/fw-upgrade.log` → `upgrade3.js` 映射 `[1/6]`→步1、`[3/6]`→步2、`[6/6]`→步3。
- 本次升级**不会**动到 AGH 配置：`upprotect` 生效，sysupgrade 保留路由器上那份（AGH 自己写的、合法的）`/etc/AdGuardHome.yaml`。

**复用工具**：本次体检用到的三个只读脚本留在工作区（非仓库内），每次编译前可直接跑：

- `gh_check.py` —— 核对上游源更新与补丁落点（含 ssr+ 两个补丁是否仍能命中）
- `yaml_check.py` —— 校验所有烘焙 YAML/JSON 的**语法**可解析性（**Bug ④ 就是它抓出来的**，9/18 事故后新建）
- `agh_verify.py` —— 把烘焙 AGH yaml 传到路由器 `/tmp`，调 **AGH 本体** `--check-config` 验证**语义**可读性（**Bug ⑤ 就是它抓出来的**）。改任何 AGH 配置后都该跑一次

### 2026-09-18 · 首次在线升级实战：两个 bug（升级工具 nohup + AGH 配置丢失与烘焙 yaml 失效）

刷入 full-2026.09.15-1543 后实测两次翻车，均已修复并推 GitHub。备查要点如下。

**Bug ①：网页一键升级点了没反应（升级工具自身）**

| 项 | 内容 |
|---|---|
| 现象 | 网页点「开始升级」后毫无动静，路由器不重启、不下载；`/tmp/fw-upgrade.log` 只有一行 `hc5962-upgrade: line 23: nohup: not found` |
| 根因 | rpcd 后端脚本用 `nohup` 往后台拉起刷机程序，**本机 busybox 没有 nohup**（该限制此前已知，写 v3 时踩了自己记过的坑）。第 23 行瞬间报错退出，下载/校验/刷机均未开始 |
| 修复 | 删掉 `nohup`（后台 + 重定向足够，rpcd 每次调用现读脚本）。commit `fb4c3c7` |
| 注意 | 1543 固件编译早于该修复，**其内烘焙的升级工具仍带 nohup**——用 1543 的网页升级前需先热修或改用 SSH `fw-upgrade`；从下一版固件起自带修复 |
| 附注 | 32MB 固件的 sha256 在 MIPS 上要算几十秒，期间页面日志一行不动，像卡死但不是——校验/试刷/刷入全程约 5-7 分钟 |

**Bug ②：升级后 AGH 起不来 → 全屋断翻墙（丢失配置 + 烘焙 yaml 自带两处 bug）**

死因链四环，每环有实证：

1. `/etc/AdGuardHome.yaml` **不在 sysupgrade 保留清单**（该插件的保留机制 `upprotect` 未配置）→ 升级把调教好的配置清掉；
2. 露出的烘焙 yaml（`files/etc/AdGuardHome.yaml`）**本身有两处 bug**：`statistics.interval: 1` 缺时间单位（AGH 报 `missing unit in duration "1"`）、缺 `schema_version` 字段——9/10 写这份文件时埋的，此前实机一直用现成配置，从未真正读到过它；
3. 缺 `schema_version` 触发 AGH 的 schema 迁移**改写配置文件**，改写产物自带 `bootstrap_dns: - []`（列表嵌空列表）语法错误 → AGH 连续崩溃退出（开机日志 PID 3888 报 duration 错、PID 4250 报 line 17 unmarshal 错）；
4. dnsmasq(53) → AGH(5335，死) → mosdns(5353) 链断 → 本地 DNS 全灭 → Xray 解析不了节点域名 → 隧道建不起来 → 全屋不能翻墙。**ssr+ 的 40+ 节点配置全程完好，没丢。**

排查中洗清的嫌疑人：大小写两个 init 脚本全文、uci-defaults 脚本、/usr/share/AdGuardHome 附属脚本、模板文件——都没有拷贝配置的代码，改写者是 AGH 自己的迁移逻辑。

修复（commit `4835dff` + `c4de2d7`）：

- 实机：修 yaml（`bootstrap_dns: []`、querylog 12h）+ 设 `upprotect=/etc/AdGuardHome.yaml`（写进 keep.d，升级不再清它）；
- 仓库：新增 `files/etc/config/AdGuardHome`（UCI 对齐实机，**upprotect 烘焙进去**，下一版固件起升级不丢配置）；烘焙 yaml 修为 `interval: 24h` + `schema_version: 28`。

  > ⚠️ **此修复并不彻底**（2026-09-24 复查发现）：它只解决了「单位缺失」和「缺 schema_version」，文件里还有**两处字段类型错误 + 8 个缺失段**，AGH 本体依然读不进去（`--check-config` 报 `exit=1`）。也就是说，此处之后全新刷机仍会重演 AGH 起不来。真正修好是在 9/24 —— 见该日条目 **Bug ⑤**。教训：**「YAML 语法合法」不等于「AGH 能读」**，中间还隔着 schema 这一层。

遗留提醒：升级后 AGH 回到包默认行为，safe_search 全开、过滤规则与管理员账号为空，需进 `:3000` 界面重新调回。

### 2026-09-15 · 乐观缓存默认开 + Wake-on-LAN + README 校对

**内容**（为第一次固件自动编译 + 路由器半自动升级测试做的准备）：

| 改动 | 文件 | 内容 |
|---|---|---|
| ① | `files/etc/AdGuardHome.yaml` | `cache_optimistic` 由 `false` 改 **`true`**（9/11 实机已开并验证：隧道被挤兑时缓存中已有的域名照常应答，把"国外 DNS 全断"降级为"个别新域名慢一下"） |
| ② | `configs/config-full.config` | 新增 **Wake-on-LAN**：`luci-app-wol` + `luci-i18n-wol-zh-cn` + `etherwake`（官方源，无后台服务，随用随点）。**实机此前已 opkg 手动装过这两款**（etherwake 1.09-5、luci-app-wol git-25.294），sysupgrade 升级会清掉 opkg 手装插件——烘焙进固件正是为了让它升级后不丢 |
| ③ | `README.md` | 校对 5 处过时/错误描述：健康采样 v1.05→v1.06、LAN DNS 114→127.0.0.1、tmpfs 判据改 12h 轮转稳态、异常取证条件补 `!! LOWMEM`、"待观察"改"已验证"；补 AGH 维持 0.107.46 决策与 ssr+ 运维须知 |
| — | iStore | 核对确认新库从未包含 iStore（configs 零匹配），维持现状；下次 sysupgrade 升级后 iStore 自然消失 |

**乐观缓存的效果边界**（勿夸大）：只救"缓存中已存在但已过期"的域名（过期条目以
10s TTL 应答、后台异步刷新）；从未解析过的新域名上游超时依然失败。

### 2026-09-10 · 内存盘 tmpfs 泄漏治理（AdGuard Home 查询日志）

**背景**：排查「可用内存持续下降、9/6 与 9/8 各发生一次内存耗尽假死」。
结论是**没有任何进程泄漏**——稳定期全部进程 RSS 斜率合计 −255 kB/h，anon 地板持平；
**唯一只增不减的是 `/tmp` 这个内存盘**，因为 AdGuard Home 的工作目录 `/var/adguardhome`
就在 tmpfs 里，查询日志每天长 5～13MB，而本机无 swap、tmpfs 页无法回收。

| 改动 | 文件 | 内容 |
|---|---|---|
| ① | `files/etc/AdGuardHome.yaml` | `querylog.interval` 由 `90`（90 天）改为 **`12h`**（最终方案） |
| ① | `files/etc/uci-defaults/zz-hc5962-custom` | 同日曾新增第 11 节 cron `50 3 * * *` 每天删 `querylog.json`，**当天撤销**，改为纯靠 AGH 轮转（保留说明注释，别再加回来） |
| ⑤ | `files/etc/health_sample.sh` | v1.06：采样行新增 `shmem` / `tmpfs`；新增「可用内存连续 3 次 <25MB」专项取证块（`!! LOWMEM`，只取证不动作） |
| — | `README.md` | 新增「十四·五」整节说明排查结论与改动理由；采样行示例与字段表同步更新 |

**采用 AGH 自轮转而不用 cron 删除的理由**：轮转到 12h 的稳态占用 ~5.2MB，与每天删一次
相当，但省掉每天 03:50 那 5～15 秒的 DNS 中断；且两者互斥（每天删会让轮转永不触发）。

**已知副作用**：AGH 查询日志可回看时长从「无上限（90 天）」缩短为 **24 小时**
（保留期 = 2 × 12h）；除此之外没有其他影响。

**已验证（2026-09-11、09-12 连续两轮）**：轮转按预期发生——`querylog.json` 与
`querylog.json.1` 并存且各 ≤3.5MB（实测 0.70 + 2.09MB）、json 最早记录恰 12.0h、
轮转点 = `.1` 的 mtime；采样行 `tmpfs=` 已停止增长并稳定在 ~10MB。本观察项**正式关闭**，
仅当 tmpfs 重新单调上涨或 AGH 异常时再按需检查。
