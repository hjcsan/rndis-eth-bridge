# 快速开始

## 30 秒判断你的问题是否适用本方案

在平板上（需要 root）：

```sh
# 1. 手机插上、开启 USB 网络共享
# 2. 看是否出现了 usbN 网卡
su -c 'ls /sys/class/net/ | grep usb'

# 3. 看 Android 有没有认领任何以太网
su -c 'dumpsys ethernet | grep -E "name filter|Tracking"'
```

三种结果：

| 输出 | 含义 | 下一步 |
|---|---|---|
| 有 `usb0`/`usb1`，`Tracking interfaces: (空)` | ✅ **本模块适用** | 继续往下 |
| 没有 `usb*` 网卡 | 驱动层没绑上 | 见 [内核补丁](../kernel/rndis_vivo_quirk.patch) |
| 有 `usbN` 且已经被 Tracking | Android 已认领 | 不需要本模块，查别的原因 |

---

## 安装

```sh
# 下载 module/rndis_eth_bridge.zip，然后：
adb push rndis_eth_bridge.zip /data/local/tmp/
adb shell 'su -c "magisk --install-module /data/local/tmp/rndis_eth_bridge.zip"'
adb reboot
```

或者在 Magisk App 里：模块 → 从本地安装 → 选 zip → 重启。

---

## 验证

重启后插上手机、开启 USB 网络共享，然后：

```sh
adb shell 'su -c "sh /data/adb/modules/rndis_eth_bridge/action.sh"'
```

期望输出（关键三行）：

```
运行中 (pid 15013)
  eth0  UP  10.195.23.239/24 240e:44d:301:8432:.../64
  ✅ EthernetTracker 已接管 eth0
  ✅ 已注册为 Android 网络（Ethernet CONNECTED）
```

**然后关掉 WiFi，用浏览器试一下。** 这才是最终验证——
见 [为什么不能只看 curl](../README.md#坑-2curl-通--app-能上网)。

---

## 出问题时按这个顺序查

`action.sh` 的输出是按依赖顺序排列的，从上往下看：

| 现象 | 原因 | 处理 |
|---|---|---|
| `未运行` | 守护没起来 | 重启；或 `su -c 'sh /data/adb/modules/rndis_eth_bridge/service.sh'` |
| `(无以太网/USB 网卡)` | 手机没开共享，或驱动没绑上 | 检查手机；查 `dmesg \| grep rndis` |
| 有 `usbN [手机共享(RNDIS)]` 但没 `eth0` | 改名失败 | 看日志有没有 `改名失败（目标名可能已被占用）` |
| 有 `eth0` 但 `❌ EthernetTracker 未接管` | 系统没有以太网服务，或名字不对 | `dumpsys ethernet \| grep "name filter"` |
| `✅ Ethernet CONNECTED` 但 App 无网 | 不是本模块的问题 | 查 DNS、代理 App、防火墙 |
| `IPv4: HTTP 000` | 没有 IPv4 地址 | 等几秒让 DHCP 完成；或 `ip -4 addr show eth0` |

---

## 手动测试（不改任何东西）

想先确认方案有效，可以手动改名试一次：

```sh
# 找到 RNDIS 网卡（路径含 xhci-hcd 的那个）
su -c 'for d in /sys/class/net/usb*; do echo "$d -> $(readlink -f $d)"; done'

# 假设是 usb0，改名
su -c 'ip link set usb0 down && ip link set usb0 name eth0 && ip link set eth0 up'

# 看 Android 有没有接手（应该 1 秒内出现）
su -c 'dumpsys ethernet | grep eth0'

# 关掉 WiFi 试试 App
```

**注意**：不要用 `ip link set eth0 down` 测试，会让手机判定对端断开、
自行关闭 USB 共享，必须物理拔插才能恢复。

---

## 卸载

Magisk → 模块 → 移除 → 重启。

没有残留：不改内核、不改系统分区、不写 sysctl、不装 `.ko`。

---

## 需要重新编译内核的情况

如果 `dmesg` 里有：

```
rndis_host 1-1:1.0: bad CDC descriptors
```

说明驱动层就没绑上，本模块无能为力。需要给内核打补丁：

```sh
cd <kernel>/common
git apply -p1 /path/to/rndis_vivo_quirk.patch
```

并确认配置：

```
CONFIG_USB_NET_DRIVERS=y
CONFIG_USBNET=y
CONFIG_USB_NET_CDCETHER=y
CONFIG_USB_NET_RNDIS_HOST=y
```

详见 [README 的内核侧章节](../README.md#内核侧如果驱动层就绑不上)。
