# Codex Token Monitor

<p align="center">
  <img src="Assets/AppIcon.png" width="128" alt="Codex Token Monitor 应用图标">
</p>

<p align="center">在 macOS 菜单栏中实时查看 Codex 的 5 小时与每周额度。</p>

<p align="center">
  <img src="https://raw.githubusercontent.com/Naja404/codex-token-monitor/37479fea56cc835e2cdb10e664e7bff4384ff177/docs/images/menu-popover.png" width="340" alt="Codex Token Monitor 菜单栏与详情面板">
</p>

## 功能

- 菜单栏双行显示：5 小时 / 每周剩余额度与下次重置时间。
- 点按菜单栏项目查看进度条、精确重置时间和累计 session token。
- 每分钟自动刷新，也会在详情面板打开时刷新。
- 直接使用本机 Codex 登录凭据请求 OpenAI 额度，不经过第三方 Adapter。
- 使用 macOS 系统菜单栏模板颜色，自动适应浅色和深色外观。

## 安装

1. 在 [Releases](../../releases) 下载 `Codex-Token-Monitor-macOS-arm64.zip`。
2. 解压后，将 `Codex Token Monitor.app` 拖入“应用程序”。
3. 首次打开如被 Gatekeeper 拦截，请在 Finder 中右键应用，选择“打开”。
4. 在此 Mac 上登录 Codex 后启动应用；菜单栏会显示真实额度。

> 当前发布包面向 Apple Silicon（M1/M2/M3/M4）与 macOS 14 或更高版本。

## 数据与隐私

应用只读取本机 `~/.codex/auth.json` 内由 Codex 登录保存的凭据，并请求 OpenAI 的 `https://chatgpt.com/backend-api/wham/usage` 来获取当前账号的额度窗口。

- 不读取或上传你的提示词、代码或聊天内容。
- 不写入或修改 Codex 凭据。
- 不使用第三方 Adapter 或中转服务。
- 未登录、凭据失效或接口不可用时，界面显示占位符。

## 从源码运行

需要 macOS 14+ 与 Xcode Command Line Tools。

```bash
git clone https://github.com/<your-account>/codex-token-monitor.git
cd codex-token-monitor
swift run
```

## 发布新版本

仓库已经包含 GitHub Actions 工作流。创建并推送 `v` 前缀标签即可自动构建 Apple Silicon 安装包、上传构建产物并创建 GitHub Release：

```bash
git tag v1.0.0
git push origin v1.0.0
```

## 已知限制

- 本工具显示 ChatGPT/Codex 订阅额度，不是 OpenAI API key 的 API 限流数据。
- 此额度接口未作为公开稳定 SDK 契约发布；OpenAI 或 Codex 的内部实现变化可能影响读取结果。
- 应用使用 ad-hoc 签名，尚未经过 Apple 公证。

## License

暂未指定许可证。发布前请根据你的分发计划添加许可证文件。
