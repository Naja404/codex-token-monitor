# 多供应商额度监控规格（阶段 A）

## 目标与范围

为现有 macOS 菜单栏应用增加 Antigravity CLI 额度和供应商开关设置。
本期支持 Codex、Antigravity，并按后续请求增加 Claude Code，不承诺检测任意 AI 软件。
Windows、应用名称、发布版本、现有回写协议和 Touch Bar 动画不在本期改动范围。

## 界面与默认行为

- 概览：约 360pt 宽，原生材质背景、系统字体、SF Symbols、柔和额度色；高度受屏幕限制，内容可滚动。
- 按供应商分组，仅展示已开启项。Codex 显示 5 小时、每周、附加额度及读取状态。
- Antigravity 显示 Gemini 和 Claude + GPT 两组，各自显示 5 小时、每周、百分比、重置日期时间。
- 不合并不同供应商或不同模型组的配额；无数据为占位符，不能伪造 0% 或 100%。
- 供应商设置为独立原生窗口，避免原弹窗无限变高或输入失焦；保留明显的返回/关闭路径。
- 设置中每个供应商列出开关、读取方式、检测结果、必要条件、重新检测/验证按钮。
- Codex 默认保持开启；Antigravity 默认关闭，用户开启后才定时读取。开关即时保存。
- 菜单栏保留紧凑两行和系统单色，默认固定 Codex；允许选择已开启的 Codex、Antigravity / Gemini、Antigravity / Claude + GPT 之一。用户追加需求支持可选自动轮播，间隔 5–60 秒、默认 10 秒；轮播不改变刷新频率、不自动混合最低值，弹窗打开时暂停切换。
- 关闭当前菜单栏来源时切换到另一个已开启来源；全部关闭时保留设置入口并显示“未启用”。
- 现有回写明确标注“Codex 回写”，不发送 Antigravity 数据；关闭 Codex 时停止后续额度请求和自动回写。
- Touch Bar 跟随菜单栏当前供应商/额度组，包括手动切换和轮播；刷新按钮只刷新当前供应商，小猫使用该组较低余量。未知值不回退成 Codex 数据，动画速度阈值保持不变。
- 额度弹窗与设置窗口复用原生 Touch Bar；应用/设置窗口重新获得焦点时恢复，离开应用后停止动画。关闭弹窗不能清掉仍在使用的设置窗口 Touch Bar。

## 检测与读取契约

### Codex

- 继续使用现有本机登录凭据和 OpenAI API，不增加用户手填令牌或替换 API 地址。
- 区分“发现凭据”“验证成功”“凭据失效/无额度”“网络失败”；本地文件存在不代表已验证登录。
- 不显示令牌内容；缺少条件时提示先在 Codex 登录。

### Antigravity

- 检测 agy 路径及版本（至少 1.1.11）；支持 PATH、常见安装位置和用户选择的可执行文件绝对路径。
- 使用参数数组执行，不拼接 shell 命令；仅运行 --version 和 -p /usage --output-format json --print-timeout 20s。
- 区分未安装、版本不支持、待验证、未登录、请求失败、可用；未安装时仍显示安装/登录指引。
- 启用后每 60 秒读取，提供手动刷新；单次进程最多 30 秒、输出最多 512 KiB，禁止并发重复查询。
- 在后台执行，使用独立临时工作目录，不将项目文件作为上下文发送。凭据由 CLI 管理。
- 只接受 SUCCESS 且 command.name 为 usage 的结构化报告；有模型对话迹象时停止自动查询并提示更新 CLI。
- 读取 groups[].buckets[] 的 remaining_fraction、window、reset_time；跳过 disabled 和无效值，保留缺失窗口的不可用状态。
- 关闭后取消本应用发起的查询，忽略迟到结果；不得终止用户自己运行的 agy。
- CLI 出错只显示安全分类和恢复指引，不在界面或日志泄露原始凭据或完整 stderr。
- 刷新失败清楚标记失效状态，不将上次结果当成最新成功；记录每个供应商独立成功时间。

## 技术栈与工程位置

### Claude Code 追加范围

- 用户选择独立刷新：只读默认本机 Claude Code OAuth，固定请求 Anthropic `/api/oauth/usage`，不转发第三方，不调用模型、不刷新或修改凭据。
- macOS Keychain 优先，仅条目不存在时读取默认 `.claude/.credentials.json`；自定义配置目录和多账号不在本次范围。
- 默认关闭，独立开关、验证按钮、成功时间和错误指引。只有主动验证允许钥匙串交互。
- 5 分钟自动刷新，失败退避，遵守更长的 Retry-After，限流冷却不能被手动刷新或开关绕过；认证错误暂停自动刷新。
- 五小时和每周百分比为 100 - utilization，重置日期可缺失，未知不伪造。与 Antigravity Claude + GPT 独立，回写仍只发送 Codex。
- 验证：解析边界、认证错误、取消和迟到结果、开关与轮播、Touch Bar 路由；真实查询需本机有效订阅登录，不用测试数据代替真实验证。

### 文件

- Swift 6、SwiftUI + AppKit、macOS 14+，继续使用当前 Swift Package，不新增依赖。
- Sources/AppMain.swift：由 main.swift 重命名，保留 @main 入口、Codex 额度模型、菜单栏、弹窗定位和 Touch Bar。
- Sources/AntigravityReader.swift：CLI 检测、受限后台进程、响应解析和安全错误分类。
- Sources/ClaudeUsageReader.swift：只读 OAuth 凭据、Anthropic 额度请求与解析。
- Sources/ProviderStore.swift：供应商开关、刷新状态与菜单栏来源。
- Sources/ProviderViews.swift：额度概览、独立设置及 Codex 回写入口。
- Tests/CodexTokenMonitorTests/：Swift Testing 解析、状态及进程边界测试。
- docs/：本规格；README.md：实现完成后补充条件、配置和使用说明。

## 命令

在仓库根目录执行：

```sh
swift test
swift build -c release
swift run
git diff --check
```

## 代码风格

保持现有四空格、描述性类型命名、UI 状态使用 MainActor；耗时工作不阻塞主线程。
沿用已有额度模型风格，例如：

```swift
@Published private(set) var fiveHour: QuotaWindow?
@Published private(set) var weekly: QuotaWindow?
```

不为未来未接入的供应商搭建插件框架；优先最小可测的读取边界。

## 验证策略与成功标准

- 先写失败测试，再实现：真实结构样本四个窗口、仅每周、空数据、缺字段、disabled、非法比例/日期、非 usage 报告。
- 进程边界测试：成功、非零退出、超时、大输出、取消，确认不阻塞 UI、不遗留自建进程。
- 设置测试：默认值、持久化、关闭后不刷新/不回写、菜单栏来源回退、迟到结果丢弃。
- 保留现有全部 Codex 解析及 Touch Bar 测试并运行完整测试集。
- 本机 agy 真实查询验证；只读查询，不发送模型任务、不打印登录凭据。
- 视觉与交互验证：浅/深色、键盘焦点、错误和加载状态、长路径、设置窗口输入、弹窗滚动、多屏定位回归。

## 边界

- 始终：保护凭据、后台读取、清晰区分检测与验证、保留用户现有设置和未提交改动。
- 先询问：新增供应商范围、修改回写协议、安装 CLI、自动发起登录、Windows 同步、GitHub 推送及发布。
- 禁止：提交凭据、默认启用新供应商的轮询、未知额度显示为正常额度、运行用户模型提示词、终止用户的 CLI 进程。

## 执行计划

用户已确认分阶段计划并要求执行。本轮交付阶段 A，不提交或发布 GitHub。

1. CLI 读取与解析：新增 Antigravity 读取器和通用百分比指标/额度组，测试真实结构、缺失窗口、错误、超时、取消和输出上限。
2. 供应商状态：新增独立设置/刷新状态；Codex 接入开关，禁止关闭后的请求与回写；测试持久化、菜单栏回退与迟到结果。
3. 界面：360pt 概览、独立设置窗口，保留原生多屏定位和 Codex Touch Bar；验证浅深色、滚动、键盘和加载状态。
4. 回归与文档：完整 Swift 测试、Release 构建、真实 CLI 只读验证；README 明确未发布和 Windows 功能差异。

每步通过验证后进入下一步。SwiftUI/AppKit 保持原生；不建立动态插件或任意脚本运行框架。

## 本轮验证记录（2026-10-10）

- `swift test` 通过：解析、单飞查询、关闭后不查询/不回写、迟到结果、菜单栏回退、错误退避和已有 Codex / Touch Bar 回归。
- CLI 进程边界通过：输出/退出码、超时、输出上限、启动后取消、仅清理自建进程组；Homebrew 符号链接可识别。
- 本机 agy 1.3.2 实测通过：读取到两个额度组、四个窗口；只输出结构数量，不记录凭据或原始报告。
- 原生设置窗口 CLI 输入框可成为 first responder；浅色/深色概览和设置页已渲染检查，README 配图明确为测试示例数据。
- `swift build -c release` 和 `git diff --check` 通过。
- 尚需人工实机验收：两块显示器的首次弹窗定位、实际 Touch Bar 激活/动画、系统缩放和完整键盘操作。保留原定位与动画实现，不把离屏渲染视作真机交互测试。
- 未修改 Windows、未替换“应用程序”中的安装包、未创建 GitHub 提交或 Release。
