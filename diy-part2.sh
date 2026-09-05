#!/bin/bash
#
# diy-part2.sh —— 在 .config 落地之后、make defconfig 之前执行
#
# 职责：
#   1. 兜底修改固件默认 LAN IP（真正的主力配置在 files/etc/uci-defaults/ 里）
#   2. full 档位摘掉 factory.bin，绕开 32MB 的 check-size
#
# 注意：ImmortalWrt 23.05 的 config_generate 里网络段是变量形式：
#         lan) ipad=${ipaddr:-"192.168.1.1"} ;;
#    所以只能用「替换默认 IP 字面量」的方式改，不能用 set network.lan.ipaddr 去匹配。
#

set -e

CFG="package/base-files/files/bin/config_generate"

if [ -f "$CFG" ]; then
    echo ">> [diy-part2] 修改默认 LAN IP: 192.168.1.1 -> 192.168.112.200"
    sed -i 's/192\.168\.1\.1/192.168.112.200/g' "$CFG"
else
    echo "!! [diy-part2] 未找到 $CFG，跳过 IP 兜底修改"
fi

# 默认主机名（ImmortalWrt 自带 default-settings 会再覆盖一次，uci-defaults 才是最终值）
[ -f package/base-files/files/etc/config/system ] && \
    sed -i "s/option hostname.*/option hostname 'HC5962'/" package/base-files/files/etc/config/system

# !! 关键: 从 GitHub 网页上传的文件默认没有可执行权限，
#    uci-defaults 脚本不可执行 = 不会被运行 = 所有定制全部失效
chmod +x files/etc/uci-defaults/* 2>/dev/null || true
echo ">> [diy-part2] uci-defaults 权限:"
ls -l files/etc/uci-defaults/ 2>/dev/null || true

# ------------------------------------------------------------------
# 修复 ssr+ (helloworld feed) gen_config.lua 的 gRPC 空表 bug
#
# 症状：订阅节点为 trojan/vmess + grpc 传输、且 serviceName 字段缺失时，
#       grpcSettings 表所有键都是 nil → luci.jsonc 把空 Lua 表编码成 []（数组），
#       新版 xray 拒收数组直接退出 → ssr+ 显示「未运行」。
# 修法：serviceName 兜底为空字符串 ""，表非空即编码为 {}（对象），xray 可正常启动。
# 参考：实机定位于 2026-09-05，上游 fw876/helloworld master 同样存在此行。
# ------------------------------------------------------------------
GEN="package/feeds/helloworld/luci-app-ssr-plus/root/usr/share/shadowsocksr/gen_config.lua"
if [ -f "$GEN" ] && grep -q 'and server.serviceName or nil,' "$GEN"; then
    sed -i 's/and server.serviceName or nil,/and server.serviceName or "",/' "$GEN"
    echo ">> [diy-part2] 已修复 ssr+ gen_config.lua 的 gRPC 空表 bug（serviceName 兜底空串）"
else
    echo "!! [diy-part2] 未找到 $GEN 或已无目标行，跳过 gRPC bug 修复"
fi

# ------------------------------------------------------------------
# 体积限制：只卡 factory，不卡 sysupgrade
#
# mt7621.mk 里 HC5962 的定义：
#     IMAGE_SIZE := 32768k
#     IMAGES += factory.bin
#     IMAGE/factory.bin     := append-kernel | pad-to $(KERNEL_SIZE) | append-ubi | check-size
#     IMAGE/sysupgrade.bin  := sysupgrade-tar | append-metadata        ← 来自 Device/nand
#
# 关键点：只有 factory.bin 的 recipe 带 check-size，超过 32MB 会在打包阶段直接失败。
#         sysupgrade.bin 的 recipe 里没有 check-size，编译期不做体积校验。
#
# 那 sysupgrade 的真实上限是多少？看 DTS：
#   ubiconcat0 (0x1c80000 = 28.5MB) + ubiconcat1 (0x5d40000 = 93.25MB)
#   经 mtd-concat 拼成 "ubi" 分区，共 0x79c0000 ≈ 121.75 MB
# 所以 40MB 量级的 sysupgrade 完全装得下。
#
# 结论：
#   minimal ── 内容小，factory + sysupgrade 都产出
#   full    ── 带全协议 ssr+ 必然超 32MB，只保留 sysupgrade.bin
# ------------------------------------------------------------------
MK="target/linux/ramips/image/mt7621.mk"

if [ "${PROFILE:-minimal}" = "full" ]; then
    if [ -f "$MK" ]; then
        sed -i '/^define Device\/hiwifi_hc5962$/,/^endef$/ { /IMAGES += factory\.bin/d }' "$MK"
        echo ">> [diy-part2] full 档位: 已摘掉 factory.bin，只产出 sysupgrade.bin"
        echo ">> [diy-part2] HC5962 段落现状:"
        sed -n '/^define Device\/hiwifi_hc5962$/,/^endef$/p' "$MK"
    else
        echo "!! [diy-part2] 未找到 $MK，无法摘除 factory.bin"
    fi
else
    echo ">> [diy-part2] minimal 档位: 保留 factory.bin，需保证其体积 ≤ 32MB"
fi
