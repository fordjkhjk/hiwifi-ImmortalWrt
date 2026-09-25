#!/bin/bash
#
# diy-part1.sh —— 在 feeds update 之前执行
# 本工程的 feeds 源全部写在仓库根目录的 feeds.conf.default 里，
# workflow 会自动把它覆盖到 openwrt/feeds.conf.default，所以这里
# 只做一些「不能靠静态文件完成」的兜底与提示。
#

set -e

echo ">> [diy-part1] 当前 feeds.conf.default 内容:"
cat feeds.conf.default

# 保险起见：确认自定义源确实写进去了（防止 workflow 没覆盖 feeds 文件）
# 注意：这里刻意不写 ";分支" —— 不写才会跟随 helloworld 的默认分支。
# 曾经写死 ";master"，结果 master 于 2026-07-11 停更后，ssr+ 长期拿不到
# 上游更新（实机 opkg 里 luci-app-ssr-plus 停在 190-3 即为此故）。
grep -q "helloworld" feeds.conf.default || \
  echo 'src-git helloworld https://github.com/fw876/helloworld' >> feeds.conf.default

# luci-app-adguardhome（AdGuard Home 的 LuCI 管理页，社区版）
# 这个仓库的 Makefile 在仓库根目录，是标准的「package 目录布局」——必须直接
# 放进源码树的 package/ 下让编译器看到，不能注册成 feed（feed 扫描只认子
# 目录里的包，根目录 Makefile 会被静默忽略，实测已踩过这个坑）。
# AGH 核心仍来自官方 packages 源的 net/adguardhome，这里只是 LuCI 界面。
# 中文界面已内置在包里（安装时由 po2lmo 现场编译 zh-cn 翻译），无需 i18n 包。
if [ ! -d package/luci-app-adguardhome ]; then
  git clone --depth 1 https://github.com/rufengsuixing/luci-app-adguardhome package/luci-app-adguardhome
fi

echo ">> [diy-part1] feeds 确认完毕"
