#!/bin/sh
#
# 健康采样 v1.02：每 5 分钟记录 负载 / 内存明细 / CPU 细分 / D状态进程数 / RSS 前 3
#                 + Xray 资源占用 / DoH 隧道连接数 / br-lan 收发速率
#                 + Xray 单进程内存超限时自动重启（带冷却期）
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
# v1.02 新增（2026-09-08，9/8 01:05 崩溃取证后的补强）：
#   1) 采样行增加 Xray 内存 / fd 数 / DoH 隧道连接数 / br-lan 速率。
#      动机：那次崩溃只能看到「Xray 涨了 40MB」，却无法判断是「流量驱动」
#      还是「连接驱动」——采样里压根没有流量和连接数。补上后下次可直接区分。
#   2) Xray 单进程 RSS 超过 50MB 自动重启 shadowsocksr（30 分钟冷却）。
#      这是不依赖根因的兜底：根因至今未定论，但「Xray 超过 50MB 就会抽干
#      内存」是实测事实，掐掉它就能拦住崩溃链条。
#

LOG=/tmp/health.log
FLASH=/root/health-flash.log
ALERT=/root/health-alert.log
CPU_PREV=/tmp/health_cpu_prev
NET_PREV=/tmp/health_net_prev

# Xray 单进程内存阈值（kB）与重启冷却期（秒）——见文件末尾第 3 节
XRSS_LIMIT=51200
RESTART_COOL=1800
XR_TS=/tmp/health_xray_restart

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

# ---------- Xray 资源占用 ----------
# ssr+ 用的其实是 Xray，进程名显示为 v2ray（/var/etc/ssrplus/bin/v2ray 软链到
# /usr/bin/xray）。它有 TCP / UDP 两个进程，所以阈值必须按「单个进程」判断：
# 两个进程合计基线就 35MB 左右，按合计算离 50MB 太近，会频繁误触发。
XRSS_MAX=0
XRSS_TOT=0
XFD=0
for p in $(ls /proc | grep -E '^[0-9]+$'); do
    c=$(cat /proc/$p/comm 2>/dev/null)
    [ "$c" = "v2ray" ] || continue
    r=$(grep VmRSS /proc/$p/status 2>/dev/null | awk '{print $2}')
    [ -n "$r" ] || continue
    XRSS_TOT=$((XRSS_TOT + r))
    [ "$r" -gt "$XRSS_MAX" ] && XRSS_MAX=$r
    d=$(ls /proc/$p/fd 2>/dev/null | wc -l)
    XFD=$((XFD + d))
done

# DoH 隧道连接数：本机发往 8.8.8.8 / 1.1.1.1 的 443 连接。
# 注意 mosdns → 127.0.0.1:1080 是回环，不进 conntrack（实测 conntrack 里
# 含 127.0.0.1 的仅 7 条），所以只能从 netstat 数出站连接。
DOHC=$(netstat -tn 2>/dev/null | grep -cE '(8\.8\.8\.8|8\.8\.4\.4|1\.1\.1\.1|1\.0\.0\.1):443')

# ---------- br-lan 收发速率 ----------
# 与上次采样求差得出 KB/s。只能用 br-lan：实测 eth0 的 tx 计数已顶到
# 2147483647（2^31-1，32 位计数器上限），拿它算速率会得到负数或假零。
NET_TXT="(first)"
NRX=$(awk '/^ *br-lan:/{print $2}' /proc/net/dev)
NTX=$(awk '/^ *br-lan:/{print $10}' /proc/net/dev)
NOWTS=$(date +%s)
if [ -f "$NET_PREV" ] && [ -n "$NRX" ] && [ -n "$NTX" ]; then
    set -- $(cat "$NET_PREV")
    PRX=$1; PTX=$2; PTS=$3
    DT=$((NOWTS - PTS))
    if [ "$DT" -gt 0 ] && [ "$NRX" -ge "$PRX" ] && [ "$NTX" -ge "$PTX" ]; then
        NET_TXT="rx=$(( (NRX - PRX) / DT / 1024 )) tx=$(( (NTX - PTX) / DT / 1024 ))KB/s"
    fi
fi
[ -n "$NRX" ] && echo "$NRX $NTX $NOWTS" > "$NET_PREV"

# RSS 前 3 的进程（只看 >2MB 的，忽略一堆 1MB 上下的小守护进程）
TOP3=$(for p in $(ls /proc | grep -E '^[0-9]+$'); do
    r=$(grep VmRSS /proc/$p/status 2>/dev/null | awk '{print $2}')
    c=$(cat /proc/$p/comm 2>/dev/null)
    [ -n "$r" ] && [ "$r" -gt 2000 ] && echo "$r:$c"
done | sort -rn | head -3 | tr '\n' ' ')

LINE="$(date '+%F %T') load=[$LOAD] avail=${AV}kB mem=[free=$MF cached=$CA anon=$AP sunrecl=$SU] cpu=[$CPU_TXT] Dproc=$DPROC xray=[max=${XRSS_MAX} tot=${XRSS_TOT}kB fd=$XFD dohconn=$DOHC] net=[$NET_TXT] top=[$TOP3]"

# ---------- 常规双写 ----------
echo "$LINE" >> "$LOG"
if [ -f "$LOG" ] && [ "$(wc -c < $LOG)" -gt 400000 ]; then
    tail -n 800 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi

echo "$LINE" >> "$FLASH"
if [ -f "$FLASH" ] && [ "$(wc -c < $FLASH)" -gt 150000 ]; then
    tail -n 600 "$FLASH" > "$FLASH.tmp" && mv "$FLASH.tmp" "$FLASH"
fi

# ---------- Xray 内存超限自动重启 ----------
# 背景：2026-09-08 01:05 崩溃。Xray 单进程 RSS 5 分钟内从 27MB 涨到 69.8MB，
#   可用内存被抽到 10MB → 内核疯狂回收 → UBI 闪存 I/O 阻塞 → 全机 D 状态假死
#   31 分钟才自愈。暴涨的根因至今没有定论（「DoH 并发导致连接堆积」的假说
#   已被 01:20 的数据推翻：连接数降 62% 时内存一个 KB 没降），但有一点是实测
#   事实：Xray 单进程一旦冲到 70MB，内存必然见底。
#   所以这里做不依赖根因的兜底 —— 超过阈值就掐掉，把崩溃链条拦在半路。
#
# 阈值口径（重要）：按「单个进程」判断，不是两个加起来。
#   实测基线：两进程各 17~20MB（合计约 35MB）；全天最高 39.2MB；崩溃时 69.8MB。
#   50MB（51200kB）既有足够余量避免误触发，又明显早于崩溃水位。
#   若改成按两进程合计判断，35MB 的基线离 50MB 只剩 15MB，会频繁误触发。
#
# 冷却期 1800s：防止内存持续偏高时每 5 分钟重启一次（重启风暴）。
# 代价：翻墙会断约 10 秒（国内网络与 lan2 那台走主路由的设备不受影响）。
if [ "$XRSS_MAX" -gt "$XRSS_LIMIT" ] 2>/dev/null; then
    NOWTS=$(date +%s)
    LAST=0
    [ -f "$XR_TS" ] && LAST=$(cat "$XR_TS")
    {
        echo "=============================================="
        echo "!! XRAY RESTART CHECK $(date '+%F %T')"
        echo "   xray 单进程最大 RSS=${XRSS_MAX}kB  阈值=${XRSS_LIMIT}kB  两进程合计=${XRSS_TOT}kB"
    } >> "$ALERT"
    if [ $((NOWTS - LAST)) -gt "$RESTART_COOL" ]; then
        echo "   冷却期已过（距上次 $((NOWTS - LAST))s），执行 shadowsocksr restart" >> "$ALERT"
        echo "---- 重启前 meminfo ----" >> "$ALERT"
        grep -E 'MemTotal|MemAvailable|MemFree|AnonPages|SUnreclaim' /proc/meminfo >> "$ALERT"
        echo "---- 重启前 RSS top10 ----" >> "$ALERT"
        for p in $(ls /proc | grep -E '^[0-9]+$'); do
            r=$(grep VmRSS /proc/$p/status 2>/dev/null | awk '{print $2}')
            c=$(cat /proc/$p/comm 2>/dev/null)
            [ -n "$r" ] && [ "$r" -gt 1000 ] && echo "$r $c $p"
        done | sort -rn | head -10 >> "$ALERT"
        echo "---- 重启前 DoH 隧道连接数：$DOHC  Xray fd：$XFD ----" >> "$ALERT"
        /etc/init.d/shadowsocksr restart >> "$ALERT" 2>&1
        echo "   restart rc=$?" >> "$ALERT"
        date +%s > "$XR_TS"
    else
        echo "   冷却期内（距上次 $((NOWTS - LAST))s < ${RESTART_COOL}s），本次跳过" >> "$ALERT"
    fi
    echo "==============================================" >> "$ALERT"
    echo >> "$ALERT"
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
