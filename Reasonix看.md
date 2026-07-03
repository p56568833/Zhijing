# Reasonix 看

## 开发工作流

1. 改代码
2. `swift build --disable-sandbox`
3. 打包到 `dist/`：
   ```
   mkdir -p dist/知境测试版.app/Contents/MacOS dist/知境测试版.app/Contents/Resources
   cp .build/arm64-apple-macosx/debug/Zhijing dist/知境测试版.app/Contents/MacOS/Zhijing
   cp Assets/AppIcon.icns dist/知境测试版.app/Contents/Resources/
   ```
   （Info.plist 如不存在也需创建）
4. `open dist/知境.app` 快速预览效果

## 重要规则

- **不要**试图写入 `~/Applications/知境.app` 或 `~/Applications/知境测试版.app`。开发包只保留在 `dist/`。
- **不要**手动删除用户的 `~/Applications/知境.app`。那是用户的唯一安装版本。
- 最终安装由用户手动完成：`dist/知境.app` → 拖到 `~/Applications/` 替换。
- 开发期间始终从 `dist/知境测试版.app` 直接启动测试。Dock 中显示为「**知境测试版**」，可与正式版区分。
- 每次改完代码记得 `touch` 相关文件后再 build，避免增量编译缓存没更新。

## 项目信息

- 名称：知境
- 类型：macOS 原生 App（SwiftUI + AppKit）
- 最低系统：macOS 14
- 构建工具：Swift Package Manager
