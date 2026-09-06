#!/bin/sh
#
# 健康采样：每 5 分钟记录 负载 / 可用内存 / RSS 前 3 的进程
#
# 位置: files/etc/health_sample.sh（由 zz-hc5962-custom 挂 cron）
# 输出: /tmp/health.log        内存盘，重启清空（主用，零磨损，详细）
#       /root/health-flash.log 闪存，重启保留（崩溃取证用）
#
# 为什么要两份（2026-09-06 实机事故后的修正）：
#   本机曾发生「可用内存耗尽 → 内核回收 → UBI 闪存 I/O 阻塞 → 全机假死」，
#   负载 31、SSH/LuCI/翻墙全断，只能强制重启。而 syslog / dmesg 全在内存盘，
#   重启即清空，本机也无 /sys/fs/pstore —— 只写内存盘的话，崩溃重启后
#   现场证据仍然全丢，事后照样查不出原因。
#   因此同一行内容再往闪存存一份：半夜崩了，第二天开机仍能读到崩溃前
#   最后几条记录，看出可用内存是怎么掉下去的。
#
# 闪存磨损评估：一天 288 行 × 约 120B ≈ 35KB，一年约 12MB，overlay 有 71MB，
# 常规 NAND 寿命下可忽略。
#

LOG=/tmp/health.log
FLASH=/root/health-flash.log

AV=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
LOAD=$(cut -d' ' -f1-3 /proc/loadavg)

# RSS 前 3 的进程（只统计 >2MB 的，忽略一堆 1MB 上下的小守护进程）
TOP3=$(for p in $(ls /proc | grep -E '^[0-9]+$'); do
    r=$(grep VmRSS /proc/$p/status 2>/dev/null | awk '{print $2}')
    c=$(cat /proc/$p/comm 2>/dev/null)
    [ -n "$r" ] && [ "$r" -gt 2000 ] && echo "$r:$c"
done | sort -rn | head -3 | tr '\n' ' ')

LINE="$(date '+%F %T') load=[$LOAD] avail=${AV}kB top=[$TOP3]"

# 内存盘：详细，重启即清
echo "$LINE" >> "$LOG"
if [ -f "$LOG" ] && [ "$(wc -c < $LOG)" -gt 400000 ]; then
    tail -n 800 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi

# 闪存：同一行再存一份，重启不丢（上限 150KB，超出留最后 600 行）
echo "$LINE" >> "$FLASH"
if [ -f "$FLASH" ] && [ "$(wc -c < $FLASH)" -gt 150000 ]; then
    tail -n 600 "$FLASH" > "$FLASH.tmp" && mv "$FLASH.tmp" "$FLASH"
fi

exit 0
