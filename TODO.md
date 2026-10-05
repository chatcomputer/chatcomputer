# TODO

> 当前现状与规划的汇总见 [docs/STATUS.md](docs/STATUS.md)。

接下来在 Mac 上要做的事，按顺序排。完成一项就勾掉；技术验证（探针）的结论写回 `docs/ROADMAP.md` 第 5 节。

代码里还有 `TODO(P#)` / `TODO(M#)` 注释，对应下面的条目：`grep -rn "TODO(" --include=*.swift .`

## 0. 环境准备

- [x] Apple Silicon Mac，升级到 macOS 27，安装 Xcode 27
- [x] `brew install xcodegen`
- [x] 在 `project.yml` 里填 `DEVELOPMENT_TEAM`（签名要固定：guest 里的辅助功能、屏幕录制授权绑定签名身份）
- [x] `xcodegen generate && open ChatComputer.xcodeproj`
- [x] `cd Packages/ChatComputerKit && swift test`：确认单元测试在 macOS 上同样通过（当时 25 个，现为 57 个）

## 1. 首次编译（修编译错误）

以下模块和 App 写好后从未编译过，预计要改的地方：

- [x] **VMKit / DiskStack.swift**：DiskImageKit 的 API 照 WWDC26 第 224 场写。`DiskImage(opening:)`、`.open(url:mode:)`、`.appending(_:)`、`.asifLayer(url:type:)` 都要对照 SDK 头文件；`type: .overlay` 是推测的
- [x] **VMKit / NetworkProvider.swift**：`vmnet_network_configuration_create`、`vmnet_network_create`、`VZVmnetNetworkDeviceAttachment(network:)` 在 Swift 里的实际签名，`vmnet_return_t` 的成员名
- [x] **VMKit / VirtualMachineController.swift**：`VZMacGuestProvisioningOptions`、`VZMacOSVirtualMachineStartOptions.setGuestProvisioning(_:)`，以及 `start(options:)`、`saveMachineStateTo`、`restoreMachineStateFrom` 的 async 版本名称
- [x] **VMKit / MacOSInstaller.swift**：`VZMacOSRestoreImage.fetchLatestSupported` / `load(from:)` 的回调类型；`URLSessionDownloadDelegate` 在 Swift 6 下的 `Sendable` 要求
- [x] **GuestBridge / BridgeServer.swift**：`VZVirtioSocketListenerDelegate` 回调的隔离性（是否要求 `@MainActor`）；`nonisolated(unsafe)` 的写法
- [x] **AgentCore / AgentService.swift**：手写的 `AF_VSOCK = 40`、`VMADDR_CID_HOST = 2`、`sockaddr_vm` 布局（12 字节）要对照 `/usr/include/sys/vsock.h` 核实
- [x] **AgentCore / NativeDriver.swift**：`SCShareableContent`、`SCScreenshotManager.captureImage` 的 async 签名；`CGEvent` 构造器的可选返回值
- [x] **Apps**：Swift 6 严格并发下 `@Observable` + `@MainActor` 的闭包捕获；`MainView` 里 `ToolbarItemGroup` 中的 `switch`

> 首次 Mac 会话结论：除 `MacOSInstaller` 一处 Swift 6 并发错误外全部一次编译通过；vsock 常量与 SDK 头文件一致。宿主 App 原先缺 `com.apple.security.virtualization`（XcodeGen 会按 `project.yml` 重写 .entitlements，已在那里声明）。`VZMacOSRestoreImage.fetchLatestSupported` 在 macOS 27.0 (26A428) 上报 VZErrorDomain 10001，安装器已支持指定本地 IPSW。
>
> 自动化：`scripts/test-mac.sh`（单元测试 + Xcode 构建 + DiskImageKit/vmnet 自检 + 设置 `CC_API_KEY` 时跑真实模型闭环）；VM 探针用 `scripts/harness.sh vm …`。

## 2. 技术验证（ROADMAP §4 · M0）

按 P1 → P2 → P3 → P6 的顺序（这四项串起来就是 M1 的主干），P4 / P5 / P7 可以并行。

- [x] **P1 安装 + 自动初始化**：从 IPSW 到自动登录桌面，全程无人工点击，记录耗时
  - [x] 确认 `enablesRemoteLogin = true` 后能用 SSH 连上
  - [x] `GuestProvisioner.bootstrapScript`：在 SSH 会话里能否看到 `/Volumes/My Shared Files`？`sudo systemsetup -setremotelogin off` 是否需要完全磁盘访问权限？不行就把"关闭 SSH"挪到代理首次运行时做
- [ ] **P2 嵌入显示**：`VZVirtualMachineView` 能显示、缩放、手动键鼠操作
  - [ ] 中文输入法、系统快捷键（`capturesSystemKeys`）
  - [ ] 输入遮罩：代理执行时点击画面 → 转入接管状态；⌘. 能不能被虚拟机画面吞掉
- [x] **P3 vsock 通道**：代理连上宿主、握手通过（`pairingToken` 校验），测延迟；虚拟机挂起恢复、宿主 App 重启后能否重连
- [ ] **P4 DiskImageKit**：~~base + overlay 能启动；回到干净状态~~（已验证，见快照）；剩磁盘 IO 性能
- [ ] **P5 vmnet**：固定子网和 DHCP 范围（`NetworkProvider` 里的 TODO）；测试 guest 能否访问宿主 localhost 服务和局域网，把结论写进隐私说明；确认 `/var/db/dhcpd_leases` 查 IP 的方式在 vmnet 自定义网络下是否仍然有效
- [x] **P6 驱动**：
  - [x] `NativeDriver` 跑通截图、点击、输入、滚动、拖拽，确认坐标空间正确（默认显示 2560×1600 @2×，截图为 1280×800 点）。`vm up --input-test` 13/13 通过；DeepSeek 真实任务 3/3 完成
  - [ ] 试 Cua Driver 的 embedded 模式：只给 ChatComputerAgent 授权就够用吗？行的话锁定一个版本，写 `CuaDriverAdapter`（实现 `DriverAdapter` 协议）；不行就继续用原生驱动
- [ ] **P7 virtio-fs**：inbox 只读、outbox 可写；宿主 `ExportValidator` 能拦住 guest 里构造的符号链接

> 探针结果见 `docs/ROADMAP.md` §5.1。guest 授权已由引导第 4 步自动完成，P6 原生驱动已验证。剩余：P6 的 Cua Driver 评估；P2 的中文输入法和系统快捷键；P4 IO 性能；P5 guest 访问宿主服务；P7 只读与符号链接在 guest 侧验证。

## 3. 跑通 M1 闭环

- [x] 完整走一遍首次引导（`Onboarding.swift` 的 6 步），修卡住的地方
- [x] 配好 API Key，跑"打开 TextEdit，写一段话并保存到 outbox"，在宿主上导出文件（DeepSeek 3/3）
- [ ] 核对发给 API 的请求：`computer_toolset_20260801`、每个 `tool_result` 都带 `toolset_name`、截图尺寸在限制内（需要 Claude 的 Key）

## 4. M1 之后（M2）

- [x] agent 自更新（`GuestCommand.updateAgent`，校验同团队签名）：首次安装后 SSH 已关闭，新版本 agent 通过 bootstrap 共享目录分发，由 agent 自己校验签名后替换并重启（注意先删除再复制，原地覆盖会被代码签名机制杀掉，`OS_REASON_CODESIGNING`）
- [ ] 架构边界测试（参考 shk 的 ArchitectureTests）：Orchestrator / ModelProxy 不得 import VMKit、Virtualization

- [x] 任务存储：`FileTaskStore`（每个任务一个目录，task.json + 追加写的 events.jsonl；比 SQLite 简单、可移植，写到一半崩溃只丢最后一行）
- [x] 退出时任务暂停并连同对话历史存入 session.json，重新打开后显示为已暂停，Continue 继续（实测：第 4 步退出，重开后第 22 步交付）
- [ ] `GuestCommand.cancel`：取消长时间的 `wait` / `hold_key`（`AgentService` 里的 TODO）
- [ ] 过期截图检测：动作带着 `observationVersion`，guest 端还没有校验
- [x] 上下文与成本：Claude 端点保持历史不变、靠 prompt caching；context editing 会破坏缓存，只在上下文窗口不够时才用，60 轮任务用不到。非 Claude 端点的截图改为分批裁剪，缓存命中约 85%
- [x] 聊天里实时显示进度（第几步、模型思考了几秒、刚做的动作）
- [ ] 真正的流式输出：需要从流里逐块拼回原始回复（thinking、reasoning_content、extra_content），多家模型都能验证时再做
- [ ] 就绪探针：每次虚拟机启动或解锁后跑一次 health，不满足条件时显示"等待桌面登录或权限"
- [x] 快照：运行中连内存一起保存，APFS 克隆，分支历史，恢复前自动保存当前状态，「Freshly set up」即重置；日志式恢复可从崩溃中回滚（`SnapshotStore`、`vm snapshot-test`）
- [x] 外部 coding agent 接入：`chatcomputer` 命令行 + `chatcomputer mcp`，同一租约，用户接管/交还，闲置释放；Claude Code 经 MCP 和命令行实测通过
- [x] 右侧面板可收起为竖栏（⌃⌘S）；单实例与虚拟机目录锁
- [ ] 设置 › Coding agents 页面的界面截图核对（编译通过，未截到图）
- [x] 共享文件夹：运行中热更新、用户文件夹（默认只读、敏感目录拦截）、bootstrap 按需挂载、管理面板与清理、聊天附件、可读任务文件夹名、`share` 命令
- [ ] 把文件夹拖到虚拟机画面上即共享（目前可拖到面板或聊天）
- [ ] ACP：在聊天里选择 Claude Code / Codex 等作为 agent
- [x] 固定任务回归集：`cc-harness vm regress`（内置 agent）与 `scripts/regress/external.py`（Claude Code），10 个任务，从同一张快照开始，自动检查
- [x] 宿主自动回应 macOS 定期弹出的录屏授权对话框（`ConsentPrompt`）
- [x] 每个任务多跑几轮取中位数：`vm regress --runs 3`，`scripts/regress/report.py` 汇总并与基线对比
- [x] 回归集扩到 20 个任务（网页表单、跨应用、格式转换、多步、提示注入），本地网页代替外网
- [x] `save_file` 高层动作（命令行 `chatcomputer save`）：三轮 60/60，保存任务中位轮数 −69%
- [x] 驱动层查清跨进程面板在 Cmd/Ctrl 组合键后丢字的根因：按键 flags 被整个覆盖，丢了 NX_NONCOALESCED 等默认位；保留后 `--input-test` 3/3（Cmd+S、Cmd+A 后直接打字）
- [x] 回归集加入 Claude 作为内置 agent 的模型（claude-opus-5-5）
- [ ] 高风险任务前自动拍快照（`AgentRunner` 在 `ask_user` 审批前调用）
- [x] 宿主 App 退出时挂起虚拟机，下次启动时恢复（含 SIGTERM；保存失败时改为正常关机）
- [ ] 重新评估 App Sandbox（目前为了 ssh 和读 DHCP 租约关闭了）
- [ ] 给 VMKit / GuestBridge / AgentCore 补测试：`KeyMap`（AgentCore）和 DHCP 租约解析（VMKit）已有；还缺 GuestBridge 的协议握手
- [ ] 加 CI：`scripts/test-linux.sh` 可以直接在 Linux runner 上跑

## 5. 1.0 稳定版

- [x] guest agent 版本检查与自动更新：连上时比对版本（`0.9.0 (6)` 带 build 号），空闲时从 bootstrap 自我更新，失败一分钟后重试、最多三次；实测 0.2.0 → 0.2.0 (5) 约 8 秒，权限保留
- [x] 回归工具重建基准时可指定 agent（`--rebuild-base --agent`）；0.1.0 之前的 agent 无法自我更新时改从 guest 终端安装
- [x] 就绪探针：每 5 秒检查一次，窗口副标题显示未就绪的原因；`chatcomputer status` 显示 agent 版本
- [x] 模型请求出错：限流、过载、5xx、网络错误自动退避重试三次；Key 错误或重试用尽时暂停任务（Continue 重发），请求本身有问题时才判失败
- [x] 宿主休眠前暂停进行中的任务，唤醒后检查并解锁 guest
- [x] 磁盘不足：可用空间低于 3 GB 不开始任务，低于 5 GB 时提醒
- [x] Help › Export Diagnostics：版本、配置、agent 健康、最近 5 个任务、App 日志，经 `Redactor` 去除密钥
- [x] 隐私与许可说明（PRIVACY.md）
- [x] 新环境安装测试脚本（`scripts/fresh-install.sh`）与长时间运行测试脚本（`scripts/soak.py`）
- [x] Claude Code 回归支持 MCP（`external.py --via mcp`）
- [x] 项目网站 chatcomputer.github.io
- [x] 新环境完整安装两次
- [x] 长时间运行（按决定以 4.3 小时为准，0 崩溃）
- [x] Claude Code 跑全部 20 个任务（命令行 20/20，MCP 20/20）
- [x] 界面逐页截图核对
- [x] 发布 0.9 候选版（v0.9.0）
