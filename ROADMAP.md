# 产品路线图 / Roadmap

更新：2026-10-11。目标是把 Codex Token Monitor 逐步发展为**多供应商 AI 额度监控工具**，优先保证数据可信、读取安全、查看直观。

本文件是当前范围与进度的统一入口。`docs/multi-provider-spec.md`、`docs/warp-and-popover-spec.md` 保留历史阶段的设计和验证记录；与新需求冲突时，以当前代码、本路线图及对应版本说明为准。

“已实现”不等于“所有账号已实测”。本文件按 **v1.4.3** 范围整理，包含玻璃主题与折叠动效修复；本版 macOS 安装包已完成签名、公证及解压验证，详见 [版本说明](docs/releases/v1.4.3.md)。实际发布状态与可下载附件以 [GitHub Release](https://github.com/Naja404/codex-token-monitor/releases/tag/v1.4.3) 为准。

## 已完成

### 当前实现（v1.4.3）

| 方向 | 已实现范围 | 边界 |
| --- | --- | --- |
| Codex | 本机登录凭据直连 OpenAI；套餐、5 小时 / 每周、附加额度 | 套餐分支有解析测试；不是 API Key 余额，不推算精确剩余 Token |
| Antigravity | 官方 agy CLI 检测、版本与登录条件检查、Gemini / Claude + GPT 分组额度 | 本机 CLI 已实测；不把两个模型组的百分比合并 |
| Claude Code | 默认本机订阅 OAuth，独立刷新 Anthropic 额度 | 不支持任意代理 Key、自定义配置目录或多账号；真实账号验收见下节 |
| Warp | 个人 API Key、周期 Credits、个人额外 Credits | 代码和离线测试已完成；尚缺真实个人 Key 验证，不包含团队额度 |
| TeamoRouter | 从 .zshrc 安全导入或手动配置；余额、今日消费、Token 用量与请求数 | 已完成本机三个接口只读验证；不是 Claude 官方订阅额度，不计算不存在的百分比 |
| 生命周期 | 独立开关、验证、最近成功时间、错误分类、限流退避、取消与迟到结果丢弃 | 新增供应商默认关闭；安装检测不代表已登录或接口可用 |
| 展示与交互 | 紧凑概览、单卡折叠、全部展开 / 收起、可折叠连接设置、中英文 | 折叠不清空配置输入，也不触发额外额度请求 |
| 菜单栏 / Touch Bar | 系统单色、固定或 5–60 秒轮播、10/30/60 秒快捷项、翻牌；小猫随当前额度组联动 | 无数据或低于 10% 时睡眠；无百分比分母的金额不参与速度推算 |
| 外观 | 原生、极光、深空、液态玻璃四套主题；系统 / 浅色 / 深色；动效与无障碍适配 | macOS 14 兼容材质，不使用 macOS 26 原生玻璃 API；不改变刷新频率、额度颜色含义或品牌 Logo |
| Codex 回写 | API 地址、Bearer、Key ID、保存/验证、定时回写、成功时间、连续失败暂停 | 仅发送真实且完整的 Codex 账户窗口；不回写其他供应商或手动值 |
| 分发 | GitHub 中英文 Release；macOS Developer ID 签名、公证及票据 | Windows x64 包保留 Codex 托盘与回写，未签名；不等同于 macOS 功能全集 |

### v1.4.3 本轮交付

- [x] 折叠区域的高度与淡入淡出过渡；展开 260ms、收起 180ms，箭头同节奏，支持中途反向及关闭动效。
- [x] 五供应商批量折叠、不同高度卡片和滚动视口回归；输入草稿保留。
- [x] 修复刷新成功微光与快速折叠同时发生时的卡片重叠：微光仅控制颜色透明度，描边跟随当前卡片边界；增加刷新与连续反向折叠的回归测试。
- [x] 新增“液态 · 玻璃”主题：兼容 macOS 14 的材质、高光和阴影，增强边缘反光与视觉层次；四主题设置采用两列预览。保留浅深色、中英文及实色降级，真实桌面 / 硬件验收仍列在下节。
- [x] 整理本路线图，修正 README 中的余额支持、平台差异和发布状态说明。
- [x] 更新玻璃主题截图与 6 帧演示 GIF；本地 134 项 Swift 测试、3 项额外原生折叠渲染测试及 arm64 Release 构建通过。
- [x] 本版 macOS App 使用 Developer ID、Hardened Runtime 和安全时间戳签名；Apple 公证 Accepted、附加票据成功，最终 ZIP 解压后的签名、票据、Gatekeeper 和资源检查通过。

发布流程：GitHub Actions 构建 Windows 包并附入草稿，macOS 正式附件使用上述已签名公证 ZIP；两平台 CI 与附件核对通过后才发布。CI 构建不替代下述真实账号和硬件验收。

## 待验证

这些是验收缺口，不是尚未编写的功能。离线 fixture、截图渲染和单元测试不能替代真实账号 / 硬件测试。

| 项目 | 验收条件 |
| --- | --- |
| Warp 真实账号 | 用户在本机填入个人 Key；对照官方客户端确认周期、剩余 Credits、额外额度与重置时间；凭据不进日志或截图 |
| Codex 套餐矩阵 | 用 Free / Plus / Pro / Business / Enterprise / Edu 对应账号确认实际返回；缺失窗口显示不可用，不按套餐猜数值 |
| Claude Code 订阅 | 有效 OAuth 下对照官方用量页面；验证令牌过期、钥匙串拒绝及 429 冷却的恢复路径 |
| macOS 实机交互 | M1 + macOS 14.8；两屏切换、未激活屏首次点击、失焦收起、键盘焦点、折叠连续点击、Touch Bar 切换和动画 |
| 玻璃主题 | 浅深色、浅/深桌面背景、四主题切换、英文标签、减少动态效果 / 透明度 / 增强对比度；字体和错误信息清晰，CPU 无持续装饰动画负担 |
| Windows | 10/11 x64 托盘点击、缩放、多屏定位、DPAPI 配置恢复；不能以 CI 编译成功代替实机验收 |

## 下一阶段

以下是建议执行顺序，不是已承诺的版本日期。每项通过验收后再进入下一项；新增供应商和发布动作仍需单独确认。

### 1. 收尾当前体验与可靠性（优先）

- 完成上述真实账号与 M1 / 双屏验收，优先修复可复现问题；同步 README 截图和已知限制。
- 检查凭据存储边界：现有 macOS **Codex 回写 Bearer 仍保存在 UserDefaults**；规划独立迁移到钥匙串，要求旧配置可恢复、迁移失败不丢失数据。v1.4.3 不修改凭据存储。
- 验收：全量 Swift 测试、Release 构建、原生界面预览通过；按平台记录剩余手工验收项。只有用户要求发布时才制作下一版签名公证安装包。

### 2. 逐个增加供应商

- 先确认用户优先级、可用账号和只读数据源，再选择下一家；优先有明确额度接口或结构化 CLI 输出的服务。
- 每家作为完整小任务：读取与解析 → 独立配置和状态 → 菜单栏 / Touch Bar 路由 → 测试、真实验证、文档。复用现有最小边界，不预先搭建插件平台。
- 验收：明确订阅百分比 / Credits / 金额单位、账户与模型组范围、凭据权限及刷新约束；有真实返回依据，缺失数据可解释，停用后不继续查询。

## 暂不做（保留候选，不代表取消）

| 项目 | 暂缓原因 / 重新启动条件 |
| --- | --- |
| 多账号与账号切换 | 先定义账号标识、凭据隔离和官方客户端登录互不干扰的方案，再单独立项 |
| 历史趋势、消耗预测 | 当前展示即时快照；先确定本地保留时长、隐私与“重置 / 充值 / 缺数据”的统计含义，不伪造历史 |
| Windows 多供应商、主题同步 | 独立平台工作；先完成现有托盘实机验收，再确认移植范围 |
| 泛化第三方代理余额 | 目前仅专门接入 TeamoRouter；不能把任意 ANTHROPIC_BASE_URL 当成同一种计费 API |
| 运行中 / 未读完成 / 等待输入对话数 | 此前已撤回；没有可靠状态来源时不通过日志猜测，不混进额度监控 |
| macOS 26 原生 Liquid Glass API | 本轮优先兼容 macOS 14.8；不提升最低系统要求，未来单独评估原生增强 |
| App Store 上架 | 需单独评估沙盒、凭据读取、外部 CLI 与审核要求；Developer ID 公证不等于可上架 |
| 云端账号托管、任意脚本 / 动态插件、自动登录 | 超出本地只读额度工具当前边界；不在本轮建立相关能力 |

## 长期原则与维护规则

- 不把未知或读取失败显示为 0% / 100%；不把历史成功值冒充刚刚刷新成功。
- 不混合供应商、账户、模型组与计费单位；没有总量分母就不计算剩余百分比。
- 不读取 / 上传提示词、代码、对话内容，不执行模型任务来“探测余额”，不自动修改官方客户端登录状态。
- 凭据留在本机；不进入 Git、日志、README、演示截图或遥测。配置导入不得执行 `.zshrc`。
- 新服务默认关闭；后台读取不阻塞界面，遵守服务端限流，关闭后忽略迟到结果。
- 每次交付更新本文件对应项，并注明“源码未发布 / 发布版本”；真实验收记录不使用模拟测试结果替代。

English summary: a local, read-only multi-provider quota monitor. Implemented features, real-account/hardware validation, next steps and deferred scope are tracked separately. v1.4.3 includes the glass-inspired theme and disclosure-motion fixes. Local tests and the arm64 Release build passed; the macOS package is signed, notarized, stapled and verified after extraction. GitHub Actions builds the Windows package, and publication follows successful CI and asset checks. The Release page is authoritative for publication status. Windows retains Codex-only functionality.
