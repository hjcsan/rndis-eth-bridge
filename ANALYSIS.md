# 技术分析：Android 为什么看不见你的 USB 网卡

本文是 [`README.md`](README.md) 的深度补充，记录完整的技术推理链条、被证伪的假设，
以及每一步的实验证据。

---

## 1. 问题的本质

先把问题定准。用户报告的现象是「USB 网络共享开了，但 App 没网」。
这句话可以拆成四个互相独立的层次：

```
① 物理层   USB 枚举是否成功？设备是否被识别？
② 驱动层   内核是否创建了网卡？驱动是否绑定成功？
③ 网络栈层 网卡是否 up？是否有地址、路由、邻居？
④ 框架层   Android 的 ConnectivityService 是否接纳这张网卡？
```

**这四个层次任意一层断了，用户看到的都是同一句话：「没网」。**

绝大多数排障教程直接从 ③ 开始查（配 IP、加路由、改 DNS），
但如果断在 ④，前三层怎么修都没用——因为 App 根本不看内核路由表。

本项目最终定位在 ④。下面按层次复盘。

---

## 2. 逐层排查

### 2.1 物理层：枚举正常

```console
$ lsusb
Bus 001 Device 005: ID 2d95:600a vivo iQOO 12

$ ls /sys/bus/usb/devices/1-1/
2d95:600a  bConfigurationValue  idProduct  ...
```

设备已枚举，`idVendor=0x2d95`（vivo）、`idProduct=0x600a`。

**vivo 机型的 USB 模式是互斥单选的**，两个模式对应两个 PID：

| PID | 模式 | 接口布局 | 能否 USB 共享 |
|---|---|---|---|
| `2d95:6012` | MTP / 文件传输 | `1:0` class=06/01/01 + `1:1` class=08/06/50 | ❌ |
| `2d95:600a` | RNDIS | `1:0` class=e0/01/03 + `1:1` class=0a/00/00 | ✅ |

用户界面上对应「反向充电」开关：

- **开启反向充电** → `6012`，手机给平板供电 + 可访问平板文件，**但 USB 共享被禁用**
- **关闭反向充电** → `600a`，**USB 共享可用**，但手机不从平板取电

这是固件层面的硬性互斥，不是 bug。要 USB 共享就必须接受这个取舍。

### 2.2 驱动层：曾经断裂过（已修复）

第一轮排查时 `dmesg` 里有这条：

```console
rndis_host 1-1:1.0: bad CDC descriptors
```

且 `usbnet_generic_cdc_bind()` 走到 `bad_desc` 分支，数据接口 `1-1:1.1` 未绑定，
`usb0` 网卡根本没有被创建。

**根因**：vivo 的 CDC Union 描述符里 `bMasterInterface0`/`bSlaveInterface0` 指向接口 0/1，
但配置的 `wTotalLength` 覆盖范围不足以让通用 CDC 解析器确信数据接口存在，
于是通用路径放弃。而 IAD 声称只有两个接口、接口 0 是 `e0/01/03`（标准 RNDIS），
布局与标准 RNDIS 逐字节一致。

**修复**：给内核打 `kernel/rndis_vivo_quirk.patch`，让这两个 PID 直接走
硬编码接口号路径（和 Android 的 `android_rndis_quirk` 兜底分支同款做法）：

```c
if (le16_to_cpu(dev->udev->descriptor.idVendor) == 0x2d95 &&
    (le16_to_cpu(dev->udev->descriptor.idProduct) == 0x600a ||
     le16_to_cpu(dev->udev->descriptor.idProduct) == 0x6012))
	vivo_rndis_quirk = true;
```

同时四个配置项必须是 **`=y`** 而非 `=m`：

```
CONFIG_USB_NET_DRIVERS=y
CONFIG_USBNET=y
CONFIG_USB_NET_CDCETHER=y
CONFIG_USB_NET_RNDIS_HOST=y
```

> **为什么必须内置？** 实测设备 vendor 在开机早期就加载了 `cdc_ether.ko`/`usbnet.ko`
> （引用计数 3/8，`rmmod` 报 `Resource temporarily unavailable`）。
> 模块形式顶不掉已加载的内核模块，只能编进 vmlinux。

打补丁后 `dmesg` 变成：

```console
rndis_host 1-1:1.0: vivo RNDIS quirk: forcing hard-wired interfaces 0/1
rndis_host 1-1:1.0 usb1: register 'rndis_host' at usb-xhci-hcd.4.auto-1, RNDIS device, 6e:29:e0:a9:98:6c
```

`bad CDC descriptors` 消失，网卡被创建。

**这一层修复后，问题依然存在。** 这就把矛头指向了 ④。

### 2.3 网络栈层：看起来一切正常

```console
$ ip -br addr show usb1
usb1  UP  6e:29:e0:a9:98:6c
      fe80::.../64, 240e:44d:301:8432:.../64

$ ip -6 route show table all | grep usb1
240e:44d:301:8432::/64 dev usb1 proto kernel metric 256
fe80::/64 dev usb1 proto kernel metric 256
default via fe80::... dev usb1 proto ra metric 1024 ... hoplimit 254 pref high
```

**内核已经把 RA 的默认路由装进了该网卡专属的路由表**（表号每次重连都变：
`1038 → 1040 → 1041 → 1042 → 1043 → 1044`）。

`ping6` 直接报 `Network is unreachable`，因为：

```console
$ ip -6 rule show
...
32000:	from all unreachable        ← 所有流量最终落到这里
```

**没有任何规则指向那张路由表。** 这就是 v1.x 方案的全部依据——
手动补一条规则：

```sh
ip -6 rule add from all lookup 1044 pref 15000
```

加上之后 `ping6` 通、`curl -6` HTTP 200。

**但 App 依然没网。** 这是整个项目最重要的转折点。

### 2.4 框架层：真相在这里

```console
$ dumpsys connectivity
Active default network: 103
network{103} ... Transports: WIFI   ← 只有 WiFi，没有 usb1
```

USB 网卡在 Android 框架里**完全不存在**。

```console
$ dumpsys ethernet
Ethernet State: enabled
Ethernet interface name filter: eth\d      ← 决定性证据
EthernetNetworkFactory
Tracking interfaces: (空)
```

`EthernetTracker` 用正则 `eth\d` 过滤网卡名。`usb1` 不匹配 → 直接忽略。

**这就是 2.3 里 `ip rule` 能修好 shell 却修不好 App 的原因：**

```
内核路由表  ←── ip rule 能修好这一层 ──→  ping / curl 可用
     ↑
     │  但 App 不看这里
     │
ConnectivityManager  ←── 必须这里接纳 ──→  App 才可用
     ↑
     │  只有 NetworkAgent 注册过的网络才被接纳
     │
EthernetTracker（名字必须是 eth\d）
```

---

## 3. 验证：改名后一切自动完成

```console
$ ip link set usb1 down && ip link set usb1 name eth0 && ip link set eth0 up
```

**不到一秒，Android 全部自动配好：**

```console
$ dumpsys ethernet
  eth0:NetworkInterfaceState{
    iface: eth0, up: true
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

注意三件事：

1. **IPv4 突然就有了**（`10.195.23.239/24`）。之前"手机只给 IPv6"的判断是错的——
   不是手机不给，是没人在要。`IpClient` 一启动就把 DHCP 跑了。
2. **DNS 自动配好了**，同时有 IPv4 和 IPv6 的 DNS。
3. **默认路由自动装了**，`0.0.0.0/0` 和 `::/0` 都有。

**删掉 `ip rule` 后一切照旧**，`curl -4` 与 `curl -6` 依然 HTTP 200。
证明 `EthernetTracker` 自己装了路由，`ip rule` 纯属多余。

---

## 4. 被证伪的假设（记录以免后人重走）

| # | 假设 | 证伪方式 | 结论 |
|---|---|---|---|
| 1 | 内核缺 RNDIS 驱动 | `zcat /proc/config.gz` 显示 `USB_NET_RNDIS_HOST=y` | ❌ 配置早就对 |
| 2 | 是 CDC 描述符缺陷 | dmesg 报 `bad CDC descriptors` | ✅ **这一条是真的**，但修完仍无网 |
| 3 | 手机只支持 IPv6 | 改名后立刻拿到 `10.195.23.x/24` | ❌ 双栈，只是没人跑 DHCP |
| 4 | 缺 IPv6 路由规则 | 加 `ip rule` 后 shell 通了，App 仍不通 | ⚠️ 只解决了 shell 层 |
| 5 | 是 DNS 问题 | `nslookup` 正常；探测地址 `generate_204` 也 204 | ❌ |
| 6 | 是 SELinux 拦截 | `dmesg \| grep avc` 无相关记录 | ❌ |
| 7 | 是 `usb0` 名字被占用 | 手动改名成功 | ❌ |
| 8 | 改名成 `ethN`（N 任意）都行 | 改成 `eth9` 被忽略，还留下僵尸条目 | ⚠️ **必须精确是 `eth0`** |
| 9 | `usb0` 一定是平板自身 gadget | 实测 RNDIS 有时就叫 `usb0` | ❌ **最贵的错误** |
| 10 | `curl` 通 = App 能上网 | 同一时刻 App 显示无网 | ❌ **最致命的错误** |

---

## 5. 为什么必须是 `eth0` 而不是 `eth1`/`eth9`

`EthernetTracker` 对 `eth0` 有特殊处理：

- 系统启动时就会针对 `eth0` 预先建立跟踪记录（`EthernetTracker` 构造时）
- 改名成 `eth9` 时，`EthernetTracker` 虽然名字匹配 `eth\d`，但没有对应的
  `IpClient` 配置模板，于是留下 `eth9:NetworkInterfaceState{ up: false }` 僵尸条目

实测：

```console
# 改成 eth9
$ dumpsys ethernet
  eth9:NetworkInterfaceState{ iface: eth9, up: false }   ← 僵尸，无 agent、无 ipClient
  (没有 eth9 的有效网络)

# 改回 eth0
$ dumpsys ethernet
  eth0:NetworkInterfaceState{ iface: eth0, up: true, ... VALIDATED ... }
  (完整网络)
```

**结论**：`TARGET=eth0` 不可改。

---

## 6. 名字竞争：为什么内核有时叫 `usb0`、有时叫 `usb1`

内核给不需要固定名字的网络设备分配名字时，用 `dev_alloc_name()` 从模板
`usb%d` 里找第一个空闲编号。**编号取决于分配顺序，而分配顺序取决于
本次开机有哪些设备先被探测到。**

实测三种路径：

```
① 手机 RNDIS 先探测，平板 gadget 未启用
   → 手机拿到 usb0

② 平板 gadget 先探测（平板作为从设备插在电脑上时）
   → gadget 拿到 usb0，手机拿到 usb1

③ 平板 gadget 探测过但 later 被移除，编号 usb0 短暂空闲
   → 手机可能拿到 usb0
```

所以**任何按名字判断的逻辑都是错的**。必须看 sysfs 路径：

```
手机共享的 RNDIS  ：.../a600000.ssusb/a600000.dwc3/xhci-hcd.4.auto/usb1/1-1/1-1:1.0/net/usbN
平板自身的 gadget ：.../a600000.ssusb/a600000.dwc3/gadget.0/net/usbN
```

判据：路径含 `xhci-hcd` 的是**主机控制器**下的设备（外接），
含 `gadget` 的是**本机作为从设备**。前者才是手机共享。

---

## 7. 状态检测：为什么 `operstate` 和 `IFF_RUNNING` 都不能用

守护需要知道网卡是否 up。三个候选信号实测：

### `operstate`

```console
$ cat /sys/class/net/usb0/operstate
unknown      ← 永远是 unknown，不管 up 还是 down
```

RNDIS 协议**没有物理链路检测机制**（不像以太网有 carrier detect）。
`operstate` 因此无法反映真实状态。

### `IFF_RUNNING` (`0x1000`)

```console
$ ip link set usb0 down
$ cat /sys/class/net/usb0/flags
0x1002       ← 0x1000 仍然置位
```

`IFF_RUNNING` 在内核里表示「驱动认为链路可用」，但 RNDIS 驱动从不主动清除它。

### `IFF_UP` (`0x1`)

```console
$ ip link set usb0 down; cat flags
0x1002       ← bit 0 清空
$ ip link set usb0 up;   cat flags
0x1003       ← bit 0 置位
```

**只有 `IFF_UP` 真实翻转。** 判据：

```sh
f=$(cat /sys/class/net/eth0/flags)
case "$f" in 0x*) v=$((f)) ;; *) v=$((0x$f)) ;; esac
[ $((v & 0x1)) -eq 0 ] && ip link set eth0 up
```

另注：`IFF_LOWER_UP`(`0x10000`) 在 `ip link` 输出里能看到，但**不在 sysfs `flags` 文件里**
（sysfs 只导出低 16 位），不要试图从 sysfs 读它。

---

## 8. 进程管理：三种 PID 取法全不可靠

这是实现过程中最耗时的一块。目标很简单：`service.sh` 启动守护后，
让 `action.sh` 能准确判断「守护是否在运行」。

### 三次失败的尝试

**尝试 1：`$!`**

```sh
nohup sh daemon.sh >/dev/null 2>&1 &
echo $! > eth.pid
```

实测：写进 pid 文件的 `7557`，实际运行的守护是 `5121`。

原因：Magisk 执行 `service.sh` 时本身处于某种包装环境，`$!` 拿到的是
启动器进程的 PID，而 `sh` 解析完脚本后会再 fork 一个子进程真正执行。

**尝试 2：脚本内 `$$`**

```sh
echo $$ > eth.pid
```

实测：仍然对不上。`sh` 在 fork 子进程执行脚本时，`$$` 继承父值，
指向的是外层 `sh` 进程。

**尝试 3：`/proc/self/stat`**

```sh
mypid=$(awk '{print $1}' /proc/self/stat)
```

实测：`/proc/self` 指向当前正在读它的进程，但读操作本身由 `awk` 子进程执行，
拿到的又是 `awk` 的 PID。

### 最终方案：不信 PID，按命令行匹配

```sh
find_daemon() {
    for p in /proc/[0-9]*; do
        pid=${p#/proc/}
        case "$pid" in ''|*[!0-9]*) continue ;; esac
        [ -r "${p}/cmdline" ] || continue
        cmd=$(cat "${p}/cmdline" 2>/dev/null | tr '\0' ' ' 2>/dev/null)
        [ -z "$cmd" ] && continue
        case "$cmd" in
            sh\ *rndis-eth-daemon.sh*) echo "$pid" ;;
        esac
    done
}
```

四个细节都是踩出来的：

1. `[0-9]*` 会匹配 `/proc/8350_reg` 这类非进程目录 → 必须校验纯数字
2. 只匹配脚本名不够 → `bash -c "...daemon.sh..."` 外层命令行也含脚本名
   → 必须加 `sh ` 前缀
3. 遍历时进程可能退出 → 先 `[ -r ]` 判断
4. Android 的 `tr` 需 `'\0'` 正确转义（小心 Python 生成脚本时写成真 NUL）

**副产品**：这个函数天然能发现多实例，`action.sh` 里直接用来告警。

---

## 9. 为什么不用 `.ko` 模块加载（一条死路）

早期曾尝试用 Magisk 模块在开机时 `insmod` 三个模块：
`usbnet.ko`、`cdc_ether.ko`、`rndis_host.ko`。

`load.log` 每次开机三轮全部失败：

```
insmod: can't insert 'usbnet.ko': invalid module format
=== 完成：成功 0 个，失败 3 个 ===
```

原因两层：

1. **内核已经把这三个编进去了**（`=y`），`/proc/modules` 里没有它们，
   内核版本里的 vermagic 也不允许加载同名模块
2. 即使编成 `=m`，vendor 在开机早期已加载它们，引用计数非零，
   `rmmod` 报 `Resource temporarily unavailable`，模块形式顶不掉

**结论**：驱动层修复只能重新编译内核，没有运行时方案。
这个模块最终被删除（`/data/adb/modules/rndis_host/`，1.6 MB）。

---

## 10. 性能优化的来龙去脉

v1.x 方案需要频繁执行 `ip` 命令查询路由表和规则，实测：

| 版本 | 待机 CPU | 连机 CPU | 说明 |
|---|---|---|---|
| v1.0 | 0.2286% | — | 固定 3 秒轮询，每轮 fork 3 个 `ip` |
| v1.1 | 0.0795% | 0.2600% | 自适应退避（空闲 15 秒） |
| **v2.3** | **0.0467%** | — | 只读 sysfs，几乎不 fork |

单条命令开销实测（5 次平均）：

| 命令 | 耗时 |
|---|---|
| `ip -6 route show table all` | 21 ms |
| `ip -6 rule show` | 33 ms |
| `ip -6 addr show usb1` | 32 ms |

v1.x 每轮 55–85 ms，且 88% 时间在**内核态**（`fork` + `exec` 开销）。
v2.x 每轮只 `cat` 一个 sysfs 文件（微秒级），所以 CPU 降低约 5.6 倍。

**教训**：能用 sysfs 读的，不要 fork `ip` 命令。

---

## 11. 日志与自愈设计

### 日志轮转

```sh
LOG_MAX=500
trim_log() {
    lines=$(wc -l < "$LOG" 2>/dev/null)
    [ -z "$lines" ] && return 0
    if [ "$lines" -gt "$LOG_MAX" ]; then
        tail -200 "$LOG" > "$LOG.tmp" && mv -f "$LOG.tmp" "$LOG"
        log "(日志已轮转)"
    fi
}
```

每 100 轮检查一次（500 秒），避免每轮都 `wc -l`。

### 自愈能力

守护天然具备三种自愈：

| 场景 | 机制 | 实测 |
|---|---|---|
| 手机拔出 → 插回 | 网卡消失后再出现，守护重新改名 | ✅ |
| 系统把名字重置回 `usbN` | 每 5 秒检查 `eth0` 是否还在 | ✅ 重启后 5 秒内改回 |
| 网卡被 down 掉 | `IFF_UP` 检查后自动 up | ✅ |

**为什么会有「名字被重置」？** 实测整机重启后，
`03:03:23` 改名为 `eth0`，`03:06:29` 又出现一次改名记录。
说明系统某次网络栈状态变化（可能是 `netd` 重启或 `EthernetTracker` 重新扫描）
把网卡名还原了。守护自动补回——**这正是守护存在的意义，不是缺陷**。

---

## 12. 与代理类 App 的协作

测试环境同时跑着 Clash 类代理（TUN 模式）。两者关系：

```
App
 ↓
Clash TUN（VPN 接口）
 ↓
内核路由 → eth0（USB 共享）
 ↓
手机 → 移动网络
```

`EthernetTracker` 接管 `eth0` 后，Ethernet 成为底层链路（`IS_UNMETERED`
且 `VALIDATED`，评分较高），Clash 的 TUN 在其之上做流量分流。
两者不冲突，属正常协作。

**注意**：若代理 App 配置了「仅允许 WiFi」之类的限制，可能拒绝走 Ethernet。
这不是本模块的问题，需在代理 App 里放开。

---

## 13. 遗留问题与未来方向

### 仍未解决

1. **无法验证其他品牌手机**。vivo/iQOO 的互斥 USB 模式是固件行为，
   其他品牌（小米、华为、三星）的 RNDIS 实现可能有差异。
   若它们的 RNDIS 网卡也叫 `usbN`，本模块应同样有效，但未实测。
2. **无法覆盖无 `EthernetTracker` 的 ROM**。部分深度定制系统移除了以太网服务。
   检测方法见 README 的[兼容性说明](README.md#兼容性说明)。
3. **`TARGET` 硬编码为 `eth0`**。若设备已有真正的 `eth0`（外接 USB 网卡），
   改名会失败。理论上可以做成「找第一个空闲的 `ethN` 且 N=0 优先」，
   但实测 `eth9` 会留僵尸条目，所以没有实现。

### 可能的改进

- 用 `inotify`/`uevent` 替代轮询（Android 的 `sh` 没有 `inotifywait`，
  需要编译一个小程序，收益不大）
- 把诊断能力做成独立 App（当前是 shell 脚本）
- 支持自定义 `TARGET`（改 `module.prop` 或在模块目录放配置文件）

---

## 14. 方法论总结

这个项目从「App 没网」到「改名解决」花了很长时间，弯路主要来自两个错误：

### 错误 1：用错误的工具验证

`curl` 通就以为成功了。**必须用与用户相同的路径验证**——
用户是 App，App 走 `ConnectivityManager`，那就必须看 `dumpsys connectivity`。

### 错误 2：过早接受「合理」的解释

「手机固件只支持 IPv6」听起来很合理（确实有 vivo 机型这么干），
而且有 `ip rule` 修好 shell 层的"证据"支撑。但它是错的。
**「合理的解释」不等于「验证过的解释」。**

改名实验只花了一分钟，但它推翻了两天的推理。
**当推理链条很长时，优先做一个能证伪的快速实验。**

---

## License

MIT
