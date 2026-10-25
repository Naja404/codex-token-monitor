# macOS 拖拽安装器

v1.4.4 新增 DMG 安装窗口。双击 DMG 后显示 App、指向 `/Applications` 的快捷方式和中英文拖拽提示。ZIP 仍保留供兼容下载。

## 从 App 生成 DMG

需要 macOS、Swift、`hdiutil` 和 Python 3.10+。使用固定版本的 [dmgbuild](https://dmgbuild.readthedocs.io/) 直接写入 Finder 布局文件，无需控制 Finder，也不需要桌面会话或自动化权限。最终产物为只读压缩磁盘镜像。

```bash
python3 -m venv .build/dmg-tools
.build/dmg-tools/bin/python -m pip install -r Packaging/requirements-dmg.txt
export DMG_PYTHON="$PWD/.build/dmg-tools/bin/python"
bash scripts/create-dmg.sh \
  "dist/Codex Token Monitor.app" \
  dist/Codex-Token-Monitor-macOS-arm64.dmg
```

输入 App 必须已经完成签名，脚本不会重新签名或修改源 App。它会验证镜像内 App 的签名、Applications 链接、Finder 图标位置与背景布局及最终 DMG 校验和。失败即停止，临时挂载和目录会在退出时清理。GitHub Actions 在组装 App 后执行同一个脚本，并保存 ZIP 和 DMG。

## 正式分发

仓库既有分发规则继续适用：CI 的 ad-hoc 包只作为 Actions artifact，不直接上传公开 Release。正式分发顺序为：

1. 对最终 App 使用 Developer ID Application、Hardened Runtime 和安全时间戳签名。
2. 用临时 ZIP 提交 App 公证，Accepted 后给源 App 附加票据。
3. 从这个 App 生成正式 ZIP 和 DMG，确保离线安装时 App 本身已有票据。
4. 对 DMG 进行 Developer ID 签名，再提交 DMG 公证，Accepted 后给 DMG 附加票据。
5. 验证最终 DMG 的 `hdiutil verify`、`codesign --verify`、`xcrun stapler validate`；挂载后验证 App 的 `codesign --verify --deep --strict`、`xcrun stapler validate`、`spctl --assess --type execute --verbose` 和 `--verify-resources`，并实际打开窗口检查拖拽布局。
6. 将验证通过的文件上传到草稿 Release，附件及 CI 核对通过后发布。

签名身份、公证配置只保存在本机钥匙串或私有 CI 配置，不写进脚本。生成本地 ad-hoc 预览包不代表已完成 Developer ID 签名、公证或发布。

## 未公证预发布

v1.4.4 经项目所有者明确授权以未公证预发布形式提供。Actions 手动运行时填写与 App 版本一致的 `release_tag`，仅在确认说明已披露 ad-hoc 签名及未公证限制后启用 `publish_prerelease`。工作流等待两个平台构建成功，上传 macOS DMG、macOS ZIP、Windows ZIP 及 SHA-256 校验和，再发布为 Pre-release，并显式保留原 Latest 稳定版。此选项默认关闭，不能用作正式稳定版签名公证的替代。
