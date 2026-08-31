#
# luci-app-hc5962-upgrade — HC5962 网页固件升级
#
# 功能: 在 LuCI「系统 → 固件升级」页检查 GitHub 仓库是否有新版本，
#       输入确认词后一键在线刷入（下载 → sha256 校验 → 试刷 → 写入）。
#
# 依赖: 固件内置脚本 fw-check-update / fw-upgrade（在 files/usr/bin，随固件打包），
#       本包只提供 LuCI 页面。
#
include $(TOPDIR)/rules.mk

LUCI_TITLE:=HC5962 firmware web upgrade
LUCI_DEPENDS:=+luci-base +curl +jq
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
