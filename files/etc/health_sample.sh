#!/bin/sh
#
# 健康采样 v1.06：每 5 分钟记录 负载 / 内存明细 / CPU 细分 / D状态进程数 / RSS 前 3
#                 + Xray 资源占用 / DoH 隧道连接数 / br-lan 收发速率
#                 + Shmem 与 /tmp 内存盘占用
#                 + Xray 单进程内存超限时自动重启（带冷却期）
#                 + 可用内存持续过低时的专项取证（v1.06 新增，见第 4 节）
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
#      v1.05 起改为双条件：还要求可用内存低于 30MB。详见第 3 节。
#      这是不依赖根因的兜底：根因至今未定论，但「Xray 超过 50MB 就会抽干
#      内存」是实测事实，掐掉它就能拦住崩溃链条。
#
# v1.03 修正（2026-09-08）：进程名改为自动发现，不再硬编码。
#   原本写死匹配 comm="v2ray"。这是「认人靠脸」：只要 ssr+ 换了内核（软链名
#   一变，比如 xray / naive / hysteria），匹配就落空 —— 而它落空时既不报错也
#   不告警，XRSS_MAX 恒为 0，兜底永远不触发，日志看着一切正常。
#   改为每次从 /var/etc/ssrplus/bin/ 读当前内核名再匹配，换内核自动跟着认。
#   另：实测确认本机 comm=v2ray 命中 2 个进程、comm=xray 命中 0 个 —— 写 xray
#   就是标准的静默失效，这正是这次要防的。
#
# v1.04 补强（2026-09-08）：给自动发现加排除名单。
#   查 /etc/init.d/shadowsocksr 的 ln_start_bin 调用点时发现，这个目录不只有代理
#   内核，ssr+ 自启的 DNS / 辅助进程（mosdns、chinadns-ng、dnsproxy、dns2socks、
#   ipt2socks、redsocks2 ...）也在里面留软链。启用 ssr+ 自带 DNS 分流后它们会被
#   一起统计，mosdns 涨到 50MB 就会误判成 Xray 爆了、白重启一次。用排除名单剔掉。
#   注意是「排除」不是「白名单」—— 漏写顶多少统计，不会退回静默失效。
#

LOG=/tmp/health.log
FLASH=/root/health-flash.log
ALERT=/root/health-alert.log
CPU_PREV=/tmp/health_cpu_prev
NET_PREV=/tmp/health_net_prev

# Xray 单进程内存阈值（kB）、可用内存阈值（kB）与重启冷却期（秒）——见文件末尾第 3 节
# 两个阈值是「与」关系，必须同时越线才重启，理由见第 3 节
XRSS_LIMIT=51200
AVAIL_LIMIT=30720
RESTART_COOL=1800
XR_TS=/tmp/health_xray_restart

# 可用内存持续过低阈值（kB）、连续命中次数、计数器文件——见第 4 节
# 25600kB = 25MB，比第 3 节的 30MB 更严；连续 3 次 = 持续 15 分钟
AVAIL_HARD=25600
LOWMEM_N=3
LOWMEM_CT=/tmp/health_lowmem_ct

# ---------- 采集 ----------
AV=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
MF=$(grep MemFree /proc/meminfo | awk '{print $2}')
CA=$(grep '^Cached:' /proc/meminfo | awk '{print $2}')
AP=$(grep AnonPages /proc/meminfo | awk '{print $2}')
SU=$(grep SUnreclaim /proc/meminfo | awk '{print $2}')
SH=$(grep Shmem /proc/meminfo | awk '{print $2}')

# /tmp 是 tmpfs（内存盘）：AGH 的工作目录与查询日志、ssr+ 生成的域名表都在这。
# 它会计入 Cached，但在没有 swap 的机器上**永远无法回收**——涨一兆就少一兆
# 可用内存，重启前不会回落。必须单独记，否则「Cached 看着很高、可用内存却很低」
# 容易被误判成「页缓存而已，紧张时内核会自己丢」。
TP=$(df -k /tmp 2>/dev/null | awk 'NR==2{print $3}')

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
# 【进程名自动发现】ssr+ 把当前在用的内核软链到 /var/etc/ssrplus/bin/<名字>，
# 现在是 bin/v2ray -> /usr/bin/xray（真身是 Xray 24.12.31）。内核记 comm 用的是
# 启动时传进来的路径名、不解析软链接，所以进程名 = 这里的软链名。
#
# 为什么不硬编码 `v2ray`：ssr+ 支持多内核（v2ray / xray / trojan / naive /
# hysteria ...），换内核时软链名跟着变。写死名字的话，一换就匹配不到 ——
# 而且不报错、不告警，XRSS_MAX 恒为 0，保护形同虚设（静默失效）。
# 读目录 = 脚本自己去问「今天谁当班」，换什么内核都自动认得。
#
# 【排除名单】这个目录里不只有代理内核 —— ssr+ 自启的 DNS / 辅助进程也走同一个
# ln_start_bin，一样会在里面留软链（行号见 /etc/init.d/shadowsocksr）：
#   mosdns 326/737 · chinadns-ng 416/826 · dnsproxy 335/382 · dns2tcp 293
#   dns2socks 298/716 · dns2socks-rust 303/719 · microsocks · redsocks2
#   ipt2socks · shadow-tls
# 它们不是代理内核，内存量级跟 Xray 无关。一旦启用 ssr+ 自带的 DNS 分流，这些
# 名字就会混进候选列表，被一起算进 XRSS_MAX —— mosdns 现在就已 14.6MB，它涨到
# 50MB 会被误判成「Xray 爆了」，白白重启一次 shadowsocksr（重启也治不好它）。
#
# 用「排除」而不是「白名单」：将来万一漏写了某个辅助进程的名字，后果只是少统计
# 一个进程，不会退化成 v1.02 那种「名字对不上 → 恒为 0 → 兜底从不触发」的静默失效。
# v1.06 补强（2026-09-10，内存增长元凶排查之后）：
#   1) 常规采样行增加 Shmem 与 /tmp（tmpfs）占用。
#      动机：那次排查的结论是「进程 RSS 全都不涨，唯一只增不减的是内存盘」——
#      AdGuardHome 的工作目录 /var/adguardhome（/var 就是 /tmp）整个在 tmpfs 里，
#      查询日志每天长 5~13MB，而 tmpfs 页在无 swap 时无法回收。这么关键的一项
#      当时却完全没有采样，只能临时部署采集脚本。补上后趋势直接可见。
#   2) 新增「可用内存持续过低」专项取证（第 4 节）。
#      原有的 Xray 兜底只在「Xray 超阈值 + 内存见底」时动作，如果内存是被别的
#      东西吃掉的（tmpfs / 内核 slab / 别的进程），它就全程沉默。补一条按可用
#      内存单独触发的取证，把 /tmp 明细一并钉进现场。
#      注意它只取证、不动作 —— 低内存的成因还没穷举完，贸然自动重启服务
#      既可能掩盖真凶，也会误伤正在用网的人。
EXCLUDE_NAMES="mosdns chinadns-ng dnsproxy dns2tcp dns2socks dns2socks-rust microsocks redsocks2 ipt2socks shadow-tls"
PROXY_NAMES=""
for n in $(ls /var/etc/ssrplus/bin/ 2>/dev/null); do
    case " $EXCLUDE_NAMES " in
        *" $n "*) continue ;;
    esac
    PROXY_NAMES="$PROXY_NAMES $n"
done
PROXY_NAMES=$(echo $PROXY_NAMES)          # 去掉首尾空白（否则拼接后会多出双空格）
# 兜底：/var/etc/ssrplus 是运行时目录，ssr+ 没启用时为空 → 名字列表空 →
# 匹配不到 → 不触发，行为安全（服务没跑本就无需重启）。这里再给个兜底名单，
# 万一整个插件换了（那时这脚本本来也要重配），不至于立刻失效。
[ -z "$PROXY_NAMES" ] && PROXY_NAMES="v2ray xray"

# 它有 TCP / UDP 两个进程，所以阈值必须按「单个进程」判断：
# 两个进程合计基线就 35MB 左右，按合计算离 50MB 太近，会频繁误触发。
XRSS_MAX=0
XRSS_TOT=0
XFD=0
for p in $(ls /proc | grep -E '^[0-9]+$'); do
    c=$(cat /proc/$p/comm 2>/dev/null)
    [ -n "$c" ] || continue                # 读不到名字（内核线程等）不算命中
    # 名字在候选列表里才算命中（两侧补空格，避免子串误匹配：v2ray 不会误配 v2rayx）
    case " $PROXY_NAMES " in
        *" $c "*) ;;
        *) continue ;;
    esac
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

LINE="$(date '+%F %T') load=[$LOAD] avail=${AV}kB mem=[free=$MF cached=$CA anon=$AP sunrecl=$SU shmem=$SH tmpfs=$TP] cpu=[$CPU_TXT] Dproc=$DPROC xray=[max=${XRSS_MAX} tot=${XRSS_TOT}kB fd=$XFD dohconn=$DOHC] net=[$NET_TXT] top=[$TOP3]"

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
# 阈值口径（重要）：按「单个进程」判断，不是几个加起来。
#   实测基线：单进程 17~20MB；全天最高 39.2MB；崩溃时 69.8MB。
#   50MB（51200kB）既有足够余量避免误触发，又明显早于崩溃水位。
#
# 为什么要加「可用内存」这第二个条件（2026-09-09 改，两条件是「与」关系）：
#   Xray 的内存是流量驱动的收发缓冲区，看高清视频时单进程冲到 42~44MB 属于
#   正常现象且能自愈。只按 50MB 单个条件判断，会在系统其实还很宽裕时白重启
#   一次 —— 实测 2026-09-08 21:47 就是 Xray 44.5MB、可用 41.8MB，重启纯属误伤。
#   真正危险的是「Xray 涨」和「系统见底」同时发生，所以要求两条线都越界。
#   用真实事件校准：9/8 崩溃时 Xray 69.8MB + 可用 10MB，两条都过线，照样拦得住；
#   9/8 21:47 看视频 Xray 44.5MB + 可用 41.8MB，两条都不过线，正确放过。
#
# 冷却期 1800s：防止内存持续偏高时每 5 分钟重启一次（重启风暴）。
# 代价：翻墙会断约 10 秒（国内网络与 lan2 那台走主路由的设备不受影响）。
if [ "$XRSS_MAX" -gt "$XRSS_LIMIT" ] 2>/dev/null && [ "$AV" -lt "$AVAIL_LIMIT" ] 2>/dev/null; then
    NOWTS=$(date +%s)
    LAST=0
    [ -f "$XR_TS" ] && LAST=$(cat "$XR_TS")
    {
        echo "=============================================="
        echo "!! XRAY RESTART CHECK $(date '+%F %T')"
        echo "   xray 单进程最大 RSS=${XRSS_MAX}kB  阈值=${XRSS_LIMIT}kB  合计=${XRSS_TOT}kB"
        echo "   可用内存=${AV}kB  阈值=${AVAIL_LIMIT}kB  （两项须同时越线才重启）"
        echo "   匹配到的进程名=[$PROXY_NAMES]（自动发现，非硬编码）"
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

# ---------- 可用内存持续过低：专项取证 ----------
# 背景（2026-09-10 内存增长元凶排查的结论）：
#   本机 244MB、无 swap。排查结果是「每个进程的 RSS 都稳、甚至往下走，
#   唯一只增不减的是 /tmp 这个内存盘」——AdGuardHome 的工作目录
#   /var/adguardhome（OpenWrt 上 /var 就是 /tmp）整个泡在 tmpfs 里，
#   查询日志 querylog.json 每天长 5~13MB，而 tmpfs 页在没有 swap 时
#   无法换出也无法回收。按这个速度，距每周三 04:00 重启还有 6 天时，
#   可用内存就会从 52MB 掉到 23MB（低于 25MB 危险线）。
#
# 与第 3 节 Xray 兜底的分工：
#   第 3 节是「动作」——条件满足就重启 shadowsocksr，因为已实测确认
#   「Xray 单进程冲到 70MB 必然抽干内存」，掐掉它能拦住崩溃链条。
#   本节是「取证」——不自动做任何事。低内存的成因没有穷举完（tmpfs 只是
#   已确认的其中一个），此时自动重启别的服务，既可能掩盖真凶，也会误伤
#   正在用网的人。这里只负责把现场钉死，等人来判断。
#
# 为什么要求「连续 N 次」而不是一次命中就报：
#   看高清视频时 Xray 的收发缓冲区膨胀会把可用内存短暂压到 25MB 以下
#   （实测 2026-09-10 09:32 一次流量突发就压到 37MB，10 分钟内自愈）。
#   单次命中基本都是这种误报；连续 3 次 = 持续 15 分钟，才说明真的下不来。
#
# 为什么现场里要记 /tmp 明细：
#   2026-09-10 那次排查，为了拿到「/tmp 里到底是谁在涨」不得不临时部署
#   采集脚本跑一天。把这条信息直接写进告警现场，下次不用再临时装东西。
if [ "$AV" -lt "$AVAIL_HARD" ] 2>/dev/null; then
    N=0
    [ -f "$LOWMEM_CT" ] && N=$(cat "$LOWMEM_CT")
    N=$((N + 1))
    echo "$N" > "$LOWMEM_CT"
    if [ "$N" -ge "$LOWMEM_N" ]; then
        echo "0" > "$LOWMEM_CT"          # 归零重新计数：之后最多每 15 分钟报一次
        if [ "$XRSS_MAX" -gt "$XRSS_LIMIT" ] 2>/dev/null; then
            XVERDICT="超阈值(${XRSS_MAX}kB > ${XRSS_LIMIT}kB)，Xray 是主要嫌疑"
        else
            XVERDICT="未超阈值(${XRSS_MAX}kB <= ${XRSS_LIMIT}kB)，Xray 不是主因，优先查 tmpfs / 内核 slab"
        fi
        {
            echo "=============================================="
            echo "!! LOWMEM $(date '+%F %T')  可用内存连续 ${LOWMEM_N} 次低于 $((AVAIL_HARD / 1024))MB（约 $((LOWMEM_N * 5)) 分钟）"
            echo "$LINE"
            echo "---- Xray 是否背锅 ----"
            echo "   $XVERDICT"
            echo "---- 内存盘 /tmp（tmpfs，无 swap 时不可回收）----"
            df -k /tmp 2>/dev/null
            echo "---- /tmp 各目录占用 top10 ----"
            du -sk /tmp/* 2>/dev/null | sort -rn | head -10
            echo "---- AGH 工作目录 /var/adguardhome/data ----"
            ls -l /var/adguardhome/data/ 2>/dev/null
            echo "---- meminfo 关键项 ----"
            grep -E 'MemTotal|MemAvailable|MemFree|AnonPages|SUnreclaim|Slab|Shmem|Cached' /proc/meminfo
            echo "---- process RSS top10 ----"
            for p in $(ls /proc | grep -E '^[0-9]+$'); do
                r=$(grep VmRSS /proc/$p/status 2>/dev/null | awk '{print $2}')
                c=$(cat /proc/$p/comm 2>/dev/null)
                [ -n "$r" ] && [ "$r" -gt 1000 ] && echo "$r $c $p"
            done | sort -rn | head -10
            echo "=============================================="
            echo
        } >> "$ALERT"

        if [ -f "$ALERT" ] && [ "$(wc -c < $ALERT)" -gt 150000 ]; then
            tail -n 900 "$ALERT" > "$ALERT.tmp" && mv "$ALERT.tmp" "$ALERT"
        fi
    fi
else
    echo "0" > "$LOWMEM_CT"               # 恢复正常就清零，下次重新累计
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
