# 极路由 4 增强版 (HiWiFi HC5962) · ImmortalWrt 云编译配置

**编译的源码：`https://github.com/immortalwrt/immortalwrt` 分支 `openwrt-23.05`**  
**本仓库不引用 P3TERX/Actions-OpenWrt，也不需要**

> **没用过 GitHub？先看这份：** [操作手册-手把手.md](操作手册-手把手.md)  
> 从注册账号到拿到固件，每一步点哪个按钮、填什么都写清楚了，不需要任何基础。  
> 下面这份 README 是技术细节说明（为什么这么配、各参数什么意思）。



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
  REPO_BRANCH: openwrt-23.05
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

### 2. 为什么是 openwrt-23.05 而不是 24.10

|                                        | 23.05（本项目实际形态）        | 24.10                |
| -------------------------------------- | ------------------------------ | -------------------- |
| 防火墙后端                                  | **firewall4 + nftables**（实测） | firewall4 + nftables |
| 你的 `iptables -t nat -A POSTROUTING...` | 已改由 `zz-hc5962-custom` 首启置 lan zone `masq='1'`，fw4 自动生成 fullcone NAT，直接生效 | 同样按 nftables 写法 |
| ssr+ 支持                                | 成熟稳定                     | 透明代理/分流不完善           |

> 注：早期这份配置想"显式切回 firewall3"，实测被 defconfig 静默推翻
> （`CONFIG_PACKAGE_firewall=y` 被降级成 `=m`，fw4 照装），所以固件里实际
> 就是 firewall4。自定义 NAT 规则走 uci（lan zone masq），不写任何 nft 文件。

结论：**23.05 更适配你的需求**。代价是 AdGuard Home 的 LuCI 界面在官方 23.05 feed 里没有，用社区包补（见下）。

### 3. 插件来源核对结果

| 插件           | 来源                                     | 说明                                                                                                   |
| ------------ | -------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| SMB          | `luci-app-ksmbd`                       | ImmortalWrt 官方 luci feed。ksmbd 是内核态 SMB3，约 300KB；samba4 约 8-10MB，为控体积选 ksmbd                         |
| U盘自动挂载       | `automount`                            | ImmortalWrt 官方 `package/emortal/automount`，热插拔自动挂载并写 fstab                                           |
| ssr+         | `luci-app-ssr-plus`                    | **ImmortalWrt 任何官方源都没有**，用上游 `fw876/helloworld`                                                      |
| AdGuard Home | `adguardhome` + `luci-app-adguardhome` | 核心在官方 packages 源；**LuCI 界面只在 luci 的 master 分支有**，23.05 分支没有。社区版 `rufengsuixing/luci-app-adguardhome` 仓库是 package 目录布局（Makefile 在根目录），**不能当 feed 用**（feed 扫描只认子目录，会被静默忽略），由 `diy-part1.sh` 直接 clone 进 `package/` |
| ZeroTier     | `zerotier` + `luci-app-zerotier`       | **纯官方 packages / luci 源，不需要任何第三方源**。本体约 500KB，依赖 `kmod-tun`（TUN/TAP 虚拟网卡）                            |
| vlmcsd (KMS) | `vlmcsd` + `luci-app-vlmcsd`           | **纯官方 packages / luci 源**。本体仅 23KB，用于局域网内 Windows / Office 的 KMS 激活                                  |
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
4. 23.05 的内核是 5.15，比 LEDE 的 5.4/5.10 新，MT7621 的无线驱动（mt76）也更完善。

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
files/etc/AdGuardHome.yaml             # AGH 烘焙配置（端口 5335、上游 127.0.0.1:5353、4MB 缓存）
files/etc/mosdns/config.yaml           # mosdns v5.3.3 分流配置（监听 5353，国内外分流，见十二·五章）
files/etc/mosdns/cn.txt                # 国内域名名单（约 11 万条，dnsmasq-china-list 转换）
files/etc/config/ksmbd                  # ksmbd 共享配置（U 盘挂到 /mnt/sda1 即自动访客可读写共享；同时绑 LAN+ZeroTier）
files/etc/hotplug.d/net/60-ksmbd-zerotier  # ZT 网卡出现时重启 ksmbd（补绑 zt 接口，解决开机时序）
files/etc/hc5962-upgrade.conf           # 升级仓库配置（分享固件给别人时改 REPO 一行）
files/etc/health_sample.sh              # 每 5 分钟记录负载/可用内存到 /tmp/health.log（崩溃取证；cron 由 zz-hc5962-custom 第 10 节挂载）
files/usr/bin/fw-check-update           # 路由器端：检查 GitHub 有无新固件（支持 --json，网页用）
files/usr/bin/fw-upgrade                # 路由器端：下载→校验→试刷→确认→刷入（支持 -y，网页用）
package/luci-app-hc5962-upgrade/        # 网页固件升级页（LuCI → 系统 → 固件升级，仅 full 档位）
```

**网络定制**（由 `zz-hc5962-custom` 在首次启动时写入）：

- LAN IP `192.168.112.200` / 掩码 `255.255.255.0`
- 网关 `192.168.112.1`
- DNS `114.114.114.114`
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
git commit -m "ImmortalWrt 23.05 HC5962 build config"
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

顺带说明：ImmortalWrt 23.05 的 ramips target **没有内置 mtk_hnat 驱动**  
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
- mosdns 负责**按域名名单分流**：国内域名直连国内 DNS（5 家并行取最快），
  国外域名走 socks5 隧道查 8.8.8.8 防污染、隧道不可用时直连兜底

为什么需要 mosdns 而不是让 AGH 直接分流：**AGH 的 upstream 不支持 socks5**，
它没法把查询送进梯子；而「国外域名在隧道内解析」必须由会走 socks5 的 mosdns 补位。

### 已烘焙，刷机即用

mosdns 及其配置**已经烘焙进 full 固件**（`CONFIG_PACKAGE_mosdns=y`），全新刷机后
自动运行，**无需任何手动配置**。仓库里就位的文件：

| 文件 | 作用 |
|---|---|
| `files/etc/mosdns/config.yaml` | v5.3.3 plugins-only 原生格式，监听 5353，定义国内/国外两条分流路径（已用官方 v5.3.3 二进制实跑验证通过） |
| `files/etc/mosdns/cn.txt` | 国内域名名单（约 11 万条，源自 felixonmars/dnsmasq-china-list，每行一个域名） |
| `files/etc/AdGuardHome.yaml` | AGH 烘焙配置：上游只有一行 `127.0.0.1:5353`（mosdns）、4MB 缓存、关乐观缓存 |
| `files/etc/uci-defaults/99-dns-setup` | 首启脚本：dnsmasq 转发 `127.0.0.1#5335` + noresolv、AGH 置 enabled、重启 dnsmasq |

> 为什么不用 geosite.dat：**mosdns v5.3.3 已经移除了 `data_providers`/`servers`
> 顶层键，也不支持 geosite.dat 二进制**（源码里没有 load_dat 插件、没有 v2ray/geosite
> 相关代码）。所以国内名单改用纯文本列表 cn.txt，由 `domain_set` 插件加载——零额外
> 数据包依赖，比 geosite.dat 更可控。

### 分流逻辑（config.yaml 干了什么）

`files/etc/mosdns/config.yaml` 的实际分流：

- **国内域名**（命中 cn.txt）→ `forward_local`：5 家上游并行取最快 ——
  `223.5.5.5`、`119.29.29.29`、`114.114.114.114`（UDP）+ 阿里 DoH `https://dns.alidns.com/dns-query`
  + DNSPod DoH `https://doh.pub/dns-query`
- **国外域名**（未命中）→ 先走 `socks5 127.0.0.1:1080` 隧道查 `8.8.8.8`（防污染）；
  隧道不可用时 `fallback` 兜底：`114.114.114.114` 优先、`1.1.1.1` 次选
  （境外 UDP 直连反正被污染，兜底拿境内可信结果保链路可用）
- **缓存**：mosdns 自带一层 cache（`size: 4096`），兜住 AGH 漏掉的查询

> socks5 端口 `1080` 是 helloworld/ssr+ 的默认本地代理口，如你在 ssr+ 里改过就以界面为准。

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

**分享固件给别人**（比如恩山论坛）：改 `files/etc/hc5962-upgrade.conf` 里的 `REPO` 一行即可
指向你自己的仓库（格式 `用户名/仓库名`），检查/升级脚本和网页页都会跟着走。

### 升级会清掉什么

| 内容 | 升级后 |
|---|---|
| 烘焙进固件的插件（ssr+、AdGuard Home、ZeroTier、vlmcsd 等） | ✅ 升级到新版本 |
| LuCI 里的设置、无线密码、ssr+ 节点配置 | ✅ 保留 |
| iStore / opkg 手动装的插件 | ❌ 清掉，需重装（2026-09 起固件已不带 iStore：官方源砍了 mipsel_24kc 架构 feed，iStore 在本机装不了任何插件，纯占体积） |
| 烘焙配置（AdGuardHome.yaml、mosdns、ksmbd、lan masq 等）及 uci-defaults 已生效的定制 | ✅ 保留（烘焙 + conffiles 机制） |

「长期必用烘焙、偶尔尝鲜走 opkg」分层策略的落点。

---

## 十四、待确认事项

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
