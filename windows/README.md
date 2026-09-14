# Codex Token Monitor · Windows

Windows 10/11 x64 系统托盘版，使用 C# / WPF / .NET 10。免安装包自带运行时，解压后运行 `CodexTokenMonitor.exe`；关闭详情面板后继续在托盘运行，右键托盘图标选择“退出”结束。

## 登录与运行

1. 先在 **Windows 本机**使用 ChatGPT 账户登录 Codex，生成 `%USERPROFILE%\.codex\auth.json`。如果设置了 `CODEX_HOME`，则读取该目录下的 `auth.json`。
2. 运行 EXE，在任务栏右下角找到图标（可能位于隐藏图标区域）。无需保持 Codex 窗口开启。
3. 点击显示详情，点其他窗口或按 Escape 收起。右键菜单提供刷新、回写设置和退出。

API Key 登录、仅保存在其他设备或 WSL 内的凭据，以及仅存于系统凭据库而没有 `auth.json` 的登录方式，目前无法读取。应用不主动刷新 OAuth 令牌；HTTP 401 时需要在 Codex 中重新登录。

## 额度与回写

- 每 30 秒读取一次 OpenAI usage 数据。托盘数字优先显示账户 5 小时剩余百分比，没有此窗口时显示周余量；悬浮提示注明两个窗口。
- 识别 Free、Plus、Pro、Business、Enterprise、Edu，未知套餐保留原始值；不据此推断席位档位。
- 按窗口秒数识别 5 小时和每周额度。缺失窗口显示“未提供”，附加模型额度单独标明来源。读取失败后清除旧额度。
- 回写设置支持 API 地址、Bearer、Codex Key ID、1–60 分钟间隔（默认 1 分钟），自动回写默认关闭。
- “保存配置”持久化设置并重置失败计数；“验证连接”向草稿地址发送一次真实额度，不保存草稿、不累计失败；“立即回写”使用已保存配置。
- 连续 10 次回写失败后暂停，最近成功时间和错误状态显示在面板及设置窗口中。修正配置并保存后恢复。
- 回写仅发送完整且本次成功读取的账户双窗口；不发送模型附加额度或缺失窗口。JSON 与 macOS 版一致，时间采用 Windows 本地时区。
- Bearer 使用 Windows DPAPI 当前用户加密，设置保存在 `%LOCALAPPDATA%\CodexTokenMonitor\settings.json`，不能直接复制到别人的电脑使用。

## 构建

安装 .NET 10 SDK 后，在仓库根目录执行：

```powershell
dotnet run --project windows/Checks -c Release
dotnet publish windows/App/App.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:DebugType=None -o dist/windows-x64
```

GitHub Actions 的 Windows build 会运行逻辑检查、编译 EXE、生成 ZIP artifact；版本标签发布流程会将 Windows ZIP 添加到同一 GitHub Release。当前是免安装 ZIP，不是 MSI 安装程序。程序尚未做 Windows 代码签名。

## 实机验收

数据检查覆盖套餐、窗口顺序、模型额度隔离、回写 JSON、调度间隔和连续失败暂停。仍需要 Windows 实机验证：

- 冷启动与重复启动仅一个实例、隐藏图标区、右键退出及任务栏重启后的图标恢复。
- 双屏不同缩放比例，分别首次点击非活动屏托盘，确认面板可见且不越界；失焦和 Escape 收起。
- 配置输入、保存重启后恢复、验证请求、成功时间、10 次失败暂停与重新保存恢复。
- 用各套餐真实账号核对额度，凭据失效/断网显示占位，缺失窗口时不回写。

Windows 界面使用原生控件，目前未复刻 macOS 的玻璃材质，也没有手动额度编辑。Mac 上无法验证 Windows 桌面交互，构建成功不代表这些实机检查已通过。
