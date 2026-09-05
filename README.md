# InkFlow

本地运行的 macOS 简体拼音输入法，使用 librime 和系统候选窗口。

需要 Apple Silicon Mac、macOS 13 或更新版本及 Xcode 命令行工具。

## 构建与安装

```sh
macOS/scripts/build.sh
macOS/scripts/test.sh
INKFLOW_SIGN_IDENTITY='<Developer ID 证书 SHA1>' macOS/scripts/install.sh
```

首次构建需要联网下载校验过的引擎和词典；安装后的输入与词典处理不需要联网。签名使用 Team `T7976FL2LP` 的 Developer ID Application 证书，使用前检查证书主体 OU。应用标识为 `io.damao.inkflow`。

安装位置为 `~/Library/Input Methods/InkFlow.app`。在系统设置 → 键盘 → 文本输入 → 编辑中添加 InkFlow，必要时注销后重新登录。再次安装会保留旧应用备份。用户词典与部署数据保存在 `~/Library/Application Support/InkFlow`，安装不会删除它们。

## 使用

- 输入全拼，用空格或数字 1–9 选词，也可以点击候选。
- 用 Page Up / Page Down 或 `[` / `]`、`-` / `=` 翻页。
- 退格删除，Escape 取消组合；回车或切换输入源结束当前组合。
- Control + Shift + Space 切换中文与英文，并先提交当前组合。
- Command、Option 等应用快捷键交给当前应用处理。

真实文本编辑器和浏览器输入体验需要在本机启用后验证。

第三方来源、固定版本与校验值见 [依赖说明](macOS/DEPENDENCIES.md)。
