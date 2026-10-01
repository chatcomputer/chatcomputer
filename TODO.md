# TODO

接下来在 Mac 上要做的事，按顺序排。完成一项就勾掉；技术验证（探针）的结论写回 `docs/ROADMAP.md` 第 5 节。

代码里还有 `TODO(P#)` / `TODO(M#)` 注释，对应下面的条目：`grep -rn "TODO(" --include=*.swift .`

## 0. 环境准备

- [ ] Apple Silicon Mac，升级到 macOS 27，安装 Xcode 27
- [ ] `brew install xcodegen`
- [ ] 在 `project.yml` 里填 `DEVELOPMENT_TEAM`（签名要固定：guest 里的辅助功能、屏幕录制授权绑定签名身份）
- [ ] `xcodegen generate && open ChatComputer.xcodeproj`
- [ ] `cd Packages/ChatComputerKit && swift test`：确认 25 个测试在 macOS 上同样通过（目前只在 Linux 上跑过）

## 1. 首次编译（修编译错误）

以下模块和 App 写好后从未编译过，预计要改的地方：

- [ ] **VMKit / DiskStack.swift**：DiskImageKit 的 API 照 WWDC26 第 224 场写。`DiskImage(opening:)`、`.open(url:mode:)`、`.appending(_:)`、`.asifLayer(url:type:)` 都要对照 SDK 头文件；`type: .overlay` 是推测的
- [ ] **VMKit / NetworkProvider.swift**：`vmnet_network_configuration_create`、`vmnet_network_create`、`VZVmnetNetworkDeviceAttachment(network:)` 在 Swift 里的实际签名，`vmnet_return_t` 的成员名
- [ ] **VMKit / VirtualMachineController.swift**：`VZMacGuestProvisioningOptions`、`VZMacOSVirtualMachineStartOptions.setGuestProvisioning(_:)`，以及 `start(options:)`、`saveMachineStateTo`、`restoreMachineStateFrom` 的 async 版本名称
- [ ] **VMKit / MacOSInstaller.swift**：`VZMacOSRestoreImage.fetchLatestSupported` / `load(from:)` 的回调类型；`URLSessionDownloadDelegate` 在 Swift 6 下的 `Sendable` 要求
- [ ] **GuestBridge / BridgeServer.swift**：`VZVirtioSocketListenerDelegate` 回调的隔离性（是否要求 `@MainActor`）；`nonisolated(unsafe)` 的写法
- [ ] **AgentCore / AgentService.swift**：手写的 `AF_VSOCK = 40`、`VMADDR_CID_HOST = 2`、`sockaddr_vm` 布局（12 字节）要对照 `/usr/include/sys/vsock.h` 核实
- [ ] **AgentCore / NativeDriver.swift**：`SCShareableContent`、`SCScreenshotManager.captureImage` 的 async 签名；`CGEvent` 构造器的可选返回值
- [ ] **Apps**：Swift 6 严格并发下 `@Observable` + `@MainActor` 的闭包捕获；`MainView` 里 `ToolbarItemGroup` 中的 `switch`

## 2. 技术验证（ROADMAP §4 · M0）

按 P1 → P2 → P3 → P6 的顺序（这四项串起来就是 M1 的主干），P4 / P5 / P7 可以并行。

- [ ] **P1 安装 + 自动初始化**：从 IPSW 到自动登录桌面，全程无人工点击，记录耗时
  - [ ] 确认 `enablesRemoteLogin = true` 后能用 SSH 连上
  - [ ] `GuestProvisioner.bootstrapScript`：在 SSH 会话里能否看到 `/Volumes/My Shared Files`？`sudo systemsetup -setremotelogin off` 是否需要完全磁盘访问权限？不行就把"关闭 SSH"挪到代理首次运行时做
- [ ] **P2 嵌入显示**：`VZVirtualMachineView` 能显示、缩放、手动键鼠操作
  - [ ] 中文输入法、系统快捷键（`capturesSystemKeys`）
  - [ ] 输入遮罩：代理执行时点击画面 → 转入接管状态；⌘. 能不能被虚拟机画面吞掉
- [ ] **P3 vsock 通道**：代理连上宿主、握手通过（`pairingToken` 校验），测延迟；虚拟机挂起恢复、宿主 App 重启后能否重连
- [ ] **P4 DiskImageKit**：base + overlay 能启动；丢弃 overlay 后回到干净状态；测启动与磁盘 IO 性能
- [ ] **P5 vmnet**：固定子网和 DHCP 范围（`NetworkProvider` 里的 TODO）；测试 guest 能否访问宿主 localhost 服务和局域网，把结论写进隐私说明；确认 `/var/db/dhcpd_leases` 查 IP 的方式在 vmnet 自定义网络下是否仍然有效
- [ ] **P6 驱动**：
  - [ ] `NativeDriver` 跑通截图、点击、输入、滚动、拖拽，确认坐标空间正确（默认显示 2560×1600 @2×，截图为 1280×800 点）
  - [ ] 试 Cua Driver 的 embedded 模式：只给 ChatComputerAgent 授权就够用吗？行的话锁定一个版本，写 `CuaDriverAdapter`（实现 `DriverAdapter` 协议）；不行就继续用原生驱动
- [ ] **P7 virtio-fs**：inbox 只读、outbox 可写；宿主 `ExportValidator` 能拦住 guest 里构造的符号链接

## 3. 跑通 M1 闭环

- [ ] 完整走一遍首次引导（`Onboarding.swift` 的 6 步），修卡住的地方
- [ ] 配好 API Key，跑"打开 TextEdit，写一段话并保存到 outbox"，在宿主上导出文件
- [ ] 核对发给 API 的请求：`computer_toolset_20260801`、每个 `tool_result` 都带 `toolset_name`、截图尺寸在限制内

## 4. M1 之后（M2）

- [ ] 任务存储换成 SQLite（`AppModel.store` 目前是 `InMemoryTaskStore`，退出即丢）
- [ ] 宿主 App 重启后恢复任务：读取事件日志，进入"待检查"状态，重新截图后再继续
- [ ] `GuestCommand.cancel`：取消长时间的 `wait` / `hold_key`（`AgentService` 里的 TODO）
- [ ] 过期截图检测：动作带着 `observationVersion`，guest 端还没有校验
- [ ] 上下文增长：每轮截图都留在对话里，长任务会越来越大。不要在客户端删旧截图（会让后续 thinking 块失效），改用服务端的 tool result 清理
- [ ] 模型请求改为流式，聊天里实时显示进度说明
- [ ] 就绪探针：每次虚拟机启动或解锁后跑一次 health，不满足条件时显示"等待桌面登录或权限"
- [ ] 宿主 App 退出时调用 `suspend()` 挂起虚拟机，下次启动时恢复
- [ ] 重新评估 App Sandbox（目前为了 ssh 和读 DHCP 租约关闭了）
- [ ] 给 VMKit / GuestBridge / AgentCore 补测试（至少覆盖协议握手和 `KeyMap`）
- [ ] 加 CI：`scripts/test-linux.sh` 可以直接在 Linux runner 上跑
