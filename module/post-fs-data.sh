#!/system/bin/sh
# 开机早期：清理旧版本（v1.x）留下的 pref 15000 规则。
#
# 旧版思路是在 usbN 网卡上加 `ip rule ... pref 15000` 绕过 Android 不认领的问题。
# v2.0 改用"把网卡改名成 eth0 交给 EthernetTracker"的方案后，那条规则完全多余
# 而且可能干扰正常的网络选择，所以升级时清掉。
MODDIR=${0%/*}
PREF=15000

ip -6 rule show 2>/dev/null | grep -E "^${PREF}:" | while read -r line; do
    # lookup 后面可能是数字表号，也可能是接口名（内核会把绑定到接口的表显示成接口名）
    tbl=$(echo "$line" | grep -oE 'lookup [A-Za-z0-9_.-]+' | awk '{print $2}')
    [ -n "$tbl" ] && ip -6 rule del from all lookup "$tbl" pref "$PREF" 2>/dev/null
done
