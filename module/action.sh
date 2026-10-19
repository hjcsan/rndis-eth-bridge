#!/system/bin/sh
# 点模块"操作"按钮：显示当前状态
MODDIR=${0%/*}
echo "===== USB 网络共享状态 ====="
echo
echo "--- 守护进程 ---"
# pid 文件可能失效（重启、手杀），以 /proc 里 cmdline 的精确匹配为准
find_daemon() {
    for p in /proc/[0-9]*; do
        pid=${p#/proc/}
        # /proc 下可能有 /proc/8350_reg 这类非进程目录，必须校验纯数字
        case "$pid" in ''|*[!0-9]*) continue ;; esac
        # 进程可能在遍历时退出，先确认可读再把错误全部吞掉
        [ -r "${p}/cmdline" ] || continue
        cmd=$(cat "${p}/cmdline" 2>/dev/null | tr '\0' ' ' 2>/dev/null)
        [ -z "$cmd" ] && continue
        # 必须【以 sh 开头】且命令行里含守护脚本名，才算守护进程，
        # 否则 `bash -c "...rndis-eth-daemon.sh..."` 这类外层命令也会被误认。
        case "$cmd" in
            sh\ *rndis-eth-daemon.sh*) echo "$pid" ;;
        esac
    done
}
insts=$(find_daemon)
cnt=$(echo "$insts" | grep -c . )
if [ "$cnt" -ge 1 ] 2>/dev/null; then
    echo "运行中 (pid $(echo $insts | tr ' ' ','))"
    [ "$cnt" -gt 1 ] && echo "  ⚠ 检测到 $cnt 个实例，建议重启清理（多实例会重复写日志）"
else
    echo "未运行（改名不会生效，请重启或重新启用模块）"
fi
echo
echo "--- 相关网卡 ---"

show_iface() {
    n=$1
    f=$(cat "/sys/class/net/$n/flags" 2>/dev/null)
    [ -z "$f" ] && return
    case "$f" in 0x*) v=$((f)) ;; *) v=$((0x$f)) ;; esac
    # 只有 IFF_UP(0x1) 会随 down/up 真实翻转；operstate 恒为 unknown，IFF_RUNNING 不会清零
    if [ $((v & 0x1)) -ne 0 ]; then st="UP"; else st="DOWN"; fi
    addr=$(timeout 2 ip -br addr show "$n" 2>/dev/null | sed 's/^[^ ]* *[^ ]* *//')
    echo "  $n  $st"
    [ -n "$addr" ] && echo "      $addr"
}

# 网卡类型判断。两级判据：
#   1) 驱动名（最可靠）：/sys/class/net/X/device/driver -> rndis_host / cdc_ether / r8152 ...
#   2) sysfs 路径（兜底）：读不到驱动名时看是否含 xhci-hcd / gadget
# 不能按名字判断：内核按分配顺序起名，RNDIS 有时是 usb1、有时是 usb0。
# 也不能只看路径：外接 USB 网卡和 RNDIS 一样挂在 xhci-hcd 下，路径区分不开。
which_kind() {
    drv=$(readlink -f "/sys/class/net/$1/device/driver" 2>/dev/null)
    drv=${drv##*/}
    case "$drv" in
        rndis_host)  echo "手机共享(RNDIS)"; return ;;
        cdc_ether)   echo "USB网卡(cdc_ether)"; return ;;
        r8152)       echo "USB网卡(r8152)"; return ;;
        ax88179_178a) echo "USB网卡(ax88179)"; return ;;
    esac
    p=$(readlink -f "/sys/class/net/$1" 2>/dev/null)
    case "$p" in
        *gadget*)   echo "平板自身" ;;
        *xhci-hcd*) echo "USB设备(${drv:-驱动未知})" ;;
        *)          echo "其他" ;;
    esac
}

found=0
for d in /sys/class/net/eth*; do
    [ -e "$d" ] || continue
    n=${d##*/}
    echo "  $n  [$(which_kind "$n")]"
    show_iface "$n"
    found=1
done
for d in /sys/class/net/usb*; do
    [ -e "$d" ] || continue
    n=${d##*/}
    kind=$(which_kind "$n")
    if [ "$kind" = "手机共享(RNDIS)" ]; then
        echo "  $n  [$kind] ← 还没被改名（守护可能未运行）"
        show_iface "$n"
    else
        echo "  $n  [$kind] （无需改名）"
    fi
    found=1
done
[ $found -eq 0 ] && echo "  (无以太网/USB 网卡，手机未连接或未开启共享)"
echo
echo "--- Android 是否认领 ---"
if timeout 5 dumpsys ethernet 2>/dev/null | grep -q "eth0:NetworkInterfaceState{ iface: eth0, up: true"; then
    echo "  ✅ EthernetTracker 已接管 eth0"
    timeout 5 dumpsys connectivity 2>/dev/null \
        | grep -oE 'InterfaceName: eth0 .*' | head -1 \
        | grep -oE 'DnsAddresses: \[ [^]]*\]' | sed 's/^/  DNS: /'
    if timeout 5 dumpsys connectivity 2>/dev/null | grep -q "ni{Ethernet CONNECTED"; then
        echo "  ✅ 已注册为 Android 网络（Ethernet CONNECTED）"
    else
        echo "  ⚠ EthernetTracker 有记录，但 ConnectivityService 尚未注册网络"
    fi
else
    echo "  ❌ EthernetTracker 未接管（eth0 不存在或未 up）"
fi
echo
echo "--- 默认网络 ---"
timeout 5 dumpsys connectivity 2>/dev/null | grep -m1 "Active default network"
echo
echo "--- 连通性（注意：curl 以 root 运行，仅作参考，不代表 App 状态）---"
timeout 8 curl -4 -s -o /dev/null -w "  IPv4: HTTP %{http_code}  %{time_total}s\n" --max-time 6 https://www.baidu.com 2>&1
timeout 8 curl -6 -s -o /dev/null -w "  IPv6: HTTP %{http_code}  %{time_total}s\n" --max-time 6 https://www.baidu.com 2>&1
echo
echo "--- 最近日志 ---"
tail -12 /data/adb/rndis_eth.log 2>/dev/null || echo "  (无日志)"
