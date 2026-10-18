#!/system/bin/sh
# RNDIS IPv6 路由守护：为手机 USB 共享创建的 usbX 网卡补上 Android 缺失的 ip rule
#
# 背景：iQOO 12 等 vivo 机型的 USB 网络共享是 IPv6-only（固件层面无 IPv4 tethering）。
#       内核收到 RA 后会把默认路由装进该网卡专属的 table（如 1040/1041，每次重连都变），
#       但 Android netd 不认领这张网卡，不会生成指向该 table 的 ip rule，
#       结果所有 IPv6 流量走完规则后落到 "32000: unreachable"。
#       本脚本动态发现 table 号并补上 rule，网卡消失/重连时自动跟进。
#
# 设计要点：
#   - 不轮询到底：空闲时退避到 15 秒一轮，检测到网卡出现才回到 2 秒快扫
#   - 规则只加给"有默认路由"的表，网卡一消失立刻撤销，不留垃圾
#   - 只认 pref 15000 这一条自己的规则，不碰系统和其他模块的规则

LOG=/data/adb/rndis-ipv6-guard.log
PREF=15000
# 旧版曾硬编码 1038，启动时清理掉以免指向错误的表
STALE_TABLES="1038"
# 日志超过这个行数就截断，防止长期运行无限增长
LOG_MAX=500

log() {
    echo "$(date '+%m-%d %H:%M:%S') $*" >> "$LOG"
}

# 日志轮转：超过上限只保留最后 200 行
trim_log() {
    [ -f "$LOG" ] || return 0
    lines=$(wc -l < "$LOG" 2>/dev/null)
    [ -z "$lines" ] && return 0
    if [ "$lines" -gt "$LOG_MAX" ]; then
        tail -200 "$LOG" > "$LOG.tmp" 2>/dev/null && mv -f "$LOG.tmp" "$LOG"
        log "(日志已轮转)"
    fi
}

# 找出某网卡当前使用的 ipv6 路由表号
table_of() {
    timeout 3 ip -6 route show table all 2>/dev/null \
        | grep "dev $1 " \
        | grep -oE 'table [0-9]+' \
        | awk '{print $2}' | sort -u | head -1
}

# 当前 sysfs 里存在的 usb* 网卡（usb0 是平板自身 gadget，排除在外）
usb_ifs() {
    for d in /sys/class/net/usb*; do
        [ -e "$d" ] || continue
        n=${d##*/}
        [ "$n" = "usb0" ] && continue
        echo "$n"
    done
}

# 已生效的规则表号（只匹配本脚本 pref 号下的规则）
active_tables() {
    timeout 3 ip -6 rule show 2>/dev/null | grep -E "^${PREF}:" \
        | grep -oE 'lookup [0-9]+' | awk '{print $2}'
}

apply_once() {
    # 返回 0 表示"检测到网卡"，用于决定下一轮间隔
    found=0
    want=""

    for i in $(usb_ifs); do
        found=1
        # 网卡存在就拉起：Android 不会自动把 usb1 up，
        # 不 up 就收不到 RA，也就永远没有路由表。这一步是必需的。
        #
        # 判断依据必须读 sysfs 的 IFF_UP 标志位，不能用 operstate 或 ip link：
        #   - operstate 恒为 "unknown"（RNDIS 无链路检测，永远等不到 "up"），
        #     用它判断会导致每轮重复 set up、日志无限膨胀。
        #   - IFF_RUNNING(0x1000) 在网卡 down 后仍保持置位，不能用。
        #   - ip link 要 fork 一次进程，每轮都跑开销明显。
        # 实测只有 IFF_UP(0x1) 会随 down/up 真实翻转：down=0x1002，up=0x1003。
        _f=$(cat "/sys/class/net/$i/flags" 2>/dev/null)
        case "$_f" in
            0x*) _v=$((_f)) ;;
            *)   _v=$((0x$_f)) ;;
        esac
        if [ $((_v & 0x1)) -eq 0 ]; then
            timeout 2 ip link set "$i" up 2>/dev/null && log "拉起网卡 $i"
        fi
        t=$(table_of "$i")
        [ -z "$t" ] && continue
        # 表里必须有 default 路由，否则加了规则也没意义
        timeout 3 ip -6 route show table "$t" 2>/dev/null | grep -q '^default' || continue
        want="$want $t"
    done

    have=$(active_tables)

    # 补：需要的表里还没有规则的
    for t in $want; do
        echo "$have" | grep -qx "$t" && continue
        ip -6 rule add from all lookup "$t" pref "$PREF" 2>/dev/null \
            && log "为 table $t 添加规则 (pref $PREF)"
    done

    # 撤：有规则但对应的表已无默认路由（网卡消失或 RA 过期）
    for t in $have; do
        echo "$want" | tr ' ' '\n' | grep -qx "$t" && continue
        ip -6 rule del from all lookup "$t" pref "$PREF" 2>/dev/null \
            && log "撤掉失效规则 table $t"
    done

    [ "$found" -eq 1 ]
}

log "=== 守护启动 ==="
# 清掉旧版硬编码表留下的规则
for st in $STALE_TABLES; do
    ip -6 rule del from all lookup "$st" pref "$PREF" 2>/dev/null && log "清理旧规则 table $st"
done

# 自适应间隔：有 usb 网卡时 2 秒快扫，没有时退避到 15 秒
# 这样拔掉手机后几乎不耗 CPU，插上后 15 秒内一定能发现（实际通常 3 秒内）
idle_sleep=15
busy_sleep=5
cur_sleep=$idle_sleep
tick=0

while true; do
    if apply_once; then
        # 有网卡：快扫
        cur_sleep=$busy_sleep
    else
        # 没网卡：退避
        cur_sleep=$idle_sleep
    fi

    # 每 100 轮做一次日志轮转检查
    tick=$((tick + 1))
    [ $((tick % 100)) -eq 0 ] && trim_log

    sleep "$cur_sleep"
done
