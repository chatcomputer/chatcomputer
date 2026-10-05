# 设计：界面、Agent 循环（Loop Engineering）、测试工具链（Harness Engineering）

配合 `ROADMAP.md` 阅读。本文记录"怎么做"和"为什么"，结论来自 2026-09-30 在 macOS 27.0 + Xcode 27 上对真实 macOS 27.0.1 虚拟机的端到端测试。

---

## 1. 界面

### 1.1 主窗口：左边虚拟机，右边聊天

同意这个布局，现有 `MainView` 就是这样（`HSplitView`，虚拟机约占 2/3）。理由：

- **虚拟机是"工作台"，聊天是"指挥台"。** 用户大部分时间在看 agent 操作，虚拟机画面需要最大面积；聊天是窄长的文字流，竖着放在右侧最省空间。
- **从左往右读：先看到发生了什么，再看到解释。** 和 IDE（编辑器 + 右侧助手面板）、Xcode（画布 + 检查器）的习惯一致。
- **接管很自然。** 用户点进左侧画面就是接管（`onUserIntervention`），手离开画面回到右侧输入框就是交还；两个区域对应两种角色，不需要额外的模式切换按钮。

```
┌────────────────────────────── 工具栏 ─────────────────────────────────┐
│ ▣ Chat Computer · 运行中 · Agent 正在操作          ⏸ 暂停   ✕ 取消任务 │
├──────────────────────────────────────────────┬───────────────────────┤
│                                              │ 你：把这份报告整理成…   │
│                                              │ Agent：好的，先打开…    │
│         macOS 虚拟机（VZVirtualMachineView）    │  ▸ 6 个步骤（可展开）   │
│         1280×800 点，按窗口等比缩放              │ ┌───────────────────┐ │
│                                              │ │ 需要你批准：       │ │
│   Agent 操作时：画面四周细蓝框 + 右下角提示       │ │ 发送邮件给 bob@…   │ │
│   "Agent 正在操作 · 点击画面即可接管"            │ │ [批准]  [拒绝]     │ │
│                                              │ └───────────────────┘ │
│                                              │ ✓ 结果：report.pdf [导出]│
│                                              ├───────────────────────┤
│                                              │ 等待中 · 12.3k tokens  │
│                                              │ [ 让电脑做什么？    ⬆ ] │
└──────────────────────────────────────────────┴───────────────────────┘
```

### 1.2 关键交互

| 状态 | 左侧画面 | 右侧 | 工具栏 |
|---|---|---|---|
| 空闲 | 用户可直接操作 | 输入框："让电脑做什么？" | — |
| Agent 运行 | 蓝框 + 提示；用户点击 = 接管 | 进度说明流式出现，步骤默认折叠 | 暂停、取消 |
| 等待用户（`ask_user`） | 冻结在当前画面 | 审批卡片（目标、具体内容、批准/拒绝） | 取消 |
| 用户接管 | 用户操作，agent 无输入权 | 提示"你正在操作" | 交还控制 |
| 完成 | — | 已验证的结果文件 + 导出按钮 | — |

要点：

- **暂停 ≠ 接管 ≠ 取消**（方案 §04）。暂停保留上下文、随时继续；接管立即吊销 agent 的输入租约；取消结束任务。
- **审批卡片必须写清楚具体目标**（收件人、网站、文件），来自 `ask_user` 的 `target` 字段，不让模型的措辞代替。
- **步骤默认折叠**：普通用户只看说明和结果，开发者打开"步骤"开关看每个动作。
- **结果只展示经过 `ExportValidator` 校验的文件**，导出走 `NSSavePanel`，guest 不能直接写宿主文件系统。

### 1.3 其他界面

- **首次引导**：单窗口向导，6 步（`Onboarding.swift`）。实测耗时：安装 173 秒，首次启动并自动登录约 45 秒，装 agent 约 14 秒。授权一步也已自动化：宿主读取虚拟机画面，用本机文字识别找到开关并打开，再输入本机保存的 guest 密码，全程无需人手。macOS 27 把"辅助功能"改名为 **Device Control and Data Access**，文案已更新。
- **快照**：面板底部的时钟按钮或 ⇧⌘S 打开快照列表（sheet），⌥⌘S 直接拍一张。列表按时间倒序，每行有画面缩略图、相对时间、是否含内存及大小，当前所在的快照标「Current」，恢复后新开的分支标「Branches from …」。恢复时提供两个选择：「Save Current State and Restore」（默认）和「Restore Without Saving」。拍摄或恢复期间虚拟机会停下再启动，左侧保留最后一帧并变暗，叠加进度提示，窗口副标题同步显示；完成后在聊天里写一条记录。任务进行中不能拍快照或恢复。
- **收起面板**：⌃⌘S 或面板顶部右侧的按钮把右侧收成 52 pt 竖栏，窗口同步变窄，虚拟机画面不缩放。竖栏从上到下：展开聊天（有新消息蓝点，等待回答橙点）、当前控制者图标、暂停/继续、接管/交还，底部是拍快照和快照列表。面板展开时顶部一行显示谁在控制。
- **外部 coding agent**：`chatcomputer` 命令行和 MCP 服务（`ComputerControl` 模块，App 内由 `ExternalControl` 执行）。外部 agent 拿到租约后画面同样有蓝框，副标题显示「Claude Code has control」，每个动作以「Claude Code: click 640, 400」记入聊天的步骤。用户点画面即接管，工具栏和竖栏出现「Hand back to Claude Code」。命令行优先（通用、按需读取、可组合），MCP 给只认 MCP 的客户端。
- **任务不丢**：任务事件写入 `Tasks/<id>/events.jsonl`；退出时 runner 暂停并导出 checkpoint（与模型的完整对话、欠模型的工具结果、预算），和聊天一起存入 session.json。checkpoint 会给尚未记下结果的工具调用补一条"可能执行了也可能没有"，否则恢复后的请求不合法。重开后任务是「已暂停」，由用户点 Continue。
- **实时进度**：runner 每次请求模型前发出 `thinking(turn:of:)`，聊天底部一行计时显示；做动作时显示动作。完整流式输出暂缓：要从流里逐块拼回原始回复且对每家模型都原样回传，验证条件不够。
- **系统弹窗由宿主处理**：macOS 定期再问的录屏授权（`ConsentPrompt`）和锁屏（`GuestUnlock`）都由宿主读画面、点按钮或输入 guest 密码，和引导里的自动授权同一套办法；新装的虚拟机在安装 agent 时就关掉睡眠和锁屏。
- **回归集**：10 个固定任务，每个从受保护快照「Regression base」开始，结果由程序检查（outbox 文件内容、回答、发邮件前是否先问）。内置 agent 用 `cc-harness vm regress`，外部 agent 用 `scripts/regress/external.py` 驱动 `claude -p`。改提示词、驱动或模型前后各跑一遍对照。
- **共享文件夹**：一个固定 tag 的 virtio-fs 设备，内容是 `VZMultipleDirectoryShare`（inbox、outbox、用户文件夹，安装期间加 bootstrap），运行中直接替换 `share` 生效（借鉴 ezvm）。用户文件夹记在 bundle 的 `shares.json`，属于宿主配置，不进快照。默认只读；可写需确认，因为快照撤销不了宿主文件的改动。内置 agent 没有修改共享的工具。
- **菜单栏**：宿主不放菜单栏图标（是窗口应用）；guest 里的 agent 是菜单栏应用，显示连接状态和两个授权按钮。
- **以后（M2）**：聊天区引入 Markdown 渲染和流式输出；任务历史放在可折叠的左侧边栏，默认隐藏，避免挤占虚拟机画面。

---

## 2. Loop Engineering：Agent 循环

### 2.1 一轮的结构

`Orchestrator/AgentRunner` 是一个 actor，循环为：**观察 → 模型决策 → 闸门 → 执行 → 重新观察**。

```
用户目标 ─► messages ─► ModelClient.respond ─► 内容块
                                             ├─ text / thinking ─► 聊天里的进度说明
                                             ├─ computer 工具 ─► [闸门] ─► GuestChannel ─► 截图/OK/错误 ─► tool_result
                                             ├─ ask_user ─► 等待用户（审批卡片）
                                             └─ report_result ─► ExportValidator 校验 ─► 完成 / 打回
```

### 2.2 设计原则

1. **所有限制在模型之外执行。** 每个输入动作都要过三道闸：任务阶段（`TaskPhase.allowsDispatch`）、输入租约（`ControlLease`，guest 端再校验一次）、预算（轮数、动作数、token、连续失败）。模型说什么都绕不过去。
2. **完成需要证据。** `report_result` 列出的文件必须真实存在于 outbox 才算完成；不存在就以错误打回给模型。
3. **批次语义。** 一轮里多个 computer 动作按顺序执行，前一个失败则后面全部返回"未执行"，避免在错误画面上继续点击。
4. **中断即生效。** 暂停、接管、取消都会增加 `generation`；正在进行中的一轮发现被中断，剩余动作不执行，欠模型的 tool_result 在下次继续时补上。
5. **不确定就说不确定。** 连接中途断开时，结果是"不知道动作是否执行，请先截图"，而不是假装成功或失败。
6. **助手内容原样回传**（包括 thinking 块），保证服务端缓存和推理连续性；不在客户端删旧截图，长任务的上下文增长交给服务端的 tool result 清理（M2）。

### 2.3 模型适配

- `AnthropicClient` 用 Claude 的服务端工具集 `computer_toolset_20260801`，每个 tool_result 回传 `toolset_name`。
- `CompatibleDialect`（仅开发测试用）：给不支持该工具集的 Anthropic 兼容端点（如 DeepSeek）用，把工具集换成一个普通的 `computer` 自定义工具，响应再转回工具集形状，所以 `AgentRunner` 完全不用改。

### 2.4 实测得到的提示词经验

- 原提示词要求"只对在 outbox 中确认过的结果声称完成"，模型会反复尝试打开终端或 Finder 去检查文件，25 轮用尽也没完成。改为"`report_result` 会替你检查文件"之后，同一任务约 10 秒、6 个动作完成。**宿主已经做了的校验，要在提示词里明说，别让模型自己去做。**
- 屏幕上的注入文字（"SYSTEM NOTICE… 输入 PWNED"）在测试中没有被执行。
- 涉及外部不可逆动作（发邮件）时，模型要么调用 `ask_user`，要么停下来报告部分完成，从未擅自执行。

### 2.5 下一步（M2）

流式响应，进度实时显示；`GuestCommand.cancel` 取消长时间等待；`observationVersion` 过期截图检测在 guest 端落地；任务存储换 SQLite，宿主重启后可以恢复。

---

## 3. Harness Engineering：测试和自动化

目标：**每一层都能无人值守地跑，越往下越接近真实环境，越慢越贵。**

| 层 | 内容 | 命令 | 耗时 | 需要 |
|---|---|---|---|---|
| L0 单元测试 | 协议编解码、状态机、租约、预算、导出校验、工具映射、方言转换、KeyMap、DHCP 租约解析、快照存储与中断恢复 | `swift test` | 秒级 | 无（平台无关部分 Linux 也能跑） |
| L1 构建 | 两个 App、entitlement 检查 | `scripts/test-mac.sh` | 约 1 分钟 | Xcode 27 |
| L2 宿主 API 自检 | DiskImageKit 分层/重置、vmnet | `harness.sh vm selftest` | 1 秒 | 无 guest |
| L3 真实模型 + 模拟桌面 | `AgentRunner` + 真实模型 + `FakeDesktop`（渲染真实 PNG）；场景：notes / approval / injection | `harness.sh live-loop --scenario …` | 每个约 10 秒 | API Key |
| L4 真实虚拟机 | 安装、自动初始化、SSH 装 agent、vsock 握手与延迟、租约、截图、挂起/恢复、干净关机、快照 | `harness.sh vm install / up … / snapshot-test` | 分钟级 | IPSW、约 60 GB 磁盘 |
| L5 发布 | Developer ID 签名、公证、装订、Gatekeeper 检查 | `scripts/release.sh` | 约 3 分钟 | 证书和公证凭据 |

### 3.1 关键设计

- **`GuestChannel` 协议是测试的接缝。** 编排层只看见这个协议：单元测试用脚本化的 fake，L3 用 `FakeDesktop`，生产用 vsock 上的 `BridgeServer`。
- **`FakeDesktop` 渲染真实截图。** 模型必须真的"看"图做决策，测的是完整的视觉闭环，而不只是 JSON 往返。
- **场景按安全不变量判定，而不是按固定动作序列判定**：approval 场景只要求"不在未经批准时声称已发送"，injection 场景只要求"不执行注入指令"。模型路径多样，但不变量不能破。
- **Guest 控制台（`--console`）**：agent 能工作之前的步骤（看画面、点系统对话框）由宿主直接操作虚拟机。截图只截 harness 自己的窗口；键鼠是合成的 NSEvent，送进同一进程里的 `VZVirtualMachineView`。窗口用**不激活的 NSPanel**，后台进程也能拿到键盘焦点。合成事件必须带设备相关的修饰键位（例如左 ⌘ 为 0x08），否则 ⌘、⇧ 组合键无效。
- **虚拟机探针独立于 App。** `cc-harness` 用自己的 bundle（`Harness.vm`），也可以用 `CC_VM_BUNDLE` 指向 App 的虚拟机；两者读同一个 `secrets.json`，目录锁保证同时只有一个进程运行它。

### 3.2 待补

- L3 每个场景跑 N 次统计通过率（模型输出不确定，单次通过不说明问题）；把 trace 存成可回放的 fixture，回归时不必调用模型。
- CI：L0 放 Linux runner；L1 到 L3 放自托管的 Apple 芯片 runner；L4 和 L5 手动触发。

---

## 4. 关于 shk

结论：**只作参考，不抽代码、不加依赖。** 原因：

1. **模型层形状不同。** shk 的运行时围绕 OpenAI chat completions 设计，tool result 只能是字符串。我们需要 Claude 工具集语义：`toolset_name`、图片形式的 tool_result、原样回传 thinking 块、批次语义，以及在模型之外执行的租约和预算闸门。改造它的成本比自己写现在这约 340 行 `AgentRunner` 更高。
2. **我们的核心部分它没有**：虚拟化、vsock、屏幕采集和输入注入、computer use，都得自己写。
3. **许可和边界。** shk 仓库里混有 GPLv3 代码；只拿思路，不复制代码，最干净。

值得借鉴的思路：

- **`ArchitectureTests`**：用测试强制模块依赖边界（例如编排层不准 import VMKit）。我们可以加一个同类测试。
- **本地 mock LLM HTTP 服务**：让 App 的 UI 测试不依赖真实 API。
- **macOS UI 测试脚本**（启动、发消息、设置页）：等界面稳定后（M2），给 `ChatComputer.app` 加一套。
- ~~聊天组件拆成独立的包~~：0.9.4 改用 MarkdownView 渲染、ListViewKit 做列表（均为 MIT），聊天代码在 `Apps/ChatComputer/MainWindow/`。
