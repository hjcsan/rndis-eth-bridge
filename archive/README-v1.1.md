# USB 共享 IPv6 路由修复（Magisk 模块）

## 背景

一加平板 Pro（caihong / SM8650）通过 USB 从 iQOO 12 获取网络共享。

**驱动层已解决**（内核内置了 `vivo RNDIS quirk` 补丁）：

- `bad CDC descriptors` 消失
- RNDIS 绑定成功，网卡 `usb1` 正常创建
- MAC / MTU / 包过滤器全部配置成功
- 链路双向通信正常（`carrier=1`）

**但 IPv4 层手机固件不支持。** 实测抓包（`tcpdump -i usb1`）证实：

| 协议 | 手机行为 |
|---|---|
| IPv6 | ✅ 收到 RS 就回 RA（router lifetime 7200s），收到 NS 就回 NA |
| IPv4 | ❌ 完全不响应：无 DHCP、ARP 请求零应答 |

iQOO 12 的 USB 网络共享在固件层面就是 **IPv6-only**，设置里也没有「仅 IPv6」或 IP 设置选项。

## 问题一：内核装了路由，Android 不给规则

IPv6 链路是通的，内核收到 RA 后**已经**把默认路由装进了 `usb1` 专属的路由表：

```
table 1040:
  240e:44d:301:8432::/64 dev usb1 proto kernel
  fe80::/64              dev usb1 proto kernel
  default via fe80::...  dev usb1 proto ra   ← 内核装了
```

但 Android 的 `netd` **不认领这张网卡**（它不是 `netd` 创建的网络），所以不会生成指向该表的 `ip rule`。而 `ip -6 rule` 最后一条是：

```
32000:  from all unreachable
```

**所有 IPv6 流量走完规则后落到 `unreachable`**：

```
ip -6 route get 2400:3200::1  →  Network is unreachable
```

修复：补一条 `ip rule` 指向该路由表。

```
15000:  from all lookup 1040
```

**关键点：table 号不是固定的。** 每次重连 / 重启共享都会变，实测观察到过
`1038` → `1040` → `1041` → `1042` → `1043`。所以脚本必须**动态发现**，不能硬编码。

## 问题二：Android 不会把 usb1 拉起来

插上手机后 `usb1` 是 **DOWN** 状态，Android 不会自动 up 它。网卡不 up：

- 收不到手机的 RA
- 也就永远不会有那张路由表
- 规则自然无从谈起

必须 `ip link set usb1 up` 才行。

## 判断「网卡是否已 up」的三个坑（实测结论）

这是本项目最容易踩错的地方，三个信号里只有一个可靠：

| 信号 | 实测行为 | 能用吗 |
|---|---|---|
| `operstate` | RNDIS 无链路检测，**恒为 `unknown`**，永不变化 | ❌ 用它会导致每轮重复 `set up`、日志无限膨胀 |
| `IFF_RUNNING` (`0x1000`) | 网卡 down 后**仍然保持置位**（实测 down=0x1002、up=0x1003 都含 0x1000） | ❌ 无法反映真实状态 |
| **`IFF_UP` (`0x1`)** | down=`0x1002`、up=`0x1003`，**真实翻转** | ✅ **唯一可靠** |

读取方式：

```sh
f=$(cat /sys/class/net/usb1/flags)     # 例如 0x1003
case "$f" in 0x*) v=$((f)) ;; *) v=$((0x$f)) ;; esac
if [ $((v & 0x1)) -eq 0 ]; then ip link set usb1 up; fi
```

用 `cat` 读 sysfs 而不是 `ip link`，省掉每轮一次 fork。

> 注意：`IFF_LOWER_UP`(`0x10000`) 在 `ip link` 输出里能看到，但**不在 sysfs 的 `flags` 里**，
> 所以不能靠 sysfs 判断链路是否真有对端。不过本项目只需判断「是否已 up」，`IFF_UP` 足够。

## 修复的整体链路

```
插上手机
  → 内核创建 usb1（DOWN）
  → 守护读 IFF_UP=0 → ip link set usb1 up
  → 网卡 up 后发出 RS → 手机回 RA
  → 内核把地址和默认路由装进 table XXXX（每次都不同）
  → 守护发现 table XXXX 有 default → ip rule add ... pref 15000
  → IPv6 通
```

拔掉手机 → `usb1` 消失 → 守护发现表失效 → 自动 `ip rule del`，不留垃圾。

## 模块内容

| 文件 | 作用 |
|---|---|
| `module.prop` | 模块描述 |
| `post-fs-data.sh` | 开机早期清理上次遗留的规则，避免指向已失效的表 |
| `service.sh` | 等 `sys.boot_completed` 后拉起守护，处理单实例 |
| `rndis-ipv6-guard.sh` | 常驻守护：自动拉起 usb 网卡、动态发现 table 并维护 pref 15000 规则 |
| `action.sh` | 模块"操作"按钮：显示守护状态、网卡状态、当前规则、路由决策、最近日志 |

守护日志：`/data/adb/rndis-ipv6-guard.log`（模块目录下 `guard.log` 软链到它）

## 守护设计

**自适应轮询间隔**：

| 场景 | 间隔 | 理由 |
|---|---|---|
| 检测到 usb 网卡 | 5 秒 | 保证插上后及时响应 |
| 无 usb 网卡（待机） | **15 秒** | 平板绝大多数时间处于此状态，省 CPU |

**规则维护是幂等的**：只在「需要但没有」时添加、在「有但失效」时删除，不会反复删加。

**日志轮转**：超过 500 行截断，只保留最后 200 行，长期运行不会膨胀。

**只认自己的规则**：脚本只操作 `pref 15000` 这一条，绝不碰系统或其他模块的规则。

## 实测性能

| 场景 | CPU 占用 | 说明 |
|---|---|---|
| 拔掉手机（待机） | **0.0795%** | 302 秒耗 0.24 秒，退避生效 |
| 连着手机 | **0.2600%** | 50 秒耗 0.13 秒，5 秒快扫 |
| 对比旧版（固定 3 秒） | 0.2286% | 待机场景降低约 **65%** |

单条命令开销（5 次平均）：`ip -6 route show table all` 14.3ms、`ip -6 rule show` 9.0ms。

## 已验证的场景

- **自动拉起网卡**：`usb1` 为 DOWN / `IFF_UP=0` 时，守护 2 秒内拉起并加规则
- **动态 table 发现**：5 次重连，table 号从 1038 变到 1043，全部自动适配
- **拔机自动撤规则**：网卡消失后 `撤掉失效规则 table 1043`，无残留
- **重连自动恢复**：断开后重新插上，全自动恢复，无需人工干预
- **日志不重复**：稳态下仅 1–4 行，早期 `operstate` 判断导致的刷屏已修复
- **`action.sh`**：无手机时也能正常显示并给出明确提示

## 注意事项

- `usb0` 是平板自身作为从设备时的 gadget 网卡，**排除在外**（脚本和 `action.sh` 都显式跳过）
- 只处理 IPv6。IPv4 无法通过软件修复——那是手机固件行为
- 大部分网站和 App 支持 IPv6，但纯 IPv4 站点仍打不开
- 规则是全局的（`from all`）。若同时连着有 IPv6 的 WiFi，理论上可能影响 WiFi 的 IPv6 出口；
  这是 Android per-network 路由架构（netd 用 fwmark + 网络 ID）导致的已知局限，
  而 `netd` 没认领 `usb1`，也就没有网络 ID 可用。
- **不要用 `ip link set usb1 down` 来测试**：这会让手机判定对端断开、自行关闭共享，
  需要重新插拔才能恢复。测试请用物理拔插。
