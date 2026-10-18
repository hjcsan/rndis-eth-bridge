#!/system/bin/sh
# RNDIS 以太网桥接守护
#
# 为什么需要这个模块：
#   iQOO 12 等手机的 USB 网络共享会创建一个 RNDIS 网卡。Android 的 rndis_host 驱动
#   把它命名为 usbN（如 usb1），但 Android 的 EthernetTracker 只认名字匹配 eth\d 的网卡
#   （实测 `dumpsys ethernet` 显示 "Ethernet interface name filter: eth\d"）。
#   名字对不上 → EthernetTracker 不接 → 没有 NetworkAgent、没有 DHCP、没有 DNS，
#   于是 App 层看到的就是"无网络"，尽管内核路由其实可能是通的。
#
#   把网卡改名为 eth0 后，EthernetTracker 立刻接手：
#     - 创建 EthernetNetworkAgent，注册进 ConnectivityService
#     - IpClientManager 跑起 DHCP，同时拿到 IPv4 和 IPv6 地址
#     - 自动配置 DNS（如 10.195.23.3 与 240e:...::a0）
#     - 自动安装 0.0.0.0/0 和 ::/0 默认路由
#   全程不需要我们手动加任何 ip rule —— 实测删掉 pref 15000 规则后依然 HTTP 200。
#
#   所以本模块只做一件事：把 usb* 网卡改名成 eth0。
#
# 注意：
#   usb0 是平板自身作为 USB 从设备时的 gadget 网卡（路径含 gadget.0），与手机共享无关，跳过。

LOG=/data/adb/rndis_eth.log
TARGET=eth0
# 守护自己写 PID：由父进程用 $! 记录是不可靠的（拿到的是启动器 PID，
# sh 解析脚本时会再 fork 一个子进程真正执行，两者不是同一个进程）。
PIDFILE=${0%/*}/eth.pid
# 日志超过这个行数就截断，防止长期运行无限增长
LOG_MAX=500
# 空闲轮询间隔（秒）：没有 usb 网卡时几乎不耗 CPU
IDLE_SLEEP=10
# 发现 usb 网卡后的轮询间隔（秒）：改名完成后就没什么事了，慢一点
BUSY_SLEEP=5

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

# 网卡是否已 up：读 sysfs 的 IFF_UP(0x1)。
# 不能用 operstate —— RNDIS 的 operstate 恒为 "unknown"，永远等不到 "up"。
# 不能用 IFF_RUNNING(0x1000) —— 实测网卡 down 后它仍保持置位。
up_check() {
    f=$(cat "/sys/class/net/$1/flags" 2>/dev/null)
    [ -z "$f" ] && return 1
    case "$f" in
        0x*) v=$((f)) ;;
        *)   v=$((0x$f)) ;;
    esac
    [ $((v & 0x1)) -ne 0 ]
}

apply_once() {
    # 返回 0 表示本轮发现了 usb 网卡（用于选择下一轮的间隔）

    # 如果 eth0 已经存在，说明改名已经完成，什么也不用做。
    if [ -e /sys/class/net/$TARGET ]; then
        up_check "$TARGET" || timeout 2 ip link set "$TARGET" up 2>/dev/null
        return 1
    fi

    # 找需要改名的网卡。
    #
    # 注意：只能按 sysfs 路径判断，不能按网卡名字判断！
    # 内核按分配顺序给网卡起名 usb0/usb1，同一个手机有时是 usb1、有时是 usb0：
    #   手机共享的 RNDIS  ：.../a600000.ssusb/a600000.dwc3/xhci-hcd.4.auto/usb1/1-1/1-1:1.0/net/usbN
    #   平板自身的 gadget：.../a600000.ssusb/a600000.dwc3/gadget.0/net/usbN
    # 早期版本简单地跳过 usb0，结果在 RNDIS 恰好被命名成 usb0 时完全不动作（实测踩到）。
    src=""
    for d in /sys/class/net/usb*; do
        [ -e "$d" ] || continue
        p=$(readlink -f "$d" 2>/dev/null)
        # 只改 RNDIS（走 xHCI 主机控制器来的），跳过平板自身 gadget
        case "$p" in
            *xhci-hcd*) src=${d##*/} ;;
        esac
    done
    [ -z "$src" ] && return 1

    # 改名必须满足两个条件：网卡 down 着、目标名没被占。
    # 顺序：down -> rename -> up。改名本身会触发 netlink 的 DELLINK+NEWLINK，
    # EthernetTracker 收到 NEWLINK 时会检查名字，匹配 eth\d 才会接手。
    timeout 2 ip link set "$src" down 2>/dev/null
    if timeout 3 ip link set "$src" name "$TARGET" 2>/dev/null; then
        log "把 $src 改名为 $TARGET"
        timeout 2 ip link set "$TARGET" up 2>/dev/null
        # up 之后 EthernetTracker 会自动跑 DHCP 并注册网络，无需干预
        return 0
    fi

    # 改名失败（例如目标名已被占用）：把源网卡拉起来，至少保持原样可用
    log "改名 $src -> $TARGET 失败（目标名可能已被占用）"
    timeout 2 ip link set "$src" up 2>/dev/null
    return 0
}

log "=== 守护启动 ==="
# 由守护自己写 PID。注意三种取 PID 的方式可靠性不同（实测）：
#   $!            → 启动器 PID，脚本不是它执行的，错
#   $$            → sh 解析完脚本后 fork 子进程真正执行，但 $$ 仍继承父值，也错
#   /proc/self/stat 第一字段 → 真实执行进程，唯一可靠
mypid=$(awk '{print $1}' /proc/self/stat 2>/dev/null)
if [ -z "$mypid" ]; then
    mypid=$$
fi
echo "$mypid" > "$PIDFILE" 2>/dev/null

# 清理：如果上次遗留了非 eth0 的 ethXXX，可能导致 EthernetTracker 里留僵尸记录。
# 这里只做提示，不主动改名，避免误伤真正的外接以太网卡。
for d in /sys/class/net/eth*; do
    [ -e "$d" ] || continue
    n=${d##*/}
    [ "$n" = "$TARGET" ] && continue
    log "注意：存在额外的以太网接口 $n"
done

tick=0
while true; do
    if apply_once; then
        cur_sleep=$BUSY_SLEEP
    else
        cur_sleep=$IDLE_SLEEP
    fi

    tick=$((tick + 1))
    [ $((tick % 100)) -eq 0 ] && trim_log

    sleep "$cur_sleep"
done
