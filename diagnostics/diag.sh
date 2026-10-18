#!/system/bin/sh
# RNDIS 网络共享诊断脚本 —— 在 Termux 的 su 环境里执行
# 用法: su -c 'sh /data/local/tmp/diag.sh'

IF="${IF:-usb1}"
D="/sys/class/net/$IF"

hr() { echo "================================================================"; }
sec() { echo; echo ">>> $*"; }

hr
echo " RNDIS 诊断报告  接口=$IF  时间=$(date)"
hr

sec "1. 接口是否存在于本命名空间"
if [ -d "$D" ]; then
  echo "  OK: $D"
else
  echo "  FAIL: 本命名空间没有 $IF"
  echo "  现有网卡:"
  for n in /sys/class/net/*; do echo "    $(basename $n)"; done
  exit 1
fi

sec "2. 基本信息"
echo "  link/ether : $(cat $D/address 2>/dev/null)"
echo "  operstate  : $(cat $D/operstate 2>/dev/null)"
echo "  carrier    : $(cat $D/carrier 2>/dev/null || echo 'n/a')"
echo "  speed      : $(cat $D/speed 2>/dev/null || echo 'n/a')"
echo "  mtu        : $(cat $D/mtu 2>/dev/null)"
echo "  路径       : $(readlink -f $D)"

sec "3. 强制 up 并清空地址（从零开始）"
ip link set "$IF" up 2>&1
ip addr flush dev "$IF" scope global 2>&1
ip -6 route flush dev "$IF" 2>&1
sleep 1
ip -br addr show "$IF" 2>&1

sec "4. 静默监听 12 秒，统计收到的包类型"
r0=$(cat $D/statistics/rx_packets)
t0=$(cat $D/statistics/tx_packets)
b0=$(cat $D/statistics/rx_bytes)
sleep 12
r1=$(cat $D/statistics/rx_packets)
t1=$(cat $D/statistics/tx_packets)
b1=$(cat $D/statistics/rx_bytes)
echo "  12 秒内: rx_packets +$((r1-r0))   tx_packets +$((t1-t0))   rx_bytes +$((b1-b0))"
echo "  累计:    rx=$r1 tx=$t1"

sec "5. 12 秒后自动出现的东西"
echo "  --- IPv6 地址 ---"
ip -6 addr show "$IF" 2>&1 | grep -E "inet6|inet " || echo "    (无)"
echo "  --- IPv4 地址 ---"
ip -4 addr show "$IF" 2>&1 | grep -E "inet " || echo "    (无)"
echo "  --- IPv6 邻居(含 RA 源) ---"
ip -6 neigh show dev "$IF" 2>&1 || echo "    (空)"
echo "  --- IPv4 邻居(ARP) ---"
ip -4 neigh show dev "$IF" 2>&1 || echo "    (空)"
echo "  --- 该设备的 IPv6 路由 ---"
ip -6 route show dev "$IF" 2>&1 || echo "    (空)"

sec "6. IPv6 accept_ra / forwarding"
for k in accept_ra accept_ra_defrtr accept_ra_pinfo accept_ra_rtr_pref forwarding disable_ipv6; do
  v=$(cat /proc/sys/net/ipv6/conf/$IF/$k 2>/dev/null || echo "n/a")
  echo "  $k = $v"
done

sec "7. IPv4 关键参数"
echo "  arp_filter   = $(cat /proc/sys/net/ipv4/conf/$IF/arp_filter 2>/dev/null || echo n/a)"
echo "  rp_filter    = $(cat /proc/sys/net/ipv4/conf/$IF/rp_filter 2>/dev/null || echo n/a)"
echo "  forwarding   = $(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)"

sec "8. 试一试主动发 ARP/RS 后看邻居表"
# 主动触发一次 RS，逼手机回 RA
ip -6 addr add fe80::1/64 dev "$IF" 2>/dev/null
sleep 1
ip -6 addr del fe80::1/64 dev "$IF" 2>/dev/null
sleep 3
echo "  --- 触发后 IPv6 邻居 ---"
ip -6 neigh show dev "$IF" 2>&1 || echo "    (空)"
echo "  --- 触发后编号 ---"
r2=$(cat $D/statistics/rx_packets); echo "  rx_packets 现在 = $r2 (相对第4步 +$((r2-r1)))"

sec "9. 丢包与错误计数"
for k in rx_errors rx_dropped tx_errors tx_dropped rx_frame_errors rx_length_errors rx_missed_errors collisions; do
  v=$(cat $D/statistics/$k 2>/dev/null || echo n/a)
  echo "  $k = $v"
done

sec "10. 当前完整路由表"
echo "  --- IPv4 ---"; ip -4 route show 2>&1
echo "  --- IPv6 ---"; ip -6 route show 2>&1

hr
echo " 报告结束"
hr
