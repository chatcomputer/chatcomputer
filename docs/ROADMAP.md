# Chat Computer 实施规划（macOS 27 专用版）

版本 0.1 | 2026-10-01 | 基于 [产品与技术方案 v0.1](./proposal-v0.1.md)

## 0. 关键决定：只支持 macOS 27

宿主机与 guest 都只支持 macOS 27（Apple Silicon）。这让方案 v0.1 里的几处复杂度直接消失：

| 方案 v0.1 中的问题 | macOS 27 下的解法 |
| --- | --- |
| 第 3 节第 4 步「建立 guest 用户与桌面」需要人工点完设置助理，或靠 Lume 的 VNC 脚本模拟点击 | `VZMacGuestProvisioningOptions` 在首次启动时直接创建账户、开启自动登录（以及可选的 SSH） |
| 第 5 节「Lume 与直接使用 VZ 的选择」 | 在 App 进程内直接调用 VZ，不引入 Lume。Lume 本身也是 VZ 的封装，区别在于 VM 由 Lume 的 CLI/后台进程持有、画面走 VNC，而 `VZVirtualMachineView` 只能显示同进程内的 `VZVirtualMachine`。Lume 额外提供的无人值守安装与镜像管理，现在都有一方 API 覆盖，因此没必要再为了它接受跨进程显示 |
| 第 8 节「备份点」需要自己复制整块磁盘 | DiskImageKit 的分层镜像（基础层 + ASIF overlay）提供写时复制快照 |
| 第 7 节网络「NAT 不是完整隔离」 | vmnet 自定义网络（`VZVmnetNetworkDeviceAttachment`，macOS 26 起）可以控制 DHCP、子网和 VM 间通信 |
| 第 7 节主客通信「先用 SSH stdio」 | 改用 virtio-vsock（`VZVirtioSocketDevice`）：不走网络、天然绑定到这一台 VM，不需要口令和 host key |
| 第 2 节验证矩阵（14/15/26 多种组合） | 只测 27 host + 27 guest，矩阵只剩硬件和 build 两个维度 |

代价：用户必须先升级到 macOS 27；开发机也必须是 macOS 27 + Xcode 27。本仓库的云端容器是 Linux，**无法编译或运行这个 App**，所有构建与真实 VM 测试都要在 Mac 上进行。

## 1. 用到的 macOS 27 / WWDC26 新能力

来源：WWDC26 Session 224 *Expand the capabilities of your Virtualization app*。以下 API 名称和用法以该 session 为准；落地前需对照 Xcode 27 SDK 头文件再核对一次。

### 1.1 Guest 自动初始化：`VZMacGuestProvisioningOptions`（host 27）

```swift
let provisioning = VZMacGuestProvisioningOptions()
provisioning.fullName = "Chat Computer"
provisioning.username = "agent"
provisioning.password = generatedPassword   // 随机生成，存入宿主 Keychain
provisioning.logsInAutomatically = true     // 必需：Cua/AX/截屏都要有 Aqua 图形会话
provisioning.enablesRemoteLogin = true      // 仅 bootstrap 阶段使用，装好 guest agent 后关闭

let startOptions = VZMacOSVirtualMachineStartOptions()
try startOptions.setGuestProvisioning(provisioning)
try await vm.start(options: startOptions)
```

- 只在 guest 尚未完成设置时生效，所以它天然是「首次引导」的一部分。
- 口令每台 VM 随机生成，仅存在宿主 Keychain，满足方案「避免公开默认口令」的要求。
- 自动登录 = 重启后自动回到可操作的桌面，直接解决「SSH 可用不等于桌面可用」的大部分情况（锁屏仍需探针检测）。

### 1.2 分层磁盘：DiskImageKit（host 27）

```swift
let base    = try DiskImage(opening: .open(url: goldenURL, mode: .readOnly))   // 装好系统 + agent 的金镜像
let overlay = try DiskImage(opening: .open(url: workOverlayURL))               // 用户这台电脑的写入层
let stacked = try base.appending(overlay)
let attachment = try VZDiskImageStorageDeviceAttachment(diskImage: stacked)
config.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: attachment)]
```

产品用途：

- **金镜像**：安装 + provisioning + agent 安装完成后冻结为只读 base。「重置电脑」= 丢弃 overlay，秒级完成，不必重新下载 IPSW。
- **快照**（已实现，`SnapshotStore`）：不再叠加 overlay，而是用 APFS 克隆保存 overlay、AuxiliaryStorage 和（运行中时）内存状态。磁盘栈始终只有一层，任意快照可以单独恢复或删除，空间成本只是增量。运行中的虚拟机先挂起再克隆，然后恢复运行。参考了 ezvm 的日志式恢复与快照分支。
- **注意**（session 原话）：栈越浅性能越好，需要定期合并；复制 VM 时必须同时复制辅助存储（auxiliary storage）、硬件模型和机器标识。这些由同一个 `VMBundle` 管理器统一维护。

### 1.3 网络：vmnet 自定义网络（host 26+）

```swift
var status: vmnet_return_t = .VMNET_FAILURE
let netConfig = vmnet_network_configuration_create(.VMNET_SHARED_MODE, &status)!
// 在这里设置固定子网 / DHCP 保留，让 guest IP 可预测
let network = vmnet_network_create(netConfig, &status)!
let nic = VZVirtioNetworkDeviceConfiguration()
nic.attachment = VZVmnetNetworkDeviceAttachment(network: network)
```

- vmnet 网络是引用计数对象、App 退出后不保留，配置需由我们自己持久化。
- 不需要端口转发：控制通道走 vsock，不走网络。
- 待验证：vmnet 是否能阻止 guest 访问宿主机上监听的服务与局域网（方案第 7 节的要求）。若不能，需要在文档与隐私页面如实说明，并考虑后续用 Network Extension 做过滤。

### 1.4 主客通信：virtio-vsock（不是新 API，但在 27-only 前提下变成首选）

- Host：`VZVirtioSocketDevice` + `VZVirtioSocketListener`，guest agent 主动连接宿主固定端口。
- 天然一对一绑定到这台 VM，不经过 TCP/IP，不受 guest 网络配置和网页内容影响。
- SSH 只用于 bootstrap（安装 agent），完成后通过 agent 关闭 Remote Login。

注：`VZCustomVirtioDevice`（WWDC26 新增）目前只支持 Linux guest，不适用于本项目。

### 1.5 文件交换：virtio-fs 共享目录（host/guest 13+）

- `VZVirtioFileSystemDeviceConfiguration` + `VZMultipleDirectoryShare`：
  - `inbox/<job-id>`：只读，用户主动导入的文件
  - `outbox/<job-id>`：可写，代理产出；导出前在宿主侧做大小、类型、路径、符号链接校验
- 不共享主目录，不同步剪贴板，完全符合方案第 7 节。

### 1.6 其他会用到的已有能力

| API | 用途 |
| --- | --- |
| `VZVirtualMachineView` + `automaticallyReconfiguresDisplay` | 左侧嵌入显示，窗口缩放时 guest 分辨率跟随 |
| `saveMachineStateTo` / `restoreMachineStateFrom` | 退出 App 时挂起 guest，再开时秒级恢复（失败则冷启动） |
| `VZMacOSRestoreImage.fetchLatestSupported` + `VZMacOSInstaller` | 首次引导从 Apple 下载并安装 IPSW |
| macOS guest iCloud 支持（15+） | 后续按需支持 Apple Account 登录；MVP 不依赖 |

## 2. 总体架构

```
┌─────────────────────────── Host: ChatComputer.app (macOS 27) ───────────────────────────┐
│  SwiftUI 双栏窗口                                                                         │
│  ├─ VMDisplayView (NSViewRepresentable → VZVirtualMachineView + 输入租约遮罩)             │
│  └─ ChatPanel / TaskPanel / ApprovalSheet / OnboardingFlow                               │
│                                                                                          │
│  Orchestrator (actor)  ── Policy ── Budget ── ControlLease                               │
│      │                     │                                                             │
│  ModelProxy ── Keychain    TaskStore (SQLite 事件日志 + 产物清单 + 外部动作账本)           │
│      │                                                                                   │
│  VMKit: VMBundle / Installer / Provisioner / DiskStack(DiskImageKit) / Network(vmnet)    │
│      │                                                                                   │
│  GuestBridge (vsock server, 协议 = BridgeProtocol)                                       │
└──────┼───────────────────────────────────────────────────────────────────────────────────┘
       │ virtio-vsock                      virtio-fs: inbox(ro) / outbox(rw)
┌──────┼──────────────── Guest: macOS 27 (auto-login, user "agent") ───────────────────────┐
│  ChatComputerAgent (LaunchAgent, 已签名, 持有辅助功能 + 屏幕录制权限)                       │
│   └─ DriverAdapter: CuaDriverAdapter (首选) | NativeDriverAdapter (AX + ScreenCaptureKit + CGEvent) │
│  Safari / Finder / TextEdit                                                              │
└──────────────────────────────────────────────────────────────────────────────────────────┘
```

### 2.1 代码组织（Xcode 27 工程 + 本地 Swift Packages）

| 模块 | 运行位置 | 职责 |
| --- | --- | --- |
| `ChatComputer` (app target) | Host | SwiftUI 界面、引导流程、窗口与菜单、紧急停止快捷键 |
| `VMKit` | Host | VM bundle 格式、IPSW 下载与安装、provisioning、DiskImageKit 分层、vmnet、保存/恢复 |
| `BridgeProtocol` | 双方共享 | 命令信封与响应的 Codable 类型、版本协商、长度帧编码 |
| `GuestBridge` | Host | vsock 监听、配对、租约校验、超时、迟到响应丢弃 |
| `Orchestrator` | Host | 代理循环、任务状态机、观察选择、验证 |
| `Policy` | Host | 工具白名单、风险分级、审批绑定、文件导出校验 |
| `ModelProxy` | Host | 供应商适配（首个：Anthropic Messages API + computer use 工具）、用量与预算、Keychain |
| `TaskStore` | Host | SQLite（GRDB）事件日志：planned → dispatched → observed → verified / uncertain |
| `ChatComputerAgent` (独立 target) | Guest | vsock 客户端、DriverAdapter、健康探针、virtio-fs 挂载检查 |

### 2.2 必要的工程配置

- Entitlement：`com.apple.security.virtualization`；USB 直通暂不做，不申请 Claim USB Accessory。
- vmnet 自定义网络是否需要额外 entitlement、是否兼容 App Sandbox：G1 首周验证。
- Guest agent 需要稳定签名（Developer ID），否则每次升级 TCC 授权失效。
- 驱动选型：首选 Cua Driver 的 **embedded 模式**（宿主 App 拉起私有 driver daemon，继承宿主 App 的 TCC 授权）。这样 guest 里只有一个授权身份「Chat Computer Agent」，用户只需授权一次。该模式是否如文档所述可用，由 P6 实测确认。
- 不引入 `cua-perception` 扩展（AGPL-3.0）。Peekaboo 不作为首版依赖：它以自身菜单栏 App 持有 TCC、自带模型 agent 层，未提供可嵌入的库或授权委托，只作为 AX 目标定位（元素 ID / 快照）的设计参考。

## 3. 首次引导流程（对应方案第 3 节，已按 macOS 27 简化）

1. **检查设备**：Apple Silicon、macOS 27、可用内存/磁盘；`VZMacOSRestoreImage` 的 `mostFeaturefulSupportedConfiguration` 是否可用。
2. **选择资源**：默认 4 vCPU / 8 GB / 80 GB ASIF 稀疏盘，显示 IPSW + 金镜像 + overlay 的实际空间预算。
3. **下载并安装 macOS 27**：`VZMacOSInstaller`，进度可见、可断点重试；展示 macOS SLA 由用户接受。
4. **自动初始化 guest**：首次启动带 `VZMacGuestProvisioningOptions`（随机口令进 Keychain、自动登录、临时开启 SSH）。*无需用户操作。*
5. **安装 guest agent**：通过 virtio-fs 挂载签名的 agent pkg，经 SSH 安装 LaunchAgent → agent 通过 vsock 回连并完成配对（每台 VM 独立身份）→ 关闭 SSH。*无需用户操作。*
6. **授予 guest 权限**：这是唯一必须由用户在左侧 guest 画面里亲手点的步骤（辅助功能、屏幕录制）。右侧逐项说明；agent 实时上报状态，通过后做截图 + 无害输入测试。不改 TCC 数据库、不关 SIP。
7. **冻结金镜像**：关机 → 当前磁盘转为只读 base，新建 overlay。以后「重置电脑」从这里开始。
8. **配置模型并跑首个任务**：Key 存 Keychain → 认证/视觉/工具调用检查 → 「打开 TextEdit 保存一条测试笔记」→ 在 outbox 中确认文件存在并导出。

目标：用户只需要在第 3 步接受许可、第 6 步点两次授权、第 8 步填 Key。

## 4. 里程碑

沿用方案第 10 节的闸门思路，不承诺日期，每个里程碑以可演示的验收结果为准。

### M0 技术探针（G1 前置，每项是一个独立的小 demo）

| # | 探针 | 通过标准 |
| --- | --- | --- |
| P1 | 安装 + provisioning | 从 IPSW 到自动登录桌面全程无人工点击；记录耗时 |
| P2 | 嵌入显示 | SwiftUI 窗口里 `VZVirtualMachineView` 可显示、缩放、手动键鼠；中文输入法可用 |
| P3 | vsock 通道 | guest 内一个命令行程序与宿主双向收发 JSON，测延迟与断线重连 |
| P4 | DiskImageKit | base + overlay 启动；丢弃 overlay 后回到干净状态；测启动与 IO 性能 |
| P5 | vmnet | 自定义子网可上网；测试 guest 能否访问宿主 localhost 服务与局域网 |
| P6 | Guest 驱动 | Cua Driver embedded 模式跑通「截图 + 点击 + 输入 + 浏览器语义快照」，确认 TCC 只授权给 Chat Computer Agent 即可；同时用原生 AX/ScreenCaptureKit/CGEvent 写最小对照实现作为退路 |
| P7 | virtio-fs | inbox 只读、outbox 可写，宿主侧路径校验 |

### M1 技术闭环（= G1）

一个窗口：左侧 VM，右侧聊天框。输入「打开 TextEdit，写一段话并保存到 outbox」，模型经 Orchestrator → vsock → agent 执行，宿主侧在 outbox 校验文件并展示。只有执行中 / 完成 / 失败三个状态，无审批、无持久化。

### M2 可用产品（= G2）

完整首次引导（第 3 节）；完整状态机（方案第 4 节的 8 个状态）；暂停、接管（用户点进 VM 画面即撤销代理租约）、取消、紧急停止；Keychain；SQLite 任务存储；权限探针与就绪检查。

### M3 受控试用（= G3）

Policy 层与审批卡片；提示注入对抗用例；DiskImageKit 检查点与重置；挂起/恢复；诊断包（脱敏、可预览）；30 个固定任务 × 3 次的回归任务集；签名、公证、更新。

### M4 持续任务（= G4）

外部动作账本、长时间等待、预算、睡眠/唤醒恢复、overlay 合并维护。

## 5. 风险与仍需决定的事

1. **许可**：macOS 27 SLA 对虚拟实例的用途限制仍须法务确认，方案第 10 节的结论不变：确认前只面向个人非商业与开发测试。
2. **API 细节**：本文的 macOS 27 API 名称来自 WWDC26 session，需要以 Xcode 27 正式版 SDK 为准；P1/P4 探针会顺带核对。
3. **TCC 与驱动身份**：默认选 Cua Driver（embedded 模式）。若 P6 证明 embedded 模式在 macOS 27 guest 中不能让授权落在我们的 Agent 上，改用自写原生驱动（AX + ScreenCaptureKit + CGEvent），而不是换 Peekaboo。
4. **网络隔离**：P5 若证明 vmnet 无法阻止访问宿主服务，需要在隐私说明中披露，并把过滤列入 M3。
5. **模型选择**：建议首发锁定一个支持视觉 + computer use 工具的模型（例如 Anthropic Claude），用户自带 Key；其他供应商在 M3 之后以 `ModelProvider` 适配器扩展。

### 5.1 探针结果（2026-09-30，宿主 macOS 27.0 / Xcode 27，guest macOS 27.0.1 26A434，M 系列 32 GB）

| 探针 | 结果 | 数据与发现 |
|---|---|---|
| P1 安装 | ✅ | IPSW → 已安装 **173 秒**，磁盘占用 28.6 GB。`VZMacOSRestoreImage.fetchLatestSupported` 在宿主 27.0 上报 VZErrorDomain 10001，安装器已支持传入本地 IPSW |
| P1 自动初始化 | ✅ | `VZMacGuestProvisioningOptions` 首次启动直接进入已登录桌面，无设置助理。SSH 会话能看到 `/Volumes/My Shared Files`；在 SSH 里用 sudo 关闭 Remote Login 成功（GUI 终端不行，要求完全磁盘访问权限）。`launchctl bootstrap gui/<uid>` 在 SSH 里必须用 root（否则报错 125） |
| P1 装 agent | ✅ | 冷启动后约 **14 秒**装好。**注意**：SSH 关闭后无法再通过 SSH 更新 agent，需要 agent 自更新通道（M2） |
| P2 显示 | ✅（部分） | `VZVirtualMachineView` 正常显示，鼠标坐标准确；中文输入法未测 |
| P3 vsock | ✅ | 冷启动后 **13.8 秒**完成配对；health 往返 p50 **1.6 ms**（预热后 0.27 ms），p95 5.5 ms；无租约输入被 guest 拒绝；挂起 **3.0 秒**（状态文件 2.7 GB），恢复 **2.8 秒**后 agent **1.1 秒**内重连 |
| P4 DiskImageKit | ✅（IO 性能未测） | ASIF base + overlay 叠加、重置均正常（`vm selftest`）；带 overlay 启动正常（日常使用）。快照（2026-10-02，`vm snapshot-test`）：运行中快照 **6.4 秒**（含 2.5 GB 内存），之后 agent 1.3 秒重连、画面不变；恢复含内存的快照 **4.6 秒**，打开的 Spotlight 消失；重置到空 overlay（克隆出的新 overlay）冷启动后 agent 15 秒就绪；撤销重置 3.4 秒。ASIF overlay 文件可直接 APFS 克隆并换回原路径使用 |
| P5 vmnet | ✅ | shared 模式不需要 root；guest 能上网；宿主能访问 guest:22。**每个 network 实例的子网可能不同**（先后观察到 192.168.64/24 和 192.168.66/24），租约文件里会留旧条目，已改为按当前子网（`vmnet_network_get_ipv4_subnet`）取最新租约。guest 访问宿主服务尚未测 |
| P6 驱动 | ✅ | 两项授权由宿主级控制自动完成（`HostControl`，读取 VM 画面并输入密码，密码不经过模型或屏幕）。修复前快捷键与输入在保存对话框等跨进程面板里会丢失：修饰键必须作为带设备位的真实按键发送，文字按真实按键逐字输入。`vm up --input-test`（TextEdit + 保存对话框，逐字节比对）从 0/3 提升到 13/13。真实任务「在 TextEdit 写一行字并保存到 outbox」用 deepseek-flash 3/3 完成（136–448 秒，每次都交付了经过校验的文件） |
| P7 virtio-fs | ✅（部分） | 自动挂载在 `/Volumes/My Shared Files`，guest 从 bootstrap 共享读文件正常。运行中替换 `VZVirtioFileSystemDevice.share`（2026-10-02，`vm share-test`）：增删文件夹、挂上和取下 bootstrap 后 agent 的 health 全程 0 秒回应，Finder 立即看到新文件夹和其中文件。只读与符号链接逃逸未在 guest 侧测 |
| 跨进程面板的输入（2026-10-03） | ⚠️ 已绕开 | 保存对话框、Go to Folder、Spotlight、查找栏这类跨进程面板：**只要按过 Cmd 或 Ctrl 组合键（包括打开对话框的 Cmd+S），之后的普通打字全部丢失，直到在面板里点一下**；Shift、Option 组合和方向键不受影响，移动鼠标也不能恢复。表现为文件存成 `Untitled.txt`、Spotlight「不接受输入」。`save_file` 已改为：等对话框出现后先点名称框，用 ↓ 加 Shift+↑ 全选（不用 Cmd+A），打字后读屏核对，再同样处理 Go to Folder；没看到对话框就不打字（以前 Cmd+A 和文件名会落进文档）。根因可能是驱动把按键的 flags 整个覆盖、去掉了系统默认的 `0x20000100`（含 NX_NONCOALESCED），尚未验证 |
| 关机 | ✅（修复后） | `VZVirtualMachine.requestStop()` 在 macOS guest 里只弹出"确定要关机吗"对话框，**永远不会自己完成**，会让"冻结金镜像"一步卡死。已改为 agent 发送 loginwindow 的 `aevtrsdn` 事件（无需授权，对话框 60 秒后自动关机；有辅助功能权限时立即确认），实测 66 秒干净关机 |
| 公证 | ✅ | Developer ID + hardened runtime + 时间戳，公证 Accepted，已装订，Gatekeeper：`Notarized Developer ID`（`scripts/release.sh`） |

测试中发现并已修复的产品 bug：宿主读 vsock 时 `availableData` 碰到已关闭的描述符会抛 ObjC 异常、导致整个 App 崩溃；配对令牌在安装成功前就写入，失败重试后已装好的 agent 会被永久拒绝；宿主 App 缺少 virtualization entitlement。

## 6. 下一步

> 当前现状、实测结果与最新规划见 [STATUS.md](STATUS.md)。

1. ~~建立 Xcode 工程与第 2.1 节的 package 骨架~~：已完成，见仓库根目录 `README.md`。平台无关模块已在 Linux 上编译并通过测试；macOS 专用模块与两个 App 需在 macOS 27 + Xcode 27 上首次编译。
2. 按 P1 → P2 → P3 → P6 的顺序完成探针（这四个串起来就是 M1 的主干），P4/P5/P7 并行。
3. 每个探针结束后把结论写回本文件第 5 节。

## 参考

- [WWDC26 · Expand the capabilities of your Virtualization app](https://developer.apple.com/videos/play/wwdc2026/224/)
- [Apple Developer Forums · 在 macOS 26.6 上安装 macOS 27 guest 的问题](https://developer.apple.com/forums/thread/830118)
- [DiskImageKit](https://developer.apple.com/documentation/DiskImageKit) · [vmnet](https://developer.apple.com/documentation/vmnet) · [Virtualization](https://developer.apple.com/documentation/Virtualization)
- 方案 v0.1 第 12 节中的其余来源
