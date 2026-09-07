#!/bin/sh
#
# 健康采样：每 5 分钟记录 负载 / 内存明细 / CPU 细分 / D状态进程数 / RSS 前 3
#
# 位置: files/etc/health_sample.sh（由 zz-hc5962-custom 挂 cron）
# 输出: /tmp/health.log         内存盘，重启清空（主用，零磨损）
#       /root/health-flash.log  闪存，重启保留（崩溃取证用）
#       /root/health-alert.log  闪存，仅在异常时写入的「详细现场」
#
# 为什么要两份常规日志（2026-09-06 实机事故后的修正）：
#   本机曾发生「可用内存耗尽 → 内核回收 → UBI 闪存 I/O 阻塞 → 全机假死」，
#   负载 31、SSH/LuCI/翻墙全断，只能强制重启。而 syslog / dmesg 全在内存盘，
#   重启即清空，本机也无 /sys/fs/pstore —— 只写内存盘的话，崩溃重启后
#   现场证据仍然全丢，事后照样查不出原因。因此同一行再往闪存存一份。
#
# 为什么要记 CPU 细分和 D 状态进程数（2026-09-07 补）：
#   事故时 LuCI 显示「CPU 94%」，容易误判成"某个进程算疯了"。但 Linux 的
#   load average 统计的是「可运行 + 不可中断(D状态)」进程数，内存耗尽引发
#   的回收 I/O 会把大批进程卡成 D 状态，于是负载和 CPU 使用率一起飙升，
#   看起来像 CPU 忙，实际是在等 I/O。要分辨二者，必须记录 iowait 和 D 进程数：
#     - iowait 高 + D 进程多   → 卡在 I/O，根源多半是内存回收（内存问题）
#     - user/sys 高 + D 进程少 → 真在算东西（CPU 问题，查是哪个进程）
#
# 为什么要记内存明细（AnonPages / SUnreclaim）：
#   AnonPages  = 用户进程占用的匿名内存，它涨 = 某个进程在泄漏（看 top 是谁）
#   SUnreclaim = 内核不可回收的 slab，它涨 = 内核对象泄漏（conntrack / dentry 等）
#   只记 MemAvailable 看不出是哪种，定位方向完全不同。
#
# 阈值触发的详细现场（health-alert.log）会记录：全量进程 RSS 排名、
# /proc/meminfo 全量、conntrack 数、dmesg 尾部、top 快照、D 状态进程。
#
# 闪存磨损评估：常规行 288 行/天 × 约 180B ≈ 50KB/天，年约 18MB，
# overlay 有 71MB，常规 NAND 寿命下可忽略。告警现场只在异常时写。
#

LOG=/tmp/health.log
FLASH=/root/health-flash.log
ALERT=/root/health-alert.log
CPU_PREV=/tmp/health_cpu_prev

# ---------- 采集 ----------
AV=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
MF=$(grep MemFree /proc/meminfo | awk '{print $2}')
CA=$(grep '^Cached:' /proc/meminfo | awk '{print $2}')
AP=$(grep AnonPages /proc/meminfo | awk '{print $2}')
SU=$(grep SUnreclaim /proc/meminfo | awk '{print $2}')

LOAD=$(cut -d' ' -f1-3 /proc/loadavg)
# 1 分钟负载取整，供阈值比较（busybox sh 不支持小数比较）
LD1=$(echo "$LOAD" | cut -d' ' -f1 | cut -d. -f1)

# CPU 累计 ticks: user nice system idle iowait irq softirq
CPU_LINE=$(head -1 /proc/stat)
set -- $CPU_LINE
CU=$2; CN=$3; CS=$4; CI=$5; CW=$6; CQ=$7; CSQ=$8

# 与上次采样求差，得出这 5 分钟内的 CPU 分布百分比
CPU_TXT="(first)"
if [ -f "$CPU_PREV" ]; then
    set -- $(cat "$CPU_PREV")
    PU=$1; PN=$2; PS=$3; PI=$4; PW=$5; PQ=$6; PSQ=$7
    DU=$((CU - PU)); DN=$((CN - PN)); DS=$((CS - PS))
    DI=$((CI - PI)); DW=$((CW - PW)); DQ=$((CQ - PQ)); DSQ=$((CSQ - PSQ))
    TOT=$((DU + DN + DS + DI + DW + DQ + DSQ))
    if [ "$TOT" -gt 0 ]; then
        PU=$(( (DU + DN) * 100 / TOT ))
        PS=$(( DS * 100 / TOT ))
        PW=$(( DW * 100 / TOT ))
        CPU_TXT="u=${PU}% s=${PS}% io=${PW}%"
    fi
fi
echo "$CU $CN $CS $CI $CW $CQ $CSQ" > "$CPU_PREV"

# D 状态（不可中断，通常卡在 I/O）进程数
DPROC=$(ps | awk 'NR>1 && $4 ~ /D/ {n++} END {print n+0}')

# RSS 前 3 的进程（只看 >2MB 的，忽略一堆 1MB 上下的小守护进程）
TOP3=$(for p in $(ls /proc | grep -E '^[0-9]+$'); do
    r=$(grep VmRSS /proc/$p/status 2>/dev/null | awk '{print $2}')
    c=$(cat /proc/$p/comm 2>/dev/null)
    [ -n "$r" ] && [ "$r" -gt 2000 ] && echo "$r:$c"
done | sort -rn | head -3 | tr '\n' ' ')

LINE="$(date '+%F %T') load=[$LOAD] avail=${AV}kB mem=[free=$MF cached=$CA anon=$AP sunrecl=$SU] cpu=[$CPU_TXT] Dproc=$DPROC top=[$TOP3]"

# ---------- 常规双写 ----------
echo "$LINE" >> "$LOG"
if [ -f "$LOG" ] && [ "$(wc -c < $LOG)" -gt 400000 ]; then
    tail -n 800 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi

echo "$LINE" >> "$FLASH"
if [ -f "$FLASH" ] && [ "$(wc -c < $FLASH)" -gt 150000 ]; then
    tail -n 600 "$FLASH" > "$FLASH.tmp" && mv "$FLASH.tmp" "$FLASH"
fi

# ---------- 异常时抓详细现场 ----------
# 阈值：1分钟负载 >5（正常 0~1，事故时 25~31）
#       或 可用内存 <30MB（正常 50~90，事故时 16）
#       或 D状态进程 >3（正常 0）
HIT=""
[ "$LD1" -gt 5 ] 2>/dev/null && HIT="load"
[ "$AV" -lt 30000 ] 2>/dev/null && HIT="$HIT mem"
[ "$DPROC" -gt 3 ] 2>/dev/null && HIT="$HIT dproc"

if [ -n "$HIT" ]; then
    {
        echo "=============================================="
        echo "!! ALERT $(date '+%F %T')  trigger:$HIT"
        echo "$LINE"
        echo "---- /proc/meminfo ----"
        cat /proc/meminfo
        echo "---- /proc/stat ----"
        head -1 /proc/stat
        echo "---- conntrack ----"
        echo "count=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null) max=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null)"
        echo "---- process RSS top15 ----"
        for p in $(ls /proc | grep -E '^[0-9]+$'); do
            r=$(grep VmRSS /proc/$p/status 2>/dev/null | awk '{print $2}')
            c=$(cat /proc/$p/comm 2>/dev/null)
            [ -n "$r" ] && [ "$r" -gt 1000 ] && echo "$r $c $p"
        done | sort -rn | head -15
        echo "---- D state processes ----"
        ps | awk 'NR==1 || $4 ~ /D/'
        echo "---- top snapshot ----"
        top -n 1 2>/dev/null | head -20
        echo "---- dmesg tail ----"
        dmesg | tail -25
        echo "=============================================="
        echo
    } >> "$ALERT"

    if [ -f "$ALERT" ] && [ "$(wc -c < $ALERT)" -gt 150000 ]; then
        tail -n 900 "$ALERT" > "$ALERT.tmp" && mv "$ALERT.tmp" "$ALERT"
    fi
fi

exit 0
