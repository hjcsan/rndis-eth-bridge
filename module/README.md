# USB 网络共享 以太网桥接（Magisk 模块）

让 Android 真正认领手机 USB 网络共享，App 可以正常上网。

## 一句话原理

手机共享出来的 RNDIS 网卡被内核命名为 **`usb0` / `usb1`**，而 Android 的 `EthernetTracker`
**只认名字匹配 `eth\d` 的网卡**。名字不对 → 不被认领 → 没有 DHCP、没有 DNS、
`ConnectivityManager` 看不到网络 → **所有 App 显示「无网络」**。

把网卡**改名成 `eth0`**，Android 原生以太网服务立刻接手，全自动配置完毕。

```sh
ip link set usb0 down
ip link set usb0 name eth0
ip link set eth0 up
```

就这三行。

## 证据链

### 1. 过滤器只认 eth

```
$ dumpsys ethernet
Ethernet State: enabled
Ethernet interface name filter: eth\d      ← 关键
EthernetNetworkFactory
Tracking interfaces: (空)
```

网卡叫 `usb0` 时，`Tracking interfaces` 是**空的**——Android 根本不知道它存在。

### 2. 改名后立刻被接管

```
$ ip link set usb0 down && ip link set usb0 name eth0 && ip link set eth0 up

$ dumpsys ethernet
  eth0:NetworkInterfaceState{ iface: eth0, up: true,
    Transports: ETHERNET
    Capabilities: NOT_METERED&INTERNET&NOT_RESTRICTED&TRUSTED&NOT_VPN&VALIDATED&...
    networkAgent: EthernetNetworkAgent
    ipClient:     IpClientManager
    LinkAddresses: [ 10.195.23.17/24, fe80::..., 240e:44d:301:8432:... ]
    DnsAddresses: [ /240e:44d:301:8432::39, /10.195.23.3 ]
    Routes: [ ::/0 -> fe80::..., 0.0.0.0/0 -> 10.195.23.3 ] }

$ dumpsys connectivity
Active default network: 104          ← 变成 Ethernet
network{104}  ni{Ethernet CONNECTED}
```

`NetworkAgent`、`IpClientManager`、地址、DNS、默认路由、`VALIDATED` 标志
——**全部由 Android 自己配好了**。

### 3. 连 IPv4 都是自动的

之前以为「手机共享只有 IPv6」，那是误判。真相是：

- 网卡叫 `usb0` 时，没有任何 DHCP 客户端去请求 → 拿不到 IPv4
- 改名叫 `eth0` 后，`IpClientManager` 跑起 DHCP → **立刻拿到 `10.195.23.x/24`**

手机固件本来就是 IPv4 + IPv6 双栈。

### 4. 最终验证（用户实测）

- 未关 WiFi：App 正常上网，且 `Active default network` 是 Ethernet
- **关掉 WiFi：App 依然正常上网** → 确认走的是 USB，不是 WiFi 掩盖

## 三个踩过的坑（都很重要）

### 坑 1：`usb0` 不一定是平板自身的 gadget 网卡

早期版本写死了「跳过 `usb0`」，因为观察到 `usb0` 是平板自己作为从设备时的 gadget 网卡。
**这是错的。**

内核按分配顺序给网卡起名，同一个手机会出现两种结果：

```
手机共享的 RNDIS  ：.../a600000.ssusb/a600000.dwc3/xhci-hcd.4.auto/usb1/1-1/1-1:1.0/net/usb0
平板自身的 gadget ：.../a600000.ssusb/a600000.dwc3/gadget.0/net/usb0
```

**名字一样，路径不同。** 实测中 RNDIS 有时是 `usb1`、有时是 `usb0`，
跳过 `usb0` 会导致「插上手机毫无反应」。用户就是因为撞上 `usb0` 才测试失败。

**正确做法**：按 sysfs 路径判断，含 `xhci-hcd` 的是 RNDIS（需改名），
含 `gadget` 的是平板自身（跳过）。

```sh
p=$(readlink -f /sys/class/net/usb0)
case "$p" in
    *xhci-hcd*) # RNDIS，需要改名
    *gadget*)   # 平板自身，跳过
esac
```

### 坑 2：不能用 `curl` 判断"App 能不能上网"

`curl` 以 root 运行时，走的是内核路由，**不受 Android 框架的网络选择约束**。
所以会出现：

| 使用方 | 走哪条路 | 结果 |
|---|---|---|
| `ping` / `curl` / shell | 内核路由 + libc `getaddrinfo` | ✅ 通 |
| 浏览器、微信、任何 App | `ConnectivityManager` + `DnsResolver` → **netd** | ❌ 认为没网 |

**正确验证**：看 `dumpsys connectivity` 里该网络有没有 `VALIDATED` 标志，
以及 `Active default network` 是不是它。只有 BOTH 成立，App 才算真能上网。

### 坑 3：v1.x 的「加 ip rule」方案是死路

v1.x 的思路是：既然 Android 不认领，那就手动加 `ip rule` 把流量导进内核已建好的路由表。

```sh
ip -6 rule add from all lookup 1044 pref 15000
```

这**确实能让 `ping` 和 `curl` 通**，但**永远无法让 App 上网**——`netd` 只认有过
`NetworkAgent` 注册的网络，内核层的策略路由骗不过框架层。

**教训：在内核层绕过去，不等于应用层可用。**

## 判断网卡是否 up：三个坑（实测）

| 信号 | 实测行为 | 能用吗 |
|---|---|---|
| `operstate` | RNDIS 无链路检测，**恒为 `unknown`** | ❌ 永远等不到"up" |
| `IFF_RUNNING` (`0x1000`) | 网卡 down 后**仍然保持置位** | ❌ 无法反映真实状态 |
| **`IFF_UP` (`0x1`)** | down=`0x1002`、up=`0x1003`，**真实翻转** | ✅ **唯一可靠** |

```sh
f=$(cat /sys/class/net/eth0/flags)     # 0x1003
case "$f" in 0x*) v=$((f)) ;; *) v=$((0x$f)) ;; esac
[ $((v & 0x1)) -eq 0 ] && ip link set eth0 up
```

另外：`IFF_LOWER_UP`(`0x10000`) 在 `ip link` 输出里能看到，但**不在 sysfs `flags` 里**。

## 模块内容

| 文件 | 作用 |
|---|---|
| `module.prop` | 模块描述 |
| `post-fs-data.sh` | 开机早期清理 v1.x 遗留的 pref 15000 规则 |
| `service.sh` | 等 `sys.boot_completed` 后拉起守护，处理单实例 |
| `rndis-eth-daemon.sh` | 常驻守护：按 sysfs 路径识别 RNDIS 网卡，改名为 `eth0` 并 up |
| `action.sh` | 模块"操作"按钮：显示守护状态、网卡状态、Android 是否接管、连通性、日志 |

守护日志：`/data/adb/rndis_eth.log`（模块目录下 `eth.log` 软链到它）

## 守护设计

```
每 10 秒（发现 RNDIS 网卡时 5 秒）检查一次：
  eth0 已存在？
    → 是：确保它 up，结束
    → 否：扫描 /sys/class/net/usb*，路径含 xhci-hcd 的？
          → 有：down → rename eth0 → up
          → 无：什么都不做
```

**幂等**：改名完成后守护基本上什么都不做，只是每 5 秒读一个 sysfs 文件确认 `eth0` 还在。

**日志轮转**：超过 500 行截断，只保留最后 200 行。

### 关于 PID 与单实例（踩过的坑）

`service.sh` 拉起守护时，**不能用 `$!` 记 PID**。实测三种取法：

| 取值方式 | 结果 |
|---|---|
| `$!`（父进程拿到的后台 PID） | 启动器的 PID，脚本不是它执行的 |
| `$$`（脚本内） | sh 解析完脚本会再 fork 子进程执行，但 `$$` 仍继承父值 |
| `/proc/self/stat` 第一字段 | 真实执行进程 |

由于这三者都可能不可靠，最终做法是**不信任何单一来源**：
启动后用 `find_daemon()` 遍历 `/proc/<pid>/cmdline`，要求命令行
**以 `sh ` 开头**且**含 `rndis-eth-daemon.sh`**，以此作为唯一判据。
`eth.pid` 只当缓存，`action.sh` 显示状态时同样走 `find_daemon()`，
所以即使 PID 文件失效也不会误报。

两点细节：

- `for p in /proc/[0-9]*` 会匹配到 `/proc/8350_reg` 这类**非进程目录**，
  必须校验 `pid` 是纯数字，否则报 `can't open .../cmdline`。
- 只按脚本名匹配是不够的：`bash -c "sh .../rndis-eth-daemon.sh"` 这种外层
  命令行也含脚本名，会被误认。加上 `sh ` 前缀才能排除。
- 遍历 `/proc` 时进程可能正在退出，先 `[ -r "${p}/cmdline" ]` 判断再读，
  错误全部吞掉，否则 `action.sh` 会被 `can't open /proc/NNNNN/cmdline` 刷屏。

**单实例**：`service.sh` 启动前会先杀掉所有已存在的守护（`find_daemon()` 结果，
先 `kill` 再 `kill -9`）。没有这一步会出现多个守护同时改名、日志重复写入。

## 实测性能

| 项目 | 数值 |
|---|---|
| CPU 占用 | **0.0467%**（107 秒耗 0.05 秒） |
| 日志 | 稳态 2 行，超过 500 行自动截断 |
| 改名耗时 | 1 秒内完成 |

## 已验证的场景

- **自动改名（`usb1`）**：守护 1 秒内改名为 `eth0`，DHCP 拿到 `10.195.23.211/24`
- **自动改名（`usb0`）**：v2.1 修复后同样 1 秒内完成，拿到 `10.195.23.17/24`
- **自动改名（v2.3，`usb0`）**：重启守护后插上手机，5 秒内完成，拿到 `10.195.23.220/24`
- **开机自启（v2.3）**：整机重启后守护于 `03:03:13` 自动拉起，`03:03:23`
  完成 `usb0 → eth0`（7 秒），全程无需人工干预；随后 Android 自动完成 DHCP、
  DNS 与默认网络注册，`10.195.23.239/24` 可直连访问
- **自动修复名字被重置**：同一份日志里 `03:06:29` 又出现一次改名——系统某次网络
  状态变化把网卡名重置回了 `usb0`，守护在 5 秒内自动改回。这是守护存在的意义，
  不是缺陷
- **Android 接管**：`EthernetTracker` 出现 `eth0: up: true`，
  `EthernetNetworkAgent` 与 `IpClientManager` 均已创建，
  `Capabilities` 含 `VALIDATED`，`Active default network` 切换为 Ethernet
- **IPv4 + IPv6 双通**：`curl -4` 与 `curl -6` 均 HTTP 200
- **App 实测**：连 WiFi 时正常；**关掉 WiFi 依然正常**
- **不需要 ip rule**：删掉 pref 15000 规则后一切照旧
- **单实例**：连续启动 `service.sh` 三次，始终只有一个守护进程

## 注意事项

- **名字必须精确是 `eth0`**：改成 `eth9` 会被忽略（`EthernetTracker` 已针对 `eth0`
  建了跟踪记录，改走后会留下僵尸条目）。
- **重复改名会在 `dumpsys ethernet` 里留下僵尸记录**（如 `eth9: up: false`）。
  无害，但不要手动折腾名字。
- **不要用 `ip link set eth0 down` 测试**：会让手机判定对端断开、自行关闭共享，
  需要重新插拔。
- 如果平板本身还插了真正的 USB 以太网卡，会与 `eth0` 冲突
  （日志记录 `改名失败（目标名可能已被占用）`），届时需要调整 `TARGET`。
