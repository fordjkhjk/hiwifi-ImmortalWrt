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
grep -q "helloworld" feeds.conf.default || \
  echo 'src-git helloworld https://github.com/fw876/helloworld;master' >> feeds.conf.default

grep -q "istore" feeds.conf.default || \
  echo 'src-git istore https://github.com/linkease/istore;main' >> feeds.conf.default

grep -q "adguardhome" feeds.conf.default || \
  echo 'src-git adguardhome https://github.com/rufengsuixing/luci-app-adguardhome;master' >> feeds.conf.default

echo ">> [diy-part1] feeds 确认完毕"
