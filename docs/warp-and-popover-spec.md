# Warp 接入与简介 / 明细弹窗

状态：用户已确认继续实现。2026-10-10。

## 执行计划与实际选择

1. Warp 解析、请求和生命周期 → 验证 Credits、未知值、限流、取消、鉴权错误测试。
2. 默认简介 / 明细、离线品牌图标、Touch Bar 同源 → 验证原生预览、资源加载和交互状态测试。
3. README、截图与睡眠 GIF → 验证全量测试、Release 编译和资源打包路径。

已从 [CodexBar 的 Warp 接口实现](https://github.com/steipete/CodexBar/blob/main/Sources/CodexBarCore/Providers/Warp/WarpUsageFetcher.swift) 确认查询协议，独立实现只读请求与严格解析。选择官方支持创建的个人 API Key：未确认可安全复用的本机登录会话协议，因此不扫描 Warp 私有登录存储、不刷新会话。用户在设置中提供自己的 Key，保存在本应用专用钥匙串项；无需安装 Warp CLI。真实账户连接仍需用户填入 Key 后验证。

接口为 `POST https://app.warp.dev/graphql/v2?op=GetRequestLimitInfo`，只请求个人 `requestLimitInfo` 和 `bonusGrants`，不请求或累加 `workspaces`。额度查询属于客户端内部接口，不能视为稳定的公共 API。

## 目标

在 macOS Monitor 中加入 Warp 的真实 Credits 额度，并让多供应商余量可以一眼扫读。
只调整本轮功能，不改变现有 Codex 回写协议、各供应商凭据、不发布 GitHub。

## 产品行为与验收

### Warp

- 新增供应商设置卡片：独立开关、连接验证、最近成功时间、错误与恢复指引，默认关闭。
- 优先验证本机 Warp 登录凭据的只读使用方式；只请求 Warp 官方服务，不运行 AI 对话，不修改、撤销或刷新原应用凭据。
- 已在本机客户端发现 GraphQL `/graphql/v2`、`GetRequestLimitInfo` 及额度字段，并通过公开实现确认查询与鉴权协议；真实账户响应仍需用户配置个人 Key 验证。
- 若本机登录凭据无法安全使用，报告具体原因；采用手填 Warp API Key 之前确认可用性，若需要新增授权则向用户说明。密钥只能本机安全保存，不进入日志、README 或 Git。
- 有效上限和已用量都已返回时计算剩余量及百分比；显示账户周期余量、重置日期，额外 Credits 单列。
- 不把 Credits 命名为 tokens，不捏造 5 小时或每周额度，不混合个人和团队额度。无上限、无月度额度、缺失或过期数据分别标识。
- 开启后约 5 分钟刷新；失败退避、遵守服务端限流，认证失败暂停自动读取，关闭后取消查询并忽略迟到结果。
- 参与菜单栏固定展示与轮播；Warp 两行分别展示周期余量与重置日期。Touch Bar 使用相同数据源和实际指标，小猫仅在存在有效百分比时联动。
- 用户追加：无任何有效额度或当前关联余量低于 10% 时，小猫趴下睡觉；10% 及以上保持原有动作分级。睡眠为闭眼、收脚、慢呼吸及 Z 标记，无数据的额度文字仍为占位符。

### 简介 / 明细

- 顶部固定分段控件：简介 / 明细。每次打开额度弹窗默认简介；切换不发起额外网络请求。
- 简介：仅显示已开启供应商，紧凑排列 Logo、名称、带窗口标签的余量和短状态；尽量同屏看到四家供应商。
- Codex、Claude Code 各显示 5h / 7d；Antigravity 保留 Gemini、Claude + GPT 两行，不合并百分比；Warp 使用 Credits / 周期标记。
- 不把最低余量做成跨供应商总分。未知数值显示 —；异常时简介仍保留简短警告，不隐藏错误。
- 明细：展示每组进度条、重置日期、数据来源、最近成功时间、完整错误与已有附加额度。
- 顶部刷新、底部设置与退出始终可见；内容超过屏幕高度时滚动。切换模式保留弹窗锚点，不重建原生 Touch Bar。
- 不调整已有多屏定位、自动失焦关闭、菜单栏轮播暂停规则；纳入回归检查。

### 视觉方向

- 科技感来自紧凑仪表盘布局、等宽数字、细分隔、低饱和蓝青点缀，而非高亮霓虹、闪烁、装饰性假图表。
- 浅色与深色跟随系统；继续使用系统字体和原生材质，文字对比优先于透明效果。
- 用供应商官方 Logo 替代通用符号：Codex、Antigravity、Claude、Warp。资源来源与使用条件须可追溯，不用 AI 绘制或自行臆造品牌标记。
- 图标等尺寸，保留原比例与必要留白；随应用打包，运行时不加载远程图片，不依赖同事安装相同应用。
- 品牌色用于识别，额度颜色仍按现有柔和绿 / 橙 / 黄 / 红分级；同时保留数字和文字状态，不能只靠颜色传达含义。
- 切换即时响应，最多短淡入；尊重减少动态效果、减少透明度与增强对比度。

## 技术栈与工程位置

- Swift 6、SwiftUI + AppKit、macOS 14+，不新增第三方 UI 框架。
- Sources/WarpUsageReader.swift：待新增，只读凭据 / 网络边界 / 响应解析。
- Sources/ProviderStore.swift：Warp 生命周期、开关、数据源与轮播。
- Sources/ProviderViews.swift：简介、明细、Warp 设置及可访问性。
- Sources/AppMain.swift：仅修改指标呈现 / 打开时简介状态等必要连接，不改多屏定位算法。
- 应用资源与打包脚本：打包 Logo 并记录来源，兼容 swift run 与 .app。
- Tests/CodexTokenMonitorTests/：解析、状态、刷新路由、界面和资源加载验证。
- README.md、docs/images/：更新使用条件、简介 / 明细截图；示例数据明确标注。

## 命令

在 /Users/hisoka/Documents/Playground/codex-token-monitor 执行：

```sh
swift test
swift build -c release
swift run
git diff --check
```

## 代码风格

保持四空格、描述性命名，UI 状态使用 MainActor，I/O 不阻塞主线程。沿用现有模式：

```swift
@Published private(set) var isRefreshingClaude = false
@Published private(set) var claudeLastSuccessAt: Date?
```

仅抽取本轮确实需要的共享额度显示逻辑，不搭建未来供应商插件框架。

## 测试与验证

- 先写失败测试：合法 Credits、零额度、无限、字段缺失、越界、GraphQL errors、额外额度及日期。
- 验证默认关闭、持久化、验证不启用轮询、限流退避、取消、迟到结果和密钥不泄露。
- 验证简介默认、模式切换无网络副作用、各来源单位与标签、全关闭和错误占位。
- 验证菜单栏 / Touch Bar 同源，刷新仅影响选中服务，不改变 Codex 回写。
- 浅色、深色、错误和四供应商满内容分别渲染检查；Logo 验证在 swift run 和打包产物中可加载。
- 有效本机登录条件下做一次只读 Warp 查询；如受凭据 / 接口限制，单独报告，不能把 fixture 测试当作真实连接成功。
- 完整测试与 Release 编译通过。实机多屏定位及 Touch Bar 视觉体验仍需用户复核。

## 边界

实现验证：95 项测试通过（含原生界面预览、密钥输入焦点、Logo 加载、Warp 状态与 Touch Bar），Release 编译通过；按 Release 目录布局复制资源后四个 Logo 均可读取。README 使用明确标注的示例截图与实际绘制代码导出的 GIF，不充当真实账户验证。

- 始终：保护现有未提交改动，验证外部数据，未知值明确占位。
- 先确认：新增授权、修改登录状态、安装依赖、Windows 同步、推送和发布。
- 禁止：复制凭据到日志或文档、购买 Credits、执行模型任务、混用团队余额、为视觉展示伪造额度。
