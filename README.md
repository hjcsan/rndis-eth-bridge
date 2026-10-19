# rndis-eth-bridge

> 让 Android 真正认领手机 USB 网络共享（RNDIS），App 得以正常上网。
>
> 一个 Magisk 模块 + 一份完整的逆向分析记录。

## 目录

- [问题：USB 共享了，App 还是没网](#问题usb-共享了app-还是没网)
- [根因：Android 只认 `eth\d`](#根因android-只认-ethd)
- [原理：改名为什么能解决一切](#原理改名为什么能解决一切)
- [证据链](#证据链)
- [影响范围与副作用](#影响范围与副作用)
- [功能清单](#功能清单)
- [安装与使用](#安装与使用)
- [内核侧：如果驱动层就绑不上](#内核侧如果驱动层就绑不上)
- [踩过的坑（重要）](#踩过的坑重要)
- [实测数据](#实测数据)
- [仓库结构](#仓库结构)
- [兼容性说明](#兼容性说明)
- [参考](#参考)

---

## 问题：USB 共享了，App 还是没网

手机（测试机为 iQOO 12，USB ID `2d95:600a`）插上平板，开启「USB 网络共享」后，平板上：

| 层面 | 现象 |
|---|---|
| 内核层 | 网卡已创建，RX/TX 计数正常增长 |
| shell 层 | `ping` / `curl` **可以通** |
| **App 层** | **浏览器、微信全部显示「无网络」** |
| Android 框架 | `dumpsys connectivity` 里**根本没有这张网卡对应的网络** |

关键矛盾：**root shell 能上网，App 不能**。

这不是 DNS 问题，不是防火墙问题，不是运营商问题。这是 Android 的网络管理框架**根本没有接纳这张网卡**。

---

## 根因：Android 只认 `eth\d`

决定性证据来自一条几乎没人注意的输出：

```console
$ dumpsys ethernet
Ethernet State: enabled
Ethernet interface name filter: eth\d      ← 这一行
EthernetNetworkFactory
Tracking interfaces: (空)                   ← 所以这里永远是空的
```

Android 的 `EthernetTracker` 有一个**硬编码的网卡名过滤器 `eth\d`**。内核把 RNDIS 网卡创建成 `usb0` 或 `usb1`，名字对不上，于是：

```
内核创建 usbN
    ↓
EthernetTracker 检查名字 → 不匹配 eth\d → 忽略
    ↓
没有 NetworkAgent 注册进 ConnectivityService
    ↓
没有 IpClient / DHCP 客户端被启动
    ↓
拿不到 IPv4 地址、拿不到 DNS、拿不到 Android 层默认路由
    ↓
ConnectivityManager 认为「无网络」
    ↓
所有 App 遵循框架选择 → 全部显示离线
        （而 root shell 走内核路由，所以照样能通）
```

**为什么 root shell 能通？** 因为 `ping` 和 `curl` 直接用内核路由表 + libc 的 `getaddrinfo`，完全绕过了 `ConnectivityManager` 和 `netd` 的网络选择逻辑。这是整个排查中最致命的陷阱——见[坑 2](#坑-2curl-通--app-能上网)。

---

## 原理：改名为什么能解决一切

把网卡名字改成 `eth0`，就满足了那个正则。剩下的事 Android 全自动完成：

```sh
ip link set usb0 down
ip link set usb0 name eth0
ip link set eth0 up
```

改名会触发 netlink 的 `DELLINK` + `NEWLINK` 事件。`EthernetTracker` 收到 `NEWLINK` 时检查名字，匹配置信后立刻：

```
EthernetTracker 接受 eth0
    ↓
创建 EthernetNetworkAgent → 注册进 ConnectivityService
    ↓
创建 IpClientManager → 启动 DHCP 客户端
    ↓
DHCP 拿到 IPv4（10.195.23.x/24）
RA  拿到 IPv6（240e:.../64 + fe80::/64）
    ↓
自动配置 DNS（10.195.23.3 与 240e:...::xx）
    ↓
自动安装 0.0.0.0/0 与 ::/0 默认路由
    ↓
网络标记 VALIDATED，Android 自动切换默认网络
    ↓
App 正常上网
```

**全程不需要任何 `ip rule`、不需要手动配 DNS、不需要静态路由。**

这也纠正了一个流传很广的误解：很多教程说「手机 USB 共享只给 IPv6，要手动加 IPv6 路由规则」。真相是——**手机是双栈的，只是没人跑 DHCP 客户端去要 IPv4**。网卡一旦被 Android 认领，`IpClient` 立刻把 IPv4 要回来了。

---

## 证据链

### 1. 名字不匹配时，Android 完全无视

```console
$ ip -br link show usb0
usb0  DOWN  6e:29:e0:a9:98:6c

$ dumpsys ethernet
Tracking interfaces: (空)
```

### 2. 改名后立刻被接管

```console
$ ip link set usb0 down && ip link set usb0 name eth0 && ip link set eth0 up

$ dumpsys ethernet
  eth0:NetworkInterfaceState{ iface: eth0, up: true
    Transports: ETHERNET
    Capabilities: NOT_METERED&INTERNET&NOT_RESTRICTED&TRUSTED&NOT_VPN&VALIDATED&...
    networkAgent: EthernetNetworkAgent
    ipClient:     IpClientManager
    LinkAddresses: [ 10.195.23.239/24, fe80::..., 240e:44d:301:8432:... ]
    DnsAddresses: [ /240e:44d:301:8432::60, /10.195.23.3 ]
    Routes: [ ::/0 -> fe80::..., 0.0.0.0/0 -> 10.195.23.3 ] }

$ dumpsys connectivity
Active default network: 102
network{102}  ni{Ethernet CONNECTED}
```

`NetworkAgent`、`IpClientManager`、地址、DNS、默认路由、`VALIDATED`
——**全部由 Android 自己配好了**。

### 3. `ip rule` 方案是多余的（实测证伪）

v1.x 版本曾手动加 `ip rule` 把流量导进内核已建好的路由表：

```console
$ ip -6 rule add from all lookup 1044 pref 15000
$ ping6 2400:3200::1            # 通
$ curl -6 https://www.baidu.com # HTTP 200
```

**但 App 依然没网。** 改名成功后删掉这条规则：

```console
$ ip -6 rule del from all lookup 1044 pref 15000
$ curl -4 https://www.baidu.com  # HTTP 200
$ curl -6 https://www.baidu.com  # HTTP 200
```

**一切照旧。** 证明 `EthernetTracker` 自己装了默认路由，那条规则纯属多余。

---

## 影响范围与副作用

诚实评估这个模块做了什么、会影响什么。

### 影响面（范围）

| 维度 | 影响 |
|---|---|
| **作用对象** | 仅修改**一张网卡的名称**，从 `usbN` 改为 `eth0` |
| **网络命名空间** | 仅 Android 主命名空间（`/proc/1/ns/net`） |
| **进程** | 常驻一个 shell 守护进程，实测 CPU **0.0467%** |
| **内存** | 一个 `sh` 进程，约 2 MB 常驻 |
| **内核态改动** | **无**。模块不碰内核、不加载 .ko、不写 sysctl |
| **SELinux** | **无**。不需要 `setenforce 0`，不需要额外策略 |
| **系统分区** | **无**。Magisk 模块，卸载即完全还原 |
| **其他网卡** | **不动**。只看 `usb*` 且 sysfs 路径含 `xhci-hcd` 的 |
| **路由表** | **不手动改**。路由/DNS/默认网络全由 Android 自己配 |
| **IPv4 配置** | 不干预，交由 `IpClient` 跑 DHCP |
| **IPv6 配置** | 不干预，交由内核处理 RA |

### 副作用与风险

| 风险 | 说明 | 缓解 |
|---|---|---|
| **`eth0` 名字冲突** | 若平板同时插了**真正的 USB 以太网卡**，或系统已有 `eth0`，改名会失败 | 日志记录 `改名失败（目标名可能已被占用）`，源网卡保持原状可用。此时需改 `TARGET` 变量 |
| **`EthernetTracker` 僵尸条目** | 反复改名会在 `dumpsys ethernet` 留下 `eth9: up: false` 之类的记录 | 无害。但**不要手动折腾名字**，`eth0` 是唯一正确目标 |
| **误伤平板自身 gadget** | 平板作为 USB 从设备时也有 `usb0`（路径含 `gadget.0`） | 已按 sysfs 路径排除，见[坑 1](#坑-1usb0-不一定是手机共享的网卡) |
| **WiFi 优先级的竞争** | 改名后 Ethernet 会参与网络评分。实测 `Active default network` 会切到 Ethernet（因 `IS_UNMETERED` 且 `VALIDATED`） | 这是**期望行为**——USB 共享通常比手机热点更省电、更稳定。若不希望，可断开 USB |
| **与代理类 App 的交互** | Clash/VPN 类 App 会以 VPN 形式接管流量，此时 Ethernet 只作为底层链路 | 无影响，属正常协作 |
| **Android 版本差异** | `eth\d` 过滤器是 AOSP 实现细节，不同 ROM 可能不同 | 见[兼容性说明](#兼容性说明) |

### 明确**不做**的事

- ❌ 不修改内核、不编译模块、不需要重新刷内核
- ❌ 不修改 `netd` / `ConnectivityService` / 任何系统 APK
- ❌ 不改 `iptables` / `nftables`
- ❌ 不设置 `net.ipv4.ip_forward`
- ❌ 不做 NAT、不做桥接、不做 DHCP 服务端
- ❌ 不碰 WiFi、不碰移动数据

**它只做一件事：改个名字。** 剩下的全部交给 Android 原生机制。

---

## 功能清单

### 模块本体

| 文件 | 功能 |
|---|---|
| `module.prop` | Magisk 模块描述（v2.3） |
| `post-fs-data.sh` | 开机早期清理 v1.x 遗留的 `pref 15000` 规则 |
| `service.sh` | 等 `sys.boot_completed` 后拉起守护；单实例保护 |
| `rndis-eth-daemon.sh` | **核心**：常驻守护，识别 RNDIS 网卡并改名为 `eth0` |
| `action.sh` | 模块「操作」按钮：状态诊断面板 |

### `action.sh` 诊断面板输出

```
===== USB 网络共享状态 =====

--- 守护进程 ---
运行中 (pid 15013)

--- 相关网卡 ---
  eth0  [手机共享(RNDIS)]
  eth0  UP
      10.195.23.239/24 240e:44d:301:8432:a64f:.../64 fe80::8445:.../64

--- Android 是否认领 ---
  ✅ EthernetTracker 已接管 eth0
  DNS: DnsAddresses: [ /240e:44d:301:8432::60,/10.195.23.3 ]
  ✅ 已注册为 Android 网络（Ethernet CONNECTED）

--- 默认网络 ---
Active default network: 102

--- 连通性（注意：curl 以 root 运行，仅作参考，不代表 App 状态）---
  IPv4: HTTP 200  0.241178s
  IPv6: HTTP 200  0.233564s

--- 最近日志 ---
10-19 03:03:13 === 守护启动 ===
10-19 03:03:16 守护已启动 pid=15013（启动器 15013）
10-19 03:03:23 把 usb0 改名为 eth0
```

**按这个面板的顺序看，就能定位问题在哪一层**：

1. 守护不在 → 重启
2. 网卡没出现 → 手机没开共享，或内核 USB 驱动没绑上（见[内核侧](#内核侧如果驱动层就绑不上)）
3. 有 `usbN` 但没 `eth0` → 改名失败（名字被占）
4. 有 `eth0` 但 `EthernetTracker 未接管` → 名字不对，或系统无以太网服务
5. `Ethernet CONNECTED` 但 App 无网 → 问题不在本模块（查 DNS/代理/防火墙）

### 守护工作循环

```
每 5 秒（无网卡时 10 秒）一轮：

  eth0 已存在？
    ├─ 是 → 确保它 up（IFF_UP 位），结束
    └─ 否 → 扫描 /sys/class/net/usb*
              ├─ 路径含 xhci-hcd？→ down → rename eth0 → up
              └─ 路径含 gadget？  → 跳过（平板自身）
```

**幂等**：改名完成后基本什么都不做，只是每 5 秒读一个 sysfs 文件确认 `eth0` 还在。

**自动修复**：若系统把名字重置回 `usbN`（重启网络栈时常见），守护会在 5 秒内改回。

### 诊断脚本 `diagnostics/diag.sh`

在 Termux 的 `su` 里执行，输出 10 个章节的完整状态：

`su -c 'sh /data/local/tmp/diag.sh'`

覆盖：接口存在性、基本信息、强制 up、12 秒包统计、自动获取的地址/邻居/路由、
IPv6 RA 参数、IPv4 参数、主动触发 ARP/RS、丢包计数、完整路由表。

支持用 `IF=usb1` 指定接口名（默认 `usb1`）。

---

## 安装与使用

### 前置条件

- Android 设备已 Root（Magisk / KernelSU / APatch）
- 手机支持 USB 网络共享（RNDIS）
- **内核侧 RNDIS 驱动可用**（见下一节；部分 vivo/iQOO 机型需要内核补丁）

### 安装

```sh
# 方式 1：Magisk App 里刷入
#   下载 module/rndis_eth_bridge.zip → Magisk → 模块 → 从本地安装

# 方式 2：命令行
adb push rndis_eth_bridge.zip /data/local/tmp/
adb shell 'su -c "magisk --install-module /data/local/tmp/rndis_eth_bridge.zip"'
adb reboot
```

### 打包（从源码目录）

```sh
cd module
zip -r ../rndis_eth_bridge.zip module.prop post-fs-data.sh service.sh \
                          rndis-eth-daemon.sh action.sh README.md
```

### 验证

重启后插上手机、开启 USB 网络共享，然后在 Magisk 里点模块的「操作」按钮，
或直接执行：

```sh
adb shell 'su -c "sh /data/adb/modules/rndis_eth_bridge/action.sh"'
```

期望看到 `✅ EthernetTracker 已接管 eth0` 与 `✅ 已注册为 Android 网络`。

### 卸载

Magisk 里移除模块并重启。**没有任何残留**——不改内核、不改系统分区。

---

## 内核侧：如果驱动层就绑不上

本模块解决的是「网卡已经创建，但 Android 不认领」。
如果连网卡都没被创建，属于**内核驱动层**问题，模块无能为力。

典型症状（`dmesg`）：

```console
rndis_host 1-1:1.0: bad CDC descriptors
```

这是因为 vivo/iQOO 机型（`2d95:600a`、`2d95:6012`）的 CDC Union 描述符中
`wTotalLength` 覆盖范围有缺陷，`usbnet_generic_cdc_bind()` 解析失败后落到
`bad_desc` 分支，RNDIS 数据接口 never get claimed，`usb0` 网卡不会创建。

**解决方案**：给内核打补丁，让这两个 USB ID 走硬编码接口号路径。
仓库内提供 `kernel/rndis_vivo_quirk.patch`（针对 `android14-6.1`）：

```diff
+	if (le16_to_cpu(dev->udev->descriptor.idVendor) == 0x2d95 &&
+	    (le16_to_cpu(dev->udev->descriptor.idProduct) == 0x600a ||
+	     le16_to_cpu(dev->udev->descriptor.idProduct) == 0x6012))
+		vivo_rndis_quirk = true;
```

应用方式：

```sh
cd <kernel>/common
git apply -p1 /path/to/rndis_vivo_quirk.patch
```

同时需要确保配置里 RNDIS 是**内置**而非模块（`=y`）：

```
CONFIG_USB_NET_DRIVERS=y
CONFIG_USBNET=y
CONFIG_USB_NET_CDCETHER=y
CONFIG_USB_NET_RNDIS_HOST=y
```

> **为什么必须 `=y`？** 设备 vendor 在开机早期就加载了 `cdc_ether.ko`/`usbnet.ko`，
> 引用计数非零，无法 `rmmod`。模块形式顶不掉已加载的内核模块，所以必须编进 vmlinux。

验证补丁生效：

```sh
adb shell 'su -c "dmesg | grep -i vivo"'
# 期望：vivo RNDIS quirk: forcing hard-wired interfaces 0/1
```

---

## 踩过的坑（重要）

这一节是整个项目最有价值的部分。每一个坑都花了数小时。

### 坑 1：`usb0` 不一定是手机共享的网卡

早期版本观察到 `usb0` 是平板自身作为 USB 从设备时的 gadget 网卡，
于是在代码里**写死了跳过 `usb0`**。

**这是错的。**

内核按分配顺序给网卡起名，同一台设备会出现两种结果：

```
手机共享的 RNDIS  ：.../a600000.ssusb/a600000.dwc3/xhci-hcd.4.auto/usb1/1-1/1-1:1.0/net/usb0
平板自身的 gadget ：.../a600000.ssusb/a600000.dwc3/gadget.0/net/usb0
```

**名字一模一样，路径完全不同。** 实测中 RNDIS 有时是 `usb1`、有时是 `usb0`。
跳过 `usb0` 会导致「插上手机毫无反应」。

**正确做法**：按 sysfs 路径判断。

```sh
p=$(readlink -f /sys/class/net/usb0)
case "$p" in
    *xhci-hcd*) # RNDIS，需要改名
    *gadget*)   # 平板自身，跳过
esac
```

> ⚠️ 路径判据只是**第一步**，它区分不了「手机 RNDIS」和「外接 USB 网卡」，
> 且循环不 `break` 时会挑错对象 —— 见下面的坑 10。v2.4 起改用**驱动名**做最终判据。

### 坑 2：`curl` 通 ≠ App 能上网

这是**最致命**的陷阱。`curl` 以 root 运行时走内核路由，不受 Android 框架约束：

| 使用方 | 走哪条路 | 结果 |
|---|---|---|
| `ping` / `curl` / shell | 内核路由 + libc `getaddrinfo` | ✅ 通 |
| 浏览器、微信、任何 App | `ConnectivityManager` + `DnsResolver` → **netd** | ❌ 认为没网 |

**正确验证方式**：看两个东西

```sh
dumpsys connectivity | grep "Active default network"   # 是不是它
dumpsys ethernet     | grep "VALIDATED"                # 有没有验证通过
```

只有 **`Active default network` 指向它** 且 **`Capabilities` 含 `VALIDATED`**，
App 才算真能上网。

### 坑 3：`ip rule` 方案是死路

v1.x 版本增加了 `ip rule ... pref 15000`，把流量导进内核已建好的路由表。

**这确实能让 `ping` 和 `curl` 通，但永远无法让 App 上网**——`netd` 只认有过
`NetworkAgent` 注册的网络，内核层的策略路由骗不过框架层。

**教训：在内核层绕过，不等于应用层可用。**

### 坑 4：判断网卡 up 状态，`operstate` 和 `IFF_RUNNING` 都不可靠

| 信号 | 实测行为 | 能用吗 |
|---|---|---|
| `operstate` | RNDIS 无链路检测，**恒为 `unknown`** | ❌ 永远等不到 "up" |
| `IFF_RUNNING` (`0x1000`) | 网卡 down 后**仍然保持置位** | ❌ 无法反映真实状态 |
| **`IFF_UP` (`0x1`)** | down=`0x1002`、up=`0x1003`，**真实翻转** | ✅ **唯一可靠** |

```sh
f=$(cat /sys/class/net/eth0/flags)
case "$f" in 0x*) v=$((f)) ;; *) v=$((0x$f)) ;; esac
[ $((v & 0x1)) -eq 0 ] && ip link set eth0 up
```

另：`IFF_LOWER_UP`(`0x10000`) 在 `ip link` 输出里可见，但**不在 sysfs `flags` 里**。

### 坑 5：取进程 PID 的三种方式全不可靠

`service.sh` 拉起守护后用 `$!` 记录 PID，结果 `action.sh` 一直误报「未运行」。
实测三种取法：

| 取值方式 | 结果 |
|---|---|
| `$!`（父进程拿到的后台 PID） | 启动器的 PID，脚本不是它执行的 |
| `$$`（脚本内） | `sh` 解析完脚本会再 fork 子进程执行，但 `$$` 仍继承父值 |
| `/proc/self/stat` 第一字段 | 临时子进程，退出即失效 |

**最终方案：不信任何单一来源。** 遍历 `/proc/<pid>/cmdline`，
要求命令行**以 `sh ` 开头**且**含 `rndis-eth-daemon.sh`**，以此作为唯一判据。
`eth.pid` 只当缓存，显示状态时同样走匹配函数，所以即使 PID 文件失效也不会误报。

三个细节：

- `for p in /proc/[0-9]*` 会匹配到 `/proc/8350_reg` 这类**非进程目录**，
  必须校验 `pid` 是纯数字，否则报 `can't open .../cmdline`
- 只按脚本名匹配不够：`bash -c "sh .../rndis-eth-daemon.sh"` 这种外层命令行
  也含脚本名，会被误认。加上 `sh ` 前缀才能排除
- 遍历 `/proc` 时进程可能正在退出，先 `[ -r "${p}/cmdline" ]` 判断再读

### 坑 6：进程泄漏

`service.sh` 原来的清理逻辑只看 PID 文件，一份失效就漏杀，
**导致多个守护进程同时运行**、重复改名、日志重复写入。

现在按 `/proc/*/cmdline` 匹配杀干净（先 `kill` 再 `kill -9`）。

### 坑 7：别用 `ip link set eth0 down` 测试

会让手机判定对端断开、**自行关闭 USB 共享**，必须物理拔插才能恢复。

### 坑 8：写入真 NUL 字节

用 Python 生成代码时，`'\0'` 被写成了真正的 NUL 字节（`0x00`），
导致 `tr` 命令完全失效。

**这个 bug 极隐蔽**：`bash -n` 不报错，但运行行为完全错误。

检查方法：

```sh
python3 -c "
for f in ['action.sh','service.sh']:
    b=open(f,'rb').read()
    print(f, 'NUL:', b.count(bytes([0])))
"
```

### 坑 9：Android `sh` 语法限制

- toybox 的 `sh` **不支持** `$(( ))` 里乘除混合写法，需改用 `awk`
- `sleep 0.2` 在部分版本不支持小数，需 `sleep 0.2 2>/dev/null || sleep 1`
- `/system/bin/timeout` 可用（不是 GNU coreutils 版）

### 坑 10：路径判据分不清「手机」和「USB 网卡」，且循环不 `break` 会挑错对象

坑 1 的结论是「按 sysfs 路径判断」，但这条路**只能排除平板自身的 gadget**，
排除不了别的 USB 网络设备。v2.3 及更早的代码是：

```sh
for d in /sys/class/net/usb*; do
    p=$(readlink -f "$d")
    case "$p" in
        *xhci-hcd*) src=${d##*/} ;;   # ← 每次匹配都覆盖，没有 break
    esac
done
```

两个缺陷叠加：

1. **外接 USB 网卡也走 xHCI**，路径同样含 `xhci-hcd`，判据无法区分。
2. **没有 `break`**：多个网卡都匹配时，`src` 被最后一个覆盖。

实测构造 `usb0 = rndis_host`（手机）、`usb1 = cdc_ether`（USB 网卡）：

```
旧逻辑选中: usb1  ← 去改 USB 网卡，手机反而漏掉 ❌
新逻辑选中: usb0  ← 正确命中手机 ✅
```

**正确做法：看驱动名。** `usbnet_probe()` 里的
`SET_NETDEV_DEV(net, &udev->dev)` 把 netdev 挂到 USB 接口下，
所以 `/sys/class/net/<if>/device/driver` 一定可读（实测 `wlan0` 同理指向 `cnss_pci`）：

```sh
drv=$(readlink -f "$d/device/driver" 2>/dev/null); drv=${drv##*/}
[ "$drv" = "rndis_host" ] || continue    # 只认 RNDIS，别的一概不碰
src=${d##*/}; break                      # 第一个命中就停
```

各驱动的名字来源（内核 `v6.1` 源码，便于自查）：

| 驱动 | 初始名字 | 原因 |
|---|---|---|
| `rndis_host`（手机共享） | `usb%d` | `FLAG_ETHER\|FLAG_POINTTOPOINT`，且 vivo 的 MAC 首字节 `0x02` 位恒置（本地管理） |
| `cdc_ether`（USB 网卡） | `usb%d` → `eth%d` | 同上 flags，但 MAC 是全局唯一 OUI，`0x02` 位清零 → 改 `eth%d` |
| `ax88179_178a`（USB 网卡） | `eth%d` | `FLAG_ETHER` 但**无** `FLAG_POINTTOPOINT` |
| `r8152`（USB 网卡） | `eth%d` | 不走 `usbnet_probe`，直接 `alloc_etherdev()`（默认模板就是 `eth%d`） |

> 顺带解释了一个现象：**别的厂商手机插上就能用，vivo 不行。**
> 如果固件用的是真实 OUI（`0x02` 位清零），内核会直接把它命名成 `eth0`，
> Android 原生认领，根本不需要这个模块。vivo 用随机本地 MAC，才卡在 `usbN`。

---

## 实测数据

### 性能

| 项目 | 数值 |
|---|---|
| CPU 占用 | **0.0467%**（107 秒耗 0.05 秒 CPU） |
| 内存 | 一个 `sh` 进程，约 2 MB |
| 空转轮询 | 10 秒/轮（无网卡时） |
| 工作轮询 | 5 秒/轮（有网卡时） |
| 日志 | 稳态 2 行；超 500 行自动截断保留 200 行 |
| 改名耗时 | 5–7 秒内（含轮询间隔） |

对比 v1.x 的 `ip rule` 方案：待机 0.0795%、连机 0.26%（每轮 fork 3 个 `ip` 进程）。
**v2.x 的 CPU 占用约降低 5.6 倍**，因为不再需要频繁 fork `ip` 子进程。

### 已验证场景

| 场景 | 结果 |
|---|---|
| 自动改名（RNDIS 命名为 `usb1`） | ✅ 1 秒内，DHCP 拿到 `10.195.23.211/24` |
| 自动改名（RNDIS 命名为 `usb0`） | ✅ 5 秒内，拿到 `10.195.23.220/24` |
| **开机自启** | ✅ 重启后 7 秒内完成 `usb0 → eth0`，全程无人工干预 |
| **名字被系统重置后自动修复** | ✅ 5 秒内改回 |
| Android 接管 | ✅ `EthernetTracker`、`NetworkAgent`、`IpClientManager` 全部就位 |
| IPv4 + IPv6 双通 | ✅ `curl -4` 与 `curl -6` 均 HTTP 200 |
| **App 实测（连 WiFi）** | ✅ 正常 |
| **App 实测（关 WiFi）** | ✅ **依然正常**——证明走的是 USB 而非 WiFi |
| 单实例保护 | ✅ 连续启动 3 次，始终只有 1 个守护进程 |
| 重启后直连 | ✅ USB 网段地址 `10.195.23.239` 可直接 `adb connect` |

### 测试环境

| 项 | 值 |
|---|---|
| 设备 | 一加平板 Pro（OPD2404，SM8650 / Pineapple） |
| 系统 | Android 16（LineageOS 系自定义，KDE/Wayland 桌面模式） |
| 内核 | `6.1.141-Hjc_new`（自编译，带 RNDIS quirk 补丁） |
| Root | Magisk |
| 手机 | iQOO 12（`2d95:600a` RNDIS 模式） |
| Android 网络服务 | `EthernetTracker`，过滤器 `eth\d` |

---

## 仓库结构

```
rndis-eth-bridge/
├── README.md                      # 本文档
├── module/                        # Magisk 模块源码
│   ├── module.prop
│   ├── post-fs-data.sh
│   ├── service.sh
│   ├── rndis-eth-daemon.sh        # 核心守护
│   └── action.sh                  # 诊断面板
├── diagnostics/
│   └── diag.sh                    # 独立诊断脚本（10 章节）
├── kernel/
│   └── rndis_vivo_quirk.patch     # vivo/iQOO CDC 描述符补丁
└── archive/                       # 历史版本归档
    ├── rndis-ipv6-guard-v1.1.sh   # v1.x：ip rule 方案（已被证伪）
    └── README-v1.1.md
```

### 版本演进

| 版本 | 方案 | 结局 |
|---|---|---|
| v1.0 | 固定 3 秒轮询 + 加 `ip rule` | ✅ shell 通 / ❌ App 不通 |
| v1.1 | 自适应轮询 + 动态发现路由表号 | ✅ shell 通 / ❌ App 不通 |
| v2.0 | **改名成 `eth0`** | ⚠️ 方向对，但排除逻辑写死跳过 `usb0` |
| v2.1 | 按 sysfs 路径识别 RNDIS | ✅ **App 可以上网** |
| v2.2 | 修 PID 记录 + 单实例保护 | ✅ 状态显示正确 |
| v2.3 | 修 `/proc` 遍历报错刷屏 + NUL 字节 | ✅ 当前版本 |

---

## 兼容性说明

### 可能适用

任何 **RNDIS 网卡被 Android 忽略** 的场景：

- 手机 USB 网络共享（Android 手机 → Android 平板/车机）
- 部分 4G/5G USB 上网卡（若其驱动走 `rndis_host`）
- 部分开发板/树莓派以 RNDIS gadget 模式接入

### 关键前提

`EthernetTracker` 的过滤器必须是 `eth\d`。验证方法：

```sh
adb shell 'dumpsys ethernet | grep "name filter"'
```

- 输出 `eth\d` → 本模块直接适用
- 输出其他模式（如 `usb\d`、`rndis\d`）→ 需修改 `module/rndis-eth-daemon.sh` 里的 `TARGET`
- 无此行输出 → 该系统可能没有以太网服务，本方案不适用

### 已知不适用

- **手机侧是 IPv6-only 且不响应 RA**（极罕见）——本模块不解决
- **内核 CDC 驱动绑不上**——需先打 `kernel/rndis_vivo_quirk.patch`
- **系统无 `EthernetTracker`**（部分深度定制 ROM 移除）——本模块无效
- **非 RNDIS 协议**（ECM/NCM 且 Android 已正常识别）——不需要本模块

---

## 参考

### Android 源码

- `frameworks/opt/net/ethernet/java/com/android/server/ethernet/EthernetTracker.java`
  —— 网卡名过滤器 `eth\d` 与状态跟踪
- `frameworks/opt/net/ethernet/java/com/android/server/ethernet/EthernetNetworkAgent.java`
  —— 网络注册
- `packages/modules/NetworkStack/` —— `IpClientManager`、DHCP 客户端

### 内核

- `drivers/net/usb/rndis_host.c` —— `generic_rndis_bind()`：RNDIS 初始化、MAC 获取、包过滤器
- `drivers/net/usb/cdc_ether.c` —— `usbnet_generic_cdc_bind()`：
  CDC Union/Descriptor 解析，`bad CDC descriptors` 报错出处
- `drivers/net/usb/usbnet.c` —— `usbnet_probe()`、`register_netdev()`

### 相关项目

- [EVDI](https://github.com/DisplayLink/evdi) —— 虚拟显示器（同类「内核能力暴露给用户态」思路）
- [Anland](https://github.com/) —— Android Wayland Host，容器桌面显示方案

---

## License

MIT

## 作者

hjcsan

---

> **一句话总结**：Android 用一条硬编码正则 `eth\d` 筛选以太网卡，
> 而手机 USB 共享创建的是 `usbN`。改个名字，Android 就把 DHCP、DNS、
> 默认路由全部自动配好了。整个模块只做这一件事。
