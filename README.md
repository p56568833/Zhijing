# 知境

一款原生 macOS Markdown 知识库与写作应用。真实的 Markdown 文件夹是唯一数据源。

![知境应用图标](Assets/AppIcon.png)

## 下载

前往 [GitHub Releases](https://github.com/p56568833/Zhijing/releases/latest) 下载最新版 Universal DMG。安装包同时支持 Apple 芯片和 Intel Mac，需要 macOS 14 或更高版本。

当前公开构建尚未使用 Apple Developer ID 公证。若 macOS 首次阻止打开，请在 Finder 中右键点击“知境”，选择“打开”，再确认一次。

## 当前 MVP

- 打开本地知识库，浏览、创建、编辑、重命名和删除 `.md` / `.txt`
- 自动保存、收藏、最近文稿、全文搜索与来源定位
- 编辑 / Markdown 阅读模式
- 选中文字可添加荧光、重要、概念或下划线标记；编辑时自动收起非活动标记的语法，源文仍保留为可读的 Markdown
- 选中文字后在选区旁直接写批注，批注作为 Markdown 块保存在正文中
- 外部文件变更对照，逐处接受或拒绝，并在应用前自动创建版本快照
- 手动快照与历史恢复

## 运行

在 Codex 中点击 `Run`，或运行：

```bash
./script/build_and_run.sh
```

构建后的唯一应用位于项目根目录的 `知境.app`。

## 测试

运行完整测试：

```bash
./script/test.sh
```

脚本会优先使用 `/Applications/Xcode.app` 的完整工具链，并将 SwiftPM 模块缓存保存在项目的 `.build` 目录中，避免系统命令行工具与 SDK 版本不一致。

当前项目没有第三方 SwiftPM 依赖。

## 制作发布包

运行以下命令会构建 Apple 芯片与 Intel 双架构版本，并在 `dist` 目录生成 Universal DMG：

```bash
./script/package_release.sh
```

## 本地数据

- Markdown、纯文本与 SRT 文稿保留在用户选择的知识库文件夹中。
- 历史版本和旧版批注缓存位于当前用户的 Application Support 目录；新批注直接属于 Markdown 正文。
