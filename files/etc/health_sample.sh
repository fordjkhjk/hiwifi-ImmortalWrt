#!/bin/sh
#
# 健康采样：每 5 分钟记录 负载 / 可用内存 / RSS 前 3 的进程
#
# 位置: files/etc/health_sample.sh（由 zz-hc5962-custom 挂 cron）
# 输出: /tmp/health.log（内存盘，重启即清空，这是有意为之）
#
# 背景（2026-09-06 实机事故）：
#   路由器发生「可用内存耗尽 → 内核强制回收 → UBI 闪存 I/O 阻塞
#   （大量 kworker 卡 D 状态）→ 全机假死」，负载飙到 31，SSH / LuCI /
#   翻墙全部无响应，只能强制重启。
#   OpenWrt 的 syslog 与 dmesg 都存在内存盘，重启即清空；本机也没有
#   /sys/fs/pstore（内核崩溃日志通道）。也就是说：一旦重启，现场证据
#   100% 丢失，事后无法定性是谁吃掉了内存。
#
# 所以常驻一个极轻量的采样：把趋势写在内存盘，下次崩溃前能看到可用内存
# 是如何一步步掉下去的，从而定位泄漏源。
#
# 设计取舍：
#   - 写 /tmp 而不是闪存：零磨损，不占 overlay 空间，不加剧 UBI 负担
#   - 只记 3 个进程：够定位元凶，又不会让日志膨胀
#   - 超 400KB 自动截断：防止长期不重启把 122MB 内存盘撑满
#

LOG=/tmp/health.log

# 日志超过 400KB 时只保留最后 800 行（约 800*120B ≈ 96KB）
if [ -f "$LOG" ] && [ "$(wc -c < $LOG)" -gt 400000 ]; then
    tail -n 800 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi

AV=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
LOAD=$(cut -d' ' -f1-3 /proc/loadavg)

# RSS 前 3 的进程（只统计 >2MB 的，忽略一堆 1MB 上下的小守护进程）
TOP3=$(for p in $(ls /proc | grep -E '^[0-9]+$'); do
    r=$(grep VmRSS /proc/$p/status 2>/dev/null | awk '{print $2}')
    c=$(cat /proc/$p/comm 2>/dev/null)
    [ -n "$r" ] && [ "$r" -gt 2000 ] && echo "$r:$c"
done | sort -rn | head -3 | tr '\n' ' ')

echo "$(date '+%F %T') load=[$LOAD] avail=${AV}kB top=[$TOP3]" >> "$LOG"

exit 0
