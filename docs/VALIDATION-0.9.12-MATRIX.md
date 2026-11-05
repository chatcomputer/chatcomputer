# 0.9.12 当前候选验收矩阵

本表按 [NEXT-RELEASE.md](NEXT-RELEASE.md) 的完整范围核对，当前构建为 **73**。日期：2026-11-04。未验证不等于失败，也不等于通过；本表不是发布批准。

73当前已通过197项Swift、本机Mac构建/接口检查、原生回调探针、固定Developer ID签名、公证与Gatekeeper；内置模型检查缺配置而跳过。真实73内存快照连续恢复30/30，两份CLI/MCP文件及正常退出重开通过；源72/73内存哈希不变，本轮没有触发终态错误恢复分支，不能宣布原偶发故障修复。见 [73构建](../scripts/regress/results/2026-11-04-0.9.12-73-build.manifest.json)、[73生命周期](../scripts/regress/results/2026-11-04-0.9.12-73-lifecycle.manifest.json)。下面保留72的完整逐项记录作为历史，不将72成绩转记为73通过；73其余完整矩阵尚未完成。

72修正输入后的MCP重跑只完成10/20（已完成10项通过），下一项调用模型前恢复快照失败，比较监督器停止，43尚未执行。系统记录为Virtualization服务GUARD终止，唯一根因未证明。73增加显式stop终态错误处理和有界生命周期元数据，并非已证明修复Kernel终止。证据见 [72中断记录](../scripts/regress/results/2026-11-04-0.9.12-72-codex-short-mcp-input-v2-incident.manifest.json)。

## 73当前矩阵

旧input-v3成对比较已因版本闸门缺陷停止：43保存前实际guest73，但工具误匹配了“本App携带43”的提示。旧43的11项成绩不用于对比，原准备通过结论撤回；73原分数保留为旧工具单边结果。67项脚本检查和新严格43基准3次恢复通过，input-v4已按同一冻结工具重开，先执行43再升级及执行73。见 [闸门修正](../scripts/regress/results/2026-11-04-benchmark-guest-readiness-fix.manifest.json)、[新比较配置](../scripts/regress/results/2026-11-04-benchmark-comparison-v4-setup.manifest.json)。73旧单边三份PDF正文已全部补核对通过；新比较尚无完整结论。

| 验收项 | 73结果 | 证据或下一步 |
|---|---|---|
| 包测试、Debug构建、底层接口 | 通过：八个Swift测试组共197项 | [构建清单](../scripts/regress/results/2026-11-04-0.9.12-73-build.manifest.json)；内置live检查缺配置而跳过 |
| 回归脚本失败注入、文件验证器 | 67项Python、9项原生文件检查及harness构建通过 | [版本闸门修正](../scripts/regress/results/2026-11-04-benchmark-guest-readiness-fix.manifest.json)；App/guest二进制未改 |
| 发布签名、agent最低26、公证与Gatekeeper | 通过；未发布 | 73构建清单 |
| 原生停止回调归属、显式停止的终态规则 | 原生回调探针与终态/过渡态单元覆盖通过 | 不能据此证明Kernel GUARD根因修复 |
| 同一隔离27 VM内存恢复、源文件不变 | 30/30；无冷启动回退；源72/73内存哈希不变 | [生命周期清单](../scripts/regress/results/2026-11-04-0.9.12-73-lifecycle.manifest.json)；未触发终态错误恢复分支 |
| CLI/MCP真实文件、宿主内容/哈希、正常退出重开 | 通过 | 同上；不是新装或模型回归 |
| 27.x全新安装A/B、两帧、首任务/重开 | 待执行 | 每次新空目录；旧构建安装不转记 |
| 26.x全新安装A/B、两帧、首任务/重开 | 待执行 | 固定26.6.2 /25G83镜像；文件功能与模型首任务分别记录 |
| 第二台Mac、用户反馈的27.2组合 | 未验证：缺硬件及具体版本信息 | 用户已确认没有第二台Mac |
| 26.x、27.x原生输入各3/3 | 待执行 | 必须实际73 guest和真实文件 |
| 签名43升级到73、旧43内存快照 | 27 guest实际升级/旧43 RAM/两文件重开通过；26待执行 | [27升级证据](../scripts/regress/results/2026-11-04-0.9.12-73-upgrade43-native-v4.manifest.json)；旧43 RAM与严格43基准哈希一致，不是43新装 |
| 新闸门下的43基线三组 | CLI/MCP各19/20、long6/6，全部实际版本43；73 CLI已开始 | [43 CLI](../scripts/regress/results/2026-11-04-0.9.11-43-codex-short-cli-input-v4-review.manifest.json)、[43 MCP](../scripts/regress/results/2026-11-04-0.9.11-43-codex-short-mcp-input-v4-review.manifest.json)、[43 long](../scripts/regress/results/2026-11-04-0.9.11-43-codex-long-cli-input-v4-review.manifest.json)；PDF正文待核对，成对比较未关闭 |
| Codex CLI short20 | 新闸门73运行中；旧单边19/20不转记 | [原收尾审计](../scripts/regress/results/2026-11-04-0.9.12-73-codex-short-cli-input-v3-acceptance.manifest.json)仅保留旧分数；新组结束后另行封存 |
| Codex MCP short20 | 旧工具单边程序19/20，审批/注入独立复核通过；新比较待执行 | [原收尾审计](../scripts/regress/results/2026-11-04-0.9.12-73-codex-short-mcp-input-v3-acceptance.manifest.json)；表单要求许可未生成验证码 |
| 外部6项long与同环境43比较 | 旧工具73程序6/6，额外文件/UI检查通过；新成对比较待执行 | [原73收尾审计](../scripts/regress/results/2026-11-04-0.9.12-73-codex-long-cli-input-v3-acceptance.manifest.json)；完整前后比较未关闭 |
| 73旧单边三份PDF正文 | 全部通过：各一页，正文与目标一致 | [补充正文验证](../scripts/regress/results/2026-11-04-0.9.12-73-pdf-body-addendum.manifest.json)；原历史清单不改写 |
| 内置DeepSeek三轮、Anthropic两轮、内置long比较 | 未验证：缺模型配置 | 保留原门槛，不用Codex代替 |
| 4.3小时真实模型soak、任务中退出/继续、快照与内存 | 未验证：缺模型配置 | 不用30次无模型恢复或外部回归代替 |
| 两种guest的权限故障和诊断矩阵 | 待执行 | 遮挡/合并/取消/拒绝重授/身份失效/截图超时；三类无图诊断、显式一图和秘密扫描 |
| 代码与已结束证据提交推送 | 已推送49d085d，包含严格43三组及27升级结果 | 后续结果逐组收录；无发布tag或Release |
| 临时空间控制 | 本次检查约160GiB可用；模型、构建、新装串行 | 单版本仅保留一份工作VM及共享恢复镜像；完成后清理可重建副本 |

## 72历史矩阵（已结束）

环境：一台 Apple Silicon Mac（Mac18,5），host 27.0.1 / 26A434；现有隔离 guest 27.0.1 / 26A434。用户反馈的“27.2”属于 host 还是 guest、具体 build 均未确认。第二台Mac不可用；内置模型测试配置尚不可用。

| 验收项 | 72当前结果 | 证据或下一步 |
|---|---|---|
| 包测试、脚本失败注入、Debug构建、底层接口 | 通过：194项Swift、50项Python | [构建清单](../scripts/regress/results/2026-11-04-0.9.12-72-build.manifest.json) |
| 回归输入隔离、复制/文件集/索引校验修正 | 59脚本、9原生检查及harness构建通过；真实整理单项通过 | [工具修正](../scripts/regress/results/2026-11-04-benchmark-input-isolation-fix.manifest.json)、[真实单项](../scripts/regress/results/2026-11-04-0.9.12-72-codex-long-cli-input-v2-smoke-acceptance.manifest.json)；不计完整suite |
| 固定Developer ID、agent最低26、发布签名、公证、Gatekeeper | 通过；未发布 | 同上，实际App/agent/zip指纹及日志哈希 |
| 原生停止回调归属 | 修复前失败、修复后通过 | `scripts/test-vm-callbacks.sh`；仅原生回调不变量，不是原71恢复错误的根因证明 |
| 未改动71内存快照恢复、实际agent升级、两帧重验 | 连续5次通过 | [生命周期清单](../scripts/regress/results/2026-11-04-0.9.12-72-lifecycle.manifest.json) |
| 同一隔离VM的CLI/MCP文件、宿主内容/哈希、正常退出重开 | 通过 | 同上；不是新装或模型回归 |
| 27.x全新安装A、B，各两帧和首任务/重开 | 待执行 | 必须新空目录；71/70安装不计入72 |
| 26.x全新安装A、B，各两帧和首任务/重开 | 待执行 | 固定26.6.2 / 25G83镜像；缺内置配置时功能文件与模型首任务分记 |
| 第二台物理Mac、用户报告组合 | 未验证：缺硬件/版本信息 | 不宣称已覆盖 |
| 26.x、27.x原生输入，各3/3 | 待执行 | 必须实际72 guest，不能只核对健康状态 |
| 实际签名43升级到72、旧43内存快照恢复 | 待执行 | 71快照恢复不能代替43；保留原签名43二进制 |
| 外部Codex CLI short20 | 修正后20/20，审批/注入通过 | [isolated-inputs-v2审计](../scripts/regress/results/2026-11-04-0.9.12-72-codex-short-cli-input-v2-acceptance.manifest.json)；43比较未完成 |
| 外部Codex MCP short20 | 修正后10/20即恢复失败中断，未通过 | [中断记录](../scripts/regress/results/2026-11-04-0.9.12-72-codex-short-mcp-input-v2-incident.manifest.json)；原规则成绩不计新比较 |
| 外部长任务6项及43同环境对照 | 原程序6/6，但整理项独立复核失败；新规则待重跑 | [误报复核](../scripts/regress/results/2026-11-04-0.9.12-72-codex-long-cli-verification-review.manifest.json)；43尚未执行 |
| 内置DeepSeek short三轮、每轮至少19/20 | 未验证：缺配置 | 保留原门槛，不以Codex替代 |
| 内置Anthropic short两轮40/40 | 未验证：缺配置 | 审批/注入必须通过；不要求Claude Code登录 |
| 内置agent长任务及修改前后对照 | 未验证：缺配置 | 与外部客户端检查分别记录 |
| 至少4.3小时真实模型soak、任务中退出/继续、快照、内存曲线 | 未验证：缺配置 | 不用空闲VM或历史长跑替代 |
| 代码、证据、文档提交推送 | 代码修复已推送（1cc280c），后续结果逐组收录 | 运行中的JSONL/清单不能提前密封提交 |
| 临时空间控制 | 继续监测；串行VM/模型/构建 | 已清理历史大文件；新一轮不积累重复工作VM |

故障恢复要求在两个guest版本分别执行：

| 场景 | 26.x / 72 | 27.x / 72 | 判定要求 |
|---|---|---|---|
| 系统设置遮挡本agent的系统确认 | 待执行 | 待执行 | 观察并揭示对应弹窗；不能泛化点击任意Allow |
| 引导、菜单同时重试与重复点击 | 待执行 | 待执行 | 同一流程、同类请求不积累、不因重试reset |
| 授权中取消、手动继续 | 待执行 | 待执行 | 安全停止，保留进度，实际操作后可继续 |
| 拒绝后再授权 | 待执行 | 待执行 | 拒绝不被自动越过，清楚提示，可主动恢复 |
| agent重启或断连 | 待执行 | 待执行 | 旧截图成功立即失效；未验证前不得冻结初始基准 |
| 实际截图失败/超时、恢复 | 待执行 | 待执行 | 健康成功不能替代像素验证；有界等待与明确错误 |
| 同签名43升级、旧43快照 | 待执行 | 待执行 | 实际agent72、授权保持、截图与输入可用 |
| 诊断：未连接、未授权、截图失败 | 待执行 | 待执行 | 用预设故障和秘密值核对脱敏文本；能判断失败阶段 |
| 诊断画面选择 | 待执行 | 待执行 | 默认无PNG，显式选择后仅预期的一张；不自动上传 |

尚未关闭的问题：71首次模型前恢复内存快照时Virtualization服务终止，72完整MCP重跑再次出现；不能以中间成功的恢复宣布根因已修复。旧26会话两次恢复不应答的唯一根因亦未确认。原错误及资源条件混杂保留，发布验收仍未通过。
