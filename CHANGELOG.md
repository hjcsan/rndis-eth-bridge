# 更新日志

本项目经历过一次**方案彻底推翻**，版本号因此从 v1.1 直接跳到 v2.0。

---

## v2.3 — 2026-10-19

**修复**

- 修掉 `action.sh` / `service.sh` 遍历 `/proc` 时的
  `can't open /proc/NNNNN/cmdline` 报错刷屏。
  进程可能在遍历中途退出，现在先 `[ -r "${p}/cmdline" ]` 判断再读。
- 修掉生成脚本时误写入的 1 个 **NUL 字节**（`0x00`），它会让 `tr '\0' ' '` 失效。
  这个 bug 极隐蔽：`bash -n` 不报错，但运行行为完全错误。

**验证**

- 整机重启后 `03:03:13` 守护自动拉起，`03:03:23` 完成 `usb0 → eth0`（7 秒）
- 全程无需人工干预，Android 自动完成 DHCP/DNS/默认网络注册
- USB 网段地址 `10.195.23.239` 可直接 `adb connect`

---

## v2.2 — 2026-10-19

**修复**

- **PID 记录不可靠**：`service.sh` 用 `$!` 记 PID，拿到的是启动器 PID，
  导致 `action.sh` 长期误报「未运行」。
  实测 `$!`、`$$`、`/proc/self/stat` **三种取法全部不可靠**
  （详见 [ANALYSIS.md §8](ANALYSIS.md#8-进程管理三种-pid-取法全不可靠)）。
  改为遍历 `/proc/*/cmdline` 按命令行特征精确匹配。
- **进程泄漏**：原清理逻辑只看 PID 文件，一份失效就漏杀，
  导致多个守护同时运行、重复改名。现在按命令行匹配杀干净（先 `kill` 再 `kill -9`）。
- `action.sh` 增加多实例告警。

**验证**

- 连续启动 `service.sh` 三次，始终只有 1 个守护进程
- pid 文件与实际进程 PID 一致

---

## v2.1 — 2026-10-19

**关键修复**

- **`usb0` 不一定是平板自身 gadget，也可能是手机共享的 RNDIS。**
  v2.0 写死了跳过 `usb0`，导致「插上手机毫无反应」。
  内核按分配顺序起名，同一个手机会出现 `usb0` 或 `usb1` 两种结果：

  ```
  手机共享的 RNDIS  ：.../xhci-hcd.4.auto/usb1/1-1/1-1:1.0/net/usb0
  平板自身的 gadget ：.../gadget.0/net/usb0
  ```

  改为按 sysfs 路径判断：含 `xhci-hcd` 的是 RNDIS，含 `gadget` 的是平板自身。

**验证**

- 手动改名 `usb0 → eth0` 后立刻拿到 `10.195.23.17/24`
- `Active default network` 切换为 Ethernet，`VALIDATED` 标志出现
- **用户实测：连 WiFi 时正常；关掉 WiFi 依然正常** → 问题彻底解决

---

## v2.0 — 2026-10-19

**方案彻底重写。** v1.x 的 `ip rule` 方案被证伪——它只能让 `ping`/`curl` 通，
永远无法让 App 上网。

**新方案**

- 把 RNDIS 网卡从 `usbN` **改名成 `eth0`**，让 Android 的 `EthernetTracker`
  认领（它的过滤器是 `eth\d`），随后 DHCP/DNS/默认路由全由 Android 自动完成。
- 新增 `rndis-eth-daemon.sh`（只做改名）、重写 `service.sh`、`post-fs-data.sh`、`action.sh`。
- 模块 ID 从 `rndis_ipv6_route` 改为 `rndis_eth_bridge`。
- 旧的 `ip rule` 清理逻辑保留在 `post-fs-data.sh` 中，用于升级时清理遗留规则。

**发现**

- 改名后**立刻拿到 IPv4**，推翻了「手机只支持 IPv6」的判断
- 删掉 `pref 15000` 规则后一切照旧，证明 `EthernetTracker` 自己装了默认路由
- 名字必须**精确是 `eth0`**，改成 `eth9` 会被忽略并留下僵尸条目

**性能**

- CPU 从 v1.x 的 0.0795%（待机）/ 0.26%（连机）降到 **0.0467%**

---

## v1.1 — 2026-10-18（已废弃，归档于 `archive/`）

**方案**：手动补 `ip rule` 把流量导进内核已建好的路由表。

**改进**

- 自适应轮询：空闲退避 15 秒，发现网卡回到 2 秒
- 动态发现路由表号（实测每次重连都变：`1038 → 1040 → 1041 → 1042 → 1043 → 1044`）
- 日志轮转（超 500 行保留 200 行）
- 只认自己的 `pref 15000` 规则，不碰系统规则
- CPU 从 v1.0 的 0.2286% 降到 0.0795%

**结局**：❌ **方案本身是错的**。shell 层通了，App 层永远不通。
归档保留仅作历史参考。

---

## v1.0 — 2026-10-18（已废弃）

**方案**：固定 3 秒轮询，发现 `usb*` 网卡就拉起并加 `ip rule`。

**结果**：`ping6` 通、`curl -6` HTTP 200，**但 App 显示无网络**。

**性能**：CPU 0.2286%（897 秒耗 2.05 秒，88% 在内核态）。

---

## 内核侧变更（非本仓库版本号）

### `kernel/rndis_vivo_quirk.patch`

- 修复 vivo/iQOO（`2d95:600a`、`2d95:6012`）报 `bad CDC descriptors`、
  RNDIS 数据接口无法 claim、网卡不创建的问题。
- 让这两个 PID 走硬编码接口号路径（同 Android `android_rndis_quirk` 兜底做法）。
- 配套配置必须 `=y` 而非 `=m`（vendor 已加载 `cdc_ether.ko`，模块形式顶不掉）。

**验证**：`dmesg` 出现 `vivo RNDIS quirk: forcing hard-wired interfaces 0/1`，
`bad CDC descriptors` 消失，网卡正常创建。

---

## 版本号跳跃说明

v1.1 → v2.0 不是功能迭代，是**方案推翻**：

| | v1.x | v2.x |
|---|---|---|
| 思路 | 绕过 Android，在内核层补路由 | 让 Android 认领网卡 |
| 手段 | `ip rule add` | `ip link set name eth0` |
| shell 层 | ✅ 通 | ✅ 通 |
| **App 层** | ❌ **永远不通** | ✅ 通 |
| 依赖 | 动态发现路由表号 | 无（Android 全自动） |
| CPU | 0.0795% | 0.0467% |

因此主版本号递增，避免用户误以为可以平滑升级。
