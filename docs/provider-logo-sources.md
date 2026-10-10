# 供应商品牌资源

仅用于标识额度所属供应商，不代表官方背书。品牌名称、Logo 及应用图标属于各自所有者，**不适用本项目源代码的 MIT 授权**；再分发时应遵守各品牌使用要求。

| 文件 | 来源（2026-10-10） | 说明 |
| --- | --- | --- |
| `codex.png` | OpenAI 官方 ChatGPT macOS 应用 `Contents/Resources/electron.icns` | OpenAI 标识，用于 Codex；不是自行设计的 Codex 专用 Logo |
| `antigravity.png` | Google 官方 Antigravity 应用 `Contents/Resources/icon.icns` | 原应用图标 |
| `warp.png` | Warp 官方应用 `Contents/Resources/AppIcon.icns` | 原应用图标 |
| `claude.png` | [Claude 官方网站图标](https://claude.com/icon.png) | Claude 星形标识 |

PNG 随 SwiftPM 资源包离线分发；从 ICNS 导出时仅转换格式并缩小到 128px，未重绘品牌图形。应用运行时不依赖其他应用安装路径，不请求远程图标。Release 工作流将 `CodexTokenMonitor_CodexTokenMonitor.bundle` 放在 `.app` 根目录，以匹配 SwiftPM 的 `Bundle.module` 查找位置。
